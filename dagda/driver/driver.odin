package driver

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "dagda:dagda"

// Wire protocol: one UTF-8 JSON object per line.
// Requests:
//   {"op":"inspect"}                          -> list all resolved elements
//   {"op":"inspect","role":"counter.value"}   -> discover resolved elements by role
//   {"op":"invoke","id":2,"action":"activate"} -> invoke an advertised action by ID
//   {"op":"hit-test","x":120,"y":40}          -> topmost element at a window point, or null
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

write_f32_exact :: proc(b: ^strings.Builder, v: f32) {
	if v == 0 {
		strings.write_byte(b, '0')
		return
	}
	buf: [64]u8
	s := strconv.write_float(buf[:], f64(v), 'g', -1, 32)
	s = strings.trim_prefix(s, "+")
	strings.write_string(b, s)
}

write_resolved_element :: proc(b: ^strings.Builder, el: dagda.Resolved_Element, has_canvas := false, canvas: dagda.Size = {}) {
	strings.write_string(b, "{\"id\":")
	strings.write_u64(b, u64(el.info.id))
	strings.write_string(b, ",\"role\":")
	write_json_string(b, el.info.role)
	strings.write_string(b, ",\"kind\":")
	write_json_string(b, kind_name(el.kind))
	strings.write_string(b, ",\"text\":")
	write_json_string(b, el.text)
	fmt.sbprintf(b, ",\"bounds\":{{\"x\":%.2f,\"y\":%.2f,\"width\":%.2f,\"height\":%.2f}}",
		el.bounds.x, el.bounds.y, el.bounds.width, el.bounds.height)
	if has_canvas {
		// visible_canvas_bounds is the read-only intersection of
		// the element's canvas rectangle with the canvas sheet,
		// or null when that intersection has no area. On any axis
		// that fits inside the sheet, the declared origin and
		// size are preserved exactly, even when the other axis
		// is clipped.
		cb := el.canvas_bounds
		// Compare each extent with the space remaining on its
		// axis instead of summing origin + size, whose rounding
		// could hide a far-edge overrun.
		vis_x, vis_w: f32
		if cb.x >= 0 {
			remaining := canvas.width - cb.x
			if cb.width <= remaining {
				vis_x, vis_w = cb.x, cb.width
			} else {
				vis_x, vis_w = cb.x, remaining
			}
		} else {
			vis_x = 0
			vis_w = min(cb.width + cb.x, canvas.width)
		}
		vis_y, vis_h: f32
		if cb.y >= 0 {
			remaining := canvas.height - cb.y
			if cb.height <= remaining {
				vis_y, vis_h = cb.y, cb.height
			} else {
				vis_y, vis_h = cb.y, remaining
			}
		} else {
			vis_y = 0
			vis_h = min(cb.height + cb.y, canvas.height)
		}
		strings.write_string(b, ",\"visible_canvas_bounds\":")
		if vis_w <= 0 || vis_h <= 0 {
			strings.write_string(b, "null")
		} else {
			strings.write_string(b, "{\"x\":")
			write_f32_exact(b, vis_x)
			strings.write_string(b, ",\"y\":")
			write_f32_exact(b, vis_y)
			strings.write_string(b, ",\"width\":")
			write_f32_exact(b, vis_w)
			strings.write_string(b, ",\"height\":")
			write_f32_exact(b, vis_h)
			strings.write_byte(b, '}')
		}
		strings.write_string(b, ",\"canvas_bounds\":{\"x\":")
		write_f32_exact(b, el.canvas_bounds.x)
		strings.write_string(b, ",\"y\":")
		write_f32_exact(b, el.canvas_bounds.y)
		strings.write_string(b, ",\"width\":")
		write_f32_exact(b, el.canvas_bounds.width)
		strings.write_string(b, ",\"height\":")
		write_f32_exact(b, el.canvas_bounds.height)
		strings.write_byte(b, '}')
	}
	strings.write_string(b, ",\"actions\":[")
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

parse_exact_u64_token :: proc(kind: json.Token_Kind, text: string) -> (u64, bool) {
	if kind != .Integer || len(text) == 0 {
		return 0, false
	}
	for i in 0 ..< len(text) {
		if text[i] < '0' || text[i] > '9' {
			return 0, false
		}
	}
	val, ok := strconv.parse_u64(text)
	return val, ok
}

is_key_name :: proc(token_text: string, target_key: string) -> bool {
	value, err := json.parse_string(token_text, .JSON, true)
	if err != .None {
		return false
	}
	defer json.destroy_value(value)
	s, ok := value.(json.String)
	return ok && string(s) == target_key
}

// extract_top_level_u64 parses a top-level unsigned 64-bit integer field directly
// from the original JSON token text so the full u64 range [0, max(u64)] round-trips
// without signed i64 overflow or float rounding, and any out-of-range or non-integer
// value is rejected before reaching the application handler.
extract_top_level_u64 :: proc(line: string, target_key: string) -> (val: u64, found: bool, ok: bool) {
	t := json.make_tokenizer(line, .JSON, true)
	depth := 0
	key_matches := false
	pending := false
	for {
		token, err := json.get_token(&t)
		if token.kind == .EOF {
			return val, found, found
		}
		if err != .None {
			return 0, false, false
		}
		if pending {
			if depth == 1 {
				parsed, valid := parse_exact_u64_token(token.kind, token.text)
				if !valid {
					return 0, true, false
				}
				val = parsed
				found = true
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
				key_matches = is_key_name(token.text, target_key)
			}
		case .Colon:
			if depth == 1 && key_matches {
				pending = true
			}
			key_matches = false
		case .Null, .False, .True, .Infinity, .NaN, .Integer, .Float, .Ident, .Comma, .EOF, .Invalid:
		}
	}
}

F32_MAX_MAGNITUDE :: 3.402823466e+38

// parse_f32_token converts an original JSON number token to a
// finite f32 without going through the parser's integer value,
// so huge integer tokens cannot wrap before conversion. Valid
// fractional and exponent forms are accepted; anything outside
// the finite f32 range is rejected.
parse_f32_token :: proc(kind: json.Token_Kind, text: string) -> (f32, bool) {
	if kind != .Integer && kind != .Float {
		return 0, false
	}
	val, ok := strconv.parse_f64(text)
	if !ok || val != val || val > F32_MAX_MAGNITUDE || val < -F32_MAX_MAGNITUDE {
		return 0, false
	}
	return f32(val), true
}

extract_top_level_f32 :: proc(line: string, target_key: string) -> (val: f32, found: bool, ok: bool) {
	t := json.make_tokenizer(line, .JSON, true)
	depth := 0
	key_matches := false
	pending := false
	for {
		token, err := json.get_token(&t)
		if token.kind == .EOF {
			return val, found, found
		}
		if err != .None {
			return 0, false, false
		}
		if pending {
			if depth == 1 {
				parsed, valid := parse_f32_token(token.kind, token.text)
				if !valid {
					return 0, true, false
				}
				val = parsed
				found = true
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
				key_matches = is_key_name(token.text, target_key)
			}
		case .Colon:
			if depth == 1 && key_matches {
				pending = true
			}
			key_matches = false
		case .Null, .False, .True, .Infinity, .NaN, .Integer, .Float, .Ident, .Comma, .EOF, .Invalid:
		}
	}
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
				write_resolved_element(&b, el, frame.has_canvas, frame.transform.canvas)
			}
			strings.write_string(&b, "]}")
			return strings.to_string(b), false
		}

		role_str, is_str := role_val.(json.String)
		if !is_str {
			strings.builder_destroy(&b)
			return reply_error("Malformed_Request"), false
		}

		// Emit each match directly from the frame role walk, in
		// declaration order; a missing role is Unknown_Role.
		strings.write_string(&b, "{\"ok\":true,\"elements\":[")
		emitted := 0
		query := dagda.query_by_role(frame, string(role_str))
		for {
			el, found := dagda.next_match(&query)
			if !found {
				break
			}
			if emitted > 0 {
				strings.write_byte(&b, ',')
			}
			write_resolved_element(&b, el, frame.has_canvas, frame.transform.canvas)
			emitted += 1
		}
		if emitted == 0 {
			strings.builder_destroy(&b)
			return reply_error("Unknown_Role"), false
		}
		strings.write_string(&b, "]}")
		return strings.to_string(b), false

	case "hit-test":
		// Read-only: coordinates are logical window coordinates,
		// the same space inspect reports as bounds. Delegates to
		// dagda.hit_test, so a query answers exactly what a
		// pointer press would hit without touching focus,
		// actions, or application state. ID 0 is a valid hit.
		x, _, ok_x := extract_top_level_f32(line, "x")
		y, _, ok_y := extract_top_level_f32(line, "y")
		if !ok_x || !ok_y {
			return reply_error("Malformed_Request"), false
		}
		b: strings.Builder
		strings.builder_init(&b)
		strings.write_string(&b, "{\"ok\":true,\"id\":")
		if hit_id, hit := dagda.hit_test(frame, {x = x, y = y}); hit {
			strings.write_u64(&b, u64(hit_id))
		} else {
			strings.write_string(&b, "null")
		}
		strings.write_byte(&b, '}')
		return strings.to_string(b), false

	case "invoke":
		raw_id, _, ok_id := extract_top_level_u64(line, "id")
		act_str, ok_act := get_string(obj, "action")
		if !ok_id || !ok_act {
			return reply_error("Malformed_Request"), false
		}
		id := dagda.Object_Id(raw_id)
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
