package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "dagda:dagda"
import sdl "vendor:sdl3"
import "dagda:dagda/driver"
import "dagda:dagda/sdlhost"

A_OUTLINE_ID :: dagda.Object_Id(0)
A_CANVAS_ID :: dagda.Object_Id(1)
B_CANVAS_ID :: dagda.Object_Id(2)
STATUS_ID :: dagda.Object_Id(3)

Doc_Target :: enum {
	Title_A,
	Title_B,
}

Title_Doc :: struct {
	text: string,
	rev:  dagda.Revision,
	undo: [dynamic]string,
}

// Conflict_App models a VisiDeck-like slide where title A has two visual fields
// (an outline row with ID 0 and a canvas headline with ID 1) and title B is an
// independently editable field (ID 2).
Conflict_App :: struct {
	doc_a:                  Title_Doc,
	doc_b:                  Title_Doc,
	disable_conflict_check: bool,
	editable_ids:           [3]dagda.Object_Id,
	status_buf:             [128]u8,
	elements:               [4]dagda.Canvas_Element,
	// Observation log for the native-IME desktop probe: when
	// COMPOSITION_OBS_LOG names a file, composition start/end
	// and commit callbacks append ordered records (sequence,
	// field, host-thread id, exact text bytes as hex, and the
	// resulting revision/undo depth) and rewrite that file.
	obs_path:               string,
	obs_buf:                [dynamic]u8,
	obs_seq:                int,
	main_thread:            int,
}

doc_destroy :: proc(d: ^Title_Doc) {
	delete(d.text)
	for prev in d.undo {
		delete(prev)
	}
	delete(d.undo)
}

doc_for_field :: proc(id: dagda.Object_Id) -> (Doc_Target, bool) {
	switch id {
	case A_OUTLINE_ID, A_CANVAS_ID:
		return .Title_A, true
	case B_CANVAS_ID:
		return .Title_B, true
	}
	return .Title_A, false
}

doc_ptr :: proc(app: ^Conflict_App, which: Doc_Target) -> ^Title_Doc {
	switch which {
	case .Title_A:
		return &app.doc_a
	case .Title_B:
		return &app.doc_b
	}
	return &app.doc_a
}

doc_commit_text :: proc(d: ^Title_Doc, new_text: string) -> bool {
	if !dagda.valid_single_line(new_text) || new_text == d.text {
		return false
	}
	cloned, err := strings.clone(new_text)
	if err != nil {
		return false
	}
	if _, push_err := append(&d.undo, d.text); push_err != nil {
		delete(cloned)
		return false
	}
	d.text = cloned
	d.rev += 1
	return true
}

doc_undo_text :: proc(d: ^Title_Doc) -> bool {
	if len(d.undo) == 0 {
		return false
	}
	delete(d.text)
	d.text = pop(&d.undo)
	d.rev += 1
	return true
}

conflict_canvas :: proc(user_data: rawptr) -> dagda.Canvas {
	app := (^Conflict_App)(user_data)
	status := fmt.bprintf(
		app.status_buf[:],
		"a_rev=%d, a_undo=%d, b_rev=%d, b_undo=%d",
		u64(app.doc_a.rev),
		len(app.doc_a.undo),
		u64(app.doc_b.rev),
		len(app.doc_b.undo),
	)
	app.elements = {
		{
			info   = {id = A_OUTLINE_ID, role = "a.outline"},
			kind   = .Label,
			text   = app.doc_a.text,
			bounds = {x = 40, y = 60, width = 420, height = 72},
		},
		{
			info   = {id = A_CANVAS_ID, role = "a.canvas"},
			kind   = .Label,
			text   = app.doc_a.text,
			bounds = {x = 500, y = 60, width = 420, height = 72},
		},
		{
			info   = {id = B_CANVAS_ID, role = "b.canvas"},
			kind   = .Label,
			text   = app.doc_b.text,
			bounds = {x = 500, y = 180, width = 420, height = 72},
		},
		{
			info   = {id = STATUS_ID, role = "conflict.status"},
			kind   = .Label,
			text   = status,
			bounds = {x = 40, y = 300, width = 880, height = 56},
		},
	}
	return {
		size     = {width = 960, height = 540},
		elements = app.elements[:],
	}
}

conflict_text_commit :: proc(user_data: rawptr, id: dagda.Object_Id, new_text: string) -> bool {
	app := (^Conflict_App)(user_data)
	which, ok := doc_for_field(id)
	if !ok {
		return false
	}
	return doc_commit_text(doc_ptr(app, which), new_text)
}

obs_hex :: proc(text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(text) {
		fmt.sbprintf(&b, "%02x", text[i])
	}
	return strings.to_string(b)
}

obs_record :: proc(app: ^Conflict_App, line: string) {
	if len(app.obs_path) == 0 {
		return
	}
	append(&app.obs_buf, line)
	append(&app.obs_buf, '\n')
	_ = os.write_entire_file(app.obs_path, app.obs_buf[:])
}

