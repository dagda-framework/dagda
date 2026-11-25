package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "dagda:dagda"
import sdl "vendor:sdl3"

WINDOW_WIDTH  :: 860
WINDOW_HEIGHT :: 340

Title_Window :: struct {
	window:    ^sdl.Window,
	renderer:  ^sdl.Renderer,
	font:      Font,
	editor:    Editor_State,
	title_box: sdl.FRect,
}

window_init :: proc(win: ^Title_Window, adapter: Model_Adapter) -> bool {
	if !sdl.Init({.VIDEO}) {
		fmt.eprintf("SDL_Init failed: %s\n", sdl.GetError())
		return false
	}

	if !sdl.CreateWindowAndRenderer("Dagda — Shared Title", WINDOW_WIDTH, WINDOW_HEIGHT, {.RESIZABLE}, &win.window, &win.renderer) {
		fmt.eprintf("SDL_CreateWindowAndRenderer failed: %s\n", sdl.GetError())
		sdl.Quit()
		return false
	}

	font_init(&win.font)
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
	if win.editor.needs_clear_composition {
		_ = sdl.ClearComposition(win.window)
		win.editor.needs_clear_composition = false
	}
	if win.editor.focused {
		if !sdl.TextInputActive(win.window) {
			_ = sdl.StartTextInput(win.window)
		}
		before := win.editor.committed_text[:win.editor.caret]
		caret_offset := c.int(font_measure_width(&win.font, before, 30) + 18)
		area := sdl.Rect{
			x = c.int(win.title_box.x),
			y = c.int(win.title_box.y),
			w = c.int(win.title_box.w),
			h = c.int(win.title_box.h),
		}
		_ = sdl.SetTextInputArea(win.window, &area, caret_offset)
	} else {
		if sdl.TextInputActive(win.window) {
			_ = sdl.StopTextInput(win.window)
		}
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
	font_draw_text(&win.font, r, header, 56, 48, 16, sdl.Color{165, 177, 198, 255})

	// Focus badge
	badge_x := max(w - 190, 360)
	badge_rect := sdl.FRect{x = badge_x, y = 44, w = 132, h = 28}
	if win.editor.focused {
		sdl.SetRenderDrawColor(r, 29, 78, 57, 255)
		sdl.RenderFillRect(r, &badge_rect)
		sdl.SetRenderDrawColor(r, 64, 179, 126, 255)
		sdl.RenderRect(r, &badge_rect)
		font_draw_text(&win.font, r, "FOCUSED", badge_x + 10, 50, 16, sdl.Color{198, 246, 213, 255})
	} else {
		sdl.SetRenderDrawColor(r, 48, 54, 68, 255)
		sdl.RenderFillRect(r, &badge_rect)
		sdl.SetRenderDrawColor(r, 98, 108, 128, 255)
		sdl.RenderRect(r, &badge_rect)
		font_draw_text(&win.font, r, "BLURRED", badge_x + 10, 50, 16, sdl.Color{165, 177, 198, 255})
	}

	// Active composition badge
	if win.editor.composing {
		comp_rect := sdl.FRect{x = badge_x - 168, y = 44, w = 158, h = 28}
		sdl.SetRenderDrawColor(r, 92, 62, 22, 255)
		sdl.RenderFillRect(r, &comp_rect)
		sdl.SetRenderDrawColor(r, 245, 180, 72, 255)
		sdl.RenderRect(r, &comp_rect)
		font_draw_text(&win.font, r, "COMPOSING", comp_rect.x + 8, 50, 16, sdl.Color{254, 235, 200, 255})
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

	text_x := win.title_box.x + 18
	text_y := win.title_box.y + 24
	title_px: f32 = 24

	// Selection highlight
	if has_selection(&win.editor) {
		sel_start, sel_end := selection_bounds(&win.editor)
		x0 := text_x + font_measure_width(&win.font, win.editor.committed_text[:sel_start], title_px)
		x1 := text_x + font_measure_width(&win.font, win.editor.committed_text[:sel_end], title_px)
		sel_rect := sdl.FRect{x = x0, y = win.title_box.y + 14, w = max(x1 - x0, 2), h = 44}
		sdl.SetRenderDrawColor(r, 52, 92, 152, 255)
		sdl.RenderFillRect(r, &sel_rect)
	}

	// Draw committed text before caret, inline preedit (if any), and committed text after caret.
	before := win.editor.committed_text[:win.editor.caret]
	after := win.editor.committed_text[win.editor.caret:]
	cursor_x := text_x
	cursor_x += font_draw_text(&win.font, r, before, cursor_x, text_y, title_px, sdl.Color{240, 244, 250, 255})

	caret_x := cursor_x
	if win.editor.composing && len(win.editor.preedit_text) > 0 {
		preedit_w := font_measure_width(&win.font, win.editor.preedit_text, title_px)
		preedit_bg := sdl.FRect{x = cursor_x - 2, y = win.title_box.y + 14, w = preedit_w + 4, h = 44}
		sdl.SetRenderDrawColor(r, 76, 54, 24, 255)
		sdl.RenderFillRect(r, &preedit_bg)

		font_draw_text(&win.font, r, win.editor.preedit_text, cursor_x, text_y, title_px, sdl.Color{255, 214, 122, 255})

		underline := sdl.FRect{x = cursor_x, y = win.title_box.y + 54, w = preedit_w, h = 2}
		sdl.SetRenderDrawColor(r, 245, 180, 72, 255)
		sdl.RenderFillRect(r, &underline)

		cursor_x += preedit_w
		caret_x = cursor_x
	}

	font_draw_text(&win.font, r, after, cursor_x, text_y, title_px, sdl.Color{240, 244, 250, 255})

	// Caret bar
	if win.editor.focused {
		caret_rect := sdl.FRect{x = caret_x, y = win.title_box.y + 14, w = 2, h = 44}
		sdl.SetRenderDrawColor(r, 118, 185, 255, 255)
		sdl.RenderFillRect(r, &caret_rect)
	}

	// Separate composition line so preedit is visibly distinct from committed text.
	if win.editor.composing {
		comp_line := fmt.tprintf("Preedit: %q | Gate: Busy_Composing | Esc to cancel", win.editor.preedit_text)
		font_draw_text(&win.font, r, comp_line, 56, 204, 12, sdl.Color{245, 198, 108, 255})
	} else {
		gate_line := fmt.tprintf("Committed: %q | Gate: Ready", win.editor.committed_text)
		font_draw_text(&win.font, r, gate_line, 56, 204, 12, sdl.Color{136, 152, 178, 255})
	}

	// Status + keybind legend
	font_draw_text(&win.font, r, win.editor.last_status, 56, 236, 12, sdl.Color{174, 214, 241, 255})
	help := "Type to edit | Ctrl+Z Undo | Esc Cancel preedit | F2 External rename"
	font_draw_text(&win.font, r, help, 56, 268, 10, sdl.Color{120, 132, 154, 255})
}

window_render :: proc(win: ^Title_Window, screenshot_path := "") {
	window_draw(win)
	if len(screenshot_path) > 0 {
		_ = window_save_screenshot(win, screenshot_path)
	}
	sdl.RenderPresent(win.renderer)
	win.editor.needs_redraw = false
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
		fmt.eprintf("SDL_SavePNG failed: %s\n", sdl.GetError())
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

run_demo_capture :: proc(win: ^Title_Window, adapter: Model_Adapter, capture_dir: string) {
	_ = os.make_directory(capture_dir)

	pump :: proc(win: ^Title_Window, screenshot_path := "") {
		ev: sdl.Event
		for sdl.PollEvent(&ev) {}
		window_sync_text_input(win)
		window_render(win, screenshot_path)
	}

	sdl.Delay(50)
	pump(win)
	fmt.printf("[1] Initial:       rev=%d text=%q focused=%v composing=%v\n",
		win.editor.snapshot_revision, win.editor.committed_text, win.editor.focused, win.editor.composing)

	// Inject active composition (SDL TEXT_EDITING)
	preedit_cstr := cstring("Q4 ")
	edit_ev: sdl.Event
	edit_ev.type = .TEXT_EDITING
	edit_ev.edit.text = preedit_cstr
	edit_ev.edit.start = 3
	edit_ev.edit.length = 0
	editor_handle_sdl_event(&win.editor, adapter, &edit_ev, win.title_box)
	blocked := simulate_external_rename(win, adapter, "Revenue grew 12%")
	pump(win, fmt.tprintf("%s/01-composing-busy.png", capture_dir))
	fmt.printf("[2] Composing:     rev=%d text=%q preedit=%q external_applied=%v focused=%v\n",
		win.editor.snapshot_revision, win.editor.committed_text, win.editor.preedit_text, blocked, win.editor.focused)

	// Cancel composition with Escape
	esc_ev: sdl.Event
	esc_ev.type = .KEY_DOWN
	esc_ev.key.key = sdl.K_ESCAPE
	editor_handle_sdl_event(&win.editor, adapter, &esc_ev, win.title_box)
	pump(win)
	fmt.printf("[3] Cancel Esc:    rev=%d text=%q composing=%v focused=%v\n",
		win.editor.snapshot_revision, win.editor.committed_text, win.editor.composing, win.editor.focused)

	// External rename now succeeds without stealing focus
	applied := simulate_external_rename(win, adapter, "Revenue grew 12%")
	pump(win, fmt.tprintf("%s/02-external-rename.png", capture_dir))
	fmt.printf("[4] External edit: rev=%d text=%q applied=%v focused=%v\n",
		win.editor.snapshot_revision, win.editor.committed_text, applied, win.editor.focused)

	// Keyboard Undo (Ctrl+Z) restores original title and keeps focus
	undo_ev: sdl.Event
	undo_ev.type = .KEY_DOWN
	undo_ev.key.key = sdl.K_Z
	undo_ev.key.mod = sdl.KMOD_LCTRL
	editor_handle_sdl_event(&win.editor, adapter, &undo_ev, win.title_box)
	pump(win, fmt.tprintf("%s/03-after-undo.png", capture_dir))
	fmt.printf("[5] Ctrl+Z Undo:   rev=%d text=%q focused=%v\n",
		win.editor.snapshot_revision, win.editor.committed_text, win.editor.focused)
}

main :: proc() {
	fixture: Local_Fixture
	fixture_init(&fixture, "Quarterly results", 1)
	defer fixture_destroy(&fixture)
	adapter := fixture_adapter(&fixture)

	win: Title_Window
	if !window_init(&win, adapter) {
		os.exit(1)
	}
	defer window_destroy(&win)

	if len(os.args) >= 3 && os.args[1] == "--demo-capture" {
		run_demo_capture(&win, adapter, os.args[2])
		return
	}

	window_render(&win)
	external_step := 0
	running := true

	for running {
		ev: sdl.Event
		if sdl.WaitEventTimeout(&ev, 100) {
			for {
				#partial switch ev.type {
				case .QUIT, .WINDOW_CLOSE_REQUESTED:
					running = false
				case .WINDOW_EXPOSED, .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED:
					win.editor.needs_redraw = true
				case .KEY_DOWN:
					if ev.key.key == sdl.K_F2 {
						external_step += 1
						next := external_step % 2 == 1 ? "Revenue grew 12%" : "Board review draft"
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

		window_sync_text_input(&win)
		if win.editor.needs_redraw {
			window_render(&win)
		}
	}
}
