package main

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import "dagda:dagda"
import sdl "vendor:sdl3"

// Editor_State owns all window-local text editing state: keyboard focus,
// selection anchor, caret byte offset, and active SDL IME preedit text.
Editor_State :: struct {
	focused:                 bool,
	window_focused:          bool,
	snapshot_id:             dagda.Object_Id,
	snapshot_revision:       dagda.Revision,
	committed_text:          string,
	caret:                   int,
	anchor:                  int,
	preedit_text:            string,
	preedit_start:           int,
	preedit_length:          int,
	composing:               bool,
	needs_redraw:            bool,
	needs_clear_composition: bool,
	commit_count:            int,
	last_status:             string,
}

editor_init :: proc(state: ^Editor_State, adapter: Model_Adapter) {
	snap := adapter_snapshot(adapter)
	state.focused = true
	state.window_focused = true
	state.snapshot_id = snap.id
	state.snapshot_revision = snap.revision
	state.committed_text = strings.clone(snap.text)
	state.caret = len(state.committed_text)
	state.anchor = state.caret
	state.preedit_text = ""
	state.preedit_start = 0
	state.preedit_length = 0
	state.composing = false
	state.needs_redraw = true
	state.needs_clear_composition = false
	state.commit_count = 0
	editor_set_status(state, "Ready")
}

editor_destroy :: proc(state: ^Editor_State) {
	delete(state.committed_text)
	state.committed_text = ""
	delete(state.preedit_text)
	state.preedit_text = ""
	delete(state.last_status)
	state.last_status = ""
}

// editor_is_composing reports whether the window currently has an active,
// uncommitted IME composition preedit.
editor_is_composing :: proc(state: ^Editor_State) -> bool {
	return state.composing
}

// editor_external_commit_gate exposes the composition check for the integration
// layer so external commits can return a retryable busy result instead of
// colliding with active composition.
editor_external_commit_gate :: proc(state: ^Editor_State) -> External_Commit_Gate {
	if state.composing {
		return .Busy_Composing
	}
	return .Ready
}

// editor_sync_from_model refreshes the window's committed text and revision
// from the backing model and marks the window for redraw without stealing or
// dropping keyboard focus.
editor_sync_from_model :: proc(state: ^Editor_State, adapter: Model_Adapter) -> bool {
	snap := adapter_snapshot(adapter)
	if snap.id == state.snapshot_id &&
	   snap.revision == state.snapshot_revision &&
	   snap.text == state.committed_text {
		return false
	}

	delete(state.committed_text)
	state.committed_text = strings.clone(snap.text)
	state.snapshot_id = snap.id
	state.snapshot_revision = snap.revision
	state.caret = clamp_utf8_boundary(state.committed_text, state.caret)
	state.anchor = clamp_utf8_boundary(state.committed_text, state.anchor)
	state.needs_redraw = true
	return true
}

editor_set_status :: proc(state: ^Editor_State, msg: string) {
	delete(state.last_status)
	state.last_status = strings.clone(msg)
}

editor_clear_preedit :: proc(state: ^Editor_State) {
	if len(state.preedit_text) > 0 {
		delete(state.preedit_text)
		state.preedit_text = ""
	}
	state.preedit_start = 0
	state.preedit_length = 0
	state.composing = false
}

editor_cancel_composition :: proc(state: ^Editor_State) -> bool {
	if !state.composing {
		return false
	}
	editor_clear_preedit(state)
	state.needs_clear_composition = true
	state.needs_redraw = true
	editor_set_status(state, "Composition cancelled")
	return true
}

selection_bounds :: proc(state: ^Editor_State) -> (start: int, end: int) {
	if state.anchor <= state.caret {
		return state.anchor, state.caret
	}
	return state.caret, state.anchor
}

has_selection :: proc(state: ^Editor_State) -> bool {
	return state.anchor != state.caret
}

clamp_utf8_boundary :: proc(s: string, offset: int) -> int {
	if offset <= 0 {
		return 0
	}
	if offset >= len(s) {
		return len(s)
	}
	i := offset
	for i > 0 && (s[i] & 0xC0) == 0x80 {
		i -= 1
	}
	return i
}

