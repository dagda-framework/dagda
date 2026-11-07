package dagda_app

import "core:encoding/json"
import "core:encoding/uuid"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:nbio"
import "core:strings"
import "core:strconv"
import "core:time"
import config "../config"
import db "../db"
import http "../http"
import platform "../platform"
import routes "../routes"
import runtime "../runtime"
import transport "../../vendor/odin-http"

State :: enum { Uninitialized, Configured, Starting, Running, Draining, Stopped, Failed }
Error :: enum { None, Invalid_State, Signals, Event_Loop, Database, Workers, Startup_Hook, Listen, Transport }
Hooks :: struct {
    start: proc(data: rawptr) -> bool,
    stop: proc(data: rawptr),
    data: rawptr,
}
App :: struct {
    state: State,
    config: config.Config, // borrowed; destroy the original config after destroy(App)
    hooks: Hooks,
    router: routes.Router,
    middleware: [dynamic]http.Middleware,
    logger: http.Access_Logger,
    logger_data: rawptr,
    _server: transport.Server,
    _pool: runtime.Pool,
    _allocator: mem.Allocator,
}

init :: proc(a: ^App, settings: config.Config, allocator := context.allocator) {
    assert(a.state == .Uninitialized)
    a.config = settings
    a._allocator = allocator
    a.middleware.allocator = allocator
    routes.init(&a.router, allocator)
    a.state = .Configured
    if settings.access_log { a.logger = http.stdout_access_log }
    assert(route(a, .Get, "/health/live", liveness) == .None)
    assert(route(a, .Get, "/health/ready", readiness, a) == .None)
}
destroy :: proc(a: ^App) {
    assert(a.state != .Starting && a.state != .Running && a.state != .Draining)
    routes.destroy(&a.router)
    delete(a.middleware)
    a^ = {}
}
route :: proc(a: ^App, method: http.Method, pattern: string, handler: http.Handler,
              data: rawptr = nil, middleware: []http.Middleware = nil) -> routes.Error {
    if a.state != .Configured { return .Frozen }
    return routes.add(&a.router, method, pattern, handler, data, middleware)
}
use :: proc(a: ^App, middleware: http.Middleware) -> bool {
    if a.state != .Configured || middleware.handle == nil || len(a.middleware) >= 16 { return false }
    append(&a.middleware, middleware)
    return true
}

// All lifecycle calls are on the main HTTP thread. Shutdown is cooperative:
// already-admitted DB operations retain their original deadlines and ownership.
request_stop :: proc(a: ^App) {
    if a.state == .Running { a.state = .Draining }
}
run :: proc(a: ^App) -> (error: Error) {
    if a.state != .Configured { return .Invalid_State }
    a.state = .Starting
    a.router.frozen = true
    defer {
        a.state = .Stopped if error == .None else .Failed
        event("stopped" if error == .None else "startup_or_runtime_failed", fmt.tprintf("%v", error))
    }
    context.logger = log.create_console_logger(a.config.log_level)
    if platform.install_signals() != 0 { return .Signals }
    if nbio.acquire_thread_event_loop() != nil { return .Event_Loop }
    defer nbio.release_thread_event_loop()

    // Startup can block; request handling never performs this check on the loop.
    deadline := platform.monotonic_ms() + a.config.deadline_ms
    connection, db_error := db.connect(a.config.database_url, deadline)
    if db_error != .None { return .Database }
    _, query_error := db.query_text(&connection, "SELECT 'ready'", nil, deadline, context.temp_allocator)
    db.close(&connection)
    if query_error != .None { return .Database }
    if !runtime.start(&a._pool, a.config.database_url) { return .Workers }
    hook_entered := false
    defer {
        runtime.stop(&a._pool)
        if hook_entered && a.hooks.stop != nil { a.hooks.stop(a.hooks.data) }
    }
    if a.hooks.start != nil {
        hook_entered = true
        if !a.hooks.start(a.hooks.data) { return .Startup_Hook }
    } else { hook_entered = true }
    opts := transport.Default_Server_Opts
    opts.thread_count = 1
    opts.limit_headers = 16 * 1024
    opts.max_connections = a.config.max_connections
    opts.read_timeout = time.Duration(a.config.read_timeout_ms) * time.Millisecond
    opts.write_timeout = time.Duration(a.config.write_timeout_ms) * time.Millisecond
    opts.auto_expect_continue = false
    opts.redirect_head_to_get = false
    if transport.listen(&a._server, a.config.endpoint, opts) != nil { return .Listen }
    a.state = .Running
    event("listening", a.config.listen)
    nbio.timeout_poly(25 * time.Millisecond, a, control)
    if transport.serve(&a._server, transport.Handler{user_data = a, handle = handle, started = started, completed = completed}) != nil { return .Transport }
    assert(runtime.active(&a._pool) == 0)
    return .None
}

control :: proc(_: ^nbio.Operation, a: ^App) {
    if platform.stop_requested() != 0 { request_stop(a) }
    if a.state == .Draining {
        event("draining", "")
        transport.server_shutdown(&a._server)
        return
    }
    nbio.timeout_poly(25 * time.Millisecond, a, control)
}
event :: proc(name, detail: string) {
    value := struct {event, detail: string}{name, detail}
    bytes, error := json.marshal(value, allocator=context.temp_allocator)
    if error == nil { fmt.eprintln(string(bytes)) }
}

