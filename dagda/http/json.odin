package dagda_http

import json "core:encoding/json"
import "core:io"
import "core:math"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

MAX_JSON_BYTES :: 8192
MAX_JSON_DEPTH :: 32

// Serialize before finalizing. The fixed writer bounds output allocation and
// ensures an encoding failure cannot send a partial successful response.
JSON_Writer :: struct { bytes: [MAX_JSON_BYTES]byte, count: int }
json_write :: proc(data: rawptr, mode: io.Stream_Mode, bytes: []byte, _: i64, _: io.Seek_From) -> (i64, io.Error) {
    if mode != .Write { return 0, .Unsupported }
    w := cast(^JSON_Writer)data
    if len(bytes) > len(w.bytes) - w.count { return 0, .Short_Write }
    copy(w.bytes[w.count:], bytes)
    w.count += len(bytes)
    return i64(len(bytes)), .None
}
respond_json :: proc(c: ^Context, status: int, value: $T) -> bool {
    if c._state != .Open { return false }
    w: JSON_Writer
    error := json.marshal_to_writer(io.Writer{procedure=json_write, data=&w}, value, {spec=.JSON})
    if error != nil { return fail(c, .Invalid_Response) }
    // write_response copies body bytes into transport storage before returning.
    return json_text(c, status, string(w.bytes[:w.count]))
}

// Destination changes only after complete validation/decoding. Strings, slices,
// and nullable unions are allocated in the request arena. Decode once per request.
decode_json :: proc(c: ^Context, destination: ^$T) -> bool {
    if c._state != .Open { return false }
    if destination == nil || c._json_decoded {
        fail(c, .Invalid_JSON_Destination)
        return false
    }
    c._json_decoded = true
    context.allocator = c.allocator
    context.temp_allocator = c.allocator
    media, _ := header(c, "content-type")
    if !json_media_type(media) {
        fail(c, .Unsupported_Media_Type)
        return false
    }
    if !json_syntax_safe(c.body) {
        fail(c, .Invalid_JSON)
        return false
    }
    parser := json.make_parser(c.body, spec=.JSON, parse_integers=true, allocator=c.allocator)
    value, error := json.parse_value(&parser)
    if error != nil || parser.curr_token.kind != .EOF || (parser.curr_token_err != nil && parser.curr_token_err != .EOF) || !json_matches(value, type_info_of(T)) {
        fail(c, .Invalid_JSON)
        return false
    }
    decoded: T
    if json.unmarshal_string(c.body, &decoded, spec=.JSON, allocator=c.allocator) != nil {
        fail(c, .Invalid_JSON)
        return false
    }
    destination^ = decoded
    c._json_object, c._json_object_ready = value.(json.Object)
    return true
}

json_media_type :: proc(value: string) -> bool {
    parts := strings.split(value, ";", context.temp_allocator)
    if len(parts) == 0 || !strings.equal_fold(strings.trim_space(parts[0]), "application/json") { return false }
    // Only the optional UTF-8 charset is supported; reject ambiguous parameters.
    if len(parts) == 1 { return true }
    if len(parts) != 2 { return false }
    parameter := strings.trim_space(parts[1])
    equal := strings.index_byte(parameter, '=')
    if equal < 0 || !strings.equal_fold(strings.trim_space(parameter[:equal]), "charset") { return false }
    charset := strings.trim_space(parameter[equal+1:])
    return strings.equal_fold(charset, "utf-8") || strings.equal_fold(charset, `"utf-8"`)
}