prev_rune_boundary :: proc(s: string, offset: int) -> int {
	if offset <= 0 {
		return 0
	}
	i := offset - 1
	for i > 0 && (s[i] & 0xC0) == 0x80 {
		i -= 1
	}
	return i
}

next_rune_boundary :: proc(s: string, offset: int) -> int {
	if offset >= len(s) {
		return len(s)
	}
	_, width := utf8.decode_rune_in_string(s[offset:])
	if width <= 0 {
		return min(offset + 1, len(s))
	}
	return min(offset + width, len(s))
}

editor_apply_snapshot :: proc(state: ^Editor_State, snap: Title_Snapshot) {
	delete(state.committed_text)
	state.committed_text = strings.clone(snap.text)
	state.snapshot_id = snap.id
	state.snapshot_revision = snap.revision
}

editor_commit_replacement :: proc(
	state: ^Editor_State,
	adapter: Model_Adapter,
	replacement: string,
	new_caret: int,
) -> dagda.Action_Error {
	target := dagda.Action_Target{
		id            = state.snapshot_id,
		base_revision = state.snapshot_revision,
	}
	res := adapter_commit(adapter, target, replacement)
	editor_apply_snapshot(state, res.snapshot)
	if res.err == .None {
		state.caret = clamp_utf8_boundary(state.committed_text, new_caret)
		state.anchor = state.caret
		state.commit_count += 1
		editor_set_status(state, fmt.tprintf("Committed rev %d", state.snapshot_revision))
	} else {
		state.caret = clamp_utf8_boundary(state.committed_text, state.caret)
		state.anchor = clamp_utf8_boundary(state.committed_text, state.anchor)
		editor_set_status(state, fmt.tprintf("Commit rejected: %v (synced rev %d)", res.err, state.snapshot_revision))
	}
	state.needs_redraw = true
	return res.err
}

editor_handle_text_editing :: proc(state: ^Editor_State, text: string, start: int, length: int) -> bool {
	if !state.focused {
		return false
	}
	editor_clear_preedit(state)
	if len(text) > 0 {
		state.preedit_text = strings.clone(text)
		state.preedit_start = max(start, 0)
		state.preedit_length = max(length, 0)
		state.composing = true
		editor_set_status(state, "Composing (uncommitted preedit)")
	} else {
		editor_set_status(state, "Composition ended")
	}
	state.needs_redraw = true
	return true
}

editor_handle_text_input :: proc(state: ^Editor_State, adapter: Model_Adapter, text: string) -> bool {
	if !state.focused {
		return false
	}
	editor_clear_preedit(state)
	if len(text) == 0 {
		state.needs_redraw = true
		return false
	}

	sel_start, sel_end := selection_bounds(state)
	b: strings.Builder
	strings.builder_init(&b)
	defer strings.builder_destroy(&b)
	strings.write_string(&b, state.committed_text[:sel_start])
	strings.write_string(&b, text)
	strings.write_string(&b, state.committed_text[sel_end:])

	new_caret := sel_start + len(text)
	editor_commit_replacement(state, adapter, strings.to_string(b), new_caret)
	return true
}

