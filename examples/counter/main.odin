package main

import "core:fmt"
import "core:os"
import "dagda:dagda"
import "dagda:dagda/sdlhost"

Counter :: struct {
	count:     int,
	label_buf: [32]u8,
	elements:  [2]dagda.Element,
}

counter_view :: proc(user_data: rawptr) -> dagda.View {
	c := (^Counter)(user_data)
	text := fmt.bprintf(c.label_buf[:], "%d", c.count)
	c.elements = {
		{info = {id = 1, role = "counter.value"}, kind = .Label, text = text},
		{info = {id = 2, role = "counter.increment"}, kind = .Button, text = "Increment"},
	}
	return {elements = c.elements[:]}
}

counter_handle :: proc(user_data: rawptr, id: dagda.Object_Id, action: dagda.Action) -> bool {
	c := (^Counter)(user_data)
	if id == 2 && action == .Activate {
		c.count += 1
		return true
	}
	return false
}

main :: proc() {
	counter: Counter
	opts, ok := sdlhost.parse_cli_args(os.args[1:])
	if !ok {
		fmt.eprintln("usage: counter [--socket <socket-path>]")
		os.exit(2)
	}
	app := sdlhost.App{
		title     = "Dagda — Counter",
		width     = 360,
		height    = 180,
		user_data = &counter,
		view      = counter_view,
		handle    = counter_handle,
	}
	if code := sdlhost.run(app, opts); code != 0 {
		os.exit(code)
	}
}
