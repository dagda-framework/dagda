package sdlhost

import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "dagda:dagda"
import "dagda:dagda/driver"
import sdl "vendor:sdl3"

View_Proc :: #type proc(user_data: rawptr) -> dagda.View

// App describes a native Dagda application hosted in an SDL3 window.
App :: struct {
	title:     string,
	width:     i32,
	height:    i32,
	user_data: rawptr,
	view:      View_Proc,
	handle:    dagda.Action_Handler,
}

Run_Options :: struct {
	socket_path:   string,
	control_stdin: bool,
}

parse_cli_args :: proc(args: []string) -> (opts: Run_Options, ok: bool) {
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		if arg == "--socket" && i + 1 < len(args) {
			i += 1
			opts.socket_path = args[i]
		} else if arg == "--control-stdin" {
			opts.control_stdin = true
		} else {
			return {}, false
		}
	}
	return opts, true
}

signal_stopped: bool

on_signal :: proc "c" (_: posix.Signal) {
	signal_stopped = true
}

Host :: struct {
	app:          App,
	window:       ^sdl.Window,
	renderer:     ^sdl.Renderer,
	font:         Font,
	frame:        dagda.Frame,
	viewport:     dagda.Size,
	hovered_id:   dagda.Object_Id,
	pressed_id:   dagda.Object_Id,
	needs_redraw: bool,
}

host_rebuild_frame :: proc(h: ^Host) {
	w, height: c.int
	sdl.GetWindowSize(h.window, &w, &height)
	h.viewport = {width = f32(w), height = f32(height)}
	dagda.frame_destroy(&h.frame)
	h.frame, _ = dagda.resolve(h.app.view(h.app.user_data), h.viewport)
	h.needs_redraw = true
}

host_rebuild_cb :: proc(ctx: rawptr) {
	host_rebuild_frame((^Host)(ctx))
}

host_draw :: proc(h: ^Host) {
	r := h.renderer
	sdl.SetRenderDrawColor(r, 22, 25, 32, 255)
	sdl.RenderClear(r)

	for el in h.frame.elements {
		rect := sdl.FRect{
			x = el.bounds.x,
			y = el.bounds.y,
			w = el.bounds.width,
			h = el.bounds.height,
		}
		switch el.kind {
		case .Label:
			sdl.SetRenderDrawColor(r, 31, 36, 47, 255)
			sdl.RenderFillRect(r, &rect)
			sdl.SetRenderDrawColor(r, 56, 65, 84, 255)
			sdl.RenderRect(r, &rect)

			px: f32 = 24
			tw := font_measure_width(&h.font, el.text, px)
			tx := rect.x + max((rect.w - tw) * 0.5, 12)
			ty := rect.y + (rect.h - px) * 0.5
			font_draw_text(&h.font, r, el.text, tx, ty, px, sdl.Color{240, 244, 250, 255})

		case .Button:
			if h.pressed_id == el.info.id {
				sdl.SetRenderDrawColor(r, 46, 98, 178, 255)
			} else if h.hovered_id == el.info.id {
				sdl.SetRenderDrawColor(r, 64, 124, 214, 255)
			} else {
				sdl.SetRenderDrawColor(r, 52, 108, 194, 255)
			}
			sdl.RenderFillRect(r, &rect)
			sdl.SetRenderDrawColor(r, 118, 176, 255, 255)
			sdl.RenderRect(r, &rect)

			px: f32 = 18
			tw := font_measure_width(&h.font, el.text, px)
			tx := rect.x + max((rect.w - tw) * 0.5, 12)
			ty := rect.y + (rect.h - px) * 0.5
			font_draw_text(&h.font, r, el.text, tx, ty, px, sdl.Color{248, 250, 255, 255})
		}
	}
}

