package sdlhost

import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"
import "dagda:dagda"
import "dagda:dagda/driver"
import sdl "vendor:sdl3"

@(test)
test_host_exits_nonzero_and_removes_socket_on_duplicate_id_rebuild :: proc(t: ^testing.T) {
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
	changed, suppress, consumed := pointer_handle_event(&p, frame, &ev, record, &rec)
	testing.expect_value(t, changed, false)
	testing.expect_value(t, suppress, false)
	testing.expect_value(t, consumed, false)
	testing.expect_value(t, rec.count, 0)

	// Press + Release without motion on ID 0 preserves click (suppress_click=false on release).
	ev = btn_ev(.MOUSE_BUTTON_DOWN, sdl.BUTTON_LEFT, 150, 180) // canvas (150, 80)
	changed, suppress, consumed = pointer_handle_event(&p, frame, &ev, record, &rec)
	testing.expect_value(t, changed, true)
	testing.expect_value(t, suppress, true)
	testing.expect_value(t, consumed, true)

	ev = btn_ev(.MOUSE_BUTTON_UP, sdl.BUTTON_LEFT, 150, 180)
	changed, suppress, consumed = pointer_handle_event(&p, frame, &ev, record, &rec)
	testing.expect_value(t, changed, true)
	testing.expect_value(t, suppress, false) // button activation preserved!
	testing.expect_value(t, consumed, true)
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
	_, _, _ = pointer_handle_event(&p, frame, &ev, record, &rec)
	ev = mot_ev(470, 215) // canvas (470, 115)
	_, _, _ = pointer_handle_event(&p, frame, &ev, record, &rec)
	ev = mot_ev(700, 350) // canvas (700, 250) - outside card.two
	_, _, _ = pointer_handle_event(&p, frame, &ev, record, &rec)
	ev = btn_ev(.MOUSE_BUTTON_UP, sdl.BUTTON_LEFT, 700, 350)
	_, suppress, _ = pointer_handle_event(&p, frame, &ev, record, &rec)
	testing.expect_value(t, suppress, true)
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
	_, _, _ = pointer_handle_event(&p, frame, &ev, record, &rec)
	ev = mot_ev(500, 240) // canvas (500, 140)
	_, _, _ = pointer_handle_event(&p, frame, &ev, record, &rec)
	esc: sdl.Event
	esc.type = .KEY_DOWN
	esc.key.key = sdl.K_ESCAPE
	changed, _, consumed = pointer_handle_event(&p, frame, &esc, record, &rec)
	testing.expect_value(t, changed, true)
	testing.expect_value(t, consumed, true)
	testing.expect_value(t, p.active, false)
	testing.expect_value(t, rec.count, 3)
	testing.expect_value(t, rec.events[2].phase, Pointer_Phase.Cancel)
	testing.expect_value(t, rec.events[2].target_id, dagda.Object_Id(2))
	testing.expect_value(t, rec.events[2].point, dagda.Point{x = 500, y = 140})

	// WINDOW_FOCUS_LOST cancels active gesture without consuming focus event.
	rec = {}
	ev = btn_ev(.MOUSE_BUTTON_DOWN, sdl.BUTTON_LEFT, 150, 180)
	_, _, _ = pointer_handle_event(&p, frame, &ev, record, &rec)
	lost: sdl.Event
	lost.type = .WINDOW_FOCUS_LOST
	changed, _, consumed = pointer_handle_event(&p, frame, &lost, record, &rec)
	testing.expect_value(t, changed, true)
	testing.expect_value(t, consumed, false)
	testing.expect_value(t, p.active, false)
	testing.expect_value(t, rec.count, 2)
	testing.expect_value(t, rec.events[1].phase, Pointer_Phase.Cancel)
	testing.expect_value(t, rec.events[1].target_id, dagda.Object_Id(0))
}
