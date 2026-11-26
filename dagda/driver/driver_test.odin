package driver

import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:strings"
import "core:testing"
import "dagda:dagda"

Test_Counter :: struct {
	count:     int,
	label_buf: [32]u8,
	elements:  [2]dagda.Element,
}

test_counter_view :: proc(c: ^Test_Counter) -> dagda.View {
	text := fmt.bprintf(c.label_buf[:], "%d", c.count)
	c.elements = {
		{info = {id = 1, role = "counter.value"}, kind = .Label, text = text},
		{info = {id = 2, role = "counter.increment"}, kind = .Button, text = "Increment"},
	}
	return {elements = c.elements[:]}
}

test_counter_handle :: proc(user_data: rawptr, id: dagda.Object_Id, action: dagda.Action) -> bool {
	c := (^Test_Counter)(user_data)
	if id == 2 && action == .Activate {
		c.count += 1
		return true
	}
	return false
}

@(test)
test_inspect_shared_role_in_declaration_order :: proc(t: ^testing.T) {
	// Two buttons share a role with an unrelated element between
	// them: inspect emits both, in declaration order, with their
	// resolved bounds and advertised actions.
	c: Test_Counter
	elements := []dagda.Element{
		{info = {id = 10, role = "shared.action"}, kind = .Button, text = "First"},
		{info = {id = 99, role = "other.label"}, kind = .Label, text = "Between"},
		{info = {id = 20, role = "shared.action"}, kind = .Button, text = "Second"},
	}
	frame, ok := dagda.resolve({elements = elements}, {width = 320, height = 200})
	testing.expect(t, ok)
	defer dagda.frame_destroy(&frame)

	rep, applied := dispatch(frame, test_counter_handle, &c, `{"op":"inspect","role":"shared.action"}`)
	defer delete(rep)
	testing.expect_value(t, applied, false)
	testing.expect_value(t, rep, `{"ok":true,"elements":[{"id":10,"role":"shared.action","kind":"button","text":"First","bounds":{"x":16.00,"y":16.00,"width":288.00,"height":40.00},"actions":["activate"]},{"id":20,"role":"shared.action","kind":"button","text":"Second","bounds":{"x":16.00,"y":112.00,"width":288.00,"height":40.00},"actions":["activate"]}]}`)

	missing, _ := dispatch(frame, test_counter_handle, &c, `{"op":"inspect","role":"missing"}`)
	defer delete(missing)
	testing.expect_value(t, missing, `{"ok":false,"error":"Unknown_Role"}`)

	wrong_type, _ := dispatch(frame, test_counter_handle, &c, `{"op":"inspect","role":1}`)
	defer delete(wrong_type)
	testing.expect_value(t, wrong_type, `{"ok":false,"error":"Malformed_Request"}`)
}

@(test)
test_dispatch_inspect_and_invoke :: proc(t: ^testing.T) {
	c: Test_Counter
	frame, ok := dagda.resolve(test_counter_view(&c), {width = 360, height = 180})
	testing.expect(t, ok)
	defer dagda.frame_destroy(&frame)

	val_rep, val_app := dispatch(frame, test_counter_handle, &c, `{"op":"inspect","role":"counter.value"}`)
	defer delete(val_rep)
	testing.expect_value(t, val_app, false)
	testing.expect_value(t, val_rep, `{"ok":true,"elements":[{"id":1,"role":"counter.value","kind":"label","text":"0","bounds":{"x":16.00,"y":16.00,"width":328.00,"height":40.00},"actions":[]}]}`)

	btn_rep, btn_app := dispatch(frame, test_counter_handle, &c, `{"op":"inspect","role":"counter.increment"}`)
	defer delete(btn_rep)
	testing.expect_value(t, btn_app, false)
	testing.expect_value(t, btn_rep, `{"ok":true,"elements":[{"id":2,"role":"counter.increment","kind":"button","text":"Increment","bounds":{"x":16.00,"y":64.00,"width":328.00,"height":40.00},"actions":["activate"]}]}`)

	inv_rep, inv_app := dispatch(frame, test_counter_handle, &c, `{"op":"invoke","id":2,"action":"activate"}`)
	defer delete(inv_rep)
	testing.expect_value(t, inv_app, true)
	testing.expect_value(t, inv_rep, `{"ok":true,"id":2,"action":"activate"}`)
	testing.expect_value(t, c.count, 1)

	// Error paths
	err1, _ := dispatch(frame, test_counter_handle, &c, `{"op":"inspect","role":"missing"}`)
	defer delete(err1)
	testing.expect_value(t, err1, `{"ok":false,"error":"Unknown_Role"}`)

	err2, _ := dispatch(frame, test_counter_handle, &c, `{"op":"invoke","id":1,"action":"activate"}`)
	defer delete(err2)
	testing.expect_value(t, err2, `{"ok":false,"error":"Unsupported_Action"}`)

	err3, _ := dispatch(frame, test_counter_handle, &c, `{"op":"invoke","id":999,"action":"activate"}`)
	defer delete(err3)
	testing.expect_value(t, err3, `{"ok":false,"error":"Unknown_Object"}`)

	err4, _ := dispatch(frame, test_counter_handle, &c, `{"op":"invoke","id":2,"action":"bogus"}`)
	defer delete(err4)
	testing.expect_value(t, err4, `{"ok":false,"error":"Unknown_Action"}`)
}

