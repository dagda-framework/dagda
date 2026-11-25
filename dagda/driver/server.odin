package driver

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "dagda:dagda"

Client_Conn :: struct {
	fd:       posix.FD,
	in_buf:   [dynamic]u8,
	out_buf:  [dynamic]u8,
	out_sent: int,
	eof:      bool,
	drop:     bool,
}

// Server is a non-blocking Unix-domain socket server that runs on the host's
// main thread so idle or partially written clients never stall UI rendering.
Server :: struct {
	active:    bool,
	path:      string,
	listen_fd: posix.FD,
	identity:  Endpoint_Identity,
	clients:   [dynamic]Client_Conn,
}

set_nonblocking :: proc(fd: posix.FD) -> bool {
	flags := posix.fcntl(fd, .GETFL)
	if flags < 0 {
		return false
	}
	return posix.fcntl(fd, .SETFL, flags | c.int(posix.O_NONBLOCK)) >= 0
}

compact_out_buf :: proc(client: ^Client_Conn) {
	if client.out_sent <= 0 {
		return
	}
	remaining := len(client.out_buf) - client.out_sent
	if remaining > 0 {
		copy(client.out_buf[:remaining], client.out_buf[client.out_sent:])
		resize(&client.out_buf, remaining)
	} else {
		clear(&client.out_buf)
	}
	client.out_sent = 0
}

server_start :: proc(srv: ^Server, path: string) -> bool {
	if os.exists(path) {
		fmt.eprintf("socket path already exists: %s\n", path)
		return false
	}
	listen_fd, identity, ok := listen_unix(path)
	if !ok {
		fmt.eprintf("could not listen on %s\n", path)
		return false
	}
	if !set_nonblocking(listen_fd) {
		posix.close(listen_fd)
		remove_unix_owned(path, identity)
		fmt.eprintf("could not configure non-blocking socket on %s\n", path)
		return false
	}
	srv.active = true
	srv.path = strings.clone(path)
	srv.listen_fd = listen_fd
	srv.identity = identity
	fmt.printf("Listening %s\n", srv.path)
	_ = os.flush(os.stdout)
	return true
}

client_destroy :: proc(client: ^Client_Conn) {
	if client.fd >= 0 {
		posix.close(client.fd)
		client.fd = -1
	}
	delete(client.in_buf)
	delete(client.out_buf)
}

server_stop :: proc(srv: ^Server) {
	if !srv.active {
		return
	}
	for &client in srv.clients {
		client_destroy(&client)
	}
	delete(srv.clients)
	if srv.listen_fd >= 0 {
		posix.close(srv.listen_fd)
		srv.listen_fd = -1
	}
	remove_unix_owned(srv.path, srv.identity)
	delete(srv.path)
	srv.path = ""
	srv.active = false
}

// server_poll accepts connections, reads complete newline-delimited requests,
// dispatches them against the current frame, and flushes replies. When an
// invoke applies, rebuild_frame is called immediately before queueing the reply
// so pipelined requests see the updated state. If rebuild_frame returns false,
// Frame_Invalid is returned, further request processing stops immediately, and
// rebuild_failed is reported so the host can exit cleanly.
server_poll :: proc(
	srv: ^Server,
	frame: ^dagda.Frame,
	handler: dagda.Action_Handler,
	user_data: rawptr,
	rebuild_ctx: rawptr,
	rebuild_frame: proc(ctx: rawptr) -> bool,
) -> (any_applied: bool, rebuild_failed: bool) {
	return server_poll_source(srv, frame, handler, user_data, {}, false, rebuild_ctx, rebuild_frame)
}

// server_poll_edits is server_poll with an advertised-edit source:
// edits / preview / commit requests dispatch through it while
// inspect and invoke keep their existing behavior.
server_poll_edits :: proc(
	srv: ^Server,
	frame: ^dagda.Frame,
	handler: dagda.Action_Handler,
	user_data: rawptr,
	source: Edit_Source,
	rebuild_ctx: rawptr,
	rebuild_frame: proc(ctx: rawptr) -> bool,
) -> (any_applied: bool, rebuild_failed: bool) {
	return server_poll_source(srv, frame, handler, user_data, source, true, rebuild_ctx, rebuild_frame)
}

