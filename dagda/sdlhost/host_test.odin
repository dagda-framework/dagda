package sdlhost

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"
import "dagda:dagda"
import "dagda:dagda/driver"
import sdl "vendor:sdl3"

// SDL_Init / SDL_Quit are process-global and not thread-safe; serialize tests
// that initialize SDL3 when Odin runs package tests across multiple threads.
sdl_test_mu: sync.Mutex

@(test)
test_host_exits_nonzero_and_removes_socket_on_duplicate_id_rebuild :: proc(t: ^testing.T) {
	sync.mutex_guard(&sdl_test_mu)
	Dup_State :: struct {
		triggered: bool,
		elements:  [2]dagda.Element,
	}
	dup_view :: proc(user_data: rawptr) -> dagda.View {
		s := (^Dup_State)(user_data)
		if !s.triggered {
			s.elements = {
				{info = {id = 1, role = "dup.value"}, kind = .Label, text = "ok"},
				{info = {id = 2, role = "dup.trigger"}, kind = .Button, text = "Trigger"},
			}
		} else {
			s.elements = {
				{info = {id = 1, role = "dup.value"}, kind = .Label, text = "bad"},
				{info = {id = 1, role = "dup.trigger"}, kind = .Button, text = "bad"},
			}
		}
		return {elements = s.elements[:]}
	}
	dup_handle :: proc(user_data: rawptr, id: dagda.Object_Id, action: dagda.Action) -> bool {
		s := (^Dup_State)(user_data)
		if id == 2 && action == .Activate {
			s.triggered = true
			return true
		}
		return false
	}

	Client_Probe :: struct {
		sock_path:      string,
		connected:      bool,
		first_buf:      [256]u8,
		first_len:      int,
		got_second:     bool,
	}
	probe_proc :: proc(th: ^thread.Thread) {
		p := (^Client_Probe)(th.data)
		fd: posix.FD = -1
		for _ in 0 ..< 200 {
			if cfd, ok := driver.connect_unix(p.sock_path); ok {
				fd = cfd
				break
			}
			time.sleep(10 * time.Millisecond)
		}
		if fd < 0 {
			return
		}
		defer posix.close(fd)
		p.connected = true
		_ = driver.write_all(fd, "{\"op\":\"invoke\",\"id\":2,\"action\":\"activate\"}\n{\"op\":\"inspect\"}\n")
		r := driver.Line_Reader{fd = fd}
		if line1, ok1 := driver.read_line(&r); ok1 {
			n := min(len(line1), len(p.first_buf))
			copy(p.first_buf[:n], line1[:n])
			p.first_len = n
			delete(line1)
		}
		if line2, ok2 := driver.read_line(&r); ok2 {
			p.got_second = true
			delete(line2)
		}
	}

	sock_dir := fmt.tprintf("/tmp/dagda-sdlhost-dup-%d", posix.getpid())
	_ = os.make_directory(sock_dir)
	defer _ = os.remove(sock_dir)
	sock_path := fmt.tprintf("%s/dup.sock", sock_dir)

	probe := Client_Probe{sock_path = sock_path}

	th := thread.create(probe_proc)
	th.data = &probe
	thread.start(th)

	state: Dup_State
	app := App{
		title     = "Dagda — Duplicate ID Test",
		width     = 320,
		height    = 160,
		user_data = &state,
		view      = dup_view,
		handle    = dup_handle,
	}
	code := run(app, {socket_path = sock_path})
	thread.join(th)
	thread.destroy(th)

	testing.expect_value(t, probe.connected, true)
	testing.expect_value(t, code, 1)
	testing.expect_value(t, string(probe.first_buf[:probe.first_len]), `{"ok":false,"error":"Frame_Invalid"}`)
	testing.expect_value(t, probe.got_second, false)
	testing.expect_value(t, os.exists(sock_path), false)
}

@(test)
test_keyboard_focus_traversal_id_zero_activation_and_reconcile :: proc(t: ^testing.T) {
	// Fixture with two buttons (including ID 0) and a non-activatable label.
	Fixture :: struct {
		hits_zero: int,
		hits_two:  int,
		order:     int, // 0 = [btn0, lbl1, btn2], 1 = [btn2, lbl1, btn0], 2 = [lbl1, btn2], 3 = [lbl1(as label), btn0(as label)]
		elements:  [3]dagda.Element,
	}
	make_view :: proc(fx: ^Fixture) -> dagda.View {
		switch fx.order {
		case 0:
			fx.elements = {
				{info = {id = 0, role = "btn.zero"}, kind = .Button, text = "Zero"},
				{info = {id = 1, role = "lbl.status"}, kind = .Label, text = "Status"},
				{info = {id = 2, role = "btn.two"}, kind = .Button, text = "Two"},
			}
			return {elements = fx.elements[:3]}
		case 1:
			fx.elements = {
				{info = {id = 2, role = "btn.two"}, kind = .Button, text = "Two"},
				{info = {id = 1, role = "lbl.status"}, kind = .Label, text = "Status"},
				{info = {id = 0, role = "btn.zero"}, kind = .Button, text = "Zero"},
			}
			return {elements = fx.elements[:3]}
		case 2:
			fx.elements[0] = {info = {id = 1, role = "lbl.status"}, kind = .Label, text = "Status"}
			fx.elements[1] = {info = {id = 2, role = "btn.two"}, kind = .Button, text = "Two"}
			return {elements = fx.elements[:2]}
		case 3:
			// ID 2 becomes a Label (no longer supports .Activate).
			fx.elements[0] = {info = {id = 1, role = "lbl.status"}, kind = .Label, text = "Status"}
			fx.elements[1] = {info = {id = 2, role = "btn.two"}, kind = .Label, text = "Disabled"}
			return {elements = fx.elements[:2]}
		}
		return {}
	}
	handle :: proc(user_data: rawptr, id: dagda.Object_Id, action: dagda.Action) -> bool {
		fx := (^Fixture)(user_data)
		if action != .Activate {
			return false
		}
		if id == 0 {
			fx.hits_zero += 1
			return true
		}
		if id == 2 {
			fx.hits_two += 1
			return true
		}
		return false
	}

	key_ev :: proc(type: sdl.EventType, key: sdl.Keycode, mod: sdl.Keymod = {}, repeat := false) -> sdl.Event {
		ev: sdl.Event
		ev.type = type
		ev.key.key = key
		ev.key.mod = mod
		ev.key.repeat = repeat
		return ev
	}

	fx: Fixture
	frame, ok := dagda.resolve(make_view(&fx), {width = 320, height = 200})
	testing.expect(t, ok)
	defer dagda.frame_destroy(&frame)

	f: Focus_State
	testing.expect_value(t, f.has_focus, false)

	// From no focus: Shift+Tab selects last eligible (ID 2).
	ev := key_ev(.KEY_DOWN, sdl.K_TAB, sdl.KMOD_LSHIFT)
	_, redraw := focus_handle_event(&f, frame, &ev, handle, &fx)
	testing.expect_value(t, redraw, true)
	testing.expect_value(t, f.has_focus, true)
	testing.expect_value(t, f.focused_id, dagda.Object_Id(2))

	// Reset to no focus: Tab selects first eligible (ID 0 — valid!).
	_ = focus_clear(&f)
	ev = key_ev(.KEY_DOWN, sdl.K_TAB)
	_, redraw = focus_handle_event(&f, frame, &ev, handle, &fx)
	testing.expect_value(t, redraw, true)
	testing.expect_value(t, f.has_focus, true)
	testing.expect_value(t, f.focused_id, dagda.Object_Id(0))

	// Tab skips Label (ID 1) and lands on ID 2; next Tab wraps back to ID 0.
	ev = key_ev(.KEY_DOWN, sdl.K_TAB)
	_, _ = focus_handle_event(&f, frame, &ev, handle, &fx)
	testing.expect_value(t, f.focused_id, dagda.Object_Id(2))
	_, _ = focus_handle_event(&f, frame, &ev, handle, &fx)
	testing.expect_value(t, f.focused_id, dagda.Object_Id(0))

	// Shift+Tab from first eligible wraps to last eligible (ID 2), then back to ID 0.
	ev = key_ev(.KEY_DOWN, sdl.K_TAB, sdl.KMOD_LSHIFT)
	_, _ = focus_handle_event(&f, frame, &ev, handle, &fx)
	testing.expect_value(t, f.focused_id, dagda.Object_Id(2))
	_, _ = focus_handle_event(&f, frame, &ev, handle, &fx)
	testing.expect_value(t, f.focused_id, dagda.Object_Id(0))

	// Enter activates once on initial press; repeat Enter is ignored.
	ev = key_ev(.KEY_DOWN, sdl.K_RETURN)
	applied, _ := focus_handle_event(&f, frame, &ev, handle, &fx)
	testing.expect_value(t, applied, true)
	testing.expect_value(t, fx.hits_zero, 1)

	ev = key_ev(.KEY_DOWN, sdl.K_RETURN, {}, true)
	applied, _ = focus_handle_event(&f, frame, &ev, handle, &fx)
	testing.expect_value(t, applied, false)
	testing.expect_value(t, fx.hits_zero, 1)

	// Space arms on initial down (does not activate), ignores repeat, activates once on up.
	ev = key_ev(.KEY_DOWN, sdl.K_SPACE)
	applied, _ = focus_handle_event(&f, frame, &ev, handle, &fx)
	testing.expect_value(t, applied, false)
	testing.expect_value(t, f.has_space_pending, true)
	testing.expect_value(t, fx.hits_zero, 1)

	ev = key_ev(.KEY_DOWN, sdl.K_SPACE, {}, true)
	applied, _ = focus_handle_event(&f, frame, &ev, handle, &fx)
	testing.expect_value(t, applied, false)
	testing.expect_value(t, fx.hits_zero, 1)

	ev = key_ev(.KEY_UP, sdl.K_SPACE)
	applied, _ = focus_handle_event(&f, frame, &ev, handle, &fx)
	testing.expect_value(t, applied, true)
	testing.expect_value(t, f.has_space_pending, false)
	testing.expect_value(t, fx.hits_zero, 2)

	// Pending Space is cancelled when focus moves via Tab.
	ev = key_ev(.KEY_DOWN, sdl.K_SPACE)
	_, _ = focus_handle_event(&f, frame, &ev, handle, &fx)
	testing.expect_value(t, f.has_space_pending, true)
	ev = key_ev(.KEY_DOWN, sdl.K_TAB)
	_, _ = focus_handle_event(&f, frame, &ev, handle, &fx)
	testing.expect_value(t, f.has_space_pending, false)
	testing.expect_value(t, f.focused_id, dagda.Object_Id(2))
	ev = key_ev(.KEY_UP, sdl.K_SPACE)
	applied, _ = focus_handle_event(&f, frame, &ev, handle, &fx)
	testing.expect_value(t, applied, false)
	testing.expect_value(t, fx.hits_zero, 2)
	testing.expect_value(t, fx.hits_two, 0)

	// Pending Space is cancelled on WINDOW_FOCUS_LOST.
	ev = key_ev(.KEY_DOWN, sdl.K_SPACE)
	_, _ = focus_handle_event(&f, frame, &ev, handle, &fx)
	testing.expect_value(t, f.has_space_pending, true)
	lost: sdl.Event
	lost.type = .WINDOW_FOCUS_LOST
	_, _ = focus_handle_event(&f, frame, &lost, handle, &fx)
	testing.expect_value(t, f.has_space_pending, false)
	ev = key_ev(.KEY_UP, sdl.K_SPACE)
	applied, _ = focus_handle_event(&f, frame, &ev, handle, &fx)
	testing.expect_value(t, applied, false)
	testing.expect_value(t, fx.hits_two, 0)

	// Reorder elements on rebuild: focus stays on ID 0 by stable ID.
	ev = key_ev(.KEY_DOWN, sdl.K_TAB)
	_, _ = focus_handle_event(&f, frame, &ev, handle, &fx)
	testing.expect_value(t, f.focused_id, dagda.Object_Id(0))

	fx.order = 1
	dagda.frame_destroy(&frame)
	frame, ok = dagda.resolve(make_view(&fx), {width = 320, height = 200})
	testing.expect(t, ok)
	_ = focus_reconcile(&f, frame)
	testing.expect_value(t, f.has_focus, true)
	testing.expect_value(t, f.focused_id, dagda.Object_Id(0))

	// Arm Space on ID 0, then rebuild with ID 0 removed -> clears focus and cancels pending Space.
	ev = key_ev(.KEY_DOWN, sdl.K_SPACE)
	_, _ = focus_handle_event(&f, frame, &ev, handle, &fx)
	testing.expect_value(t, f.has_space_pending, true)

	fx.order = 2
	dagda.frame_destroy(&frame)
	frame, ok = dagda.resolve(make_view(&fx), {width = 320, height = 200})
	testing.expect(t, ok)
	_ = focus_reconcile(&f, frame)
	testing.expect_value(t, f.has_focus, false)
	testing.expect_value(t, f.has_space_pending, false)

	// Focus ID 2, then rebuild with ID 2 turned into a non-activatable Label -> clears focus.
	ev = key_ev(.KEY_DOWN, sdl.K_TAB)
	_, _ = focus_handle_event(&f, frame, &ev, handle, &fx)
	testing.expect_value(t, f.has_focus, true)
	testing.expect_value(t, f.focused_id, dagda.Object_Id(2))

	fx.order = 3
	dagda.frame_destroy(&frame)
	frame, ok = dagda.resolve(make_view(&fx), {width = 320, height = 200})
	testing.expect(t, ok)
	_ = focus_reconcile(&f, frame)
	testing.expect_value(t, f.has_focus, false)
}

@(test)
test_canvas_pointer_gestures_delivery_cancel_and_click_preservation :: proc(t: ^testing.T) {
	Recorder :: struct {
		events: [16]Pointer_Event,
		count:  int,
	}
	record :: proc(user_data: rawptr, ev: Pointer_Event) -> bool {
		r := (^Recorder)(user_data)
		if r.count < len(r.events) {
			r.events[r.count] = ev
			r.count += 1
		}
		return true
	}

	// 960x540 canvas fitted into 960x740 viewport: scale=1, offset=(0, 100).
	// Include Object_Id(0) to prove stable ID 0 is distinguished from no-target.
	els := [2]dagda.Canvas_Element{
		{info = {id = 0, role = "card.zero"}, kind = .Button, text = "Zero", bounds = {x = 100, y = 50, width = 200, height = 100}},
		{info = {id = 2, role = "card.two"}, kind = .Button, text = "Two", bounds = {x = 400, y = 50, width = 200, height = 100}},
	}
	frame, ok := dagda.resolve_canvas({size = {width = 960, height = 540}, elements = els[:]}, {width = 960, height = 740})
	testing.expect(t, ok)
	defer dagda.frame_destroy(&frame)

	btn_ev :: proc(type: sdl.EventType, btn: u8, x, y: f32) -> sdl.Event {
		ev: sdl.Event
		ev.type = type
		ev.button.button = btn
		ev.button.x = x
		ev.button.y = y
		return ev
	}
	mot_ev :: proc(x, y: f32) -> sdl.Event {
		ev: sdl.Event
		ev.type = .MOUSE_MOTION
		ev.motion.x = x
		ev.motion.y = y
		return ev
	}

	p: Pointer_State
	rec: Recorder

	// Letterbox press (y=20 < offset.y=100) is ignored.
	ev := btn_ev(.MOUSE_BUTTON_DOWN, sdl.BUTTON_LEFT, 150, 20)
	res := pointer_handle_event(&p, frame, &ev, record, &rec)
	testing.expect_value(t, res.changed, false)
	testing.expect_value(t, res.suppress_click, false)
	testing.expect_value(t, res.consumed, false)
	testing.expect_value(t, rec.count, 0)

	// Press + Release without motion on ID 0 preserves click with stable ID 0.
	ev = btn_ev(.MOUSE_BUTTON_DOWN, sdl.BUTTON_LEFT, 150, 180) // canvas (150, 80)
	res = pointer_handle_event(&p, frame, &ev, record, &rec)
	testing.expect_value(t, res.changed, true)
	testing.expect_value(t, res.suppress_click, true)
	testing.expect_value(t, res.consumed, true)

	ev = btn_ev(.MOUSE_BUTTON_UP, sdl.BUTTON_LEFT, 150, 180)
	res = pointer_handle_event(&p, frame, &ev, record, &rec)
	testing.expect_value(t, res.changed, true)
	testing.expect_value(t, res.suppress_click, false) // button activation preserved!
	testing.expect_value(t, res.has_click_id, true)
	testing.expect_value(t, res.click_target_id, dagda.Object_Id(0))
	testing.expect_value(t, res.consumed, true)
	testing.expect_value(t, rec.count, 2)
	testing.expect_value(t, rec.events[0].phase, Pointer_Phase.Press)
	testing.expect_value(t, rec.events[0].has_target, true)
	testing.expect_value(t, rec.events[0].target_id, dagda.Object_Id(0))
	testing.expect_value(t, rec.events[0].point, dagda.Point{x = 150, y = 80})
	testing.expect_value(t, rec.events[1].phase, Pointer_Phase.Release)
	testing.expect_value(t, rec.events[1].target_id, dagda.Object_Id(0))

	// Drag on ID 2: multiple moves keep stable target_id=2 even off-element, release suppresses click.
	rec = {}
	ev = btn_ev(.MOUSE_BUTTON_DOWN, sdl.BUTTON_LEFT, 450, 200) // canvas (450, 100)
	_ = pointer_handle_event(&p, frame, &ev, record, &rec)
	ev = mot_ev(470, 215) // canvas (470, 115)
	_ = pointer_handle_event(&p, frame, &ev, record, &rec)
	ev = mot_ev(700, 350) // canvas (700, 250) - outside card.two
	_ = pointer_handle_event(&p, frame, &ev, record, &rec)
	ev = btn_ev(.MOUSE_BUTTON_UP, sdl.BUTTON_LEFT, 700, 350)
	res = pointer_handle_event(&p, frame, &ev, record, &rec)
	testing.expect_value(t, res.suppress_click, true)
	testing.expect_value(t, res.has_click_id, false)
	testing.expect_value(t, rec.count, 4)
	testing.expect_value(t, rec.events[1].phase, Pointer_Phase.Move)
	testing.expect_value(t, rec.events[1].target_id, dagda.Object_Id(2))
	testing.expect_value(t, rec.events[1].point, dagda.Point{x = 470, y = 115})
	testing.expect_value(t, rec.events[2].phase, Pointer_Phase.Move)
	testing.expect_value(t, rec.events[2].target_id, dagda.Object_Id(2))
	testing.expect_value(t, rec.events[2].point, dagda.Point{x = 700, y = 250})
	testing.expect_value(t, rec.events[3].phase, Pointer_Phase.Release)
	testing.expect_value(t, rec.events[3].target_id, dagda.Object_Id(2))

	// Escape cancels active gesture with stable target ID and last logical point.
	rec = {}
	ev = btn_ev(.MOUSE_BUTTON_DOWN, sdl.BUTTON_LEFT, 450, 200)
	_ = pointer_handle_event(&p, frame, &ev, record, &rec)
	ev = mot_ev(500, 240) // canvas (500, 140)
	_ = pointer_handle_event(&p, frame, &ev, record, &rec)
	esc: sdl.Event
	esc.type = .KEY_DOWN
	esc.key.key = sdl.K_ESCAPE
	res = pointer_handle_event(&p, frame, &esc, record, &rec)
	testing.expect_value(t, res.changed, true)
	testing.expect_value(t, res.cancelled, true)
	testing.expect_value(t, res.consumed, true)
	testing.expect_value(t, p.active, false)
	testing.expect_value(t, rec.count, 3)
	testing.expect_value(t, rec.events[2].phase, Pointer_Phase.Cancel)
	testing.expect_value(t, rec.events[2].target_id, dagda.Object_Id(2))
	testing.expect_value(t, rec.events[2].point, dagda.Point{x = 500, y = 140})

	// WINDOW_FOCUS_LOST cancels active gesture without consuming focus event.
	rec = {}
	ev = btn_ev(.MOUSE_BUTTON_DOWN, sdl.BUTTON_LEFT, 150, 180)
	_ = pointer_handle_event(&p, frame, &ev, record, &rec)
	lost: sdl.Event
	lost.type = .WINDOW_FOCUS_LOST
	res = pointer_handle_event(&p, frame, &lost, record, &rec)
	testing.expect_value(t, res.changed, true)
	testing.expect_value(t, res.cancelled, true)
	testing.expect_value(t, res.consumed, false)
	testing.expect_value(t, p.active, false)
	testing.expect_value(t, rec.count, 2)
	testing.expect_value(t, rec.events[1].phase, Pointer_Phase.Cancel)
	testing.expect_value(t, rec.events[1].target_id, dagda.Object_Id(0))
}

@(test)
test_release_does_not_activate_replacement_button_at_identical_bounds :: proc(t: ^testing.T) {
	Swap_State :: struct {
		replaced:  bool,
		hits_orig: int,
		hits_new:  int,
		elements:  [1]dagda.Canvas_Element,
	}
	make_frame :: proc(s: ^Swap_State) -> dagda.Frame {
		id := s.replaced ? dagda.Object_Id(9) : dagda.Object_Id(2)
		s.elements[0] = {
			info   = {id = id, role = "btn.slot"},
			kind   = .Button,
			text   = s.replaced ? "Replacement" : "Original",
			bounds = {x = 100, y = 100, width = 200, height = 100},
		}
		frame, ok := dagda.resolve_canvas({size = {width = 960, height = 540}, elements = s.elements[:]}, {width = 960, height = 540})
		assert(ok)
		return frame
	}
	on_pointer :: proc(user_data: rawptr, ev: Pointer_Event) -> bool {
		s := (^Swap_State)(user_data)
		if ev.phase == .Press && ev.has_target && ev.target_id == 2 {
			// Replace button 2 with button 9 at identical bounds on press.
			s.replaced = true
			return true
		}
		return false
	}
	on_action :: proc(user_data: rawptr, id: dagda.Object_Id, action: dagda.Action) -> bool {
		s := (^Swap_State)(user_data)
		if action != .Activate {
			return false
		}
		if id == 2 {
			s.hits_orig += 1
			return true
		}
		if id == 9 {
			s.hits_new += 1
			return true
		}
		return false
	}

	s: Swap_State
	frame := make_frame(&s)
	defer dagda.frame_destroy(&frame)

	p: Pointer_State
	down: sdl.Event
	down.type = .MOUSE_BUTTON_DOWN
	down.button.button = sdl.BUTTON_LEFT
	down.button.x = 150
	down.button.y = 150
	res := pointer_handle_event(&p, frame, &down, on_pointer, &s)
	testing.expect_value(t, res.changed, true)
	testing.expect_value(t, s.replaced, true)

	// Host rebuilds frame after press callback swapped button 2 -> button 9 at identical bounds.
	dagda.frame_destroy(&frame)
	frame = make_frame(&s)

	up: sdl.Event
	up.type = .MOUSE_BUTTON_UP
	up.button.button = sdl.BUTTON_LEFT
	up.button.x = 150
	up.button.y = 150
	res = pointer_handle_event(&p, frame, &up, on_pointer, &s)
	testing.expect_value(t, res.has_click_id, true)
	testing.expect_value(t, res.click_target_id, dagda.Object_Id(2))

	// Release must NOT activate replacement button 9 (nor missing button 2).
	activated := pointer_try_activate(frame, {x = 150, y = 150}, res.click_target_id, on_action, &s)
	testing.expect_value(t, activated, false)
	testing.expect_value(t, s.hits_orig, 0)
	testing.expect_value(t, s.hits_new, 0)

	// Ordinary press+release on button 9 without replacement still activates button 9.
	res = pointer_handle_event(&p, frame, &down, on_pointer, &s)
	res = pointer_handle_event(&p, frame, &up, on_pointer, &s)
	testing.expect_value(t, res.has_click_id, true)
	testing.expect_value(t, res.click_target_id, dagda.Object_Id(9))
	activated = pointer_try_activate(frame, {x = 150, y = 150}, res.click_target_id, on_action, &s)
	testing.expect_value(t, activated, true)
	testing.expect_value(t, s.hits_new, 1)
}

@(test)
test_cancel_clears_pressed_state_and_redraws_even_when_handler_returns_false :: proc(t: ^testing.T) {
	noop_pointer :: proc(_: rawptr, _: Pointer_Event) -> bool {
		return false
	}

	els := [1]dagda.Canvas_Element{
		{info = {id = 2, role = "card"}, kind = .Button, text = "Card", bounds = {x = 100, y = 100, width = 200, height = 100}},
	}
	frame, ok := dagda.resolve_canvas({size = {width = 960, height = 540}, elements = els[:]}, {width = 960, height = 540})
	testing.expect(t, ok)
	defer dagda.frame_destroy(&frame)

	h: Host
	h.frame = frame
	h.app.on_pointer = noop_pointer

	// Press sets pressed state and starts active gesture.
	down: sdl.Event
	down.type = .MOUSE_BUTTON_DOWN
	down.button.button = sdl.BUTTON_LEFT
	down.button.x = 150
	down.button.y = 150
	h.has_pressed = true
	h.pressed_id = 2
	_ = pointer_handle_event(&h.pointer, h.frame, &down, h.app.on_pointer, nil)
	testing.expect_value(t, h.pointer.active, true)

	// Escape cancels while handler returns false (no document change): pressed cleared + redraw requested.
	h.needs_redraw = false
	esc: sdl.Event
	esc.type = .KEY_DOWN
	esc.key.key = sdl.K_ESCAPE
	res := host_handle_pointer_cancel_event(&h, &esc)
	testing.expect_value(t, res.cancelled, true)
	testing.expect_value(t, res.changed, false)
	testing.expect_value(t, h.has_pressed, false)
	testing.expect_value(t, h.pressed_id, dagda.Object_Id(0))
	testing.expect_value(t, h.needs_redraw, true)

	// Same check for WINDOW_FOCUS_LOST when cancel handler returns false.
	h.has_pressed = true
	h.pressed_id = 2
	_ = pointer_handle_event(&h.pointer, h.frame, &down, h.app.on_pointer, nil)
	h.needs_redraw = false
	lost: sdl.Event
	lost.type = .WINDOW_FOCUS_LOST
	res = host_handle_pointer_cancel_event(&h, &lost)
	testing.expect_value(t, res.cancelled, true)
	testing.expect_value(t, res.changed, false)
	testing.expect_value(t, h.has_pressed, false)
	testing.expect_value(t, h.pressed_id, dagda.Object_Id(0))
	testing.expect_value(t, h.needs_redraw, true)
}

