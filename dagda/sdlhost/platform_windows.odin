#+build windows
package sdlhost

import win "core:sys/windows"

@(private = "file")
on_console_ctrl :: proc "system" (ctrl_type: win.DWORD) -> win.BOOL {
	switch ctrl_type {
	case win.CTRL_C_EVENT, win.CTRL_BREAK_EVENT, win.CTRL_CLOSE_EVENT:
		signal_stopped = true
		return true
	}
	return false
}

platform_install_signals :: proc() {
	_ = win.SetConsoleCtrlHandler(on_console_ctrl, true)
}

platform_read_stdin_nonblocking :: proc(buf: []u8) -> int {
	if len(buf) == 0 {
		return 0
	}
	stdin := win.GetStdHandle(win.STD_INPUT_HANDLE)
	if stdin == nil || stdin == win.INVALID_HANDLE_VALUE {
		return 0
	}
	avail: win.DWORD = 0
	if !win.PeekNamedPipe(stdin, nil, 0, nil, &avail, nil) || avail == 0 {
		return 0
	}
	to_read := min(win.DWORD(len(buf)), avail)
	read_bytes: win.DWORD = 0
	if !win.ReadFile(stdin, raw_data(buf), to_read, &read_bytes, nil) || read_bytes == 0 {
		return 0
	}
	return int(read_bytes)
}
