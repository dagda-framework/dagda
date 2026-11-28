#+build windows
package driver

import "core:c"
import win "core:sys/windows"

// Winsock AF_UNIX transport: same --socket path interface
// and newline wire protocol as POSIX. Odin's Windows
// bindings have no sockaddr_un, so it is defined here
// (family AF_UNIX=1, 108-byte path, matching Winsock).

Socket_Handle :: win.SOCKET

INVALID_SOCKET_HANDLE :: win.INVALID_SOCKET

Socket_Error :: enum {
	None,
	Again,
	Other,
}

AF_UNIX :: 1
SOCK_STREAM :: 1
FIONBIO :: c.long(-2147195266) // 0x8004667e as a signed c_long
WSAEWOULDBLOCK :: 10035

Sockaddr_Un :: struct {
	family: u16,
	path:   [108]c.char,
}

winsock_started: bool

winsock_ensure :: proc() -> bool {
	if winsock_started {
		return true
	}
	data: win.WSADATA
	if win.WSAStartup(0x0202, &data) != 0 {
		return false
	}
	winsock_started = true
	return true
}

close_socket :: proc(fd: Socket_Handle) {
	if fd != INVALID_SOCKET_HANDLE {
		_ = win.closesocket(fd)
	}
}

socket_error_of :: proc() -> Socket_Error {
	return win.WSAGetLastError() == WSAEWOULDBLOCK ? .Again : .Other
}

socket_send :: proc(fd: Socket_Handle, data: rawptr, length: int) -> (int, Socket_Error) {
	n := win.send(fd, data, c.int(length), 0)
	if n == win.SOCKET_ERROR {
		return 0, socket_error_of()
	}
	return int(n), .None
}

socket_recv :: proc(fd: Socket_Handle, data: rawptr, length: int) -> (int, Socket_Error) {
	n := win.recv(fd, data, c.int(length), 0)
	if n == win.SOCKET_ERROR {
		return -1, socket_error_of()
	}
	return int(n), .None
}

set_nonblocking_socket :: proc(fd: Socket_Handle) -> bool {
	arg: c.ulong = 1
	return win.ioctlsocket(fd, FIONBIO, &arg) != win.SOCKET_ERROR
}

socket_accept :: proc(listen_fd: Socket_Handle) -> (Socket_Handle, bool) {
	conn := win.accept(listen_fd, nil, nil)
	return conn, conn != INVALID_SOCKET_HANDLE
}

socket_poll :: proc(requests: []Socket_Poll_Request, results: []Socket_Poll_Result) -> int {
	pfds := make([]win.WSA_POLLFD, len(requests))
	defer delete(pfds)
	for req, i in requests {
		ev: c.short = 0
		if req.want_read {
			ev |= win.POLLIN
		}
		if req.want_write {
			ev |= win.POLLOUT
		}
		pfds[i] = {fd = req.fd, events = ev}
	}
	ready := win.WSAPoll(raw_data(pfds), c.ulong(len(pfds)), 0)
	if ready <= 0 {
		return int(ready)
	}
	for pf, i in pfds {
		results[i] = {
			read  = (pf.revents & win.POLLIN) != 0,
			write = (pf.revents & win.POLLOUT) != 0,
			err   = (pf.revents & (win.POLLERR | win.POLLNVAL)) != 0,
			hup   = (pf.revents & win.POLLHUP) != 0,
		}
	}
	return int(ready)
}

make_addr_un :: proc(path: string) -> (Sockaddr_Un, bool) {
	addr: Sockaddr_Un
	if len(path) == 0 || len(path) >= len(addr.path) {
		return addr, false
	}
	addr.family = AF_UNIX
	for i in 0 ..< len(path) {
		addr.path[i] = c.char(path[i])
	}
	return addr, true
}

Endpoint_Identity :: struct {
	volume: u64,
	index:  u64,
	valid:  bool,
}

endpoint_identity :: proc(path: string) -> Endpoint_Identity {
	// AF_UNIX socket files on Windows are reparse points
	// that do not reliably open as files, so the prototype
	// does not read a file identity here. remove_unix_owned
	// documents the fallback this selects.
	return {}
}

remove_unix_owned :: proc(path: string, identity: Endpoint_Identity) {
	if identity.valid {
		current := endpoint_identity(path)
		if !current.valid || current.volume != identity.volume || current.index != identity.index {
			return
		}
	}
	// With no readable identity (some AF_UNIX endpoints do
	// not open as files), the listening server still removes
	// the endpoint it created; this is the prototype's
	// documented ownership fallback on Windows.
	wbuf: [512]u16
	wpath := win.utf8_to_wstring_buf(wbuf[:], path)
	if wpath == nil {
		return
	}
	_ = win.DeleteFileW(wpath)
}

listen_unix :: proc(path: string) -> (Socket_Handle, Endpoint_Identity, bool) {
	if !winsock_ensure() {
		return INVALID_SOCKET_HANDLE, {}, false
	}
	addr, ok := make_addr_un(path)
	if !ok {
		return INVALID_SOCKET_HANDLE, {}, false
	}
	fd := win.socket(AF_UNIX, SOCK_STREAM, 0)
	if fd == INVALID_SOCKET_HANDLE {
		return INVALID_SOCKET_HANDLE, {}, false
	}
	if win.bind(fd, (^win.SOCKADDR_STORAGE_LH)(&addr), c.int(size_of(addr))) == win.SOCKET_ERROR {
		_ = win.closesocket(fd)
		return INVALID_SOCKET_HANDLE, {}, false
	}
	identity := endpoint_identity(path)
	if win.listen(fd, 16) == win.SOCKET_ERROR {
		_ = win.closesocket(fd)
		remove_unix_owned(path, identity)
		return INVALID_SOCKET_HANDLE, {}, false
	}
	return fd, identity, true
}

connect_unix :: proc(path: string) -> (Socket_Handle, bool) {
	if !winsock_ensure() {
		return INVALID_SOCKET_HANDLE, false
	}
	addr, ok := make_addr_un(path)
	if !ok {
		return INVALID_SOCKET_HANDLE, false
	}
	fd := win.socket(AF_UNIX, SOCK_STREAM, 0)
	if fd == INVALID_SOCKET_HANDLE {
		return INVALID_SOCKET_HANDLE, false
	}
	if win.connect(fd, (^win.SOCKADDR_STORAGE_LH)(&addr), c.int(size_of(addr))) == win.SOCKET_ERROR {
		_ = win.closesocket(fd)
		return INVALID_SOCKET_HANDLE, false
	}
	return fd, true
}
