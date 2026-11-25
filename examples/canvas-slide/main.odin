package main

import "core:fmt"
import "core:os"
import "dagda:dagda"
import "dagda:dagda/sdlhost"

// Slide_Canvas is an app-owned fixed-aspect (16:9) canvas fixture.
// Slide-specific types stay in the consuming app, outside Dagda core.
Slide_Canvas :: struct {
	selected:     bool,
	clicks:       int,
	headline_buf: [64]u8,
	elements:     [2]dagda.Canvas_Element,
}

slide_canvas :: proc(user_data: rawptr) -> dagda.Canvas {
	s := (^Slide_Canvas)(user_data)
	headline := fmt.bprintf(s.headline_buf[:], "Slide Canvas (selected=%v, clicks=%d)", s.selected, s.clicks)
	s.elements = {
		{
			info   = {id = 1, role = "slide.headline"},
			kind   = .Label,
			text   = headline,
			bounds = {x = 80, y = 60, width = 800, height = 80},
		},
		{
			info   = {id = 2, role = "slide.card"},
			kind   = .Button,
			text   = s.selected ? "Selected Card" : "Filled Card",
			bounds = {x = 220, y = 200, width = 520, height = 220},
		},
	}
	return {
		size     = {width = 960, height = 540},
		elements = s.elements[:],
	}
}

slide_handle :: proc(user_data: rawptr, id: dagda.Object_Id, action: dagda.Action) -> bool {
	s := (^Slide_Canvas)(user_data)
	if id == 2 && action == .Activate {
		s.selected = true
		s.clicks += 1
		return true
	}
	return false
}

main :: proc() {
	slide: Slide_Canvas
	opts, ok := sdlhost.parse_cli_args(os.args[1:])
	if !ok {
		fmt.eprintln("usage: canvas-slide [--size WxH] [--socket <socket-path>]")
		os.exit(2)
	}
	app := sdlhost.App{
		title     = "Dagda — Canvas Slide",
		width     = 800,
		height    = 540,
		user_data = &slide,
		canvas    = slide_canvas,
		handle    = slide_handle,
	}
	if code := sdlhost.run(app, opts); code != 0 {
		os.exit(code)
	}
}
