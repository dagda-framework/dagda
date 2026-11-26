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

// Text_Version_Handler (App.text_version_of) supplies an
// optional opaque version
// for an editable field's committed text. The version is
// app-owned bookkeeping (a document revision is the obvious
// choice): the host only stores the value captured with a
// composition snapshot, compares it with the value belonging
// to a later frame, and hands both to the remap callback.
// ok=false means the field is unversioned, in which case
// only byte changes invoke the mapper. Version zero is a
// valid version whenever ok is true.
Text_Version_Handler :: #type proc(user_data: rawptr, field_id: dagda.Object_Id) -> (version: u64, ok: bool)

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
	focused:         bool,
	active_id:       dagda.Object_Id,
	dragging:        bool,
	drag_target_id:  dagda.Object_Id,
	has_preferred_x: bool,
	preferred_x:     f32,
	scroll_offsets:  map[dagda.Object_Id][2]f32,
	session:         dagda.Text_Session,
	// Session-owned snapshot of the composing field's
	// committed text, cloned at composition start and
	// advanced only after a successful remap. It keeps the
	// old bytes alive when the app builder replaces its own
	// storage, and is released when composition ends.
	composition_snapshot:     string,
	has_composition_snapshot: bool,
	snapshot_allocator:       mem.Allocator,
	// Opaque app version captured with the snapshot, when
	// the field is versioned. Advanced together with the
	// snapshot text after a successful remap.
	snapshot_version:     u64,
	has_snapshot_version: bool,
}

text_edit_snapshot_clear :: proc(te: ^Text_Edit_State) {
	if te.has_composition_snapshot {
		delete(te.composition_snapshot, te.snapshot_allocator)
		te.composition_snapshot = ""
		te.has_composition_snapshot = false
		te.snapshot_version = 0
		te.has_snapshot_version = false
	}
}

text_edit_snapshot_set :: proc(te: ^Text_Edit_State, text: string) -> bool {
	alloc := te.session.allocator
	cloned, err := strings.clone(text, alloc)
	if err != nil || (len(text) > 0 && len(cloned) != len(text)) {
		delete(cloned, alloc)
		return false
	}
	text_edit_snapshot_clear(te)
	te.composition_snapshot = cloned
	te.has_composition_snapshot = true
	te.snapshot_allocator = alloc
	return true
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

text_edit_is_multiline :: proc(
	cfg: Editable_Text_Config,
	targets: []dagda.Object_Id,
	multiline_targets: []dagda.Object_Id,
	id: dagda.Object_Id,
) -> bool {
	if !text_edit_is_target(cfg, targets, id) || len(multiline_targets) == 0 {
		return false
	}
	for mid in multiline_targets {
		if mid == id {
			return true
		}
	}
	return false
}

Line_Span :: struct {
	start: int,
	end:   int,
}

text_edit_line_count :: proc(s: string) -> int {
	return strings.count(s, "\n") + 1
}

text_edit_line_index_at :: proc(s: string, offset: int) -> int {
	pos := clamp(offset, 0, len(s))
	line := 0
	for i in 0 ..< pos {
		if s[i] == '\n' {
			line += 1
		}
	}
	return line
}

text_edit_line_span :: proc(s: string, target_line: int) -> (span: Line_Span, ok: bool) {
	if target_line < 0 {
		return {}, false
	}
	line := 0
	start := 0
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\n' {
			if line == target_line {
				return {start = start, end = i}, true
			}
			line += 1
			start = i + 1
		}
	}
	if line == target_line {
		return {start = start, end = len(s)}, true
	}
	return {}, false
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

TEXT_EDIT_CARET_WIDTH :: f32(2)

// text_edit_visible_rect intersects rect with the fitted canvas bounds when
// frame.has_canvas is true, returning the actually visible window-space rect
// of an editable field.
text_edit_visible_rect :: proc(frame: dagda.Frame, rect: dagda.Rect) -> dagda.Rect {
	if !frame.has_canvas {
		return rect
	}
	t := frame.transform
	fitted_x0 := t.offset.x
	fitted_y0 := t.offset.y
	fitted_x1 := t.offset.x + t.canvas.width * t.scale
	fitted_y1 := t.offset.y + t.canvas.height * t.scale
	x0 := max(rect.x, fitted_x0)
	y0 := max(rect.y, fitted_y0)
	x1 := min(rect.x + rect.width, fitted_x1)
	y1 := min(rect.y + rect.height, fitted_y1)
	return {
		x      = x0,
		y      = y0,
		width  = max(x1 - x0, 0),
		height = max(y1 - y0, 0),
	}
}

// text_edit_layout returns the exact rendered text origin and pixel height
// shared by painting, click/drag hit-testing, scrolling, and IME candidate
// placement, sized to the actually visible field interior.
text_edit_layout :: proc(frame: dagda.Frame, rect: dagda.Rect) -> (text_x: f32, text_y: f32, px: f32) {
	text_scale: f32 = frame.has_canvas ? clamp(frame.transform.scale, 0.4, 2.0) : 1.0
	px = max(24 * text_scale, 12)
	pad_x := max(16 * text_scale, 10)
	vis := text_edit_visible_rect(frame, rect)
	pad := min(pad_x, max((vis.width - TEXT_EDIT_CARET_WIDTH) * 0.5, 0))
	text_x = vis.x + pad
	text_y = rect.y + (rect.height - px) * 0.5
	return
}

// text_edit_view_width returns the horizontal visible text width inside the
// actually visible field interior of rect.
text_edit_view_width :: proc(frame: dagda.Frame, rect: dagda.Rect) -> f32 {
	text_scale: f32 = frame.has_canvas ? clamp(frame.transform.scale, 0.4, 2.0) : 1.0
	pad_x := max(16 * text_scale, 10)
	vis := text_edit_visible_rect(frame, rect)
	pad := min(pad_x, max((vis.width - TEXT_EDIT_CARET_WIDTH) * 0.5, 0))
	return max(vis.width - 2 * pad, 0)
}