started :: proc(handler: ^transport.Handler, request: ^transport.Request, response: ^transport.Response) {
    a := cast(^App)handler.user_data
    allocator := virtual.arena_allocator(&response._conn.temp_allocator)
    context.allocator = allocator
    context.temp_allocator = allocator
    c := new(http.Context, allocator)
    c.route = "<unparsed>"
    c.request_id = uuid.to_string(uuid.generate_v4(), allocator)
    c.started_ms = platform.monotonic_ms()
    c.deadline_ms = c.started_ms + a.config.deadline_ms
    c.allocator = allocator
    c._request = request
    c._response = response
    c._pool = &a._pool
    c._reply = http.write_response
    c._logger = a.logger
    c._logger_data = a.logger_data
    c._defer_log = true
    response.user_data = c
    transport.headers_set_unsafe(&response.headers, "x-request-id", c.request_id)
}
completed :: proc(_: ^transport.Handler, request: ^transport.Request, response: ^transport.Response, send_failed: bool) {
    c := cast(^http.Context)response.user_data
    if c == nil { return }
    context.temp_allocator = c.allocator
    if line, ok := request.line.(transport.Requestline); ok { c.method = line.method; c._method_known = true }
    status := int(response.status) if response.sent else 0
    outcome := "write_failed" if send_failed else ("response" if response.sent else "connection_closed")
    http.log_completed(c, status, outcome)
}

handle :: proc(handler: ^transport.Handler, request: ^transport.Request, response: ^transport.Response) {
    a := cast(^App)handler.user_data
    c := cast(^http.Context)response.user_data
    allocator := c.allocator
    context.allocator = allocator
    context.temp_allocator = allocator
    c.method = request.line.(transport.Requestline).method
    c._method_known = true
    c.deadline_ms = platform.monotonic_ms() + a.config.deadline_ms
    c.path = request.url.path
    c.route = "<unmatched>"
    if a.state != .Running {
        http.fail(c, .Draining)
        return
    }
    size, ok := request_body_length(c)
    if !ok { return }
    if size > 0 {
        transport.body(request, http.MAX_JSON_BYTES, c, body_ready)
        return
    }
    dispatch_request(a, c)
}

// Shared by the network adapter and the in-process application test client.
// The transport parser remains responsible for HTTP framing/header syntax.
request_body_length :: proc(c: ^http.Context) -> (int, bool) {
    if transport.headers_has_unsafe(c._request.headers, "transfer-encoding") {
        http.fail(c, .Body_Not_Supported)
        return 0, false
    }
    if transport.headers_has_unsafe(c._request.headers, "expect") {
        http.fail(c, .Expectation_Failed)
        return 0, false
    }
    if transport.headers_has_unsafe(c._request.headers, "content-encoding") {
        http.fail(c, .Unsupported_Content_Encoding)
        return 0, false
    }
    if length, present := transport.headers_get_unsafe(c._request.headers, "content-length"); present {
        digits := len(length) > 0
        for ch in length { if ch < '0' || ch > '9' { digits = false; break } }
        if !digits { http.fail(c, .Invalid_Content_Length); return 0, false }
        size, ok := strconv.parse_u64(length)
        if !ok { http.fail(c, .Invalid_Content_Length); return 0, false }
        if size > http.MAX_JSON_BYTES { http.fail(c, .Body_Too_Large); return 0, false }
        return int(size), true
    }
    return 0, true
}
body_ready :: proc(data: rawptr, body: transport.Body, error: transport.Body_Error) {
    c := cast(^http.Context)data
    context.allocator = c.allocator
    context.temp_allocator = c.allocator
    if error != nil {
        http.fail(c, .Incomplete_Body)
        return
    }
    // The scanner's buffer can move; retain a request-owned copy for async handlers.
    c.body = strings.clone(body, c.allocator)
    a := cast(^App)c._response._conn.server.handler.user_data
    if a.state != .Running { http.fail(c, .Draining); return }
    dispatch_request(a, c)
}
dispatch_request :: proc(a: ^App, c: ^http.Context) {
    allocator := c.allocator
    c.deadline_ms = platform.monotonic_ms() + a.config.deadline_ms
    match := routes.match(&a.router, c.method, c.path, allocator)
    if match.route != nil { c.route = match.route.pattern }
    switch match.state {
    case .Bad_Path: http.dispatch(c, bad_path, global_middleware=a.middleware[:])
    case .Not_Found: http.dispatch(c, not_found, global_middleware=a.middleware[:])
    case .Method_Not_Allowed:
        allowed: strings.Builder
        strings.builder_init(&allowed, allocator)
        for method in http.Method {
            if method in match.allow {
                if len(strings.to_string(allowed)) > 0 { strings.write_string(&allowed, ", ") }
                strings.write_string(&allowed, transport.method_string(method))
            }
        }
        http.set_header(c, "allow", strings.to_string(allowed))
        http.dispatch(c, method_not_allowed, global_middleware=a.middleware[:])
    case .Found:
        c.params = make([]http.Param, match.count, allocator)
        copy(c.params, match.params[:match.count])
        http.dispatch(c, match.route.handler, match.route.data, a.middleware[:], match.route.middleware)
    }
}
liveness :: proc(c: ^http.Context) { http.json_text(c, 200, `{"status":"ok"}`) }
readiness :: proc(c: ^http.Context) {
    a := cast(^App)c.user_data
    if a.state != .Running { http.fail(c, .Not_Ready); return }
    http.query_text(c, "SELECT 'ready'", result=ready_result)
}
ready_result :: proc(c: ^http.Context, status: int, _: string) {
    if status == 200 { http.json_text(c, 200, `{"status":"ready"}`) }
    else { http.fail(c, .Not_Ready) }
}
not_found :: proc(c: ^http.Context) { http.fail(c, .Not_Found) }
method_not_allowed :: proc(c: ^http.Context) { http.fail(c, .Method_Not_Allowed) }
bad_path :: proc(c: ^http.Context) { http.fail(c, .Invalid_Path) }
