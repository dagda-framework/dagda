package sdlhost

import "dagda:dagda"
import sdl "vendor:sdl3"

// Pointer_Phase identifies the lifecycle stage of a canvas pointer gesture.
Pointer_Phase :: enum {
	Press,
	Move,
	Release,
	Cancel,
}

// Pointer_Event carries a canvas pointer gesture transition with a stable
// target ID (captured on press) and logical canvas coordinates.
Pointer_Event :: struct {
	phase:      Pointer_Phase,
	has_target: bool,
	target_id:  dagda.Object_Id,
	point:      dagda.Point,
}

// Pointer_Handler receives canvas pointer gesture events and returns true
// when application state changed and the host should rebuild the frame.
Pointer_Handler :: #type proc(user_data: rawptr, ev: Pointer_Event) -> bool

// Pointer_State tracks an active left-button pointer gesture in sdlhost.
Pointer_State :: struct {
	active:      bool,
	has_target:  bool,
	target_id:   dagda.Object_Id,
	press_point: dagda.Point,
	last_point:  dagda.Point,
	moved:       bool,
}

// Pointer_Result summarizes how pointer_handle_event processed an SDL event.
Pointer_Result :: struct {
	changed:         bool,
	consumed:        bool,
	cancelled:       bool,
	suppress_click:  bool,
	has_click_id:    bool,
	click_target_id: dagda.Object_Id,
}

window_to_canvas_unclamped :: proc(t: dagda.Canvas_Transform, p: dagda.Point) -> (dagda.Point, bool) {
	if t.scale <= 0 {
		return {}, false
	}
	return {x = (p.x - t.offset.x) / t.scale, y = (p.y - t.offset.y) / t.scale}, true
}

pointer_cancel :: proc(
	p: ^Pointer_State,
	handler: Pointer_Handler,
	user_data: rawptr,
) -> (cancelled: bool, changed: bool) {
	if !p.active {
		return false, false
	}
	pe := Pointer_Event{
		phase      = .Cancel,
		has_target = p.has_target,
		target_id  = p.target_id,
		point      = p.last_point,
	}
	p^ = {}
	if handler != nil {
		changed = handler(user_data, pe)
	}
	return true, changed
}

// pointer_try_activate activates target_id on release only if the exact same
// stable element ID is still under the release point and supports .Activate.
pointer_try_activate :: proc(
	frame: dagda.Frame,
	win_p: dagda.Point,
	target_id: dagda.Object_Id,
	handler: dagda.Action_Handler,
	user_data: rawptr,
) -> bool {
	hit_id, hit := dagda.hit_test(frame, win_p)
	if !hit || hit_id != target_id {
		return false
	}
	return dagda.invoke(frame, target_id, .Activate, handler, user_data) == .Applied
}

// pointer_handle_event translates SDL pointer/cancel events on a canvas frame
// into Pointer_Event callbacks with a stable target ID and logical canvas
// coordinates.
//
// On release without motion, Pointer_Result reports has_click_id=true with the
// originally pressed target's stable ID and suppress_click=false so the host
// can activate that element only if it is still under the pointer.
pointer_handle_event :: proc(
	p: ^Pointer_State,
	frame: dagda.Frame,
	ev: ^sdl.Event,
	handler: Pointer_Handler,
	user_data: rawptr,
) -> (res: Pointer_Result) {
	if !frame.has_canvas || handler == nil {
		return {}
	}

	#partial switch ev.type {
	case .MOUSE_BUTTON_DOWN:
		if ev.button.button == sdl.BUTTON_LEFT {
			win_p := dagda.Point{x = ev.button.x, y = ev.button.y}
			canvas_p, in_canvas := dagda.window_point_to_canvas(frame.transform, win_p)
			if !in_canvas {
				return {}
			}
			if p.active {
				cancelled, c := pointer_cancel(p, handler, user_data)
				res.cancelled = cancelled
				res.changed = c
			}
			id, hit := dagda.hit_test(frame, win_p)
			p.active = true
			p.has_target = hit
			p.target_id = hit ? id : 0
			p.press_point = canvas_p
			p.last_point = canvas_p
			p.moved = false
			if handler(user_data, {
				phase      = .Press,
				has_target = hit,
				target_id  = p.target_id,
				point      = canvas_p,
			}) {
				res.changed = true
			}
			res.suppress_click = true
			res.consumed = true
			return res
		}
		if ev.button.button == sdl.BUTTON_RIGHT && p.active {
			res.cancelled, res.changed = pointer_cancel(p, handler, user_data)
			res.suppress_click = true
			res.consumed = true
			return res
		}

	case .MOUSE_MOTION:
		if !p.active {
			return {}
		}
		canvas_p, ok := window_to_canvas_unclamped(frame.transform, {x = ev.motion.x, y = ev.motion.y})
		if !ok {
			res.consumed = true
			return res
		}
		if canvas_p != p.press_point {
			p.moved = true
		}
		p.last_point = canvas_p
		res.changed = handler(user_data, {
			phase      = .Move,
			has_target = p.has_target,
			target_id  = p.target_id,
			point      = canvas_p,
		})
		res.consumed = true
		return res

	case .MOUSE_BUTTON_UP:
		if ev.button.button == sdl.BUTTON_LEFT && p.active {
			canvas_p, ok := window_to_canvas_unclamped(frame.transform, {x = ev.button.x, y = ev.button.y})
			if !ok {
				canvas_p = p.last_point
			}
			if canvas_p != p.press_point {
				p.moved = true
			}
			was_moved := p.moved
			had_target := p.has_target
			target_id := p.target_id
			pe := Pointer_Event{
				phase      = .Release,
				has_target = had_target,
				target_id  = target_id,
				point      = canvas_p,
			}
			p^ = {}
			res.changed = handler(user_data, pe)
			res.consumed = true
			if !was_moved && had_target {
				res.has_click_id = true
				res.click_target_id = target_id
				res.suppress_click = false
			} else {
				res.suppress_click = true
			}
			return res
		}

	case .KEY_DOWN:
		if ev.key.key == sdl.K_ESCAPE && p.active {
			res.cancelled, res.changed = pointer_cancel(p, handler, user_data)
			res.suppress_click = true
			res.consumed = true
			return res
		}

	case .WINDOW_FOCUS_LOST:
		if p.active {
			res.cancelled, res.changed = pointer_cancel(p, handler, user_data)
			res.suppress_click = true
			res.consumed = false
			return res
		}
	}

	return {}
}
