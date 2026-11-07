package main

import "core:fmt"
import "core:log"
import "core:mem/virtual"
import "core:nbio"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import http "../../vendor/odin-http"
import runtime "../../dagda/runtime"
import platform "../../dagda/platform"
import db "../../dagda/db"

App :: struct {
    server: http.Server,
    pool: runtime.Pool,
    draining: bool,
    test_routes: bool,
    deadline_ms: i64,
}

main :: proc() {
    os.exit(run())
}

run :: proc() -> int {
    context.logger = log.create_console_logger(.Warning)
    conninfo := os.get_env("DAGDA_DATABASE_URL", context.allocator)
    defer delete(conninfo)
    if conninfo == "" {
        fmt.eprintln("DAGDA_DATABASE_URL is required. See docs/M0.md.")
        os.exit(1)
    }
    conninfo_c := strings.clone_to_cstring(conninfo, context.allocator)
    defer delete(conninfo_c)
    if !db.valid_local_conninfo(conninfo_c) {
        fmt.eprintln("M0 requires one absolute Unix socket directory or hostaddr=127.0.0.1 / ::1; service lookup is unsupported.")
        os.exit(1)
    }
    target_variables := []string{"PGSERVICE", "PGHOST", "PGHOSTADDR"}
    for variable in target_variables {
        if os.get_env(variable, context.temp_allocator) != "" {
            fmt.eprintln("M0 requires explicit connection settings; unset", variable)
            os.exit(1)
        }
    }
    listen := os.get_env("DAGDA_LISTEN", context.temp_allocator)
    if listen == "" { listen = "127.0.0.1:8080" }
    endpoint, ok := net.parse_endpoint(listen)
    if !ok { fmt.eprintln("Invalid DAGDA_LISTEN"); os.exit(1) }
    app := new(App)
    defer free(app)
    app.deadline_ms = 2000
    deadline := os.get_env("DAGDA_DEADLINE_MS", context.temp_allocator)
    if deadline != "" {
        value, valid := strconv.parse_i64(deadline)
        if !valid || value < 50 || value > 30000 { fmt.eprintln("Invalid DAGDA_DEADLINE_MS (50..30000)"); os.exit(1) }
        app.deadline_ms = value
    }
    app.test_routes = os.get_env("DAGDA_TEST_ROUTES", context.temp_allocator) == "1"
    if platform.install_signals() != 0 { fmt.eprintln("Could not install signal handlers"); os.exit(1) }
    if err := nbio.acquire_thread_event_loop(); err != nil {
        fmt.eprintf("Could not initialize the HTTP event loop (OS error %d). Check io_uring support and permissions.\n", i32(err))
        return 1
    }
    defer nbio.release_thread_event_loop()
    if !runtime.start(&app.pool, conninfo_c) { fmt.eprintln("Could not start workers"); os.exit(1) }
    defer runtime.stop(&app.pool)
    opts := http.Default_Server_Opts
    opts.thread_count = 1 // Each response returns to this sole owning event loop.
    opts.limit_headers = 16 * 1024
    opts.max_connections = 64
    opts.read_timeout = 2 * time.Second
    opts.write_timeout = time.Second
    opts.auto_expect_continue = false
    opts.redirect_head_to_get = false
    if err := http.listen(&app.server, endpoint, opts); err != nil {
        fmt.eprintln("Could not listen:", err)
        return 1
    }
    nbio.timeout_poly(25 * time.Millisecond, app, control)
    fmt.printf("Dagda M0 listening on %s (workers=%d, capacity=%d)\n", listen, runtime.WORKERS, runtime.CAPACITY)
    handler := http.Handler{user_data = app, handle = handle}
    if err := http.serve(&app.server, handler); err != nil { fmt.eprintln("HTTP server failed:", err); return 1 }
    assert(runtime.active(&app.pool) == 0)
    fmt.println("Dagda M0 drained")
    return 0
}

control :: proc(_: ^nbio.Operation, app: ^App) {
    if platform.stop_requested() != 0 { app.draining = true }
    if app.draining {
        http.server_shutdown(&app.server)
        return
    }
    nbio.timeout_poly(25 * time.Millisecond, app, control)
}

