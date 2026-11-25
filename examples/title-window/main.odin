package main

import title_model "../title-model"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "dagda:dagda"
import sdl "vendor:sdl3"

signal_stopped: bool

on_window_signal :: proc "c" (_: posix.Signal) {
	signal_stopped = true
}

WINDOW_WIDTH  :: 860
WINDOW_HEIGHT :: 340
TITLE_PX      :: f32(30)

Title_Window :: struct {
	window:                 ^sdl.Window,
	renderer:               ^sdl.Renderer,
	font:                   Font,
	editor:                 Editor_State,
	title_box:              sdl.FRect,
	control_stdin:          bool,
	has_text_input_area:    bool,
	last_text_input_area:   sdl.Rect,
	last_text_input_cursor: c.int,
}

window_init :: proc(win: ^Title_Window, adapter: Model_Adapter) -> bool {
	if !font_init(&win.font) {
		return false
	}

	if !sdl.Init({.VIDEO}) {
		fmt.eprintf("SDL_Init failed: %s\n", sdl.GetError())
		font_destroy(&win.font)
		return false
	}

	if !sdl.CreateWindowAndRenderer("Dagda — Shared Title", WINDOW_WIDTH, WINDOW_HEIGHT, {.RESIZABLE}, &win.window, &win.renderer) {
		fmt.eprintf("SDL_CreateWindowAndRenderer failed: %s\n", sdl.GetError())
		sdl.Quit()
		font_destroy(&win.font)
		return false
	}

	editor_init(&win.editor, adapter)
	win.title_box = sdl.FRect{x = 56, y = 112, w = WINDOW_WIDTH - 112, h = 72}
	window_sync_text_input(win)
	return true
}

window_destroy :: proc(win: ^Title_Window) {
	if win.window != nil && sdl.TextInputActive(win.window) {
		_ = sdl.StopTextInput(win.window)
	}
	editor_destroy(&win.editor)
	font_destroy(&win.font)
	if win.renderer != nil {
		sdl.DestroyRenderer(win.renderer)
		win.renderer = nil
	}
	if win.window != nil {
		sdl.DestroyWindow(win.window)
		win.window = nil
	}
	sdl.Quit()
}

window_is_composing :: proc(win: ^Title_Window) -> bool {
	return editor_is_composing(&win.editor)
}

window_external_commit_gate :: proc(win: ^Title_Window) -> External_Commit_Gate {
	return editor_external_commit_gate(&win.editor)
}

window_sync_text_input :: proc(win: ^Title_Window) {
	if win.window == nil {
		return
	}
	if win.control_stdin {
		win.editor.needs_clear_composition = false
		return
	}
	if win.editor.needs_clear_composition {
		_ = sdl.ClearComposition(win.window)
		win.editor.needs_clear_composition = false
	}
	if win.editor.focused {
		just_started := false
		if !sdl.TextInputActive(win.window) {
			_ = sdl.StartTextInput(win.window)
			just_started = true
		}
		layout := compute_title_layout(&win.font, &win.editor, win.title_box, TITLE_PX)
		area := sdl.Rect{
			x = c.int(win.title_box.x),
			y = c.int(win.title_box.y),
			w = c.int(win.title_box.w),
			h = c.int(win.title_box.h),
		}
		if just_started ||
		   !win.has_text_input_area ||
		   area != win.last_text_input_area ||
		   layout.candidate_cursor_x != win.last_text_input_cursor {
			_ = sdl.SetTextInputArea(win.window, &area, layout.candidate_cursor_x)
			win.has_text_input_area = true
			win.last_text_input_area = area
			win.last_text_input_cursor = layout.candidate_cursor_x
		}
	} else {
		if sdl.TextInputActive(win.window) {
			_ = sdl.StopTextInput(win.window)
		}
		win.has_text_input_area = false
	}
}

