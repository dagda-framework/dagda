// multiline-text is the fixture for the multiline editable field request.
//
// One window holds a body that should accept several lines, a single-line
// title beside it for comparison, and a status line. The app owns both
// strings, their revision and the undo history. It never sees a key, a
// caret or a selection: it only answers the host's commit and undo
// callbacks, and prints one line for each so a script can check exactly
// what the host handed over and in what order. An edit that arrives over
// the --socket driver goes through the app's edit handler instead and is
// printed as EDIT.
//
//	COMMIT id=1 rev=3 text=first\nsecond
//	REJECT id=1 text=...
//	UNDO id=1 rev=4 text=first
//	COMPOSITION id=1 composing=true
//	EDIT id=1 rev=5 text=from\nan agent
//
// In the printed text a line feed is \n, a carriage return is \r and a
// backslash is \\. Everything else is the UTF-8 the host passed.
//
// Build it against today's host and the body is an ordinary single-line
// field, which is what the script's first run shows. Build with
// -define:MULTILINE=true once the host has a multiline field: the one
// line under `when MULTILINE` below is the whole opt-in, and its name is
// a placeholder for whatever Dagda calls it.
package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "dagda:dagda"
import "dagda:dagda/driver"
import "dagda:dagda/sdlhost"

MULTILINE :: #config(MULTILINE, false)

BODY_ID :: dagda.Object_Id(1)
TITLE_ID :: dagda.Object_Id(2)
STATUS_ID :: dagda.Object_Id(3)

// Each field has its own revision, which a driver edit must name.
Field :: struct {
	text: string,
	rev:  dagda.Revision,
	undo: [dynamic]string,
}

EDIT_REPLACE_TEXT :: "replace_text"

Note_App :: struct {
	body:         Field,
	title:        Field,
	// When positive, the app refuses a body of more lines than this. It
	// stands in for any app rule that can turn a line break down.
	max_lines:    int,
	editable_ids: [2]dagda.Object_Id,
	body_ids:     [1]dagda.Object_Id,
	edits:        [2]dagda.Advertised_Edit,
	allocator:    mem.Allocator,
	status_buf:   [96]u8,
	elements:     [3]dagda.Canvas_Element,
}

note_init :: proc(n: ^Note_App, body: string, max_lines: int, allocator := context.allocator) {
	n^ = {
		max_lines    = max_lines,
		editable_ids = {BODY_ID, TITLE_ID},
		body_ids     = {BODY_ID},
		edits        = {
			{object_id = BODY_ID, edit = EDIT_REPLACE_TEXT, argument = .Text},
			{object_id = TITLE_ID, edit = EDIT_REPLACE_TEXT, argument = .Text},
		},
		allocator    = allocator,
	}
	n.body.text = strings.clone(body, allocator)
	n.title.text = strings.clone("Title", allocator)
	n.body.undo.allocator = allocator
	n.title.undo.allocator = allocator
}

field_of :: proc(n: ^Note_App, id: dagda.Object_Id) -> ^Field {
	switch id {
	case BODY_ID:
		return &n.body
	case TITLE_ID:
		return &n.title
	}
	return nil
}

line_count :: proc(s: string) -> int {
	return strings.count(s, "\n") + 1
}

// body_acceptable is the app's whole rule for a body: valid UTF-8, lines
// separated by a line feed only, and no more lines than the limit.
body_acceptable :: proc(n: ^Note_App, s: string) -> bool {
	if !utf8.valid_string(s) || strings.contains_rune(s, '\r') {
		return false
	}
	return n.max_lines <= 0 || line_count(s) <= n.max_lines
}

acceptable :: proc(n: ^Note_App, id: dagda.Object_Id, s: string) -> bool {
	return id == BODY_ID ? body_acceptable(n, s) : dagda.valid_single_line(s)
}

// replace installs new_text as one undo step and one revision.
replace :: proc(n: ^Note_App, field: ^Field, new_text: string) {
	append(&field.undo, field.text)
	field.text = strings.clone(new_text, n.allocator)
	field.rev += 1
}

report :: proc(kind: string, id: dagda.Object_Id, rev: dagda.Revision, text: string, with_rev: bool) {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s id=%d", kind, u64(id))
	if with_rev {
		fmt.sbprintf(&b, " rev=%d", rev)
	}
	strings.write_string(&b, " text=")
	for i in 0 ..< len(text) {
		switch text[i] {
		case '\n':
			strings.write_string(&b, "\\n")
		case '\r':
			strings.write_string(&b, "\\r")
		case '\\':
			strings.write_string(&b, "\\\\")
		case:
			strings.write_byte(&b, text[i])
		}
	}
	fmt.println(strings.to_string(b))
	_ = os.flush(os.stdout)
}

note_commit :: proc(user_data: rawptr, id: dagda.Object_Id, new_text: string) -> bool {
	n := (^Note_App)(user_data)
	field := field_of(n, id)
	if field == nil {
		return false
	}
	if !acceptable(n, id, new_text) || new_text == field.text {
		report("REJECT", id, 0, new_text, false)
		return false
	}
	replace(n, field, new_text)
	report("COMMIT", id, field.rev, field.text, true)
	return true
}

