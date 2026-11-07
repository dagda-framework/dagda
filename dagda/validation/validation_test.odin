package dagda_validation

import "core:fmt"
import "core:math"
import "core:testing"

@(test)
text_required_and_unicode_length :: proc(t: ^testing.T) {
    errors: Errors
    testing.expect(t, valid(&errors))
    testing.expect(t, !required_text(&errors, "title", " \t\n\u2003"))
    testing.expect_value(t, error_code(&errors.items[0]), "required")
    testing.expect(t, required_text(&errors, "title", "  Odin  "))
    testing.expect(t, text_length(&errors, "name", "☘é", 2, 2))
    testing.expect(t, !text_length(&errors, "name", "☘é", 3, 4))
    testing.expect(t, !text_length(&errors, "name", "☘é", 0, 1))
    testing.expect(t, !text_length(&errors, "bytes", "\xff", 0, 2))
    testing.expect_value(t, errors.count, 4)
    testing.expect_value(t, error_code(&errors.items[1]), "too_short")
    testing.expect_value(t, error_code(&errors.items[2]), "too_long")
    testing.expect(t, !valid(&errors))
}

@(test)
ranges_choices_and_custom_rules :: proc(t: ^testing.T) {
    errors: Errors
    testing.expect(t, integer_range(&errors, "quantity", 1, 1, 100))
    testing.expect(t, integer_range(&errors, "quantity", 100, 1, 100))
    testing.expect(t, !integer_range(&errors, "quantity", 0, 1, 100))
    testing.expect(t, !integer_range(&errors, "quantity", 101, 1, 100))
    testing.expect_value(t, errors.count, 1) // duplicate code is suppressed
    testing.expect(t, number_range(&errors, "amount", 1.5, 1, 2))
    testing.expect(t, !number_range(&errors, "amount", math.inf_f64(1), 1, 2))
    testing.expect(t, !number_range(&errors, "amount", math.nan_f64(), 1, 2))
    testing.expect(t, one_of(&errors, "priority", "normal", {"low", "normal"}))
    testing.expect(t, !one_of(&errors, "priority", "Normal", {"low", "normal"}))
    testing.expect(t, !check(&errors, "items[0].sku", false, "unavailable"))
    testing.expect_value(t, field_name(&errors.items[3]), "items[0].sku")
    testing.expect_value(t, error_code(&errors.items[3]), "unavailable")
}

@(test)
bounded_owned_errors_and_deduplication :: proc(t: ^testing.T) {
    errors: Errors
    field := [5]byte{'t', 'i', 't', 'l', 'e'}
    code := [8]byte{'r', 'e', 'q', 'u', 'i', 'r', 'e', 'd'}
    add(&errors, string(field[:]), string(code[:]))
    field[0] = 'X'
    code[0] = 'X'
    testing.expect_value(t, field_name(&errors.items[0]), "title")
    testing.expect_value(t, error_code(&errors.items[0]), "required")
    for i in 1..<MAX_ERRORS { add(&errors, fmt.tprintf("field_%d", i), "invalid") }
    testing.expect_value(t, errors.count, MAX_ERRORS)
    testing.expect(t, !errors.truncated)
    add(&errors, "title", "required")
    testing.expect(t, !errors.truncated)
    add(&errors, "extra", "invalid")
    testing.expect(t, errors.truncated)
    testing.expect_value(t, errors.count, MAX_ERRORS)
    testing.expect(t, !valid(&errors))
    copied := errors
    errors = {}
    testing.expect_value(t, field_name(&copied.items[0]), "title")
}

@(test)
invalid_rules_fail_closed :: proc(t: ^testing.T) {
    errors: Errors
    testing.expect(t, !integer_range(&errors, "number", 0, 2, 1))
    testing.expect(t, errors.invalid && !valid(&errors))
    errors = {}
    testing.expect(t, !number_range(&errors, "number", 0, 0, math.inf_f64(1)))
    testing.expect(t, errors.invalid)
    errors = {}
    testing.expect(t, !text_length(&errors, "title", "a", -1, 10))
    testing.expect(t, errors.invalid)
    errors = {}
    testing.expect(t, !one_of(&errors, "priority", "a", nil))
    testing.expect(t, errors.invalid)
    errors = {}
    add(&errors, "DO NOT ECHO", "invalid")
    testing.expect(t, errors.invalid && errors.count == 0)
    errors = {}
    testing.expect(t, !check(&errors, "title", true, "not a code"))
    testing.expect(t, errors.invalid)
    testing.expect(t, !valid(nil))
}