editor_handle_key_down :: proc(state: ^Editor_State, adapter: Model_Adapter, key: sdl.Keycode, mod: sdl.Keymod) -> bool {
	if !state.focused {
		if key == sdl.K_TAB {
			state.focused = true
			state.needs_redraw = true
			editor_set_status(state, "Title focused")
			return true
		}
		return false
	}

	if key == sdl.K_ESCAPE {
		if editor_cancel_composition(state) {
			return true
		}
		if has_selection(state) {
			state.anchor = state.caret
			state.needs_redraw = true
			return true
		}
		return false
	}

	// While an IME composition is active, protect committed text from editing keys.
	if state.composing {
		return false
	}

	ctrl := (mod & sdl.KMOD_CTRL) != {}
	shift := (mod & sdl.KMOD_SHIFT) != {}
	alt := (mod & sdl.KMOD_ALT) != {}

	if ctrl && !alt && !shift && key == sdl.K_Z {
		res := adapter_undo(adapter)
		editor_apply_snapshot(state, res.snapshot)
		if res.undone {
			state.caret = len(state.committed_text)
			state.anchor = state.caret
			editor_set_status(state, fmt.tprintf("Undo -> rev %d", state.snapshot_revision))
		} else {
			editor_set_status(state, "Nothing to undo")
		}
		state.needs_redraw = true
		return true
	}

	if ctrl && !alt && key == sdl.K_A {
		state.anchor = 0
		state.caret = len(state.committed_text)
		state.needs_redraw = true
		return true
	}

	switch key {
	case sdl.K_LEFT:
		if !shift && has_selection(state) {
			sel_start, _ := selection_bounds(state)
			state.caret = sel_start
			state.anchor = sel_start
		} else {
			state.caret = prev_rune_boundary(state.committed_text, state.caret)
			if !shift {
				state.anchor = state.caret
			}
		}
		state.needs_redraw = true
		return true

	case sdl.K_RIGHT:
		if !shift && has_selection(state) {
			_, sel_end := selection_bounds(state)
			state.caret = sel_end
			state.anchor = sel_end
		} else {
			state.caret = next_rune_boundary(state.committed_text, state.caret)
			if !shift {
				state.anchor = state.caret
			}
		}
		state.needs_redraw = true
		return true

	case sdl.K_HOME:
		state.caret = 0
		if !shift {
			state.anchor = 0
		}
		state.needs_redraw = true
		return true

	case sdl.K_END:
		state.caret = len(state.committed_text)
		if !shift {
			state.anchor = state.caret
		}
		state.needs_redraw = true
		return true

	case sdl.K_BACKSPACE:
		del_start, del_end := selection_bounds(state)
		if del_start == del_end {
			if state.caret == 0 {
				return false
			}
			del_start = prev_rune_boundary(state.committed_text, state.caret)
			del_end = state.caret
		}
		b: strings.Builder
		strings.builder_init(&b)
		defer strings.builder_destroy(&b)
		strings.write_string(&b, state.committed_text[:del_start])
		strings.write_string(&b, state.committed_text[del_end:])
		editor_commit_replacement(state, adapter, strings.to_string(b), del_start)
		return true

	case sdl.K_DELETE:
		del_start, del_end := selection_bounds(state)
		if del_start == del_end {
			if state.caret >= len(state.committed_text) {
				return false
			}
			del_start = state.caret
			del_end = next_rune_boundary(state.committed_text, state.caret)
		}
		b: strings.Builder
		strings.builder_init(&b)
		defer strings.builder_destroy(&b)
		strings.write_string(&b, state.committed_text[:del_start])
		strings.write_string(&b, state.committed_text[del_end:])
		editor_commit_replacement(state, adapter, strings.to_string(b), del_start)
		return true
	}

	return false
}

point_in_frect :: proc(x, y: f32, r: sdl.FRect) -> bool {
	return x >= r.x && x <= r.x + r.w && y >= r.y && y <= r.y + r.h
}

editor_handle_sdl_event :: proc(
	state: ^Editor_State,
	adapter: Model_Adapter,
	ev: ^sdl.Event,
	title_box: sdl.FRect,
) -> bool {
	#partial switch ev.type {
	case .TEXT_EDITING:
		text := ev.edit.text != nil ? string(ev.edit.text) : ""
		return editor_handle_text_editing(state, text, int(ev.edit.start), int(ev.edit.length))

	case .TEXT_INPUT:
		text := ev.text.text != nil ? string(ev.text.text) : ""
		return editor_handle_text_input(state, adapter, text)

	case .KEY_DOWN:
		return editor_handle_key_down(state, adapter, ev.key.key, ev.key.mod)

	case .MOUSE_BUTTON_DOWN:
		if ev.button.button == sdl.BUTTON_LEFT {
			inside := point_in_frect(ev.button.x, ev.button.y, title_box)
			if inside {
				state.focused = true
				state.needs_redraw = true
				editor_set_status(state, "Title focused")
			} else {
				if state.composing {
					editor_cancel_composition(state)
				}
				state.focused = false
				state.needs_redraw = true
				editor_set_status(state, "Title blurred")
			}
			return true
		}

	case .WINDOW_FOCUS_GAINED:
		state.window_focused = true
		state.needs_redraw = true
		return true

	case .WINDOW_FOCUS_LOST:
		state.window_focused = false
		state.needs_redraw = true
		return true
	}

	return false
}
