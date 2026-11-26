package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"
import "dagda:dagda"
import driver "dagda:dagda/driver"

// Test fixture host: serves one canvas frame at a fixed viewport
// size so a real dagda-client can inspect visible_canvas_bounds
// at different window sizes.
main :: proc() {
	if len(os.args) != 4 {
		fmt.eprintln("usage: visible-host <socket-path> <width> <height>")
		os.exit(2)
	}
	width, ok_w := strconv.parse_f32(os.args[2])
	height, ok_h := strconv.parse_f32(os.args[3])
	if !ok_w || !ok_h {
		os.exit(2)
	}
	canvas := dagda.Canvas{
		size = {width = 960, height = 540},
		elements = {
			{info = {id = 1, role = "clipped"}, kind = .Button, text = "Clipped", bounds = {x = 900, y = 480, width = 200, height = 120}},
			{info = {id = 2, role = "full"}, kind = .Label, text = "Full", bounds = {x = 10, y = 10, width = 100, height = 50}},
		},
	}
	frame, ok := dagda.resolve_canvas(canvas, {width = width, height = height})
	if !ok {
		os.exit(1)
	}
	defer dagda.frame_destroy(&frame)

	server: driver.Server
	if !driver.server_start(&server, os.args[1]) {
		os.exit(1)
	}
	defer driver.server_stop(&server)
	rebuild :: proc(ctx: rawptr) -> bool {
		return true
	}
	for {
		_, failed := driver.server_poll(&server, &frame, nil, nil, nil, rebuild)
		if failed {
			os.exit(1)
		}
		time.sleep(10 * time.Millisecond)
	}
}