// text_edit_multiline_layout returns the shared top-aligned line geometry for
// multiline painting, click/drag hit-testing, vertical navigation, scrolling,
// and IME candidate placement.
text_edit_multiline_layout :: proc(frame: dagda.Frame, rect: dagda.Rect) -> (
	text_x: f32,
	first_line_y: f32,
	px: f32,
	line_h: f32,
	view_w: f32,
	view_h: f32,
) {
	text_scale: f32 = frame.has_canvas ? clamp(frame.transform.scale, 0.4, 2.0) : 1.0
	px = max(24 * text_scale, 12)
	line_h = math.ceil(px * 1.35)
	pad_x := max(16 * text_scale, 10)
	pad_y := max(12 * text_scale, 8)
	vis := text_edit_visible_rect(frame, rect)
	pad := min(pad_x, max((vis.width - TEXT_EDIT_CARET_WIDTH) * 0.5, 0))
	pad_top := min(pad_y, max((vis.height - line_h) * 0.5, 0))
	text_x = vis.x + pad
	first_line_y = vis.y + pad_top
	view_w = max(vis.width - 2 * pad, 0)
	view_h = max(vis.height - 2 * pad_top, 0)
	return
}

text_edit_scroll_x :: proc(te: ^Text_Edit_State, id: dagda.Object_Id) -> f32 {
	if te == nil {
		return 0
	}
	v := te.scroll_offsets[id]
	return v[0]
}

text_edit_scroll_y :: proc(te: ^Text_Edit_State, id: dagda.Object_Id) -> f32 {
	if te == nil {
		return 0
	}
	v := te.scroll_offsets[id]
	return v[1]
}

text_edit_content_metrics :: proc(
	te: ^Text_Edit_State,
	font: ^Font,
	frame: dagda.Frame,
	bounds: dagda.Rect,
	committed: string,
	is_active: bool,
	multiline := false,
) -> (content_w: f32, caret_content_x: f32, total_lines: int, caret_line: int) {
	total_lines = 1
	caret_line = 0
	if font == nil || !font.loaded {
		return 0, 0, 1, 0
	}
	_, _, px := text_edit_layout(frame, bounds)
	if !multiline {
		if is_active && te != nil && dagda.is_composing(&te.session) {
			sel_start, sel_end := dagda.selection_bounds(&te.session)
			sel_start = clamp(sel_start, 0, len(committed))
			sel_end = clamp(sel_end, sel_start, len(committed))
			prefix_w := font_measure_width(font, committed[:sel_start], px)
			preedit_w := font_measure_width(font, te.session.preedit, px)
			suffix_w := font_measure_width(font, committed[sel_end:], px)
			caret_bytes := text_edit_preedit_caret_bytes(&te.session)
			caret_pre_w := font_measure_width(font, te.session.preedit[:caret_bytes], px)
			return prefix_w + preedit_w + suffix_w, prefix_w + caret_pre_w, 1, 0
		}
		content_w = font_measure_width(font, committed, px)
		if is_active && te != nil {
			caret_off := clamp(te.session.caret, 0, len(committed))
			caret_content_x = font_measure_width(font, committed[:caret_off], px)
		}
		return content_w, caret_content_x, 1, 0
	}

	// Multiline metrics: measure max visual line width, total visual lines,
	// and caret (x, line) using the exact same line decomposition as drawing.
	composing := is_active && te != nil && dagda.is_composing(&te.session)
	sel_start, sel_end := 0, 0
	if composing {
		sel_start, sel_end = dagda.selection_bounds(&te.session)
		sel_start = clamp(sel_start, 0, len(committed))
		sel_end = clamp(sel_end, sel_start, len(committed))
	}
	start_line := composing ? text_edit_line_index_at(committed, sel_start) : -1
	end_line := composing ? text_edit_line_index_at(committed, sel_end) : -1

	raw_lines := text_edit_line_count(committed)
	total_lines = composing ? (raw_lines - (end_line - start_line)) : raw_lines
	if total_lines < 1 {
		total_lines = 1
	}

	line_idx := 0
	line_start := 0
	for {
		rel_nl := strings.index_byte(committed[line_start:], '\n')
		line_end := rel_nl >= 0 ? line_start + rel_nl : len(committed)

		if composing {
			if line_idx == start_line {
				end_line_end := dagda.line_end_offset(committed, sel_end)
				prefix_w := font_measure_width(font, committed[line_start:sel_start], px)
				preedit_w := font_measure_width(font, te.session.preedit, px)
				suffix_w := font_measure_width(font, committed[sel_end:end_line_end], px)
				content_w = max(content_w, prefix_w + preedit_w + suffix_w)
				caret_bytes := text_edit_preedit_caret_bytes(&te.session)
				caret_content_x = prefix_w + font_measure_width(font, te.session.preedit[:caret_bytes], px)
				caret_line = start_line
			} else if line_idx < start_line || line_idx > end_line {
				lw := font_measure_width(font, committed[line_start:line_end], px)
				content_w = max(content_w, lw)
			}
		} else {
			lw := font_measure_width(font, committed[line_start:line_end], px)
			content_w = max(content_w, lw)
		}

		if rel_nl < 0 {
			break
		}
		line_start = line_end + 1
		line_idx += 1
	}

	if is_active && te != nil && !composing {
		caret_off := clamp(te.session.caret, 0, len(committed))
		caret_line = text_edit_line_index_at(committed, caret_off)
		ls := dagda.line_start_offset(committed, caret_off)
		caret_content_x = font_measure_width(font, committed[ls:caret_off], px)
	}
	return content_w, caret_content_x, total_lines, caret_line
}

text_edit_clamped_scroll_2d :: proc(
	te: ^Text_Edit_State,
	font: ^Font,
	frame: dagda.Frame,
	id: dagda.Object_Id,
	bounds: dagda.Rect,
	committed: string,
	is_active: bool,
	multiline := false,
) -> (scroll_x: f32, scroll_y: f32) {
	if font == nil || !font.loaded {
		return 0, 0
	}
	content_w, _, total_lines, _ := text_edit_content_metrics(te, font, frame, bounds, committed, is_active, multiline)
	if !multiline {
		view_w := text_edit_view_width(frame, bounds)
		max_scroll_x := max(content_w + TEXT_EDIT_CARET_WIDTH - view_w, 0)
		return clamp(text_edit_scroll_x(te, id), 0, max_scroll_x), 0
	}
	_, _, _, line_h, view_w, view_h := text_edit_multiline_layout(frame, bounds)
	max_scroll_x := max(content_w + TEXT_EDIT_CARET_WIDTH - view_w, 0)
	max_scroll_y := max(f32(total_lines) * line_h - view_h, 0)
	return clamp(text_edit_scroll_x(te, id), 0, max_scroll_x), clamp(text_edit_scroll_y(te, id), 0, max_scroll_y)
}

text_edit_clamped_scroll :: proc(
	te: ^Text_Edit_State,
	font: ^Font,
	frame: dagda.Frame,
	id: dagda.Object_Id,
	bounds: dagda.Rect,
	committed: string,
	is_active: bool,
) -> f32 {
	sx, _ := text_edit_clamped_scroll_2d(te, font, frame, id, bounds, committed, is_active, false)
	return sx
}

