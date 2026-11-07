package dagda_validation

import "core:math"
import "core:strings"
import "core:unicode/utf8"

MAX_ERRORS :: 16
MAX_FIELD_BYTES :: 64
MAX_CODE_BYTES :: 32

// Fixed storage owns metadata without borrowing caller strings or allocating.
// Field names and codes are application-defined; never pass submitted values.
Issue :: struct {
    field: [MAX_FIELD_BYTES]byte,
    field_length: int,
    code: [MAX_CODE_BYTES]byte,
    code_length: int,
}
Errors :: struct {
    items: [MAX_ERRORS]Issue,
    count: int,
    truncated: bool,
    invalid: bool, // invalid rule configuration/metadata; fail closed
}
valid :: proc(errors: ^Errors) -> bool {
    return errors != nil && errors.count == 0 && !errors.truncated && !errors.invalid
}
field_name :: proc(issue: ^Issue) -> string { return string(issue.field[:issue.field_length]) }
error_code :: proc(issue: ^Issue) -> string { return string(issue.code[:issue.code_length]) }

metadata_valid :: proc(value: string, field: bool) -> bool {
    if len(value) == 0 || len(value) > (MAX_FIELD_BYTES if field else MAX_CODE_BYTES) { return false }
    for ch in value {
        if ('a' <= ch && ch <= 'z') || ('A' <= ch && ch <= 'Z') || ('0' <= ch && ch <= '9') || ch == '_' { continue }
        if field && (ch == '.' || ch == '[' || ch == ']' || ch == '-') { continue }
        return false
    }
    return true
}
add :: proc(errors: ^Errors, field, code: string) {
    if errors == nil { return }
    if !metadata_valid(field, true) || !metadata_valid(code, false) { errors.invalid = true; return }
    for &issue in errors.items[:errors.count] {
        if field_name(&issue) == field && error_code(&issue) == code { return }
    }
    if errors.count == MAX_ERRORS { errors.truncated = true; return }
    issue := &errors.items[errors.count]
    issue.field_length = len(field)
    issue.code_length = len(code)
    copy(issue.field[:], transmute([]byte)field)
    copy(issue.code[:], transmute([]byte)code)
    errors.count += 1
}
check :: proc(errors: ^Errors, field: string, condition: bool, code := "invalid") -> bool {
    if errors == nil { return false }
    if !metadata_valid(field, true) || !metadata_valid(code, false) { errors.invalid = true; return false }
    if !condition { add(errors, field, code) }
    return condition
}
required :: proc(errors: ^Errors, field: string, has_value: bool) -> bool {
    return check(errors, field, has_value, "required")
}
required_text :: proc(errors: ^Errors, field, value: string) -> bool {
    return required(errors, field, len(strings.trim_space(value)) > 0)
}
// Length is Unicode code points, not bytes or user-perceived grapheme clusters.
// Validation never trims or otherwise rewrites the submitted value.
text_length :: proc(errors: ^Errors, field, value: string, minimum, maximum: int) -> bool {
    if errors == nil { return false }
    if minimum < 0 || maximum < minimum { errors.invalid = true; return false }
    if !utf8.valid_string(value) { return check(errors, field, false) }
    length := utf8.rune_count_in_string(value)
    if length < minimum { return check(errors, field, false, "too_short") }
    if length > maximum { return check(errors, field, false, "too_long") }
    return check(errors, field, true)
}
integer_range :: proc(errors: ^Errors, field: string, value, minimum, maximum: i64) -> bool {
    if errors == nil { return false }
    if maximum < minimum { errors.invalid = true; return false }
    return check(errors, field, value >= minimum && value <= maximum, "out_of_range")
}
number_range :: proc(errors: ^Errors, field: string, value, minimum, maximum: f64) -> bool {
    if errors == nil { return false }
    if math.is_nan(minimum) || math.is_nan(maximum) || math.is_inf(minimum) || math.is_inf(maximum) || maximum < minimum {
        errors.invalid = true
        return false
    }
    return check(errors, field, !math.is_nan(value) && !math.is_inf(value) && value >= minimum && value <= maximum, "out_of_range")
}
one_of :: proc(errors: ^Errors, field, value: string, choices: []string) -> bool {
    if errors == nil { return false }
    if len(choices) == 0 { errors.invalid = true; return false }
    for choice in choices { if value == choice { return check(errors, field, true) } }
    return check(errors, field, false, "invalid_choice")
}