@(test)
test_server_socket_roundtrip_and_rebuild :: proc(t: ^testing.T) {
	Host_State :: struct {
		counter: Test_Counter,
		frame:   dagda.Frame,
	}
	hs: Host_State
	ok: bool
	hs.frame, ok = dagda.resolve(test_counter_view(&hs.counter), {width = 360, height = 180})
	testing.expect(t, ok)
	defer dagda.frame_destroy(&hs.frame)

	rebuild :: proc(ctx: rawptr) -> bool {
		s := (^Host_State)(ctx)
		dagda.frame_destroy(&s.frame)
		frame, ok := dagda.resolve(test_counter_view(&s.counter), {width = 360, height = 180})
		if !ok {
			return false
		}
		s.frame = frame
		return true
	}

	sock_dir := fmt.tprintf("/tmp/dagda-drv-unit-%d", posix.getpid())
	_ = os.make_directory(sock_dir)
	defer _ = os.remove(sock_dir)
	sock_path := fmt.tprintf("%s/app.sock", sock_dir)

	srv: Server
	testing.expect(t, server_start(&srv, sock_path))
	defer server_stop(&srv)

	fd, conn_ok := connect_unix(sock_path)
	testing.expect(t, conn_ok)
	defer posix.close(fd)

	// Pipelined invoke + inspect in one write: inspect must see count=1 after rebuild!
	testing.expect(t, write_all(fd, "{\"op\":\"invoke\",\"id\":2,\"action\":\"activate\"}\n{\"op\":\"inspect\",\"role\":\"counter.value\"}\n"))
	applied, failed := server_poll(&srv, &hs.frame, test_counter_handle, &hs.counter, &hs, rebuild)
	applied2, failed2 := server_poll(&srv, &hs.frame, test_counter_handle, &hs.counter, &hs, rebuild)
	testing.expect_value(t, applied || applied2, true)
	testing.expect_value(t, failed || failed2, false)

	r := Line_Reader{fd = fd}
	r1, ok1 := read_line(&r)
	defer delete(r1)
	testing.expect(t, ok1)
	testing.expect_value(t, r1, `{"ok":true,"id":2,"action":"activate"}`)

	r2, ok2 := read_line(&r)
	defer delete(r2)
	testing.expect(t, ok2)
	testing.expect_value(t, r2, `{"ok":true,"elements":[{"id":1,"role":"counter.value","kind":"label","text":"1","bounds":{"x":16.00,"y":16.00,"width":328.00,"height":40.00},"actions":[]}]}`)
}