@(test)
test_canvas_editable_text_preedit_cancel_commit_undo_and_grapheme_backspace :: proc(t: ^testing.T) {
	Text_App :: struct {
		text:     string,
		rev:      u64,
		undo:     [dynamic]string,
		elements: [1]dagda.Canvas_Element,
	}
	make_frame :: proc(s: ^Text_App) -> dagda.Frame {
		s.elements[0] = {
			info   = {id = 1, role = "slide.headline"},
			kind   = .Label,
			text   = s.text,
			bounds = {x = 80, y = 60, width = 640, height = 80},
		}
		frame, ok := dagda.resolve_canvas({size = {width = 960, height = 540}, elements = s.elements[:]}, {width = 800, height = 540})
		assert(ok)
		return frame
	}
	on_commit :: proc(user_data: rawptr, id: dagda.Object_Id, new_text: string) -> bool {
		s := (^Text_App)(user_data)
		if id != 1 || new_text == s.text {
			return false
		}
		cloned, err := strings.clone(new_text)
		if err != nil {
			return false
		}
		append(&s.undo, s.text)
		s.text = cloned
		s.rev += 1
		return true
	}
	on_undo :: proc(user_data: rawptr, id: dagda.Object_Id) -> bool {
		s := (^Text_App)(user_data)
		if id != 1 || len(s.undo) == 0 {
			return false
		}
		delete(s.text)
		s.text = pop(&s.undo)
		s.rev += 1
		return true
	}

	s := Text_App{text = strings.clone("Slide Canvas")}
	defer {
		delete(s.text)
		for u in s.undo {
			delete(u)
		}
		delete(s.undo)
	}

	cfg := Editable_Text_Config{
		enabled   = true,
		target_id = 1,
		on_commit = on_commit,
		on_undo   = on_undo,
	}
	frame := make_frame(&s)
	defer dagda.frame_destroy(&frame)

	te: Text_Edit_State
	defer text_edit_destroy(&te)

	dispatch_ev :: proc(te: ^Text_Edit_State, frame: ^dagda.Frame, s: ^Text_App, cfg: Editable_Text_Config, ev: ^sdl.Event) {
		res := text_edit_handle_event(te, nil, nil, frame^, cfg, s, ev)
		if res.needs_rebuild {
			dagda.frame_destroy(frame)
			frame^ = make_frame(s)
			if res.has_pending_edit {
				text_edit_apply_committed(te, nil, nil, frame^, cfg, &res.pending_edit)
			} else {
				text_edit_reconcile(te, nil, nil, frame^, cfg)
			}
		}
	}

	key_ev :: proc(key: sdl.Keycode, mod: sdl.Keymod = {}, repeat := false) -> sdl.Event {
		ev: sdl.Event
		ev.type = .KEY_DOWN
		ev.key.key = key
		ev.key.mod = mod
		ev.key.repeat = repeat
		return ev
	}

	// Focus headline and select "Canvas" (6 graphemes from end).
	testing.expect(t, text_edit_focus(&te, nil, nil, frame, cfg))
	for _ in 0 ..< 6 {
		ev := key_ev(sdl.K_LEFT, sdl.KMOD_LSHIFT)
		dispatch_ev(&te, &frame, &s, cfg, &ev)
	}
	sel_s, sel_e := dagda.selection_bounds(&te.session)
	testing.expect_value(t, sel_s, 6)
	testing.expect_value(t, sel_e, 12)

	// Show live preedit and cancel with Escape: text, revision, and selection stay intact.
	pre_ev: sdl.Event
	pre_ev.type = .TEXT_EDITING
	pre_ev.edit.text = "Draft"
	pre_ev.edit.start = 0
	pre_ev.edit.length = 5
	dispatch_ev(&te, &frame, &s, cfg, &pre_ev)
	testing.expect_value(t, dagda.is_composing(&te.session), true)
	testing.expect_value(t, te.session.preedit, "Draft")
	testing.expect_value(t, s.text, "Slide Canvas")
	testing.expect_value(t, s.rev, u64(0))

	esc := key_ev(sdl.K_ESCAPE)
	dispatch_ev(&te, &frame, &s, cfg, &esc)
	testing.expect_value(t, dagda.is_composing(&te.session), false)
	testing.expect_value(t, s.text, "Slide Canvas")
	testing.expect_value(t, s.rev, u64(0))
	sel_s, sel_e = dagda.selection_bounds(&te.session)
	testing.expect_value(t, sel_s, 6)
	testing.expect_value(t, sel_e, 12)

	// Compose "e", send Enter (swallowed while composing), then TEXT_INPUT "é" ->
	// selected range "Canvas" is replaced by "é" exactly once (1 rev, 1 undo).
	pre_ev.edit.text = "e"
	pre_ev.edit.length = 1
	dispatch_ev(&te, &frame, &s, cfg, &pre_ev)
	enter := key_ev(sdl.K_RETURN)
	dispatch_ev(&te, &frame, &s, cfg, &enter)
	testing.expect_value(t, dagda.is_composing(&te.session), true)
	testing.expect_value(t, s.text, "Slide Canvas")
	testing.expect_value(t, s.rev, u64(0))
	testing.expect_value(t, len(s.undo), 0)

	ti_commit: sdl.Event
	ti_commit.type = .TEXT_INPUT
	ti_commit.text.text = "é"
	dispatch_ev(&te, &frame, &s, cfg, &ti_commit)
	testing.expect_value(t, dagda.is_composing(&te.session), false)
	testing.expect_value(t, s.text, "Slide é")
	testing.expect_value(t, s.rev, u64(1))
	testing.expect_value(t, len(s.undo), 1)

	// Ctrl+Shift+Z and repeated Ctrl+Z must NOT fire undo.
	shift_undo := key_ev(sdl.K_Z, (primary_modifier() | sdl.KMOD_LSHIFT))
	dispatch_ev(&te, &frame, &s, cfg, &shift_undo)
	testing.expect_value(t, s.text, "Slide é")
	testing.expect_value(t, s.rev, u64(1))
	testing.expect_value(t, len(s.undo), 1)

	repeat_undo := key_ev(sdl.K_Z, primary_modifier(), true)
	dispatch_ev(&te, &frame, &s, cfg, &repeat_undo)
	testing.expect_value(t, s.text, "Slide é")
	testing.expect_value(t, s.rev, u64(1))
	testing.expect_value(t, len(s.undo), 1)

	// Initial Ctrl+Z undoes once -> exact original bytes "Slide Canvas".
	undo_ev := key_ev(sdl.K_Z, primary_modifier())
	dispatch_ev(&te, &frame, &s, cfg, &undo_ev)
	testing.expect_value(t, s.text, "Slide Canvas")
	testing.expect_value(t, s.rev, u64(2))
	testing.expect_value(t, len(s.undo), 0)

	// Insert decomposed é ("e\u0301", 3 UTF-8 bytes) at end, then Backspace removes it as 1 grapheme.
	end_ev := key_ev(sdl.K_END)
	dispatch_ev(&te, &frame, &s, cfg, &end_ev)
	ti: sdl.Event
	ti.type = .TEXT_INPUT
	ti.text.text = "e\u0301"
	dispatch_ev(&te, &frame, &s, cfg, &ti)
	testing.expect_value(t, s.text, "Slide Canvase\u0301")
	testing.expect_value(t, len(s.text), len("Slide Canvas") + 3)

	bs := key_ev(sdl.K_BACKSPACE)
	dispatch_ev(&te, &frame, &s, cfg, &bs)
	testing.expect_value(t, s.text, "Slide Canvas")
}

@(test)
test_canvas_editable_text_rejected_proposal_preserves_selection_and_composition :: proc(t: ^testing.T) {
	Reject_App :: struct {
		text:     string,
		rev:      u64,
		reject:   bool,
		elements: [1]dagda.Canvas_Element,
	}
	make_frame :: proc(s: ^Reject_App) -> dagda.Frame {
		s.elements[0] = {
			info   = {id = 1, role = "slide.headline"},
			kind   = .Label,
			text   = s.text,
			bounds = {x = 80, y = 60, width = 640, height = 80},
		}
		frame, ok := dagda.resolve_canvas({size = {width = 960, height = 540}, elements = s.elements[:]}, {width = 800, height = 540})
		assert(ok)
		return frame
	}
	on_commit :: proc(user_data: rawptr, id: dagda.Object_Id, new_text: string) -> bool {
		s := (^Reject_App)(user_data)
		if id != 1 || s.reject {
			return false
		}
		cloned, err := strings.clone(new_text)
		if err != nil {
			return false
		}
		delete(s.text)
		s.text = cloned
		s.rev += 1
		return true
	}

	s := Reject_App{text = strings.clone("Slide Canvas"), reject = true}
	defer delete(s.text)

	cfg := Editable_Text_Config{enabled = true, target_id = 1, on_commit = on_commit}
	frame := make_frame(&s)
	defer dagda.frame_destroy(&frame)

	te: Text_Edit_State
	defer text_edit_destroy(&te)

	testing.expect(t, text_edit_focus(&te, nil, nil, frame, cfg))
	// Select "Canvas" (bytes 6..12) and start preedit "e".
	te.session.anchor = 6
	te.session.caret = 12

	pre_ev: sdl.Event
	pre_ev.type = .TEXT_EDITING
	pre_ev.edit.text = "e"
	pre_ev.edit.start = 0
	pre_ev.edit.length = 1
	_ = text_edit_handle_event(&te, nil, nil, frame, cfg, &s, &pre_ev)
	testing.expect_value(t, dagda.is_composing(&te.session), true)

	// App rejects TEXT_INPUT "é": selection (6, 12) and active preedit "e" must survive for retry.
	ti: sdl.Event
	ti.type = .TEXT_INPUT
	ti.text.text = "é"
	res := text_edit_handle_event(&te, nil, nil, frame, cfg, &s, &ti)
	testing.expect_value(t, res.needs_rebuild, false)
	testing.expect_value(t, s.text, "Slide Canvas")
	testing.expect_value(t, s.rev, u64(0))
	testing.expect_value(t, dagda.is_composing(&te.session), true)
	testing.expect_value(t, te.session.preedit, "e")
	sel_s, sel_e := dagda.selection_bounds(&te.session)
	testing.expect_value(t, sel_s, 6)
	testing.expect_value(t, sel_e, 12)

	// Retry once app accepts: replaces "Canvas" with "é" and clears composition.
	s.reject = false
	res = text_edit_handle_event(&te, nil, nil, frame, cfg, &s, &ti)
	testing.expect_value(t, res.needs_rebuild, true)
	dagda.frame_destroy(&frame)
	frame = make_frame(&s)
	text_edit_apply_committed(&te, nil, nil, frame, cfg, &res.pending_edit)
	testing.expect_value(t, s.text, "Slide é")
	testing.expect_value(t, s.rev, u64(1))
	testing.expect_value(t, dagda.is_composing(&te.session), false)
}

@(test)
test_preedit_caret_pixel_and_sdl_text_input_area_at_two_scales :: proc(t: ^testing.T) {
	sync.mutex_guard(&sdl_test_mu)
	if !sdl.Init({.VIDEO}) {
		return
	}
	defer sdl.Quit()

	font: Font
	if !font_init(&font) {
		return
	}
	defer font_destroy(&font)

	els := [1]dagda.Canvas_Element{
		{info = {id = 1, role = "slide.headline"}, kind = .Label, text = "Slide ", bounds = {x = 80, y = 60, width = 640, height = 80}},
	}
	cfg := Editable_Text_Config{enabled = true, target_id = 1}

	viewports := [2]dagda.Size{{width = 800, height = 540}, {width = 640, height = 480}}
	for vp in viewports {
		window: ^sdl.Window
		renderer: ^sdl.Renderer
		testing.expect(t, sdl.CreateWindowAndRenderer("Caret Test", c.int(vp.width), c.int(vp.height), {}, &window, &renderer))
		defer sdl.DestroyWindow(window)
		defer sdl.DestroyRenderer(renderer)
		defer font_destroy_textures(&font)

		frame, ok := dagda.resolve_canvas({size = {width = 960, height = 540}, elements = els[:]}, vp)
		testing.expect(t, ok)
		defer dagda.frame_destroy(&frame)

		h: Host
		h.window = window
		h.renderer = renderer
		h.font = font
		h.frame = frame
		h.app.text_edit = cfg
		defer {
			font = h.font
			text_edit_destroy(&h.text_edit)
		}

		testing.expect(t, text_edit_focus(&h.text_edit, h.window, &h.font, h.frame, cfg))

		el, found := dagda.find(h.frame, 1)
		testing.expect(t, found)
		tx, ty, px := text_edit_layout(h.frame, el.bounds)
		start_x := tx + font_measure_width(&h.font, "Slide ", px)
		end_x := start_x + font_measure_width(&h.font, "café", px)

		// 1. Explicit cursor start=0, length=0: caret and SDL candidate anchor must sit at start of "café".
		pre_zero: sdl.Event
		pre_zero.type = .TEXT_EDITING
		pre_zero.edit.text = "café"
		pre_zero.edit.start = 0
		pre_zero.edit.length = 0
		_ = text_edit_handle_event(&h.text_edit, h.window, &h.font, h.frame, cfg, nil, &pre_zero)

		got_area: sdl.Rect
		got_cursor: c.int
		testing.expect(t, sdl.GetTextInputArea(h.window, &got_area, &got_cursor))
		testing.expect_value(t, got_area.x + got_cursor, c.int(math.round(start_x)))

		// Render and verify the painted amber caret pixel at the top of the caret bar (above the underline).
		host_draw(&h)
		surface := sdl.RenderReadPixels(h.renderer, nil)
		testing.expect(t, surface != nil)
		if surface != nil {
			defer sdl.DestroySurface(surface)
			caret_y := c.int(math.floor(ty - 1))
			r0, g0, b0, a0: u8
			testing.expect(t, sdl.ReadSurfacePixel(surface, c.int(math.floor(start_x)), caret_y, &r0, &g0, &b0, &a0))
			testing.expect_value(t, r0, u8(255))
			testing.expect_value(t, g0, u8(206))
			testing.expect_value(t, b0, u8(84))

			// End of "café" must NOT have the caret bar when start=0, length=0.
			r1, g1, b1, a1: u8
			testing.expect(t, sdl.ReadSurfacePixel(surface, c.int(math.floor(end_x)), caret_y, &r1, &g1, &b1, &a1))
			testing.expect(t, !(r1 == 255 && g1 == 206 && b1 == 84))
		}

		// 2. Unspecified cursor (start=-1, length=0): preserves fallback to end of "café".
		pre_unspec: sdl.Event
		pre_unspec.type = .TEXT_EDITING
		pre_unspec.edit.text = "café"
		pre_unspec.edit.start = -1
		pre_unspec.edit.length = 0
		_ = text_edit_handle_event(&h.text_edit, h.window, &h.font, h.frame, cfg, nil, &pre_unspec)

		testing.expect(t, sdl.GetTextInputArea(h.window, &got_area, &got_cursor))
		testing.expect_value(t, got_area.x + got_cursor, c.int(math.round(end_x)))
	}
}

@(test)
test_dual_undo_handlers_one_keypress_one_undo :: proc(t: ^testing.T) {
	Dual_Undo_App :: struct {
		field_undo_calls: int,
		app_undo_calls:   int,
		elements:         [2]dagda.Canvas_Element,
	}
	field_undo :: proc(user_data: rawptr, id: dagda.Object_Id) -> bool {
		a := (^Dual_Undo_App)(user_data)
		if id == 1 {
			a.field_undo_calls += 1
			return true
		}
		return false
	}
	app_undo :: proc(user_data: rawptr) -> bool {
		a := (^Dual_Undo_App)(user_data)
		a.app_undo_calls += 1
		return true
	}

	app_state := Dual_Undo_App{
		elements = {
			{info = {id = 1, role = "slide.headline"}, kind = .Label, text = "Slide Canvas", bounds = {x = 80, y = 60, width = 640, height = 80}},
			{info = {id = 2, role = "slide.card"}, kind = .Button, text = "Card", bounds = {x = 220, y = 200, width = 520, height = 220}},
		},
	}
	frame, ok := dagda.resolve_canvas({size = {width = 960, height = 540}, elements = app_state.elements[:]}, {width = 800, height = 540})
	testing.expect(t, ok)
	defer dagda.frame_destroy(&frame)

	h: Host
	h.frame = frame
	h.app = App{
		user_data = &app_state,
		on_undo   = app_undo,
		text_edit = {
			enabled   = true,
			target_id = 1,
			on_undo   = field_undo,
		},
	}
	defer text_edit_destroy(&h.text_edit)

	key_ev :: proc(key: sdl.Keycode, mod: sdl.Keymod = {}, repeat := false) -> sdl.Event {
		ev: sdl.Event
		ev.type = .KEY_DOWN
		ev.key.key = key
		ev.key.mod = mod
		ev.key.repeat = repeat
		return ev
	}

	// 1. Focus the text field: one initial Ctrl+Z calls field_undo exactly once, app_undo 0 times.
	testing.expect(t, text_edit_focus(&h.text_edit, nil, nil, h.frame, h.app.text_edit))
	ev := key_ev(sdl.K_Z, primary_modifier())
	rebuild, _, _ := host_dispatch_key_event(&h, &ev)
	testing.expect_value(t, rebuild, true)
	testing.expect_value(t, app_state.field_undo_calls, 1)
	testing.expect_value(t, app_state.app_undo_calls, 0)

	// 2. Modified/repeat Ctrl+Z while field is focused leave both callback counts unchanged.
	ev = key_ev(sdl.K_Z, (primary_modifier() | sdl.KMOD_LSHIFT))
	_, _, _ = host_dispatch_key_event(&h, &ev)
	ev = key_ev(sdl.K_Z, (primary_modifier() | non_primary_modifier()))
	_, _, _ = host_dispatch_key_event(&h, &ev)
	ev = key_ev(sdl.K_Z, primary_modifier(), true)
	_, _, _ = host_dispatch_key_event(&h, &ev)
	testing.expect_value(t, app_state.field_undo_calls, 1)
	testing.expect_value(t, app_state.app_undo_calls, 0)

	// 3. During composition, Ctrl+Z preserves the preedit and history (neither handler called).
	pre: sdl.Event
	pre.type = .TEXT_EDITING
	pre.edit.text = "café"
	pre.edit.start = 0
	pre.edit.length = 4
	_ = text_edit_handle_event(&h.text_edit, nil, nil, h.frame, h.app.text_edit, &app_state, &pre)
	testing.expect_value(t, dagda.is_composing(&h.text_edit.session), true)

	ev = key_ev(sdl.K_Z, primary_modifier())
	rebuild, _, _ = host_dispatch_key_event(&h, &ev)
	testing.expect_value(t, rebuild, false)
	testing.expect_value(t, dagda.is_composing(&h.text_edit.session), true)
	testing.expect_value(t, h.text_edit.session.preedit, "café")
	testing.expect_value(t, app_state.field_undo_calls, 1)
	testing.expect_value(t, app_state.app_undo_calls, 0)

	// Cancel composition, then Tab transfers focus to button 2 and blurs text field.
	esc := key_ev(sdl.K_ESCAPE)
	_, _, _ = host_dispatch_key_event(&h, &esc)
	testing.expect_value(t, dagda.is_composing(&h.text_edit.session), false)

	tab := key_ev(sdl.K_TAB)
	_, _, _ = host_dispatch_key_event(&h, &tab)
	testing.expect_value(t, h.text_edit.focused, false)
	testing.expect_value(t, h.focus.has_focus, true)
	testing.expect_value(t, h.focus.focused_id, dagda.Object_Id(2))

	// 4. With button focused, one initial Ctrl+Z calls app_undo exactly once, field_undo unchanged.
	ev = key_ev(sdl.K_Z, primary_modifier())
	rebuild, _, _ = host_dispatch_key_event(&h, &ev)
	testing.expect_value(t, rebuild, true)
	testing.expect_value(t, app_state.field_undo_calls, 1)
	testing.expect_value(t, app_state.app_undo_calls, 1)

	// 5. Modified/repeat Ctrl+Z with button focused leave both callback counts unchanged.
	ev = key_ev(sdl.K_Z, (primary_modifier() | sdl.KMOD_LSHIFT))
	_, _, _ = host_dispatch_key_event(&h, &ev)
	ev = key_ev(sdl.K_Z, (primary_modifier() | non_primary_modifier()))
	_, _, _ = host_dispatch_key_event(&h, &ev)
	ev = key_ev(sdl.K_Z, primary_modifier(), true)
	_, _, _ = host_dispatch_key_event(&h, &ev)
	testing.expect_value(t, app_state.field_undo_calls, 1)
	testing.expect_value(t, app_state.app_undo_calls, 1)
}

@(test)
test_two_editable_elements_shared_string_preedit_isolation_and_undo :: proc(t: ^testing.T) {
	sync.mutex_guard(&sdl_test_mu)
	if !sdl.Init({.VIDEO}) {
		return
	}
	defer sdl.Quit()

	font: Font
	if !font_init(&font) {
		return
	}
	defer font_destroy(&font)

	Shared_State :: struct {
		title:       string,
		rev:         u64,
		last_id:     dagda.Object_Id,
		undo:        [dynamic]string,
		editable:    [2]dagda.Object_Id,
		elements:    [2]dagda.Canvas_Element,
	}
	make_frame :: proc(s: ^Shared_State) -> dagda.Frame {
		s.elements = {
			{info = {id = 1, role = "outline.title"}, kind = .Label, text = s.title, bounds = {x = 80, y = 60, width = 640, height = 80}},
			{info = {id = 2, role = "canvas.title"}, kind = .Label, text = s.title, bounds = {x = 80, y = 200, width = 640, height = 80}},
		}
		frame, ok := dagda.resolve_canvas({size = {width = 960, height = 540}, elements = s.elements[:]}, {width = 800, height = 540})
		assert(ok)
		return frame
	}
	on_commit :: proc(user_data: rawptr, id: dagda.Object_Id, new_text: string) -> bool {
		s := (^Shared_State)(user_data)
		if (id != 1 && id != 2) || new_text == s.title {
			return false
		}
		cloned, err := strings.clone(new_text)
		if err != nil {
			return false
		}
		append(&s.undo, s.title)
		s.title = cloned
		s.rev += 1
		s.last_id = id
		return true
	}
	on_undo :: proc(user_data: rawptr, id: dagda.Object_Id) -> bool {
		s := (^Shared_State)(user_data)
		if (id != 1 && id != 2) || len(s.undo) == 0 {
			return false
		}
		delete(s.title)
		s.title = pop(&s.undo)
		s.rev += 1
		s.last_id = id
		return true
	}

	window: ^sdl.Window
	renderer: ^sdl.Renderer
	testing.expect(t, sdl.CreateWindowAndRenderer("Shared Text Test", 800, 540, {}, &window, &renderer))
	defer sdl.DestroyWindow(window)
	defer sdl.DestroyRenderer(renderer)
	defer font_destroy_textures(&font)

	s := Shared_State{
		title    = strings.clone("Slide Title"),
		editable = {1, 2},
	}
	defer {
		delete(s.title)
		for u in s.undo {
			delete(u)
		}
		delete(s.undo)
	}

	h: Host
	h.window = window
	h.ime_window = window
	h.renderer = renderer
	h.font = font
	h.frame = make_frame(&s)
	h.app = App{
		user_data = &s,
		text_edit = {
			enabled   = true,
			on_commit = on_commit,
			on_undo   = on_undo,
		},
		editable_text_targets = s.editable[:],
	}
	defer {
		font = h.font
		text_edit_destroy(&h.text_edit)
		dagda.frame_destroy(&h.frame)
	}

	// Verify positional Editable_Text_Config{true, 1, nil, nil} remains source-compatible.
	legacy_cfg := Editable_Text_Config{true, 1, nil, nil}
	testing.expect_value(t, text_edit_is_target(legacy_cfg, nil, 1), true)
	testing.expect_value(t, text_edit_is_target(legacy_cfg, nil, 2), false)

	// 1. Click inside element 1 after "Slide" (byte 5) and insert "!".
	el1, ok1 := dagda.find(h.frame, 1)
	testing.expect(t, ok1)
	tx1, _, px1 := text_edit_layout(h.frame, el1.bounds)
	slide_w := font_measure_width(&h.font, "Slide", px1)
	testing.expect(t, text_edit_click_id(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, 1, tx1 + slide_w, h.app.editable_text_targets))
	testing.expect_value(t, h.text_edit.active_id, dagda.Object_Id(1))
	testing.expect_value(t, h.text_edit.session.caret, 5)

	ti1: sdl.Event
	ti1.type = .TEXT_INPUT
	ti1.text.text = "!"
	res := text_edit_handle_event(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, &s, &ti1, h.app.editable_text_targets)
	testing.expect_value(t, res.needs_rebuild, true)
	dagda.frame_destroy(&h.frame)
	h.frame = make_frame(&s)
	text_edit_apply_committed(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, &res.pending_edit)
	testing.expect_value(t, s.title, "Slide! Title")
	testing.expect_value(t, s.rev, u64(1))
	testing.expect_value(t, s.last_id, dagda.Object_Id(1))

	// 2. Click inside element 2 at the start (byte 0) and start preedit "e".
	el2, ok2 := dagda.find(h.frame, 2)
	testing.expect(t, ok2)
	tx2, _, _ := text_edit_layout(h.frame, el2.bounds)
	testing.expect(t, text_edit_click_id(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, 2, tx2 - 4, h.app.editable_text_targets))
	testing.expect_value(t, h.text_edit.active_id, dagda.Object_Id(2))
	testing.expect_value(t, h.text_edit.session.caret, 0)

	pre: sdl.Event
	pre.type = .TEXT_EDITING
	pre.edit.text = "e"
	pre.edit.start = 0
	pre.edit.length = 1
	_ = text_edit_handle_event(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, &s, &pre, h.app.editable_text_targets)

	// Verify ONLY element 2 paints preedit highlight RGB(62,78,118) and element 1 has 0 preedit pixels.
	host_draw(&h)
	surface := sdl.RenderReadPixels(h.renderer, nil)
	testing.expect(t, surface != nil)
	if surface != nil {
		defer sdl.DestroySurface(surface)
		count_preedit_bg :: proc(surf: ^sdl.Surface, b: dagda.Rect) -> int {
			hits := 0
			for y := c.int(math.floor(b.y)); y < c.int(math.ceil(b.y + b.height)); y += 1 {
				for x := c.int(math.floor(b.x)); x < c.int(math.ceil(b.x + b.width)); x += 1 {
					r, g, bl, a: u8
					if sdl.ReadSurfacePixel(surf, x, y, &r, &g, &bl, &a) && r == 62 && g == 78 && bl == 118 {
						hits += 1
					}
				}
			}
			return hits
		}
		el1_now, _ := dagda.find(h.frame, 1)
		el2_now, _ := dagda.find(h.frame, 2)
		testing.expect_value(t, count_preedit_bg(surface, el1_now.bounds), 0)
		testing.expect(t, count_preedit_bg(surface, el2_now.bounds) >= 50)
	}

	// 3. Commit "é" on element 2 -> updates shared string once and reports id=2.
	ti2: sdl.Event
	ti2.type = .TEXT_INPUT
	ti2.text.text = "é"
	res = text_edit_handle_event(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, &s, &ti2, h.app.editable_text_targets)
	testing.expect_value(t, res.needs_rebuild, true)
	dagda.frame_destroy(&h.frame)
	h.frame = make_frame(&s)
	text_edit_apply_committed(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, &res.pending_edit)
	testing.expect_value(t, s.title, "éSlide! Title")
	testing.expect_value(t, s.rev, u64(2))
	testing.expect_value(t, s.last_id, dagda.Object_Id(2))

	// 4. Undo once -> restores "Slide! Title" and reports id=2.
	undo_ev: sdl.Event
	undo_ev.type = .KEY_DOWN
	undo_ev.key.key = sdl.K_Z
	undo_ev.key.mod = primary_modifier()
	rebuild, _, _ := host_dispatch_key_event(&h, &undo_ev)
	testing.expect_value(t, rebuild, true)
	testing.expect_value(t, s.title, "Slide! Title")
	testing.expect_value(t, s.rev, u64(3))
	testing.expect_value(t, s.last_id, dagda.Object_Id(2))
}

