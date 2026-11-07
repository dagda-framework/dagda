package dagda_http

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:nbio"
import "core:strings"
import transport "../../vendor/odin-http"
import runtime "../runtime"
import platform "../platform"

Method :: transport.Method
Handler :: proc(request: ^Context)
Middleware :: struct {
    handle: proc(request: ^Context, next: ^Next, data: rawptr),
    data: rawptr,
}
Param :: struct { name, value: string }
Header :: struct { name, value: string }
State :: enum { Open, Pending, Responded }
Access_Record :: struct {
    event: string,
    request_id: string,
    method: string,
    route: string,
    status: int,
    duration_ms: i64,
    outcome: string,
}
Access_Logger :: proc(record: Access_Record, data: rawptr)
Result_Handler :: proc(request: ^Context, status: int, body: string)
Reply_Proc :: proc(request: ^Context, status: int, body: string)

// Context and all returned strings live only until response completion. Handlers
// and middleware execute on the HTTP loop; query_text copies work into its slot.
Context :: struct {
    method: Method,
    path, route, request_id: string,
    body: string, // bounded, request-owned bytes; populated before dispatch
    _json_decoded: bool,
    _json_object: json.Object,
    _json_object_ready: bool,
    params: []Param,
    deadline_ms, started_ms: i64,
    allocator: mem.Allocator,
    user_data: rawptr,
    response_headers: [dynamic]Header,
    _state: State,
    _method_known, _defer_log, _logged: bool,
    _request: ^transport.Request,
    _response: ^transport.Response,
    _pool: ^runtime.Pool,
    _handler: Handler,
    _global, _local: []Middleware,
    _reply: Reply_Proc,
    _logger: Access_Logger,
    _logger_data: rawptr,
    _result: Result_Handler,
}
Next :: struct { _request: ^Context, _index: int, _used: bool }

param :: proc(c: ^Context, name: string) -> (value: string, found: bool) {
    for entry in c.params { if entry.name == name { return entry.value, true } }
    return
}
query :: proc(c: ^Context, name: string) -> (value: string, found: bool) {
    if c._request == nil { return }
    return transport.query_get(c._request.url, name)
}
header :: proc(c: ^Context, name: string) -> (value: string, found: bool) {
    if c._request == nil { return }
    return transport.headers_get_unsafe(c._request.headers, strings.to_lower(name, c.allocator))
}

set_header :: proc(c: ^Context, name, value: string) -> bool {
    if c._state != .Open || len(name) == 0 || len(name) > 128 || len(value) > 1024 { return false }
    name := strings.to_lower(name, c.allocator)
    for ch in name {
        if !(('a' <= ch && ch <= 'z') || ('0' <= ch && ch <= '9') || ch == '-') { return false }
    }
    if name == "content-length" || name == "connection" || name == "transfer-encoding" || name == "x-request-id" { return false }
    for ch in value { if ch < 32 || ch == 127 { return false } }
    for &entry in c.response_headers {
        if entry.name == name { entry.value = strings.clone(value, c.allocator); return true }
    }
    if len(c.response_headers) >= 16 { return false }
    if c.response_headers.allocator.procedure == nil { c.response_headers.allocator = c.allocator }
    append(&c.response_headers, Header{strings.clone(name, c.allocator), strings.clone(value, c.allocator)})
    return true
}

// Raw, already-encoded JSON is the M1 step-1/2 response API. Typed encoding and
// request body decoding are separate work. Responses are capped at 8 KiB.
json_text :: proc(c: ^Context, status: int, body: string) -> bool {
    status, body := status, body
    if c._state != .Open { return false }
    if status < 200 || status > 599 || len(body) > 8192 {
        status = 500
        body = `{"error":{"code":"invalid_response"}}`
    }
    c._state = .Responded
    if !c._defer_log { log_completed(c, status, "response") }
    if c._reply != nil { c._reply(c, status, body) }
    return true
}

