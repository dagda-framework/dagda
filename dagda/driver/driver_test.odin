package driver

import "core:fmt"
import "core:os"
import "core:sys/posix"
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

	rebuild :: proc(ctx: rawptr) {
		s := (^Host_State)(ctx)
		dagda.frame_destroy(&s.frame)
		s.frame, _ = dagda.resolve(test_counter_view(&s.counter), {width = 360, height = 180})
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
	applied := server_poll(&srv, &hs.frame, test_counter_handle, &hs.counter, &hs, rebuild)
	applied = server_poll(&srv, &hs.frame, test_counter_handle, &hs.counter, &hs, rebuild) || applied
	testing.expect_value(t, applied, true)

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