@(test)
test_click_field_b_during_field_a_preedit_keeps_composition_and_commits_to_a :: proc(t: ^testing.T) {
	State :: struct {
		title:        string,
		rev:          u64,
		commit_count: int,
		last_id:      dagda.Object_Id,
		editable:     [2]dagda.Object_Id,
		elements:     [2]dagda.Canvas_Element,
	}
	make_frame :: proc(s: ^State) -> dagda.Frame {
		s.elements = {
			{info = {id = 1, role = "outline.title"}, kind = .Label, text = s.title, bounds = {x = 80, y = 60, width = 640, height = 80}},
			{info = {id = 2, role = "canvas.title"}, kind = .Label, text = s.title, bounds = {x = 80, y = 200, width = 640, height = 80}},
		}
		frame, ok := dagda.resolve_canvas({size = {width = 960, height = 540}, elements = s.elements[:]}, {width = 800, height = 540})
		assert(ok)
		return frame
	}
	on_commit :: proc(user_data: rawptr, id: dagda.Object_Id, new_text: string) -> bool {
		s := (^State)(user_data)
		cloned, err := strings.clone(new_text)
		if err != nil {
			return false
		}
		delete(s.title)
		s.title = cloned
		s.rev += 1
		s.commit_count += 1
		s.last_id = id
		return true
	}

	s := State{title = strings.clone("Slide Title"), editable = {1, 2}}
	defer delete(s.title)

	frame := make_frame(&s)
	defer dagda.frame_destroy(&frame)

	cfg := Editable_Text_Config{true, 0, on_commit, nil}
	te: Text_Edit_State
	defer text_edit_destroy(&te)

	// Focus field A (id=1), select "Title" (6..11), and start preedit "e".
	testing.expect(t, text_edit_focus_id(&te, nil, nil, frame, cfg, 1, s.editable[:]))
	te.session.anchor = 6
	te.session.caret = 11
	pre: sdl.Event
	pre.type = .TEXT_EDITING
	pre.edit.text = "e"
	pre.edit.start = 0
	pre.edit.length = 1
	_ = text_edit_handle_event(&te, nil, nil, frame, cfg, &s, &pre, s.editable[:])
	testing.expect_value(t, dagda.is_composing(&te.session), true)

	// Click field B (id=2) while A is composing: focus, caret, selection, and preedit stay in A.
	testing.expect_value(t, text_edit_click_id(&te, nil, nil, frame, cfg, 2, 100, s.editable[:]), false)
	testing.expect_value(t, te.focused, true)
	testing.expect_value(t, te.active_id, dagda.Object_Id(1))
	testing.expect_value(t, te.session.anchor, 6)
	testing.expect_value(t, te.session.caret, 11)
	testing.expect_value(t, dagda.is_composing(&te.session), true)
	testing.expect_value(t, te.session.preedit, "e")

	// Deliver final "é": commits exactly once attributed to A (id=1).
	final_ev: sdl.Event
	final_ev.type = .TEXT_INPUT
	final_ev.text.text = "é"
	res := text_edit_handle_event(&te, nil, nil, frame, cfg, &s, &final_ev, s.editable[:])
	testing.expect_value(t, res.needs_rebuild, true)
	dagda.frame_destroy(&frame)
	frame = make_frame(&s)
	text_edit_apply_committed(&te, nil, nil, frame, cfg, &res.pending_edit)
	testing.expect_value(t, s.title, "Slide é")
	testing.expect_value(t, s.rev, u64(1))
	testing.expect_value(t, s.commit_count, 1)
	testing.expect_value(t, s.last_id, dagda.Object_Id(1))
	testing.expect_value(t, dagda.is_composing(&te.session), false)

	// After A commits, a fresh click can now focus B.
	testing.expect_value(t, text_edit_click_id(&te, nil, nil, frame, cfg, 2, 100, s.editable[:]), true)
	testing.expect_value(t, te.active_id, dagda.Object_Id(2))
}

@(test)
test_click_field_b_during_field_a_preedit_escape_then_click_b_and_text_input :: proc(t: ^testing.T) {
	State :: struct {
		title:        string,
		rev:          u64,
		commit_count: int,
		last_id:      dagda.Object_Id,
		editable:     [2]dagda.Object_Id,
		elements:     [2]dagda.Canvas_Element,
	}
	make_frame :: proc(s: ^State) -> dagda.Frame {
		s.elements = {
			{info = {id = 1, role = "outline.title"}, kind = .Label, text = s.title, bounds = {x = 80, y = 60, width = 640, height = 80}},
			{info = {id = 2, role = "canvas.title"}, kind = .Label, text = s.title, bounds = {x = 80, y = 200, width = 640, height = 80}},
		}
		frame, ok := dagda.resolve_canvas({size = {width = 960, height = 540}, elements = s.elements[:]}, {width = 800, height = 540})
		assert(ok)
		return frame
	}
	on_commit :: proc(user_data: rawptr, id: dagda.Object_Id, new_text: string) -> bool {
		s := (^State)(user_data)
		cloned, err := strings.clone(new_text)
		if err != nil {
			return false
		}
		delete(s.title)
		s.title = cloned
		s.rev += 1
		s.commit_count += 1
		s.last_id = id
		return true
	}

	s := State{title = strings.clone("Slide Title"), editable = {1, 2}}
	defer delete(s.title)

	frame := make_frame(&s)
	defer dagda.frame_destroy(&frame)

	cfg := Editable_Text_Config{true, 0, on_commit, nil}
	te: Text_Edit_State
	defer text_edit_destroy(&te)

	// Start preedit "e" in field A (id=1), then click field B (id=2).
	testing.expect(t, text_edit_focus_id(&te, nil, nil, frame, cfg, 1, s.editable[:]))
	pre: sdl.Event
	pre.type = .TEXT_EDITING
	pre.edit.text = "e"
	pre.edit.start = 0
	pre.edit.length = 1
	_ = text_edit_handle_event(&te, nil, nil, frame, cfg, &s, &pre, s.editable[:])
	testing.expect_value(t, text_edit_click_id(&te, nil, nil, frame, cfg, 2, 100, s.editable[:]), false)
	testing.expect_value(t, te.active_id, dagda.Object_Id(1))

	// Cancel with Escape: preserves revision and clears composition.
	esc: sdl.Event
	esc.type = .KEY_DOWN
	esc.key.key = sdl.K_ESCAPE
	_ = text_edit_handle_event(&te, nil, nil, frame, cfg, &s, &esc, s.editable[:])
	testing.expect_value(t, dagda.is_composing(&te.session), false)
	testing.expect_value(t, s.title, "Slide Title")
	testing.expect_value(t, s.rev, u64(0))
	testing.expect_value(t, s.commit_count, 0)

	// Click field B again -> now focuses B.
	testing.expect_value(t, text_edit_click_id(&te, nil, nil, frame, cfg, 2, 100, s.editable[:]), true)
	testing.expect_value(t, te.active_id, dagda.Object_Id(2))

	// Send TEXT_INPUT("Q") directly without any preceding keydown -> commits once under B (id=2).
	ti: sdl.Event
	ti.type = .TEXT_INPUT
	ti.text.text = "Q"
	res := text_edit_handle_event(&te, nil, nil, frame, cfg, &s, &ti, s.editable[:])
	testing.expect_value(t, res.needs_rebuild, true)
	dagda.frame_destroy(&frame)
	frame = make_frame(&s)
	text_edit_apply_committed(&te, nil, nil, frame, cfg, &res.pending_edit)
	testing.expect_value(t, s.title, "Slide TitleQ")
	testing.expect_value(t, s.rev, u64(1))
	testing.expect_value(t, s.commit_count, 1)
	testing.expect_value(t, s.last_id, dagda.Object_Id(2))
}

@(test)
test_tab_traverses_editable_fields_and_buttons_skips_passive_and_preserves_id_and_preedit :: proc(t: ^testing.T) {
	Tab_App :: struct {
		field_a:      string,
		field_b:      string,
		last_edit_id: dagda.Object_Id,
		edit_count:   int,
		btn_hits:     int,
		reordered:    bool,
		editable:     [2]dagda.Object_Id,
		elements:     [4]dagda.Canvas_Element,
	}
	make_frame :: proc(s: ^Tab_App) -> dagda.Frame {
		if !s.reordered {
			// Declaration order: passive(99), field A(0), passive? no: field A(0), passive(99), field B(2), button(3).
			s.elements = {
				{info = {id = 0, role = "field.a"}, kind = .Label, text = s.field_a, bounds = {x = 40, y = 40, width = 300, height = 50}},
				{info = {id = 99, role = "passive.lbl"}, kind = .Label, text = "Passive", bounds = {x = 40, y = 110, width = 300, height = 40}},
				{info = {id = 2, role = "field.b"}, kind = .Label, text = s.field_b, bounds = {x = 40, y = 170, width = 300, height = 50}},
				{info = {id = 3, role = "btn.go"}, kind = .Button, text = "Go", bounds = {x = 40, y = 240, width = 140, height = 50}},
			}
		} else {
			// Reordered frame: button(3), field B(2), passive(99), field A(0) — stable ID must stay focused!
			s.elements = {
				{info = {id = 3, role = "btn.go"}, kind = .Button, text = "Go", bounds = {x = 40, y = 240, width = 140, height = 50}},
				{info = {id = 2, role = "field.b"}, kind = .Label, text = s.field_b, bounds = {x = 40, y = 170, width = 300, height = 50}},
				{info = {id = 99, role = "passive.lbl"}, kind = .Label, text = "Passive", bounds = {x = 40, y = 110, width = 300, height = 40}},
				{info = {id = 0, role = "field.a"}, kind = .Label, text = s.field_a, bounds = {x = 40, y = 40, width = 300, height = 50}},
			}
		}
		frame, ok := dagda.resolve_canvas({size = {width = 960, height = 540}, elements = s.elements[:]}, {width = 800, height = 540})
		assert(ok)
		return frame
	}
	on_commit :: proc(user_data: rawptr, id: dagda.Object_Id, new_text: string) -> bool {
		s := (^Tab_App)(user_data)
		cloned, err := strings.clone(new_text)
		if err != nil {
			return false
		}
		if id == 0 {
			delete(s.field_a)
			s.field_a = cloned
		} else if id == 2 {
			delete(s.field_b)
			s.field_b = cloned
		} else {
			delete(cloned)
			return false
		}
		s.last_edit_id = id
		s.edit_count += 1
		return true
	}
	on_action :: proc(user_data: rawptr, id: dagda.Object_Id, action: dagda.Action) -> bool {
		s := (^Tab_App)(user_data)
		if id == 3 && action == .Activate {
			s.btn_hits += 1
			return true
		}
		return false
	}

	s := Tab_App{
		field_a  = strings.clone("Alpha"),
		field_b  = strings.clone("Beta"),
		editable = {0, 2}, // includes Object_Id(0)!
	}
	defer {
		delete(s.field_a)
		delete(s.field_b)
	}

	h: Host
	h.frame = make_frame(&s)
	h.app = App{
		user_data = &s,
		handle    = on_action,
		text_edit = {
			enabled   = true,
			on_commit = on_commit,
		},
		editable_text_targets = s.editable[:],
	}
	defer {
		text_edit_destroy(&h.text_edit)
		dagda.frame_destroy(&h.frame)
	}

	key_ev :: proc(key: sdl.Keycode, mod: sdl.Keymod = {}) -> sdl.Event {
		ev: sdl.Event
		ev.type = .KEY_DOWN
		ev.key.key = key
		ev.key.mod = mod
		return ev
	}
	send_text :: proc(h: ^Host, s: ^Tab_App, text: cstring) {
		ev: sdl.Event
		ev.type = .TEXT_INPUT
		ev.text.text = text
		tres := text_edit_handle_event(&h.text_edit, nil, nil, h.frame, h.app.text_edit, s, &ev, h.app.editable_text_targets)
		if tres.needs_rebuild {
			dagda.frame_destroy(&h.frame)
			h.frame = make_frame(s)
			text_edit_apply_committed(&h.text_edit, nil, nil, h.frame, h.app.text_edit, &tres.pending_edit)
		}
	}

	// Start without any mouse click: Tab -> field A (id=0), type "1".
	tab := key_ev(sdl.K_TAB)
	shift_tab := key_ev(sdl.K_TAB, sdl.KMOD_LSHIFT)
	enter := key_ev(sdl.K_RETURN)
	esc := key_ev(sdl.K_ESCAPE)

	_, _, _ = host_dispatch_key_event(&h, &tab)
	testing.expect_value(t, h.text_edit.focused, true)
	testing.expect_value(t, h.text_edit.active_id, dagda.Object_Id(0))
	testing.expect_value(t, h.focus.has_focus, false)
	send_text(&h, &s, "1")
	testing.expect_value(t, s.field_a, "Alpha1")
	testing.expect_value(t, s.last_edit_id, dagda.Object_Id(0))

	// Tab skips passive label(99) -> field B (id=2), type "2".
	_, _, _ = host_dispatch_key_event(&h, &tab)
	testing.expect_value(t, h.text_edit.focused, true)
	testing.expect_value(t, h.text_edit.active_id, dagda.Object_Id(2))
	testing.expect_value(t, h.focus.has_focus, false)
	send_text(&h, &s, "2")
	testing.expect_value(t, s.field_b, "Beta2")
	testing.expect_value(t, s.last_edit_id, dagda.Object_Id(2))

	// Tab -> button(3), Enter activates button once.
	_, _, _ = host_dispatch_key_event(&h, &tab)
	testing.expect_value(t, h.text_edit.focused, false)
	testing.expect_value(t, h.focus.has_focus, true)
	testing.expect_value(t, h.focus.focused_id, dagda.Object_Id(3))
	rebuild, _, _ := host_dispatch_key_event(&h, &enter)
	testing.expect_value(t, rebuild, true)
	testing.expect_value(t, s.btn_hits, 1)

	// Tab wraps forward back to field A (id=0).
	_, _, _ = host_dispatch_key_event(&h, &tab)
	testing.expect_value(t, h.text_edit.focused, true)
	testing.expect_value(t, h.text_edit.active_id, dagda.Object_Id(0))
	testing.expect_value(t, h.focus.has_focus, false)

	// Reverse traversal: Shift+Tab wraps backward from field A(0) -> button(3) -> field B(2) -> field A(0).
	_, _, _ = host_dispatch_key_event(&h, &shift_tab)
	testing.expect_value(t, h.text_edit.focused, false)
	testing.expect_value(t, h.focus.has_focus, true)
	testing.expect_value(t, h.focus.focused_id, dagda.Object_Id(3))

	_, _, _ = host_dispatch_key_event(&h, &shift_tab)
	testing.expect_value(t, h.text_edit.focused, true)
	testing.expect_value(t, h.text_edit.active_id, dagda.Object_Id(2))
	testing.expect_value(t, h.focus.has_focus, false)

	// Frame rebuild with reordered elements preserves stable active_id (2).
	s.reordered = true
	dagda.frame_destroy(&h.frame)
	h.frame = make_frame(&s)
	_ = focus_reconcile(&h.focus, h.frame)
	text_edit_reconcile(&h.text_edit, nil, nil, h.frame, h.app.text_edit, h.app.editable_text_targets)
	testing.expect_value(t, h.text_edit.focused, true)
	testing.expect_value(t, h.text_edit.active_id, dagda.Object_Id(2))
	testing.expect_value(t, h.focus.has_focus, false)
	s.reordered = false
	dagda.frame_destroy(&h.frame)
	h.frame = make_frame(&s)
	text_edit_reconcile(&h.text_edit, nil, nil, h.frame, h.app.text_edit, h.app.editable_text_targets)

	// Active preedit in field B(2) with selection: Tab and Shift+Tab leave focus, selection, and preedit in B.
	h.text_edit.session.anchor = 0
	h.text_edit.session.caret = 4
	pre: sdl.Event
	pre.type = .TEXT_EDITING
	pre.edit.text = "café"
	pre.edit.start = 0
	pre.edit.length = 4
	_ = text_edit_handle_event(&h.text_edit, nil, nil, h.frame, h.app.text_edit, &s, &pre, h.app.editable_text_targets)
	testing.expect_value(t, dagda.is_composing(&h.text_edit.session), true)

	_, _, _ = host_dispatch_key_event(&h, &tab)
	_, _, _ = host_dispatch_key_event(&h, &shift_tab)
	testing.expect_value(t, h.text_edit.focused, true)
	testing.expect_value(t, h.text_edit.active_id, dagda.Object_Id(2))
	testing.expect_value(t, h.text_edit.session.anchor, 0)
	testing.expect_value(t, h.text_edit.session.caret, 4)
	testing.expect_value(t, dagda.is_composing(&h.text_edit.session), true)
	testing.expect_value(t, h.text_edit.session.preedit, "café")

	// Escape cancels preedit -> Tab traversal works again (B(2) -> button(3)).
	_, _, _ = host_dispatch_key_event(&h, &esc)
	testing.expect_value(t, dagda.is_composing(&h.text_edit.session), false)
	_, _, _ = host_dispatch_key_event(&h, &tab)
	testing.expect_value(t, h.text_edit.focused, false)
	testing.expect_value(t, h.focus.has_focus, true)
	testing.expect_value(t, h.focus.focused_id, dagda.Object_Id(3))

	// Commit also re-enables traversal: Shift+Tab -> B(2), compose "e", commit "é", then Tab -> button(3).
	_, _, _ = host_dispatch_key_event(&h, &shift_tab)
	testing.expect_value(t, h.text_edit.active_id, dagda.Object_Id(2))
	pre.edit.text = "e"
	pre.edit.length = 1
	_ = text_edit_handle_event(&h.text_edit, nil, nil, h.frame, h.app.text_edit, &s, &pre, h.app.editable_text_targets)
	send_text(&h, &s, "é")
	testing.expect_value(t, dagda.is_composing(&h.text_edit.session), false)
	_, _, _ = host_dispatch_key_event(&h, &tab)
	testing.expect_value(t, h.text_edit.focused, false)
	testing.expect_value(t, h.focus.has_focus, true)
	testing.expect_value(t, h.focus.focused_id, dagda.Object_Id(3))
}

@(test)
test_active_composition_query_distinguishes_none_and_id_zero :: proc(t: ^testing.T) {
	els := [2]dagda.Canvas_Element{
		{info = {id = 0, role = "a.outline"}, kind = .Label, text = "Alpha", bounds = {x = 40, y = 40, width = 300, height = 50}},
		{info = {id = 1, role = "a.canvas"}, kind = .Label, text = "Alpha", bounds = {x = 400, y = 40, width = 300, height = 50}},
	}
	editable := [2]dagda.Object_Id{0, 1}
	frame, ok := dagda.resolve_canvas({size = {width = 960, height = 540}, elements = els[:]}, {width = 800, height = 540})
	testing.expect(t, ok)
	defer dagda.frame_destroy(&frame)

	h: Host
	h.frame = frame
	h.app = App{
		text_edit             = {enabled = true},
		editable_text_targets = editable[:],
	}
	defer text_edit_destroy(&h.text_edit)

	// No composition -> active=false.
	testing.expect_value(t, host_active_composition(&h), Active_Composition{active = false, field_id = 0})

	// Focus ID 0 without preedit -> still active=false.
	testing.expect(t, text_edit_focus_id(&h.text_edit, nil, nil, h.frame, h.app.text_edit, 0, editable[:]))
	testing.expect_value(t, host_active_composition(&h), Active_Composition{active = false, field_id = 0})

	// Start preedit in ID 0 -> active=true, field_id=0 (explicitly distinct from no composition).
	pre: sdl.Event
	pre.type = .TEXT_EDITING
	pre.edit.text = "e"
	pre.edit.start = 0
	pre.edit.length = 1
	_ = text_edit_handle_event(&h.text_edit, nil, nil, h.frame, h.app.text_edit, nil, &pre, editable[:])
	testing.expect_value(t, host_active_composition(&h), Active_Composition{active = true, field_id = 0})

	// During dispatch scope, current_composition() returns the window's active composition.
	prev := dispatch_host
	dispatch_host = &h
	defer { dispatch_host = prev }
	testing.expect_value(t, current_composition(), Active_Composition{active = true, field_id = 0})

	// Cancel composition -> active=false again.
	esc: sdl.Event
	esc.type = .KEY_DOWN
	esc.key.key = sdl.K_ESCAPE
	_ = text_edit_handle_event(&h.text_edit, nil, nil, h.frame, h.app.text_edit, nil, &esc, editable[:])
	testing.expect_value(t, current_composition(), Active_Composition{active = false, field_id = 0})
}

@(test)
test_canvas_editable_text_click_places_caret_at_two_viewports :: proc(t: ^testing.T) {
	font: Font
	if !font_init(&font) {
		return
	}
	defer font_destroy(&font)

	els := [1]dagda.Canvas_Element{
		{info = {id = 1, role = "slide.headline"}, kind = .Label, text = "Slide Canvas", bounds = {x = 80, y = 60, width = 640, height = 80}},
	}
	cfg := Editable_Text_Config{enabled = true, target_id = 1}

	viewports := [2]dagda.Size{{width = 800, height = 540}, {width = 640, height = 480}}
	for vp in viewports {
		frame, ok := dagda.resolve_canvas({size = {width = 960, height = 540}, elements = els[:]}, vp)
		testing.expect(t, ok)
		defer dagda.frame_destroy(&frame)

		el, found := dagda.find(frame, 1)
		testing.expect(t, found)
		text_x, _, px := text_edit_layout(frame, el.bounds)
		slide_w := font_measure_width(&font, "Slide", px)

		te: Text_Edit_State
		defer text_edit_destroy(&te)

		// Click right after "Slide" -> caret lands at byte offset 5.
		_ = text_edit_click(&te, nil, &font, frame, cfg, text_x + slide_w)
		testing.expect_value(t, te.session.caret, 5)
		testing.expect_value(t, te.session.anchor, 5)

		// Click before text origin -> caret lands at byte offset 0.
		_ = text_edit_click(&te, nil, &font, frame, cfg, text_x - 4)
		testing.expect_value(t, te.session.caret, 0)
	}
}

@(test)
test_clipboard_copy_paste_combining_multiline_reject_and_preedit :: proc(t: ^testing.T) {
	Clip_App :: struct {
		title:          string,
		rev:            u64,
		commit_calls:   int,
		reject_commits: bool,
		last_id:        dagda.Object_Id,
		undo_stack:     [dynamic]string,
		editable:       [2]dagda.Object_Id,
		elements:       [2]dagda.Canvas_Element,
	}
	make_frame :: proc(s: ^Clip_App) -> dagda.Frame {
		s.elements = {
			{info = {id = 1, role = "outline.title"}, kind = .Label, text = s.title, bounds = {x = 40, y = 40, width = 500, height = 60}},
			{info = {id = 2, role = "canvas.title"}, kind = .Label, text = s.title, bounds = {x = 40, y = 140, width = 500, height = 60}},
		}
		frame, ok := dagda.resolve_canvas({size = {width = 960, height = 540}, elements = s.elements[:]}, {width = 800, height = 540})
		assert(ok)
		return frame
	}
	on_commit :: proc(user_data: rawptr, id: dagda.Object_Id, new_text: string) -> bool {
		s := (^Clip_App)(user_data)
		s.commit_calls += 1
		if s.reject_commits || new_text == s.title {
			return false
		}
		cloned, err := strings.clone(new_text)
		if err != nil {
			return false
		}
		append(&s.undo_stack, s.title)
		s.title = cloned
		s.rev += 1
		s.last_id = id
		return true
	}
	on_undo :: proc(user_data: rawptr, id: dagda.Object_Id) -> bool {
		s := (^Clip_App)(user_data)
		if len(s.undo_stack) == 0 {
			return false
		}
		delete(s.title)
		s.title = pop(&s.undo_stack)
		s.rev += 1
		s.last_id = id
		return true
	}

	// "Cafe\u0301 Title" uses a decomposed combining acute accent (bytes: 65 cc 81).
	initial := "Cafe\u0301 Title"
	s := Clip_App{
		title    = strings.clone(initial),
		editable = {1, 2},
	}
	defer {
		delete(s.title)
		for prev in s.undo_stack {
			delete(prev)
		}
		delete(s.undo_stack)
	}

	h: Host
	h.frame = make_frame(&s)
	h.app = App{
		user_data = &s,
		text_edit = {
			enabled   = true,
			on_commit = on_commit,
			on_undo   = on_undo,
		},
		editable_text_targets = s.editable[:],
	}
	h.clipboard = memory_clipboard_interface(&h.mem_clipboard)
	defer {
		memory_clipboard_destroy(&h.mem_clipboard)
		text_edit_destroy(&h.text_edit)
		dagda.frame_destroy(&h.frame)
	}

	dispatch_key :: proc(h: ^Host, s: ^Clip_App, key: sdl.Keycode, mod: sdl.Keymod = {}) {
		ev: sdl.Event
		ev.type = .KEY_DOWN
		ev.key.key = key
		ev.key.mod = mod
		rebuild, has_pending, pending := host_dispatch_key_event(h, &ev)
		if rebuild {
			dagda.frame_destroy(&h.frame)
			h.frame = make_frame(s)
			if has_pending {
				text_edit_apply_committed(&h.text_edit, nil, nil, h.frame, h.app.text_edit, &pending)
			} else {
				text_edit_reconcile(&h.text_edit, nil, nil, h.frame, h.app.text_edit, h.app.editable_text_targets)
			}
		}
	}

	// 1. Focus view 1 (id=1). Ctrl+C with empty selection is a no-op.
	testing.expect(t, text_edit_focus_id(&h.text_edit, nil, nil, h.frame, h.app.text_edit, 1, s.editable[:]))
	dispatch_key(&h, &s, sdl.K_C, primary_modifier())
	testing.expect_value(t, h.mem_clipboard.text, "")
	testing.expect_value(t, s.rev, u64(0))
	testing.expect_value(t, s.commit_calls, 0)

	// Select "fe\u0301" (bytes 2..6: "f" + "e" + U+0301) in view 1 and Ctrl+C.
	dispatch_key(&h, &s, sdl.K_HOME)
	dispatch_key(&h, &s, sdl.K_RIGHT)
	dispatch_key(&h, &s, sdl.K_RIGHT)
	dispatch_key(&h, &s, sdl.K_RIGHT, sdl.KMOD_LSHIFT)
	dispatch_key(&h, &s, sdl.K_RIGHT, sdl.KMOD_LSHIFT)
	testing.expect_value(t, h.text_edit.session.anchor, 2)
	testing.expect_value(t, h.text_edit.session.caret, 6)

	dispatch_key(&h, &s, sdl.K_C, primary_modifier())
	testing.expect_value(t, h.mem_clipboard.text, "fe\u0301")
	testing.expect_value(t, s.rev, u64(0))
	testing.expect_value(t, s.commit_calls, 0)
	testing.expect_value(t, len(s.undo_stack), 0)

	// 2. Focus view 2 (id=2), select "Title" (last 5 bytes), Ctrl+V pastes exact UTF-8 bytes once.
	testing.expect(t, text_edit_focus_id(&h.text_edit, nil, nil, h.frame, h.app.text_edit, 2, s.editable[:]))
	for _ in 0 ..< 5 {
		dispatch_key(&h, &s, sdl.K_LEFT, sdl.KMOD_LSHIFT)
	}
	sel_start, sel_end := dagda.selection_bounds(&h.text_edit.session)
	testing.expect_value(t, s.title[sel_start:sel_end], "Title")

	dispatch_key(&h, &s, sdl.K_V, primary_modifier())
	testing.expect_value(t, s.title, "Cafe\u0301 fe\u0301")
	testing.expect_value(t, s.rev, u64(1))
	testing.expect_value(t, s.commit_calls, 1)
	testing.expect_value(t, len(s.undo_stack), 1)
	testing.expect_value(t, s.last_id, dagda.Object_Id(2))

	// 3. One Ctrl+Z restores the original title.
	dispatch_key(&h, &s, sdl.K_Z, primary_modifier())
	testing.expect_value(t, s.title, "Cafe\u0301 Title")
	testing.expect_value(t, s.rev, u64(2))
	testing.expect_value(t, len(s.undo_stack), 0)

	// 4. Multiline paste (\n and \r) preserves text, selection, and history.
	dispatch_key(&h, &s, sdl.K_END)
	for _ in 0 ..< 5 {
		dispatch_key(&h, &s, sdl.K_LEFT, sdl.KMOD_LSHIFT)
	}
	want_anchor := h.text_edit.session.anchor
	want_caret := h.text_edit.session.caret

	testing.expect(t, clipboard_set(h.clipboard, "Line1\nLine2"))
	dispatch_key(&h, &s, sdl.K_V, primary_modifier())
	testing.expect_value(t, s.title, "Cafe\u0301 Title")
	testing.expect_value(t, s.rev, u64(2))
	testing.expect_value(t, s.commit_calls, 1)
	testing.expect_value(t, len(s.undo_stack), 0)
	testing.expect_value(t, h.text_edit.session.anchor, want_anchor)
	testing.expect_value(t, h.text_edit.session.caret, want_caret)

	testing.expect(t, clipboard_set(h.clipboard, "Line1\rLine2"))
	dispatch_key(&h, &s, sdl.K_V, primary_modifier())
	testing.expect_value(t, s.title, "Cafe\u0301 Title")
	testing.expect_value(t, s.rev, u64(2))
	testing.expect_value(t, s.commit_calls, 1)
	testing.expect_value(t, h.text_edit.session.anchor, want_anchor)
	testing.expect_value(t, h.text_edit.session.caret, want_caret)

	// 5. App-rejected proposal preserves text, selection, and history.
	s.reject_commits = true
	testing.expect(t, clipboard_set(h.clipboard, "Blocked"))
	dispatch_key(&h, &s, sdl.K_V, primary_modifier())
	testing.expect_value(t, s.title, "Cafe\u0301 Title")
	testing.expect_value(t, s.rev, u64(2))
	testing.expect_value(t, s.commit_calls, 2)
	testing.expect_value(t, len(s.undo_stack), 0)
	testing.expect_value(t, h.text_edit.session.anchor, want_anchor)
	testing.expect_value(t, h.text_edit.session.caret, want_caret)

	// 6. Active IME composition: Ctrl+V leaves preedit, selection, text, and history intact.
	s.reject_commits = false
	pre: sdl.Event
	pre.type = .TEXT_EDITING
	pre.edit.text = "e"
	pre.edit.start = 0
	pre.edit.length = 1
	_ = text_edit_handle_event(&h.text_edit, nil, nil, h.frame, h.app.text_edit, &s, &pre, s.editable[:], h.clipboard)
	testing.expect_value(t, dagda.is_composing(&h.text_edit.session), true)

	testing.expect(t, clipboard_set(h.clipboard, "PASTE"))
	dispatch_key(&h, &s, sdl.K_V, primary_modifier())
	testing.expect_value(t, dagda.is_composing(&h.text_edit.session), true)
	testing.expect_value(t, h.text_edit.session.preedit, "e")
	testing.expect_value(t, s.title, "Cafe\u0301 Title")
	testing.expect_value(t, s.rev, u64(2))
	testing.expect_value(t, s.commit_calls, 2)
	testing.expect_value(t, len(s.undo_stack), 0)
	testing.expect_value(t, h.text_edit.session.anchor, want_anchor)
	testing.expect_value(t, h.text_edit.session.caret, want_caret)
}

