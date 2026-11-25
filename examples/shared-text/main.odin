package main

import "core:fmt"
import "core:os"
import "core:strings"
import "dagda:dagda"
import "dagda:dagda/sdlhost"

OUTLINE_TITLE_ID :: dagda.Object_Id(1)
CANVAS_TITLE_ID :: dagda.Object_Id(2)
STATUS_ID :: dagda.Object_Id(3)

// Shared_Text_App is a minimal native fixture with two distinct single-line
// elements editing one app-owned string, revision, and undo history.
Shared_Text_App :: struct {
	title:          string,
	rev:            u64,
	last_editor_id: dagda.Object_Id,
	undo_stack:     [dynamic]string,
	editable_ids:   [2]dagda.Object_Id,
	status_buf:     [96]u8,
	elements:       [3]dagda.Canvas_Element,
}

shared_destroy :: proc(s: ^Shared_Text_App) {
	delete(s.title)
	for prev in s.undo_stack {
		delete(prev)
	}
	delete(s.undo_stack)
}

shared_canvas :: proc(user_data: rawptr) -> dagda.Canvas {
	s := (^Shared_Text_App)(user_data)
	status := fmt.bprintf(
		s.status_buf[:],
		"rev=%d, undo=%d, last_id=%d",
		s.rev,
		len(s.undo_stack),
		u64(s.last_editor_id),
	)
	s.elements = {
		{
			info   = {id = OUTLINE_TITLE_ID, role = "outline.title"},
			kind   = .Label,
			text   = s.title,
			bounds = {x = 80, y = 60, width = 640, height = 80},
		},
		{
			info   = {id = CANVAS_TITLE_ID, role = "canvas.title"},
			kind   = .Label,
			text   = s.title,
			bounds = {x = 80, y = 200, width = 640, height = 80},
		},
		{
			info   = {id = STATUS_ID, role = "shared.status"},
			kind   = .Label,
			text   = status,
			bounds = {x = 80, y = 340, width = 640, height = 56},
		},
	}
	return {
		size     = {width = 960, height = 540},
		elements = s.elements[:],
	}
}

shared_commit :: proc(user_data: rawptr, id: dagda.Object_Id, new_text: string) -> bool {
	s := (^Shared_Text_App)(user_data)
	if (id != OUTLINE_TITLE_ID && id != CANVAS_TITLE_ID) || new_text == s.title {
		return false
	}
	cloned, err := strings.clone(new_text)
	if err != nil {
		return false
	}
	append(&s.undo_stack, s.title)
	s.title = cloned
	s.rev += 1
	s.last_editor_id = id
	return true
}

shared_undo :: proc(user_data: rawptr, id: dagda.Object_Id) -> bool {
	s := (^Shared_Text_App)(user_data)
	if (id != OUTLINE_TITLE_ID && id != CANVAS_TITLE_ID) || len(s.undo_stack) == 0 {
		return false
	}
	delete(s.title)
	s.title = pop(&s.undo_stack)
	s.rev += 1
	s.last_editor_id = id
	return true
}

main :: proc() {
	state := Shared_Text_App{
		title        = strings.clone("Slide Title"),
		editable_ids = {OUTLINE_TITLE_ID, CANVAS_TITLE_ID},
	}
	defer shared_destroy(&state)

	opts, ok := sdlhost.parse_cli_args(os.args[1:])
	if !ok {
		fmt.eprintln("usage: shared-text [--size WxH] [--socket <socket-path>] [--control-stdin]")
		os.exit(2)
	}

	app := sdlhost.App{
		title     = "Dagda — Shared Text Fixture",
		width     = 800,
		height    = 540,
		user_data = &state,
		canvas    = shared_canvas,
		text_edit = {
			enabled    = true,
			target_ids = state.editable_ids[:],
			on_commit  = shared_commit,
			on_undo    = shared_undo,
		},
	}
	if code := sdlhost.run(app, opts); code != 0 {
		os.exit(code)
	}
}
