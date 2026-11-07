package dagda_testing

import "core:encoding/json"
import "core:crypto"
import "core:encoding/uuid"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import app "../app"
import http "../http"
import platform "../platform"
import transport "../../vendor/odin-http"

Request :: struct {
    method: http.Method,
    target: string,
    headers: []http.Header,
    body: string,
}
Error :: enum { None, Invalid_App_State, Invalid_Request, Allocation, Database_Not_Supported, Async_Not_Supported }
// All response strings, headers, decoded JSON, and the completion record belong
// to this response until destroy. Do not copy ownership or destroy twice via aliases.
Response :: struct {
    status: int,
    body: string,
    headers: map[string]string,
    completion: http.Access_Record,
    completions: int,
    _arena: ^virtual.Arena,
    _owner: mem.Allocator,
}
destroy :: proc(response: ^Response) {
    if response._arena != nil {
        virtual.arena_destroy(response._arena)
        free(response._arena, response._owner)
    }
    response^ = {}
}
header :: proc(response: ^Response, name: string) -> string {
    if response._arena == nil { return "" }
    key := strings.to_lower(name, virtual.arena_allocator(response._arena))
    return response.headers[key]
}
decode_json :: proc(response: ^Response, destination: ^$T) -> json.Unmarshal_Error {
    if response._arena == nil || destination == nil { return .Invalid_Parameter }
    allocator := virtual.arena_allocator(response._arena)
    context.allocator = allocator
    context.temp_allocator = allocator
    if !http.json_syntax_safe(response.body, bounded_integers=false) { return .Invalid_Data }
    parser := json.make_parser(response.body, spec=.JSON, parse_integers=false, allocator=allocator)
    _, error := json.parse_value(&parser)
    if error != nil || parser.curr_token.kind != .EOF || (parser.curr_token_err != nil && parser.curr_token_err != .EOF) { return .Invalid_Data }
    value: T
    if decode_error := json.unmarshal_string(response.body, &value, spec=.JSON, allocator=allocator); decode_error != nil { return decode_error }
    destination^ = value
    return nil
}

// No listener, lifecycle hooks, workers, or external log sinks are started.
// Use a Configured App and inject ordinary application services through route data.
// Database work and asynchronous handlers are explicit test-client errors.
@(require_results)
request :: proc(application: ^app.App, input: Request, allocator := context.allocator) -> (response: Response, error: Error) {
    if application == nil || application.state != .Configured { return {}, .Invalid_App_State }
    if len(input.target) == 0 || len(input.target) > 8000 || input.target[0] != '/' || len(input.headers) > 64 {
        return {}, .Invalid_Request
    }
    for ch in input.target { if ch <= 32 || ch == 127 || ch == '#' { return {}, .Invalid_Request } }
    storage: virtual.Arena
    if virtual.arena_init_growing(&storage, 64 * 1024) != nil { return {}, .Allocation }
    defer virtual.arena_destroy(&storage)
    request_allocator := virtual.arena_allocator(&storage)
    context.allocator = request_allocator
    context.temp_allocator = request_allocator
    transport_request: transport.Request
    transport.request_init(&transport_request, request_allocator)
    total := 0
    for item in input.headers {
        total += len(item.name) + len(item.value) + 4
        if total > 16 * 1024 { return {}, .Invalid_Request }
        for ch in item.name { if ch == ':' || ch == '\r' || ch == '\n' { return {}, .Invalid_Request } }
        // One caller header must correspond to exactly one HTTP field line.
        for ch in item.value { if ch == '\r' || ch == '\n' { return {}, .Invalid_Request } }
        line := fmt.tprintf("%s: %s", item.name, item.value)
        if _, ok := transport.header_parse(&transport_request.headers, line, request_allocator); !ok { return {}, .Invalid_Request }
    }
    if !transport.headers_has_unsafe(transport_request.headers, "host") {
        transport.headers_set_unsafe(&transport_request.headers, "host", "localhost")
    }
    if !transport.headers_validate_for_server(&transport_request.headers) { return {}, .Invalid_Request }
    if !transport.headers_has_unsafe(transport_request.headers, "content-length") && !transport.headers_has_unsafe(transport_request.headers, "transfer-encoding") {
        transport.headers_set_unsafe(&transport_request.headers, "content-length", fmt.tprintf("%d", len(input.body)))
    }
    transport_request.headers.readonly = true
    transport_request.url = transport.url_parse(strings.clone(input.target, request_allocator))
    response._owner = allocator
    response._arena = new(virtual.Arena, allocator)
    if response._arena == nil { return {}, .Allocation }
    if virtual.arena_init_growing(response._arena, 64 * 1024) != nil {
        free(response._arena, allocator)
        return {}, .Allocation
    }
    response.headers = make(map[string]string, virtual.arena_allocator(response._arena))
    context.random_generator = crypto.random_generator()
    now := platform.monotonic_ms()
    c := http.Context{
        method=input.method, path=transport_request.url.path, route="<unmatched>",
        request_id=uuid.to_string(uuid.generate_v4(), request_allocator), started_ms=now,
        allocator=request_allocator, _request=&transport_request,
        _method_known=true, _defer_log=true, _reply=capture_response, _reply_data=&response,
        _logger=capture_completion, _logger_data=&response,
    }
    size, ok := app.request_body_length(&c)
    if ok {
        if size != len(input.body) { destroy(&response); return {}, .Invalid_Request }
        c.body = strings.clone(input.body, request_allocator)
        app.dispatch_request(application, &c)
    }
    if c._query_attempted { destroy(&response); return {}, .Database_Not_Supported }
    if c._state != .Responded { destroy(&response); return {}, .Async_Not_Supported }
    http.log_completed(&c, response.status, "response")
    return response, .None
}

capture_response :: proc(c: ^http.Context, status: int, body: string) {
    response := cast(^Response)c._reply_data
    allocator := virtual.arena_allocator(response._arena)
    payload, headers := http.response_parts(c, status, body)
    response.status = status
    response.body = strings.clone(payload, allocator)
    for item in headers {
        // Response metadata may override content-type; keep one owned key/value.
        if old, found := response.headers[item.name]; found {
            _ = old // arena reclaims the previous value on response destruction
            response.headers[item.name] = strings.clone(item.value, allocator)
        } else { response.headers[strings.clone(item.name, allocator)] = strings.clone(item.value, allocator) }
    }
}
capture_completion :: proc(record: http.Access_Record, data: rawptr) {
    response := cast(^Response)data
    allocator := virtual.arena_allocator(response._arena)
    response.completions += 1
    response.completion = record
    response.completion.request_id = strings.clone(record.request_id, allocator)
    response.completion.method = strings.clone(record.method, allocator)
    response.completion.route = strings.clone(record.route, allocator)
    response.completion.outcome = strings.clone(record.outcome, allocator)
}