@(test)
test_clipboard_sdl_dummy_roundtrip :: proc(t: ^testing.T) {
	// Exercise the default SDL3 clipboard path only under SDL's in-process dummy driver
	// so automated test runs never overwrite a live desktop clipboard.
	sync.mutex_lock(&sdl_test_mu)
	defer sync.mutex_unlock(&sdl_test_mu)
	if !sdl.Init({.VIDEO}) {
		return
	}
	defer sdl.Quit()
	driver_cstr := sdl.GetCurrentVideoDriver()
	if driver_cstr == nil || string(driver_cstr) != "dummy" {
		return
	}

	sample := "fe\u0301"
	testing.expect(t, clipboard_set({}, sample))
	got, ok := clipboard_get({})
	testing.expect(t, ok)
	defer delete(got)
	testing.expect_value(t, got, sample)

	// Refused copy containing U+0000 must preserve the seeded SDL clipboard,
	// selection, revision, and undo history.
	testing.expect(t, clipboard_set({}, "prior-sdl"))

	Nul_App :: struct {
		title:      string,
		rev:        u64,
		undo_depth: int,
		elements:   [1]dagda.Canvas_Element,
	}
	s := Nul_App{
		title      = "ab\x00cd",
		rev        = 7,
		undo_depth = 2,
	}
	s.elements = {
		{info = {id = 1, role = "outline.title"}, kind = .Label, text = s.title, bounds = {x = 40, y = 40, width = 500, height = 60}},
	}
	frame, frame_ok := dagda.resolve_canvas({size = {width = 960, height = 540}, elements = s.elements[:]}, {width = 800, height = 540})
	testing.expect(t, frame_ok)
	defer dagda.frame_destroy(&frame)

	h: Host
	h.frame = frame
	h.app = App{
		user_data = &s,
		text_edit = {enabled = true, target_id = 1},
	}
	defer text_edit_destroy(&h.text_edit)

	testing.expect(t, text_edit_focus_id(&h.text_edit, nil, nil, h.frame, h.app.text_edit, 1))
	h.text_edit.session.anchor = 1
	h.text_edit.session.caret = 4

	ev: sdl.Event
	ev.type = .KEY_DOWN
	ev.key.key = sdl.K_C
	ev.key.mod = sdl.KMOD_LCTRL
	rebuild, has_pending, _ := host_dispatch_key_event(&h, &ev)
	testing.expect_value(t, rebuild, false)
	testing.expect_value(t, has_pending, false)
	testing.expect_value(t, h.text_edit.session.anchor, 1)
	testing.expect_value(t, h.text_edit.session.caret, 4)
	testing.expect_value(t, s.rev, u64(7))
	testing.expect_value(t, s.undo_depth, 2)

	after, after_ok := clipboard_get({})
	testing.expect(t, after_ok)
	defer delete(after)
	testing.expect_value(t, after, "prior-sdl")
}

@(test)
test_clipboard_copy_declines_nul_preserving_memory_backend_and_state :: proc(t: ^testing.T) {
	Spy_Clipboard :: struct {
		mc:        Memory_Clipboard,
		set_calls: int,
	}
	spy_set :: proc(ctx: rawptr, text: string) -> bool {
		sp := (^Spy_Clipboard)(ctx)
		sp.set_calls += 1
		return memory_clipboard_set(&sp.mc, text)
	}
	spy_get :: proc(ctx: rawptr, allocator := context.allocator) -> (string, bool) {
		sp := (^Spy_Clipboard)(ctx)
		return memory_clipboard_get(&sp.mc, allocator)
	}

	Nul_App :: struct {
		title:      string,
		rev:        u64,
		undo_depth: int,
		elements:   [1]dagda.Canvas_Element,
	}
	s := Nul_App{
		title      = "ab\x00cd",
		rev        = 3,
		undo_depth = 1,
	}
	s.elements = {
		{info = {id = 1, role = "outline.title"}, kind = .Label, text = s.title, bounds = {x = 40, y = 40, width = 500, height = 60}},
	}
	frame, ok := dagda.resolve_canvas({size = {width = 960, height = 540}, elements = s.elements[:]}, {width = 800, height = 540})
	testing.expect(t, ok)
	defer dagda.frame_destroy(&frame)

	spy: Spy_Clipboard
	defer memory_clipboard_destroy(&spy.mc)
	cb := Clipboard{ctx = &spy, get = spy_get, set = spy_set}

	// Seed the memory backend with a known value.
	testing.expect(t, clipboard_set(cb, "prior-mem"))
	testing.expect_value(t, spy.set_calls, 1)
	testing.expect_value(t, spy.mc.text, "prior-mem")

	h: Host
	h.frame = frame
	h.app = App{
		user_data = &s,
		text_edit = {enabled = true, target_id = 1},
	}
	h.clipboard = cb
	defer text_edit_destroy(&h.text_edit)

	testing.expect(t, text_edit_focus_id(&h.text_edit, nil, nil, h.frame, h.app.text_edit, 1))
	h.text_edit.session.anchor = 1
	h.text_edit.session.caret = 4

	ev: sdl.Event
	ev.type = .KEY_DOWN
	ev.key.key = sdl.K_C
	ev.key.mod = sdl.KMOD_LCTRL
	rebuild, has_pending, _ := host_dispatch_key_event(&h, &ev)
	testing.expect_value(t, rebuild, false)
	testing.expect_value(t, has_pending, false)

	// Declined before calling backend set; previous clipboard, selection, rev, and undo survive.
	testing.expect_value(t, spy.set_calls, 1)
	testing.expect_value(t, spy.mc.text, "prior-mem")
	testing.expect_value(t, h.text_edit.session.anchor, 1)
	testing.expect_value(t, h.text_edit.session.caret, 4)
	testing.expect_value(t, s.rev, u64(3))
	testing.expect_value(t, s.undo_depth, 1)
}

@(test)
test_mouse_drag_selection_grapheme_bounds_clamping_composition_and_canvas_drag :: proc(t: ^testing.T) {
	Drag_App :: struct {
		title:        string,
		rev:          u64,
		card_x:       f32,
		card_presses: int,
		card_moves:   int,
		card_ups:     int,
		editable:     [2]dagda.Object_Id,
		elements:     [3]dagda.Canvas_Element,
	}
	make_canvas :: proc(user_data: rawptr) -> dagda.Canvas {
		s := (^Drag_App)(user_data)
		s.elements = {
			{info = {id = 1, role = "outline.title"}, kind = .Label, text = s.title, bounds = {x = 80, y = 60, width = 640, height = 80}},
			{info = {id = 2, role = "canvas.title"}, kind = .Label, text = s.title, bounds = {x = 80, y = 200, width = 640, height = 80}},
			{info = {id = 3, role = "slide.card"}, kind = .Button, text = "Card", bounds = {x = s.card_x, y = 340, width = 180, height = 80}},
		}
		return {size = {width = 960, height = 540}, elements = s.elements[:]}
	}
	on_pointer :: proc(user_data: rawptr, ev: Pointer_Event) -> bool {
		s := (^Drag_App)(user_data)
		if !ev.has_target || ev.target_id != 3 {
			return false
		}
		#partial switch ev.phase {
		case .Press:
			s.card_presses += 1
			return true
		case .Move:
			s.card_moves += 1
			s.card_x = ev.point.x
			return true
		case .Release:
			s.card_ups += 1
			return true
		}
		return false
	}

	s := Drag_App{
		title    = "Ae\u0301B",
		card_x   = 80,
		editable = {1, 2},
	}

	h: Host
	if !font_init(&h.font) {
		return
	}
	defer font_destroy(&h.font)
	h.viewport = {width = 800, height = 540}
	h.app = App{
		user_data             = &s,
		canvas                = make_canvas,
		on_pointer            = on_pointer,
		text_edit             = {enabled = true},
		editable_text_targets = s.editable[:],
	}
	testing.expect(t, host_rebuild_frame(&h))
	h.clipboard = memory_clipboard_interface(&h.mem_clipboard)
	defer {
		memory_clipboard_destroy(&h.mem_clipboard)
		text_edit_destroy(&h.text_edit)
		dagda.frame_destroy(&h.frame)
	}

	mouse_down :: proc(x, y: f32) -> sdl.Event {
		ev: sdl.Event
		ev.type = .MOUSE_BUTTON_DOWN
		ev.button.button = sdl.BUTTON_LEFT
		ev.button.down = true
		ev.button.x = x
		ev.button.y = y
		return ev
	}
	mouse_move :: proc(x, y: f32) -> sdl.Event {
		ev: sdl.Event
		ev.type = .MOUSE_MOTION
		ev.motion.x = x
		ev.motion.y = y
		return ev
	}
	mouse_up :: proc(x, y: f32) -> sdl.Event {
		ev: sdl.Event
		ev.type = .MOUSE_BUTTON_UP
		ev.button.button = sdl.BUTTON_LEFT
		ev.button.down = false
		ev.button.x = x
		ev.button.y = y
		return ev
	}
	ctrl_c :: proc() -> sdl.Event {
		ev: sdl.Event
		ev.type = .KEY_DOWN
		ev.key.key = sdl.K_C
		ev.key.mod = primary_modifier()
		return ev
	}

	el1, found1 := dagda.find(h.frame, 1)
	el2, found2 := dagda.find(h.frame, 2)
	card, found3 := dagda.find(h.frame, 3)
	testing.expect(t, found1 && found2 && found3)

	tx, _, px := text_edit_layout(h.frame, el1.bounds)
	y1 := el1.bounds.y + el1.bounds.height * 0.5
	y2 := el2.bounds.y + el2.bounds.height * 0.5
	x_after_a := tx + font_measure_width(&h.font, "A", px)
	x_after_e := tx + font_measure_width(&h.font, "Ae\u0301", px)

	// 1. LTR drag across decomposed "e\u0301" (moving vertically over field 2 stays on field 1).
	d := mouse_down(x_after_a, y1)
	m := mouse_move(x_after_e, y2)
	u := mouse_up(x_after_e, y2)
	_ = host_dispatch_mouse_event(&h, &d)
	testing.expect_value(t, h.text_edit.dragging, true)
	testing.expect_value(t, h.text_edit.active_id, dagda.Object_Id(1))
	_ = host_dispatch_mouse_event(&h, &m)
	_ = host_dispatch_mouse_event(&h, &u)
	testing.expect_value(t, h.text_edit.dragging, false)
	testing.expect_value(t, h.text_edit.active_id, dagda.Object_Id(1))
	testing.expect_value(t, h.text_edit.session.anchor, 1)
	testing.expect_value(t, h.text_edit.session.caret, 4)
	testing.expect_value(t, s.rev, u64(0))

	copy_ev := ctrl_c()
	_, _, _ = host_dispatch_key_event(&h, &copy_ev)
	testing.expect_value(t, h.mem_clipboard.text, "e\u0301")

	// 2. RTL drag across decomposed "e\u0301".
	d = mouse_down(x_after_e, y1)
	m = mouse_move(x_after_a, y1)
	u = mouse_up(x_after_a, y1)
	_ = host_dispatch_mouse_event(&h, &d)
	_ = host_dispatch_mouse_event(&h, &m)
	_ = host_dispatch_mouse_event(&h, &u)
	testing.expect_value(t, h.text_edit.session.anchor, 4)
	testing.expect_value(t, h.text_edit.session.caret, 1)
	testing.expect_value(t, s.rev, u64(0))

	// 3. Dragging past right end and past left end clamps cleanly to [0, len(title)].
	d = mouse_down(x_after_a, y1)
	m = mouse_move(el1.bounds.x + el1.bounds.width + 120, y1)
	_ = host_dispatch_mouse_event(&h, &d)
	_ = host_dispatch_mouse_event(&h, &m)
	testing.expect_value(t, h.text_edit.session.anchor, 1)
	testing.expect_value(t, h.text_edit.session.caret, len(s.title))
	m = mouse_move(el1.bounds.x - 120, y1)
	u = mouse_up(el1.bounds.x - 120, y1)
	_ = host_dispatch_mouse_event(&h, &m)
	_ = host_dispatch_mouse_event(&h, &u)
	testing.expect_value(t, h.text_edit.session.anchor, 1)
	testing.expect_value(t, h.text_edit.session.caret, 0)

	// 4. Ordinary click collapses selection to a single caret.
	d = mouse_down(x_after_e, y1)
	u = mouse_up(x_after_e, y1)
	_ = host_dispatch_mouse_event(&h, &d)
	_ = host_dispatch_mouse_event(&h, &u)
	testing.expect_value(t, h.text_edit.session.anchor, 4)
	testing.expect_value(t, h.text_edit.session.caret, 4)

	// 5. Active IME composition in field 1: pressing/dragging field 2 preserves field 1's composition.
	pre: sdl.Event
	pre.type = .TEXT_EDITING
	pre.edit.text = "e"
	pre.edit.start = 0
	pre.edit.length = 1
	_ = text_edit_handle_event(&h.text_edit, nil, &h.font, h.frame, h.app.text_edit, &s, &pre, s.editable[:], h.clipboard)
	testing.expect_value(t, dagda.is_composing(&h.text_edit.session), true)

	d = mouse_down(x_after_a, y2)
	m = mouse_move(x_after_e, y2)
	u = mouse_up(x_after_e, y2)
	_ = host_dispatch_mouse_event(&h, &d)
	_ = host_dispatch_mouse_event(&h, &m)
	_ = host_dispatch_mouse_event(&h, &u)
	testing.expect_value(t, h.text_edit.focused, true)
	testing.expect_value(t, h.text_edit.active_id, dagda.Object_Id(1))
	testing.expect_value(t, h.text_edit.dragging, false)
	testing.expect_value(t, dagda.is_composing(&h.text_edit.session), true)
	testing.expect_value(t, h.text_edit.session.preedit, "e")

	// Cancel composition, then verify canvas object dragging (card id=3) still works cleanly.
	esc: sdl.Event
	esc.type = .KEY_DOWN
	esc.key.key = sdl.K_ESCAPE
	_, _, _ = host_dispatch_key_event(&h, &esc)

	cx := card.bounds.x + card.bounds.width * 0.5
	cy := card.bounds.y + card.bounds.height * 0.5
	d = mouse_down(cx, cy)
	m = mouse_move(cx + 40, cy)
	u = mouse_up(cx + 40, cy)
	testing.expect_value(t, host_dispatch_mouse_event(&h, &d), true)
	testing.expect_value(t, h.text_edit.focused, false)
	testing.expect_value(t, host_dispatch_mouse_event(&h, &m), true)
	testing.expect_value(t, host_dispatch_mouse_event(&h, &u), true)
	testing.expect_value(t, s.card_presses, 1)
	testing.expect_value(t, s.card_moves, 1)
	testing.expect_value(t, s.card_ups, 1)
}

@(test)
test_editable_canvas_press_notifies_on_pointer_rebuilds_and_keeps_drag_target :: proc(t: ^testing.T) {
	Deck_App :: struct {
		titles:         [2]string,
		selected_slide: int,
		press_calls:    int,
		last_press_id:  dagda.Object_Id,
		editable:       [3]dagda.Object_Id,
		elements:       [3]dagda.Canvas_Element,
	}
	make_canvas :: proc(user_data: rawptr) -> dagda.Canvas {
		s := (^Deck_App)(user_data)
		s.elements = {
			{info = {id = 1, role = "outline.row.0"}, kind = .Label, text = s.titles[0], bounds = {x = 40, y = 60, width = 320, height = 70}},
			{info = {id = 2, role = "outline.row.1"}, kind = .Label, text = s.titles[1], bounds = {x = 40, y = 160, width = 320, height = 70}},
			{info = {id = 3, role = "slide.headline"}, kind = .Label, text = s.titles[s.selected_slide], bounds = {x = 400, y = 60, width = 500, height = 80}},
		}
		return {size = {width = 960, height = 540}, elements = s.elements[:]}
	}
	on_pointer :: proc(user_data: rawptr, ev: Pointer_Event) -> bool {
		s := (^Deck_App)(user_data)
		if ev.phase != .Press || !ev.has_target {
			return false
		}
		s.press_calls += 1
		s.last_press_id = ev.target_id
		if ev.target_id == 1 && s.selected_slide != 0 {
			s.selected_slide = 0
			return true
		}
		if ev.target_id == 2 && s.selected_slide != 1 {
			s.selected_slide = 1
			return true
		}
		return false
	}
	on_commit :: proc(user_data: rawptr, id: dagda.Object_Id, new_text: string) -> bool {
		s := (^Deck_App)(user_data)
		idx := -1
		if id == 1 {
			idx = 0
		} else if id == 2 {
			idx = 1
		} else if id == 3 {
			idx = s.selected_slide
		}
		if idx < 0 {
			return false
		}
		cloned, err := strings.clone(new_text)
		if err != nil {
			return false
		}
		delete(s.titles[idx])
		s.titles[idx] = cloned
		return true
	}

	s := Deck_App{
		titles         = {strings.clone("Quarterly results"), strings.clone("Next steps")},
		selected_slide = 0,
		editable       = {1, 2, 3},
	}
	defer {
		delete(s.titles[0])
		delete(s.titles[1])
	}

	h: Host
	if !font_init(&h.font) {
		return
	}
	defer font_destroy(&h.font)
	h.viewport = {width = 800, height = 540}
	h.app = App{
		user_data             = &s,
		canvas                = make_canvas,
		on_pointer            = on_pointer,
		text_edit             = {enabled = true, on_commit = on_commit},
		editable_text_targets = s.editable[:],
	}
	testing.expect(t, host_rebuild_frame(&h))
	defer {
		text_edit_destroy(&h.text_edit)
		dagda.frame_destroy(&h.frame)
	}

	mouse_down :: proc(x, y: f32) -> sdl.Event {
		ev: sdl.Event
		ev.type = .MOUSE_BUTTON_DOWN
		ev.button.button = sdl.BUTTON_LEFT
		ev.button.down = true
		ev.button.x = x
		ev.button.y = y
		return ev
	}
	mouse_move :: proc(x, y: f32) -> sdl.Event {
		ev: sdl.Event
		ev.type = .MOUSE_MOTION
		ev.motion.x = x
		ev.motion.y = y
		return ev
	}
	mouse_up :: proc(x, y: f32) -> sdl.Event {
		ev: sdl.Event
		ev.type = .MOUSE_BUTTON_UP
		ev.button.button = sdl.BUTTON_LEFT
		ev.button.down = false
		ev.button.x = x
		ev.button.y = y
		return ev
	}

	row1, ok1 := dagda.find(h.frame, 1)
	row2, ok2 := dagda.find(h.frame, 2)
	testing.expect(t, ok1 && ok2)

	// 1. Click slide B's row ("Next steps") after "Next" -> on_pointer(.Press) fires once,
	//    rebuilds headline to "Next steps", and typing " two" updates both row 2 and headline.
	tx2, _, px2 := text_edit_layout(h.frame, row2.bounds)
	y2 := row2.bounds.y + row2.bounds.height * 0.5
	x_after_next := tx2 + font_measure_width(&h.font, "Next", px2)

	d := mouse_down(x_after_next, y2)
	u := mouse_up(x_after_next, y2)
	testing.expect(t, host_dispatch_mouse_event(&h, &d))
	testing.expect_value(t, s.press_calls, 1)
	testing.expect_value(t, s.last_press_id, dagda.Object_Id(2))
	testing.expect_value(t, s.selected_slide, 1)
	testing.expect_value(t, h.text_edit.dragging, true)
	testing.expect_value(t, h.text_edit.drag_target_id, dagda.Object_Id(2))

	hl, hl_ok := dagda.find(h.frame, 3)
	testing.expect(t, hl_ok)
	testing.expect_value(t, hl.text, "Next steps")

	testing.expect(t, host_dispatch_mouse_event(&h, &u))
	testing.expect_value(t, s.press_calls, 1)

	ti: sdl.Event
	ti.type = .TEXT_INPUT
	ti.text.text = " two"
	tres := text_edit_handle_event(&h.text_edit, nil, &h.font, h.frame, h.app.text_edit, &s, &ti, s.editable[:])
	testing.expect_value(t, tres.needs_rebuild, true)
	testing.expect(t, host_rebuild_frame(&h))
	text_edit_apply_committed(&h.text_edit, nil, &h.font, h.frame, h.app.text_edit, &tres.pending_edit)

	r2_after, _ := dagda.find(h.frame, 2)
	hl_after, _ := dagda.find(h.frame, 3)
	testing.expect_value(t, r2_after.text, "Next two steps")
	testing.expect_value(t, hl_after.text, "Next two steps")

	// 2. Press on slide A's row (id=1) triggers rebuild + keeps drag selection attached to row 1.
	tx1, _, px1 := text_edit_layout(h.frame, row1.bounds)
	y1 := row1.bounds.y + row1.bounds.height * 0.5
	x_after_quarterly := tx1 + font_measure_width(&h.font, "Quarterly", px1)
	d = mouse_down(tx1, y1)
	m := mouse_move(x_after_quarterly, y2) // move vertically over row 2
	u = mouse_up(x_after_quarterly, y2)
	testing.expect(t, host_dispatch_mouse_event(&h, &d))
	testing.expect_value(t, s.selected_slide, 0)
	testing.expect_value(t, s.press_calls, 2)
	testing.expect_value(t, h.text_edit.dragging, true)
	testing.expect_value(t, h.text_edit.drag_target_id, dagda.Object_Id(1))
	testing.expect(t, host_dispatch_mouse_event(&h, &m))
	testing.expect(t, host_dispatch_mouse_event(&h, &u))
	testing.expect_value(t, h.text_edit.active_id, dagda.Object_Id(1))
	testing.expect_value(t, h.text_edit.session.anchor, 0)
	testing.expect_value(t, h.text_edit.session.caret, len("Quarterly"))

	// 3. During active IME composition in row 1, clicking row 2 does NOT fire on_pointer
	//    and preserves focus, preedit, and selected slide 0.
	pre: sdl.Event
	pre.type = .TEXT_EDITING
	pre.edit.text = "e"
	pre.edit.start = 0
	pre.edit.length = 1
	_ = text_edit_handle_event(&h.text_edit, nil, &h.font, h.frame, h.app.text_edit, &s, &pre, s.editable[:])
	testing.expect_value(t, dagda.is_composing(&h.text_edit.session), true)

	d = mouse_down(tx2, y2)
	u = mouse_up(tx2, y2)
	testing.expect(t, host_dispatch_mouse_event(&h, &d))
	testing.expect(t, host_dispatch_mouse_event(&h, &u))
	testing.expect_value(t, s.press_calls, 2)
	testing.expect_value(t, s.selected_slide, 0)
	testing.expect_value(t, h.text_edit.active_id, dagda.Object_Id(1))
	testing.expect_value(t, dagda.is_composing(&h.text_edit.session), true)
	testing.expect_value(t, h.text_edit.session.preedit, "e")
}

