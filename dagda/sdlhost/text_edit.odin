package sdlhost

import "core:c"
import "core:math"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"
import "dagda:dagda"
import sdl "vendor:sdl3"

// Text_Commit_Handler commits a proposed full replacement string for an
// editable text element. Return true if the app accepted and committed it.
Text_Commit_Handler :: #type proc(user_data: rawptr, id: dagda.Object_Id, new_text: string) -> bool

// Text_Undo_Handler handles Ctrl+Z while the editable text element is focused
// and not composing. Return true if the app applied an undo step.
Text_Undo_Handler :: #type proc(user_data: rawptr, id: dagda.Object_Id) -> bool

// Editable_Text_Config opts a single-line text element into host-managed
// grapheme movement, selection, and IME composition backed by dagda.Text_Session.
// The app owns committed text, revision, and undo history.
// For multiple editable elements in one window, set App.editable_text_targets.
Editable_Text_Config :: struct {
	enabled:   bool,
	target_id: dagda.Object_Id,
	on_commit: Text_Commit_Handler,
	on_undo:   Text_Undo_Handler,
}

Text_Edit_State :: struct {
	focused:   bool,
	active_id: dagda.Object_Id,
	session:   dagda.Text_Session,
}

// Active_Composition identifies which visual field in the current host window
// has an active IME preedit, using an explicit active flag because
// Object_Id(0) is a valid element ID.
Active_Composition :: struct {
	active:   bool,
	field_id: dagda.Object_Id,
}

@(private="package", thread_local)
dispatch_host: ^Host

@(private="package")
host_active_composition :: proc(h: ^Host) -> Active_Composition {
	if h != nil && h.text_edit.focused && dagda.is_composing(&h.text_edit.session) {
		return {active = true, field_id = h.text_edit.active_id}
	}
	return {}
}

// current_composition reports which visual field in the dispatching host window
// currently has an active IME composition. Outside dispatch, it returns an
// inactive Active_Composition{active = false, field_id = 0}. Intended for an
// app's external Edit_Handler to decide whether an incoming edit conflicts with
// live user composition.
current_composition :: proc() -> Active_Composition {
	return host_active_composition(dispatch_host)
}

text_edit_is_target :: proc(cfg: Editable_Text_Config, targets: []dagda.Object_Id, id: dagda.Object_Id) -> bool {
	if !cfg.enabled {
		return false
	}
	if len(targets) > 0 {
		for tid in targets {
			if tid == id {
				return true
			}
		}
		return false
	}
	return id == cfg.target_id
}

text_edit_default_target :: proc(cfg: Editable_Text_Config, targets: []dagda.Object_Id = nil) -> dagda.Object_Id {
	if len(targets) > 0 {
		return targets[0]
	}
	return cfg.target_id
}

Text_Edit_Result :: struct {
	consumed:         bool,
	needs_redraw:     bool,
	needs_rebuild:    bool,
	has_pending_edit: bool,
	pending_edit:     dagda.Text_Edit,
}

// text_edit_layout returns the exact rendered text origin and pixel height
// shared by painting and font_hit_test_caret for an editable single-line label.
text_edit_layout :: proc(frame: dagda.Frame, rect: dagda.Rect) -> (text_x: f32, text_y: f32, px: f32) {
	text_scale: f32 = frame.has_canvas ? clamp(frame.transform.scale, 0.4, 2.0) : 1.0
	px = max(24 * text_scale, 12)
	pad_x := max(16 * text_scale, 10)
	text_x = rect.x + pad_x
	text_y = rect.y + (rect.height - px) * 0.5
	return
}

// text_edit_preedit_caret_bytes returns the byte offset of the caret within
// session.preedit. An explicit non-negative preedit_start (including 0 with
// length 0) is honored; a negative preedit_start falls back to the end of the
// preedit string.
text_edit_preedit_caret_bytes :: proc(session: ^dagda.Text_Session) -> int {
	preedit := session.preedit
	if session.preedit_start < 0 {
		return len(preedit)
	}
	caret_runes := session.preedit_start + max(session.preedit_length, 0)
	return rune_offset_to_bytes(preedit, caret_runes)
}