// Bound recursion before calling the standard parser. Tokenization also checks
// numeric range before the standard decoder can narrow an integer by casting.
json_syntax_safe :: proc(body: string, bounded_integers := true) -> bool {
    if len(body) == 0 || len(body) > MAX_JSON_BYTES || !utf8.valid_string(body) { return false }
    tokenizer := json.make_tokenizer(body, .JSON, true)
    depth := 0
    empty_string := false
    comma := false
    for {
        token, error := json.get_token(&tokenizer)
        if error != nil && error != .EOF { return false }
        if token.kind == .Colon && empty_string { return false }
        if comma && (token.kind == .Close_Brace || token.kind == .Close_Bracket) { return false }
        comma = token.kind == .Comma
        empty_string = token.kind == .String && token.text == `""`
        #partial switch token.kind {
        case .Open_Brace, .Open_Bracket:
            depth += 1
            if depth > MAX_JSON_DEPTH { return false }
        case .Close_Brace, .Close_Bracket:
            depth -= 1
            if depth < 0 { return false }
        case .Integer:
            if bounded_integers {
                if _, ok := strconv.parse_i64(token.text); !ok { return false }
            }
        case .Float:
            number, ok := strconv.parse_f64(token.text)
            if !ok || math.is_nan(number) || math.is_inf(number) { return false }
        case .EOF:
            return depth == 0 && json.is_valid(transmute([]byte)body, .JSON, true)
        }
    }
}

// Deliberately small DTO surface: structs, arrays/slices, nullable unions and
// scalar values. Unknown fields and null for non-nullable fields are rejected.
// Missing fields retain zero values; required/business validation is separate.
json_matches :: proc(value: json.Value, info: ^reflect.Type_Info) -> bool {
    info := reflect.type_info_base(info)
    #partial switch kind in info.variant {
    case reflect.Type_Info_Union:
        if len(kind.variants) != 1 || kind.no_nil { return false }
        if _, null := value.(json.Null); null { return true }
        return json_matches(value, kind.variants[0])
    case reflect.Type_Info_Struct:
        object, ok := value.(json.Object)
        if !ok { return false }
        fields := reflect.struct_fields_zipped(info.id)
        for key, element in object {
            found := false
            for field in fields {
                if field.is_using { return false }
                tag, tagged := reflect.struct_tag_lookup(field.tag, "json")
                name := field.name
                if tagged {
                    tagged_name := tag
                    if comma := strings.index_byte(tag, ','); comma >= 0 { tagged_name = tag[:comma] }
                    if tagged_name == "-" { continue }
                    if tagged_name != "" { name = tagged_name }
                }
                if key == name {
                    if !json_matches(element, field.type) { return false }
                    found = true
                    break
                }
            }
            if !found { return false }
        }
        return true
    case reflect.Type_Info_Slice:
        array, ok := value.(json.Array)
        if !ok { return false }
        for element in array { if !json_matches(element, kind.elem) { return false } }
        return true
    case reflect.Type_Info_Array:
        array, ok := value.(json.Array)
        if !ok || len(array) != kind.count { return false }
        for element in array { if !json_matches(element, kind.elem) { return false } }
        return true
    case reflect.Type_Info_String:
        _, ok := value.(json.String)
        return ok && info.id != cstring
    case reflect.Type_Info_Boolean:
        _, ok := value.(json.Boolean)
        return ok
    case reflect.Type_Info_Integer:
        number, ok := value.(json.Integer)
        if !ok || info.size > 8 { return false }
        bits := uint(info.size * 8)
        if kind.signed {
            if bits == 64 { return true }
            limit := i64(1) << (bits-1)
            return number >= -limit && number < limit
        }
        return number >= 0 && (bits == 64 || u64(number) < (u64(1) << bits))
    case reflect.Type_Info_Float:
        number: f64
        #partial switch v in value {
        case json.Float: number = v
        case json.Integer: number = f64(v)
        case: return false
        }
        return info.size == 8 || (info.size == 4 && !math.is_inf(f32(number)))
    }
    return false
}

// Exact top-level wire name (including json tags). This is available only after
// a successful object decode; it does not interpret dotted paths or JSON Pointer.
JSON_Field_State :: enum { Unavailable, Missing, Null, Value }
json_field_state :: proc(c: ^Context, name: string) -> JSON_Field_State {
    if !c._json_object_ready { return .Unavailable }
    value, found := c._json_object[name]
    if !found { return .Missing }
    if _, null := value.(json.Null); null { return .Null }
    return .Value
}