reply :: proc(response: ^http.Response, status: int, body: string) {
    // M0 deliberately closes each connection; keep-alive is a later gate.
    response.status = http.Status(status)
    http.headers_set_close(&response.headers)
    http.headers_set_content_type(&response.headers, "application/json")
    http.body_set(response, body) // Copies bytes into the connection's arena.
    http.respond(response)
}

pool_state_json :: proc(inflight, capacity: int) -> string {
    return fmt.tprintf(`{{"inflight":%d,"capacity":%d}}`, inflight, capacity)
}

handle :: proc(handler: ^http.Handler, request: ^http.Request, response: ^http.Response) {
    app := cast(^App)handler.user_data
    // No body-consuming routes in M0. Do not dispatch work for unread bodies.
    if http.headers_has_unsafe(request.headers, "transfer-encoding") {
        reply(response, 400, `{"error":{"code":"body_not_supported"}}`)
        return
    }
    if length, exists := http.headers_get_unsafe(request.headers, "content-length"); exists && length != "0" {
        reply(response, 400, `{"error":{"code":"body_not_supported"}}`)
        return
    }
    if app.draining {
        reply(response, 503, `{"error":{"code":"draining"}}`)
        return
    }
    if request.line.(http.Requestline).method != .Get {
        reply(response, 405, `{"error":{"code":"method_not_allowed"}}`)
        return
    }
    if request.url.path == "/health/live" {
        reply(response, 200, `{"status":"ok"}`)
        return
    }
    if app.test_routes && request.url.path == "/_test/state" {
        reply(response, 200, pool_state_json(runtime.active(&app.pool), runtime.CAPACITY))
        return
    }
    work := runtime.Work{query = "SELECT row_to_json(item)::text FROM (SELECT id, name FROM dagda_m0_items WHERE id = $1::bigint) item", deadline_ms = platform.monotonic_ms() + app.deadline_ms}
    argument: i64 = 1
    switch request.url.path {
    case "/items":
        id, exists := http.query_get(request.url, "id")
        if exists {
            parsed, valid := strconv.parse_i64(id)
            if !valid || parsed <= 0 { reply(response, 400, `{"error":{"code":"invalid_id"}}`); return }
            argument = parsed
        }
    case "/_test/slow":
        if !app.test_routes { reply(response, 404, `{"error":{"code":"not_found"}}`); return }
        raw, _ := http.query_get(request.url, "ms")
        ms, valid := strconv.parse_i64(raw)
        if !valid || ms < 0 || ms > 10000 { reply(response, 400, `{"error":{"code":"invalid_delay"}}`); return }
        work.query = "SELECT json_build_object('slept_ms', $1::int)::text FROM pg_sleep($1::double precision / 1000.0)"
        argument = ms
    case "/_test/query-error":
        if !app.test_routes { reply(response, 404, `{"error":{"code":"not_found"}}`); return }
        work.query = "SELECT ($1::int / 0)::text"
    case:
        reply(response, 404, `{"error":{"code":"not_found"}}`)
        return
    }
    value := strings.clone_to_cstring(fmt.tprintf("%d", argument), context.temp_allocator)
    parameters := make([]cstring, 1, context.temp_allocator)
    parameters[0] = value
    work.parameters = parameters
    slot := runtime.reserve(&app.pool, work)
    if slot == nil {
        http.headers_set_unsafe(&response.headers, "retry-after", "1")
        reply(response, 503, `{"error":{"code":"overloaded"}}`)
        return
    }
    completion := nbio.prep_timeout(0, complete)
    completion.user_data[0] = app
    completion.user_data[1] = slot
    slot.completion = completion
    slot.transport_data = response
    runtime.submit(&app.pool, slot)
}

complete :: proc(operation: ^nbio.Operation) {
    app := cast(^App)operation.user_data[0]
    slot := cast(^runtime.Slot)operation.user_data[1]
    response := cast(^http.Response)slot.transport_data
    // The worker arena is different from HTTP's connection arena. All response
    // writing happens here, on the owning event loop, before releasing the slot.
    context.temp_allocator = virtual.arena_allocator(&response._conn.temp_allocator)
    response.status = http.Status(slot.status)
    http.headers_set_close(&response.headers)
    http.headers_set_content_type(&response.headers, "application/json")
    http.body_set(response, slot.body)
    runtime.release(&app.pool, slot)
    http.respond(response)
}
