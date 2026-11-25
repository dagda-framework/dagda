package sdlhost

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "dagda:dagda"
import "dagda:dagda/driver"
import sdl "vendor:sdl3"

View_Proc :: #type proc(user_data: rawptr) -> dagda.View
Canvas_Proc :: #type proc(user_data: rawptr) -> dagda.Canvas

// App describes a native Dagda application hosted in an SDL3 window.
// Supply either view (flow layout) or canvas (fixed-aspect canvas layout).
App :: struct {
	title:      string,
	width:      i32,
	height:     i32,
	user_data:  rawptr,
	view:       View_Proc,
	canvas:     Canvas_Proc,
	handle:     dagda.Action_Handler,
	on_pointer: Pointer_Handler,
	// Optional advertised-edit source for the --socket endpoint.
	// When its handler is set, edits / preview / commit requests
	// dispatch through it; when omitted, the endpoint keeps its
	// existing inspect / invoke behavior only. The app owns its
	// revisions, mutation policy, and undo history.
	edits: driver.Edit_Source,
	// Optional Ctrl+Z undo hook, called on the host thread. It
	// returns true when the app actually undid something.
	on_undo: proc(user_data: rawptr) -> bool,
}

Run_Options :: struct {
	socket_path:   string,
	control_stdin: bool,
	width:         i32,
	height:        i32,
}

parse_size_arg :: proc(s: string) -> (w: i32, h: i32, ok: bool) {
	x := strings.index_byte(s, 'x')
	if x <= 0 || x + 1 >= len(s) {
		return 0, 0, false
	}
	wv, ok_w := strconv.parse_int(s[:x])
	hv, ok_h := strconv.parse_int(s[x + 1:])
	if !ok_w || !ok_h || wv <= 0 || hv <= 0 {
		return 0, 0, false
	}
	return i32(wv), i32(hv), true
}

