package dagda_http

import "core:mem/virtual"
import "core:testing"

Probe :: struct { order: int, replies, logs, status: int }
record_reply :: proc(c: ^Context, status: int, _: string) {
    p := cast(^Probe)c.user_data
    p.replies += 1
    p.status = status
}
record_log :: proc(record: Access_Record, data: rawptr) {
    p := cast(^Probe)data
    p.logs += 1
    p.status = record.status
}
outer :: proc(c: ^Context, n: ^Next, data: rawptr) {
    p := cast(^Probe)data
    p.order = p.order * 10 + 1
    next(n)
    p.order = p.order * 10 + 5
    next(n) // must not execute a second time
}
inner :: proc(c: ^Context, n: ^Next, data: rawptr) {
    p := cast(^Probe)data
    p.order = p.order * 10 + 2
    next(n)
    p.order = p.order * 10 + 4
}
handler :: proc(c: ^Context) {
    p := cast(^Probe)c.user_data
    p.order = p.order * 10 + 3
    json_text(c, 200, `{}`)
    json_text(c, 500, `{}`) // finalization is idempotent
}
deny :: proc(c: ^Context, _: ^Next, _: rawptr) { json_text(c, 403, `{}`) }
missing_reply :: proc(_: ^Context) {}

@(test)
middleware_order_and_exactly_once_completion :: proc(t: ^testing.T) {
    p: Probe
    c := Context{_reply=record_reply, _logger=record_log, _logger_data=&p}
    globals := [1]Middleware{{outer, &p}}
    locals := [1]Middleware{{inner, &p}}
    dispatch(&c, handler, &p, globals[:], locals[:])
    testing.expect_value(t, p.order, 12345)
    testing.expect_value(t, p.replies, 1)
    testing.expect_value(t, p.logs, 1)
    testing.expect_value(t, p.status, 200)
}

@(test)
short_circuit_and_missing_response :: proc(t: ^testing.T) {
    p: Probe
    c := Context{_reply=record_reply, _logger=record_log, _logger_data=&p}
    middleware := [1]Middleware{{handle=deny}}
    dispatch(&c, handler, &p, middleware[:])
    testing.expect_value(t, p.order, 0)
    testing.expect_value(t, p.status, 403)
    testing.expect_value(t, p.replies, 1)
    c = Context{_reply=record_reply, _logger=record_log, _logger_data=&p}
    dispatch(&c, missing_reply, &p)
    testing.expect_value(t, p.status, 500)
    testing.expect_value(t, p.logs, 2)
}

@(test)
pending_work_cannot_be_prematurely_finalized :: proc(t: ^testing.T) {
    p: Probe
    c := Context{_state=.Pending, _reply=record_reply, user_data=&p}
    testing.expect(t, !json_text(&c, 200, `{}`))
    testing.expect_value(t, p.replies, 0)
}

@(test)
response_headers_reject_protocol_overrides_and_injection :: proc(t: ^testing.T) {
    storage: [4096]byte
    arena: virtual.Arena
    testing.expect(t, virtual.arena_init_buffer(&arena, storage[:]) == nil)
    c := Context{allocator=virtual.arena_allocator(&arena)}
    testing.expect(t, set_header(&c, "x-example", "value"))
    testing.expect(t, !set_header(&c, "content-length", "100"))
    testing.expect(t, !set_header(&c, "Content-Length", "100"))
    testing.expect(t, !set_header(&c, "x-request-id", "spoofed"))
    testing.expect(t, !set_header(&c, "bad header", "value"))
    testing.expect(t, !set_header(&c, "x-example", "value\r\nInjected: true"))
}
