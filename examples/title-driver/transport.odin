package title_driver

import "core:c"
import "core:strings"
import "core:sys/posix"

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

// listen_unix binds a stream socket at path. The caller owns the
// endpoint and should remove_unix(path) after closing it.
listen_unix :: proc(path: string) -> (posix.FD, bool) {
	addr, ok := make_addr(path)
	if !ok {
		return -1, false
	}
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {
		return -1, false
	}
	if posix.bind(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK {
		posix.close(fd)
		return -1, false
	}
	if posix.listen(fd, 16) != .OK {
		posix.close(fd)
		posix.unlink(cstring(raw_data(path)))
		return -1, false
	}
	return fd, true
}

connect_unix :: proc(path: string) -> (posix.FD, bool) {
	addr, ok := make_addr(path)
	if !ok {
		return -1, false
	}
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {
		return -1, false
	}
	if posix.connect(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK {
		posix.close(fd)
		return -1, false
	}
	return fd, true
}

remove_unix :: proc(path: string) {
	buf: [256]u8
	if len(path) >= len(buf) {
		return
	}
	copy(buf[:], path)
	posix.unlink(cstring(raw_data(buf[:len(path)+1])))
}

write_all :: proc(fd: posix.FD, data: string) -> bool {
	sent := 0
	for sent < len(data) {
		remaining := len(data) - sent
		n := posix.send(fd, rawptr(raw_data(data[sent:])), c.size_t(remaining), {})
		if n <= 0 {
			return false
		}
		sent += int(n)
	}
	return true
}

// Line_Reader buffers a stream so a read split inside a line and
// several lines in one read are both handled.
Line_Reader :: struct {
	fd:    posix.FD,
	buf:   [4096]u8,
	start: int,
	end:   int,
}

// read_line returns one line without its newline, or ok=false at
// EOF/error. A final unterminated line at EOF is still returned.
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
				if len(s) > 0 && s[len(s)-1] == '\r' {
					s = s[:len(s)-1]
				}
				return s, true
			}
			r.start = r.end
		}
		n := posix.recv(r.fd, rawptr(&r.buf), c.size_t(len(r.buf)), {})
		if n < 0 {
			strings.builder_destroy(&b)
			return "", false
		}
		if n == 0 {
			if len(strings.to_string(b)) == 0 {
				strings.builder_destroy(&b)
				return "", false
			}
			return strings.to_string(b), true
		}
		r.start = 0
		r.end = int(n)
	}
}
