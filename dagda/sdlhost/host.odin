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
	//
	// Slice-borrowing contract (also for editable_text_targets):
	// run takes App by value and copies the slice descriptors
	// (base address and length) supplied at startup, while
	// borrowing the backing arrays themselves — the caller
	// keeps each backing array valid until run returns, and
	// referenced strings must remain valid while used,
	// including the strings the declarations in edits.edits
	// reference. Refresh existing entries in the
	// host-thread view or canvas builder before returning the
	// matching elements; the host thread is the only writer of
	// the arrays. Reassigning or reslicing the caller's own copy
	// after startup does not update the host's descriptor, and
	// only slots within the supplied length are ever visible.
	// Object ID 0 is a valid ID in both lists. Workers publish
	// synchronized model state and request a rebuild; that
	// request is asynchronous, and after a successful rebuild
	// focus reconciliation plus later input and driver dispatch
	// see the refreshed entries. When a target's identity, edit
	// eligibility, and committed text stay the same across a
	// rebuild, its focused text session (caret, selection, and
	// any active preedit) is preserved.
	edits: driver.Edit_Source,
	// Optional Ctrl+Z undo hook, called on the host thread. It
	// returns true when the app actually undid something.
	on_undo:               proc(user_data: rawptr) -> bool,
	text_edit:             Editable_Text_Config,
	// Optional list of editable element IDs when multiple distinct single-line
	// elements share text_edit; when empty, text_edit.target_id is used.
	// Borrowed as described on edits above: pass the slice once,
	// keep its backing array valid until run returns, and refresh
	// entries only from the host-thread builder. Discovery of an
	// element by role (inspect) is separate from discovery of
	// its advertised edits (the edits operation, which also
	// requires the app to recognize the ID in revision_of).
	editable_text_targets: []dagda.Object_Id,
	// Called on the host thread with the visual field ID (which may be zero).
	// true marks the first active preedit. Updates keep the same start. false
	// closes it on cancellation, focus loss, field removal, or shutdown.
	// On commit, the callback runs after on_commit returns and only if the
	// composition has ended. A rejected edit can keep composing and retry.
	on_composition: proc(user_data: rawptr, field_id: dagda.Object_Id, composing: bool),
	// Optional out-storage for this window's rebuild handle.
	// The host fills it before on_ready and before the event
	// loop; copy the value to a worker if needed. It stops
	// waking anything once this window closes.
	rebuild_handle: ^Rebuild_Handle,
	// Optional callback invoked on the host thread once the
	// window is live and its rebuild handle is available.
	on_ready: proc(user_data: rawptr, handle: Rebuild_Handle),
	// Optional callback invoked on the host thread after each
	// successful presentation of a frame.
	on_present: proc(user_data: rawptr),
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
	app:           App,
	window:        ^sdl.Window,
	ime_window:    ^sdl.Window, // nil under --control-stdin to isolate injected IME tests from native IME
	renderer:      ^sdl.Renderer,
	font:          Font,
	frame:         dagda.Frame,
	viewport:      dagda.Size,
	has_hovered:   bool,
	hovered_id:    dagda.Object_Id,
	has_pressed:   bool,
	pressed_id:    dagda.Object_Id,
	pointer:       Pointer_State,
	focus:         Focus_State,
	text_edit:     Text_Edit_State,
	lshift_held:   bool,
	rshift_held:   bool,
	clipboard:     Clipboard,
	mem_clipboard: Memory_Clipboard,
	edit_cstr_buf: [256]u8,
	text_cstr_buf: [256]u8,
	needs_redraw:  bool,
	rebuild:       Rebuild_Handle,
	reported_composition: Active_Composition,
}

@(private="package")
host_report_composition :: proc(h: ^Host, current: Active_Composition) {
	previous := h.reported_composition
	if previous == current || h.app.on_composition == nil {
		return
	}
	h.reported_composition = current
	if previous.active {
		h.app.on_composition(h.app.user_data, previous.field_id, false)
	}
	if current.active {
		h.app.on_composition(h.app.user_data, current.field_id, true)
	}
}