// text_edit_caret_x computes the exact window-space X coordinate of the caret
// using the same text origin and font metrics used by text_edit_draw and
// SDL_SetTextInputArea.
text_edit_caret_x :: proc(
	te: ^Text_Edit_State,
	font: ^Font,
	frame: dagda.Frame,
	bounds: dagda.Rect,
	committed: string,
) -> f32 {
	tx, _, px := text_edit_layout(frame, bounds)
	if font == nil || !font.loaded {
		return tx
	}
	if dagda.is_composing(&te.session) {
		sel_start, _ := dagda.selection_bounds(&te.session)
		sel_start = clamp(sel_start, 0, len(committed))
		prefix_w := font_measure_width(font, committed[:sel_start], px)
		caret_bytes := text_edit_preedit_caret_bytes(&te.session)
		return tx + prefix_w + font_measure_width(font, te.session.preedit[:caret_bytes], px)
	}
	caret_off := clamp(te.session.caret, 0, len(committed))
	return tx + font_measure_width(font, committed[:caret_off], px)
}

text_edit_destroy :: proc(te: ^Text_Edit_State) {
	dagda.text_session_destroy(&te.session)
	te.focused = false
	te.active_id = 0
}

text_edit_update_ime_area :: proc(
	te: ^Text_Edit_State,
	window: ^sdl.Window,
	font: ^Font,
	frame: dagda.Frame,
	cfg: Editable_Text_Config,
) {
	if window == nil || !cfg.enabled || !te.focused {
		return
	}
	el, found := dagda.find(frame, te.active_id)
	if !found {
		return
	}
	area := sdl.Rect{
		x = c.int(math.floor(el.bounds.x)),
		y = c.int(math.floor(el.bounds.y)),
		w = max(c.int(math.ceil(el.bounds.width)), 1),
		h = max(c.int(math.ceil(el.bounds.height)), 1),
	}
	caret_x := text_edit_caret_x(te, font, frame, el.bounds, el.text)
	cursor := c.int(math.round(caret_x)) - area.x
	_ = sdl.SetTextInputArea(window, &area, cursor)
}

text_edit_focus_id :: proc(
	te: ^Text_Edit_State,
	window: ^sdl.Window,
	font: ^Font,
	frame: dagda.Frame,
	cfg: Editable_Text_Config,
	target_id: dagda.Object_Id,
	targets: []dagda.Object_Id = nil,
) -> bool {
	if !text_edit_is_target(cfg, targets, target_id) {
		return false
	}
	// Keep focus, caret, selection, and preedit in the originating field
	// until composition commits or is cancelled.
	if te.focused && te.active_id != target_id && dagda.is_composing(&te.session) {
		return false
	}
	el, found := dagda.find(frame, target_id)
	if !found {
		return false
	}
	was_focused := te.focused
	switched := !te.focused || te.active_id != target_id
	if switched {
		dagda.text_session_destroy(&te.session)
		dagda.text_session_init(&te.session, el.text)
		te.focused = true
		te.active_id = target_id
		if window != nil {
			if !was_focused {
				_ = sdl.StartTextInput(window)
			}
			text_edit_update_ime_area(te, window, font, frame, cfg)
		}
	} else if !dagda.is_composing(&te.session) {
		dagda.text_session_sync(&te.session, el.text)
		text_edit_update_ime_area(te, window, font, frame, cfg)
	}
	return switched
}

text_edit_focus :: proc(
	te: ^Text_Edit_State,
	window: ^sdl.Window,
	font: ^Font,
	frame: dagda.Frame,
	cfg: Editable_Text_Config,
	targets: []dagda.Object_Id = nil,
) -> bool {
	return text_edit_focus_id(te, window, font, frame, cfg, text_edit_default_target(cfg, targets), targets)
}

// text_edit_click_id focuses target_id and places the caret at the clicked
// grapheme boundary using font_hit_test_caret with the exact painted text
// origin and font height. While another editable field has an active preedit,
// clicking target_id leaves focus, caret, selection, and preedit untouched.
text_edit_click_id :: proc(
	te: ^Text_Edit_State,
	window: ^sdl.Window,
	font: ^Font,
	frame: dagda.Frame,
	cfg: Editable_Text_Config,
	target_id: dagda.Object_Id,
	click_x: f32,
	targets: []dagda.Object_Id = nil,
) -> bool {
	if !text_edit_is_target(cfg, targets, target_id) {
		return false
	}
	if te.focused && te.active_id != target_id && dagda.is_composing(&te.session) {
		return false
	}
	el, found := dagda.find(frame, target_id)
	if !found {
		return false
	}
	changed := text_edit_focus_id(te, window, font, frame, cfg, target_id, targets)
	if dagda.cancel_composition(&te.session) {
		changed = true
	}
	if font != nil && font.loaded {
		text_x, _, px := text_edit_layout(frame, el.bounds)
		offset := font_hit_test_caret(font, el.text, px, click_x - text_x)
		if te.session.caret != offset || te.session.anchor != offset {
			te.session.caret = offset
			te.session.anchor = offset
			changed = true
		}
	}
	text_edit_update_ime_area(te, window, font, frame, cfg)
	return changed
}