parse_cli_args :: proc(args: []string) -> (opts: Run_Options, ok: bool) {
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		if arg == "--socket" && i + 1 < len(args) {
			i += 1
			opts.socket_path = args[i]
		} else if arg == "--size" && i + 1 < len(args) {
			i += 1
			w, h, ok_size := parse_size_arg(args[i])
			if !ok_size {
				return {}, false
			}
			opts.width = w
			opts.height = h
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
	has_hovered:  bool,
	hovered_id:   dagda.Object_Id,
	has_pressed:  bool,
	pressed_id:   dagda.Object_Id,
	pointer:      Pointer_State,
	focus:        Focus_State,
	needs_redraw: bool,
}

host_rebuild_frame :: proc(h: ^Host) -> bool {
	w, height: c.int
	sdl.GetWindowSize(h.window, &w, &height)
	h.viewport = {width = f32(w), height = f32(height)}
	// Release the previous frame before rebuilding the app view/canvas so no
	// frame outlives borrowed label/role storage.
	dagda.frame_destroy(&h.frame)
	frame: dagda.Frame
	ok: bool
	if h.app.canvas != nil {
		frame, ok = dagda.resolve_canvas(h.app.canvas(h.app.user_data), h.viewport)
	} else {
		frame, ok = dagda.resolve(h.app.view(h.app.user_data), h.viewport)
	}
	if !ok {
		fmt.eprintln("dagda.resolve failed")
		return false
	}
	h.frame = frame
	_ = focus_reconcile(&h.focus, h.frame)
	h.needs_redraw = true
	return true
}

host_rebuild_cb :: proc(ctx: rawptr) -> bool {
	return host_rebuild_frame((^Host)(ctx))
}

// canvas_clip_rect returns the exact integer pixel clip rectangle whose pixel
// centers (x + 0.5, y + 0.5) lie inside the half-open fitted canvas range
// [fitted.x, fitted.x + fitted.w) x [fitted.y, fitted.y + fitted.h).
canvas_clip_rect :: proc(fitted: sdl.FRect) -> sdl.Rect {
	x0 := c.int(math.ceil(fitted.x - 0.5))
	y0 := c.int(math.ceil(fitted.y - 0.5))
	x1 := c.int(math.ceil(fitted.x + fitted.w - 0.5))
	y1 := c.int(math.ceil(fitted.y + fitted.h - 0.5))
	return sdl.Rect{
		x = x0,
		y = y0,
		w = max(x1 - x0, 0),
		h = max(y1 - y0, 0),
	}
}

host_draw :: proc(h: ^Host) {
	r := h.renderer
	if h.frame.has_canvas {
		// Distinct dark letterbox background outside the fitted canvas.
		sdl.SetRenderDrawColor(r, 14, 16, 22, 255)
		sdl.RenderClear(r)

		t := h.frame.transform
		fitted := sdl.FRect{
			x = t.offset.x,
			y = t.offset.y,
			w = t.canvas.width * t.scale,
			h = t.canvas.height * t.scale,
		}
		// Clip canvas sheet and element painting to the exact pixel rows/columns
		// whose centers lie inside the fitted canvas, matching dagda.hit_test.
		clip := canvas_clip_rect(fitted)
		sdl.SetRenderClipRect(r, &clip)
		if clip.w > 0 && clip.h > 0 {
			sheet := sdl.FRect{
				x = f32(clip.x),
				y = f32(clip.y),
				w = f32(clip.w),
				h = f32(clip.h),
			}
			sdl.SetRenderDrawColor(r, 26, 31, 42, 255)
			sdl.RenderFillRect(r, &sheet)
		}
	} else {
		sdl.SetRenderDrawColor(r, 22, 25, 32, 255)
		sdl.RenderClear(r)
	}

	text_scale: f32 = h.frame.has_canvas ? clamp(h.frame.transform.scale, 0.4, 2.0) : 1.0

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

			px := max(24 * text_scale, 12)
			tw := font_measure_width(&h.font, el.text, px)
			tx := rect.x + max((rect.w - tw) * 0.5, 12)
			ty := rect.y + (rect.h - px) * 0.5
			font_draw_text(&h.font, r, el.text, tx, ty, px, sdl.Color{240, 244, 250, 255})

		case .Button:
			is_pressed := (h.has_pressed && h.pressed_id == el.info.id) ||
			              (h.focus.has_space_pending && h.focus.space_pending_id == el.info.id)
			is_hovered := h.has_hovered && h.hovered_id == el.info.id
			if is_pressed {
				sdl.SetRenderDrawColor(r, 46, 98, 178, 255)
			} else if is_hovered {
				sdl.SetRenderDrawColor(r, 64, 124, 214, 255)
			} else {
				sdl.SetRenderDrawColor(r, 52, 108, 194, 255)
			}
			sdl.RenderFillRect(r, &rect)
			sdl.SetRenderDrawColor(r, 118, 176, 255, 255)
			sdl.RenderRect(r, &rect)

			px := max(18 * text_scale, 11)
			tw := font_measure_width(&h.font, el.text, px)
			tx := rect.x + max((rect.w - tw) * 0.5, 12)
			ty := rect.y + (rect.h - px) * 0.5
			font_draw_text(&h.font, r, el.text, tx, ty, px, sdl.Color{248, 250, 255, 255})
		}

		// Visible focus ring around the keyboard-focused element.
		if h.focus.has_focus && h.focus.focused_id == el.info.id {
			sdl.SetRenderDrawColor(r, 255, 206, 84, 255)
			ring1 := sdl.FRect{x = rect.x - 3, y = rect.y - 3, w = rect.w + 6, h = rect.h + 6}
			ring2 := sdl.FRect{x = rect.x - 2, y = rect.y - 2, w = rect.w + 4, h = rect.h + 4}
			sdl.RenderRect(r, &ring1)
			sdl.RenderRect(r, &ring2)
		}
	}

	if h.frame.has_canvas {
		sdl.SetRenderClipRect(r, nil)
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

push_sdl_button :: proc(window: ^sdl.Window, x, y: f32, down: bool) -> bool {
	win_id := sdl.GetWindowID(window)
	ev: sdl.Event
	ev.type = down ? .MOUSE_BUTTON_DOWN : .MOUSE_BUTTON_UP
	ev.button.windowID = win_id
	ev.button.button = sdl.BUTTON_LEFT
	ev.button.down = down
	ev.button.clicks = 1
	ev.button.x = x
	ev.button.y = y
	return sdl.PushEvent(&ev)
}

// push_sdl_click injects a real mouse button down + up pair into SDL3's event
// queue so automated tests exercise the exact SDL pointer input path.
push_sdl_click :: proc(window: ^sdl.Window, x, y: f32) -> bool {
	if !push_sdl_button(window, x, y, true) {
		return false
	}
	return push_sdl_button(window, x, y, false)
}

push_sdl_hover :: proc(window: ^sdl.Window, x, y: f32) -> bool {
	win_id := sdl.GetWindowID(window)
	motion: sdl.Event
	motion.type = .MOUSE_MOTION
	motion.motion.windowID = win_id
	motion.motion.x = x
	motion.motion.y = y
	return sdl.PushEvent(&motion)
}

push_sdl_key :: proc(window: ^sdl.Window, name: string) -> bool {
	win_id := sdl.GetWindowID(window)
	key: sdl.Keycode
	mod: sdl.Keymod
	repeat_key := false
	switch name {
	case "tab":
		key = sdl.K_TAB
	case "shift+tab":
		key = sdl.K_TAB
		mod = sdl.KMOD_LSHIFT
	case "enter":
		key = sdl.K_RETURN
	case "space":
		key = sdl.K_SPACE
	case "escape":
		key = sdl.K_ESCAPE
	case "ctrl+z":
		key = sdl.K_Z
		mod = sdl.KMOD_LCTRL
	case "ctrl+shift+z":
		key = sdl.K_Z
		mod = sdl.KMOD_LCTRL | sdl.KMOD_LSHIFT
	case "ctrl+z+repeat":
		key = sdl.K_Z
		mod = sdl.KMOD_LCTRL
		repeat_key = true
	case:
		return false
	}

	down: sdl.Event
	down.type = .KEY_DOWN
	down.key.windowID = win_id
	down.key.key = key
	down.key.mod = mod
	down.key.down = true
	down.key.repeat = repeat_key
	if !sdl.PushEvent(&down) {
		return false
	}

	up: sdl.Event
	up.type = .KEY_UP
	up.key.windowID = win_id
	up.key.key = key
	up.key.mod = mod
	up.key.down = false
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
		} else if strings.has_prefix(line, "hover ") || strings.has_prefix(line, "move ") {
			is_move := strings.has_prefix(line, "move ")
			rest := is_move ? line[len("move "):] : line[len("hover "):]
			sp := strings.index_byte(rest, ' ')
			if sp >= 0 {
				x, ok_x := strconv.parse_f32(rest[:sp])
				y, ok_y := strconv.parse_f32(rest[sp + 1:])
				if ok_x && ok_y && push_sdl_hover(h.window, x, y) {
					fmt.printf("CONTROL_OK %s %.2f %.2f\n", is_move ? "move" : "hover", x, y)
					_ = os.flush(os.stdout)
				} else {
					fmt.println("CONTROL_ERR invalid move")
					_ = os.flush(os.stdout)
				}
			}
		} else if strings.has_prefix(line, "down ") {
			rest := line[len("down "):]
			sp := strings.index_byte(rest, ' ')
			if sp >= 0 {
				x, ok_x := strconv.parse_f32(rest[:sp])
				y, ok_y := strconv.parse_f32(rest[sp + 1:])
				if ok_x && ok_y && push_sdl_button(h.window, x, y, true) {
					fmt.printf("CONTROL_OK down %.2f %.2f\n", x, y)
					_ = os.flush(os.stdout)
				} else {
					fmt.println("CONTROL_ERR invalid down")
					_ = os.flush(os.stdout)
				}
			}
		} else if strings.has_prefix(line, "up ") {
			rest := line[len("up "):]
			sp := strings.index_byte(rest, ' ')
			if sp >= 0 {
				x, ok_x := strconv.parse_f32(rest[:sp])
				y, ok_y := strconv.parse_f32(rest[sp + 1:])
				if ok_x && ok_y && push_sdl_button(h.window, x, y, false) {
					fmt.printf("CONTROL_OK up %.2f %.2f\n", x, y)
					_ = os.flush(os.stdout)
				} else {
					fmt.println("CONTROL_ERR invalid up")
					_ = os.flush(os.stdout)
				}
			}
		} else if strings.has_prefix(line, "key ") {
			name := line[len("key "):]
			if push_sdl_key(h.window, name) {
				fmt.printf("CONTROL_OK key %s\n", name)
				_ = os.flush(os.stdout)
			} else {
				fmt.printf("CONTROL_ERR invalid key %s\n", name)
				_ = os.flush(os.stdout)
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

host_clear_pressed_on_cancel :: proc(h: ^Host) {
	if h.has_pressed {
		h.has_pressed = false
		h.pressed_id = 0
	}
	h.needs_redraw = true
}

host_handle_pointer_cancel_event :: proc(h: ^Host, ev: ^sdl.Event) -> (res: Pointer_Result) {
	res = pointer_handle_event(&h.pointer, h.frame, ev, h.app.on_pointer, h.app.user_data)
	if res.cancelled {
		host_clear_pressed_on_cancel(h)
	}
	return res
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
	w := opts.width > 0 ? c.int(opts.width) : (app.width > 0 ? c.int(app.width) : 360)
	ht := opts.height > 0 ? c.int(opts.height) : (app.height > 0 ? c.int(app.height) : 180)
	if !sdl.CreateWindowAndRenderer(title_cstr, w, ht, {.RESIZABLE}, &h.window, &h.renderer) {
		fmt.eprintf("SDL_CreateWindowAndRenderer failed: %s\n", sdl.GetError())
		return 1
	}
	defer sdl.DestroyWindow(h.window)
	defer sdl.DestroyRenderer(h.renderer)
	// Release cached glyph textures before DestroyRenderer frees the renderer.
	defer font_destroy_textures(&h.font)
	defer dagda.frame_destroy(&h.frame)

	if !host_rebuild_frame(&h) {
		return 1
	}
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
				if ev.type == .KEY_DOWN && !ev.key.repeat && ev.key.key == sdl.K_Z && (ev.key.mod & sdl.KMOD_CTRL) != {} && (ev.key.mod & (sdl.KMOD_SHIFT | sdl.KMOD_ALT)) == {} && h.app.on_undo != nil {
					if h.app.on_undo(h.app.user_data) {
						if !host_rebuild_frame(&h) {
							exit_code = 1
							running = false
						}
					}
					if !running || !sdl.PollEvent(&ev) {
						break
					}
					continue
				}
				#partial switch ev.type {
				case .QUIT, .WINDOW_CLOSE_REQUESTED:
					running = false
				case .WINDOW_EXPOSED, .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED:
					if !host_rebuild_frame(&h) {
						exit_code = 1
						running = false
					}
				case .MOUSE_MOTION:
					pres := pointer_handle_event(&h.pointer, h.frame, &ev, h.app.on_pointer, h.app.user_data)
					if pres.changed {
						if !host_rebuild_frame(&h) {
							exit_code = 1
							running = false
						}
					}
					if running && !pres.consumed {
						id, hit := dagda.hit_test(h.frame, {x = ev.motion.x, y = ev.motion.y})
						if hit != h.has_hovered || (hit && id != h.hovered_id) {
							h.has_hovered = hit
							h.hovered_id = hit ? id : 0
							h.needs_redraw = true
						}
					}
				case .MOUSE_BUTTON_DOWN:
					if ev.button.button == sdl.BUTTON_LEFT {
						id, hit := dagda.hit_test(h.frame, {x = ev.button.x, y = ev.button.y})
						h.has_pressed = hit
						h.pressed_id = hit ? id : 0
						pres := pointer_handle_event(&h.pointer, h.frame, &ev, h.app.on_pointer, h.app.user_data)
						if pres.changed {
							if !host_rebuild_frame(&h) {
								exit_code = 1
								running = false
							}
						}
						if running && !pres.suppress_click {
							if dagda.click(h.frame, {x = ev.button.x, y = ev.button.y}, h.app.handle, h.app.user_data) == .Applied {
								if !host_rebuild_frame(&h) {
									exit_code = 1
									running = false
								}
							} else {
								h.needs_redraw = true
							}
						} else if running && !pres.changed {
							h.needs_redraw = true
						}
					} else if ev.button.button == sdl.BUTTON_RIGHT && h.pointer.active {
						pres := host_handle_pointer_cancel_event(&h, &ev)
						if pres.changed {
							if !host_rebuild_frame(&h) {
								exit_code = 1
								running = false
							}
						}
					}
				case .MOUSE_BUTTON_UP:
					if ev.button.button == sdl.BUTTON_LEFT {
						pres := pointer_handle_event(&h.pointer, h.frame, &ev, h.app.on_pointer, h.app.user_data)
						if h.has_pressed {
							h.has_pressed = false
							h.pressed_id = 0
							h.needs_redraw = true
						}
						if pres.changed {
							if !host_rebuild_frame(&h) {
								exit_code = 1
								running = false
							}
						}
						if running && pres.consumed && !pres.suppress_click && pres.has_click_id {
							if pointer_try_activate(
								h.frame,
								{x = ev.button.x, y = ev.button.y},
								pres.click_target_id,
								h.app.handle,
								h.app.user_data,
							) {
								if !host_rebuild_frame(&h) {
									exit_code = 1
									running = false
								}
							}
						}
					}
				case .KEY_DOWN, .KEY_UP, .WINDOW_FOCUS_LOST:
					pres := host_handle_pointer_cancel_event(&h, &ev)
					if pres.changed {
						if !host_rebuild_frame(&h) {
							exit_code = 1
							running = false
						}
					}
					if running && !pres.consumed {
						applied, redraw := focus_handle_event(&h.focus, h.frame, &ev, h.app.handle, h.app.user_data)
						if redraw {
							h.needs_redraw = true
						}
						if applied {
							if !host_rebuild_frame(&h) {
								exit_code = 1
								running = false
							}
						}
					}
				}
				if !running || !sdl.PollEvent(&ev) {
					break
				}
			}
		}

		if running && srv.active {
			applied, rebuild_failed: bool
			if h.app.edits.handler != nil {
				applied, rebuild_failed = driver.server_poll_edits(&srv, &h.frame, h.app.handle, h.app.user_data, h.app.edits, &h, host_rebuild_cb)
			} else {
				applied, rebuild_failed = driver.server_poll(&srv, &h.frame, h.app.handle, h.app.user_data, &h, host_rebuild_cb)
			}
			if rebuild_failed {
				exit_code = 1
				running = false
			} else if applied {
				h.needs_redraw = true
			}
		}
		if running && opts.control_stdin {
			poll_control_stdin(&h, &control_buf, &running, &exit_code)
		}

		if running && h.needs_redraw {
			_ = host_render(&h)
		}
	}

	return exit_code
}