@(test)
test_release_rebuild_runs_before_activation_and_propagates_failure :: proc(t: ^testing.T) {
	Swap_App :: struct {
		button_id:     dagda.Object_Id,
		swap_on_up:    bool,
		fail_rebuild:  bool,
		activate_2:    int,
		activate_9:    int,
		elements:      [1]dagda.Canvas_Element,
		bad_elements:  [2]dagda.Canvas_Element,
	}
	make_canvas :: proc(user_data: rawptr) -> dagda.Canvas {
		s := (^Swap_App)(user_data)
		if s.fail_rebuild {
			// Duplicate IDs make dagda.resolve_canvas fail cleanly.
			s.bad_elements = {
				{info = {id = 2, role = "btn.dup"}, kind = .Button, text = "A", bounds = {x = 80, y = 80, width = 160, height = 60}},
				{info = {id = 2, role = "btn.dup"}, kind = .Button, text = "B", bounds = {x = 260, y = 80, width = 160, height = 60}},
			}
			return {size = {width = 960, height = 540}, elements = s.bad_elements[:]}
		}
		s.elements = {
			{info = {id = s.button_id, role = "swap.btn"}, kind = .Button, text = "Go", bounds = {x = 80, y = 80, width = 160, height = 60}},
		}
		return {size = {width = 960, height = 540}, elements = s.elements[:]}
	}
	on_pointer :: proc(user_data: rawptr, ev: Pointer_Event) -> bool {
		s := (^Swap_App)(user_data)
		if ev.phase == .Release && s.swap_on_up {
			s.button_id = 9
			return true
		}
		return false
	}
	on_action :: proc(user_data: rawptr, id: dagda.Object_Id, action: dagda.Action) -> bool {
		s := (^Swap_App)(user_data)
		if action != .Activate {
			return false
		}
		if id == 2 {
			s.activate_2 += 1
			return true
		}
		if id == 9 {
			s.activate_9 += 1
			return true
		}
		return false
	}

	s := Swap_App{button_id = 2}
	h: Host
	h.viewport = {width = 800, height = 540}
	h.app = App{
		user_data  = &s,
		canvas     = make_canvas,
		handle     = on_action,
		on_pointer = on_pointer,
	}
	testing.expect(t, host_rebuild_frame(&h))
	defer dagda.frame_destroy(&h.frame)

	btn, ok := dagda.find(h.frame, 2)
	testing.expect(t, ok)
	cx := btn.bounds.x + btn.bounds.width * 0.5
	cy := btn.bounds.y + btn.bounds.height * 0.5

	down: sdl.Event
	down.type = .MOUSE_BUTTON_DOWN
	down.button.button = sdl.BUTTON_LEFT
	down.button.down = true
	down.button.x = cx
	down.button.y = cy

	up: sdl.Event
	up.type = .MOUSE_BUTTON_UP
	up.button.button = sdl.BUTTON_LEFT
	up.button.down = false
	up.button.x = cx
	up.button.y = cy

	// 1. Ordinary unchanged button activates exactly once on release.
	testing.expect(t, host_dispatch_mouse_event(&h, &down))
	testing.expect(t, host_dispatch_mouse_event(&h, &up))
	testing.expect_value(t, s.activate_2, 1)
	testing.expect_value(t, s.activate_9, 0)

	// 2. Release callback replaces button 2 with button 9 at identical bounds and returns true:
	//    frame rebuilds before activation check, so neither 2 nor 9 activates.
	s.swap_on_up = true
	testing.expect(t, host_dispatch_mouse_event(&h, &down))
	testing.expect(t, host_dispatch_mouse_event(&h, &up))
	testing.expect_value(t, s.button_id, dagda.Object_Id(9))
	testing.expect_value(t, s.activate_2, 1)
	testing.expect_value(t, s.activate_9, 0)

	// 3. Rebuild failure during release propagates false so the host exits cleanly.
	s.button_id = 2
	testing.expect(t, host_rebuild_frame(&h))
	testing.expect(t, host_dispatch_mouse_event(&h, &down))
	s.fail_rebuild = true
	testing.expect_value(t, host_dispatch_mouse_event(&h, &up), false)
	testing.expect_value(t, s.activate_2, 1)
	testing.expect_value(t, s.activate_9, 0)
}

@(test)
test_editable_canvas_press_preserves_full_pointer_gesture_lifecycle :: proc(t: ^testing.T) {
	Recorded_Ev :: struct {
		phase:      Pointer_Phase,
		has_target: bool,
		target_id:  dagda.Object_Id,
	}
	Lifecycle_App :: struct {
		events:          [dynamic]Recorded_Ev,
		holding_gesture: bool,
		button_hits:     int,
		editable:        [2]dagda.Object_Id,
		elements:        [3]dagda.Canvas_Element,
	}
	make_canvas :: proc(user_data: rawptr) -> dagda.Canvas {
		s := (^Lifecycle_App)(user_data)
		s.elements = {
			{info = {id = 1, role = "field.a"}, kind = .Label, text = "Alpha Title", bounds = {x = 40, y = 60, width = 420, height = 70}},
			{info = {id = 2, role = "field.b"}, kind = .Label, text = "Beta Title", bounds = {x = 40, y = 160, width = 420, height = 70}},
			{info = {id = 3, role = "action.btn"}, kind = .Button, text = "Run", bounds = {x = 500, y = 60, width = 140, height = 70}},
		}
		return {size = {width = 960, height = 540}, elements = s.elements[:]}
	}
	on_pointer :: proc(user_data: rawptr, ev: Pointer_Event) -> bool {
		s := (^Lifecycle_App)(user_data)
		append(&s.events, Recorded_Ev{phase = ev.phase, has_target = ev.has_target, target_id = ev.target_id})
		switch ev.phase {
		case .Press:
			s.holding_gesture = true
			return true // trigger rebuild on press
		case .Move:
			return false
		case .Release, .Cancel:
			s.holding_gesture = false
			return false
		}
		return false
	}
	on_action :: proc(user_data: rawptr, id: dagda.Object_Id, action: dagda.Action) -> bool {
		s := (^Lifecycle_App)(user_data)
		if id == 3 && action == .Activate {
			s.button_hits += 1
			return true
		}
		return false
	}

	s := Lifecycle_App{editable = {1, 2}}
	defer delete(s.events)

	h: Host
	if !font_init(&h.font) {
		return
	}
	defer font_destroy(&h.font)
	h.viewport = {width = 800, height = 540}
	h.app = App{
		user_data             = &s,
		canvas                = make_canvas,
		handle                = on_action,
		on_pointer            = on_pointer,
		text_edit             = {enabled = true},
		editable_text_targets = s.editable[:],
	}
	testing.expect(t, host_rebuild_frame(&h))
	defer {
		text_edit_destroy(&h.text_edit)
		dagda.frame_destroy(&h.frame)
	}

	mouse_down :: proc(x, y: f32) -> sdl.Event {
		ev: sdl.Event
		ev.type = .MOUSE_BUTTON_DOWN
		ev.button.button = sdl.BUTTON_LEFT
		ev.button.down = true
		ev.button.x = x
		ev.button.y = y
		return ev
	}
	mouse_move :: proc(x, y: f32) -> sdl.Event {
		ev: sdl.Event
		ev.type = .MOUSE_MOTION
		ev.motion.x = x
		ev.motion.y = y
		return ev
	}
	mouse_up :: proc(x, y: f32) -> sdl.Event {
		ev: sdl.Event
		ev.type = .MOUSE_BUTTON_UP
		ev.button.button = sdl.BUTTON_LEFT
		ev.button.down = false
		ev.button.x = x
		ev.button.y = y
		return ev
	}
	esc_key :: proc() -> sdl.Event {
		ev: sdl.Event
		ev.type = .KEY_DOWN
		ev.key.key = sdl.K_ESCAPE
		return ev
	}

	el1, ok1 := dagda.find(h.frame, 1)
	el2, ok2 := dagda.find(h.frame, 2)
	btn, ok3 := dagda.find(h.frame, 3)
	testing.expect(t, ok1 && ok2 && ok3)
	tx1, _, px1 := text_edit_layout(h.frame, el1.bounds)
	y1 := el1.bounds.y + el1.bounds.height * 0.5
	y2 := el2.bounds.y + el2.bounds.height * 0.5
	x_after_alpha := tx1 + font_measure_width(&h.font, "Alpha", px1)

	// 1. Click on editable field 1: Press(1) -> Release(1), app no longer holding gesture.
	d := mouse_down(tx1, y1)
	u := mouse_up(tx1, y1)
	testing.expect(t, host_dispatch_mouse_event(&h, &d))
	testing.expect_value(t, s.holding_gesture, true)
	testing.expect(t, host_dispatch_mouse_event(&h, &u))
	testing.expect_value(t, s.holding_gesture, false)
	testing.expect_value(t, len(s.events), 2)
	testing.expect_value(t, s.events[0], Recorded_Ev{.Press, true, 1})
	testing.expect_value(t, s.events[1], Recorded_Ev{.Release, true, 1})

	// 2. Drag from editable field 1 and release over field 2: Press(1) -> Move(1) -> Release(1),
	//    text selection stays on field 1, app no longer holding gesture.
	clear(&s.events)
	d = mouse_down(tx1, y1)
	m := mouse_move(x_after_alpha, y2)
	u = mouse_up(x_after_alpha, y2)
	testing.expect(t, host_dispatch_mouse_event(&h, &d))
	testing.expect(t, host_dispatch_mouse_event(&h, &m))
	testing.expect(t, host_dispatch_mouse_event(&h, &u))
	testing.expect_value(t, s.holding_gesture, false)
	testing.expect_value(t, h.text_edit.dragging, false)
	testing.expect_value(t, h.text_edit.active_id, dagda.Object_Id(1))
	testing.expect_value(t, h.text_edit.session.anchor, 0)
	testing.expect_value(t, h.text_edit.session.caret, len("Alpha"))
	testing.expect_value(t, len(s.events), 3)
	testing.expect_value(t, s.events[0], Recorded_Ev{.Press, true, 1})
	testing.expect_value(t, s.events[1], Recorded_Ev{.Move, true, 1})
	testing.expect_value(t, s.events[2], Recorded_Ev{.Release, true, 1})

	// 3. Press on editable field 1 -> Escape -> mouse-up: Press(1) -> Cancel(1) only (no Release),
	//    app no longer holding gesture and text drag ended.
	clear(&s.events)
	d = mouse_down(tx1, y1)
	esc := esc_key()
	u = mouse_up(x_after_alpha, y1)
	testing.expect(t, host_dispatch_mouse_event(&h, &d))
	testing.expect_value(t, s.holding_gesture, true)
	_, _, _ = host_dispatch_key_event(&h, &esc)
	testing.expect_value(t, s.holding_gesture, false)
	testing.expect_value(t, h.text_edit.dragging, false)
	testing.expect(t, host_dispatch_mouse_event(&h, &u))
	testing.expect_value(t, s.holding_gesture, false)
	testing.expect_value(t, len(s.events), 2)
	testing.expect_value(t, s.events[0], Recorded_Ev{.Press, true, 1})
	testing.expect_value(t, s.events[1], Recorded_Ev{.Cancel, true, 1})

	// 4. Blocked cross-field press during composition must not start a gesture.
	clear(&s.events)
	pre: sdl.Event
	pre.type = .TEXT_EDITING
	pre.edit.text = "e"
	pre.edit.start = 0
	pre.edit.length = 1
	_ = text_edit_handle_event(&h.text_edit, nil, &h.font, h.frame, h.app.text_edit, &s, &pre, s.editable[:])
	d = mouse_down(tx1, y2)
	u = mouse_up(tx1, y2)
	testing.expect(t, host_dispatch_mouse_event(&h, &d))
	testing.expect(t, host_dispatch_mouse_event(&h, &u))
	testing.expect_value(t, len(s.events), 0)
	testing.expect_value(t, s.holding_gesture, false)
	testing.expect_value(t, h.text_edit.active_id, dagda.Object_Id(1))
	testing.expect_value(t, dagda.is_composing(&h.text_edit.session), true)
	_, _, _ = host_dispatch_key_event(&h, &esc) // cancel composition

	// 5. Actionable button click activates once; drag or Escape-cancel suppresses activation.
	bx := btn.bounds.x + btn.bounds.width * 0.5
	by := btn.bounds.y + btn.bounds.height * 0.5
	d = mouse_down(bx, by)
	u = mouse_up(bx, by)
	testing.expect(t, host_dispatch_mouse_event(&h, &d))
	testing.expect(t, host_dispatch_mouse_event(&h, &u))
	testing.expect_value(t, s.button_hits, 1)
	testing.expect_value(t, s.holding_gesture, false)

	d = mouse_down(bx, by)
	m = mouse_move(bx + 10, by)
	u = mouse_up(bx + 10, by)
	testing.expect(t, host_dispatch_mouse_event(&h, &d))
	testing.expect(t, host_dispatch_mouse_event(&h, &m))
	testing.expect(t, host_dispatch_mouse_event(&h, &u))
	testing.expect_value(t, s.button_hits, 1)

	d = mouse_down(bx, by)
	testing.expect(t, host_dispatch_mouse_event(&h, &d))
	_, _, _ = host_dispatch_key_event(&h, &esc)
	u = mouse_up(bx, by)
	testing.expect(t, host_dispatch_mouse_event(&h, &u))
	testing.expect_value(t, s.button_hits, 1)
	testing.expect_value(t, s.holding_gesture, false)
}

@(test)
test_shift_click_extends_shrinks_reverses_switches_field_and_respects_ime_and_pointer :: proc(t: ^testing.T) {
	Recorded_Ev :: struct {
		phase:      Pointer_Phase,
		has_target: bool,
		target_id:  dagda.Object_Id,
	}
	Shift_App :: struct {
		title_a:         string,
		title_b:         string,
		rev:             u64,
		undo_depth:      int,
		events:          [dynamic]Recorded_Ev,
		holding_gesture: bool,
		editable:        [2]dagda.Object_Id,
		elements:        [2]dagda.Canvas_Element,
	}
	make_canvas :: proc(user_data: rawptr) -> dagda.Canvas {
		s := (^Shift_App)(user_data)
		s.elements = {
			{info = {id = 1, role = "field.a"}, kind = .Label, text = s.title_a, bounds = {x = 40, y = 60, width = 500, height = 70}},
			{info = {id = 2, role = "field.b"}, kind = .Label, text = s.title_b, bounds = {x = 40, y = 160, width = 500, height = 70}},
		}
		return {size = {width = 960, height = 540}, elements = s.elements[:]}
	}
	on_pointer :: proc(user_data: rawptr, ev: Pointer_Event) -> bool {
		s := (^Shift_App)(user_data)
		append(&s.events, Recorded_Ev{phase = ev.phase, has_target = ev.has_target, target_id = ev.target_id})
		switch ev.phase {
		case .Press:
			s.holding_gesture = true
		case .Move:
		case .Release, .Cancel:
			s.holding_gesture = false
		}
		return false
	}

	// "Ae\u0301BC": 'A'(0..1), 'e'+U+0301(1..4), 'B'(4..5), 'C'(5..6).
	s := Shift_App{
		title_a  = "Ae\u0301BC",
		title_b  = "Hello World",
		editable = {1, 2},
	}
	defer delete(s.events)

	h: Host
	if !font_init(&h.font) {
		return
	}
	defer font_destroy(&h.font)
	h.viewport = {width = 800, height = 540}
	h.app = App{
		user_data             = &s,
		canvas                = make_canvas,
		on_pointer            = on_pointer,
		text_edit             = {enabled = true},
		editable_text_targets = s.editable[:],
	}
	h.clipboard = memory_clipboard_interface(&h.mem_clipboard)
	testing.expect(t, host_rebuild_frame(&h))
	defer {
		memory_clipboard_destroy(&h.mem_clipboard)
		text_edit_destroy(&h.text_edit)
		dagda.frame_destroy(&h.frame)
	}

	click_at :: proc(h: ^Host, x, y: f32, shift := false) {
		if shift {
			kd: sdl.Event
			kd.type = .KEY_DOWN
			kd.key.key = sdl.K_LSHIFT
			kd.key.mod = sdl.KMOD_LSHIFT
			_, _, _ = host_dispatch_key_event(h, &kd)
		}
		d: sdl.Event
		d.type = .MOUSE_BUTTON_DOWN
		d.button.button = sdl.BUTTON_LEFT
		d.button.down = true
		d.button.x = x
		d.button.y = y
		_ = host_dispatch_mouse_event(h, &d)
		u: sdl.Event
		u.type = .MOUSE_BUTTON_UP
		u.button.button = sdl.BUTTON_LEFT
		u.button.down = false
		u.button.x = x
		u.button.y = y
		_ = host_dispatch_mouse_event(h, &u)
		if shift {
			ku: sdl.Event
			ku.type = .KEY_UP
			ku.key.key = sdl.K_LSHIFT
			_, _, _ = host_dispatch_key_event(h, &ku)
		}
	}

	el1, ok1 := dagda.find(h.frame, 1)
	el2, ok2 := dagda.find(h.frame, 2)
	testing.expect(t, ok1 && ok2)
	tx1, _, px1 := text_edit_layout(h.frame, el1.bounds)
	tx2, _, px2 := text_edit_layout(h.frame, el2.bounds)
	y1 := el1.bounds.y + el1.bounds.height * 0.5
	y2 := el2.bounds.y + el2.bounds.height * 0.5

	x_0 := tx1 - 2
	x_after_a := tx1 + font_measure_width(&h.font, "A", px1)
	x_after_e := tx1 + font_measure_width(&h.font, "Ae\u0301", px1)
	x_after_b := tx1 + font_measure_width(&h.font, "Ae\u0301B", px1)
	x_after_c := tx1 + font_measure_width(&h.font, "Ae\u0301BC", px1)
	x_b_after_hello := tx2 + font_measure_width(&h.font, "Hello", px2)

	// 1. Ordinary click after 'A' sets anchor=1, caret=1.
	click_at(&h, x_after_a, y1, false)
	testing.expect_value(t, h.text_edit.session.anchor, 1)
	testing.expect_value(t, h.text_edit.session.caret, 1)
	testing.expect_value(t, s.holding_gesture, false)
	testing.expect_value(t, len(s.events), 2)
	testing.expect_value(t, s.events[0], Recorded_Ev{.Press, true, 1})
	testing.expect_value(t, s.events[1], Recorded_Ev{.Release, true, 1})

	// 2. Shift-click after 'B' extends forward across decomposed e+U+0301 -> [1, 5].
	clear(&s.events)
	click_at(&h, x_after_b, y1, true)
	testing.expect_value(t, h.text_edit.session.anchor, 1)
	testing.expect_value(t, h.text_edit.session.caret, 5)
	testing.expect_value(t, s.rev, u64(0))
	testing.expect_value(t, s.undo_depth, 0)
	testing.expect_value(t, s.holding_gesture, false)
	testing.expect_value(t, len(s.events), 2)
	testing.expect_value(t, s.events[0], Recorded_Ev{.Press, true, 1})
	testing.expect_value(t, s.events[1], Recorded_Ev{.Release, true, 1})

	// 3. Later Shift-click after e+U+0301 shrinks selection -> [1, 4].
	click_at(&h, x_after_e, y1, true)
	testing.expect_value(t, h.text_edit.session.anchor, 1)
	testing.expect_value(t, h.text_edit.session.caret, 4)

	copy_ev: sdl.Event
	copy_ev.type = .KEY_DOWN
	copy_ev.key.key = sdl.K_C
	copy_ev.key.mod = primary_modifier()
	_, _, _ = host_dispatch_key_event(&h, &copy_ev)
	testing.expect_value(t, h.mem_clipboard.text, "e\u0301")

	// 4. Later Shift-click before 'A' reverses selection across original anchor -> anchor=1, caret=0.
	click_at(&h, x_0, y1, true)
	testing.expect_value(t, h.text_edit.session.anchor, 1)
	testing.expect_value(t, h.text_edit.session.caret, 0)

	// 5. Ordinary click after 'C' collapses selection -> [6, 6].
	click_at(&h, x_after_c, y1, false)
	testing.expect_value(t, h.text_edit.session.anchor, 6)
	testing.expect_value(t, h.text_edit.session.caret, 6)

	// 6. Shift-click in a different field (id=2) starts a fresh collapsed selection in field 2.
	clear(&s.events)
	click_at(&h, x_b_after_hello, y2, true)
	testing.expect_value(t, h.text_edit.active_id, dagda.Object_Id(2))
	testing.expect_value(t, h.text_edit.session.anchor, 5)
	testing.expect_value(t, h.text_edit.session.caret, 5)
	testing.expect_value(t, len(s.events), 2)
	testing.expect_value(t, s.events[0], Recorded_Ev{.Press, true, 2})
	testing.expect_value(t, s.events[1], Recorded_Ev{.Release, true, 2})

	// 7. During active preedit in field 2, Shift-click in field 1 is blocked and fires no pointer event.
	clear(&s.events)
	pre: sdl.Event
	pre.type = .TEXT_EDITING
	pre.edit.text = "e"
	pre.edit.start = 0
	pre.edit.length = 1
	_ = text_edit_handle_event(&h.text_edit, nil, &h.font, h.frame, h.app.text_edit, &s, &pre, s.editable[:], h.clipboard)
	click_at(&h, x_after_a, y1, true)
	testing.expect_value(t, len(s.events), 0)
	testing.expect_value(t, h.text_edit.active_id, dagda.Object_Id(2))
	testing.expect_value(t, dagda.is_composing(&h.text_edit.session), true)
	testing.expect_value(t, h.text_edit.session.preedit, "e")
}

@(test)
test_shift_click_uses_event_stream_order_when_sdl_mod_state_is_ahead :: proc(t: ^testing.T) {
	// Exercise both event-stream orders while SDL's live global mod state is
	// ahead of the dispatched click (as happens when a click and a later Shift
	// key event arrive in the same OS input batch before the host drains them).
	sync.mutex_lock(&sdl_test_mu)
	defer sync.mutex_unlock(&sdl_test_mu)
	if !sdl.Init({.VIDEO}) {
		return
	}
	defer sdl.Quit()
	driver_cstr := sdl.GetCurrentVideoDriver()
	if driver_cstr == nil || string(driver_cstr) != "dummy" {
		return
	}

	Order_App :: struct {
		title:    string,
		elements: [1]dagda.Canvas_Element,
	}
	make_canvas :: proc(user_data: rawptr) -> dagda.Canvas {
		s := (^Order_App)(user_data)
		s.elements = {
			{info = {id = 1, role = "field.a"}, kind = .Label, text = s.title, bounds = {x = 40, y = 60, width = 500, height = 70}},
		}
		return {size = {width = 960, height = 540}, elements = s.elements[:]}
	}
	on_commit :: proc(user_data: rawptr, id: dagda.Object_Id, new_text: string) -> bool {
		s := (^Order_App)(user_data)
		if id != 1 {
			return false
		}
		cloned, err := strings.clone(new_text)
		if err != nil {
			return false
		}
		delete(s.title)
		s.title = cloned
		return true
	}

	s := Order_App{title = strings.clone("Slide Title")}
	defer delete(s.title)

	h: Host
	if !font_init(&h.font) {
		return
	}
	defer font_destroy(&h.font)
	h.viewport = {width = 800, height = 540}
	h.app = App{
		user_data = &s,
		canvas    = make_canvas,
		text_edit = {enabled = true, target_id = 1, on_commit = on_commit},
	}
	testing.expect(t, host_rebuild_frame(&h))
	defer {
		text_edit_destroy(&h.text_edit)
		dagda.frame_destroy(&h.frame)
	}

	el1, found := dagda.find(h.frame, 1)
	testing.expect(t, found)
	tx, _, _ := text_edit_layout(h.frame, el1.bounds)
	y1 := el1.bounds.y + el1.bounds.height * 0.5
	x_start := tx - 4
	x_end := el1.bounds.x + el1.bounds.width - 4

	prev_mod := sdl.GetModState()
	defer sdl.SetModState(prev_mod)

	dispatch_click :: proc(h: ^Host, x, y: f32) {
		d: sdl.Event
		d.type = .MOUSE_BUTTON_DOWN
		d.button.button = sdl.BUTTON_LEFT
		d.button.down = true
		d.button.x = x
		d.button.y = y
		u := d
		u.type = .MOUSE_BUTTON_UP
		u.button.down = false
		_ = host_dispatch_mouse_event(h, &d)
		_ = host_dispatch_mouse_event(h, &u)
	}
	dispatch_shift :: proc(h: ^Host, key: sdl.Keycode, down: bool) {
		ev: sdl.Event
		ev.type = down ? .KEY_DOWN : .KEY_UP
		ev.key.key = key
		ev.key.mod = down ? (key == sdl.K_RSHIFT ? sdl.KMOD_RSHIFT : sdl.KMOD_LSHIFT) : {}
		ev.key.down = down
		_, _, _ = host_dispatch_key_event(h, &ev)
	}
	dispatch_text :: proc(h: ^Host, s: ^Order_App, text: cstring) {
		ti: sdl.Event
		ti.type = .TEXT_INPUT
		ti.text.text = text
		tres := text_edit_handle_event(&h.text_edit, nil, &h.font, h.frame, h.app.text_edit, s, &ti)
		if tres.needs_rebuild {
			_ = host_rebuild_frame(h)
			text_edit_apply_committed(&h.text_edit, nil, &h.font, h.frame, h.app.text_edit, &tres.pending_edit)
		}
	}

	// Order 1: Focus with caret at start (0). Global SDL mod state ALREADY has
	// KMOD_LSHIFT set (from a later queued Shift-down), then plain click at end
	// arrives BEFORE Shift-down -> must collapse caret to end, so typing "X"
	// commits "Slide TitleX" (NOT "X").
	sdl.SetModState({})
	dispatch_click(&h, x_start, y1)
	testing.expect_value(t, h.text_edit.session.anchor, 0)
	testing.expect_value(t, h.text_edit.session.caret, 0)

	sdl.SetModState(sdl.KMOD_LSHIFT)
	dispatch_click(&h, x_end, y1)
	testing.expect_value(t, h.text_edit.session.anchor, len("Slide Title"))
	testing.expect_value(t, h.text_edit.session.caret, len("Slide Title"))
	dispatch_shift(&h, sdl.K_LSHIFT, true)
	dispatch_shift(&h, sdl.K_LSHIFT, false)
	sdl.SetModState({})

	dispatch_text(&h, &s, "X")
	testing.expect_value(t, s.title, "Slide TitleX")

	// Reset title to "Slide Title" with caret at start (0).
	delete(s.title)
	s.title = strings.clone("Slide Title")
	testing.expect(t, host_rebuild_frame(&h))
	dispatch_click(&h, x_start, y1)
	testing.expect_value(t, h.text_edit.session.anchor, 0)
	testing.expect_value(t, h.text_edit.session.caret, 0)

	// Order 2: Shift-down -> click at end -> Shift-up, while SDL's live global
	// mod state is ALREADY cleared (ahead of the click) -> must extend selection
	// across "Slide Title", so typing "X" replaces it with "X".
	sdl.SetModState({})
	dispatch_shift(&h, sdl.K_RSHIFT, true)
	dispatch_click(&h, x_end, y1)
	testing.expect_value(t, h.text_edit.session.anchor, 0)
	testing.expect_value(t, h.text_edit.session.caret, len("Slide Title"))
	dispatch_shift(&h, sdl.K_RSHIFT, false)

	dispatch_text(&h, &s, "X")
	testing.expect_value(t, s.title, "X")

	// Focus loss while both Shifts are held clears Shift tracking cleanly.
	dispatch_shift(&h, sdl.K_LSHIFT, true)
	dispatch_shift(&h, sdl.K_RSHIFT, true)
	dispatch_shift(&h, sdl.K_LSHIFT, false)
	testing.expect_value(t, host_shift_down(&h), true)
	lost: sdl.Event
	lost.type = .WINDOW_FOCUS_LOST
	_, _, _ = host_dispatch_key_event(&h, &lost)
	testing.expect_value(t, host_shift_down(&h), false)
}