host_save_screenshot :: proc(h: ^Host, path: string) -> bool {
	surface := sdl.RenderReadPixels(h.renderer, nil)
	if surface == nil {
		fmt.eprintf("SDL_RenderReadPixels failed: %s\n", sdl.GetError())
		return false
	}
	defer sdl.DestroySurface(surface)
	cpath := strings.clone_to_cstring(path)
	defer delete(cpath)
	if !sdl.SavePNG(surface, cpath) {
		fmt.eprintf("SDL_SavePNG(%q) failed: %s\n", path, sdl.GetError())
		return false
	}
	return true
}

host_render :: proc(h: ^Host, screenshot_path := "") -> bool {
	host_draw(h)
	ok := true
	if len(screenshot_path) > 0 {
		ok = host_save_screenshot(h, screenshot_path)
	}
	sdl.RenderPresent(h.renderer)
	h.needs_redraw = false
	return ok
}

// push_sdl_click injects a real mouse button down + up pair into SDL3's event
// queue so automated tests exercise the exact SDL pointer input path.
push_sdl_click :: proc(window: ^sdl.Window, x, y: f32) -> bool {
	win_id := sdl.GetWindowID(window)
	down: sdl.Event
	down.type = .MOUSE_BUTTON_DOWN
	down.button.windowID = win_id
	down.button.button = sdl.BUTTON_LEFT
	down.button.down = true
	down.button.clicks = 1
	down.button.x = x
	down.button.y = y
	if !sdl.PushEvent(&down) {
		return false
	}

	up: sdl.Event
	up.type = .MOUSE_BUTTON_UP
	up.button.windowID = win_id
	up.button.button = sdl.BUTTON_LEFT
	up.button.down = false
	up.button.clicks = 1
	up.button.x = x
	up.button.y = y
	return sdl.PushEvent(&up)
}

poll_control_stdin :: proc(
	h: ^Host,
	in_buf: ^[dynamic]u8,
	running: ^bool,
	exit_code: ^int,
) {
	pfd := posix.pollfd{fd = posix.STDIN_FILENO, events = {.IN}}
	if posix.poll(&pfd, 1, 0) <= 0 || .IN not_in pfd.revents {
		return
	}
	tmp: [1024]u8
	n := posix.read(posix.STDIN_FILENO, raw_data(tmp[:]), c.size_t(len(tmp)))
	if n <= 0 {
		return
	}
	append(in_buf, ..tmp[:int(n)])

	for {
		nl := -1
		for j in 0 ..< len(in_buf^) {
			if in_buf^[j] == '\n' {
				nl = j
				break
			}
		}
		if nl < 0 {
			break
		}
		line_end := nl
		if line_end > 0 && in_buf^[line_end - 1] == '\r' {
			line_end -= 1
		}
		line := strings.clone(string(in_buf^[:line_end]))
		defer delete(line)

		remaining := len(in_buf^) - (nl + 1)
		if remaining > 0 {
			copy(in_buf^[:remaining], in_buf^[nl + 1:])
		}
		resize(in_buf, remaining)

		if strings.has_prefix(line, "click ") {
			rest := line[len("click "):]
			sp := strings.index_byte(rest, ' ')
			if sp >= 0 {
				x, ok_x := strconv.parse_f32(rest[:sp])
				y, ok_y := strconv.parse_f32(rest[sp + 1:])
				if ok_x && ok_y && push_sdl_click(h.window, x, y) {
					fmt.printf("CONTROL_OK click %.2f %.2f\n", x, y)
					_ = os.flush(os.stdout)
				} else {
					fmt.println("CONTROL_ERR invalid click")
					_ = os.flush(os.stdout)
				}
			}
		} else if strings.has_prefix(line, "screenshot ") {
			path := line[len("screenshot "):]
			if !host_render(h, path) {
				fmt.printf("CONTROL_ERR screenshot failed: %s\n", path)
				_ = os.flush(os.stdout)
				exit_code^ = 1
				running^ = false
				break
			}
			fmt.printf("CONTROL_OK screenshot=%s\n", path)
			_ = os.flush(os.stdout)
		} else if line == "quit" {
			fmt.println("CONTROL_OK quit")
			_ = os.flush(os.stdout)
			running^ = false
			break
		}
	}
}