window_draw :: proc(win: ^Title_Window) {
	r := win.renderer
	out_w, out_h: c.int
	sdl.GetCurrentRenderOutputSize(r, &out_w, &out_h)
	w := f32(out_w)
	h := f32(out_h)
	win.title_box = sdl.FRect{x = 56, y = 112, w = max(w - 112, 240), h = 72}

	// Background
	sdl.SetRenderDrawColor(r, 22, 25, 32, 255)
	sdl.RenderClear(r)

	// Slide card
	card := sdl.FRect{x = 28, y = 24, w = max(w - 56, 300), h = max(h - 48, 220)}
	sdl.SetRenderDrawColor(r, 31, 36, 47, 255)
	sdl.RenderFillRect(r, &card)
	sdl.SetRenderDrawColor(r, 56, 65, 84, 255)
	sdl.RenderRect(r, &card)

	// Header metadata
	header := fmt.tprintf("slide.title  #%d  rev %d", win.editor.snapshot_id, win.editor.snapshot_revision)
	font_draw_text(&win.font, r, header, 56, 46, 18, sdl.Color{165, 177, 198, 255})

	// Focus badge
	badge_x := max(w - 186, 360)
	badge_rect := sdl.FRect{x = badge_x, y = 42, w = 130, h = 30}
	if win.editor.focused {
		sdl.SetRenderDrawColor(r, 29, 78, 57, 255)
		sdl.RenderFillRect(r, &badge_rect)
		sdl.SetRenderDrawColor(r, 64, 179, 126, 255)
		sdl.RenderRect(r, &badge_rect)
		font_draw_text(&win.font, r, "FOCUSED", badge_x + 26, 48, 16, sdl.Color{198, 246, 213, 255})
	} else {
		sdl.SetRenderDrawColor(r, 48, 54, 68, 255)
		sdl.RenderFillRect(r, &badge_rect)
		sdl.SetRenderDrawColor(r, 98, 108, 128, 255)
		sdl.RenderRect(r, &badge_rect)
		font_draw_text(&win.font, r, "BLURRED", badge_x + 26, 48, 16, sdl.Color{165, 177, 198, 255})
	}

	// Active composition badge
	if win.editor.composing {
		comp_rect := sdl.FRect{x = badge_x - 154, y = 42, w = 144, h = 30}
		sdl.SetRenderDrawColor(r, 92, 62, 22, 255)
		sdl.RenderFillRect(r, &comp_rect)
		sdl.SetRenderDrawColor(r, 245, 180, 72, 255)
		sdl.RenderRect(r, &comp_rect)
		font_draw_text(&win.font, r, "COMPOSING", comp_rect.x + 18, 48, 16, sdl.Color{254, 235, 200, 255})
	}

	// Title input box
	sdl.SetRenderDrawColor(r, 20, 23, 30, 255)
	sdl.RenderFillRect(r, &win.title_box)
	if win.editor.focused {
		sdl.SetRenderDrawColor(r, 86, 156, 246, 255)
	} else {
		sdl.SetRenderDrawColor(r, 70, 78, 96, 255)
	}
	sdl.RenderRect(r, &win.title_box)

	layout := compute_title_layout(&win.font, &win.editor, win.title_box, TITLE_PX)

	// Committed selection highlight (when not composing)
	if layout.has_committed_sel {
		sel_rect := sdl.FRect{
			x = layout.committed_sel_x,
			y = win.title_box.y + 14,
			w = max(layout.committed_sel_w, 2),
			h = 44,
		}
		sdl.SetRenderDrawColor(r, 52, 92, 152, 255)
		sdl.RenderFillRect(r, &sel_rect)
	}

	// Draw committed text before insertion/replacement point
	font_draw_text(&win.font, r, layout.before_text, layout.before_x, layout.text_y, layout.title_px, sdl.Color{240, 244, 250, 255})

	// Draw active composition preedit (replacing any selected committed range)
	if win.editor.composing && len(layout.preedit_text) > 0 {
		preedit_bg := sdl.FRect{
			x = layout.preedit_x - 2,
			y = win.title_box.y + 14,
			w = layout.preedit_w + 4,
			h = 44,
		}
		sdl.SetRenderDrawColor(r, 76, 54, 24, 255)
		sdl.RenderFillRect(r, &preedit_bg)

		// Preedit active selection subrange (if preedit_length > 0)
		if layout.has_preedit_sel {
			psel := sdl.FRect{
				x = layout.preedit_sel_x,
				y = win.title_box.y + 14,
				w = max(layout.preedit_sel_w, 2),
				h = 44,
			}
			sdl.SetRenderDrawColor(r, 138, 92, 30, 255)
			sdl.RenderFillRect(r, &psel)
		}

		font_draw_text(&win.font, r, layout.preedit_text, layout.preedit_x, layout.text_y, layout.title_px, sdl.Color{255, 214, 122, 255})

		underline := sdl.FRect{
			x = layout.preedit_x,
			y = win.title_box.y + 56,
			w = layout.preedit_w,
			h = 2,
		}
		sdl.SetRenderDrawColor(r, 245, 180, 72, 255)
		sdl.RenderFillRect(r, &underline)
	}

	// Draw committed text after insertion/replacement point
	font_draw_text(&win.font, r, layout.after_text, layout.after_x, layout.text_y, layout.title_px, sdl.Color{240, 244, 250, 255})

	// Caret bar (uses exact layout.caret_x, honoring nonterminal preedit_start)
	if win.editor.focused {
		caret_rect := sdl.FRect{x = layout.caret_x, y = win.title_box.y + 14, w = 2, h = 44}
		sdl.SetRenderDrawColor(r, 118, 185, 255, 255)
		sdl.RenderFillRect(r, &caret_rect)
	}

	// Separate composition status line
	if win.editor.composing {
		comp_line := fmt.tprintf("Preedit: %q (start=%d len=%d) | Gate: Busy_Composing | Esc to cancel",
			win.editor.preedit_text, win.editor.preedit_start, win.editor.preedit_length)
		font_draw_text(&win.font, r, comp_line, 56, 200, 16, sdl.Color{245, 198, 108, 255})
	} else {
		gate_line := fmt.tprintf("Committed: %q | Gate: Ready", win.editor.committed_text)
		font_draw_text(&win.font, r, gate_line, 56, 200, 16, sdl.Color{136, 152, 178, 255})
	}

	// Status + keybind legend
	font_draw_text(&win.font, r, win.editor.last_status, 56, 232, 16, sdl.Color{174, 214, 241, 255})
	help := "Type to edit  |  Ctrl+Z Undo  |  Esc Cancel preedit  |  F2 Simulated external rename"
	font_draw_text(&win.font, r, help, 56, 266, 14, sdl.Color{120, 132, 154, 255})
}

