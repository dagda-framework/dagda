#+build !windows
package sdlhost

import "core:c"
import "core:sys/posix"

@(private = "file")
on_signal :: proc "c" (_: posix.Signal) {
	signal_stopped = true
}

platform_install_signals :: proc() {
	act: posix.sigaction_t
	act.sa_handler = on_signal
	posix.sigaction(.SIGINT, &act, nil)
	posix.sigaction(.SIGTERM, &act, nil)
	ignore: posix.sigaction_t
	ignore.sa_handler = transmute(proc "c" (posix.Signal))posix.SIG_IGN
	posix.sigaction(.SIGPIPE, &ignore, nil)
}

platform_read_stdin_nonblocking :: proc(buf: []u8) -> int {
	pfd := posix.pollfd{fd = posix.STDIN_FILENO, events = {.IN}}
	if posix.poll(&pfd, 1, 0) <= 0 || .IN not_in pfd.revents {
		return 0
	}
	n := posix.read(posix.STDIN_FILENO, raw_data(buf), c.size_t(len(buf)))
	if n <= 0 {
		return 0
	}
	return int(n)
}
