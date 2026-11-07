package dagda_http

import "core:encoding/json"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import db "../db"

@(test)
framework_errors_share_bounded_envelopes_and_safe_messages :: proc(t: ^testing.T) {
    arena: virtual.Arena
    testing.expect(t, virtual.arena_init_growing(&arena) == nil)
    defer virtual.arena_destroy(&arena)
    allocator := virtual.arena_allocator(&arena)
    context.allocator = allocator
    context.temp_allocator = allocator
    for kind in Error_Kind {
        probe: JSON_Probe
        c := Context{allocator=allocator, request_id="error-test-id", _reply=json_reply, user_data=&probe}
        testing.expect(t, fail(&c, kind))
        status, code, message := error_info(kind)
        testing.expect_value(t, probe.status, status)
        response: Error_Response
        testing.expect(t, json.unmarshal_string(probe.body, &response, spec=.JSON, allocator=allocator) == nil)
        testing.expect_value(t, response.request_id, "error-test-id")
        testing.expect_value(t, response.error.code, code)
        testing.expect_value(t, response.error.message, message)
        testing.expect(t, !strings.contains(probe.body, `"fields"`))
        if status == 500 { testing.expect_value(t, response.error.message, "Internal server error") }
        testing.expect(t, !fail(&c, kind))
        testing.expect_value(t, probe.replies, 1)
    }
    probe: JSON_Probe
    c := Context{allocator=allocator, request_id="error-test-id", _reply=json_reply, user_data=&probe}
    testing.expect(t, respond_error(&c, 409, "conflict", "Revision conflict"))
    testing.expect_value(t, probe.status, 409)
    c._state = .Open
    testing.expect(t, respond_error(&c, 200, "invalid secret metadata", "DO_NOT_LEAK"))
    testing.expect_value(t, probe.status, 500)
    testing.expect(t, !strings.contains(probe.body, "DO_NOT_LEAK"))
    c._state = .Pending
    testing.expect(t, !fail(&c, .Query_Failed))
    testing.expect_value(t, probe.replies, 2)
}

forward_result :: proc(c: ^Context, status: int, body: string) { json_text(c, status, body) }
@(test)
database_errors_are_normalized_before_default_and_custom_completion :: proc(t: ^testing.T) {
    arena: virtual.Arena
    testing.expect(t, virtual.arena_init_growing(&arena) == nil)
    defer virtual.arena_destroy(&arena)
    allocator := virtual.arena_allocator(&arena)
    context.allocator = allocator
    context.temp_allocator = allocator
    for error in ([]db.Error{.Deadline, .Unavailable, .Unexpected_Result, .Query}) {
        for custom in 0..<2 {
            probe: JSON_Probe
            c := Context{allocator=allocator, request_id="query-test-id", _reply=json_reply, user_data=&probe, _state=.Pending}
            if custom == 1 { c._result = forward_result }
            query_result(&c, 500, "DO_NOT_LEAK_SQL_DETAILS", error)
            response: Error_Response
            testing.expect(t, json.unmarshal_string(probe.body, &response, spec=.JSON, allocator=allocator) == nil)
            status, code, _ := error_info(database_error_kind(error))
            testing.expect_value(t, probe.status, status)
            testing.expect_value(t, response.error.code, code)
            testing.expect_value(t, response.request_id, "query-test-id")
            testing.expect(t, !strings.contains(probe.body, "DO_NOT_LEAK"))
        }
    }
}
