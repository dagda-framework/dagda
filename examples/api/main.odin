package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import app "../../dagda/app"
import config "../../dagda/config"
import http "../../dagda/http"
import validation "../../dagda/validation"

main :: proc() { os.exit(run()) }
run :: proc() -> int {
    settings, error := config.load()
    if error.field != "" { fmt.eprintf("Invalid %s: %s\n", error.field, error.message); return 1 }
    defer config.destroy(&settings)
    application := new(app.App)
    defer free(application)
    app.init(application, settings)
    defer app.destroy(application)
    hooks := Hook_State{record = settings.environment == .Test,
                        fail = settings.environment == .Test && os.get_env("DAGDA_TEST_START_FAIL", context.temp_allocator) == "1"}
    application.hooks = app.Hooks{start = on_start, stop = on_stop, data = &hooks}
    configure(application)
    if app.run(application) != .None { return 1 }
    return 0
}
// Shared route registration for the executable and Odin application tests.
configure :: proc(application: ^app.App) {
    assert(app.use(application, http.Middleware{handle = identify}))
    assert(app.route(application, .Get, "/", index) == .None)
    assert(app.route(application, .Get, "/items/:id", item) == .None)
    assert(app.route(application, .Get, "/items/new", new_item) == .None)
    assert(app.route(application, .Post, "/items", create_item) == .None)
    assert(app.route(application, .Post, "/echo", echo) == .None)
    assert(app.route(application, .Post, "/validate", validate_input) == .None)
    assert(app.route(application, .Head, "/", index) == .None)
    restricted := []http.Middleware{{handle = require_demo_key}}
    assert(app.route(application, .Get, "/private", index, middleware=restricted) == .None)
    if application.config.environment == .Test {
        assert(app.route(application, .Get, "/_test/slow", slow) == .None)
        assert(app.route(application, .Get, "/_test/sql-error", sql_error) == .None)
    }
}
Hook_State :: struct { record, fail: bool }
on_start :: proc(data: rawptr) -> bool {
    state := cast(^Hook_State)data
    if state.record { fmt.println(`{"event":"example_start"}`) }
    return !state.fail
}
on_stop :: proc(data: rawptr) {
    state := cast(^Hook_State)data
    if state.record { fmt.println(`{"event":"example_stop"}`) }
}
identify :: proc(c: ^http.Context, next: ^http.Next, _: rawptr) {
    http.set_header(c, "x-powered-by", "Dagda")
    http.next(next)
}
// Demonstrates short-circuit middleware only; this is not an authentication API.
require_demo_key :: proc(c: ^http.Context, next: ^http.Next, _: rawptr) {
    value, _ := http.header(c, "x-demo-key")
    if value != "example" { http.respond_error(c, 401, "demo_key_required", "Demo key required"); return }
    http.next(next)
}
index :: proc(c: ^http.Context) { http.respond_json(c, 200, struct {name: string}{"Dagda"}) }
new_item :: proc(c: ^http.Context) { http.json_text(c, 200, `{"route":"static"}`) }
create_item :: proc(c: ^http.Context) { http.respond_error(c, 501, "not_implemented", "Not implemented") }
item :: proc(c: ^http.Context) {
    raw, _ := http.param(c, "id")
    id, ok := strconv.parse_i64(raw)
    if !ok || id <= 0 { http.respond_error(c, 400, "invalid_id", "Invalid item ID"); return }
    params := make([]cstring, 1, c.allocator)
    params[0] = strings.clone_to_cstring(raw, c.allocator)
    http.query_text(c, "SELECT row_to_json(item)::text FROM (SELECT id, name FROM dagda_m0_items WHERE id = $1::bigint) item", params)
}
slow :: proc(c: ^http.Context) {
    raw, _ := http.query(c, "ms")
    ms, ok := strconv.parse_i64(raw)
    if !ok || ms < 0 || ms > 5000 { http.respond_error(c, 400, "invalid_delay", "Invalid delay"); return }
    params := make([]cstring, 1, c.allocator)
    params[0] = strings.clone_to_cstring(raw, c.allocator)
    http.query_text(c, "SELECT json_build_object('slept_ms', $1::int)::text FROM pg_sleep($1::double precision / 1000.0)", params)
}

// A typed round-trip example without database side effects.
Echo_Request :: struct {
    name: string,
    count: i32,
    enabled: bool,
    labels: []string,
    note: union {string},
}
echo :: proc(c: ^http.Context) {
    input: Echo_Request
    if !http.decode_json(c, &input) { return }
    http.respond_json(c, 200, input)
}

Validated_Input :: struct {
    title: string,
    quantity: i32,
    priority: string,
    enabled: bool,
}
// Demonstrates validation only; accepting this request does not persist a record.
validate_input :: proc(c: ^http.Context) {
    input: Validated_Input
    if !http.decode_json(c, &input) { return }
    errors: validation.Errors
    if validation.required_text(&errors, "title", input.title) {
        validation.text_length(&errors, "title", input.title, 1, 80)
    }
    validation.integer_range(&errors, "quantity", i64(input.quantity), 1, 100)
    validation.one_of(&errors, "priority", input.priority, {"low", "normal", "high"})
    validation.required(&errors, "enabled", http.json_field_state(c, "enabled") == .Value)
    if !http.validate(c, &errors) { return }
    http.respond_json(c, 200, input)
}

// Used only by the isolated network integration fixture.
sql_error :: proc(c: ^http.Context) { http.query_text(c, "SELECT 1 / 0") }
