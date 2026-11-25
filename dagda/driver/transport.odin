package driver

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

listen_unix :: proc(path: string) -> (posix.FD, Endpoint_Identity, bool) {
	addr, ok := make_addr(path)
	if !ok {
		return -1, {}, false
	}
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {
		return -1, {}, false
	}
	if posix.bind(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK {
		posix.close(fd)
		return -1, {}, false
	}
	identity := endpoint_identity(path)
	if posix.listen(fd, 16) != .OK {
		posix.close(fd)
		remove_unix_owned(path, identity)
		return -1, {}, false
	}
	return fd, identity, true
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

write_all :: proc(fd: posix.FD, data: string) -> bool {
	sent := 0
	for sent < len(data) {
		remaining := len(data) - sent
		n := posix.send(fd, rawptr(raw_data(data[sent:])), c.size_t(remaining), {.NOSIGNAL})
		if n <= 0 {
			return false
		}
		sent += int(n)
	}
	return true
}

Line_Reader :: struct {
	fd:    posix.FD,
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
		n := posix.recv(r.fd, rawptr(&r.buf), c.size_t(len(r.buf)), {})
		if n <= 0 {
			strings.builder_destroy(&b)
			return "", false
		}
		r.start = 0
		r.end = int(n)
	}
}