@(test)
test_narrow_field_horizontal_scroll_home_end_click_drag_ime_and_independent_views :: proc(t: ^testing.T) {
	sync.mutex_lock(&sdl_test_mu)
	defer sync.mutex_unlock(&sdl_test_mu)
	if !sdl.Init({.VIDEO}) {
		return
	}
	defer sdl.Quit()

	window := sdl.CreateWindow("scroll-test", 800, 540, {})
	if window == nil {
		return
	}
	defer sdl.DestroyWindow(window)

	Scroll_App :: struct {
		title:    string,
		editable: [2]dagda.Object_Id,
		elements: [2]dagda.Canvas_Element,
	}
	make_canvas :: proc(user_data: rawptr) -> dagda.Canvas {
		s := (^Scroll_App)(user_data)
		s.elements = {
			{info = {id = 1, role = "narrow.a"}, kind = .Label, text = s.title, bounds = {x = 40, y = 60, width = 220, height = 60}},
			{info = {id = 2, role = "narrow.b"}, kind = .Label, text = s.title, bounds = {x = 40, y = 160, width = 220, height = 60}},
		}
		return {size = {width = 960, height = 540}, elements = s.elements[:]}
	}
	on_commit :: proc(user_data: rawptr, id: dagda.Object_Id, new_text: string) -> bool {
		s := (^Scroll_App)(user_data)
		if id != 1 && id != 2 {
			return false
		}
		cloned, err := strings.clone(new_text)
		if err != nil {
			return false
		}
		delete(s.title)
		s.title = cloned
		return true
	}

	viewports := [2]dagda.Size{{width = 800, height = 540}, {width = 640, height = 480}}
	for vp in viewports {
		base_title := "0123456789 Long Narrow Editable Title Before Cafe\u0301X"
		s := Scroll_App{
			title    = strings.clone(base_title),
			editable = {1, 2},
		}
		defer delete(s.title)

		h: Host
		if !font_init(&h.font) {
			return
		}
		defer font_destroy(&h.font)
		h.ime_window = window
		h.viewport = vp
		h.app = App{
			user_data             = &s,
			canvas                = make_canvas,
			text_edit             = {enabled = true, on_commit = on_commit},
			editable_text_targets = s.editable[:],
		}
		testing.expect(t, host_rebuild_frame(&h))
		defer {
			text_edit_destroy(&h.text_edit)
			dagda.frame_destroy(&h.frame)
		}

		el1, ok1 := dagda.find(h.frame, 1)
		testing.expect(t, ok1)
		tx, _, px := text_edit_layout(h.frame, el1.bounds)
		view_w := text_edit_view_width(h.frame, el1.bounds)
		y1 := el1.bounds.y + el1.bounds.height * 0.5

		// Focus field 1 and press End -> scrolls right, caret visible at right edge, field 2 stays at 0.
		testing.expect(t, text_edit_focus_id(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, 1, s.editable[:]))
		end_ev: sdl.Event
		end_ev.type = .KEY_DOWN
		end_ev.key.key = sdl.K_END
		_, _, _ = host_dispatch_key_event(&h, &end_ev)
		scroll_end := text_edit_scroll_x(&h.text_edit, 1)
		testing.expect(t, scroll_end > 50)
		testing.expect_value(t, text_edit_scroll_x(&h.text_edit, 2), f32(0))
		cx_end := text_edit_caret_x(&h.text_edit, &h.font, h.frame, el1.bounds, s.title)
		testing.expect(t, cx_end >= tx && cx_end + TEXT_EDIT_CARET_WIDTH <= tx + view_w + 0.5)

		// Home brings start back into view; field 2 still unaffected.
		home_ev: sdl.Event
		home_ev.type = .KEY_DOWN
		home_ev.key.key = sdl.K_HOME
		_, _, _ = host_dispatch_key_event(&h, &home_ev)
		testing.expect_value(t, text_edit_scroll_x(&h.text_edit, 1), f32(0))
		testing.expect_value(t, text_edit_scroll_x(&h.text_edit, 2), f32(0))
		cx_home := text_edit_caret_x(&h.text_edit, &h.font, h.frame, el1.bounds, s.title)
		testing.expect(t, math.abs(cx_home - tx) < 0.5)

		// Press End again, then while scrolled click right beside decomposed "e\u0301" (before "X") and type "!".
		_, _, _ = host_dispatch_key_event(&h, &end_ev)
		cur_scroll := text_edit_scroll_x(&h.text_edit, 1)
		prefix_before_x := s.title[:len(s.title) - 1]
		click_x_beside_e := tx - cur_scroll + font_measure_width(&h.font, prefix_before_x, px)

		d: sdl.Event
		d.type = .MOUSE_BUTTON_DOWN
		d.button.button = sdl.BUTTON_LEFT
		d.button.down = true
		d.button.x = click_x_beside_e
		d.button.y = y1
		u := d
		u.type = .MOUSE_BUTTON_UP
		u.button.down = false
		testing.expect(t, host_dispatch_mouse_event(&h, &d))
		testing.expect(t, host_dispatch_mouse_event(&h, &u))
		testing.expect_value(t, h.text_edit.session.caret, len(s.title) - 1)

		ti: sdl.Event
		ti.type = .TEXT_INPUT
		ti.text.text = "!"
		tres := text_edit_handle_event(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, &s, &ti, s.editable[:])
		testing.expect_value(t, tres.needs_rebuild, true)
		testing.expect(t, host_rebuild_frame(&h))
		text_edit_apply_committed(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, &tres.pending_edit)
		testing.expect_value(t, s.title, "0123456789 Long Narrow Editable Title Before Cafe\u0301!X")
		testing.expect_value(t, text_edit_scroll_x(&h.text_edit, 2), f32(0))

		// Start composition near the right edge and verify painted caret X agrees with SDL_GetTextInputArea.
		_, _, _ = host_dispatch_key_event(&h, &end_ev)
		pre: sdl.Event
		pre.type = .TEXT_EDITING
		pre.edit.text = "abcdef"
		pre.edit.start = 6
		pre.edit.length = 0
		_ = text_edit_handle_event(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, &s, &pre, s.editable[:])
		painted_x := text_edit_caret_x(&h.text_edit, &h.font, h.frame, el1.bounds, s.title)
		testing.expect(t, painted_x >= el1.bounds.x && painted_x <= el1.bounds.x + el1.bounds.width)

		area: sdl.Rect
		cursor: c.int
		testing.expect(t, sdl.GetTextInputArea(window, &area, &cursor))
		sdl_anchor_x := area.x + cursor
		testing.expect(t, abs(sdl_anchor_x - c.int(math.round(painted_x))) <= 1)

		// Cancel preedit, then verify window resize while caret is at End keeps caret & IME anchor visible.
		esc: sdl.Event
		esc.type = .KEY_DOWN
		esc.key.key = sdl.K_ESCAPE
		_, _, _ = host_dispatch_key_event(&h, &esc)
		_, _, _ = host_dispatch_key_event(&h, &end_ev)
		h.viewport = {width = 500, height = 380}
		testing.expect(t, host_rebuild_frame(&h))
		el1_resized, ok_r := dagda.find(h.frame, 1)
		testing.expect(t, ok_r)
		tx_r, _, _ := text_edit_layout(h.frame, el1_resized.bounds)
		vw_r := text_edit_view_width(h.frame, el1_resized.bounds)
		cx_r := text_edit_caret_x(&h.text_edit, &h.font, h.frame, el1_resized.bounds, s.title)
		testing.expect(t, cx_r >= tx_r && cx_r + TEXT_EDIT_CARET_WIDTH <= tx_r + vw_r + 0.5)
		testing.expect(t, sdl.GetTextInputArea(window, &area, &cursor))
		testing.expect(t, abs((area.x + cursor) - c.int(math.round(cx_r))) <= 1)

		// Restore viewport, then verify dragging past left edge while scrolled clamps to 0 and scrolls to 0.
		h.viewport = vp
		testing.expect(t, host_rebuild_frame(&h))
		el1, _ = dagda.find(h.frame, 1)
		d.button.x = tx + view_w - 4
		m: sdl.Event
		m.type = .MOUSE_MOTION
		m.motion.x = el1.bounds.x - 40
		m.motion.y = y1
		u.button.x = el1.bounds.x - 40
		testing.expect(t, host_dispatch_mouse_event(&h, &d))
		testing.expect(t, host_dispatch_mouse_event(&h, &m))
		testing.expect(t, host_dispatch_mouse_event(&h, &u))
		testing.expect_value(t, h.text_edit.session.caret, 0)
		testing.expect_value(t, text_edit_scroll_x(&h.text_edit, 1), f32(0))
	}
}

@(test)
test_partly_visible_left_and_right_clipped_fields_scroll_click_and_ime :: proc(t: ^testing.T) {
	sync.mutex_lock(&sdl_test_mu)
	defer sync.mutex_unlock(&sdl_test_mu)
	if !sdl.Init({.VIDEO}) {
		return
	}
	defer sdl.Quit()

	window: ^sdl.Window
	renderer: ^sdl.Renderer
	if !sdl.CreateWindowAndRenderer("clipped-scroll-test", 960, 540, {}, &window, &renderer) {
		return
	}
	defer sdl.DestroyWindow(window)
	defer sdl.DestroyRenderer(renderer)

	Clip_App :: struct {
		title:    string,
		rev:      u64,
		editable: [2]dagda.Object_Id,
		elements: [2]dagda.Canvas_Element,
	}
	make_canvas :: proc(user_data: rawptr) -> dagda.Canvas {
		s := (^Clip_App)(user_data)
		s.elements = {
			// Right-clipped on 960x540 sheet: x=860, width=220 -> 100 visible pixels [860, 960].
			{info = {id = 1, role = "right.clipped"}, kind = .Label, text = s.title, bounds = {x = 860, y = 60, width = 220, height = 60}},
			// Left-clipped on 960x540 sheet: x=-80, width=220 -> 140 visible pixels [0, 140].
			{info = {id = 2, role = "left.clipped"}, kind = .Label, text = s.title, bounds = {x = -80, y = 160, width = 220, height = 60}},
		}
		return {size = {width = 960, height = 540}, elements = s.elements[:]}
	}
	on_commit :: proc(user_data: rawptr, id: dagda.Object_Id, new_text: string) -> bool {
		s := (^Clip_App)(user_data)
		if id != 1 && id != 2 {
			return false
		}
		cloned, err := strings.clone(new_text)
		if err != nil {
			return false
		}
		delete(s.title)
		s.title = cloned
		s.rev += 1
		return true
	}

	s := Clip_App{
		title    = strings.clone("0123456789 Long Title Cafe\u0301X"),
		editable = {1, 2},
	}
	defer delete(s.title)

	h: Host
	if !font_init(&h.font) {
		return
	}
	defer font_destroy(&h.font)
	defer font_destroy_textures(&h.font)
	h.window = window
	h.ime_window = window
	h.renderer = renderer
	h.viewport = {width = 960, height = 540}
	h.app = App{
		user_data             = &s,
		canvas                = make_canvas,
		text_edit             = {enabled = true, on_commit = on_commit},
		editable_text_targets = s.editable[:],
	}
	testing.expect(t, host_rebuild_frame(&h))
	defer {
		text_edit_destroy(&h.text_edit)
		dagda.frame_destroy(&h.frame)
	}

	count_amber_in_rect :: proc(r: ^sdl.Renderer, x0, y0, x1, y1: i32) -> int {
		surf := sdl.RenderReadPixels(r, nil)
		if surf == nil {
			return 0
		}
		defer sdl.DestroySurface(surf)
		hits := 0
		for y in y0 ..< y1 {
			for x in x0 ..< x1 {
				cr, cg, cb, ca: u8
				if sdl.ReadSurfacePixel(surf, x, y, &cr, &cg, &cb, &ca) {
					if abs(int(cr) - 255) <= 8 && abs(int(cg) - 206) <= 8 && abs(int(cb) - 84) <= 8 {
						hits += 1
					}
				}
			}
		}
		return hits
	}

	// 1. Right-clipped field (id=1): click x=915, press End, begin preedit -> caret & SDL anchor visible inside [860, 960].
	d: sdl.Event
	d.type = .MOUSE_BUTTON_DOWN
	d.button.button = sdl.BUTTON_LEFT
	d.button.down = true
	d.button.x = 915
	d.button.y = 90
	u := d
	u.type = .MOUSE_BUTTON_UP
	u.button.down = false
	testing.expect(t, host_dispatch_mouse_event(&h, &d))
	testing.expect(t, host_dispatch_mouse_event(&h, &u))
	testing.expect_value(t, h.text_edit.active_id, dagda.Object_Id(1))

	end_ev: sdl.Event
	end_ev.type = .KEY_DOWN
	end_ev.key.key = sdl.K_END
	_, _, _ = host_dispatch_key_event(&h, &end_ev)
	testing.expect_value(t, s.rev, u64(0))

	el1, _ := dagda.find(h.frame, 1)
	cx_end := text_edit_caret_x(&h.text_edit, &h.font, h.frame, el1.bounds, s.title)
	testing.expect(t, cx_end >= 860 && cx_end + TEXT_EDIT_CARET_WIDTH <= 960)
	area: sdl.Rect
	cursor: c.int
	testing.expect(t, sdl.GetTextInputArea(window, &area, &cursor))
	testing.expect(t, area.x + cursor >= 860 && area.x + cursor <= 960)
	testing.expect(t, abs((area.x + cursor) - c.int(math.round(cx_end))) <= 1)

	host_draw(&h)
	testing.expect(t, count_amber_in_rect(renderer, 860, 60, 960, 120) >= 10)

	// Begin preedit at right-clipped End -> caret & SDL anchor remain visible inside [860, 960].
	pre: sdl.Event
	pre.type = .TEXT_EDITING
	pre.edit.text = "abcdef"
	pre.edit.start = 6
	pre.edit.length = 0
	_ = text_edit_handle_event(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, &s, &pre, s.editable[:])
	cx_pre := text_edit_caret_x(&h.text_edit, &h.font, h.frame, el1.bounds, s.title)
	testing.expect(t, cx_pre >= 860 && cx_pre + TEXT_EDIT_CARET_WIDTH <= 960)
	testing.expect(t, sdl.GetTextInputArea(window, &area, &cursor))
	testing.expect(t, area.x + cursor >= 860 && area.x + cursor <= 960)
	testing.expect(t, abs((area.x + cursor) - c.int(math.round(cx_pre))) <= 1)
	host_draw(&h)
	testing.expect(t, count_amber_in_rect(renderer, 860, 60, 960, 120) >= 10)

	// Cancel preedit, press Home -> caret visible at left side of [860, 960], rev unchanged.
	esc: sdl.Event
	esc.type = .KEY_DOWN
	esc.key.key = sdl.K_ESCAPE
	_, _, _ = host_dispatch_key_event(&h, &esc)
	home_ev: sdl.Event
	home_ev.type = .KEY_DOWN
	home_ev.key.key = sdl.K_HOME
	_, _, _ = host_dispatch_key_event(&h, &home_ev)
	testing.expect_value(t, s.rev, u64(0))
	cx_home := text_edit_caret_x(&h.text_edit, &h.font, h.frame, el1.bounds, s.title)
	testing.expect(t, cx_home >= 860 && cx_home <= 900)

	// Press End, click beside visible decomposed é ("Cafe\u0301|X"), type "!" -> exact UTF-8 bytes.
	_, _, _ = host_dispatch_key_event(&h, &end_ev)
	tx1, _, px1 := text_edit_layout(h.frame, el1.bounds)
	scroll1 := text_edit_scroll_x(&h.text_edit, 1)
	click_x := tx1 - scroll1 + font_measure_width(&h.font, s.title[:len(s.title) - 1], px1)
	testing.expect(t, click_x >= 860 && click_x <= 960)
	d.button.x = click_x
	u.button.x = click_x
	testing.expect(t, host_dispatch_mouse_event(&h, &d))
	testing.expect(t, host_dispatch_mouse_event(&h, &u))
	ti: sdl.Event
	ti.type = .TEXT_INPUT
	ti.text.text = "!"
	tres := text_edit_handle_event(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, &s, &ti, s.editable[:])
	testing.expect_value(t, tres.needs_rebuild, true)
	testing.expect(t, host_rebuild_frame(&h))
	text_edit_apply_committed(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, &tres.pending_edit)
	testing.expect_value(t, s.title, "0123456789 Long Title Cafe\u0301!X")
	testing.expect_value(t, s.rev, u64(1))

	// 2. Left-clipped field (id=2): Home & End both keep caret & SDL anchor visible inside [0, 140],
	//    and clicking beside visible decomposed é edits the intended bytes.
	testing.expect(t, text_edit_focus_id(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, 2, s.editable[:]))
	el2, _ := dagda.find(h.frame, 2)
	_, _, _ = host_dispatch_key_event(&h, &home_ev)
	cx2_home := text_edit_caret_x(&h.text_edit, &h.font, h.frame, el2.bounds, s.title)
	testing.expect(t, cx2_home >= 0 && cx2_home <= 40)
	_, _, _ = host_dispatch_key_event(&h, &end_ev)
	cx2_end := text_edit_caret_x(&h.text_edit, &h.font, h.frame, el2.bounds, s.title)
	testing.expect(t, cx2_end >= 0 && cx2_end + TEXT_EDIT_CARET_WIDTH <= 140)
	testing.expect(t, sdl.GetTextInputArea(window, &area, &cursor))
	testing.expect(t, area.x + cursor >= 0 && area.x + cursor <= 140)
	testing.expect_value(t, s.rev, u64(1))

	tx2, _, px2 := text_edit_layout(h.frame, el2.bounds)
	scroll2 := text_edit_scroll_x(&h.text_edit, 2)
	// Click right after "Cafe\u0301" (before "!X") inside visible [0, 140].
	click_x2 := tx2 - scroll2 + font_measure_width(&h.font, s.title[:len(s.title) - 2], px2)
	testing.expect(t, click_x2 >= 0 && click_x2 <= 140)
	d.button.x = click_x2
	d.button.y = 190
	u.button.x = click_x2
	u.button.y = 190
	testing.expect(t, host_dispatch_mouse_event(&h, &d))
	testing.expect(t, host_dispatch_mouse_event(&h, &u))
	ti.text.text = "?"
	tres = text_edit_handle_event(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, &s, &ti, s.editable[:])
	testing.expect_value(t, tres.needs_rebuild, true)
	testing.expect(t, host_rebuild_frame(&h))
	text_edit_apply_committed(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, &tres.pending_edit)
	testing.expect_value(t, s.title, "0123456789 Long Title Cafe\u0301?!X")
	testing.expect_value(t, s.rev, u64(2))
}

@(test)
test_scroll_offsets_bounded_on_empty_frame_blur_ineligible_and_replacements :: proc(t: ^testing.T) {
	Prune_App :: struct {
		active_id: dagda.Object_Id,
		empty:     bool,
		eligible:  bool,
		title:     string,
		targets:   [1]dagda.Object_Id,
		elements:  [1]dagda.Canvas_Element,
	}
	make_canvas :: proc(user_data: rawptr) -> dagda.Canvas {
		s := (^Prune_App)(user_data)
		if s.empty {
			return {size = {width = 960, height = 540}, elements = nil}
		}
		s.elements = {
			{info = {id = s.active_id, role = "dyn.field"}, kind = .Label, text = s.title, bounds = {x = 40, y = 60, width = 200, height = 60}},
		}
		return {size = {width = 960, height = 540}, elements = s.elements[:]}
	}

	s := Prune_App{
		active_id = 1,
		eligible  = true,
		title     = "0123456789 Long Scrollable Title For Lifetime Pruning Test",
		targets   = {1},
	}

	h: Host
	if !font_init(&h.font) {
		return
	}
	defer font_destroy(&h.font)
	h.viewport = {width = 800, height = 540}
	h.app = App{
		user_data             = &s,
		canvas                = make_canvas,
		text_edit             = {enabled = true},
		editable_text_targets = s.targets[:],
	}
	testing.expect(t, host_rebuild_frame(&h))
	defer {
		text_edit_destroy(&h.text_edit)
		dagda.frame_destroy(&h.frame)
	}

	end_ev: sdl.Event
	end_ev.type = .KEY_DOWN
	end_ev.key.key = sdl.K_END

	// 1. Focus + End -> scroll entry created for id=1.
	testing.expect(t, text_edit_focus_id(&h.text_edit, nil, &h.font, h.frame, h.app.text_edit, 1, h.app.editable_text_targets))
	_, _, _ = host_dispatch_key_event(&h, &end_ev)
	saved_scroll := text_edit_scroll_x(&h.text_edit, 1)
	testing.expect(t, saved_scroll > 50)
	testing.expect_value(t, len(h.text_edit.scroll_offsets), 1)

	// 2. Surviving field temporarily loses focus -> scroll entry is preserved across reconcile,
	//    and 10,000 unchanged rebuilds leave a dedicated Default_Temp_Allocator untouched.
	testing.expect(t, text_edit_blur(&h.text_edit, nil))
	{
		temp_alloc: runtime.Default_Temp_Allocator
		runtime.default_temp_allocator_init(&temp_alloc, runtime.DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE, context.allocator)
		defer runtime.default_temp_allocator_destroy(&temp_alloc)
		prev_temp := context.temp_allocator
		context.temp_allocator = runtime.default_temp_allocator(&temp_alloc)
		defer context.temp_allocator = prev_temp

		testing.expect(t, host_rebuild_frame(&h))
		used_after_warmup := temp_alloc.arena.total_used
		for _ in 0 ..< 10_000 {
			testing.expect(t, host_rebuild_frame(&h))
		}
		testing.expect_value(t, temp_alloc.arena.total_used, used_after_warmup)
		testing.expect_value(t, temp_alloc.arena.total_used, uint(0))
	}
	testing.expect_value(t, len(h.text_edit.scroll_offsets), 1)
	testing.expect_value(t, text_edit_scroll_x(&h.text_edit, 1), saved_scroll)

	// 3. Reconcile to an empty frame -> stale entry released immediately.
	s.empty = true
	testing.expect(t, host_rebuild_frame(&h))
	testing.expect_value(t, len(h.text_edit.scroll_offsets), 0)

	// 4. Restore field, scroll again, then mark ineligible -> entry released immediately.
	s.empty = false
	testing.expect(t, host_rebuild_frame(&h))
	testing.expect(t, text_edit_focus_id(&h.text_edit, nil, &h.font, h.frame, h.app.text_edit, 1, h.app.editable_text_targets))
	_, _, _ = host_dispatch_key_event(&h, &end_ev)
	testing.expect_value(t, len(h.text_edit.scroll_offsets), 1)

	h.app.text_edit.enabled = false
	testing.expect(t, host_rebuild_frame(&h))
	testing.expect_value(t, len(h.text_edit.scroll_offsets), 0)
	h.app.text_edit.enabled = true

	// 5. Repeated replacements across 50 distinct IDs in one live window stay bounded to 1 entry.
	for next_id in dagda.Object_Id(100) ..< dagda.Object_Id(150) {
		s.active_id = next_id
		s.targets[0] = next_id
		testing.expect(t, host_rebuild_frame(&h))
		testing.expect(t, text_edit_focus_id(&h.text_edit, nil, &h.font, h.frame, h.app.text_edit, next_id, h.app.editable_text_targets))
		_, _, _ = host_dispatch_key_event(&h, &end_ev)
		testing.expect(t, text_edit_scroll_x(&h.text_edit, next_id) > 50)
		testing.expect_value(t, len(h.text_edit.scroll_offsets), 1)
	}
}

