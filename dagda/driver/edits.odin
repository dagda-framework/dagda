package driver

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import "dagda:dagda"

// Advertised-edit wiring for the generic driver. The app supplies
// its declarations, its Edit_Handler, and how to read an object's
// current revision; document policy stays in the app.

Edit_Revision_Proc :: #type proc(user_data: rawptr, id: dagda.Object_Id) -> (dagda.Revision, bool)

Edit_Source :: struct {
	edits:       []dagda.Advertised_Edit,
	handler:     dagda.Edit_Handler,
	user_data:   rawptr,
	revision_of: Edit_Revision_Proc,
}

argument_kind_name :: proc(kind: dagda.Edit_Argument_Kind) -> string {
	switch kind {
	case .None:
		return "none"
	case .Text:
		return "text"
	case .Rect:
		return "rect"
	}
	return "none"
}

write_argument :: proc(b: ^strings.Builder, arg: dagda.Edit_Argument) {
	strings.write_string(b, "{\"kind\":")
	write_json_string(b, argument_kind_name(arg.kind))
	switch arg.kind {
	case .Text:
		strings.write_string(b, ",\"text\":")
		write_json_string(b, arg.text)
	case .Rect:
		strings.write_string(b, ",\"rect\":{\"x\":")
		write_f32_exact(b, arg.rect.x)
		strings.write_string(b, ",\"y\":")
		write_f32_exact(b, arg.rect.y)
		strings.write_string(b, ",\"width\":")
		write_f32_exact(b, arg.rect.width)
		strings.write_string(b, ",\"height\":")
		write_f32_exact(b, arg.rect.height)
		strings.write_byte(b, '}')
	case .None:
	}
	strings.write_byte(b, '}')
}

edit_error_reply :: proc(source: Edit_Source, id: dagda.Object_Id, result: dagda.Edit_Result) -> string {
	name: string
	switch result {
	case .Unknown_Object:
		name = "Unknown_Object"
	case .Unknown_Edit:
		name = "Unknown_Edit"
	case .Wrong_Argument:
		name = "Wrong_Argument"
	case .Stale_Revision:
		if source.revision_of != nil {
			if rev, ok := source.revision_of(source.user_data, id); ok {
				b: strings.Builder
				strings.builder_init(&b)
				strings.write_string(&b, "{\"ok\":false,\"error\":\"Stale_Revision\",\"revision\":")
				strings.write_u64(&b, u64(rev))
				strings.write_byte(&b, '}')
				return strings.to_string(b)
			}
		}
		name = "Stale_Revision"
	case .Alloc_Failed:
		name = "Alloc_Failed"
	case .Not_Handled:
		name = "Not_Handled"
	case .Applied:
		name = "None"
	}
	return reply_error(name)
}

get_number :: proc(obj: json.Object, key: string) -> (f32, bool) {
	v, ok := obj[key]
	if !ok {
		return 0, false
	}
	#partial switch n in v {
	case json.Integer:
		return f32(n), true
	case json.Float:
		return f32(n), true
	}
	return 0, false
}

dispatch_edits :: proc(
	frame: dagda.Frame,
	handler: dagda.Action_Handler,
	user_data: rawptr,
	source: Edit_Source,
	line: string,
) -> (reply: string, applied: bool) {
	// Decide whether this is an edit operation; everything else
	// (inspect / invoke) keeps the existing dispatch behavior.
	// The op name is copied out before the probe value is
	// destroyed, since get_string only borrows its storage.
	op_buf: [16]u8
	op_len := 0
	is_edit_op := false
	probe, probe_err := json.parse_string(line, .JSON, true)
	if probe_err == .None {
		if probe_obj, is_obj := probe.(json.Object); is_obj {
			op, _ := get_string(probe_obj, "op")
			if (op == "edits" || op == "preview" || op == "commit") && len(op) <= len(op_buf) {
				copy(op_buf[:], op)
				op_len = len(op)
				is_edit_op = true
			}
		}
		json.destroy_value(probe)
	}
	if is_edit_op {
		return dispatch_edit_op(source, line, string(op_buf[:op_len]))
	}
	return dispatch(frame, handler, user_data, line)
}