host_rebuild_frame :: proc(h: ^Host) -> bool {
	if h.window != nil {
		w, height: c.int
		sdl.GetWindowSize(h.window, &w, &height)
		h.viewport = {width = f32(w), height = f32(height)}
	}
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
	text_edit_reconcile(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, h.app.editable_text_targets)
	host_report_composition(h, host_active_composition(h))
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
			if text_edit_is_target(h.app.text_edit, h.app.editable_text_targets, el.info.id) {
				text_edit_draw(h, el.info.id, el.bounds, el.text, h.text_edit.focused && h.text_edit.active_id == el.info.id)
			} else {
				px := max(24 * text_scale, 12)
				sdl.SetRenderDrawColor(r, 31, 36, 47, 255)
				sdl.RenderFillRect(r, &rect)
				sdl.SetRenderDrawColor(r, 56, 65, 84, 255)
				sdl.RenderRect(r, &rect)

				tw := font_measure_width(&h.font, el.text, px)
				tx := rect.x + max((rect.w - tw) * 0.5, 12)
				ty := rect.y + (rect.h - px) * 0.5
				font_draw_text(&h.font, r, el.text, tx, ty, px, sdl.Color{240, 244, 250, 255})
			}

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

host_present :: proc(h: ^Host) -> bool {
	ok := host_render(h)
	if ok && h.app.on_present != nil {
		h.app.on_present(h.app.user_data)
	}
	return ok
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
	text_edit_update_ime_area(&h.text_edit, h.window, &h.font, h.frame, h.app.text_edit)
	ok := true
	if len(screenshot_path) > 0 {
		ok = host_save_screenshot(h, screenshot_path)
	}
	ok = sdl.RenderPresent(h.renderer) && ok
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

push_sdl_shift_key :: proc(window: ^sdl.Window, down: bool) -> bool {
	ev: sdl.Event
	ev.type = down ? .KEY_DOWN : .KEY_UP
	ev.key.windowID = sdl.GetWindowID(window)
	ev.key.key = sdl.K_LSHIFT
	ev.key.mod = down ? sdl.KMOD_LSHIFT : {}
	ev.key.down = down
	return sdl.PushEvent(&ev)
}

// push_sdl_shift_click injects real SDL Shift key-down, mouse click, and Shift
// key-up events into SDL3's event queue so automated tests exercise the actual
// host modifier and mouse dispatch path.
push_sdl_shift_click :: proc(window: ^sdl.Window, x, y: f32) -> bool {
	if !push_sdl_shift_key(window, true) {
		return false
	}
	if !push_sdl_click(window, x, y) {
		return false
	}
	return push_sdl_shift_key(window, false)
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
	case "left":
		key = sdl.K_LEFT
	case "right":
		key = sdl.K_RIGHT
	case "shift+left":
		key = sdl.K_LEFT
		mod = sdl.KMOD_LSHIFT
	case "shift+right":
		key = sdl.K_RIGHT
		mod = sdl.KMOD_LSHIFT
	case "home":
		key = sdl.K_HOME
	case "end":
		key = sdl.K_END
	case "shift+home":
		key = sdl.K_HOME
		mod = sdl.KMOD_LSHIFT
	case "shift+end":
		key = sdl.K_END
		mod = sdl.KMOD_LSHIFT
	case "backspace":
		key = sdl.K_BACKSPACE
	case "delete":
		key = sdl.K_DELETE
	case "ctrl+a":
		key = sdl.K_A
		mod = sdl.KMOD_LCTRL
	case "ctrl+c":
		key = sdl.K_C
		mod = sdl.KMOD_LCTRL
	case "ctrl+x":
		key = sdl.K_X
		mod = sdl.KMOD_LCTRL
	case "ctrl+x+repeat":
		key = sdl.K_X
		mod = sdl.KMOD_LCTRL
		repeat_key = true
	case "ctrl+v":
		key = sdl.K_V
		mod = sdl.KMOD_LCTRL
	case "ctrl+z":
		key = sdl.K_Z
		mod = sdl.KMOD_LCTRL
	case "ctrl+shift+z":
		key = sdl.K_Z
		mod = sdl.KMOD_LCTRL | sdl.KMOD_LSHIFT
	case "ctrl+super+z":
		key = sdl.K_Z
		mod = sdl.KMOD_LCTRL | sdl.KMOD_LGUI
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

decode_control_escapes :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 1 < len(s) {
			switch s[i + 1] {
			case 'n':
				strings.write_byte(&b, '\n')
				i += 1
				continue
			case 'r':
				strings.write_byte(&b, '\r')
				i += 1
				continue
			case '\\':
				strings.write_byte(&b, '\\')
				i += 1
				continue
			}
		}
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
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
		} else if strings.has_prefix(line, "shift+click ") {
			rest := line[len("shift+click "):]
			sp := strings.index_byte(rest, ' ')
			if sp >= 0 {
				x, ok_x := strconv.parse_f32(rest[:sp])
				y, ok_y := strconv.parse_f32(rest[sp + 1:])
				if ok_x && ok_y && push_sdl_shift_click(h.window, x, y) {
					fmt.printf("CONTROL_OK shift+click %.2f %.2f\n", x, y)
					_ = os.flush(os.stdout)
				} else {
					fmt.println("CONTROL_ERR invalid shift+click")
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
		} else if strings.has_prefix(line, "preedit ") {
			text := line[len("preedit "):]
			if push_sdl_preedit(h, text) {
				fmt.printf("CONTROL_OK preedit %s\n", text)
				_ = os.flush(os.stdout)
			} else {
				fmt.println("CONTROL_ERR preedit failed")
				_ = os.flush(os.stdout)
			}
		} else if strings.has_prefix(line, "clipboard ") {
			decoded := decode_control_escapes(line[len("clipboard "):])
			defer delete(decoded)
			if clipboard_set(h.clipboard, decoded) {
				fmt.println("CONTROL_OK clipboard")
				_ = os.flush(os.stdout)
			} else {
				fmt.println("CONTROL_ERR clipboard failed")
				_ = os.flush(os.stdout)
			}
		} else if strings.has_prefix(line, "text ") {
			text := line[len("text "):]
			if push_sdl_text_input(h, text) {
				fmt.printf("CONTROL_OK text %s\n", text)
				_ = os.flush(os.stdout)
			} else {
				fmt.println("CONTROL_ERR text failed")
				_ = os.flush(os.stdout)
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
		} else if strings.has_prefix(line, "resize ") {
			w, ht, ok_size := parse_size_arg(line[len("resize "):])
			if ok_size {
				sdl.SetWindowSize(h.window, w, ht)
				_ = sdl.SyncWindow(h.window)
				if !host_rebuild_frame(h) {
					fmt.println("CONTROL_ERR resize rebuild failed")
					_ = os.flush(os.stdout)
					exit_code^ = 1
					running^ = false
					break
				}
				_ = host_render(h)
				fmt.printf("CONTROL_OK resize %dx%d\n", w, ht)
				_ = os.flush(os.stdout)
			} else {
				fmt.println("CONTROL_ERR invalid resize")
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
		} else if line == "ime-area" {
			area: sdl.Rect
			cursor: c.int
			if sdl.GetTextInputArea(h.window, &area, &cursor) {
				fmt.printf("CONTROL_OK ime-area x=%d y=%d w=%d h=%d cursor=%d\n", area.x, area.y, area.w, area.h, cursor)
			} else {
				fmt.println("CONTROL_ERR ime-area failed")
			}
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
	text_edit_drag_end(&h.text_edit)
	h.needs_redraw = true
}

host_handle_pointer_cancel_event :: proc(h: ^Host, ev: ^sdl.Event) -> (res: Pointer_Result) {
	res = pointer_handle_event(&h.pointer, h.frame, ev, h.app.on_pointer, h.app.user_data)
	if res.cancelled {
		host_clear_pressed_on_cancel(h)
	}
	return res
}

is_initial_ctrl_z :: proc(ev: ^sdl.Event) -> bool {
	return ev.type == .KEY_DOWN &&
		!ev.key.repeat &&
		ev.key.key == sdl.K_Z &&
		(ev.key.mod & sdl.KMOD_CTRL) != {} &&
		(ev.key.mod & (sdl.KMOD_SHIFT | sdl.KMOD_ALT | sdl.KMOD_GUI)) == {}
}

// host_step_keyboard_focus moves the single keyboard target forward (Tab) or
// backward (Shift+Tab) through buttons and configured editable text fields in
// frame declaration order, skipping passive labels and wrapping at both ends.
host_step_keyboard_focus :: proc(h: ^Host, backward: bool) -> bool {
	has_cur := false
	cur_id: dagda.Object_Id
	if h.text_edit.focused {
		has_cur = true
		cur_id = h.text_edit.active_id
	} else if h.focus.has_focus {
		has_cur = true
		cur_id = h.focus.focused_id
	}

	first_idx := -1
	last_idx := -1
	cur_idx := -1
	for el, i in h.frame.elements {
		if !is_tab_target(el, h.app.text_edit, h.app.editable_text_targets) {
			continue
		}
		if first_idx < 0 {
			first_idx = i
		}
		last_idx = i
		if has_cur && el.info.id == cur_id {
			cur_idx = i
		}
	}

	if first_idx < 0 {
		c1 := focus_clear(&h.focus)
		c2 := text_edit_blur(&h.text_edit, h.ime_window)
		return c1 || c2
	}

	next_idx := first_idx
	if cur_idx < 0 {
		next_idx = backward ? last_idx : first_idx
	} else if !backward {
		next_idx = first_idx
		for i := cur_idx + 1; i < len(h.frame.elements); i += 1 {
			if is_tab_target(h.frame.elements[i], h.app.text_edit, h.app.editable_text_targets) {
				next_idx = i
				break
			}
		}
	} else {
		next_idx = last_idx
		for i := cur_idx - 1; i >= 0; i -= 1 {
			if is_tab_target(h.frame.elements[i], h.app.text_edit, h.app.editable_text_targets) {
				next_idx = i
				break
			}
		}
	}

	next_el := h.frame.elements[next_idx]
	if text_edit_is_target(h.app.text_edit, h.app.editable_text_targets, next_el.info.id) {
		c1 := focus_clear(&h.focus)
		c2 := text_edit_focus_id(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, next_el.info.id, h.app.editable_text_targets)
		return c1 || c2
	}

	c1 := text_edit_blur(&h.text_edit, h.ime_window)
	c2 := focus_cancel_pending_space(&h.focus)
	if !h.focus.has_focus || h.focus.focused_id != next_el.info.id {
		h.focus.has_focus = true
		h.focus.focused_id = next_el.info.id
		return true
	}
	return c1 || c2
}

// host_shift_down reports Shift modifier state at the current point in the
// dispatched event stream rather than SDL_GetModState(), which can already
// reflect later queued key events before an earlier click is drained.
host_shift_down :: proc(h: ^Host) -> bool {
	return h.lshift_held || h.rshift_held
}

// host_dispatch_key_event routes KEY_DOWN, KEY_UP, and WINDOW_FOCUS_LOST in
// priority order: active pointer gesture cancellation, focused editable text
// (including field-scoped Ctrl+Z and composition protection), unified Tab /
// Shift+Tab traversal across editable fields and buttons, app-level Ctrl+Z
// when the text field is not focused, and button keyboard activation.
host_dispatch_key_event :: proc(h: ^Host, ev: ^sdl.Event) -> (needs_rebuild: bool, has_pending_edit: bool, pending_edit: dagda.Text_Edit) {
	defer host_report_composition(h, host_active_composition(h))
	#partial switch ev.type {
	case .KEY_DOWN:
		if ev.key.key == sdl.K_LSHIFT {
			h.lshift_held = true
		} else if ev.key.key == sdl.K_RSHIFT {
			h.rshift_held = true
		}
	case .KEY_UP:
		if ev.key.key == sdl.K_LSHIFT {
			h.lshift_held = false
		} else if ev.key.key == sdl.K_RSHIFT {
			h.rshift_held = false
		}
	case .WINDOW_FOCUS_LOST:
		h.lshift_held = false
		h.rshift_held = false
	}

	pres := host_handle_pointer_cancel_event(h, ev)
	if pres.changed {
		needs_rebuild = true
	}
	if pres.consumed {
		return
	}

	tres := text_edit_handle_event(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, h.app.user_data, ev, h.app.editable_text_targets, h.clipboard)
	if tres.needs_redraw {
		h.needs_redraw = true
	}
	if tres.needs_rebuild {
		needs_rebuild = true
	}
	if tres.has_pending_edit {
		has_pending_edit = true
		pending_edit = tres.pending_edit
	}
	if tres.consumed {
		return
	}

	if ev.type == .KEY_DOWN && ev.key.key == sdl.K_TAB && (ev.key.mod & (sdl.KMOD_CTRL | sdl.KMOD_ALT | sdl.KMOD_GUI)) == {} {
		shift := (ev.key.mod & sdl.KMOD_SHIFT) != {}
		if host_step_keyboard_focus(h, shift) {
			h.needs_redraw = true
		}
		return
	}

	if is_initial_ctrl_z(ev) && h.app.on_undo != nil {
		if h.app.on_undo(h.app.user_data) {
			needs_rebuild = true
		}
		return
	}

	applied, redraw := focus_handle_event(&h.focus, h.frame, ev, h.app.handle, h.app.user_data)
	if h.focus.has_focus && h.text_edit.focused {
		_ = text_edit_blur(&h.text_edit, h.ime_window)
		h.needs_redraw = true
	}
	if redraw {
		h.needs_redraw = true
	}
	if applied {
		needs_rebuild = true
	}
	return
}

// host_dispatch_mouse_event routes MOUSE_MOTION, MOUSE_BUTTON_DOWN, and
// MOUSE_BUTTON_UP across editable text drag selection, canvas pointer gestures,
// hover tracking, and ordinary element activation. Returns false if a frame
// rebuild failed so the host exits through its normal failure path.
host_dispatch_mouse_event :: proc(h: ^Host, ev: ^sdl.Event) -> bool {
	defer host_report_composition(h, host_active_composition(h))
	#partial switch ev.type {
	case .MOUSE_MOTION:
		if h.text_edit.dragging {
			if text_edit_drag_move(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, ev.motion.x, h.app.editable_text_targets) {
				h.needs_redraw = true
			}
		}
		pres := pointer_handle_event(&h.pointer, h.frame, ev, h.app.on_pointer, h.app.user_data)
		if pres.changed {
			if !host_rebuild_frame(h) {
				return false
			}
		}
		if !pres.consumed && !h.text_edit.dragging {
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
			if h.app.text_edit.enabled {
				if hit && text_edit_is_target(h.app.text_edit, h.app.editable_text_targets, id) {
					_ = focus_clear(&h.focus)
					started, changed := text_edit_press_id(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, id, ev.button.x, h.app.editable_text_targets, host_shift_down(h))
					if changed {
						h.needs_redraw = true
					}
					if !started {
						return true
					}
				} else if text_edit_blur(&h.text_edit, h.ime_window) {
					h.needs_redraw = true
				}
			}
			h.has_pressed = hit
			h.pressed_id = hit ? id : 0
			pres := pointer_handle_event(&h.pointer, h.frame, ev, h.app.on_pointer, h.app.user_data)
			if pres.changed {
				if !host_rebuild_frame(h) {
					return false
				}
			}
			if !pres.suppress_click {
				if dagda.click(h.frame, {x = ev.button.x, y = ev.button.y}, h.app.handle, h.app.user_data) == .Applied {
					if !host_rebuild_frame(h) {
						return false
					}
				} else {
					h.needs_redraw = true
				}
			} else if !pres.changed {
				h.needs_redraw = true
			}
		} else if ev.button.button == sdl.BUTTON_RIGHT && h.pointer.active {
			pres := host_handle_pointer_cancel_event(h, ev)
			if pres.changed {
				if !host_rebuild_frame(h) {
					return false
				}
			}
		}

	case .MOUSE_BUTTON_UP:
		if ev.button.button == sdl.BUTTON_LEFT {
			if h.text_edit.dragging {
				if text_edit_drag_move(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, ev.button.x, h.app.editable_text_targets) {
					h.needs_redraw = true
				}
				text_edit_drag_end(&h.text_edit)
			}
			pres := pointer_handle_event(&h.pointer, h.frame, ev, h.app.on_pointer, h.app.user_data)
			if h.has_pressed {
				h.has_pressed = false
				h.pressed_id = 0
				h.needs_redraw = true
			}
			if pres.changed {
				if !host_rebuild_frame(h) {
					return false
				}
			}
			if pres.consumed && !pres.suppress_click && pres.has_click_id {
				if pointer_try_activate(
					h.frame,
					{x = ev.button.x, y = ev.button.y},
					pres.click_target_id,
					h.app.handle,
					h.app.user_data,
				) {
					if !host_rebuild_frame(h) {
						return false
					}
				}
			}
		}
	}
	return true
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
	h.ime_window = opts.control_stdin ? nil : h.window
	if opts.control_stdin {
		h.clipboard = memory_clipboard_interface(&h.mem_clipboard)
	}
	defer memory_clipboard_destroy(&h.mem_clipboard)
	defer sdl.DestroyWindow(h.window)
	defer sdl.DestroyRenderer(h.renderer)
	// Release cached glyph textures before DestroyRenderer frees the renderer.
	defer font_destroy_textures(&h.font)
	defer text_edit_destroy(&h.text_edit)
	defer dagda.frame_destroy(&h.frame)
	defer host_report_composition(&h, {})

	if !host_rebuild_frame(&h) {
		return 1
	}

	srv: driver.Server
	if len(opts.socket_path) > 0 {
		if !driver.server_start(&srv, opts.socket_path) {
			return 1
		}
	}
	defer driver.server_stop(&srv)

	// Publish readiness only once every fallible startup step
	// has succeeded; a failed start leaves no live handle.
	rebuild_handle, registered := rebuild_register()
	if !registered {
		fmt.eprintln("could not register rebuild event")
		return 1
	}
	h.rebuild = rebuild_handle
	if app.rebuild_handle != nil {
		app.rebuild_handle^ = h.rebuild
	}
	_ = host_present(&h)
	if app.on_ready != nil {
		app.on_ready(app.user_data, h.rebuild)
	}

	control_buf: [dynamic]u8
	defer delete(control_buf)

	running := true
	exit_code := 0
	wait_ms: c.int = (srv.active || opts.control_stdin) ? 16 : 100

	for running && !signal_stopped {
		ev: sdl.Event
		if sdl.WaitEventTimeout(&ev, wait_ms) {
			for {
				if u32(ev.type) == h.rebuild.event_type && ev.user.data1 == rawptr(uintptr(h.rebuild.id)) {
					rebuild_consume_pending(h.rebuild)
					if !host_rebuild_frame(&h) {
						exit_code = 1
						running = false
					} else {
						_ = host_present(&h)
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
				case .MOUSE_MOTION, .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
					if !host_dispatch_mouse_event(&h, &ev) {
						exit_code = 1
						running = false
					}
				case .TEXT_EDITING, .TEXT_INPUT:
					tres := text_edit_handle_event(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, h.app.user_data, &ev, h.app.editable_text_targets)
					host_report_composition(&h, host_active_composition(&h))
					if tres.needs_redraw {
						h.needs_redraw = true
					}
					if tres.needs_rebuild {
						if !host_rebuild_frame(&h) {
							if tres.has_pending_edit {
								dagda.edit_destroy(&h.text_edit.session, &tres.pending_edit)
							}
							exit_code = 1
							running = false
						} else if tres.has_pending_edit {
							text_edit_apply_committed(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, &tres.pending_edit)
						}
					}
				case .KEY_DOWN, .KEY_UP, .WINDOW_FOCUS_LOST:
					needs_rebuild, has_pending_edit, pending_edit := host_dispatch_key_event(&h, &ev)
					if needs_rebuild {
						if !host_rebuild_frame(&h) {
							if has_pending_edit {
								dagda.edit_destroy(&h.text_edit.session, &pending_edit)
							}
							exit_code = 1
							running = false
						} else if has_pending_edit {
							text_edit_apply_committed(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, &pending_edit)
						}
					}
				}
				if !running || !sdl.PollEvent(&ev) {
					break
				}
			}
		}

		if running && srv.active {
			prev_host := dispatch_host
			dispatch_host = &h
			applied, rebuild_failed: bool
			if h.app.edits.handler != nil {
				applied, rebuild_failed = driver.server_poll_edits(&srv, &h.frame, h.app.handle, h.app.user_data, h.app.edits, &h, host_rebuild_cb)
			} else {
				applied, rebuild_failed = driver.server_poll(&srv, &h.frame, h.app.handle, h.app.user_data, &h, host_rebuild_cb)
			}
			dispatch_host = prev_host
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
			_ = host_present(&h)
		}
	}

	rebuild_mark_closing(h.rebuild)
	rebuild_unregister(h.rebuild)
	return exit_code
}