run :: proc(app: App, opts: Run_Options = {}) -> int {
	signal_stopped = false
	act: posix.sigaction_t
	act.sa_handler = on_signal
	posix.sigaction(.SIGINT, &act, nil)
	posix.sigaction(.SIGTERM, &act, nil)
	ignore: posix.sigaction_t
	ignore.sa_handler = transmute(proc "c" (posix.Signal))posix.SIG_IGN
	posix.sigaction(.SIGPIPE, &ignore, nil)

	h: Host
	h.app = app
	if !font_init(&h.font) {
		return 1
	}
	defer font_destroy(&h.font)

	if !sdl.Init({.VIDEO}) {
		fmt.eprintf("SDL_Init failed: %s\n", sdl.GetError())
		return 1
	}
	defer sdl.Quit()

	title_cstr := strings.clone_to_cstring(len(app.title) > 0 ? app.title : "Dagda")
	defer delete(title_cstr)
	w := app.width > 0 ? c.int(app.width) : 360
	ht := app.height > 0 ? c.int(app.height) : 180
	if !sdl.CreateWindowAndRenderer(title_cstr, w, ht, {.RESIZABLE}, &h.window, &h.renderer) {
		fmt.eprintf("SDL_CreateWindowAndRenderer failed: %s\n", sdl.GetError())
		return 1
	}
	defer sdl.DestroyWindow(h.window)
	defer sdl.DestroyRenderer(h.renderer)
	defer dagda.frame_destroy(&h.frame)

	host_rebuild_frame(&h)
	_ = host_render(&h)

	srv: driver.Server
	if len(opts.socket_path) > 0 {
		if !driver.server_start(&srv, opts.socket_path) {
			return 1
		}
	}
	defer driver.server_stop(&srv)

	control_buf: [dynamic]u8
	defer delete(control_buf)

	running := true
	exit_code := 0
	wait_ms: c.int = (srv.active || opts.control_stdin) ? 16 : 100

	for running && !signal_stopped {
		ev: sdl.Event
		if sdl.WaitEventTimeout(&ev, wait_ms) {
			for {
				#partial switch ev.type {
				case .QUIT, .WINDOW_CLOSE_REQUESTED:
					running = false
				case .WINDOW_EXPOSED, .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED:
					host_rebuild_frame(&h)
				case .MOUSE_MOTION:
					id, hit := dagda.hit_test(h.frame, {x = ev.motion.x, y = ev.motion.y})
					next_hover := hit ? id : 0
					if next_hover != h.hovered_id {
						h.hovered_id = next_hover
						h.needs_redraw = true
					}
				case .MOUSE_BUTTON_DOWN:
					if ev.button.button == sdl.BUTTON_LEFT {
						id, hit := dagda.hit_test(h.frame, {x = ev.button.x, y = ev.button.y})
						h.pressed_id = hit ? id : 0
						if dagda.click(h.frame, {x = ev.button.x, y = ev.button.y}, h.app.handle, h.app.user_data) == .Applied {
							host_rebuild_frame(&h)
						} else {
							h.needs_redraw = true
						}
					}
				case .MOUSE_BUTTON_UP:
					if ev.button.button == sdl.BUTTON_LEFT && h.pressed_id != 0 {
						h.pressed_id = 0
						h.needs_redraw = true
					}
				}
				if !running || !sdl.PollEvent(&ev) {
					break
				}
			}
		}

		if srv.active {
			if driver.server_poll(&srv, &h.frame, h.app.handle, h.app.user_data, &h, host_rebuild_cb) {
				h.needs_redraw = true
			}
		}
		if opts.control_stdin {
			poll_control_stdin(&h, &control_buf, &running, &exit_code)
		}

		if h.needs_redraw {
			_ = host_render(&h)
		}
	}

	return exit_code
}