window_render :: proc(win: ^Title_Window, screenshot_path := "") -> bool {
	window_draw(win)
	ok := true
	if len(screenshot_path) > 0 {
		ok = window_save_screenshot(win, screenshot_path)
	}
	sdl.RenderPresent(win.renderer)
	win.editor.needs_redraw = false
	return ok
}

window_save_screenshot :: proc(win: ^Title_Window, path: string) -> bool {
	surface := sdl.RenderReadPixels(win.renderer, nil)
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

simulate_external_rename :: proc(win: ^Title_Window, adapter: Model_Adapter, next_text: string) -> bool {
	if window_external_commit_gate(win) == .Busy_Composing {
		editor_set_status(&win.editor, "External commit blocked: Busy_Composing (retry after preedit)")
		win.editor.needs_redraw = true
		return false
	}
	snap := adapter_snapshot(adapter)
	target := dagda.Action_Target{id = snap.id, base_revision = snap.revision}
	res := adapter_commit(adapter, target, next_text)
	if res.err != .None {
		editor_set_status(&win.editor, fmt.tprintf("External commit error: %v", res.err))
		win.editor.needs_redraw = true
		return false
	}
	editor_sync_from_model(&win.editor, adapter)
	editor_set_status(&win.editor, fmt.tprintf("External rename -> rev %d (focus preserved)", win.editor.snapshot_revision))
	return true
}

demo_assert :: proc(cond: bool, msg: string) {
	if !cond {
		fmt.eprintf("DEMO CHECK FAILED: %s\n", msg)
		os.exit(1)
	}
}

run_demo_capture :: proc(win: ^Title_Window, adapter: Model_Adapter, capture_dir: string) {
	if err := os.make_directory(capture_dir); err != nil && err != .Exist {
		fmt.eprintf("Failed to create capture directory %q: %v\n", capture_dir, err)
		os.exit(1)
	}

	pump :: proc(win: ^Title_Window, screenshot_path := "") {
		ev: sdl.Event
		for sdl.PollEvent(&ev) {}
		window_sync_text_input(win)
		if !window_render(win, screenshot_path) {
			fmt.eprintf("Capture failed for %q\n", screenshot_path)
			os.exit(1)
		}
	}

	sdl.Delay(50)
	pump(win)
	demo_assert(win.editor.snapshot_revision == 0, "initial revision should be 0")
	demo_assert(win.editor.committed_text == "Quarterly results", "initial text mismatch")
	demo_assert(win.editor.focused && !win.editor.composing, "initial focus/composing mismatch")
	fmt.printf("[1] Initial:           rev=%d text=%q focused=%v composing=%v font=%q\n",
		win.editor.snapshot_revision, win.editor.committed_text, win.editor.focused, win.editor.composing, win.font.font_path)

	// Select "results" (7 chars) so composing preedit replaces the selected range.
	for _ in 0 ..< 7 {
		shift_left: sdl.Event
		shift_left.type = .KEY_DOWN
		shift_left.key.key = sdl.K_LEFT
		shift_left.key.mod = sdl.KMOD_LSHIFT
		editor_handle_sdl_event(&win.editor, adapter, &shift_left, win.title_box)
	}

	// Inject non-ASCII preedit "café" with nonterminal caret at rune index 2 ("ca|fé").
	edit_ev: sdl.Event
	edit_ev.type = .TEXT_EDITING
	edit_ev.edit.text = "café"
	edit_ev.edit.start = 2
	edit_ev.edit.length = 0
	editor_handle_sdl_event(&win.editor, adapter, &edit_ev, win.title_box)
	blocked := simulate_external_rename(win, adapter, "Café & niño")
	pump(win, fmt.tprintf("%s/01-nonascii-preedit-busy.png", capture_dir))

	layout := compute_title_layout(&win.font, &win.editor, win.title_box, TITLE_PX)
	demo_assert(win.editor.composing, "should be composing")
	demo_assert(!blocked, "external rename must be blocked while composing")
	demo_assert(win.editor.snapshot_revision == 0, "composition must not advance revision")
	demo_assert(layout.before_text == "Quarterly ", "composing should replace selected committed range")
	demo_assert(layout.caret_x > layout.preedit_x && layout.caret_x < layout.preedit_x + layout.preedit_w,
		"nonterminal preedit caret must lie inside preedit span")
	fmt.printf("[2] Non-ASCII preedit: rev=%d committed=%q preedit=%q start=%d external_applied=%v focused=%v\n",
		win.editor.snapshot_revision, win.editor.committed_text, win.editor.preedit_text, win.editor.preedit_start, blocked, win.editor.focused)

	// Cancel composition with Escape; selection and committed text survive.
	esc_ev: sdl.Event
	esc_ev.type = .KEY_DOWN
	esc_ev.key.key = sdl.K_ESCAPE
	editor_handle_sdl_event(&win.editor, adapter, &esc_ev, win.title_box)
	pump(win)
	demo_assert(!win.editor.composing, "Escape should end composition")
	demo_assert(win.editor.snapshot_revision == 0, "cancel must not advance revision")
	demo_assert(win.editor.committed_text == "Quarterly results", "cancel must preserve committed text")
	demo_assert(win.editor.focused, "cancel must preserve focus")
	fmt.printf("[3] Cancel Esc:        rev=%d text=%q composing=%v focused=%v\n",
		win.editor.snapshot_revision, win.editor.committed_text, win.editor.composing, win.editor.focused)

	// Commit non-ASCII replacement "español" over the selected range via TEXT_INPUT.
	input_ev: sdl.Event
	input_ev.type = .TEXT_INPUT
	input_ev.text.text = "español"
	editor_handle_sdl_event(&win.editor, adapter, &input_ev, win.title_box)
	pump(win, fmt.tprintf("%s/02-nonascii-committed.png", capture_dir))
	demo_assert(win.editor.snapshot_revision == 1, "TEXT_INPUT commit should advance revision to 1")
	demo_assert(win.editor.committed_text == "Quarterly español", "non-ASCII commit text mismatch")
	demo_assert(win.editor.commit_count == 1, "expected exactly 1 commit")
	fmt.printf("[4] Non-ASCII commit:  rev=%d text=%q commits=%d focused=%v\n",
		win.editor.snapshot_revision, win.editor.committed_text, win.editor.commit_count, win.editor.focused)

	// External rename now succeeds without stealing focus.
	applied := simulate_external_rename(win, adapter, "Café & niño")
	pump(win, fmt.tprintf("%s/03-external-rename.png", capture_dir))
	demo_assert(applied, "external rename should succeed when not composing")
	demo_assert(win.editor.snapshot_revision == 2, "external rename should advance revision to 2")
	demo_assert(win.editor.committed_text == "Café & niño", "external rename text mismatch")
	demo_assert(win.editor.focused, "external rename must preserve focus")
	fmt.printf("[5] External edit:     rev=%d text=%q applied=%v focused=%v\n",
		win.editor.snapshot_revision, win.editor.committed_text, applied, win.editor.focused)

	// Keyboard Undo (Ctrl+Z) restores "Quarterly español" and keeps focus.
	undo_ev: sdl.Event
	undo_ev.type = .KEY_DOWN
	undo_ev.key.key = sdl.K_Z
	undo_ev.key.mod = sdl.KMOD_LCTRL
	editor_handle_sdl_event(&win.editor, adapter, &undo_ev, win.title_box)
	pump(win, fmt.tprintf("%s/04-after-undo.png", capture_dir))
	demo_assert(win.editor.snapshot_revision == 3, "undo should advance revision to 3")
	demo_assert(win.editor.committed_text == "Quarterly español", "undo should restore prior committed text")
	demo_assert(win.editor.focused, "undo must preserve focus")
	fmt.printf("[6] Ctrl+Z Undo:       rev=%d text=%q focused=%v\n",
		win.editor.snapshot_revision, win.editor.committed_text, win.editor.focused)
}

poll_control_stdin :: proc(
	win: ^Title_Window,
	adapter: Model_Adapter,
	in_buf: ^[dynamic]u8,
	running: ^bool,
	exit_code: ^int,
) {
	pfd := posix.pollfd{fd = posix.STDIN_FILENO, events = {.IN}}
	if posix.poll(&pfd, 1, 0) <= 0 {
		return
	}
	if .IN not_in pfd.revents {
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

		if strings.has_prefix(line, "type ") {
			text := line[len("type "):]
			cstr := strings.clone_to_cstring(text)
			defer delete(cstr)
			ev: sdl.Event
			ev.type = .TEXT_INPUT
			ev.text.text = cstr
			_ = editor_handle_sdl_event(&win.editor, adapter, &ev, win.title_box)
			window_sync_text_input(win)
			_ = window_render(win)
			fmt.printf("CONTROL_OK rev=%d text=%q focused=%v composing=%v\n",
				win.editor.snapshot_revision, win.editor.committed_text, win.editor.focused, win.editor.composing)
			_ = os.flush(os.stdout)
		} else if strings.has_prefix(line, "preedit ") {
			rest := line[len("preedit "):]
			sp1 := strings.index_byte(rest, ' ')
			sp2 := sp1 >= 0 ? strings.index_byte(rest[sp1 + 1:], ' ') : -1
			if sp1 >= 0 && sp2 >= 0 {
				start_val, _ := strconv.parse_int(rest[:sp1])
				len_val, _ := strconv.parse_int(rest[sp1 + 1:sp1 + 1 + sp2])
				text := rest[sp1 + 1 + sp2 + 1:]
				cstr := strings.clone_to_cstring(text)
				defer delete(cstr)
				ev: sdl.Event
				ev.type = .TEXT_EDITING
				ev.edit.text = cstr
				ev.edit.start = c.int32_t(start_val)
				ev.edit.length = c.int32_t(len_val)
				_ = editor_handle_sdl_event(&win.editor, adapter, &ev, win.title_box)
				window_sync_text_input(win)
				_ = window_render(win)
				fmt.printf("CONTROL_OK rev=%d text=%q preedit=%q focused=%v composing=%v\n",
					win.editor.snapshot_revision, win.editor.committed_text, win.editor.preedit_text, win.editor.focused, win.editor.composing)
				_ = os.flush(os.stdout)
			}
		} else if line == "escape" {
			ev: sdl.Event
			ev.type = .KEY_DOWN
			ev.key.key = sdl.K_ESCAPE
			_ = editor_handle_sdl_event(&win.editor, adapter, &ev, win.title_box)
			window_sync_text_input(win)
			_ = window_render(win)
			fmt.printf("CONTROL_OK rev=%d text=%q focused=%v composing=%v\n",
				win.editor.snapshot_revision, win.editor.committed_text, win.editor.focused, win.editor.composing)
			_ = os.flush(os.stdout)
		} else if line == "undo" {
			ev: sdl.Event
			ev.type = .KEY_DOWN
			ev.key.key = sdl.K_Z
			ev.key.mod = sdl.KMOD_LCTRL
			_ = editor_handle_sdl_event(&win.editor, adapter, &ev, win.title_box)
			window_sync_text_input(win)
			_ = window_render(win)
			fmt.printf("CONTROL_OK rev=%d text=%q focused=%v composing=%v\n",
				win.editor.snapshot_revision, win.editor.committed_text, win.editor.focused, win.editor.composing)
			_ = os.flush(os.stdout)
		} else if strings.has_prefix(line, "screenshot ") {
			path := line[len("screenshot "):]
			window_sync_text_input(win)
			ok := window_render(win, path)
			if !ok {
				fmt.printf("CONTROL_ERR screenshot failed: %s\n", path)
				_ = os.flush(os.stdout)
				exit_code^ = 1
				running^ = false
				break
			}
			fmt.printf("CONTROL_OK screenshot=%s rev=%d text=%q focused=%v composing=%v\n",
				path, win.editor.snapshot_revision, win.editor.committed_text, win.editor.focused, win.editor.composing)
			_ = os.flush(os.stdout)
		} else if line == "status" {
			fmt.printf("CONTROL_OK rev=%d text=%q preedit=%q focused=%v composing=%v\n",
				win.editor.snapshot_revision, win.editor.committed_text, win.editor.preedit_text, win.editor.focused, win.editor.composing)
			_ = os.flush(os.stdout)
		} else if line == "quit" {
			fmt.println("CONTROL_OK quit")
			_ = os.flush(os.stdout)
			running^ = false
			break
		}
	}
}

run_main :: proc() -> int {
	demo_capture_dir := ""
	socket_path := ""
	control_stdin := false

	for i := 1; i < len(os.args); i += 1 {
		arg := os.args[i]
		if arg == "--demo-capture" && i + 1 < len(os.args) {
			i += 1
			demo_capture_dir = os.args[i]
		} else if arg == "--socket" && i + 1 < len(os.args) {
			i += 1
			socket_path = os.args[i]
		} else if arg == "--control-stdin" {
			control_stdin = true
		} else {
			fmt.eprintln("usage: title-window [--socket <socket-path>] [--demo-capture <dir>]")
			return 2
		}
	}

	act: posix.sigaction_t
	act.sa_handler = on_window_signal
	posix.sigaction(.SIGINT, &act, nil)
	posix.sigaction(.SIGTERM, &act, nil)
	ignore: posix.sigaction_t
	ignore.sa_handler = transmute(proc "c" (posix.Signal))posix.SIG_IGN
	posix.sigaction(.SIGPIPE, &ignore, nil)

	model: title_model.Model
	if err := title_model.init(&model, {id = 1, role = "slide.title"}, "Quarterly results"); err != .None {
		fmt.eprintf("title_model.init failed: %v\n", err)
		return 1
	}
	defer title_model.destroy(&model)
	adapter := title_model_adapter(&model)

	win: Title_Window
	win.control_stdin = control_stdin
	if !window_init(&win, adapter) {
		return 1
	}
	defer window_destroy(&win)

	if len(demo_capture_dir) > 0 {
		run_demo_capture(&win, adapter, demo_capture_dir)
		return 0
	}

	server: Window_Driver_Server
	if len(socket_path) > 0 {
		if !driver_server_start(&server, socket_path) {
			return 1
		}
	}
	defer driver_server_stop(&server)

	control_buf: [dynamic]u8
	defer delete(control_buf)

	_ = window_render(&win)
	external_step := 0
	running := true
	exit_code := 0
	wait_ms: c.int = (server.active || control_stdin) ? 16 : 100

	for running && !signal_stopped {
		ev: sdl.Event
		if sdl.WaitEventTimeout(&ev, wait_ms) {
			for {
				#partial switch ev.type {
				case .QUIT, .WINDOW_CLOSE_REQUESTED:
					running = false
				case .WINDOW_EXPOSED, .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED:
					win.editor.needs_redraw = true
				case .KEY_DOWN:
					if ev.key.key == sdl.K_F2 {
						external_step += 1
						next := external_step % 2 == 1 ? "Café & niño" : "Revenue grew 12%"
						_ = simulate_external_rename(&win, adapter, next)
					} else {
						_ = editor_handle_sdl_event(&win.editor, adapter, &ev, win.title_box)
					}
				case:
					_ = editor_handle_sdl_event(&win.editor, adapter, &ev, win.title_box)
				}
				if !running || !sdl.PollEvent(&ev) {
					break
				}
			}
		}

		if server.active {
			driver_server_poll(&server, &model, &win.editor, adapter)
		}
		if control_stdin {
			poll_control_stdin(&win, adapter, &control_buf, &running, &exit_code)
		}

		window_sync_text_input(&win)
		if win.editor.needs_redraw {
			_ = window_render(&win)
		}
	}
	return exit_code
}

main :: proc() {
	if code := run_main(); code != 0 {
		os.exit(code)
	}
}
