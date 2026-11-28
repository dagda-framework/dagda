package main

import "core:fmt"
import "core:os"
import "core:time"
import "dagda:dagda"
import driver "dagda:dagda/driver"

// Windows transport proof host: one button whose activation
// count is its text, served through driver.Server over the
// local socket. A stop file requests a clean shutdown so
// server_stop runs and removes the endpoint.
//
// usage: windows-host <socket-path> <stop-file>
main :: proc() {
	if len(os.args) != 3 {
		fmt.eprintln("usage: windows-host <socket-path> <stop-file>")
		os.exit(2)
	}
	sock, stop_file := os.args[1], os.args[2]

	count := 0
	buf: [32]u8
	elements: [1]dagda.Canvas_Element
	build_frame :: proc(elements: ^[1]dagda.Canvas_Element, buf: ^[32]u8, count: int) -> dagda.Frame {
		text := fmt.bprintf(buf[:], "count=%d", count)
		elements^ = {{info = {id = 7, role = "win.target"}, kind = .Button, text = text, bounds = {x = 40, y = 40, width = 200, height = 60}}}
		frame, ok := dagda.resolve_canvas({size = {width = 480, height = 300}, elements = elements[:]}, {width = 480, height = 300})
		assert(ok)
		return frame
	}
	frame := build_frame(&elements, &buf, count)
	defer dagda.frame_destroy(&frame)

	server: driver.Server
	if !driver.server_start(&server, sock) {
		os.exit(1)
	}
	defer driver.server_stop(&server)

	Handler_State :: struct {
		count:    ^int,
		elements: ^[1]dagda.Canvas_Element,
		buf:      ^[32]u8,
		frame:    ^dagda.Frame,
	}
	hs := Handler_State{count = &count, elements = &elements, buf = &buf, frame = &frame}
	handle :: proc(user_data: rawptr, id: dagda.Object_Id, action: dagda.Action) -> bool {
		if id == 7 && action == .Activate {
			return true
		}
		return false
	}
	rebuild :: proc(ctx: rawptr) -> bool {
		hs := (^Handler_State)(ctx)
		hs.count^ += 1
		dagda.frame_destroy(hs.frame)
		text := fmt.bprintf(hs.buf[:], "count=%d", hs.count^)
		hs.elements^ = {{info = {id = 7, role = "win.target"}, kind = .Button, text = text, bounds = {x = 40, y = 40, width = 200, height = 60}}}
		frame, ok := dagda.resolve_canvas({size = {width = 480, height = 300}, elements = hs.elements[:]}, {width = 480, height = 300})
		if !ok {
			return false
		}
		hs.frame^ = frame
		return true
	}

	for {
		if os.exists(stop_file) {
			break
		}
		_, failed := driver.server_poll(&server, &frame, handle, nil, &hs, rebuild)
		if failed {
			os.exit(1)
		}
		time.sleep(10 * time.Millisecond)
	}
}