@(test)
test_u64_max_id_roundtrip_and_out_of_range_rejected :: proc(t: ^testing.T) {
	MAX_ID :: dagda.Object_Id(max(u64))

	State :: struct {
		calls:    int,
		last_id:  dagda.Object_Id,
		elements: [1]dagda.Element,
	}
	st := State{
		elements = {
			{info = {id = MAX_ID, role = "btn.max"}, kind = .Button, text = "Max"},
		},
	}
	handler :: proc(user_data: rawptr, id: dagda.Object_Id, action: dagda.Action) -> bool {
		s := (^State)(user_data)
		s.calls += 1
		s.last_id = id
		return id == MAX_ID && action == .Activate
	}

	frame, ok := dagda.resolve({elements = st.elements[:]}, {width = 200, height = 100})
	testing.expect(t, ok)
	defer dagda.frame_destroy(&frame)

	insp, _ := dispatch(frame, handler, &st, `{"op":"inspect","role":"btn.max"}`)
	defer delete(insp)
	testing.expect_value(t, insp, `{"ok":true,"elements":[{"id":18446744073709551615,"role":"btn.max","kind":"button","text":"Max","bounds":{"x":16.00,"y":16.00,"width":168.00,"height":40.00},"actions":["activate"]}]}`)

	// Exact max(u64) round-trips through invoke.
	inv_ok, applied := dispatch(frame, handler, &st, `{"op":"invoke","id":18446744073709551615,"action":"activate"}`)
	defer delete(inv_ok)
	testing.expect_value(t, applied, true)
	testing.expect_value(t, inv_ok, `{"ok":true,"id":18446744073709551615,"action":"activate"}`)
	testing.expect_value(t, st.calls, 1)
	testing.expect_value(t, st.last_id, MAX_ID)

	// Out-of-range and non-integer IDs are rejected before calling the handler.
	bad_cases := []string{
		`{"op":"invoke","id":18446744073709551616,"action":"activate"}`,
		`{"op":"invoke","id":-1,"action":"activate"}`,
		`{"op":"invoke","id":1.5,"action":"activate"}`,
		`{"op":"invoke","id":"18446744073709551615","action":"activate"}`,
	}
	for req in bad_cases {
		rep, app := dispatch(frame, handler, &st, req)
		testing.expect_value(t, app, false)
		testing.expect_value(t, rep, `{"ok":false,"error":"Malformed_Request"}`)
		delete(rep)
	}
	testing.expect_value(t, st.calls, 1)
}

@(test)
test_failed_rebuild_stops_pipelined_requests_and_surfaces_error :: proc(t: ^testing.T) {
	Dup_App :: struct {
		triggered: bool,
		elements:  [2]dagda.Element,
		frame:     dagda.Frame,
	}
	view :: proc(a: ^Dup_App) -> dagda.View {
		if !a.triggered {
			a.elements = {
				{info = {id = 1, role = "a"}, kind = .Label, text = "ok"},
				{info = {id = 2, role = "b"}, kind = .Button, text = "Break"},
			}
		} else {
			// Duplicate IDs on second frame: dagda.resolve must reject this.
			a.elements = {
				{info = {id = 1, role = "a"}, kind = .Label, text = "dup"},
				{info = {id = 1, role = "b"}, kind = .Button, text = "dup"},
			}
		}
		return {elements = a.elements[:]}
	}
	handle :: proc(user_data: rawptr, id: dagda.Object_Id, action: dagda.Action) -> bool {
		a := (^Dup_App)(user_data)
		if id == 2 && action == .Activate {
			a.triggered = true
			return true
		}
		return false
	}
	rebuild :: proc(ctx: rawptr) -> bool {
		a := (^Dup_App)(ctx)
		dagda.frame_destroy(&a.frame)
		frame, ok := dagda.resolve(view(a), {width = 300, height = 160})
		if !ok {
			return false
		}
		a.frame = frame
		return true
	}

	app: Dup_App
	ok: bool
	app.frame, ok = dagda.resolve(view(&app), {width = 300, height = 160})
	testing.expect(t, ok)
	defer dagda.frame_destroy(&app.frame)

	sock_dir := fmt.tprintf("/tmp/dagda-drv-dup-%d", posix.getpid())
	_ = os.make_directory(sock_dir)
	defer _ = os.remove(sock_dir)
	sock_path := fmt.tprintf("%s/app.sock", sock_dir)

	srv: Server
	testing.expect(t, server_start(&srv, sock_path))
	defer server_stop(&srv)

	fd, conn_ok := connect_unix(sock_path)
	testing.expect(t, conn_ok)
	defer posix.close(fd)

	// Pipelined invoke (triggers duplicate-ID rebuild) + inspect:
	// server must report Frame_Invalid and NOT process inspect against an empty frame.
	testing.expect(t, write_all(fd, "{\"op\":\"invoke\",\"id\":2,\"action\":\"activate\"}\n{\"op\":\"inspect\"}\n"))
	_, failed1 := server_poll(&srv, &app.frame, handle, &app, &app, rebuild)
	_, failed2 := server_poll(&srv, &app.frame, handle, &app, &app, rebuild)
	testing.expect_value(t, failed1 || failed2, true)
	server_stop(&srv)

	r := Line_Reader{fd = fd}
	rep1, ok1 := read_line(&r)
	defer delete(rep1)
	testing.expect(t, ok1)
	testing.expect_value(t, rep1, `{"ok":false,"error":"Frame_Invalid"}`)

	// Second pipelined inspect must NOT produce a successful empty frame.
	_, ok2 := read_line(&r)
	testing.expect_value(t, ok2, false)
	testing.expect_value(t, os.exists(sock_path), false)
}