text_edit_click :: proc(
	te: ^Text_Edit_State,
	window: ^sdl.Window,
	font: ^Font,
	frame: dagda.Frame,
	cfg: Editable_Text_Config,
	click_x: f32,
	targets: []dagda.Object_Id = nil,
) -> bool {
	return text_edit_click_id(te, window, font, frame, cfg, text_edit_default_target(cfg, targets), click_x, targets)
}

text_edit_blur :: proc(te: ^Text_Edit_State, window: ^sdl.Window) -> bool {
	if !te.focused {
		return false
	}
	_ = dagda.cancel_composition(&te.session)
	te.focused = false
	te.active_id = 0
	if window != nil {
		_ = sdl.StopTextInput(window)
	}
	return true
}

text_edit_reconcile :: proc(
	te: ^Text_Edit_State,
	window: ^sdl.Window,
	font: ^Font,
	frame: dagda.Frame,
	cfg: Editable_Text_Config,
	targets: []dagda.Object_Id = nil,
) {
	if !te.focused {
		return
	}
	if !text_edit_is_target(cfg, targets, te.active_id) {
		_ = text_edit_blur(te, window)
		return
	}
	el, found := dagda.find(frame, te.active_id)
	if !found {
		_ = text_edit_blur(te, window)
		return
	}
	if !dagda.is_composing(&te.session) {
		dagda.text_session_sync(&te.session, el.text)
	}
	text_edit_update_ime_area(te, window, font, frame, cfg)
}

text_edit_apply_committed :: proc(
	te: ^Text_Edit_State,
	window: ^sdl.Window,
	font: ^Font,
	frame: dagda.Frame,
	cfg: Editable_Text_Config,
	edit: ^dagda.Text_Edit,
) {
	if el, found := dagda.find(frame, te.active_id); found {
		dagda.apply_edit(&te.session, edit^, el.text)
		text_edit_update_ime_area(te, window, font, frame, cfg)
	}
	dagda.edit_destroy(&te.session, edit)
}

rune_offset_to_bytes :: proc(s: string, rune_count: int) -> int {
	if rune_count <= 0 {
		return 0
	}
	seen := 0
	for _, byte_idx in s {
		if seen == rune_count {
			return byte_idx
		}
		seen += 1
	}
	return len(s)
}

@(private="package")
Clipboard_Get_Proc :: #type proc(ctx: rawptr, allocator := context.allocator) -> (text: string, ok: bool)

@(private="package")
Clipboard_Set_Proc :: #type proc(ctx: rawptr, text: string) -> bool

@(private="package")
Clipboard :: struct {
	ctx: rawptr,
	get: Clipboard_Get_Proc,
	set: Clipboard_Set_Proc,
}

@(private="package")
Memory_Clipboard :: struct {
	text:      string,
	allocator: mem.Allocator,
}

@(private="package")
memory_clipboard_set :: proc(ctx: rawptr, text: string) -> bool {
	mc := (^Memory_Clipboard)(ctx)
	if mc == nil {
		return false
	}
	alloc := mc.allocator.procedure != nil ? mc.allocator : context.allocator
	cloned, err := strings.clone(text, alloc)
	if err != nil {
		return false
	}
	delete(mc.text, alloc)
	mc.text = cloned
	mc.allocator = alloc
	return true
}

@(private="package")
memory_clipboard_get :: proc(ctx: rawptr, allocator := context.allocator) -> (string, bool) {
	mc := (^Memory_Clipboard)(ctx)
	if mc == nil || len(mc.text) == 0 {
		return "", false
	}
	cloned, err := strings.clone(mc.text, allocator)
	if err != nil {
		return "", false
	}
	return cloned, true
}

@(private="package")
memory_clipboard_destroy :: proc(mc: ^Memory_Clipboard) {
	if mc == nil {
		return
	}
	alloc := mc.allocator.procedure != nil ? mc.allocator : context.allocator
	delete(mc.text, alloc)
	mc^ = {}
}

