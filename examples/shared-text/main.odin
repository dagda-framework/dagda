package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "dagda:dagda"
import "dagda:dagda/sdlhost"

OUTLINE_TITLE_ID :: dagda.Object_Id(1)
CANVAS_TITLE_ID :: dagda.Object_Id(2)
STATUS_ID :: dagda.Object_Id(3)
ACTION_ID :: dagda.Object_Id(4)

// Shared_Text_App is a minimal native fixture with two distinct single-line
// elements editing one app-owned string, revision, and undo history, plus a
// passive status label and an actionable button for Tab traversal tests.
Shared_Text_App :: struct {
	title:          string,
	rev:            u64,
	last_editor_id: dagda.Object_Id,
	actions:        int,
	undo_stack:     [dynamic]string,
	editable_ids:   [2]dagda.Object_Id,
	allocator:      mem.Allocator,
	status_buf:     [96]u8,
	elements:       [4]dagda.Canvas_Element,
}

shared_init :: proc(s: ^Shared_Text_App, initial: string, allocator := context.allocator) -> bool {
	cloned, err := strings.clone(initial, allocator)
	if err != nil {
		return false
	}
	s^ = {
		title        = cloned,
		editable_ids = {OUTLINE_TITLE_ID, CANVAS_TITLE_ID},
		allocator    = allocator,
	}
	s.undo_stack.allocator = allocator
	return true
}

shared_destroy :: proc(s: ^Shared_Text_App) {
	delete(s.title, s.allocator)
	for prev in s.undo_stack {
		delete(prev, s.allocator)
	}
	delete(s.undo_stack)
	s^ = {}
}

shared_canvas :: proc(user_data: rawptr) -> dagda.Canvas {
	s := (^Shared_Text_App)(user_data)
	status := fmt.bprintf(
		s.status_buf[:],
		"rev=%d, undo=%d, last_id=%d, actions=%d",
		s.rev,
		len(s.undo_stack),
		u64(s.last_editor_id),
		s.actions,
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
		{
			info   = {id = ACTION_ID, role = "shared.action"},
			kind   = .Button,
			text   = "Apply",
			bounds = {x = 740, y = 60, width = 140, height = 80},
		},
	}
	return {
		size     = {width = 960, height = 540},
		elements = s.elements[:],
	}
}

shared_handle :: proc(user_data: rawptr, id: dagda.Object_Id, action: dagda.Action) -> bool {
	s := (^Shared_Text_App)(user_data)
	if id == ACTION_ID && action == .Activate {
		s.actions += 1
		return true
	}
	return false
}

shared_commit :: proc(user_data: rawptr, id: dagda.Object_Id, new_text: string) -> bool {
	s := (^Shared_Text_App)(user_data)
	if (id != OUTLINE_TITLE_ID && id != CANVAS_TITLE_ID) || new_text == s.title {
		return false
	}
	alloc := s.allocator.procedure != nil ? s.allocator : context.allocator
	cloned, clone_err := strings.clone(new_text, alloc)
	if clone_err != nil {
		return false
	}
	_, push_err := append(&s.undo_stack, s.title)
	if push_err != nil {
		delete(cloned, alloc)
		return false
	}
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
	alloc := s.allocator.procedure != nil ? s.allocator : context.allocator
	delete(s.title, alloc)
	s.title = pop(&s.undo_stack)
	s.rev += 1
	s.last_editor_id = id
	return true
}

main :: proc() {
	state: Shared_Text_App
	if !shared_init(&state, "Slide Title") {
		os.exit(1)
	}
	defer shared_destroy(&state)

	opts, ok := sdlhost.parse_cli_args(os.args[1:])
	if !ok {
		fmt.eprintln("usage: shared-text [--size WxH] [--socket <socket-path>] [--control-stdin]")
		os.exit(2)
	}

	app := sdlhost.App{
		title                 = "Dagda — Shared Text Fixture",
		width                 = 800,
		height                = 540,
		user_data             = &state,
		canvas                = shared_canvas,
		handle                = shared_handle,
		text_edit             = {
			enabled   = true,
			on_commit = shared_commit,
			on_undo   = shared_undo,
		},
		editable_text_targets = state.editable_ids[:],
	}
	if code := sdlhost.run(app, opts); code != 0 {
		os.exit(code)
	}
}
