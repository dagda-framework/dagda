package dagda_http

import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import validation "../validation"
import transport "../../vendor/odin-http"

@(test)
validation_response_groups_codes_and_includes_request_id :: proc(t: ^testing.T) {
    arena: virtual.Arena
    testing.expect(t, virtual.arena_init_growing(&arena) == nil)
    defer virtual.arena_destroy(&arena)
    allocator := virtual.arena_allocator(&arena)
    context.allocator = allocator
    context.temp_allocator = allocator
    probe: JSON_Probe
    c := Context{allocator=allocator, _reply=json_reply, user_data=&probe, request_id="test-request-id"}
    errors: validation.Errors
    testing.expect(t, validate(&c, &errors))
    testing.expect_value(t, probe.replies, 0)
    validation.add(&errors, "title", "required")
    validation.add(&errors, "title", "too_short")
    validation.add(&errors, "title", "required")
    validation.add(&errors, "quantity", "out_of_range")
    testing.expect(t, !validate(&c, &errors))
    testing.expect_value(t, probe.status, 422)
    response: Validation_Response
    testing.expect(t, json.unmarshal_string(probe.body, &response, spec=.JSON, allocator=allocator) == nil)
    testing.expect_value(t, response.request_id, "test-request-id")
    testing.expect_value(t, response.error.code, "validation_failed")
    testing.expect_value(t, response.error.message, "Request validation failed")
    testing.expect_value(t, len(response.error.fields), 2)
    testing.expect_value(t, len(response.error.fields["title"]), 2)
    testing.expect_value(t, response.error.fields["title"][0], "required")
    testing.expect_value(t, response.error.fields["title"][1], "too_short")
    testing.expect(t, !strings.contains(probe.body, "truncated"))
    testing.expect(t, !validate(&c, &errors))
    testing.expect_value(t, probe.replies, 1)
}

@(test)
validation_errors_remain_bounded_and_respect_pending_ownership :: proc(t: ^testing.T) {
    arena: virtual.Arena
    testing.expect(t, virtual.arena_init_growing(&arena) == nil)
    defer virtual.arena_destroy(&arena)
    allocator := virtual.arena_allocator(&arena)
    context.allocator = allocator
    context.temp_allocator = allocator
    probe: JSON_Probe
    c := Context{allocator=allocator, _reply=json_reply, user_data=&probe, request_id="test-id"}
    errors: validation.Errors
    for i in 0..<validation.MAX_ERRORS+1 {
        validation.add(&errors, fmt.tprintf("field_%d", i), "invalid")
    }
    c._state = .Pending
    testing.expect(t, !validate(&c, &errors))
    testing.expect_value(t, probe.replies, 0)
    c._state = .Open
    testing.expect(t, !validate(&c, &errors))
    testing.expect_value(t, probe.status, 422)
    testing.expect(t, strings.contains(probe.body, `"truncated":true`))
    testing.expect(t, len(probe.body) < MAX_JSON_BYTES)
    c._state = .Open
    errors = {}
    validation.add(&errors, "value must never leak", "invalid")
    testing.expect(t, !validate(&c, &errors))
    testing.expect_value(t, probe.status, 500)
    testing.expect(t, !strings.contains(probe.body, "value must never leak"))
    testing.expect(t, strings.contains(probe.body, `"request_id":"test-id"`))
}

@(test)
json_field_presence_distinguishes_missing_null_and_false :: proc(t: ^testing.T) {
    arena: virtual.Arena
    testing.expect(t, virtual.arena_init_growing(&arena) == nil)
    defer virtual.arena_destroy(&arena)
    allocator := virtual.arena_allocator(&arena)
    context.allocator = allocator
    context.temp_allocator = allocator
    request: transport.Request
    transport.request_init(&request, allocator)
    transport.headers_set_unsafe(&request.headers, "content-type", "application/json")
    Input :: struct { enabled: bool, note: union {string}, name: string `json:"wire_name"` }
    c := Context{allocator=allocator, _request=&request, body=`{"enabled":false,"note":null,"wire_name":""}`}
    testing.expect_value(t, json_field_state(&c, "enabled"), .Unavailable)
    input: Input
    testing.expect(t, decode_json(&c, &input))
    testing.expect_value(t, json_field_state(&c, "enabled"), .Value)
    testing.expect_value(t, json_field_state(&c, "note"), .Null)
    testing.expect_value(t, json_field_state(&c, "wire_name"), .Value)
    testing.expect_value(t, json_field_state(&c, "name"), .Missing)
    testing.expect_value(t, json_field_state(&c, "missing"), .Missing)
    errors: validation.Errors
    testing.expect(t, validation.required(&errors, "enabled", json_field_state(&c, "enabled") == .Value))
    testing.expect(t, !input.enabled)
}