@(test)
test_clipboard_ctrl_x_cut_combining_failures_reject_repeat_and_preedit :: proc(t: ^testing.T) {
	Cut_App :: struct {
		title:          string,
		rev:            u64,
		commit_calls:   int,
		reject_commits: bool,
		last_id:        dagda.Object_Id,
		undo_stack:     [dynamic]string,
		editable:       [2]dagda.Object_Id,
		elements:       [2]dagda.Canvas_Element,
	}
	make_canvas :: proc(user_data: rawptr) -> dagda.Canvas {
		s := (^Cut_App)(user_data)
		s.elements = {
			{info = {id = 1, role = "outline.title"}, kind = .Label, text = s.title, bounds = {x = 40, y = 40, width = 500, height = 60}},
			{info = {id = 2, role = "canvas.title"}, kind = .Label, text = s.title, bounds = {x = 40, y = 140, width = 500, height = 60}},
		}
		return {size = {width = 960, height = 540}, elements = s.elements[:]}
	}
	on_commit :: proc(user_data: rawptr, id: dagda.Object_Id, new_text: string) -> bool {
		s := (^Cut_App)(user_data)
		s.commit_calls += 1
		if s.reject_commits || new_text == s.title {
			return false
		}
		cloned, err := strings.clone(new_text)
		if err != nil {
			return false
		}
		append(&s.undo_stack, s.title)
		s.title = cloned
		s.rev += 1
		s.last_id = id
		return true
	}
	on_undo :: proc(user_data: rawptr, id: dagda.Object_Id) -> bool {
		s := (^Cut_App)(user_data)
		if len(s.undo_stack) == 0 {
			return false
		}
		delete(s.title)
		s.title = pop(&s.undo_stack)
		s.rev += 1
		s.last_id = id
		return true
	}

	Fail_Clipboard :: struct {
		mc:       Memory_Clipboard,
		fail_set: bool,
	}
	fail_cb_set :: proc(ctx: rawptr, text: string) -> bool {
		fc := (^Fail_Clipboard)(ctx)
		if fc.fail_set {
			return false
		}
		return memory_clipboard_set(&fc.mc, text)
	}
	fail_cb_get :: proc(ctx: rawptr, allocator := context.allocator) -> (string, bool) {
		fc := (^Fail_Clipboard)(ctx)
		return memory_clipboard_get(&fc.mc, allocator)
	}

	// "Ae\u0301B": 'A'(0..1), 'e'+U+0301(1..4 -> 0x65 0xCC 0x81), 'B'(4..5).
	s := Cut_App{
		title    = strings.clone("Ae\u0301B"),
		editable = {1, 2},
	}
	defer {
		delete(s.title)
		for prev in s.undo_stack {
			delete(prev)
		}
		delete(s.undo_stack)
	}

	fc: Fail_Clipboard
	defer memory_clipboard_destroy(&fc.mc)
	cb := Clipboard{ctx = &fc, get = fail_cb_get, set = fail_cb_set}

	h: Host
	h.viewport = {width = 800, height = 540}
	h.app = App{
		user_data             = &s,
		canvas                = make_canvas,
		text_edit             = {enabled = true, on_commit = on_commit, on_undo = on_undo},
		editable_text_targets = s.editable[:],
	}
	h.clipboard = cb
	testing.expect(t, host_rebuild_frame(&h))
	defer {
		text_edit_destroy(&h.text_edit)
		dagda.frame_destroy(&h.frame)
	}

	dispatch_key :: proc(h: ^Host, key: sdl.Keycode, mod: sdl.Keymod = {}, repeat := false) {
		ev: sdl.Event
		ev.type = .KEY_DOWN
		ev.key.key = key
		ev.key.mod = mod
		ev.key.repeat = repeat
		rebuild, has_pending, pending := host_dispatch_key_event(h, &ev)
		if rebuild {
			_ = host_rebuild_frame(h)
			if has_pending {
				text_edit_apply_committed(&h.text_edit, nil, nil, h.frame, h.app.text_edit, &pending)
			}
		}
	}

	// Focus field 1 (id=1). Seed clipboard with a known value.
	testing.expect(t, text_edit_focus_id(&h.text_edit, nil, nil, h.frame, h.app.text_edit, 1, s.editable[:]))
	testing.expect(t, clipboard_set(cb, "seeded"))

	// 1. Empty selection: Ctrl+X leaves document and seeded clipboard untouched.
	dispatch_key(&h, sdl.K_X, primary_modifier())
	testing.expect_value(t, s.title, "Ae\u0301B")
	testing.expect_value(t, s.commit_calls, 0)
	testing.expect_value(t, fc.mc.text, "seeded")

	// Select decomposed "e\u0301" (bytes 1..4).
	h.text_edit.session.anchor = 1
	h.text_edit.session.caret = 4

	// 2. Repeated Ctrl+X keydown leaves document, selection, and clipboard untouched.
	dispatch_key(&h, sdl.K_X, primary_modifier(), repeat = true)
	testing.expect_value(t, s.title, "Ae\u0301B")
	testing.expect_value(t, s.commit_calls, 0)
	testing.expect_value(t, fc.mc.text, "seeded")
	testing.expect_value(t, h.text_edit.session.anchor, 1)
	testing.expect_value(t, h.text_edit.session.caret, 4)

	// 3. Failing clipboard setter: zero edit proposals to app, selection & clipboard survive.
	fc.fail_set = true
	dispatch_key(&h, sdl.K_X, primary_modifier())
	testing.expect_value(t, s.title, "Ae\u0301B")
	testing.expect_value(t, s.commit_calls, 0)
	testing.expect_value(t, s.rev, u64(0))
	testing.expect_value(t, len(s.undo_stack), 0)
	testing.expect_value(t, fc.mc.text, "seeded")
	testing.expect_value(t, h.text_edit.session.anchor, 1)
	testing.expect_value(t, h.text_edit.session.caret, 4)
	fc.fail_set = false

	// 4. Active IME composition: Ctrl+X leaves preedit, selection, document, and seeded clipboard intact.
	pre: sdl.Event
	pre.type = .TEXT_EDITING
	pre.edit.text = "pre"
	pre.edit.start = 3
	pre.edit.length = 0
	_ = text_edit_handle_event(&h.text_edit, nil, nil, h.frame, h.app.text_edit, &s, &pre, s.editable[:], cb)
	testing.expect_value(t, dagda.is_composing(&h.text_edit.session), true)
	dispatch_key(&h, sdl.K_X, primary_modifier())
	testing.expect_value(t, dagda.is_composing(&h.text_edit.session), true)
	testing.expect_value(t, h.text_edit.session.preedit, "pre")
	testing.expect_value(t, s.title, "Ae\u0301B")
	testing.expect_value(t, s.commit_calls, 0)
	testing.expect_value(t, fc.mc.text, "seeded")
	testing.expect_value(t, h.text_edit.session.anchor, 1)
	testing.expect_value(t, h.text_edit.session.caret, 4)
	dispatch_key(&h, sdl.K_ESCAPE)

	// 5. App rejection: document, rev, undo, and selection survive; clipboard may retain copied text.
	s.reject_commits = true
	dispatch_key(&h, sdl.K_X, primary_modifier())
	testing.expect_value(t, s.title, "Ae\u0301B")
	testing.expect_value(t, s.commit_calls, 1)
	testing.expect_value(t, s.rev, u64(0))
	testing.expect_value(t, len(s.undo_stack), 0)
	testing.expect_value(t, h.text_edit.session.anchor, 1)
	testing.expect_value(t, h.text_edit.session.caret, 4)
	testing.expect_value(t, fc.mc.text, "e\u0301")
	s.reject_commits = false

	// 6. Accepted Ctrl+X: exact bytes 65 CC 81 copied, title becomes "AB", caret collapses to 1,
	//    focus stays in field 1, 1 revision & 1 undo entry; one undo restores exact "Ae\u0301B".
	testing.expect(t, clipboard_set(cb, "seeded2"))
	dispatch_key(&h, sdl.K_X, primary_modifier())
	testing.expect_value(t, len(fc.mc.text), 3)
	testing.expect_value(t, fc.mc.text[0], u8(0x65))
	testing.expect_value(t, fc.mc.text[1], u8(0xCC))
	testing.expect_value(t, fc.mc.text[2], u8(0x81))
	testing.expect_value(t, s.title, "AB")
	testing.expect_value(t, s.rev, u64(1))
	testing.expect_value(t, len(s.undo_stack), 1)
	testing.expect_value(t, s.last_id, dagda.Object_Id(1))
	testing.expect_value(t, h.text_edit.focused, true)
	testing.expect_value(t, h.text_edit.active_id, dagda.Object_Id(1))
	testing.expect_value(t, h.text_edit.session.anchor, 1)
	testing.expect_value(t, h.text_edit.session.caret, 1)

	dispatch_key(&h, sdl.K_Z, primary_modifier())
	testing.expect_value(t, s.title, "Ae\u0301B")
	testing.expect_value(t, s.rev, u64(2))
	testing.expect_value(t, len(s.undo_stack), 0)

	// 7. Embedded NUL in selection: declined before on_commit, preserving seeded clipboard and selection.
	delete(s.title)
	s.title = strings.clone("a\x00b")
	testing.expect(t, host_rebuild_frame(&h))
	testing.expect(t, clipboard_set(cb, "keep-nul"))
	h.text_edit.session.anchor = 0
	h.text_edit.session.caret = 3
	commits_before := s.commit_calls
	dispatch_key(&h, sdl.K_X, primary_modifier())
	testing.expect_value(t, s.commit_calls, commits_before)
	testing.expect_value(t, s.title, "a\x00b")
	testing.expect_value(t, fc.mc.text, "keep-nul")
	testing.expect_value(t, h.text_edit.session.anchor, 0)
	testing.expect_value(t, h.text_edit.session.caret, 3)
}

@(test)
test_action_origin_local_pointer_keyboard_and_thread_scope :: proc(t: ^testing.T) {
	Origin_App :: struct {
		origins:       [dynamic]Action_Origin,
		frame_origins: [dynamic]Action_Origin,
		other_thread:  Action_Origin,
		check_thread:  bool,
		elements:      [1]dagda.Canvas_Element,
	}
	make_canvas :: proc(user_data: rawptr) -> dagda.Canvas {
		s := (^Origin_App)(user_data)
		append(&s.frame_origins, current_action_origin())
		s.elements = {
			{info = {id = 2, role = "item.add"}, kind = .Button, text = "Add", bounds = {x = 80, y = 80, width = 160, height = 60}},
		}
		return {size = {width = 960, height = 540}, elements = s.elements[:]}
	}
	on_action :: proc(user_data: rawptr, id: dagda.Object_Id, action: dagda.Action) -> bool {
		s := (^Origin_App)(user_data)
		if id != 2 || action != .Activate {
			return false
		}
		append(&s.origins, current_action_origin())
		if s.check_thread {
			// Verify thread-local scoping: another thread observes .None while host thread is inside handler.
			worker := thread.create_and_start_with_poly_data(s, proc(st: ^Origin_App) {
				st.other_thread = current_action_origin()
			})
			thread.join(worker)
			thread.destroy(worker)
		}
		return true
	}
	noop_pointer :: proc(_: rawptr, _: Pointer_Event) -> bool {
		return false
	}

	// Outside any host-delivered handler call, origin is .None.
	testing.expect_value(t, current_action_origin(), Action_Origin.None)

	s := Origin_App{other_thread = .Local}
	defer {
		delete(s.origins)
		delete(s.frame_origins)
	}

	h: Host
	h.viewport = {width = 800, height = 540}
	h.app = App{
		user_data = &s,
		canvas    = make_canvas,
		handle    = on_action,
	}
	testing.expect(t, host_rebuild_frame(&h))
	defer dagda.frame_destroy(&h.frame)

	btn, found := dagda.find(h.frame, 2)
	testing.expect(t, found)
	cx := btn.bounds.x + btn.bounds.width * 0.5
	cy := btn.bounds.y + btn.bounds.height * 0.5

	down: sdl.Event
	down.type = .MOUSE_BUTTON_DOWN
	down.button.button = sdl.BUTTON_LEFT
	down.button.down = true
	down.button.x = cx
	down.button.y = cy
	up := down
	up.type = .MOUSE_BUTTON_UP
	up.button.down = false

	// 1. Local pointer click (without on_pointer) -> .Local, and .None on another thread & in rebuild.
	s.check_thread = true
	testing.expect(t, host_dispatch_mouse_event(&h, &down))
	testing.expect(t, host_dispatch_mouse_event(&h, &up))
	s.check_thread = false
	testing.expect_value(t, s.other_thread, Action_Origin.None)
	testing.expect_value(t, current_action_origin(), Action_Origin.None)

	// 2. Local pointer click (with on_pointer -> release activation path) -> .Local.
	h.app.on_pointer = noop_pointer
	testing.expect(t, host_dispatch_mouse_event(&h, &down))
	testing.expect(t, host_dispatch_mouse_event(&h, &up))
	testing.expect_value(t, current_action_origin(), Action_Origin.None)

	// 3. Local keyboard activation (Tab -> Enter, then Space down + Space up) -> .Local, .Local.
	key_ev :: proc(kind: sdl.EventType, key: sdl.Keycode) -> sdl.Event {
		ev: sdl.Event
		ev.type = kind
		ev.key.key = key
		ev.key.down = kind == .KEY_DOWN
		return ev
	}
	tab := key_ev(.KEY_DOWN, sdl.K_TAB)
	enter := key_ev(.KEY_DOWN, sdl.K_RETURN)
	space_d := key_ev(.KEY_DOWN, sdl.K_SPACE)
	space_u := key_ev(.KEY_UP, sdl.K_SPACE)
	_, _, _ = host_dispatch_key_event(&h, &tab)
	rebuild_e, _, _ := host_dispatch_key_event(&h, &enter)
	testing.expect_value(t, rebuild_e, true)
	testing.expect(t, host_rebuild_frame(&h))
	_, _, _ = host_dispatch_key_event(&h, &space_d)
	rebuild_s, _, _ := host_dispatch_key_event(&h, &space_u)
	testing.expect_value(t, rebuild_s, true)
	testing.expect(t, host_rebuild_frame(&h))
	testing.expect_value(t, current_action_origin(), Action_Origin.None)

	// Verify exact recorded origins: 4 Local (click, pointer-click, Enter, Space).
	expected := [4]Action_Origin{.Local, .Local, .Local, .Local}
	testing.expect_value(t, len(s.origins), len(expected))
	for want, i in expected {
		if i < len(s.origins) {
			testing.expect_value(t, s.origins[i], want)
		}
	}
	// Every single frame builder invocation observed .None.
	testing.expect(t, len(s.frame_origins) >= 4)
	for fo in s.frame_origins {
		testing.expect_value(t, fo, Action_Origin.None)
	}
}

Failed_Start_State :: struct {
	ready_calls:   int,
	second_result: Rebuild_Result,
}

failed_start_failed_handle: Rebuild_Handle

failed_ready :: proc(user_data: rawptr, handle: Rebuild_Handle) {
	s := (^Failed_Start_State)(user_data)
	s.ready_calls += 1
}

second_ready :: proc(user_data: rawptr, handle: Rebuild_Handle) {
	s := (^Failed_Start_State)(user_data)
	s.ready_calls += 1
	s.second_result = request_rebuild(failed_start_failed_handle)
	ev: sdl.Event
	ev.type = .QUIT
	_ = sdl.PushEvent(&ev)
}

failed_view :: proc(_: rawptr) -> dagda.View { return {} }

@(test)
test_failed_start_publishes_no_handle :: proc(t: ^testing.T) {
	sync.mutex_guard(&sdl_test_mu)
	state: Failed_Start_State
	storage: Rebuild_Handle
	app := App{
		title = "Dagda — Failed Start", width = 320, height = 160,
		user_data = &state, view = failed_view,
		rebuild_handle = &storage, on_ready = failed_ready,
	}
	bad_path := fmt.tprintf("/tmp/dagda-no-such-dir-%d/x.sock", posix.getpid())
	code := run(app, {socket_path = bad_path})
	testing.expect_value(t, code, 1)
	testing.expect_value(t, state.ready_calls, 0)
	testing.expect_value(t, storage.id, u64(0))
	failed_start_failed_handle = storage
	testing.expect_value(t, request_rebuild(storage), Rebuild_Result.Stale)

	// A second ordinary window in the same process: asking it
	// to rebuild through the failed window's handle is Stale,
	// never Posted.
	sock_dir := fmt.tprintf("/tmp/dagda-sdlhost-restart-%d", posix.getpid())
	_ = os.make_directory(sock_dir)
	defer _ = os.remove(sock_dir)
	state2: Failed_Start_State
	app2 := App{
		title = "Dagda — Restart", width = 320, height = 160,
		user_data = &state2, view = failed_view, on_ready = second_ready,
	}
	code2 := run(app2, {socket_path = fmt.tprintf("%s/x.sock", sock_dir)})
	testing.expect_value(t, code2, 0)
	testing.expect_value(t, state2.ready_calls, 1)
	testing.expect_value(t, state2.second_result, Rebuild_Result.Stale)
}

@(test)
test_parse_move_window_args_bounds :: proc(t: ^testing.T) {
	x, y, ok := parse_move_window_args("0 0")
	testing.expect(t, ok)
	testing.expect_value(t, x, c.int(0))
	testing.expect_value(t, y, c.int(0))

	x, y, ok = parse_move_window_args("-120 450")
	testing.expect(t, ok)
	testing.expect_value(t, x, c.int(-120))
	testing.expect_value(t, y, c.int(450))

	x, y, ok = parse_move_window_args("2147483647 -2147483648")
	testing.expect(t, ok)
	testing.expect_value(t, x, c.int(2147483647))
	testing.expect_value(t, y, c.int(-2147483648))

	// Values outside SDL's c.int range (such as 2^32) must be rejected instead of narrowed.
	_, _, ok = parse_move_window_args("4294967296 4294967296")
	testing.expect(t, !ok)
	_, _, ok = parse_move_window_args("2147483648 0")
	testing.expect(t, !ok)
	_, _, ok = parse_move_window_args("0 -2147483649")
	testing.expect(t, !ok)
	_, _, ok = parse_move_window_args("100")
	testing.expect(t, !ok)
}

@(test)
test_host_draw_scales_to_2x_output_surface :: proc(t: ^testing.T) {
	sync.mutex_guard(&sdl_test_mu)
	if !sdl.Init({.VIDEO}) {
		testing.fail_now(t, "SDL_Init failed")
	}
	defer sdl.Quit()

	HiDPI_State :: struct {
		title:    string,
		elements: [2]dagda.Canvas_Element,
	}
	hidpi_canvas :: proc(user_data: rawptr) -> dagda.Canvas {
		s := (^HiDPI_State)(user_data)
		s.elements = {
			{
				info   = {id = 2, role = "canvas.title"},
				kind   = .Label,
				text   = s.title,
				bounds = {x = 80, y = 200, width = 640, height = 80},
			},
			{
				info   = {id = 3, role = "canvas.narrow"},
				kind   = .Label,
				text   = "WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW",
				bounds = {x = 80, y = 320, width = 160, height = 64},
			},
		}
		return {
			size     = {width = 960, height = 540},
			elements = s.elements[:],
		}
	}

	read_rgb :: proc(surf: ^sdl.Surface, x, y: i32) -> [3]u8 {
		r, g, b, a: u8
		ok := sdl.ReadSurfacePixel(surf, c.int(x), c.int(y), &r, &g, &b, &a)
		assert(ok)
		return {r, g, b}
	}

	find_amber_caret_col :: proc(surf: ^sdl.Surface, bounds: dagda.Rect, scale: f32) -> (col: i32, found: bool) {
		x0 := max(i32(0), i32(math.floor(bounds.x * scale)) + 2)
		x1 := min(i32(surf.w), i32(math.ceil((bounds.x + bounds.width) * scale)) - 2)
		y0 := max(i32(0), i32(math.floor(bounds.y * scale)) + 4)
		y1 := min(i32(surf.h), i32(math.floor((bounds.y + bounds.height * 0.65) * scale)))
		for x := x0; x < x1; x += 1 {
			hits := 0
			for y := y0; y < y1; y += 1 {
				rgb := read_rgb(surf, x, y)
				if abs(int(rgb[0]) - 255) <= 10 && abs(int(rgb[1]) - 206) <= 10 && abs(int(rgb[2]) - 84) <= 10 {
					hits += 1
				}
			}
			if hits >= 12 {
				return x, true
			}
		}
		return -1, false
	}

	state := HiDPI_State{
		title = "Cafe\u0301 Slide Title",
	}
	editable_ids := [2]dagda.Object_Id{2, 3}

	surf1 := sdl.CreateSurface(1600, 1080, .ABGR8888)
	testing.expect(t, surf1 != nil)
	defer sdl.DestroySurface(surf1)
	ren1 := sdl.CreateSoftwareRenderer(surf1)
	testing.expect(t, ren1 != nil)
	defer sdl.DestroyRenderer(ren1)

	h: Host
	h.app = {
		user_data             = &state,
		canvas                = hidpi_canvas,
		text_edit             = {enabled = true, target_id = 2},
		editable_text_targets = editable_ids[:],
	}
	h.renderer = ren1
	h.viewport = {width = 800, height = 540}
	testing.expect(t, font_init(&h.font))
	defer font_destroy(&h.font)
	defer font_destroy_textures(&h.font)
	defer text_edit_destroy(&h.text_edit)
	defer dagda.frame_destroy(&h.frame)

	testing.expect(t, host_rebuild_frame(&h))
	el1, ok_el1 := dagda.find(h.frame, 2)
	testing.expect(t, ok_el1)
	text_x1, _, px1 := text_edit_layout(h.frame, el1.bounds)
	w_caf1 := font_measure_width(&h.font, "Caf", px1)
	expected_caret1 := text_x1 + w_caf1
	_ = text_edit_click_id(&h.text_edit, nil, &h.font, h.frame, h.app.text_edit, 2, expected_caret1 + 1.0, editable_ids[:])

	// Draw without setting any scale in the test; host_draw must derive 2x itself.
	host_draw(&h)

	cap1 := sdl.RenderReadPixels(h.renderer, nil)
	testing.expect(t, cap1 != nil)
	defer sdl.DestroySurface(cap1)
	testing.expect_value(t, cap1.w, c.int(1600))
	testing.expect_value(t, cap1.h, c.int(1080))

	// Sheet pixel (1200, 540) must be canvas sheet (26, 31, 42), while letterbox (1200, 40) & (1200, 1040) must be (14, 16, 22).
	testing.expect_value(t, read_rgb(cap1, 1200, 540), [3]u8{26, 31, 42})
	testing.expect_value(t, read_rgb(cap1, 1200, 40), [3]u8{14, 16, 22})
	testing.expect_value(t, read_rgb(cap1, 1200, 1040), [3]u8{14, 16, 22})

	// Caret must appear at ~2x logical caret X (around column 222), not at 1x (~111).
	caret_col1, found_caret1 := find_amber_caret_col(cap1, el1.bounds, 2.0)
	testing.expect(t, found_caret1)
	if found_caret1 {
		testing.expect(t, math.abs(f32(caret_col1) / 2.0 - expected_caret1) <= 2.0)
	}

	// Field clip at 2x: the narrow overflowing field (id=3) must not paint white glyph pixels to its right.
	narrow1, ok_n1 := dagda.find(h.frame, 3)
	testing.expect(t, ok_n1)
	right_outside_x := i32(math.ceil((narrow1.bounds.x + narrow1.bounds.width) * 2.0)) + 8
	narrow_mid_y := i32(math.floor((narrow1.bounds.y + narrow1.bounds.height * 0.5) * 2.0))
	testing.expect_value(t, read_rgb(cap1, right_outside_x, narrow_mid_y), [3]u8{26, 31, 42})

	// Resize to 640x480 logical points on a 1280x960 (2x) backing surface and verify scale updates cleanly.
	font_destroy_textures(&h.font)
	surf2 := sdl.CreateSurface(1280, 960, .ABGR8888)
	testing.expect(t, surf2 != nil)
	defer sdl.DestroySurface(surf2)
	ren2 := sdl.CreateSoftwareRenderer(surf2)
	testing.expect(t, ren2 != nil)
	defer sdl.DestroyRenderer(ren2)
	defer font_destroy_textures(&h.font)

	h.renderer = ren2
	h.viewport = {width = 640, height = 480}
	testing.expect(t, host_rebuild_frame(&h))
	el2, ok_el2 := dagda.find(h.frame, 2)
	testing.expect(t, ok_el2)
	text_x2, _, px2 := text_edit_layout(h.frame, el2.bounds)
	w_caf2 := font_measure_width(&h.font, "Caf", px2)
	expected_caret2 := text_x2 + w_caf2

	host_draw(&h)

	cap2 := sdl.RenderReadPixels(h.renderer, nil)
	testing.expect(t, cap2 != nil)
	defer sdl.DestroySurface(cap2)
	testing.expect_value(t, cap2.w, c.int(1280))
	testing.expect_value(t, cap2.h, c.int(960))
	testing.expect_value(t, read_rgb(cap2, 960, 480), [3]u8{26, 31, 42})
	testing.expect_value(t, read_rgb(cap2, 960, 40), [3]u8{14, 16, 22})

	caret_col2, found_caret2 := find_amber_caret_col(cap2, el2.bounds, 2.0)
	testing.expect(t, found_caret2)
	if found_caret2 {
		testing.expect(t, math.abs(f32(caret_col2) / 2.0 - expected_caret2) <= 2.0)
	}
}

@(test)
test_host_draw_2x_canvas_clip_pixel_centers :: proc(t: ^testing.T) {
	sync.mutex_guard(&sdl_test_mu)
	if !sdl.Init({.VIDEO}) {
		testing.fail_now(t, "SDL_Init failed")
	}
	defer sdl.Quit()

	Edge_State :: struct {
		elements: [2]dagda.Canvas_Element,
	}
	edge_canvas :: proc(user_data: rawptr) -> dagda.Canvas {
		s := (^Edge_State)(user_data)
		// Editable field comes first so text_edit_draw installs and restores its
		// nested clip before the overflowing button paints.
		s.elements = {
			{
				info   = {id = 2, role = "canvas.title"},
				kind   = .Label,
				text   = "Editable Title",
				bounds = {x = 360, y = 200, width = 320, height = 80},
			},
			{
				info   = {id = 4, role = "canvas.overflow"},
				kind   = .Button,
				text   = "Overflow",
				bounds = {x = 70, y = -40, width = 240, height = 620},
			},
		}
		return {
			size     = {width = 960, height = 540},
			elements = s.elements[:],
		}
	}

	read_rgb :: proc(surf: ^sdl.Surface, x, y: i32) -> [3]u8 {
		r, g, b, a: u8
		ok := sdl.ReadSurfacePixel(surf, c.int(x), c.int(y), &r, &g, &b, &a)
		assert(ok)
		return {r, g, b}
	}

	state: Edge_State
	editable_ids := [1]dagda.Object_Id{2}

	surf := sdl.CreateSurface(1602, 1084, .ABGR8888)
	testing.expect(t, surf != nil)
	defer sdl.DestroySurface(surf)
	ren := sdl.CreateSoftwareRenderer(surf)
	testing.expect(t, ren != nil)
	defer sdl.DestroyRenderer(ren)

	h: Host
	h.app = {
		user_data             = &state,
		canvas                = edge_canvas,
		text_edit             = {enabled = true, target_id = 2},
		editable_text_targets = editable_ids[:],
	}
	h.renderer = ren
	h.viewport = {width = 801, height = 542}
	testing.expect(t, font_init(&h.font))
	defer font_destroy(&h.font)
	defer font_destroy_textures(&h.font)
	defer text_edit_destroy(&h.text_edit)
	defer dagda.frame_destroy(&h.frame)

	testing.expect(t, host_rebuild_frame(&h))
	// Focus the editable field so text_edit_draw exercises its focused nested clip path.
	_ = text_edit_focus_id(&h.text_edit, nil, &h.font, h.frame, h.app.text_edit, 2, editable_ids[:])

	// Verify hit-test agreement at physical pixel centers converted to logical points:
	// fitted canvas y = [45.71875, 496.28125) pt = [91.4375, 992.5625) px.
	// Rows 91 and 992 are inside; rows 90 and 993 are outside.
	_, hit90 := dagda.hit_test(h.frame, {x = 200.5 / 2.0, y = 90.5 / 2.0})
	id91, hit91 := dagda.hit_test(h.frame, {x = 200.5 / 2.0, y = 91.5 / 2.0})
	id992, hit992 := dagda.hit_test(h.frame, {x = 200.5 / 2.0, y = 992.5 / 2.0})
	_, hit993 := dagda.hit_test(h.frame, {x = 200.5 / 2.0, y = 993.5 / 2.0})
	testing.expect(t, !hit90)
	testing.expect(t, hit91 && id91 == 4)
	testing.expect(t, hit992 && id992 == 4)
	testing.expect(t, !hit993)

	host_draw(&h)

	cap := sdl.RenderReadPixels(h.renderer, nil)
	testing.expect(t, cap != nil)
	defer sdl.DestroySurface(cap)
	testing.expect_value(t, cap.w, c.int(1602))
	testing.expect_value(t, cap.h, c.int(1084))

	letterbox := [3]u8{14, 16, 22}
	sheet := [3]u8{26, 31, 42}
	button_fill := [3]u8{52, 108, 194}

	// Overflowing button at physical x=200 (after editable field restored its nested clip):
	testing.expect_value(t, read_rgb(cap, 200, 90), letterbox)
	testing.expect_value(t, read_rgb(cap, 200, 91), button_fill)
	testing.expect_value(t, read_rgb(cap, 200, 92), button_fill)
	testing.expect_value(t, read_rgb(cap, 200, 991), button_fill)
	testing.expect_value(t, read_rgb(cap, 200, 992), button_fill)
	testing.expect_value(t, read_rgb(cap, 200, 993), letterbox)

	// Uncovered canvas sheet at physical x=1400:
	testing.expect_value(t, read_rgb(cap, 1400, 90), letterbox)
	testing.expect_value(t, read_rgb(cap, 1400, 91), sheet)
	testing.expect_value(t, read_rgb(cap, 1400, 92), sheet)
	testing.expect_value(t, read_rgb(cap, 1400, 991), sheet)
	testing.expect_value(t, read_rgb(cap, 1400, 992), sheet)
	testing.expect_value(t, read_rgb(cap, 1400, 993), letterbox)
}

