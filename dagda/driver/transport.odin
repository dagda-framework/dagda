package driver

import "core:strings"

// Shared stream helpers for the local socket transport. The
// socket itself is platform-specific: POSIX in
// socket_posix.odin, Winsock AF_UNIX in socket_windows.odin.
// Socket_Handle, INVALID_SOCKET_HANDLE, listen_unix,
// connect_unix, close_socket, Endpoint_Identity, and
// endpoint_identity are defined there with identical
// signatures so the wire protocol and call sites do not
// change between platforms.

write_all :: proc(fd: Socket_Handle, data: string) -> bool {
	sent := 0
	for sent < len(data) {
		remaining := len(data) - sent
		n, _ := socket_send(fd, raw_data(data[sent:]), remaining)
		if n <= 0 {
			return false
		}
		sent += n
	}
	return true
}

Line_Reader :: struct {
	fd:    Socket_Handle,
	buf:   [4096]u8,
	start: int,
	end:   int,
}

read_line :: proc(r: ^Line_Reader) -> (line: string, ok: bool) {
	b: strings.Builder
	strings.builder_init(&b)
	for {
		if r.start < r.end {
			i := r.start
			for i < r.end && r.buf[i] != '\n' {
				i += 1
			}
			strings.write_string(&b, string(r.buf[r.start:i]))
			if i < r.end {
				r.start = i + 1
				s := strings.to_string(b)
				if len(s) > 0 && s[len(s) - 1] == '\r' {
					s = s[:len(s) - 1]
				}
				return s, true
			}
			r.start = r.end
		}
		n, _ := socket_recv(r.fd, raw_data(r.buf[:]), len(r.buf))
		if n <= 0 {
			strings.builder_destroy(&b)
			return "", false
		}
		r.start = 0
		r.end = n
	}
}
