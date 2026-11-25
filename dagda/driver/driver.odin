package driver

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import "dagda:dagda"

// Wire protocol: one UTF-8 JSON object per line.
// Requests:
//   {"op":"inspect"}                          -> list all resolved elements
//   {"op":"inspect","role":"counter.value"}   -> discover resolved elements by role
//   {"op":"invoke","id":2,"action":"activate"} -> invoke an advertised action by ID
// Replies:
//   {"ok":true,"elements":[...]}
//   {"ok":true,"id":2,"action":"activate"}
//   {"ok":false,"error":"Name"}

write_json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for i in 0 ..< len(s) {
		ch := s[i]
		switch ch {
		case '"':
			strings.write_string(b, "\\\"")
		case '\\':
			strings.write_string(b, "\\\\")
		case '\n':
			strings.write_string(b, "\\n")
		case '\r':
			strings.write_string(b, "\\r")
		case '\t':
			strings.write_string(b, "\\t")
		case:
			if ch < 0x20 {
				strings.write_string(b, "\\u00")
				hex := "0123456789abcdef"
				strings.write_byte(b, hex[ch >> 4])
				strings.write_byte(b, hex[ch & 0xf])
			} else {
				strings.write_byte(b, ch)
			}
		}
	}
	strings.write_byte(b, '"')
}

reply_error :: proc(name: string) -> string {
	b: strings.Builder
	strings.builder_init(&b)
	strings.write_string(&b, "{\"ok\":false,\"error\":")
	write_json_string(&b, name)
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

kind_name :: proc(kind: dagda.Element_Kind) -> string {
	switch kind {
	case .Label:
		return "label"
	case .Button:
		return "button"
	}
	return "unknown"
}

action_name :: proc(action: dagda.Action) -> string {
	switch action {
	case .Activate:
		return "activate"
	}
	return ""
}

parse_action :: proc(name: string) -> (dagda.Action, bool) {
	if name == "activate" {
		return .Activate, true
	}
	return .Activate, false
}

write_resolved_element :: proc(b: ^strings.Builder, el: dagda.Resolved_Element) {
	strings.write_string(b, "{\"id\":")
	strings.write_u64(b, u64(el.info.id))
	strings.write_string(b, ",\"role\":")
	write_json_string(b, el.info.role)
	strings.write_string(b, ",\"kind\":")
	write_json_string(b, kind_name(el.kind))
	strings.write_string(b, ",\"text\":")
	write_json_string(b, el.text)
	fmt.sbprintf(b, ",\"bounds\":{{\"x\":%.2f,\"y\":%.2f,\"width\":%.2f,\"height\":%.2f}},\"actions\":[",
		el.bounds.x, el.bounds.y, el.bounds.width, el.bounds.height)
	first := true
	if .Activate in el.actions {
		if !first {
			strings.write_byte(b, ',')
		}
		write_json_string(b, action_name(.Activate))
		first = false
	}
	strings.write_string(b, "]}")
}

single_object :: proc(line: string) -> bool {
	t := json.make_tokenizer(line, .JSON, true)
	depth := 0
	started := false
	for {
		token, err := json.get_token(&t)
		if token.kind == .EOF {
			return started && depth == 0
		}
		if err != .None || token.kind == .Invalid || token.kind == .Ident {
			return false
		}
		if !started {
			if token.kind != .Open_Brace {
				return false
			}
			started = true
		} else if depth == 0 {
			return false
		}
		switch token.kind {
		case .Open_Brace, .Open_Bracket:
			depth += 1
		case .Close_Brace, .Close_Bracket:
			depth -= 1
			if depth < 0 {
				return false
			}
		case .EOF, .Invalid, .Ident:
			return false
		case .Null, .False, .True, .Infinity, .NaN, .Integer, .Float, .String, .Colon, .Comma:
		}
	}
}

get_string :: proc(obj: json.Object, key: string) -> (string, bool) {
	v, ok := obj[key]
	if !ok {
		return "", false
	}
	s, is_str := v.(json.String)
	return string(s), is_str
}

get_id :: proc(obj: json.Object, key: string) -> (dagda.Object_Id, bool) {
	v, ok := obj[key]
	if !ok {
		return 0, false
	}
	n, is_int := v.(json.Integer)
	if !is_int || n < 0 {
		return 0, false
	}
	return dagda.Object_Id(n), true
}

// dispatch handles one newline-delimited JSON request against a resolved
// dagda.Frame and Action_Handler. It returns the owned JSON reply line
// (caller deletes) and whether an action was applied (so the host can rebuild
// and redraw the frame).
dispatch :: proc(
	frame: dagda.Frame,
	handler: dagda.Action_Handler,
	user_data: rawptr,
	line: string,
) -> (reply: string, applied: bool) {
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
	op, has_op := get_string(obj, "op")
	if !has_op {
		return reply_error("Malformed_Request"), false
	}

	switch op {
	case "inspect":
		role_val, has_role_key := obj["role"]
		b: strings.Builder
		strings.builder_init(&b)

		if !has_role_key {
			strings.write_string(&b, "{\"ok\":true,\"elements\":[")
			for el, i in frame.elements {
				if i > 0 {
					strings.write_byte(&b, ',')
				}
				write_resolved_element(&b, el)
			}
			strings.write_string(&b, "]}")
			return strings.to_string(b), false
		}

		role_str, is_str := role_val.(json.String)
		if !is_str {
			strings.builder_destroy(&b)
			return reply_error("Malformed_Request"), false
		}

		objects := make([]dagda.Object_Info, len(frame.elements))
		defer delete(objects)
		for el, i in frame.elements {
			objects[i] = el.info
		}
		ids := make([]dagda.Object_Id, len(frame.elements))
		defer delete(ids)
		written, total := dagda.find_by_role(objects, string(role_str), ids)
		if total == 0 || written == 0 {
			strings.builder_destroy(&b)
			return reply_error("Unknown_Role"), false
		}

		strings.write_string(&b, "{\"ok\":true,\"elements\":[")
		emitted := 0
		for id in ids[:written] {
			el, found := dagda.find(frame, id)
			if !found {
				continue
			}
			if emitted > 0 {
				strings.write_byte(&b, ',')
			}
			write_resolved_element(&b, el)
			emitted += 1
		}
		strings.write_string(&b, "]}")
		return strings.to_string(b), false

	case "invoke":
		id, ok_id := get_id(obj, "id")
		act_str, ok_act := get_string(obj, "action")
		if !ok_id || !ok_act {
			return reply_error("Malformed_Request"), false
		}
		act, valid_act := parse_action(act_str)
		if !valid_act {
			return reply_error("Unknown_Action"), false
		}
		res := dagda.invoke(frame, id, act, handler, user_data)
		switch res {
		case .Applied:
			b: strings.Builder
			strings.builder_init(&b)
			strings.write_string(&b, "{\"ok\":true,\"id\":")
			strings.write_u64(&b, u64(id))
			strings.write_string(&b, ",\"action\":")
			write_json_string(&b, action_name(act))
			strings.write_byte(&b, '}')
			return strings.to_string(b), true
		case .Unknown_Object:
			return reply_error("Unknown_Object"), false
		case .Unsupported_Action:
			return reply_error("Unsupported_Action"), false
		case .Not_Handled:
			return reply_error("Not_Handled"), false
		}
	}

	return reply_error("Unknown_Operation"), false
}