@(private="package")
memory_clipboard_interface :: proc(mc: ^Memory_Clipboard) -> Clipboard {
	return {
		ctx = mc,
		get = memory_clipboard_get,
		set = memory_clipboard_set,
	}
}

@(private="package")
clipboard_set :: proc(cb: Clipboard, text: string) -> bool {
	if cb.set != nil {
		return cb.set(cb.ctx, text)
	}
	cstr, err := strings.clone_to_cstring(text)
	if err != nil {
		return false
	}
	defer delete(cstr)
	return sdl.SetClipboardText(cstr)
}

@(private="package")
clipboard_get :: proc(cb: Clipboard, allocator := context.allocator) -> (string, bool) {
	if cb.get != nil {
		return cb.get(cb.ctx, allocator)
	}
	if !sdl.HasClipboardText() {
		return "", false
	}
	raw := sdl.GetClipboardText()
	if raw == nil {
		return "", false
	}
	defer sdl.free(raw)
	s := string(cstring(raw))
	if len(s) == 0 {
		return "", false
	}
	cloned, err := strings.clone(s, allocator)
	if err != nil {
		return "", false
	}
	return cloned, true
}

text_edit_handle_event :: proc(
	te: ^Text_Edit_State,
	window: ^sdl.Window,
	font: ^Font,
	frame: dagda.Frame,
	cfg: Editable_Text_Config,
	user_data: rawptr,
	ev: ^sdl.Event,
	targets: []dagda.Object_Id = nil,
	clipboard: Clipboard = {},
) -> (res: Text_Edit_Result) {
	if !cfg.enabled || !te.focused {
		return {}
	}
	if !text_edit_is_target(cfg, targets, te.active_id) {
		_ = text_edit_blur(te, window)
		return {needs_redraw = true}
	}
	el, found := dagda.find(frame, te.active_id)
	if !found {
		_ = text_edit_blur(te, window)
		return {needs_redraw = true}
	}

	commit_proposal :: proc(
		te: ^Text_Edit_State,
		cfg: Editable_Text_Config,
		user_data: rawptr,
		edit: ^dagda.Text_Edit,
		clear_composition_on_accept: bool,
		res: ^Text_Edit_Result,
	) {
		if edit.err != .None {
			dagda.edit_destroy(&te.session, edit)
			res.needs_redraw = true
			return
		}
		if !edit.changed {
			if clear_composition_on_accept {
				_ = dagda.cancel_composition(&te.session)
			}
			dagda.edit_destroy(&te.session, edit)
			res.needs_redraw = true
			return
		}
		if cfg.on_commit != nil && cfg.on_commit(user_data, te.active_id, edit.text) {
			if clear_composition_on_accept {
				_ = dagda.cancel_composition(&te.session)
			}
			res.needs_rebuild = true
			res.needs_redraw = true
			res.has_pending_edit = true
			res.pending_edit = edit^
			edit^ = {}
			return
		}
		// Proposal rejected: preserve selection and any active composition for retry.
		dagda.edit_destroy(&te.session, edit)
		res.needs_redraw = true
	}

	#partial switch ev.type {
	case .TEXT_EDITING:
		preedit := ev.edit.text != nil ? string(ev.edit.text) : ""
		_ = dagda.begin_composition(&te.session, preedit, int(ev.edit.start), int(ev.edit.length))
		text_edit_update_ime_area(te, window, font, frame, cfg)
		res.consumed = true
		res.needs_redraw = true
		return res

	case .TEXT_INPUT:
		text := ev.text.text != nil ? string(ev.text.text) : ""
		// Propose replacing the selection with the IME's final text without
		// clearing composition first; clear composition only if accepted so a
		// rejected proposal preserves selection and active composition for retry.
		edit := dagda.insert_text(&te.session, el.text, text)
		commit_proposal(te, cfg, user_data, &edit, true, &res)
		if !res.needs_rebuild {
			text_edit_update_ime_area(te, window, font, frame, cfg)
		}
		res.consumed = true
		return res

	case .KEY_DOWN:
		key := ev.key.key
		mod := ev.key.mod
		shift := (mod & sdl.KMOD_SHIFT) != {}
		ctrl := (mod & sdl.KMOD_CTRL) != {}
		alt_or_gui := (mod & (sdl.KMOD_ALT | sdl.KMOD_GUI)) != {}

		if key == sdl.K_ESCAPE {
			if dagda.is_composing(&te.session) {
				_ = dagda.cancel_composition(&te.session)
				text_edit_update_ime_area(te, window, font, frame, cfg)
				res.needs_redraw = true
			}
			res.consumed = true
			return res
		}

		// While composing, swallow Enter and editing/navigation keys so the IME
		// delivers its final committed text once via TEXT_INPUT.
		if dagda.is_composing(&te.session) {
			res.consumed = true
			return res
		}

		if key == sdl.K_RETURN || key == sdl.K_KP_ENTER {
			res.consumed = true
			return res
		}

		if ctrl && !shift && !alt_or_gui && key == sdl.K_A {
			dagda.select_all(&te.session, el.text)
			text_edit_update_ime_area(te, window, font, frame, cfg)
			res.consumed = true
			res.needs_redraw = true
			return res
		}

		if ctrl && !shift && !alt_or_gui && key == sdl.K_C {
			start, end := dagda.selection_bounds(&te.session)
			start = clamp(start, 0, len(el.text))
			end = clamp(end, start, len(el.text))
			if start < end {
				_ = clipboard_set(clipboard, el.text[start:end])
			}
			res.consumed = true
			return res
		}

		if ctrl && !shift && !alt_or_gui && key == sdl.K_V {
			clip_alloc := te.session.allocator.procedure != nil ? te.session.allocator : context.allocator
			if pasted, ok := clipboard_get(clipboard, clip_alloc); ok {
				defer delete(pasted, clip_alloc)
				if len(pasted) > 0 {
					edit := dagda.insert_text(&te.session, el.text, pasted)
					commit_proposal(te, cfg, user_data, &edit, false, &res)
					if !res.needs_rebuild {
						text_edit_update_ime_area(te, window, font, frame, cfg)
					}
				}
			}
			res.consumed = true
			return res
		}

		if ctrl && !shift && !alt_or_gui && !ev.key.repeat && key == sdl.K_Z {
			if cfg.on_undo != nil && cfg.on_undo(user_data, te.active_id) {
				res.needs_rebuild = true
				res.needs_redraw = true
			}
			res.consumed = true
			return res
		}

		if !ctrl && !alt_or_gui {
			switch key {
			case sdl.K_LEFT:
				dagda.move_left(&te.session, el.text, shift)
				text_edit_update_ime_area(te, window, font, frame, cfg)
				res.consumed = true
				res.needs_redraw = true
				return res
			case sdl.K_RIGHT:
				dagda.move_right(&te.session, el.text, shift)
				text_edit_update_ime_area(te, window, font, frame, cfg)
				res.consumed = true
				res.needs_redraw = true
				return res
			case sdl.K_HOME:
				dagda.move_home(&te.session, shift)
				text_edit_update_ime_area(te, window, font, frame, cfg)
				res.consumed = true
				res.needs_redraw = true
				return res
			case sdl.K_END:
				dagda.move_end(&te.session, el.text, shift)
				text_edit_update_ime_area(te, window, font, frame, cfg)
				res.consumed = true
				res.needs_redraw = true
				return res
			case sdl.K_BACKSPACE:
				edit := dagda.backspace(&te.session, el.text)
				commit_proposal(te, cfg, user_data, &edit, false, &res)
				res.consumed = true
				return res
			case sdl.K_DELETE:
				edit := dagda.delete_forward(&te.session, el.text)
				commit_proposal(te, cfg, user_data, &edit, false, &res)
				res.consumed = true
				return res
			}
		}

	case .WINDOW_FOCUS_LOST:
		if dagda.cancel_composition(&te.session) {
			text_edit_update_ime_area(te, window, font, frame, cfg)
			res.needs_redraw = true
		}
		return res
	}

	return {}
}

