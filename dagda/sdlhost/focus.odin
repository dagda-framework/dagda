package sdlhost

import "dagda:dagda"
import sdl "vendor:sdl3"

// Focus_State tracks keyboard focus by stable element ID with an explicit
// has_focus flag (since Object_Id(0) is valid) plus any armed Space press.
Focus_State :: struct {
	has_focus:         bool,
	focused_id:        dagda.Object_Id,
	has_space_pending: bool,
	space_pending_id:  dagda.Object_Id,
}

is_focusable :: proc(el: dagda.Resolved_Element) -> bool {
	return .Activate in el.actions
}

focus_cancel_pending_space :: proc(f: ^Focus_State) -> bool {
	if !f.has_space_pending {
		return false
	}
	f.has_space_pending = false
	f.space_pending_id = 0
	return true
}

focus_clear :: proc(f: ^Focus_State) -> bool {
	changed := f.has_focus || f.has_space_pending
	f.has_focus = false
	f.focused_id = 0
	f.has_space_pending = false
	f.space_pending_id = 0
	return changed
}

// focus_reconcile preserves focus after a frame rebuild if the focused element
// still exists and advertises .Activate; otherwise clears it. It also cancels
// any pending Space press if the armed target disappeared or lost focus.
focus_reconcile :: proc(f: ^Focus_State, frame: dagda.Frame) -> (changed: bool) {
	if f.has_focus {
		el, found := dagda.find(frame, f.focused_id)
		if !found || !is_focusable(el) {
			f.has_focus = false
			f.focused_id = 0
			changed = true
		}
	}
	if f.has_space_pending {
		el, found := dagda.find(frame, f.space_pending_id)
		if !found || !is_focusable(el) || !f.has_focus || f.focused_id != f.space_pending_id {
			f.has_space_pending = false
			f.space_pending_id = 0
			changed = true
		}
	}
	return changed
}

// focus_step moves focus forward (backward == false) or backward (backward == true)
// through elements that advertise .Activate in declaration order, wrapping at
// either end. From no focus, forward selects the first eligible element and
// backward selects the last. Moving focus cancels any pending Space.
focus_step :: proc(f: ^Focus_State, frame: dagda.Frame, backward: bool) -> (changed: bool) {
	first_idx := -1
	last_idx := -1
	cur_idx := -1
	for el, i in frame.elements {
		if !is_focusable(el) {
			continue
		}
		if first_idx < 0 {
			first_idx = i
		}
		last_idx = i
		if f.has_focus && el.info.id == f.focused_id {
			cur_idx = i
		}
	}

	if first_idx < 0 {
		return focus_clear(f)
	}

	next_idx := first_idx
	if cur_idx < 0 {
		next_idx = backward ? last_idx : first_idx
	} else if !backward {
		next_idx = first_idx
		for i := cur_idx + 1; i < len(frame.elements); i += 1 {
			if is_focusable(frame.elements[i]) {
				next_idx = i
				break
			}
		}
	} else {
		next_idx = last_idx
		for i := cur_idx - 1; i >= 0; i -= 1 {
			if is_focusable(frame.elements[i]) {
				next_idx = i
				break
			}
		}
	}

	next_id := frame.elements[next_idx].info.id
	space_cancelled := focus_cancel_pending_space(f)
	if !f.has_focus || f.focused_id != next_id {
		f.has_focus = true
		f.focused_id = next_id
		return true
	}
	return space_cancelled
}

// focus_handle_event handles Tab, Shift+Tab, Enter, Space, and WINDOW_FOCUS_LOST.
// Keyboard activation routes through dagda.invoke to the application handler.
focus_handle_event :: proc(
	f: ^Focus_State,
	frame: dagda.Frame,
	ev: ^sdl.Event,
	handler: dagda.Action_Handler,
	user_data: rawptr,
) -> (applied: bool, needs_redraw: bool) {
	#partial switch ev.type {
	case .KEY_DOWN:
		key := ev.key.key
		mod := ev.key.mod
		shift := (mod & sdl.KMOD_SHIFT) != {}
		other_mods := (mod & (sdl.KMOD_CTRL | sdl.KMOD_ALT | sdl.KMOD_GUI)) != {}

		if key == sdl.K_TAB && !other_mods {
			if focus_step(f, frame, shift) {
				needs_redraw = true
			}
			return false, needs_redraw
		}

		if key == sdl.K_RETURN || key == sdl.K_KP_ENTER {
			if ev.key.repeat || !f.has_focus {
				return false, false
			}
			_ = focus_cancel_pending_space(f)
			if dagda.invoke(frame, f.focused_id, .Activate, handler, user_data) == .Applied {
				return true, true
			}
			return false, false
		}

		if key == sdl.K_SPACE {
			if ev.key.repeat || !f.has_focus {
				return false, false
			}
			el, found := dagda.find(frame, f.focused_id)
			if found && is_focusable(el) {
				f.has_space_pending = true
				f.space_pending_id = f.focused_id
				return false, true
			}
			return false, false
		}

	case .KEY_UP:
		if ev.key.key == sdl.K_SPACE && f.has_space_pending {
			target := f.space_pending_id
			f.has_space_pending = false
			f.space_pending_id = 0
			if f.has_focus && f.focused_id == target {
				if dagda.invoke(frame, target, .Activate, handler, user_data) == .Applied {
					return true, true
				}
			}
			return false, true
		}

	case .WINDOW_FOCUS_LOST:
		if focus_cancel_pending_space(f) {
			return false, true
		}
	}
	return false, false
}