@(test)
test_multiline_eligibility_id_zero_middle_enter_kp_enter_focus_loss_and_refused_composition :: proc(t: ^testing.T) {
	sync.mutex_guard(&sdl_test_mu)
	if !sdl.Init({.VIDEO}) {
		testing.fail_now(t, "SDL_Init failed")
	}
	defer sdl.Quit()

	// 1. Listing an ID in multiline_text_targets alone does not enable editing.
	cfg_disabled := Editable_Text_Config{enabled = false, target_id = 0}
	m_only := [1]dagda.Object_Id{0}
	testing.expect(t, !text_edit_is_multiline(cfg_disabled, nil, m_only[:], 0))

	cfg_other := Editable_Text_Config{enabled = true, target_id = 2}
	testing.expect(t, !text_edit_is_multiline(cfg_other, nil, m_only[:], 0))
	testing.expect(t, !text_edit_is_multiline(cfg_other, nil, nil, 2))

	// 2. Single-target fallback with ID 0 is valid and opts into multiline.
	cfg_zero := Editable_Text_Config{enabled = true, target_id = 0}
	testing.expect(t, text_edit_is_multiline(cfg_zero, nil, m_only[:], 0))

	// 3. Exercise middle-of-line Enter + queued text X + marker, keypad Enter,
	//    focus-loss cancellation, and refused proposal during composition on ID 0.
	ML_State :: struct {
		text:          string,
		reject_next:   bool,
		proposals:     [dynamic]string,
		comp_events:   [dynamic]bool,
		elements:      [1]dagda.Canvas_Element,
	}
	ml_canvas :: proc(user_data: rawptr) -> dagda.Canvas {
		s := (^ML_State)(user_data)
		s.elements = {
			{
				info   = {id = 0, role = "body"},
				kind   = .Label,
				text   = s.text,
				bounds = {x = 40, y = 40, width = 600, height = 240},
			},
		}
		return {size = {width = 800, height = 400}, elements = s.elements[:]}
	}
	ml_commit :: proc(user_data: rawptr, id: dagda.Object_Id, new_text: string) -> bool {
		s := (^ML_State)(user_data)
		if id != 0 {
			return false
		}
		append(&s.proposals, strings.clone(new_text))
		if s.reject_next {
			s.reject_next = false
			return false
		}
		delete(s.text)
		s.text = strings.clone(new_text)
		return true
	}
	ml_comp :: proc(user_data: rawptr, id: dagda.Object_Id, composing: bool) {
		s := (^ML_State)(user_data)
		if id == 0 {
			append(&s.comp_events, composing)
		}
	}

	state := ML_State{text = strings.clone("abcd")}
	defer {
		delete(state.text)
		for p in state.proposals {
			delete(p)
		}
		delete(state.proposals)
		delete(state.comp_events)
	}

	win: ^sdl.Window
	ren: ^sdl.Renderer
	testing.expect(t, sdl.CreateWindowAndRenderer("ml-test", 800, 400, {}, &win, &ren))
	defer sdl.DestroyWindow(win)
	defer sdl.DestroyRenderer(ren)

	h: Host
	h.window = win
	h.ime_window = win
	h.renderer = ren
	h.app = {
		user_data              = &state,
		canvas                 = ml_canvas,
		text_edit              = {enabled = true, target_id = 0, on_commit = ml_commit},
		multiline_text_targets = m_only[:],
		on_composition         = ml_comp,
	}
	testing.expect(t, font_init(&h.font))
	defer font_destroy(&h.font)
	defer font_destroy_textures(&h.font)
	defer text_edit_destroy(&h.text_edit)
	defer dagda.frame_destroy(&h.frame)
	defer {
		host_clear_control_cstrs(&h)
		delete(h.queued_control_cstrs)
	}

	testing.expect(t, host_rebuild_frame(&h))
	testing.expect(t, text_edit_focus_id(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, 0, nil, m_only[:]))
	// Park caret at ab|cd (byte 2).
	dagda.set_caret(&h.text_edit.session, state.text, 2, false)

	drain_events :: proc(h: ^Host, t: ^testing.T) {
		ev: sdl.Event
		for sdl.PollEvent(&ev) {
			#partial switch ev.type {
			case .TEXT_EDITING, .TEXT_INPUT:
				tres := text_edit_handle_event(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, h.app.user_data, &ev, h.app.editable_text_targets, h.clipboard, h.app.multiline_text_targets)
				host_report_composition(h, host_active_composition(h))
				if tres.needs_rebuild {
					testing.expect(t, host_rebuild_frame(h))
					if tres.has_pending_edit {
						text_edit_apply_committed(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, &tres.pending_edit, h.app.editable_text_targets, h.app.multiline_text_targets)
					}
				}
			case .KEY_DOWN, .KEY_UP, .WINDOW_FOCUS_LOST:
				needs_rebuild, has_pending_edit, pending_edit := host_dispatch_key_event(h, &ev)
				if needs_rebuild {
					testing.expect(t, host_rebuild_frame(h))
					if has_pending_edit {
						text_edit_apply_committed(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, &pending_edit, h.app.editable_text_targets, h.app.multiline_text_targets)
					}
				}
			}
		}
		host_clear_control_cstrs(h)
	}

	// Queue Enter + text X + marker '|' in one batch (simulating one write).
	testing.expect(t, push_sdl_key(win, "enter"))
	testing.expect(t, push_sdl_text_input(&h, "X"))
	testing.expect(t, push_sdl_text_input(&h, "|"))
	drain_events(&h, t)

	testing.expect_value(t, len(state.proposals), 3)
	if len(state.proposals) == 3 {
		testing.expect_value(t, state.proposals[0], "ab\ncd")
		testing.expect_value(t, state.proposals[1], "ab\nXcd")
		testing.expect_value(t, state.proposals[2], "ab\nX|cd")
	}
	testing.expect_value(t, state.text, "ab\nX|cd")

	// Keypad Enter splits line at caret and lands caret on new line.
	testing.expect(t, push_sdl_key(win, "kp_enter"))
	testing.expect(t, push_sdl_text_input(&h, "Y"))
	drain_events(&h, t)
	testing.expect_value(t, state.text, "ab\nX|\nYcd")

	// Refused proposal during composition preserves caret, selection, and active preedit for retry.
	testing.expect(t, push_sdl_preedit(&h, "niho"))
	drain_events(&h, t)
	testing.expect(t, dagda.is_composing(&h.text_edit.session))
	testing.expect_value(t, len(state.comp_events), 1)
	testing.expect_value(t, state.comp_events[0], true)

	state.reject_next = true
	testing.expect(t, push_sdl_text_input(&h, "日本"))
	drain_events(&h, t)
	testing.expect_value(t, state.text, "ab\nX|\nYcd")
	testing.expect(t, dagda.is_composing(&h.text_edit.session))
	testing.expect_value(t, h.text_edit.session.preedit, "niho")
	testing.expect_value(t, len(state.comp_events), 1) // still composing

	// Focus-loss cancels active composition without committing and fires on_composition(false).
	fl: sdl.Event
	fl.type = .WINDOW_FOCUS_LOST
	fl.window.windowID = sdl.GetWindowID(win)
	testing.expect(t, sdl.PushEvent(&fl))
	drain_events(&h, t)
	testing.expect(t, !dagda.is_composing(&h.text_edit.session))
	testing.expect_value(t, state.text, "ab\nX|\nYcd")
	testing.expect_value(t, len(state.comp_events), 2)
	testing.expect_value(t, state.comp_events[1], false)
}

@(test)
test_multiline_paint_clip_selection_hit_test_and_ime_anchor_at_two_scales :: proc(t: ^testing.T) {
	sync.mutex_guard(&sdl_test_mu)
	if !sdl.Init({.VIDEO}) {
		testing.fail_now(t, "SDL_Init failed")
	}
	defer sdl.Quit()

	Paint_State :: struct {
		text:     string,
		elements: [1]dagda.Canvas_Element,
	}
	paint_canvas :: proc(user_data: rawptr) -> dagda.Canvas {
		s := (^Paint_State)(user_data)
		s.elements = {
			{
				info   = {id = 1, role = "note.body"},
				kind   = .Label,
				text   = s.text,
				bounds = {x = 80, y = 40, width = 260, height = 140},
			},
		}
		return {size = {width = 960, height = 540}, elements = s.elements[:]}
	}

	read_rgb :: proc(surf: ^sdl.Surface, x, y: i32) -> [3]u8 {
		r, g, b, a: u8
		ok := sdl.ReadSurfacePixel(surf, c.int(x), c.int(y), &r, &g, &b, &a)
		assert(ok)
		return {r, g, b}
	}

	count_color_in_band :: proc(surf: ^sdl.Surface, x0, y0, x1, y1: i32, target: [3]u8) -> int {
		hits := 0
		cx0 := max(i32(0), x0)
		cy0 := max(i32(0), y0)
		cx1 := min(i32(surf.w), x1)
		cy1 := min(i32(surf.h), y1)
		for y := cy0; y < cy1; y += 1 {
			for x := cx0; x < cx1; x += 1 {
				rgb := read_rgb(surf, x, y)
				if abs(int(rgb[0]) - int(target[0])) <= 10 &&
				   abs(int(rgb[1]) - int(target[1])) <= 10 &&
				   abs(int(rgb[2]) - int(target[2])) <= 10 {
					hits += 1
				}
			}
		}
		return hits
	}

	glyph_ink_in_band :: proc(surf: ^sdl.Surface, x0, y0, x1, y1: i32) -> (hits: int, max_x: i32) {
		max_x = -1
		cx0 := max(i32(0), x0)
		cy0 := max(i32(0), y0)
		cx1 := min(i32(surf.w), x1)
		cy1 := min(i32(surf.h), y1)
		for y := cy0; y < cy1; y += 1 {
			for x := cx0; x < cx1; x += 1 {
				rgb := read_rgb(surf, x, y)
				// Near-white committed text glyph pixels (b >= 160 excludes amber caret RGB(255,206,84)).
				if rgb[0] >= 160 && rgb[1] >= 160 && rgb[2] >= 160 {
					hits += 1
					if x > max_x {
						max_x = x
					}
				}
			}
		}
		return hits, max_x
	}

	find_amber_caret_in_band :: proc(surf: ^sdl.Surface, x0, y0, x1, y1: i32, min_hits: int) -> (col: i32, found: bool) {
		cx0 := max(i32(0), x0)
		cy0 := max(i32(0), y0)
		cx1 := min(i32(surf.w), x1)
		cy1 := min(i32(surf.h), y1)
		for x := cx0; x < cx1; x += 1 {
			hits := 0
			for y := cy0; y < cy1; y += 1 {
				rgb := read_rgb(surf, x, y)
				if abs(int(rgb[0]) - 255) <= 10 && abs(int(rgb[1]) - 206) <= 10 && abs(int(rgb[2]) - 84) <= 10 {
					hits += 1
				}
			}
			if hits >= min_hits {
				return x, true
			}
		}
		return -1, false
	}

	// Run at two scales: 1x (800x540 -> 800x540) and 2x (800x540 -> 1600x1080).
	Scale_Case :: struct {
		out_w, out_h: c.int,
		scale:        f32,
	}
	cases := [2]Scale_Case{
		{out_w = 800, out_h = 540, scale = 1.0},
		{out_w = 1600, out_h = 1080, scale = 2.0},
	}

	// Dummy window solely to exercise real SDL_SetTextInputArea / SDL_GetTextInputArea.
	ime_win := sdl.CreateWindow("ml-ime", 800, 540, {})
	testing.expect(t, ime_win != nil)
	defer sdl.DestroyWindow(ime_win)

	editable_ids := [1]dagda.Object_Id{1}
	multiline_ids := [1]dagda.Object_Id{1}

	for sc in cases {
		surf := sdl.CreateSurface(sc.out_w, sc.out_h, .ABGR8888)
		testing.expect(t, surf != nil)
		defer sdl.DestroySurface(surf)
		ren := sdl.CreateSoftwareRenderer(surf)
		testing.expect(t, ren != nil)
		defer sdl.DestroyRenderer(ren)

		// 1. Line painting, clipping, cross-line selection, and grapheme click/drag.
		state := Paint_State{
			text = "ii\nCaf" + "e\u0301" + " WWWWWWWWWWWWWWWWWWWW\n\nFourth\nFifth\nSixth_Very_Long_Line_For_Scroll",
		}
		h: Host
		h.ime_window = ime_win
		h.renderer = ren
		h.viewport = {width = 800, height = 540}
		h.app = {
			user_data              = &state,
			canvas                 = paint_canvas,
			text_edit              = {enabled = true, target_id = 1},
			editable_text_targets  = editable_ids[:],
			multiline_text_targets = multiline_ids[:],
		}
		testing.expect(t, font_init(&h.font))
		defer font_destroy(&h.font)
		defer font_destroy_textures(&h.font)
		defer text_edit_destroy(&h.text_edit)
		defer dagda.frame_destroy(&h.frame)

		testing.expect(t, host_rebuild_frame(&h))
		el, ok_el := dagda.find(h.frame, 1)
		testing.expect(t, ok_el)
		tx, first_y, px, line_h, _, _ := text_edit_multiline_layout(h.frame, el.bounds)

		// Verify committed text glyphs actually paint on lines 0 ("ii") and 1 ("Café WWW...") at both 1x and 2x,
		// and that editing line 0 to "WWWWWW" visibly shifts the painted glyph ink on row 0.
		bx0 := i32(math.floor(el.bounds.x * sc.scale)) + i32(math.ceil(4 * sc.scale))
		bx1 := i32(math.ceil((el.bounds.x + el.bounds.width) * sc.scale)) - i32(math.ceil(4 * sc.scale))
		row0_y0 := i32(math.floor(first_y * sc.scale))
		row0_y1 := i32(math.ceil((first_y + px) * sc.scale))
		row1_y0 := i32(math.floor((first_y + line_h) * sc.scale))
		row1_y1 := i32(math.ceil((first_y + line_h + px) * sc.scale))

		host_draw(&h)
		cap0 := sdl.RenderReadPixels(h.renderer, nil)
		testing.expect(t, cap0 != nil)
		defer sdl.DestroySurface(cap0)
		ink0_hits, ink0_max_x := glyph_ink_in_band(cap0, bx0, row0_y0, bx1, row0_y1)
		ink1_hits, ink1_max_x := glyph_ink_in_band(cap0, bx0, row1_y0, bx1, row1_y1)
		testing.expect(t, ink0_hits > 10)
		testing.expect(t, ink1_hits > 50)
		testing.expect(t, ink1_max_x > ink0_max_x + i32(math.floor(40 * sc.scale)))

		state.text = "WWWWWW\nCaf" + "e\u0301" + " WWWWWWWWWWWWWWWWWWWW\n\nFourth\nFifth\nSixth_Very_Long_Line_For_Scroll"
		testing.expect(t, host_rebuild_frame(&h))
		host_draw(&h)
		cap0_edited := sdl.RenderReadPixels(h.renderer, nil)
		testing.expect(t, cap0_edited != nil)
		defer sdl.DestroySurface(cap0_edited)
		ink0_ed_hits, ink0_ed_max_x := glyph_ink_in_band(cap0_edited, bx0, row0_y0, bx1, row0_y1)
		testing.expect(t, ink0_ed_hits > ink0_hits)
		testing.expect(t, ink0_ed_max_x > ink0_max_x + i32(math.floor(40 * sc.scale)))

		// Restore line 0 to "First" for the grapheme click/drag assertions below.
		state.text = "First\nCaf" + "e\u0301" + " WWWWWWWWWWWWWWWWWWWW\n\nFourth\nFifth\nSixth_Very_Long_Line_For_Scroll"
		testing.expect(t, host_rebuild_frame(&h))
		el, ok_el = dagda.find(h.frame, 1)
		testing.expect(t, ok_el)

		// Click left and right of decomposed e+U+0301 on line 1.
		w_caf := font_measure_width(&h.font, "Caf", px)
		w_cafe := font_measure_width(&h.font, "Cafe\u0301", px)
		line1_mid_y := first_y + line_h + px * 0.5
		_ = text_edit_click_id(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, 1, tx + w_caf + (w_cafe - w_caf) * 0.25, editable_ids[:], false, line1_mid_y, multiline_ids[:])
		// "First\n" is 6 bytes, "Caf" is 3 bytes -> offset 9.
		testing.expect_value(t, h.text_edit.session.caret, 9)

		_ = text_edit_click_id(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, 1, tx + w_caf + (w_cafe - w_caf) * 0.75, editable_ids[:], false, line1_mid_y, multiline_ids[:])
		// "e\u0301" is 3 bytes -> offset 12.
		testing.expect_value(t, h.text_edit.session.caret, 12)

		// Drag from line 0 ("Fi|rst") across empty line 2 to line 3 ("Fo|urth").
		w_fi := font_measure_width(&h.font, "Fi", px)
		w_fo := font_measure_width(&h.font, "Fo", px)
		started, _ := text_edit_press_id(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, 1, tx + w_fi, editable_ids[:], false, first_y + px * 0.5, multiline_ids[:])
		testing.expect(t, started)
		_ = text_edit_drag_move(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, tx + w_fo, editable_ids[:], first_y + 3 * line_h + px * 0.5, multiline_ids[:])
		text_edit_drag_end(&h.text_edit)

		sel_s, sel_e := dagda.selection_bounds(&h.text_edit.session)
		testing.expect_value(t, sel_s, 2)
		testing.expect(t, sel_e > sel_s)

		// Paint selection across lines and verify SEL_BG on lines 0, 1, and empty line 2, plus clipping outside right edge.
		host_draw(&h)
		cap1 := sdl.RenderReadPixels(h.renderer, nil)
		testing.expect(t, cap1 != nil)
		defer sdl.DestroySurface(cap1)
		testing.expect_value(t, cap1.w, sc.out_w)
		testing.expect_value(t, cap1.h, sc.out_h)

		sel_rgb := [3]u8{58, 108, 190}
		_, sy_sel := text_edit_clamped_scroll_2d(&h.text_edit, &h.font, h.frame, 1, el.bounds, state.text, true, true)
		bx0_full := i32(math.floor(el.bounds.x * sc.scale))
		bx1_full := i32(math.ceil((el.bounds.x + el.bounds.width) * sc.scale))
		for line_i in 0 ..< 3 {
			ly0 := i32(math.floor((first_y + f32(line_i) * line_h - sy_sel) * sc.scale))
			ly1 := i32(math.ceil((first_y + f32(line_i) * line_h - sy_sel + px) * sc.scale))
			if ly1 > i32(math.floor(el.bounds.y * sc.scale)) && ly0 < i32(math.ceil((el.bounds.y + el.bounds.height) * sc.scale)) {
				testing.expect(t, count_color_in_band(cap1, bx0_full, ly0, bx1_full, ly1, sel_rgb) > 0)
			}
		}
		// Right-edge clip: sheet color (26, 31, 42) just outside field right edge.
		outside_x := i32(math.ceil((el.bounds.x + el.bounds.width) * sc.scale)) + i32(math.ceil(8 * sc.scale))
		testing.expect_value(t, read_rgb(cap1, outside_x, i32(math.floor(line1_mid_y * sc.scale))), [3]u8{26, 31, 42})

		// 2. Move caret to end of last (6th) long line -> scrolls both horizontally and vertically,
		//    start preedit, and verify painted preedit, painted caret, and SDL_GetTextInputArea agree.
		dagda.set_caret(&h.text_edit.session, state.text, len(state.text), false)
		_ = dagda.begin_composition(&h.text_edit.session, "niho", 0, 4)
		text_edit_update_ime_area(&h.text_edit, h.ime_window, &h.font, h.frame, h.app.text_edit, editable_ids[:], multiline_ids[:])

		sx_scroll := text_edit_scroll_x(&h.text_edit, 1)
		sy_scroll := text_edit_scroll_y(&h.text_edit, 1)
		testing.expect(t, sx_scroll > 0)
		testing.expect(t, sy_scroll > 0)

		host_draw(&h)
		cap2 := sdl.RenderReadPixels(h.renderer, nil)
		testing.expect(t, cap2 != nil)
		defer sdl.DestroySurface(cap2)

		caret_x, caret_y, _ := text_edit_caret_pos(&h.text_edit, &h.font, h.frame, el.bounds, state.text, true)
		pre_y0 := i32(math.floor((caret_y - 3) * sc.scale))
		pre_y1 := i32(math.ceil((caret_y + px) * sc.scale))
		testing.expect(t, count_color_in_band(cap2, bx0, pre_y0, bx1, pre_y1, [3]u8{62, 78, 118}) > 10)

		// Find painted amber caret in the upper half of the scrolled caret line.
		caret_col, found_caret := find_amber_caret_in_band(cap2, bx0 + 2, pre_y0 + 1, bx1 - 2, i32(math.floor((caret_y + px * 0.6) * sc.scale)), max(6, int(math.round(6 * sc.scale))))
		testing.expect(t, found_caret)
		if found_caret {
			testing.expect(t, math.abs(f32(caret_col) / sc.scale - caret_x) <= 2.0)
		}

		// Verify SDL_GetTextInputArea agrees with painted caret X and scrolled line Y.
		ime_area: sdl.Rect
		ime_cursor: c.int
		testing.expect(t, sdl.GetTextInputArea(ime_win, &ime_area, &ime_cursor))
		testing.expect(t, abs(int(ime_area.x + ime_cursor) - int(math.round(caret_x))) <= 2)
		testing.expect(t, abs(int(ime_area.y) - int(math.floor(caret_y - 3))) <= 2)
	}
}

@(test)
test_multiline_paste_normalization_failure_and_control_push_growth_failure :: proc(t: ^testing.T) {
	sync.mutex_guard(&sdl_test_mu)
	if !sdl.Init({.VIDEO}) {
		testing.fail_now(t, "SDL_Init failed")
	}
	defer sdl.Quit()

	Paste_State :: struct {
		text:     string,
		commits:  int,
		elements: [1]dagda.Canvas_Element,
	}
	paste_canvas :: proc(user_data: rawptr) -> dagda.Canvas {
		s := (^Paste_State)(user_data)
		s.elements = {
			{
				info   = {id = 1, role = "body"},
				kind   = .Label,
				text   = s.text,
				bounds = {x = 40, y = 40, width = 600, height = 240},
			},
		}
		return {size = {width = 800, height = 400}, elements = s.elements[:]}
	}
	paste_commit :: proc(user_data: rawptr, id: dagda.Object_Id, new_text: string) -> bool {
		s := (^Paste_State)(user_data)
		if id != 1 {
			return false
		}
		delete(s.text)
		s.text = strings.clone(new_text)
		s.commits += 1
		return true
	}

	win: ^sdl.Window
	ren: ^sdl.Renderer
	testing.expect(t, sdl.CreateWindowAndRenderer("ml-paste-fail", 800, 400, {}, &win, &ren))
	defer sdl.DestroyWindow(win)
	defer sdl.DestroyRenderer(ren)

	state := Paste_State{text = strings.clone("hello\nworld")}
	defer delete(state.text)

	ml_ids := [1]dagda.Object_Id{1}
	h: Host
	h.window = win
	h.renderer = ren
	h.clipboard = memory_clipboard_interface(&h.mem_clipboard)
	defer memory_clipboard_destroy(&h.mem_clipboard)
	h.app = {
		user_data              = &state,
		canvas                 = paste_canvas,
		text_edit              = {enabled = true, target_id = 1, on_commit = paste_commit},
		multiline_text_targets = ml_ids[:],
	}
	testing.expect(t, font_init(&h.font))
	defer font_destroy(&h.font)
	defer font_destroy_textures(&h.font)
	defer text_edit_destroy(&h.text_edit)
	defer dagda.frame_destroy(&h.frame)
	defer {
		host_clear_control_cstrs(&h)
		delete(h.queued_control_cstrs)
	}

	testing.expect(t, host_rebuild_frame(&h))
	testing.expect(t, text_edit_focus_id(&h.text_edit, nil, &h.font, h.frame, h.app.text_edit, 1, nil, ml_ids[:]))

	// Select "lo\nwo" (bytes 3..8) and attempt paste with a failing session allocator.
	dagda.set_caret(&h.text_edit.session, state.text, 3, false)
	dagda.set_caret(&h.text_edit.session, state.text, 8, true)
	testing.expect(t, clipboard_set(h.clipboard, "x\r\ny"))

	// The clipboard owns the first clone. Fail only the normalization buffer
	// and allow later allocations so a mistaken deletion could still commit.
	Paste_Allocator :: struct {
		backing: mem.Allocator,
		attempts: int,
	}
	paste_alloc :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
		a := (^Paste_Allocator)(data)
		if mode == .Alloc || mode == .Alloc_Non_Zeroed {
			a.attempts += 1
			if a.attempts == 2 {
				return nil, .Out_Of_Memory
			}
		}
		return a.backing.procedure(a.backing.data, mode, size, alignment, old_memory, old_size, loc)
	}
	orig_alloc := h.text_edit.session.allocator
	alloc := Paste_Allocator{backing = orig_alloc}
	h.text_edit.session.allocator = {procedure = paste_alloc, data = &alloc}
	paste_ev: sdl.Event
	paste_ev.type = .KEY_DOWN
	paste_ev.key.windowID = sdl.GetWindowID(win)
	paste_ev.key.key = sdl.K_V
	paste_ev.key.mod = sdl.KMOD_LGUI when ODIN_OS == .Darwin else sdl.KMOD_LCTRL
	paste_ev.key.down = true
	res := text_edit_handle_event(&h.text_edit, nil, &h.font, h.frame, h.app.text_edit, &state, &paste_ev, nil, h.clipboard, ml_ids[:])
	h.text_edit.session.allocator = orig_alloc
	testing.expect_value(t, alloc.attempts, 2)

	// Atomic failure: zero commits, no deletion, selection [3..8] untouched.
	testing.expect(t, res.consumed)
	testing.expect(t, !res.needs_rebuild)
	testing.expect_value(t, state.commits, 0)
	testing.expect_value(t, state.text, "hello\nworld")
	sel_s, sel_e := dagda.selection_bounds(&h.text_edit.session)
	testing.expect_value(t, sel_s, 3)
	testing.expect_value(t, sel_e, 8)

	// With a working allocator, CRLF and lone-CR pastes both succeed.
	res_ok := text_edit_handle_event(&h.text_edit, nil, &h.font, h.frame, h.app.text_edit, &state, &paste_ev, nil, h.clipboard, ml_ids[:])
	testing.expect(t, res_ok.needs_rebuild && res_ok.has_pending_edit)
	testing.expect(t, host_rebuild_frame(&h))
	text_edit_apply_committed(&h.text_edit, nil, &h.font, h.frame, h.app.text_edit, &res_ok.pending_edit, nil, ml_ids[:])
	testing.expect_value(t, state.text, "helx\nyrld")

	testing.expect(t, clipboard_set(h.clipboard, "p\rq"))
	res_cr := text_edit_handle_event(&h.text_edit, nil, &h.font, h.frame, h.app.text_edit, &state, &paste_ev, nil, h.clipboard, ml_ids[:])
	testing.expect(t, res_cr.needs_rebuild && res_cr.has_pending_edit)
	testing.expect(t, host_rebuild_frame(&h))
	text_edit_apply_committed(&h.text_edit, nil, &h.font, h.frame, h.app.text_edit, &res_cr.pending_edit, nil, ml_ids[:])
	testing.expect_value(t, state.text, "helx\nyp\nqrld")

	// Control event push helpers must free the cloned cstring and return false when
	// the tracking array cannot grow, without pushing any SDL event.
	ev_drain: sdl.Event
	for sdl.PollEvent(&ev_drain) {}
	h.queued_control_cstrs.allocator = mem.nil_allocator()
	testing.expect(t, !push_sdl_text_input(&h, "abc"))
	testing.expect(t, !push_sdl_preedit(&h, "xyz"))
	testing.expect_value(t, len(h.queued_control_cstrs), 0)
	testing.expect(t, !sdl.PollEvent(&ev_drain))
}