server_poll_source :: proc(
	srv: ^Server,
	frame: ^dagda.Frame,
	handler: dagda.Action_Handler,
	user_data: rawptr,
	source: Edit_Source,
	use_edits: bool,
	rebuild_ctx: rawptr,
	rebuild_frame: proc(ctx: rawptr) -> bool,
) -> (any_applied: bool, rebuild_failed: bool) {
	if !srv.active {
		return false, false
	}

	for {
		conn := posix.accept(srv.listen_fd, nil, nil)
		if conn < 0 {
			break
		}
		if !set_nonblocking(conn) {
			posix.close(conn)
			continue
		}
		append(&srv.clients, Client_Conn{fd = conn})
	}

	if len(srv.clients) == 0 {
		return false, false
	}

	pfds := make([]posix.pollfd, len(srv.clients))
	defer delete(pfds)
	for i in 0 ..< len(srv.clients) {
		ev: posix.Poll_Event
		if !srv.clients[i].eof {
			ev += {.IN}
		}
		if srv.clients[i].out_sent < len(srv.clients[i].out_buf) {
			ev += {.OUT}
		}
		pfds[i] = posix.pollfd{fd = srv.clients[i].fd, events = ev}
	}

	ready := posix.poll(raw_data(pfds), posix.nfds_t(len(pfds)), 0)
	if ready <= 0 {
		return false, false
	}

	read_buf: [4096]u8
	i := 0
	for i < len(srv.clients) {
		revents := pfds[i].revents
		client := &srv.clients[i]

		if .ERR in revents || .NVAL in revents {
			client.drop = true
		}

		if !client.drop && !rebuild_failed && (.IN in revents || .HUP in revents) && !client.eof {
			for {
				n := posix.recv(client.fd, rawptr(&read_buf), c.size_t(len(read_buf)), {})
				if n > 0 {
					append(&client.in_buf, ..read_buf[:int(n)])
					for !rebuild_failed {
						nl := -1
						for j in 0 ..< len(client.in_buf) {
							if client.in_buf[j] == '\n' {
								nl = j
								break
							}
						}
						if nl < 0 {
							break
						}
						line_end := nl
						if line_end > 0 && client.in_buf[line_end - 1] == '\r' {
							line_end -= 1
						}
						line := string(client.in_buf[:line_end])
						reply: string
						applied: bool
						if use_edits {
							reply, applied = dispatch_edits(frame^, handler, user_data, source, line)
						} else {
							reply, applied = dispatch(frame^, handler, user_data, line)
						}

						remaining := len(client.in_buf) - (nl + 1)
						if remaining > 0 {
							copy(client.in_buf[:remaining], client.in_buf[nl + 1:])
						}
						resize(&client.in_buf, remaining)

						if applied {
							any_applied = true
							if rebuild_frame != nil && !rebuild_frame(rebuild_ctx) {
								delete(reply)
								err_reply := reply_error("Frame_Invalid")
								append(&client.out_buf, ..transmute([]u8)err_reply)
								append(&client.out_buf, '\n')
								delete(err_reply)
								clear(&client.in_buf)
								rebuild_failed = true
								break
							}
						}

						append(&client.out_buf, ..transmute([]u8)reply)
						append(&client.out_buf, '\n')
						delete(reply)
					}
					if rebuild_failed {
						break
					}
				} else if n == 0 {
					client.eof = true
					clear(&client.in_buf)
					break
				} else {
					err := posix.errno()
					if err != .EAGAIN && err != .EWOULDBLOCK {
						client.drop = true
					}
					break
				}
			}
		}

		if !client.drop && client.out_sent < len(client.out_buf) {
			for client.out_sent < len(client.out_buf) {
				rem := client.out_buf[client.out_sent:]
				n := posix.send(client.fd, rawptr(raw_data(rem)), c.size_t(len(rem)), {.NOSIGNAL})
				if n > 0 {
					client.out_sent += int(n)
				} else if n < 0 {
					err := posix.errno()
					if err != .EAGAIN && err != .EWOULDBLOCK {
						client.drop = true
					}
					break
				} else {
					client.drop = true
					break
				}
			}
			compact_out_buf(client)
		}

		if client.drop || (client.eof && client.out_sent >= len(client.out_buf)) {
			client_destroy(client)
			ordered_remove(&srv.clients, i)
			for k := i; k + 1 < len(pfds); k += 1 {
				pfds[k] = pfds[k + 1]
			}
			continue
		}
		if rebuild_failed {
			break
		}
		i += 1
	}

	return any_applied, rebuild_failed
}