@(test)
test_canvas_inspect_exposes_window_and_canvas_bounds :: proc(t: ^testing.T) {
	elements := [2]dagda.Canvas_Element{
		{info = {id = 1, role = "slide.headline"}, kind = .Label, text = "Title", bounds = {x = 80, y = 60, width = 800, height = 80}},
		{info = {id = 2, role = "slide.card"}, kind = .Button, text = "Card", bounds = {x = 93.125, y = 200, width = 200.0625, height = 220}},
	}
	canvas := dagda.Canvas{
		size     = {width = 960, height = 540},
		elements = elements[:],
	}
	// 640x480 fits 960x540 at scale = 640/960 = 2/3, offset = (0, 60).
	frame, ok := dagda.resolve_canvas(canvas, {width = 640, height = 480})
	testing.expect(t, ok)
	defer dagda.frame_destroy(&frame)

	rep, applied := dispatch(frame, nil, nil, `{"op":"inspect","role":"slide.card"}`)
	defer delete(rep)
	testing.expect_value(t, applied, false)
	testing.expect_value(t, rep, `{"ok":true,"elements":[{"id":2,"role":"slide.card","kind":"button","text":"Card","bounds":{"x":62.08,"y":193.33,"width":133.38,"height":146.67},"visible_canvas_bounds":{"x":93.125,"y":200,"width":200.0625,"height":220},"canvas_bounds":{"x":93.125,"y":200,"width":200.0625,"height":220},"actions":["activate"]}]}`)
}

Wire_Doc :: struct {
	title: string,
	rev:   dagda.Revision,
	calls: int,
}

wire_handle :: proc(user_data: rawptr, target: dagda.Action_Target, edit: string, arg: dagda.Edit_Argument) -> dagda.Edit_Result {
	doc := (^Wire_Doc)(user_data)
	doc.calls += 1
	if target.base_revision != doc.rev {
		return .Stale_Revision
	}
	delete(doc.title)
	doc.title = strings.clone(arg.text)
	doc.rev += 1
	return .Applied
}

wire_revision :: proc(user_data: rawptr, id: dagda.Object_Id) -> (dagda.Revision, bool) {
	doc := (^Wire_Doc)(user_data)
	return doc.rev, id == 1
}