conflict_observe_composition :: proc(user_data: rawptr, field_id: dagda.Object_Id, composing: bool) {
	app := (^Conflict_App)(user_data)
	if len(app.obs_path) == 0 {
		return
	}
	app.obs_seq += 1
	obs_record(app, fmt.tprintf(
		"seq=%d kind=composition_%s field=%d tid=%d main_tid=%d video=%s a_text_hex=%s a_rev=%d a_undo=%d",
		app.obs_seq, composing ? "start" : "end", u64(field_id), sync.current_thread_id(), app.main_thread, sdl.GetCurrentVideoDriver(),
		obs_hex(app.doc_a.text), u64(app.doc_a.rev), len(app.doc_a.undo),
	))
}

conflict_observe_commit :: proc(user_data: rawptr, id: dagda.Object_Id, new_text: string) -> bool {
	app := (^Conflict_App)(user_data)
	accepted := conflict_text_commit(user_data, id, new_text)
	if len(app.obs_path) == 0 {
		return accepted
	}
	app.obs_seq += 1
	rev, undo: int
	if which, ok := doc_for_field(id); ok {
		d := doc_ptr(app, which)
		rev, undo = int(d.rev), len(d.undo)
	}
	obs_record(app, fmt.tprintf(
		"seq=%d kind=commit field=%d tid=%d main_tid=%d video=%s accepted=%v text_hex=%s rev=%d undo=%d",
		app.obs_seq, u64(id), sync.current_thread_id(), app.main_thread, sdl.GetCurrentVideoDriver(), accepted,
		obs_hex(new_text), rev, undo,
	))
	return accepted
}

conflict_text_undo :: proc(user_data: rawptr, id: dagda.Object_Id) -> bool {
	app := (^Conflict_App)(user_data)
	which, ok := doc_for_field(id)
	if !ok {
		return false
	}
	return doc_undo_text(doc_ptr(app, which))
}

conflict_edits := []dagda.Advertised_Edit{
	{object_id = A_OUTLINE_ID, edit = "rename", argument = .Text},
	{object_id = A_CANVAS_ID, edit = "rename", argument = .Text},
	{object_id = B_CANVAS_ID, edit = "rename", argument = .Text},
}

conflict_revision :: proc(user_data: rawptr, id: dagda.Object_Id) -> (dagda.Revision, bool) {
	app := (^Conflict_App)(user_data)
	which, ok := doc_for_field(id)
	if !ok {
		return 0, false
	}
	return doc_ptr(app, which).rev, true
}

conflict_edit_handle :: proc(
	user_data: rawptr,
	target: dagda.Action_Target,
	edit: string,
	arg: dagda.Edit_Argument,
) -> dagda.Edit_Result {
	app := (^Conflict_App)(user_data)
	if edit != "rename" || arg.kind != .Text {
		return .Not_Handled
	}
	target_doc, known := doc_for_field(target.id)
	if !known {
		return .Unknown_Object
	}
	d := doc_ptr(app, target_doc)
	if target.base_revision != d.rev {
		return .Stale_Revision
	}
	if !app.disable_conflict_check {
		comp := sdlhost.current_composition()
		if comp.active {
			if comp_doc, ok := doc_for_field(comp.field_id); ok && comp_doc == target_doc {
				return .Busy_Composing
			}
		}
	}
	if !doc_commit_text(d, arg.text) {
		return .Not_Handled
	}
	return .Applied
}

main :: proc() {
	state := Conflict_App{
		doc_a        = {text = strings.clone("Alpha Title"), rev = 1},
		doc_b        = {text = strings.clone("Beta Title"), rev = 1},
		editable_ids = {A_OUTLINE_ID, A_CANVAS_ID, B_CANVAS_ID},
	}
	state.main_thread = sync.current_thread_id()
	if obs_path, has_obs := os.lookup_env("COMPOSITION_OBS_LOG", context.allocator); has_obs {
		state.obs_path = obs_path
		obs_record(&state, fmt.tprintf(
			"seq=0 kind=ready tid=%d main_tid=%d a_text_hex=%s a_rev=%d a_undo=%d",
			state.main_thread, state.main_thread, obs_hex(state.doc_a.text), u64(state.doc_a.rev), len(state.doc_a.undo),
		))
	}
	defer {
		doc_destroy(&state.doc_a)
		doc_destroy(&state.doc_b)
		delete(state.obs_buf)
	}

	host_args := make([dynamic]string, 0, len(os.args))
	defer delete(host_args)
	for arg in os.args[1:] {
		if arg == "--disable-conflict-check" {
			state.disable_conflict_check = true
		} else {
			append(&host_args, arg)
		}
	}

	opts, ok := sdlhost.parse_cli_args(host_args[:])
	if !ok {
		fmt.eprintln("usage: composition-conflict [--size WxH] [--socket <socket-path>] [--control-stdin] [--disable-conflict-check]")
		os.exit(2)
	}

	app := sdlhost.App{
		title                 = "Dagda — Composition Conflict",
		width                 = 960,
		height                = 540,
		user_data             = &state,
		canvas                = conflict_canvas,
		edits                 = driver.Edit_Source{
			edits       = conflict_edits,
			handler     = conflict_edit_handle,
			user_data   = &state,
			revision_of = conflict_revision,
		},
		text_edit             = {
			enabled   = true,
			on_commit = conflict_observe_commit,
			on_undo   = conflict_text_undo,
		},
		on_composition        = conflict_observe_composition,
		editable_text_targets = state.editable_ids[:],
	}
	if code := sdlhost.run(app, opts); code != 0 {
		os.exit(code)
	}
}