dispatch_edit_op :: proc(source: Edit_Source, line: string, op: string) -> (string, bool) {
	if !utf8.valid_string(line) || len(strings.trim_space(line)) == 0 || !single_object(line) {
		return reply_error("Malformed_Request"), false
	}
	value, parse_err := json.parse_string(line, .JSON, true)
	if parse_err != .None {
		return reply_error("Malformed_Request"), false
	}
	defer json.destroy_value(value)
	obj, is_obj := value.(json.Object)
	if !is_obj {
		return reply_error("Malformed_Request"), false
	}

	raw_id, _, ok_id := extract_top_level_u64(line, "id")
	if !ok_id {
		return reply_error("Malformed_Request"), false
	}
	id := dagda.Object_Id(raw_id)

	switch op {
	case "edits":
		if source.revision_of == nil {
			return reply_error("Unknown_Object"), false
		}
		rev, known := source.revision_of(source.user_data, id)
		if !known {
			return reply_error("Unknown_Object"), false
		}
		found := make([]dagda.Advertised_Edit, len(source.edits))
		defer delete(found)
		written, _ := dagda.edits_for(source.edits, id, found)
		b: strings.Builder
		strings.builder_init(&b)
		strings.write_string(&b, "{\"ok\":true,\"id\":")
		strings.write_u64(&b, u64(id))
		strings.write_string(&b, ",\"revision\":")
		strings.write_u64(&b, u64(rev))
		strings.write_string(&b, ",\"edits\":[")
		for edit, i in found[:written] {
			if i > 0 {
				strings.write_byte(&b, ',')
			}
			strings.write_string(&b, "{\"name\":")
			write_json_string(&b, edit.edit)
			strings.write_string(&b, ",\"argument\":")
			write_json_string(&b, argument_kind_name(edit.argument))
			strings.write_byte(&b, '}')
		}
		strings.write_string(&b, "]}")
		return strings.to_string(b), false

	case "preview", "commit":
		name, ok_name := get_string(obj, "edit")
		raw_rev, _, ok_rev := extract_top_level_u64(line, "base_revision")
		arg, ok_arg := parse_argument(obj)
		if !ok_name || !ok_rev || !ok_arg {
			return reply_error("Malformed_Request"), false
		}
		target := dagda.Action_Target{id = id, base_revision = dagda.Revision(raw_rev)}
		if op == "preview" {
			// A successful preview must be based on the app's
			// current revision, exactly like a commit would be.
			if source.revision_of != nil {
				if current, known := source.revision_of(source.user_data, id); known && current != target.base_revision {
					return edit_error_reply(source, id, .Stale_Revision), false
				}
			}
			preview, result := dagda.preview_edit(source.edits, target, name, arg)
			if result != .Applied {
				return edit_error_reply(source, id, result), false
			}
			b: strings.Builder
			strings.builder_init(&b)
			strings.write_string(&b, "{\"ok\":true,\"id\":")
			strings.write_u64(&b, u64(id))
			strings.write_string(&b, ",\"edit\":")
			write_json_string(&b, preview.edit)
			strings.write_string(&b, ",\"revision\":")
			strings.write_u64(&b, u64(target.base_revision))
			strings.write_string(&b, ",\"argument\":")
			write_argument(&b, preview.argument)
			strings.write_byte(&b, '}')
			reply := strings.to_string(b)
			dagda.preview_destroy(&preview)
			return reply, false
		}
		result := dagda.commit_edit(source.edits, target, name, arg, source.handler, source.user_data)
		if result != .Applied {
			return edit_error_reply(source, id, result), false
		}
		rev := target.base_revision
		if source.revision_of != nil {
			if current, ok := source.revision_of(source.user_data, id); ok {
				rev = current
			}
		}
		b: strings.Builder
		strings.builder_init(&b)
		strings.write_string(&b, "{\"ok\":true,\"id\":")
		strings.write_u64(&b, u64(id))
		strings.write_string(&b, ",\"edit\":")
		write_json_string(&b, name)
		strings.write_string(&b, ",\"revision\":")
		strings.write_u64(&b, u64(rev))
		strings.write_byte(&b, '}')
		return strings.to_string(b), true
	}
	return reply_error("Unknown_Operation"), false
}

parse_argument :: proc(obj: json.Object) -> (dagda.Edit_Argument, bool) {
	raw, has := obj["argument"]
	if !has {
		return {}, false
	}
	arg_obj, is_obj := raw.(json.Object)
	if !is_obj {
		return {}, false
	}
	kind_str, ok := get_string(arg_obj, "kind")
	if !ok {
		return {}, false
	}
	switch kind_str {
	case "none":
		return dagda.argument_none(), true
	case "text":
		text, has_text := get_string(arg_obj, "text")
		if !has_text {
			return {}, false
		}
		return dagda.argument_text(text), true
	case "rect":
		raw_rect, has_rect := arg_obj["rect"]
		if !has_rect {
			return {}, false
		}
		rect_obj, is_rect := raw_rect.(json.Object)
		if !is_rect {
			return {}, false
		}
		x, ok_x := get_number(rect_obj, "x")
		y, ok_y := get_number(rect_obj, "y")
		w, ok_w := get_number(rect_obj, "width")
		h, ok_h := get_number(rect_obj, "height")
		if !ok_x || !ok_y || !ok_w || !ok_h {
			return {}, false
		}
		return dagda.argument_rect({x = x, y = y, width = w, height = h}), true
	}
	return {}, false
}
