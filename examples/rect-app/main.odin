package main

import "core:fmt"
import "core:os"
import "dagda:dagda"
import "dagda:dagda/driver"
import "dagda:dagda/sdlhost"

// Native canvas proof app: one rectangle the app owns, with its
// revision, set_rect policy, and one-step undo history.

Rect_App :: struct {
	rect:     dagda.Rect,
	revision: dagda.Revision,
	history:  dagda.Rect,
	has_hist: bool,
	elements: [1]dagda.Canvas_Element,
}

app_canvas :: proc(user_data: rawptr) -> dagda.Canvas {
	app := (^Rect_App)(user_data)
	app.elements = {{info = {id = 7, role = "slide.rect"}, kind = .Button, text = "Rect", bounds = app.rect}}
	return {size = {width = 960, height = 540}, elements = app.elements[:]}
}

app_handle :: proc(user_data: rawptr, id: dagda.Object_Id, action: dagda.Action) -> bool {
	return false // activation is not wired to any mutation in this app
}

app_edits := []dagda.Advertised_Edit{{object_id = 7, edit = "set_rect", argument = .Rect}}

app_edit_handle :: proc(user_data: rawptr, target: dagda.Action_Target, edit: string, arg: dagda.Edit_Argument) -> dagda.Edit_Result {
	app := (^Rect_App)(user_data)
	if target.base_revision != app.revision {
		return .Stale_Revision
	}
	if arg.rect.width <= 0 || arg.rect.height <= 0 {
		return .Not_Handled
	}
	app.history = app.rect
	app.has_hist = true
	app.rect = arg.rect
	app.revision += 1
	return .Applied
}

app_revision :: proc(user_data: rawptr, id: dagda.Object_Id) -> (dagda.Revision, bool) {
	app := (^Rect_App)(user_data)
	if id != 7 {
		return 0, false
	}
	return app.revision, true
}

app_undo :: proc(user_data: rawptr) -> bool {
	app := (^Rect_App)(user_data)
	if !app.has_hist {
		return false
	}
	app.rect = app.history
	app.has_hist = false
	app.revision += 1
	return true
}

main :: proc() {
	app_state := Rect_App{rect = {x = 72, y = 240, width = 360, height = 180}}
	opts, ok := sdlhost.parse_cli_args(os.args[1:])
	if !ok {
		fmt.eprintln("usage: rect-app [--socket <socket-path>] [--size <WxH>] [--control-stdin]")
		os.exit(2)
	}
	app := sdlhost.App{
		title     = "Dagda — Rect",
		width     = 1200,
		height    = 540,
		user_data = &app_state,
		canvas    = app_canvas,
		handle    = app_handle,
		edits     = driver.Edit_Source{edits = app_edits, handler = app_edit_handle, user_data = &app_state, revision_of = app_revision},
		on_undo   = app_undo,
	}
	if code := sdlhost.run(app, opts); code != 0 {
		os.exit(code)
	}
}