@(test)
test_dispatch_edits_wire :: proc(t: ^testing.T) {
	doc := Wire_Doc{title = strings.clone("Quarterly results")}
	defer delete(doc.title)
	elements := []dagda.Element{{info = {id = 1, role = "doc.title"}, kind = .Label, text = doc.title}}
	frame, ok := dagda.resolve({elements = elements}, {width = 320, height = 120})
	testing.expect(t, ok)
	defer dagda.frame_destroy(&frame)
	source := Edit_Source{
		edits = {{object_id = 1, edit = "replace_text", argument = .Text}},
		handler = wire_handle,
		user_data = &doc,
		revision_of = wire_revision,
	}
	rep, _ := dispatch_edits(frame, nil, nil, source, `{"op":"edits","id":1}`)
	defer delete(rep)
	testing.expect_value(t, rep, `{"ok":true,"id":1,"revision":0,"edits":[{"name":"replace_text","argument":"text"}]}`)

	prev, _ := dispatch_edits(frame, nil, nil, source, `{"op":"preview","id":1,"edit":"replace_text","base_revision":0,"argument":{"kind":"text","text":"Draft"}}`)
	defer delete(prev)
	testing.expect_value(t, prev, `{"ok":true,"id":1,"edit":"replace_text","revision":0,"argument":{"kind":"text","text":"Draft"}}`)
	testing.expect_value(t, doc.title, "Quarterly results")
	testing.expect_value(t, doc.calls, 0)

	commit, applied := dispatch_edits(frame, nil, nil, source, `{"op":"commit","id":1,"edit":"replace_text","base_revision":0,"argument":{"kind":"text","text":"Draft"}}`)
	defer delete(commit)
	testing.expect(t, applied)
	testing.expect_value(t, commit, `{"ok":true,"id":1,"edit":"replace_text","revision":1}`)

	stale, _ := dispatch_edits(frame, nil, nil, source, `{"op":"commit","id":1,"edit":"replace_text","base_revision":0,"argument":{"kind":"text","text":"Late"}}`)
	defer delete(stale)
	testing.expect_value(t, stale, `{"ok":false,"error":"Stale_Revision","revision":1}`)
	wrong, _ := dispatch_edits(frame, nil, nil, source, `{"op":"commit","id":1,"edit":"replace_text","base_revision":1,"argument":{"kind":"rect","rect":{"x":1,"y":2,"width":3,"height":4}}}`)
	defer delete(wrong)
	testing.expect_value(t, wrong, `{"ok":false,"error":"Wrong_Argument"}`)
	testing.expect_value(t, doc.title, "Draft")
	testing.expect_value(t, doc.calls, 2) // commit + stale only; wrong kind never reached it
}

wire_no_revision :: proc(user_data: rawptr, id: dagda.Object_Id) -> (dagda.Revision, bool) {
	return 0, false
}

@(test)
test_preview_unknown_object_cases :: proc(t: ^testing.T) {
	// An advertised declaration is present for ID 1 in both
	// cases; preview must still report Unknown_Object when the
	// live-object lookup cannot vouch for it.
	doc := Wire_Doc{title = strings.clone("Quarterly results")}
	defer delete(doc.title)
	elements := []dagda.Element{{info = {id = 1, role = "doc.title"}, kind = .Label, text = doc.title}}
	frame, ok := dagda.resolve({elements = elements}, {width = 320, height = 120})
	testing.expect(t, ok)
	defer dagda.frame_destroy(&frame)
	edits := []dagda.Advertised_Edit{{object_id = 1, edit = "replace_text", argument = .Text}}
	request := `{"op":"preview","id":1,"edit":"replace_text","base_revision":0,"argument":{"kind":"text","text":"Draft"}}`

	no_callback := Edit_Source{edits = edits, handler = wire_handle, user_data = &doc}
	rep, _ := dispatch_edits(frame, nil, nil, no_callback, request)
	defer delete(rep)
	testing.expect_value(t, rep, `{"ok":false,"error":"Unknown_Object"}`)

	unknown_id := Edit_Source{edits = edits, handler = wire_handle, user_data = &doc, revision_of = wire_no_revision}
	rep2, _ := dispatch_edits(frame, nil, nil, unknown_id, request)
	defer delete(rep2)
	testing.expect_value(t, rep2, `{"ok":false,"error":"Unknown_Object"}`)
	testing.expect_value(t, doc.calls, 0)
}

