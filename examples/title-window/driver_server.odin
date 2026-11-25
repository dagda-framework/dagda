package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "dagda:dagda"
import driver "dagda:examples/title-driver"
import title_model "dagda:examples/title-model"

MAX_WATCH_OUT_BUF :: 1024 * 1024

Driver_Client :: struct {
	fd:       posix.FD,
	in_buf:   [dynamic]u8,
	out_buf:  [dynamic]u8,
	out_sent: int,
	eof:      bool,
	watching: bool,
	watch_id: dagda.Object_Id,
	drop:     bool,
}

// Window_Driver_Server runs the Unix-socket driver non-blockingly on the
// window thread so idle or partially written client requests and slow
// watchers never stall the SDL3 event loop or editor.
Window_Driver_Server :: struct {
	active:    bool,
	path:      string,
	listen_fd: posix.FD,
	identity:  driver.Endpoint_Identity,
	clients:   [dynamic]Driver_Client,
}

set_fd_nonblocking :: proc(fd: posix.FD) -> bool {
	flags := posix.fcntl(fd, .GETFL)
	if flags < 0 {
		return false
	}
	return posix.fcntl(fd, .SETFL, flags | c.int(posix.O_NONBLOCK)) >= 0
}

Window_Guard_State :: struct {
	editor:       ^Editor_State,
	busy_blocked: bool,
}

window_mutation_guard :: proc(ctx: rawptr) -> string {
	g := (^Window_Guard_State)(ctx)
	if editor_external_commit_gate(g.editor) == .Busy_Composing {
		g.busy_blocked = true
		return "Busy_Composing"
	}
	return ""
}

// driver_server_on_model_change is registered as the title_model.Observer on
// the model-owner thread. It encodes borrowed snapshot text into owned JSON
// event bytes before returning and queues them on each matching watcher.
driver_server_on_model_change :: proc(user_data: rawptr, kind: title_model.Change_Kind, snap: title_model.Snapshot) {
	srv := (^Window_Driver_Server)(user_data)
	if srv == nil || !srv.active {
		return
	}
	has_watcher := false
	for &client in srv.clients {
		if client.watching && !client.drop && client.watch_id == snap.object.id {
			has_watcher = true
			break
		}
	}
	if !has_watcher {
		return
	}
	line := driver.format_change_event(kind, snap)
	defer delete(line)
	for &client in srv.clients {
		if !client.watching || client.drop || client.watch_id != snap.object.id {
			continue
		}
		pending := len(client.out_buf) - client.out_sent
		if pending + len(line) + 1 > MAX_WATCH_OUT_BUF {
			client.drop = true
			continue
		}
		append(&client.out_buf, ..transmute([]u8)line)
		append(&client.out_buf, '\n')
	}
}

driver_server_attach_model :: proc(srv: ^Window_Driver_Server, model: ^title_model.Model) {
	title_model.set_observer(model, driver_server_on_model_change, srv)
}

// dispatch_window_line dispatches one wire request line on the window thread
// against the window's single live title_model.Model, enforcing Busy_Composing
// for valid mutating requests while allowing inspect and preview during preedit.
dispatch_window_line :: proc(
	model: ^title_model.Model,
	editor: ^Editor_State,
	adapter: Model_Adapter,
	line: string,
) -> string {
	guard_state := Window_Guard_State{editor = editor}
	reply := driver.dispatch_guarded(model, line, &guard_state, window_mutation_guard)
	if editor_sync_from_model(editor, adapter) {
		editor_set_status(editor, fmt.tprintf("Driver updated -> rev %d (focus preserved)", editor.snapshot_revision))
	} else if guard_state.busy_blocked {
		editor_set_status(editor, "Driver blocked: Busy_Composing (retry after preedit)")
		editor.needs_redraw = true
	}
	return reply
}