log_completed :: proc(c: ^Context, status: int, outcome: string) {
    if c._logged { return }
    c._logged = true
    if c._logger == nil { return }
    method := transport.method_string(c.method) if c._method_known else "-"
    c._logger(Access_Record{"access", c.request_id, method, c.route, status,
                           max(0, platform.monotonic_ms() - c.started_ms), outcome}, c._logger_data)
}

stdout_access_log :: proc(record: Access_Record, _: rawptr) {
    bytes, error := json.marshal(record, allocator=context.temp_allocator)
    if error == nil { fmt.println(string(bytes)) }
}

// Next is synchronous and stack-owned. Do not retain it or call it from a worker.
next :: proc(n: ^Next) -> bool {
    if n == nil || n._used || n._request._state != .Open { return false }
    n._used = true
    invoke(n._request, n._index)
    return true
}
invoke :: proc(c: ^Context, index: int) {
    if c._state != .Open { return }
    if index < len(c._global) + len(c._local) {
        middleware := c._global[index] if index < len(c._global) else c._local[index - len(c._global)]
        continuation := Next{_request = c, _index = index + 1}
        middleware.handle(c, &continuation, middleware.data)
    } else {
        c._handler(c)
    }
}
dispatch :: proc(c: ^Context, handler: Handler, data: rawptr = nil,
                 global_middleware: []Middleware = nil, route_middleware: []Middleware = nil) {
    c._handler = handler
    c.user_data = data
    c._global = global_middleware
    c._local = route_middleware
    invoke(c, 0)
    if c._state == .Open { json_text(c, 500, `{"error":{"code":"handler_did_not_respond"}}`) }
}

// Copies SQL and parameters before returning. No transport or caller-owned
// string reaches a worker. At most one database operation is pending per request.
query_text :: proc(c: ^Context, sql: cstring, parameters: []cstring = nil, result: Result_Handler = nil) -> bool {
    if c._state != .Open { return false }
    work := runtime.Work{query = sql, parameters = parameters, deadline_ms = c.deadline_ms}
    if !runtime.valid_work(work) || c._pool == nil {
        return json_text(c, 500, `{"error":{"code":"invalid_database_work"}}`)
    }
    slot := runtime.reserve(c._pool, work)
    if slot == nil {
        set_header(c, "retry-after", "1")
        return json_text(c, 503, `{"error":{"code":"overloaded"}}`)
    }
    c._state = .Pending
    c._result = result
    completion := nbio.prep_timeout(0, complete)
    completion.user_data[0] = c
    completion.user_data[1] = slot
    slot.completion = completion
    slot.transport_data = c
    runtime.submit(c._pool, slot)
    return true
}
complete :: proc(op: ^nbio.Operation) {
    c := cast(^Context)op.user_data[0]
    slot := cast(^runtime.Slot)op.user_data[1]
    context.allocator = c.allocator
    context.temp_allocator = c.allocator
    status := slot.status
    body := strings.clone(slot.body, c.allocator)
    runtime.release(c._pool, slot)
    c._state = .Open
    result := c._result
    c._result = nil
    if result != nil { result(c, status, body) } else { json_text(c, status, body) }
    if c._state == .Open { json_text(c, 500, `{"error":{"code":"handler_did_not_respond"}}`) }
}

write_response :: proc(c: ^Context, status: int, body: string) {
    body := body
    response := c._response
    response.status = transport.Status(status)
    transport.headers_set_close(&response.headers)
    transport.headers_set_content_type(&response.headers, "application/json")
    transport.headers_set_unsafe(&response.headers, "x-request-id", c.request_id)
    for entry in c.response_headers { transport.headers_set_unsafe(&response.headers, entry.name, entry.value) }
    // HEAD is explicit in the router and never sends response payload bytes.
    if c.method == .Head && status != 204 && status != 304 {
        transport.headers_set_unsafe(&response.headers, "content-length", fmt.tprintf("%d", len(body)))
    }
    if c.method == .Head || status == 204 || status == 304 { body = "" }
    transport.body_set(response, body)
    transport.respond(response)
}