// text_edit_draw paints an editable label using text_edit_layout (the same
// origin and font height used by font_hit_test_caret), with selection highlight,
// live IME preedit underline, and visible caret bar when focused.
text_edit_draw :: proc(
	h: ^Host,
	bounds: dagda.Rect,
	committed: string,
	focused: bool,
) {
	r := h.renderer
	box := sdl.FRect{x = bounds.x, y = bounds.y, w = bounds.width, h = bounds.height}
	tx, ty, px := text_edit_layout(h.frame, bounds)

	if !focused {
		sdl.SetRenderDrawColor(r, 31, 36, 47, 255)
		sdl.RenderFillRect(r, &box)
		sdl.SetRenderDrawColor(r, 56, 65, 84, 255)
		sdl.RenderRect(r, &box)
		if len(committed) > 0 {
			font_draw_text(&h.font, r, committed, tx, ty, px, sdl.Color{240, 244, 250, 255})
		}
		return
	}

	sdl.SetRenderDrawColor(r, 34, 41, 56, 255)
	sdl.RenderFillRect(r, &box)
	sdl.SetRenderDrawColor(r, 108, 178, 255, 255)
	sdl.RenderRect(r, &box)
	inner := sdl.FRect{x = box.x + 1, y = box.y + 1, w = max(box.w - 2, 0), h = max(box.h - 2, 0)}
	sdl.RenderRect(r, &inner)

	caret_h := px + 6

	sel_start, sel_end := dagda.selection_bounds(&h.text_edit.session)
	sel_start = clamp(sel_start, 0, len(committed))
	sel_end = clamp(sel_end, sel_start, len(committed))
	prefix := committed[:sel_start]
	selected := committed[sel_start:sel_end]
	suffix := committed[sel_end:]

	prefix_w := font_measure_width(&h.font, prefix, px)

	if dagda.is_composing(&h.text_edit.session) {
		preedit := h.text_edit.session.preedit
		preedit_w := font_measure_width(&h.font, preedit, px)
		pre_x := tx + prefix_w

		// Preedit highlight background + underline.
		pre_bg := sdl.FRect{x = pre_x - 2, y = ty - 3, w = max(preedit_w + 4, 6), h = caret_h}
		sdl.SetRenderDrawColor(r, 62, 78, 118, 255)
		sdl.RenderFillRect(r, &pre_bg)

		underline := sdl.FRect{x = pre_x, y = ty + px + 2, w = max(preedit_w, 6), h = 2}
		sdl.SetRenderDrawColor(r, 255, 206, 84, 255)
		sdl.RenderFillRect(r, &underline)

		if len(prefix) > 0 {
			font_draw_text(&h.font, r, prefix, tx, ty, px, sdl.Color{240, 244, 250, 255})
		}
		if len(preedit) > 0 {
			font_draw_text(&h.font, r, preedit, pre_x, ty, px, sdl.Color{255, 244, 196, 255})
		}
		if len(suffix) > 0 {
			font_draw_text(&h.font, r, suffix, pre_x + preedit_w, ty, px, sdl.Color{240, 244, 250, 255})
		}
	} else {
		if len(selected) > 0 {
			sel_w := font_measure_width(&h.font, selected, px)
			sel_rect := sdl.FRect{x = tx + prefix_w, y = ty - 3, w = sel_w, h = caret_h}
			sdl.SetRenderDrawColor(r, 58, 108, 190, 255)
			sdl.RenderFillRect(r, &sel_rect)
		}
		if len(committed) > 0 {
			font_draw_text(&h.font, r, committed, tx, ty, px, sdl.Color{240, 244, 250, 255})
		}
	}

	caret_x := text_edit_caret_x(&h.text_edit, &h.font, h.frame, bounds, committed)
	caret_rect := sdl.FRect{x = caret_x, y = ty - 3, w = 2, h = caret_h}
	sdl.SetRenderDrawColor(r, 255, 206, 84, 255)
	sdl.RenderFillRect(r, &caret_rect)
}

