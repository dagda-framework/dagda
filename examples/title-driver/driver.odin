package title_driver

import "core:encoding/json"
import "core:strings"
import "core:unicode/utf8"
import "dagda:dagda"
import title_model "dagda:examples/title-model"

// Wire protocol: one UTF-8 JSON object per line.
// Requests:  inspect{role} · preview/commit{id,base_revision,text} · undo{id,base_revision}
// Success:   {"ok":true,"id":N,"revision":N,"text":"..."} (inspect adds "role", undo adds "changed")
// Errors:    {"ok":false,"error":"Name"} (stale also adds current "revision")

write_json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
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
			if c < 0x20 {
				strings.write_string(b, "\\u00")
				hex := "0123456789abcdef"
				strings.write_byte(b, hex[c>>4])
				strings.write_byte(b, hex[c&0xf])
			} else {
				strings.write_byte(b, c)
			}
		}
	}
	strings.write_byte(b, '"')
}

reply_success :: proc(id: dagda.Object_Id, revision: dagda.Revision, text: string, role := "", is_inspect := false, changed: ^bool = nil) -> string {
	b: strings.Builder
	strings.builder_init(&b)
	strings.write_string(&b, "{\"ok\":true,\"id\":")
	strings.write_u64(&b, u64(id))
	strings.write_string(&b, ",\"revision\":")
	strings.write_u64(&b, u64(revision))
	strings.write_string(&b, ",\"text\":")
	write_json_string(&b, text)
	if is_inspect {
		strings.write_string(&b, ",\"role\":")
		write_json_string(&b, role)
	}
	if changed != nil {
		strings.write_string(&b, ",\"changed\":")
		strings.write_string(&b, changed^ ? "true" : "false")
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

reply_error :: proc(name: string, revision: ^dagda.Revision = nil) -> string {
	b: strings.Builder
	strings.builder_init(&b)
	strings.write_string(&b, "{\"ok\":false,\"error\":")
	write_json_string(&b, name)
	if revision != nil {
		strings.write_string(&b, ",\"revision\":")
		strings.write_u64(&b, u64(revision^))
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

error_name :: proc(err: title_model.Error) -> string {
	switch err {
	case .Unknown_Object:
		return "Unknown_Object"
	case .Stale_Revision:
		return "Stale_Revision"
	case .Invalid_Text:
		return "Invalid_Text"
	case .Alloc_Failed:
		return "Alloc_Failed"
	case .None:
		return "None"
	}
	return "None"
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

get_revision :: proc(obj: json.Object, key: string) -> (dagda.Revision, bool) {
	id, ok := get_id(obj, key)
	return dagda.Revision(id), ok
}

// single_object reports whether line holds exactly one complete
// JSON object and nothing else (surrounding whitespace aside).
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
			return false // trailing content after the one object
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

MAX_WIRE_INT :: "9223372036854775807"

// numeric_token_in_range reports whether a raw JSON number token
// is a non-negative integer within the signed 64-bit range. The
// check runs on the original token text, before any conversion,
// so a huge decimal that would narrow or wrap is rejected.
numeric_token_in_range :: proc(kind: json.Token_Kind, text: string) -> bool {
	if kind != .Integer || len(text) == 0 {
		return false
	}
	for i in 0 ..< len(text) {
		if text[i] < '0' || text[i] > '9' {
			return false
		}
	}
	trimmed := text
	for len(trimmed) > 1 && trimmed[0] == '0' {
		trimmed = trimmed[1:]
	}
	if len(trimmed) != len(MAX_WIRE_INT) {
		return len(trimmed) < len(MAX_WIRE_INT)
	}
	return trimmed <= MAX_WIRE_INT
}

// id_fields_in_range validates every top-level id / base_revision
// value from its original numeric token, consistent with the
// client's signed-range parsing.
id_fields_in_range :: proc(line: string) -> bool {
	t := json.make_tokenizer(line, .JSON, true)
	depth := 0
	last_key := ""
	pending := false
	for {
		token, err := json.get_token(&t)
		if token.kind == .EOF {
			return true
		}
		if err != .None {
			return false
		}
		if pending {
			if depth == 1 && !numeric_token_in_range(token.kind, token.text) {
				return false
			}
			pending = false
		}
		switch token.kind {
		case .Open_Brace, .Open_Bracket:
			depth += 1
		case .Close_Brace, .Close_Bracket:
			depth -= 1
		case .String:
			if depth == 1 {
				last_key = token.text
			}
		case .Colon:
			if depth == 1 && (last_key == "\"id\"" || last_key == "\"base_revision\"") {
				pending = true
			}
		case .Null, .False, .True, .Infinity, .NaN, .Integer, .Float, .Ident, .Comma, .EOF, .Invalid:
		}
	}
}

// dispatch handles one request line against the supplied model and
// returns one owned reply line (without newline; caller deletes it).
// It is transport-independent: no socket code lives here. Exactly
// one complete UTF-8 JSON object per line is accepted; anything
// else is rejected before the model is touched.
dispatch :: proc(model: ^title_model.Model, line: string) -> string {
	if !utf8.valid_string(line) || len(strings.trim_space(line)) == 0 || !single_object(line) || !id_fields_in_range(line) {
		return reply_error("Malformed_Request")
	}
	value, parse_err := json.parse_string(line, .JSON, true)
	if parse_err != .None {
		return reply_error("Malformed_Request")
	}
	defer json.destroy_value(value)

	obj, is_obj := value.(json.Object)
	if !is_obj {
		return reply_error("Malformed_Request")
	}
	op, has_op := get_string(obj, "op")
	if !has_op {
		return reply_error("Malformed_Request")
	}

	snap := title_model.snapshot(model)

	switch op {
	case "inspect":
		role, ok := get_string(obj, "role")
		if !ok {
			return reply_error("Malformed_Request")
		}
		objects := [1]dagda.Object_Info{snap.object}
		ids: [1]dagda.Object_Id
		written, total := dagda.find_by_role(objects[:], role, ids[:])
		if total == 0 || written == 0 {
			return reply_error("Unknown_Role")
		}
		// Borrowed snapshot text is still valid: nothing mutated.
		return reply_success(snap.object.id, snap.revision, snap.text, role = snap.object.role, is_inspect = true)

	case "preview", "commit":
		id, ok_id := get_id(obj, "id")
		base, ok_base := get_revision(obj, "base_revision")
		text, ok_text := get_string(obj, "text")
		if !ok_id || !ok_base || !ok_text {
			return reply_error("Malformed_Request")
		}
		target := dagda.Action_Target{id = id, base_revision = base}
		if op == "preview" {
			p, err := title_model.preview(model, target, text)
			if err != .None {
				if err == .Stale_Revision {
					rev := title_model.snapshot(model).revision
					return reply_error(error_name(err), &rev)
				}
				return reply_error(error_name(err))
			}
			// Encode from the owned preview, then release it.
			reply := reply_success(id, title_model.snapshot(model).revision, p.text)
			title_model.preview_destroy(&p)
			return reply
		}
		if err := title_model.commit(model, target, text); err != .None {
			if err == .Stale_Revision {
				rev := title_model.snapshot(model).revision
				return reply_error(error_name(err), &rev)
			}
			return reply_error(error_name(err))
		}
		after := title_model.snapshot(model)
		return reply_success(after.object.id, after.revision, after.text)

	case "undo":
		id, ok_id := get_id(obj, "id")
		base, ok_base := get_revision(obj, "base_revision")
		if !ok_id || !ok_base {
			return reply_error("Malformed_Request")
		}
		target := dagda.Action_Target{id = id, base_revision = base}
		if err := dagda.check_target(target, snap.object, snap.revision); err != .None {
			if err == .Stale_Revision {
				rev := snap.revision
				return reply_error("Stale_Revision", &rev)
			}
			return reply_error("Unknown_Object")
		}
		changed := title_model.undo(model)
		after := title_model.snapshot(model)
		return reply_success(after.object.id, after.revision, after.text, changed = &changed)
	}
	return reply_error("Unknown_Operation")
}