driver_server_start :: proc(srv: ^Window_Driver_Server, path: string) -> bool {
	if os.exists(path) {
		fmt.eprintf("socket path already exists: %s\n", path)
		return false
	}
	listen_fd, identity, ok := driver.listen_unix(path)
	if !ok {
		fmt.eprintf("could not listen on %s\n", path)
		return false
	}
	if !set_fd_nonblocking(listen_fd) {
		posix.close(listen_fd)
		driver.remove_unix_owned(path, identity)
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

driver_client_destroy :: proc(client: ^Driver_Client) {
	if client.fd >= 0 {
		posix.close(client.fd)
		client.fd = -1
	}
	delete(client.in_buf)
	delete(client.out_buf)
}

driver_server_stop :: proc(srv: ^Window_Driver_Server) {
	if !srv.active {
		return
	}
	for &client in srv.clients {
		driver_client_destroy(&client)
	}
	delete(srv.clients)
	if srv.listen_fd >= 0 {
		posix.close(srv.listen_fd)
		srv.listen_fd = -1
	}
	driver.remove_unix_owned(srv.path, srv.identity)
	delete(srv.path)
	srv.path = ""
	srv.active = false
}

driver_server_poll :: proc(
	srv: ^Window_Driver_Server,
	model: ^title_model.Model,
	editor: ^Editor_State,
	adapter: Model_Adapter,
) {
	if !srv.active {
		return
	}

	// Accept any pending client connections without blocking.
	for {
		conn := posix.accept(srv.listen_fd, nil, nil)
		if conn < 0 {
			break
		}
		if !set_fd_nonblocking(conn) {
			posix.close(conn)
			continue
		}
		append(&srv.clients, Driver_Client{fd = conn})
	}

	if len(srv.clients) == 0 {
		return
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
		return
	}

	read_buf: [4096]u8
	i := 0
	for i < len(srv.clients) {
		revents := pfds[i].revents
		client := &srv.clients[i]
		drop := client.drop

		if .ERR in revents || .NVAL in revents || (client.watching && .HUP in revents) {
			drop = true
		}

		if !drop && (.IN in revents || .HUP in revents) && !client.eof {
			for {
				n := posix.recv(client.fd, rawptr(&read_buf), c.size_t(len(read_buf)), {})
				if n > 0 {
					if client.watching {
						// Dedicated watch connection ignores any extra client bytes.
						continue
					}
					append(&client.in_buf, ..read_buf[:int(n)])
					// Extract and dispatch every complete newline-terminated request.
					for !client.watching {
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

						// Handle watch on the model-owner thread: register watcher
						// and capture initial snapshot atomically before any edit.
						wres := driver.try_watch(model, line)
						if wres.is_watch {
							if wres.subscribed {
								client.watching = true
								client.watch_id = wres.id
							}
							append(&client.out_buf, ..transmute([]u8)wres.reply)
							append(&client.out_buf, '\n')
							delete(wres.reply)
							clear(&client.in_buf)
							break
						}

						reply := dispatch_window_line(model, editor, adapter, line)
						append(&client.out_buf, ..transmute([]u8)reply)
						append(&client.out_buf, '\n')
						delete(reply)

						remaining := len(client.in_buf) - (nl + 1)
						if remaining > 0 {
							copy(client.in_buf[:remaining], client.in_buf[nl + 1:])
						}
						resize(&client.in_buf, remaining)
					}
				} else if n == 0 {
					client.eof = true
					clear(&client.in_buf) // discard unterminated partial line on EOF
					break
				} else {
					err := posix.errno()
					if err != .EAGAIN && err != .EWOULDBLOCK {
						drop = true
					}
					break
				}
			}
		}

		if !drop && client.out_sent < len(client.out_buf) {
			for client.out_sent < len(client.out_buf) {
				rem := client.out_buf[client.out_sent:]
				n := posix.send(client.fd, rawptr(raw_data(rem)), c.size_t(len(rem)), {.NOSIGNAL})
				if n > 0 {
					client.out_sent += int(n)
				} else if n < 0 {
					err := posix.errno()
					if err != .EAGAIN && err != .EWOULDBLOCK {
						drop = true
					}
					break
				} else {
					drop = true
					break
				}
			}
			if client.out_sent >= len(client.out_buf) {
				clear(&client.out_buf)
				client.out_sent = 0
			}
		}

		if drop || (!client.watching && client.eof && client.out_sent >= len(client.out_buf)) {
			driver_client_destroy(client)
			ordered_remove(&srv.clients, i)
			// Keep pfds aligned with remaining clients by shifting revents.
			for k := i; k + 1 < len(pfds); k += 1 {
				pfds[k] = pfds[k + 1]
			}
			continue
		}
		i += 1
	}
}