// copy_to_cstr_buf copies s into a NUL-terminated fixed buffer for SDL_PushEvent.
copy_to_cstr_buf :: proc(buf: []u8, s: string) -> (cstring, bool) {
	if len(s) + 1 > len(buf) {
		return nil, false
	}
	if len(s) > 0 {
		copy(buf[:len(s)], s)
	}
	buf[len(s)] = 0
	return cstring(raw_data(buf)), true
}

push_sdl_preedit :: proc(h: ^Host, text: string) -> bool {
	cstr, ok := copy_to_cstr_buf(h.edit_cstr_buf[:], text)
	if !ok {
		return false
	}
	ev: sdl.Event
	ev.type = .TEXT_EDITING
	ev.edit.windowID = sdl.GetWindowID(h.window)
	ev.edit.text = cstr
	ev.edit.start = 0
	ev.edit.length = c.int(utf8.rune_count_in_string(text))
	return sdl.PushEvent(&ev)
}

push_sdl_text_input :: proc(h: ^Host, text: string) -> bool {
	cstr, ok := copy_to_cstr_buf(h.text_cstr_buf[:], text)
	if !ok {
		return false
	}
	ev: sdl.Event
	ev.type = .TEXT_INPUT
	ev.text.windowID = sdl.GetWindowID(h.window)
	ev.text.text = cstr
	return sdl.PushEvent(&ev)
}