note_revision :: proc(user_data: rawptr, id: dagda.Object_Id) -> (dagda.Revision, bool) {
	field := field_of((^Note_App)(user_data), id)
	if field == nil {
		return 0, false
	}
	return field.rev, true
}

// note_edit is the driver's way in. It applies the same text rule as a
// commit from the window, after the revision check and after standing
// aside for a composition in the same field.
note_edit :: proc(user_data: rawptr, target: dagda.Action_Target, edit: string, arg: dagda.Edit_Argument) -> dagda.Edit_Result {
	n := (^Note_App)(user_data)
	field := field_of(n, target.id)
	if field == nil {
		return .Unknown_Object
	}
	if edit != EDIT_REPLACE_TEXT || arg.kind != .Text {
		return .Not_Handled
	}
	if target.base_revision != field.rev {
		return .Stale_Revision
	}
	if composition := sdlhost.current_composition(); composition.active && composition.field_id == target.id {
		return .Busy_Composing
	}
	if !acceptable(n, target.id, arg.text) || arg.text == field.text {
		return .Not_Handled
	}
	replace(n, field, arg.text)
	report("EDIT", target.id, field.rev, field.text, true)
	return .Applied
}

note_undo :: proc(user_data: rawptr, id: dagda.Object_Id) -> bool {
	n := (^Note_App)(user_data)
	field := field_of(n, id)
	if field == nil || len(field.undo) == 0 {
		return false
	}
	delete(field.text, n.allocator)
	field.text = pop(&field.undo)
	field.rev += 1
	report("UNDO", id, field.rev, field.text, true)
	return true
}

note_composition :: proc(user_data: rawptr, id: dagda.Object_Id, composing: bool) {
	fmt.printf("COMPOSITION id=%d composing=%v\n", u64(id), composing)
	_ = os.flush(os.stdout)
}

note_canvas :: proc(user_data: rawptr) -> dagda.Canvas {
	n := (^Note_App)(user_data)
	status := fmt.bprintf(n.status_buf[:], "rev=%d, lines=%d", u64(n.body.rev), line_count(n.body.text))
	n.elements = {
		{
			info   = {id = BODY_ID, role = "note.body"},
			kind   = .Label,
			text   = n.body.text,
			bounds = {x = 80, y = 40, width = 800, height = 280},
		},
		{
			info   = {id = TITLE_ID, role = "note.title"},
			kind   = .Label,
			text   = n.title.text,
			bounds = {x = 80, y = 350, width = 800, height = 64},
		},
		{
			info   = {id = STATUS_ID, role = "note.status"},
			kind   = .Label,
			text   = status,
			bounds = {x = 80, y = 444, width = 800, height = 56},
		},
	}
	return {size = {width = 960, height = 540}, elements = n.elements[:]}
}

// unescape reads the --text argument, which uses the same escapes the
// app prints.
unescape :: proc(s: string) -> string {
	b := strings.builder_make()
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 1 < len(s) {
			i += 1
			switch s[i] {
			case 'n':
				strings.write_byte(&b, '\n')
			case 'r':
				strings.write_byte(&b, '\r')
			case:
				strings.write_byte(&b, s[i])
			}
			continue
		}
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
}

main :: proc() {
	body := ""
	max_lines := 0
	host_args: [dynamic]string
	for i := 1; i < len(os.args); i += 1 {
		switch {
		case os.args[i] == "--text" && i + 1 < len(os.args):
			i += 1
			body = unescape(os.args[i])
		case os.args[i] == "--max-lines" && i + 1 < len(os.args):
			i += 1
			max_lines, _ = strconv.parse_int(os.args[i])
		case:
			append(&host_args, os.args[i])
		}
	}
	opts, ok := sdlhost.parse_cli_args(host_args[:])
	if !ok {
		fmt.eprintln("usage: multiline-text [--text <escaped>] [--max-lines N] [--size WxH] [--socket <path>] [--control-stdin]")
		os.exit(2)
	}

	state: Note_App
	note_init(&state, body, max_lines)

	app := sdlhost.App {
		title                 = "Dagda — Multiline Text Fixture",
		width                 = 960,
		height                = 540,
		user_data             = &state,
		canvas                = note_canvas,
		edits                 = driver.Edit_Source {
			edits = state.edits[:],
			handler = note_edit,
			user_data = &state,
			revision_of = note_revision,
		},
		text_edit             = {enabled = true, on_commit = note_commit, on_undo = note_undo},
		editable_text_targets = state.editable_ids[:],
		on_composition        = note_composition,
	}
	when MULTILINE {
		// The request: one opt-in that makes these targets multiline.
		app.multiline_text_targets = state.body_ids[:]
	}
	fmt.printf("READY multiline=%v\n", MULTILINE)
	_ = os.flush(os.stdout)
	if code := sdlhost.run(app, opts); code != 0 {
		os.exit(code)
	}
}