@(test)
test_inspect_visible_canvas_bounds :: proc(t: ^testing.T) {
	c: Test_Counter
	canvas := dagda.Canvas{
		size = {width = 960, height = 540},
		elements = {
			{info = {id = 1, role = "clipped"}, kind = .Button, text = "Clipped", bounds = {x = 900, y = 480, width = 200, height = 120}},
			{info = {id = 2, role = "full"}, kind = .Label, text = "Full", bounds = {x = 10, y = 10, width = 100, height = 50}},
			{info = {id = 3, role = "fractional"}, kind = .Label, text = "Frac", bounds = {x = 93.125, y = -40, width = 200.0625, height = 620}},
			{info = {id = 4, role = "edge"}, kind = .Label, text = "Edge", bounds = {x = 960, y = 100, width = 50, height = 50}},
			{info = {id = 5, role = "outside"}, kind = .Label, text = "Out", bounds = {x = 1000, y = 600, width = 50, height = 50}},
			{info = {id = 6, role = "tiny1"}, kind = .Label, text = "Tiny1", bounds = {x = 900, y = 10, width = 0.1, height = 50}},
			{info = {id = 7, role = "tiny2"}, kind = .Label, text = "Tiny2", bounds = {x = 900, y = 100, width = 0.00001, height = 50}},
			{info = {id = 8, role = "pastx"}, kind = .Label, text = "PastX", bounds = {x = 960, y = 10, width = 0.00001, height = 50}},
			{info = {id = 9, role = "pasty"}, kind = .Label, text = "PastY", bounds = {x = 10, y = 540, width = 50, height = 0.00001}},
			{info = {id = 10, role = "thinclip"}, kind = .Label, text = "ThinClip", bounds = {x = 959.99993896484375, y = 10, width = 0.00008, height = 50}},
		},
	}
	frame, ok := dagda.resolve_canvas(canvas, {width = 1200, height = 540})
	testing.expect(t, ok)
	defer dagda.frame_destroy(&frame)

	rep, _ := dispatch(frame, test_counter_handle, &c, `{"op":"inspect"}`)
	defer delete(rep)
	testing.expect(t, strings.contains(rep, `"id":1`))
	testing.expect(t, strings.contains(rep, `"visible_canvas_bounds":{"x":900,"y":480,"width":60,"height":60}`))
	testing.expect(t, strings.contains(rep, `"visible_canvas_bounds":{"x":10,"y":10,"width":100,"height":50}`))
	testing.expect(t, strings.contains(rep, `"visible_canvas_bounds":{"x":93.125,"y":0,"width":200.0625,"height":540}`))
	// Fully contained tiny widths are preserved exactly.
	testing.expect(t, strings.contains(rep, `"visible_canvas_bounds":{"x":900,"y":10,"width":0.1,"height":50}`))
	testing.expect(t, strings.contains(rep, `"visible_canvas_bounds":{"x":900,"y":100,"width":1e-05,"height":50}`))
	// Edge-touching and entirely outside objects report null (twice).
	testing.expect(t, strings.contains(rep, `"visible_canvas_bounds":{"x":959.99994,"y":10,"width":6.1035156e-05,"height":50}`) || strings.contains(rep, `"width":0.00006103515625`))
	testing.expect_value(t, strings.count(rep, `"visible_canvas_bounds":null`), 4)
	// Existing fields are still present.
	testing.expect(t, strings.contains(rep, `"canvas_bounds":{"x":900,"y":480,"width":200,"height":120}`))
}

@(test)
test_hit_test_op :: proc(t: ^testing.T) {
	c: Test_Counter
	canvas := dagda.Canvas{
		size = {width = 960, height = 540},
		elements = {
			{info = {id = 0, role = "under"}, kind = .Button, text = "Under", bounds = {x = 0, y = 0, width = 200, height = 200}},
			{info = {id = 2, role = "over"}, kind = .Button, text = "Over", bounds = {x = 100, y = 100, width = 200, height = 200}},
			{info = {id = 3, role = "clipped"}, kind = .Button, text = "Clipped", bounds = {x = 900, y = 480, width = 200, height = 120}},
		},
	}
	frame, ok := dagda.resolve_canvas(canvas, {width = 1200, height = 540})
	testing.expect(t, ok)
	defer dagda.frame_destroy(&frame)

	cases := [][2]string{
		{`{"op":"hit-test","x":270,"y":150}`, `{"ok":true,"id":2}`},   // overlap: last drawn wins
		{`{"op":"hit-test","x":130,"y":10}`, `{"ok":true,"id":0}`},    // ID 0 is a valid hit
		{`{"op":"hit-test","x":1079,"y":520}`, `{"ok":true,"id":3}`},  // partly clipped canvas element
		{`{"op":"hit-test","x":10,"y":270}`, `{"ok":true,"id":null}`}, // letterbox miss
		{`{"op":"hit-test","x":"10","y":270}`, `{"ok":false,"error":"Malformed_Request"}`},
		{`{"op":"hit-test","x":10}`, `{"ok":false,"error":"Malformed_Request"}`},
	}
	for caze in cases {
		rep, applied := dispatch(frame, test_counter_handle, &c, caze[0])
		defer delete(rep)
		testing.expect_value(t, applied, false)
		testing.expect_value(t, rep, caze[1])
	}
	testing.expect_value(t, c.count, 0) // the query changed no app state
}
