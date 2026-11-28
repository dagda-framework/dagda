#+build !windows
package driver

import "core:c"
import "core:sys/posix"

Socket_Handle :: posix.FD

INVALID_SOCKET_HANDLE :: Socket_Handle(-1)

Socket_Error :: enum {
	None,
	Again,
	Other,
}

close_socket :: proc(fd: Socket_Handle) {
	if fd >= 0 {
		posix.close(fd)
	}
}

socket_send :: proc(fd: Socket_Handle, data: rawptr, length: int) -> (int, Socket_Error) {
	n := posix.send(fd, data, c.size_t(length), {.NOSIGNAL})
	if n < 0 {
		err := posix.errno()
		return 0, (err == .EAGAIN || err == .EWOULDBLOCK) ? .Again : .Other
	}
	return int(n), .None
}

socket_recv :: proc(fd: Socket_Handle, data: rawptr, length: int) -> (int, Socket_Error) {
	n := posix.recv(fd, data, c.size_t(length), {})
	if n < 0 {
		err := posix.errno()
		return -1, (err == .EAGAIN || err == .EWOULDBLOCK) ? .Again : .Other
	}
	return int(n), .None
}

set_nonblocking_socket :: proc(fd: Socket_Handle) -> bool {
	flags := posix.fcntl(fd, .GETFL)
	if flags < 0 {
		return false
	}
	return posix.fcntl(fd, .SETFL, flags | c.int(posix.O_NONBLOCK)) >= 0
}

socket_accept :: proc(listen_fd: Socket_Handle) -> (Socket_Handle, bool) {
	conn := posix.accept(listen_fd, nil, nil)
	return conn, conn >= 0
}

socket_poll :: proc(requests: []Socket_Poll_Request, results: []Socket_Poll_Result) -> int {
	pfds := make([]posix.pollfd, len(requests))
	defer delete(pfds)
	for req, i in requests {
		ev: posix.Poll_Event
		if req.want_read {
			ev += {.IN}
		}
		if req.want_write {
			ev += {.OUT}
		}
		pfds[i] = posix.pollfd{fd = req.fd, events = ev}
	}
	ready := posix.poll(raw_data(pfds), posix.nfds_t(len(pfds)), 0)
	if ready <= 0 {
		return int(ready)
	}
	for pf, i in pfds {
		results[i] = {
			read  = .IN in pf.revents,
			write = .OUT in pf.revents,
			err   = (.ERR in pf.revents) || (.NVAL in pf.revents),
			hup   = .HUP in pf.revents,
		}
	}
	return int(ready)
}

make_addr :: proc(path: string) -> (posix.sockaddr_un, bool) {
	addr: posix.sockaddr_un
	if len(path) == 0 || len(path) >= len(addr.sun_path) {
		return addr, false
	}
	addr.sun_family = posix.sa_family_t(posix.AF_UNIX)
	for i in 0 ..< len(path) {
		addr.sun_path[i] = c.char(path[i])
	}
	return addr, true
}

path_cstring :: proc(path: string, buf: ^[128]u8) -> cstring {
	buf^ = {}
	if len(path) >= len(buf) {
		return nil
	}
	copy(buf[:], path)
	return cstring(raw_data(buf[:]))
}

Endpoint_Identity :: struct {
	dev:   posix.dev_t,
	ino:   posix.ino_t,
	valid: bool,
}

endpoint_identity :: proc(path: string) -> Endpoint_Identity {
	buf: [128]u8
	cpath := path_cstring(path, &buf)
	if cpath == nil {
		return {}
	}
	st: posix.stat_t
	if posix.lstat(cpath, &st) != .OK {
		return {}
	}
	return {dev = st.st_dev, ino = st.st_ino, valid = true}
}

remove_unix_owned :: proc(path: string, identity: Endpoint_Identity) {
	if !identity.valid {
		return
	}
	current := endpoint_identity(path)
	if !current.valid || current.dev != identity.dev || current.ino != identity.ino {
		return
	}
	buf: [128]u8
	if cpath := path_cstring(path, &buf); cpath != nil {
		posix.unlink(cpath)
	}
}

listen_unix :: proc(path: string) -> (Socket_Handle, Endpoint_Identity, bool) {
	addr, ok := make_addr(path)
	if !ok {
		return INVALID_SOCKET_HANDLE, {}, false
	}
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {
		return INVALID_SOCKET_HANDLE, {}, false
	}
	if posix.bind(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK {
		posix.close(fd)
		return INVALID_SOCKET_HANDLE, {}, false
	}
	identity := endpoint_identity(path)
	if posix.listen(fd, 16) != .OK {
		posix.close(fd)
		remove_unix_owned(path, identity)
		return INVALID_SOCKET_HANDLE, {}, false
	}
	return fd, identity, true
}

connect_unix :: proc(path: string) -> (Socket_Handle, bool) {
	addr, ok := make_addr(path)
	if !ok {
		return INVALID_SOCKET_HANDLE, false
	}
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {
		return INVALID_SOCKET_HANDLE, false
	}
	if posix.connect(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK {
		posix.close(fd)
		return INVALID_SOCKET_HANDLE, false
	}
	return fd, true
}
