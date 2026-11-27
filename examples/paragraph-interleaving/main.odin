package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "dagda:dagda"
import "dagda:dagda/driver"
import "dagda:dagda/sdlhost"

HEADING :: dagda.Object_Id(1)
FIRST :: dagda.Object_Id(2)
WRITER :: dagda.Object_Id(3)
INSERTED :: dagda.Object_Id(4)

Field :: struct {
	text: string,
	history: [dynamic]string,
	revision: dagda.Revision,
}

State :: struct {
	fields: [4]Field,
	elements: [5]dagda.Canvas_Element,
	status: [160]u8,
	handle: sdlhost.Rebuild_Handle,
	worker: ^thread.Thread,
	mu: sync.Mutex,
	inserted: bool,
	starts, ends: int,
}

publish_insert :: proc(data: rawptr) {
	s := (^State)(data)
	sync.mutex_lock(&s.mu)
	s.inserted = true
	sync.mutex_unlock(&s.mu)
	_ = sdlhost.request_rebuild(s.handle)
}

composition :: proc(data: rawptr, id: dagda.Object_Id, active: bool) {
	s := (^State)(data)
	if id != WRITER { return }
	if active {
		s.starts += 1
		// Deliver one simulated remote paragraph insertion during the first preedit.
		if s.worker == nil {
			s.worker = thread.create_and_start_with_data(s, publish_insert)
		}
	} else {
		s.ends += 1
	}
}

canvas :: proc(data: rawptr) -> dagda.Canvas {
	s := (^State)(data)
	sync.mutex_lock(&s.mu)
	inserted := s.inserted
	sync.mutex_unlock(&s.mu)
	order := [?]dagda.Object_Id{HEADING, FIRST, INSERTED, WRITER}
	roles := [?]string{"heading", "paragraph.first", "paragraph.writer", "paragraph.inserted"}
	count := 0
	for id in order {
		if id == INSERTED && !inserted { continue }
		i := int(id)-1
		s.elements[count] = {
			info = {id = id, role = roles[i]}, kind = .Label, text = s.fields[i].text,
			bounds = {40, 16 + 76*f32(count), 560, 64},
		}
		count += 1
	}
	status := fmt.bprintf(s.status[:], "starts=%d ends=%d heading_history=%d writer_history=%d",
		s.starts, s.ends, len(s.fields[0].history), len(s.fields[2].history))
	s.elements[count] = {info = {id = 5, role = "status"}, kind = .Label, text = status, bounds = {40, 330, 560, 52}}
	return {size = {640, 400}, elements = s.elements[:count+1]}
}

commit :: proc(data: rawptr, id: dagda.Object_Id, value: string) -> bool {
	if id < HEADING || id > INSERTED { return false }
	if (id == HEADING && !dagda.valid_single_line(value)) || !dagda.valid_multiline(value) { return false }
	f := &((^State)(data)).fields[int(id)-1]
	if f.text == value { return false }
	cloned, err := strings.clone(value)
	if err != nil || len(cloned) != len(value) {
		delete(cloned)
		return false
	}
	previous_depth := len(f.history)
	_, push_err := append(&f.history, f.text)
	if push_err != nil || len(f.history) != previous_depth + 1 {
		delete(cloned)
		return false
	}
	f.text = cloned
	f.revision += 1
	return true
}

undo :: proc(data: rawptr, id: dagda.Object_Id) -> bool {
	if id < HEADING || id > INSERTED { return false }
	f := &((^State)(data)).fields[int(id)-1]
	if len(f.history) == 0 { return false }
	delete(f.text)
	f.text = pop(&f.history)
	f.revision += 1
	return true
}

revision :: proc(data: rawptr, id: dagda.Object_Id) -> (dagda.Revision, bool) {
	if id != HEADING { return 0, false }
	return ((^State)(data)).fields[0].revision, true
}

validate_rename :: proc(data: rawptr, target: dagda.Action_Target, edit: string, arg: dagda.Edit_Argument) -> dagda.Edit_Result {
	rev, ok := revision(data, target.id)
	if !ok { return .Unknown_Object }
	if target.base_revision != rev { return .Stale_Revision }
	if edit != "rename" || arg.kind != .Text { return .Not_Handled }
	if !dagda.valid_single_line(arg.text) { return .Not_Handled }
	if ((^State)(data)).fields[0].text == arg.text { return .Not_Handled }
	return .Applied
}

rename :: proc(data: rawptr, target: dagda.Action_Target, edit: string, arg: dagda.Edit_Argument) -> dagda.Edit_Result {
	if vres := validate_rename(data, target, edit, arg); vres != .Applied { return vres }
	preedit := sdlhost.current_composition()
	if preedit.active && preedit.field_id == target.id { return .Busy_Composing }
	if !commit(data, target.id, arg.text) { return .Not_Handled }
	return .Applied
}

main :: proc() {
	opts, ok := sdlhost.parse_cli_args(os.args[1:])
	if !ok { os.exit(2) }
	s: State
	initial := [?]string{"Report", "First paragraph", "Write OLD here", "Remote paragraph"}
	for value, i in initial { s.fields[i].text = strings.clone(value) }
	ids := [?]dagda.Object_Id{HEADING, FIRST, WRITER, INSERTED}
	edits := [?]dagda.Advertised_Edit{{object_id = HEADING, edit = "rename", argument = .Text}}
	code := sdlhost.run({
		title = "Paragraph interleaving", width = 640, height = 400, user_data = &s,
		canvas = canvas, rebuild_handle = &s.handle, on_composition = composition,
		editable_text_targets = ids[:], multiline_text_targets = ids[1:],
		text_edit = {enabled = true, on_commit = commit, on_undo = undo},
		edits = driver.Edit_Source{edits = edits[:], handler = rename, validate = validate_rename, user_data = &s, revision_of = revision},
	}, opts)
	if s.worker != nil { thread.destroy(s.worker) }
	for &field in s.fields {
		delete(field.text)
		for previous in field.history { delete(previous) }
		delete(field.history)
	}
	if code != 0 { os.exit(code) }
}