text_edit_sync_scroll :: proc(
	te: ^Text_Edit_State,
	font: ^Font,
	frame: dagda.Frame,
	cfg: Editable_Text_Config,
	targets: []dagda.Object_Id = nil,
	multiline_targets: []dagda.Object_Id = nil,
) {
	if !cfg.enabled || !te.focused || font == nil || !font.loaded {
		return
	}
	el, found := dagda.find(frame, te.active_id)
	if !found {
		return
	}
	multiline := te.session.multiline || text_edit_is_multiline(cfg, targets, multiline_targets, te.active_id)
	content_w, caret_content_x, total_lines, caret_line := text_edit_content_metrics(te, font, frame, el.bounds, el.text, true, multiline)
	if !multiline {
		view_w := text_edit_view_width(frame, el.bounds)
		max_scroll := max(content_w + TEXT_EDIT_CARET_WIDTH - view_w, 0)
		scroll := clamp(text_edit_scroll_x(te, te.active_id), 0, max_scroll)
		if caret_content_x < scroll {
			scroll = caret_content_x
		} else if caret_content_x + TEXT_EDIT_CARET_WIDTH > scroll + view_w {
			scroll = caret_content_x + TEXT_EDIT_CARET_WIDTH - view_w
		}
		scroll = clamp(scroll, 0, max_scroll)
		te.scroll_offsets[te.active_id] = {scroll, 0}
		return
	}
	_, _, _, line_h, view_w, view_h := text_edit_multiline_layout(frame, el.bounds)
	max_scroll_x := max(content_w + TEXT_EDIT_CARET_WIDTH - view_w, 0)
	sx := clamp(text_edit_scroll_x(te, te.active_id), 0, max_scroll_x)
	if caret_content_x < sx {
		sx = caret_content_x
	} else if caret_content_x + TEXT_EDIT_CARET_WIDTH > sx + view_w {
		sx = caret_content_x + TEXT_EDIT_CARET_WIDTH - view_w
	}
	sx = clamp(sx, 0, max_scroll_x)

	max_scroll_y := max(f32(total_lines) * line_h - view_h, 0)
	sy := clamp(text_edit_scroll_y(te, te.active_id), 0, max_scroll_y)
	caret_top := f32(caret_line) * line_h
	caret_bot := caret_top + line_h
	if caret_top < sy {
		sy = caret_top
	} else if caret_bot > sy + view_h {
		sy = caret_bot - view_h
	}
	sy = clamp(sy, 0, max_scroll_y)
	te.scroll_offsets[te.active_id] = {sx, sy}
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

// text_edit_caret_pos computes the exact window-space (x, y) and font px height
// of the caret using the same scrolled line geometry used by text_edit_draw and
// SDL_SetTextInputArea.
text_edit_caret_pos :: proc(
	te: ^Text_Edit_State,
	font: ^Font,
	frame: dagda.Frame,
	bounds: dagda.Rect,
	committed: string,
	multiline := false,
) -> (caret_x: f32, caret_y: f32, px: f32) {
	if !multiline {
		tx, ty, single_px := text_edit_layout(frame, bounds)
		if font == nil || !font.loaded {
			return tx, ty, single_px
		}
		sx: f32 = 0
		if te != nil && te.focused {
			sx, _ = text_edit_clamped_scroll_2d(te, font, frame, te.active_id, bounds, committed, true, false)
		}
		_, caret_content_x, _, _ := text_edit_content_metrics(te, font, frame, bounds, committed, true, false)
		return tx - sx + caret_content_x, ty, single_px
	}
	tx, first_line_y, multi_px, line_h, _, _ := text_edit_multiline_layout(frame, bounds)
	if font == nil || !font.loaded {
		return tx, first_line_y, multi_px
	}
	sx, sy: f32 = 0, 0
	if te != nil && te.focused {
		sx, sy = text_edit_clamped_scroll_2d(te, font, frame, te.active_id, bounds, committed, true, true)
	}
	_, caret_content_x, _, caret_line := text_edit_content_metrics(te, font, frame, bounds, committed, true, true)
	return tx - sx + caret_content_x, first_line_y + f32(caret_line) * line_h - sy, multi_px
}

// text_edit_caret_x computes the exact window-space X coordinate of the caret
// using the same scrolled text origin and font metrics used by text_edit_draw
// and SDL_SetTextInputArea.
text_edit_caret_x :: proc(
	te: ^Text_Edit_State,
	font: ^Font,
	frame: dagda.Frame,
	bounds: dagda.Rect,
	committed: string,
) -> f32 {
	multiline := te != nil && te.session.multiline
	cx, _, _ := text_edit_caret_pos(te, font, frame, bounds, committed, multiline)
	return cx
}

text_edit_destroy :: proc(te: ^Text_Edit_State) {
	text_edit_snapshot_clear(te)
	dagda.text_session_destroy(&te.session)
	delete(te.scroll_offsets)
	te.scroll_offsets = nil
	te.focused = false
	te.active_id = 0
	te.dragging = false
	te.drag_target_id = 0
	te.has_preferred_x = false
	te.preferred_x = 0
}

text_edit_update_ime_area :: proc(
	te: ^Text_Edit_State,
	window: ^sdl.Window,
	font: ^Font,
	frame: dagda.Frame,
	cfg: Editable_Text_Config,
	targets: []dagda.Object_Id = nil,
	multiline_targets: []dagda.Object_Id = nil,
) {
	if !cfg.enabled || !te.focused {
		return
	}
	text_edit_sync_scroll(te, font, frame, cfg, targets, multiline_targets)
	if window == nil {
		return
	}
	el, found := dagda.find(frame, te.active_id)
	if !found {
		return
	}
	vis := text_edit_visible_rect(frame, el.bounds)
	multiline := te.session.multiline || text_edit_is_multiline(cfg, targets, multiline_targets, te.active_id)
	caret_x, caret_y, px := text_edit_caret_pos(te, font, frame, el.bounds, el.text, multiline)
	area: sdl.Rect
	if !multiline {
		area = sdl.Rect{
			x = c.int(math.floor(vis.x)),
			y = c.int(math.floor(vis.y)),
			w = max(c.int(math.ceil(vis.width)), 1),
			h = max(c.int(math.ceil(vis.height)), 1),
		}
	} else {
		caret_h := px + 6
		band_y := clamp(caret_y - 3, vis.y, vis.y + vis.height)
		band_h := max(min(caret_h, vis.y + vis.height - band_y), 1)
		area = sdl.Rect{
			x = c.int(math.floor(vis.x)),
			y = c.int(math.floor(band_y)),
			w = max(c.int(math.ceil(vis.width)), 1),
			h = max(c.int(math.ceil(band_h)), 1),
		}
	}
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
	multiline_targets: []dagda.Object_Id = nil,
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
	multiline := text_edit_is_multiline(cfg, targets, multiline_targets, target_id)
	was_focused := te.focused
	switched := !te.focused || te.active_id != target_id
	if switched {
		dagda.text_session_destroy(&te.session)
		dagda.text_session_init(&te.session, el.text, context.allocator, multiline)
		te.focused = true
		te.active_id = target_id
		te.dragging = false
		te.drag_target_id = 0
		te.has_preferred_x = false
		te.preferred_x = 0
		if window != nil && !was_focused {
			_ = sdl.StartTextInput(window)
		}
		text_edit_update_ime_area(te, window, font, frame, cfg, targets, multiline_targets)
	} else {
		te.session.multiline = multiline
		if !dagda.is_composing(&te.session) {
			dagda.text_session_sync(&te.session, el.text)
			text_edit_update_ime_area(te, window, font, frame, cfg, targets, multiline_targets)
		}
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
	multiline_targets: []dagda.Object_Id = nil,
) -> bool {
	return text_edit_focus_id(te, window, font, frame, cfg, text_edit_default_target(cfg, targets), targets, multiline_targets)
}

text_edit_hit_test_offset :: proc(
	font: ^Font,
	frame: dagda.Frame,
	bounds: dagda.Rect,
	text: string,
	scroll_x, scroll_y: f32,
	point_x, point_y: f32,
	multiline: bool,
) -> int {
	if font == nil || !font.loaded {
		return 0
	}
	if !multiline {
		text_x, _, px := text_edit_layout(frame, bounds)
		return font_hit_test_caret(font, text, px, point_x - (text_x - scroll_x))
	}
	text_x, first_line_y, px, line_h, _, _ := text_edit_multiline_layout(frame, bounds)
	num_lines := text_edit_line_count(text)
	raw_line := line_h > 0 ? int(math.floor((point_y - (first_line_y - scroll_y)) / line_h)) : 0
	line_idx := clamp(raw_line, 0, num_lines - 1)
	span, ok := text_edit_line_span(text, line_idx)
	if !ok {
		return len(text)
	}
	rel := font_hit_test_caret(font, text[span.start:span.end], px, point_x - (text_x - scroll_x))
	return span.start + rel
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
	extend_selection := false,
	click_y: f32 = 0,
	multiline_targets: []dagda.Object_Id = nil,
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
	multiline := text_edit_is_multiline(cfg, targets, multiline_targets, target_id)
	was_same_field := te.focused && te.active_id == target_id
	// Hit-test against the exact scroll offset currently painted for target_id
	// before focus switching can scroll to the default end caret.
	click_sx, click_sy := text_edit_clamped_scroll_2d(te, font, frame, target_id, el.bounds, el.text, was_same_field, multiline)
	changed := text_edit_focus_id(te, window, font, frame, cfg, target_id, targets, multiline_targets)
	if dagda.cancel_composition(&te.session) {
		changed = true
	}
	te.has_preferred_x = false
	if font != nil && font.loaded {
		offset := text_edit_hit_test_offset(font, frame, el.bounds, el.text, click_sx, click_sy, click_x, click_y, multiline)
		prev_caret := te.session.caret
		prev_anchor := te.session.anchor
		dagda.set_caret(&te.session, el.text, offset, extend_selection && was_same_field)
		if te.session.caret != prev_caret || te.session.anchor != prev_anchor {
			changed = true
		}
		te.scroll_offsets[target_id] = {click_sx, click_sy}
	}
	text_edit_update_ime_area(te, window, font, frame, cfg, targets, multiline_targets)
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
	click_y: f32 = 0,
	multiline_targets: []dagda.Object_Id = nil,
) -> bool {
	return text_edit_click_id(te, window, font, frame, cfg, text_edit_default_target(cfg, targets), click_x, targets, false, click_y, multiline_targets)
}

// text_edit_press_id focuses target_id, places the caret at press_x using the
// existing click-to-caret metrics, and begins mouse drag selection along
// target_id. When extend_selection is true on an already-focused field, the
// existing selection anchor is kept and only the caret moves; entering a
// different field always starts a fresh selection. While another editable
// field has an active preedit, pressing target_id leaves focus, caret,
// selection, and preedit untouched.
text_edit_press_id :: proc(
	te: ^Text_Edit_State,
	window: ^sdl.Window,
	font: ^Font,
	frame: dagda.Frame,
	cfg: Editable_Text_Config,
	target_id: dagda.Object_Id,
	press_x: f32,
	targets: []dagda.Object_Id = nil,
	extend_selection := false,
	press_y: f32 = 0,
	multiline_targets: []dagda.Object_Id = nil,
) -> (started: bool, changed: bool) {
	if !text_edit_is_target(cfg, targets, target_id) {
		return false, false
	}
	if te.focused && te.active_id != target_id && dagda.is_composing(&te.session) {
		return false, false
	}
	if _, found := dagda.find(frame, target_id); !found {
		return false, false
	}
	changed = text_edit_click_id(te, window, font, frame, cfg, target_id, press_x, targets, extend_selection, press_y, multiline_targets)
	if te.focused && te.active_id == target_id && !dagda.is_composing(&te.session) {
		te.dragging = true
		te.drag_target_id = target_id
		started = true
	}
	return started, changed
}

// text_edit_drag_move extends the selection in either direction along the
// originating field, clamping past either end and landing on grapheme
// boundaries through Text_Session.
text_edit_drag_move :: proc(
	te: ^Text_Edit_State,
	window: ^sdl.Window,
	font: ^Font,
	frame: dagda.Frame,
	cfg: Editable_Text_Config,
	move_x: f32,
	targets: []dagda.Object_Id = nil,
	move_y: f32 = 0,
	multiline_targets: []dagda.Object_Id = nil,
) -> bool {
	if !te.dragging || !te.focused || te.active_id != te.drag_target_id || dagda.is_composing(&te.session) {
		return false
	}
	if !text_edit_is_target(cfg, targets, te.drag_target_id) {
		text_edit_drag_end(te)
		return false
	}
	el, found := dagda.find(frame, te.drag_target_id)
	if !found {
		text_edit_drag_end(te)
		return false
	}
	if font == nil || !font.loaded {
		return false
	}
	multiline := te.session.multiline || text_edit_is_multiline(cfg, targets, multiline_targets, te.drag_target_id)
	vis := text_edit_visible_rect(frame, el.bounds)
	sx, sy := text_edit_clamped_scroll_2d(te, font, frame, te.drag_target_id, el.bounds, el.text, true, multiline)
	offset: int
	if !multiline {
		text_x, _, px := text_edit_layout(frame, el.bounds)
		if move_x <= vis.x {
			offset = 0
		} else if move_x >= vis.x + vis.width {
			offset = len(el.text)
		} else {
			offset = font_hit_test_caret(font, el.text, px, move_x - (text_x - sx))
		}
	} else {
		if move_y <= vis.y && move_x <= vis.x {
			offset = 0
		} else if move_y >= vis.y + vis.height && move_x >= vis.x + vis.width {
			offset = len(el.text)
		} else {
			offset = text_edit_hit_test_offset(font, frame, el.bounds, el.text, sx, sy, move_x, move_y, true)
		}
	}
	te.has_preferred_x = false
	prev_caret := te.session.caret
	prev_sx, prev_sy := sx, sy
	dagda.set_caret(&te.session, el.text, offset, true)
	text_edit_update_ime_area(te, window, font, frame, cfg, targets, multiline_targets)
	if te.session.caret != prev_caret || text_edit_scroll_x(te, te.drag_target_id) != prev_sx || text_edit_scroll_y(te, te.drag_target_id) != prev_sy {
		return true
	}
	return false
}

text_edit_drag_end :: proc(te: ^Text_Edit_State) {
	te.dragging = false
	te.drag_target_id = 0
}

text_edit_blur :: proc(te: ^Text_Edit_State, window: ^sdl.Window) -> bool {
	if !te.focused {
		return false
	}
	_ = dagda.cancel_composition(&te.session)
	text_edit_snapshot_clear(te)
	te.focused = false
	te.active_id = 0
	te.dragging = false
	te.drag_target_id = 0
	te.has_preferred_x = false
	te.preferred_x = 0
	if window != nil {
		_ = sdl.StopTextInput(window)
	}
	return true
}

text_edit_prune_scroll_offsets :: proc(
	te: ^Text_Edit_State,
	frame: dagda.Frame,
	cfg: Editable_Text_Config,
	targets: []dagda.Object_Id = nil,
) {
	if len(te.scroll_offsets) == 0 {
		return
	}
	if !cfg.enabled {
		clear(&te.scroll_offsets)
		return
	}
	stale: [dynamic]dagda.Object_Id
	defer delete(stale)
	for id in te.scroll_offsets {
		if !text_edit_is_target(cfg, targets, id) {
			append(&stale, id)
			continue
		}
		if _, found := dagda.find(frame, id); !found {
			append(&stale, id)
		}
	}
	for id in stale {
		delete_key(&te.scroll_offsets, id)
	}
}

text_edit_reconcile :: proc(
	te: ^Text_Edit_State,
	window: ^sdl.Window,
	font: ^Font,
	frame: dagda.Frame,
	cfg: Editable_Text_Config,
	targets: []dagda.Object_Id = nil,
	multiline_targets: []dagda.Object_Id = nil,
) {
	text_edit_prune_scroll_offsets(te, frame, cfg, targets)
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
	te.session.multiline = text_edit_is_multiline(cfg, targets, multiline_targets, te.active_id)
	if !dagda.is_composing(&te.session) {
		dagda.text_session_sync(&te.session, el.text)
	}
	text_edit_update_ime_area(te, window, font, frame, cfg, targets, multiline_targets)
}

text_edit_apply_committed :: proc(
	te: ^Text_Edit_State,
	window: ^sdl.Window,
	font: ^Font,
	frame: dagda.Frame,
	cfg: Editable_Text_Config,
	edit: ^dagda.Text_Edit,
	targets: []dagda.Object_Id = nil,
	multiline_targets: []dagda.Object_Id = nil,
) {
	if el, found := dagda.find(frame, te.active_id); found {
		dagda.apply_edit(&te.session, edit^, el.text)
		te.has_preferred_x = false
		text_edit_update_ime_area(te, window, font, frame, cfg, targets, multiline_targets)
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
	// C-string clipboard APIs (SDL_SetClipboardText) cannot represent embedded NUL
	// bytes without silent truncation; decline before writing to either backend.
	if strings.index_byte(text, 0) >= 0 {
		return false
	}
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

text_edit_move_vertical :: proc(
	te: ^Text_Edit_State,
	font: ^Font,
	frame: dagda.Frame,
	bounds: dagda.Rect,
	text: string,
	delta_line: int,
	extend_selection: bool,
) -> bool {
	if font == nil || !font.loaded {
		return false
	}
	_, _, px, _, _, _ := text_edit_multiline_layout(frame, bounds)
	base_off := clamp(te.session.caret, 0, len(text))
	if !extend_selection && dagda.has_selection(&te.session) {
		sel_s, sel_e := dagda.selection_bounds(&te.session)
		base_off = delta_line < 0 ? sel_s : sel_e
		te.has_preferred_x = false
	}
	cur_line := text_edit_line_index_at(text, base_off)
	if !te.has_preferred_x {
		cur_start := dagda.line_start_offset(text, base_off)
		te.preferred_x = font_measure_width(font, text[cur_start:base_off], px)
		te.has_preferred_x = true
	}
	num_lines := text_edit_line_count(text)
	target_line := cur_line + delta_line
	if target_line < 0 || target_line >= num_lines {
		if !extend_selection && dagda.has_selection(&te.session) {
			dagda.set_caret(&te.session, text, base_off, false)
			return true
		}
		return false
	}
	span, ok := text_edit_line_span(text, target_line)
	if !ok {
		return false
	}
	rel := font_hit_test_caret(font, text[span.start:span.end], px, te.preferred_x)
	dagda.set_caret(&te.session, text, span.start + rel, extend_selection)
	return true
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
	multiline_targets: []dagda.Object_Id = nil,
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
	multiline := text_edit_is_multiline(cfg, targets, multiline_targets, te.active_id)
	te.session.multiline = multiline

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
			te.has_preferred_x = false
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
		text_edit_drag_end(te)
		te.has_preferred_x = false
		was_composing := dagda.is_composing(&te.session)
		preedit := ev.edit.text != nil ? string(ev.edit.text) : ""
		begin_err := dagda.begin_composition(&te.session, preedit, int(ev.edit.start), int(ev.edit.length))
		if begin_err == .None && !was_composing && dagda.is_composing(&te.session) {
			// Establish the session-owned snapshot of the
			// committed text this composition is anchored
			// against. If it cannot be established, cancel:
			// a later final must never run against stale
			// offsets with no trustworthy old text.
			if !text_edit_snapshot_set(te, el.text) {
				_ = dagda.cancel_composition(&te.session)
				text_edit_snapshot_clear(te)
			}
		}
		text_edit_update_ime_area(te, window, font, frame, cfg, targets, multiline_targets)
		res.consumed = true
		res.needs_redraw = true
		return res

	case .TEXT_INPUT:
		te.has_preferred_x = false
		text := ev.text.text != nil ? string(ev.text.text) : ""
		// Propose replacing the selection with the IME's final text without
		// clearing composition first; clear composition only if accepted so a
		// rejected proposal preserves selection and active composition for retry.
		edit := dagda.insert_text(&te.session, el.text, text)
		commit_proposal(te, cfg, user_data, &edit, true, &res)
		if !res.needs_rebuild {
			text_edit_update_ime_area(te, window, font, frame, cfg, targets, multiline_targets)
		}
		res.consumed = true
		return res

	case .KEY_DOWN:
		key := ev.key.key
		mod := ev.key.mod
		shift := (mod & sdl.KMOD_SHIFT) != {}
		ctrl := has_primary_modifier(mod)
		alt_or_gui := (mod & (sdl.KMOD_ALT | non_primary_modifier())) != {}

		if key == sdl.K_ESCAPE {
			text_edit_drag_end(te)
			if dagda.is_composing(&te.session) {
				_ = dagda.cancel_composition(&te.session)
				text_edit_update_ime_area(te, window, font, frame, cfg, targets, multiline_targets)
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
			if multiline && !ctrl && !alt_or_gui {
				edit := dagda.insert_text(&te.session, el.text, "\n")
				commit_proposal(te, cfg, user_data, &edit, false, &res)
				if !res.needs_rebuild {
					text_edit_update_ime_area(te, window, font, frame, cfg, targets, multiline_targets)
				}
			}
			res.consumed = true
			return res
		}

		if ctrl && !shift && !alt_or_gui && key == sdl.K_A {
			te.has_preferred_x = false
			dagda.select_all(&te.session, el.text)
			text_edit_update_ime_area(te, window, font, frame, cfg, targets, multiline_targets)
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

		if ctrl && !shift && !alt_or_gui && key == sdl.K_X {
			if !ev.key.repeat {
				start, end := dagda.selection_bounds(&te.session)
				start = clamp(start, 0, len(el.text))
				end = clamp(end, start, len(el.text))
				if start < end {
					edit := dagda.replace_range(&te.session, el.text, start, end, "")
					if edit.err == .None && edit.changed {
						if clipboard_set(clipboard, el.text[start:end]) {
							commit_proposal(te, cfg, user_data, &edit, false, &res)
							if !res.needs_rebuild {
								text_edit_update_ime_area(te, window, font, frame, cfg, targets, multiline_targets)
							}
						} else {
							dagda.edit_destroy(&te.session, &edit)
						}
					} else {
						dagda.edit_destroy(&te.session, &edit)
					}
				}
			}
			res.consumed = true
			return res
		}

		if ctrl && !shift && !alt_or_gui && key == sdl.K_V {
			clip_alloc := te.session.allocator.procedure != nil ? te.session.allocator : context.allocator
			if pasted, ok := clipboard_get(clipboard, clip_alloc); ok {
				defer delete(pasted, clip_alloc)
				if len(pasted) > 0 {
					to_insert := pasted
					normalized := ""
					if multiline {
						norm, norm_ok := dagda.normalize_multiline_newlines(pasted, clip_alloc)
						if !norm_ok {
							res.consumed = true
							return res
						}
						normalized = norm
						to_insert = normalized
					}
					defer if len(normalized) > 0 { delete(normalized, clip_alloc) }
					edit := dagda.insert_text(&te.session, el.text, to_insert)
					commit_proposal(te, cfg, user_data, &edit, false, &res)
					if !res.needs_rebuild {
						text_edit_update_ime_area(te, window, font, frame, cfg, targets, multiline_targets)
					}
				}
			}
			res.consumed = true
			return res
		}

		if ctrl && !shift && !alt_or_gui && !ev.key.repeat && key == sdl.K_Z {
			if cfg.on_undo != nil && cfg.on_undo(user_data, te.active_id) {
				te.has_preferred_x = false
				res.needs_rebuild = true
				res.needs_redraw = true
			}
			res.consumed = true
			return res
		}

		if !ctrl && !alt_or_gui {
			switch key {
			case sdl.K_LEFT:
				te.has_preferred_x = false
				dagda.move_left(&te.session, el.text, shift)
				text_edit_update_ime_area(te, window, font, frame, cfg, targets, multiline_targets)
				res.consumed = true
				res.needs_redraw = true
				return res
			case sdl.K_RIGHT:
				te.has_preferred_x = false
				dagda.move_right(&te.session, el.text, shift)
				text_edit_update_ime_area(te, window, font, frame, cfg, targets, multiline_targets)
				res.consumed = true
				res.needs_redraw = true
				return res
			case sdl.K_UP:
				if multiline {
					_ = text_edit_move_vertical(te, font, frame, el.bounds, el.text, -1, shift)
					text_edit_update_ime_area(te, window, font, frame, cfg, targets, multiline_targets)
					res.consumed = true
					res.needs_redraw = true
					return res
				}
			case sdl.K_DOWN:
				if multiline {
					_ = text_edit_move_vertical(te, font, frame, el.bounds, el.text, 1, shift)
					text_edit_update_ime_area(te, window, font, frame, cfg, targets, multiline_targets)
					res.consumed = true
					res.needs_redraw = true
					return res
				}
			case sdl.K_HOME:
				te.has_preferred_x = false
				dagda.move_line_home(&te.session, el.text, shift)
				text_edit_update_ime_area(te, window, font, frame, cfg, targets, multiline_targets)
				res.consumed = true
				res.needs_redraw = true
				return res
			case sdl.K_END:
				te.has_preferred_x = false
				dagda.move_line_end(&te.session, el.text, shift)
				text_edit_update_ime_area(te, window, font, frame, cfg, targets, multiline_targets)
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
		text_edit_drag_end(te)
		if dagda.cancel_composition(&te.session) {
			text_edit_update_ime_area(te, window, font, frame, cfg, targets, multiline_targets)
			res.needs_redraw = true
		}
		return res
	}

	return {}
}

intersect_sdl_rect :: proc(a, b: sdl.Rect) -> sdl.Rect {
	x0 := max(a.x, b.x)
	y0 := max(a.y, b.y)
	x1 := min(a.x + a.w, b.x + b.w)
	y1 := min(a.y + a.h, b.y + b.h)
	return {x = x0, y = y0, w = max(x1 - x0, 0), h = max(y1 - y0, 0)}
}

// text_edit_draw paints an editable label using text_edit_layout and its
// per-field horizontal scroll offset (clipped to the field interior), with
// selection highlight, live IME preedit underline, and visible caret bar when focused.
text_edit_draw :: proc(
	h: ^Host,
	id: dagda.Object_Id,
	bounds: dagda.Rect,
	committed: string,
	focused: bool,
	scale_x: f32 = 1.0,
	scale_y: f32 = 1.0,
) {
	r := h.renderer
	box := sdl.FRect{x = bounds.x, y = bounds.y, w = bounds.width, h = bounds.height}
	box_px := scale_frect(box, scale_x, scale_y)
	tx, ty, px := text_edit_layout(h.frame, bounds)

	if !focused {
		sdl.SetRenderDrawColor(r, 31, 36, 47, 255)
		sdl.RenderFillRect(r, &box_px)
		sdl.SetRenderDrawColor(r, 56, 65, 84, 255)
		sdl.RenderRect(r, &box_px)
	} else {
		sdl.SetRenderDrawColor(r, 34, 41, 56, 255)
		sdl.RenderFillRect(r, &box_px)
		sdl.SetRenderDrawColor(r, 108, 178, 255, 255)
		sdl.RenderRect(r, &box_px)
		inner_px := scale_frect(sdl.FRect{x = box.x + 1, y = box.y + 1, w = max(box.w - 2, 0), h = max(box.h - 2, 0)}, scale_x, scale_y)
		sdl.RenderRect(r, &inner_px)
	}

	// Renderer scale is (1, 1) so clip rects operate directly in exact physical
	// output pixels and restoring prev_clip preserves odd canvas edges verbatim.
	prev_clip_enabled := sdl.RenderClipEnabled(r)
	prev_clip: sdl.Rect
	if prev_clip_enabled {
		_ = sdl.GetRenderClipRect(r, &prev_clip)
	}
	cx0 := c.int(math.floor((bounds.x + 2) * scale_x))
	cy0 := c.int(math.floor((bounds.y + 2) * scale_y))
	cx1 := c.int(math.ceil((bounds.x + bounds.width - 2) * scale_x))
	cy1 := c.int(math.ceil((bounds.y + bounds.height - 2) * scale_y))
	inner_clip := sdl.Rect{x = cx0, y = cy0, w = max(cx1 - cx0, 0), h = max(cy1 - cy0, 0)}
	if prev_clip_enabled {
		inner_clip = intersect_sdl_rect(prev_clip, inner_clip)
	}
	_ = sdl.SetRenderClipRect(r, &inner_clip)
	defer _ = sdl.SetRenderClipRect(r, prev_clip_enabled ? &prev_clip : nil)

	multiline := text_edit_is_multiline(h.app.text_edit, h.app.editable_text_targets, h.app.multiline_text_targets, id)

	if !multiline {
		if !focused {
			scroll := text_edit_clamped_scroll(&h.text_edit, &h.font, h.frame, id, bounds, committed, false)
			draw_x := tx - scroll
			if len(committed) > 0 {
				font_draw_text(&h.font, r, committed, draw_x, ty, px, sdl.Color{240, 244, 250, 255}, scale_x, scale_y)
			}
			return
		}

		text_edit_sync_scroll(&h.text_edit, &h.font, h.frame, h.app.text_edit, h.app.editable_text_targets, h.app.multiline_text_targets)
		scroll := text_edit_clamped_scroll(&h.text_edit, &h.font, h.frame, id, bounds, committed, true)
		draw_x := tx - scroll

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
			pre_x := draw_x + prefix_w

			// Preedit highlight background + underline.
			pre_bg := scale_frect(sdl.FRect{x = pre_x - 2, y = ty - 3, w = max(preedit_w + 4, 6), h = caret_h}, scale_x, scale_y)
			sdl.SetRenderDrawColor(r, 62, 78, 118, 255)
			sdl.RenderFillRect(r, &pre_bg)

			underline := scale_frect(sdl.FRect{x = pre_x, y = ty + px + 2, w = max(preedit_w, 6), h = 2}, scale_x, scale_y)
			sdl.SetRenderDrawColor(r, 255, 206, 84, 255)
			sdl.RenderFillRect(r, &underline)

			if len(prefix) > 0 {
				font_draw_text(&h.font, r, prefix, draw_x, ty, px, sdl.Color{240, 244, 250, 255}, scale_x, scale_y)
			}
			if len(preedit) > 0 {
				font_draw_text(&h.font, r, preedit, pre_x, ty, px, sdl.Color{255, 244, 196, 255}, scale_x, scale_y)
			}
			if len(suffix) > 0 {
				font_draw_text(&h.font, r, suffix, pre_x + preedit_w, ty, px, sdl.Color{240, 244, 250, 255}, scale_x, scale_y)
			}
		} else {
			if len(selected) > 0 {
				sel_w := font_measure_width(&h.font, selected, px)
				sel_rect := scale_frect(sdl.FRect{x = draw_x + prefix_w, y = ty - 3, w = sel_w, h = caret_h}, scale_x, scale_y)
				sdl.SetRenderDrawColor(r, 58, 108, 190, 255)
				sdl.RenderFillRect(r, &sel_rect)
			}
			if len(committed) > 0 {
				font_draw_text(&h.font, r, committed, draw_x, ty, px, sdl.Color{240, 244, 250, 255}, scale_x, scale_y)
			}
		}

		caret_x := text_edit_caret_x(&h.text_edit, &h.font, h.frame, bounds, committed)
		caret_rect := scale_frect(sdl.FRect{x = caret_x, y = ty - 3, w = TEXT_EDIT_CARET_WIDTH, h = caret_h}, scale_x, scale_y)
		sdl.SetRenderDrawColor(r, 255, 206, 84, 255)
		sdl.RenderFillRect(r, &caret_rect)
		return
	}

	// Multiline painting: top-aligned lines clipped to the field interior,
	// sharing layout, scroll, selection, preedit, and caret coordinates.
	mtx, first_line_y, mpx, line_h, _, _ := text_edit_multiline_layout(h.frame, bounds)
	vis := text_edit_visible_rect(h.frame, bounds)
	if focused {
		text_edit_sync_scroll(&h.text_edit, &h.font, h.frame, h.app.text_edit, h.app.editable_text_targets, h.app.multiline_text_targets)
	}
	sx, sy := text_edit_clamped_scroll_2d(&h.text_edit, &h.font, h.frame, id, bounds, committed, focused, true)
	draw_x := mtx - sx
	caret_h := mpx + 6

	composing := focused && dagda.is_composing(&h.text_edit.session)
	sel_start, sel_end := 0, 0
	if focused {
		sel_start, sel_end = dagda.selection_bounds(&h.text_edit.session)
		sel_start = clamp(sel_start, 0, len(committed))
		sel_end = clamp(sel_end, sel_start, len(committed))
	}
	pre_start_line := composing ? text_edit_line_index_at(committed, sel_start) : -1
	pre_end_line := composing ? text_edit_line_index_at(committed, sel_end) : -1

	visual_line := 0
	line_idx := 0
	line_start := 0
	for {
		rel_nl := strings.index_byte(committed[line_start:], '\n')
		line_end := rel_nl >= 0 ? line_start + rel_nl : len(committed)

		if !(composing && line_idx > pre_start_line && line_idx <= pre_end_line) {
			line_y := first_line_y + f32(visual_line) * line_h - sy
			visual_line += 1

			// Skip offscreen lines without shaping or drawing glyphs.
			if line_y + caret_h >= vis.y && line_y - 3 <= vis.y + vis.height {
				if composing && line_idx == pre_start_line {
					end_line_end := dagda.line_end_offset(committed, sel_end)
					prefix := committed[line_start:sel_start]
					preedit := h.text_edit.session.preedit
					suffix := committed[sel_end:end_line_end]
					prefix_w := font_measure_width(&h.font, prefix, mpx)
					preedit_w := font_measure_width(&h.font, preedit, mpx)
					pre_x := draw_x + prefix_w

					pre_bg := scale_frect(sdl.FRect{x = pre_x - 2, y = line_y - 3, w = max(preedit_w + 4, 6), h = caret_h}, scale_x, scale_y)
					sdl.SetRenderDrawColor(r, 62, 78, 118, 255)
					sdl.RenderFillRect(r, &pre_bg)

					underline := scale_frect(sdl.FRect{x = pre_x, y = line_y + mpx + 2, w = max(preedit_w, 6), h = 2}, scale_x, scale_y)
					sdl.SetRenderDrawColor(r, 255, 206, 84, 255)
					sdl.RenderFillRect(r, &underline)

					if len(prefix) > 0 {
						font_draw_text(&h.font, r, prefix, draw_x, line_y, mpx, sdl.Color{240, 244, 250, 255}, scale_x, scale_y)
					}
					if len(preedit) > 0 {
						font_draw_text(&h.font, r, preedit, pre_x, line_y, mpx, sdl.Color{255, 244, 196, 255}, scale_x, scale_y)
					}
					if len(suffix) > 0 {
						font_draw_text(&h.font, r, suffix, pre_x + preedit_w, line_y, mpx, sdl.Color{240, 244, 250, 255}, scale_x, scale_y)
					}
				} else {
					if focused && !composing && sel_start < sel_end && sel_end > line_start && sel_start <= line_end {
						hl_s := clamp(sel_start, line_start, line_end)
						hl_e := clamp(sel_end, line_start, line_end)
						sel_x := draw_x + font_measure_width(&h.font, committed[line_start:hl_s], mpx)
						sel_w := font_measure_width(&h.font, committed[hl_s:hl_e], mpx)
						if sel_end > line_end {
							sel_w += max(mpx * 0.35, 6)
						}
						if sel_w > 0 {
							sel_rect := scale_frect(sdl.FRect{x = sel_x, y = line_y - 3, w = sel_w, h = caret_h}, scale_x, scale_y)
							sdl.SetRenderDrawColor(r, 58, 108, 190, 255)
							sdl.RenderFillRect(r, &sel_rect)
						}
					}

					line_text := committed[line_start:line_end]
					if len(line_text) > 0 {
						font_draw_text(&h.font, r, line_text, draw_x, line_y, mpx, sdl.Color{240, 244, 250, 255}, scale_x, scale_y)
					}
				}
			}
		}

		if rel_nl < 0 {
			break
		}
		line_start = line_end + 1
		line_idx += 1
	}

	if focused {
		caret_x, caret_y, _ := text_edit_caret_pos(&h.text_edit, &h.font, h.frame, bounds, committed, true)
		caret_rect := scale_frect(sdl.FRect{x = caret_x, y = caret_y - 3, w = TEXT_EDIT_CARET_WIDTH, h = caret_h}, scale_x, scale_y)
		sdl.SetRenderDrawColor(r, 255, 206, 84, 255)
		sdl.RenderFillRect(r, &caret_rect)
	}
}

host_clear_control_cstrs :: proc(h: ^Host) {
	if h == nil {
		return
	}
	for cstr in h.queued_control_cstrs {
		delete(cstr)
	}
	clear(&h.queued_control_cstrs)
}

push_sdl_preedit :: proc(h: ^Host, text: string) -> bool {
	cstr, err := strings.clone_to_cstring(text)
	if err != nil || cstr == nil {
		delete(cstr)
		return false
	}
	prev_len := len(h.queued_control_cstrs)
	_, append_err := append(&h.queued_control_cstrs, cstr)
	if append_err != nil || len(h.queued_control_cstrs) != prev_len + 1 {
		delete(cstr)
		return false
	}
	ev: sdl.Event
	ev.type = .TEXT_EDITING
	ev.edit.windowID = sdl.GetWindowID(h.window)
	ev.edit.text = cstr
	ev.edit.start = 0
	ev.edit.length = c.int(utf8.rune_count_in_string(text))
	if !sdl.PushEvent(&ev) {
		_ = pop(&h.queued_control_cstrs)
		delete(cstr)
		return false
	}
	return true
}

push_sdl_text_input :: proc(h: ^Host, text: string) -> bool {
	cstr, err := strings.clone_to_cstring(text)
	if err != nil || cstr == nil {
		delete(cstr)
		return false
	}
	prev_len := len(h.queued_control_cstrs)
	_, append_err := append(&h.queued_control_cstrs, cstr)
	if append_err != nil || len(h.queued_control_cstrs) != prev_len + 1 {
		delete(cstr)
		return false
	}
	ev: sdl.Event
	ev.type = .TEXT_INPUT
	ev.text.windowID = sdl.GetWindowID(h.window)
	ev.text.text = cstr
	if !sdl.PushEvent(&ev) {
		_ = pop(&h.queued_control_cstrs)
		delete(cstr)
		return false
	}
	return true
}
