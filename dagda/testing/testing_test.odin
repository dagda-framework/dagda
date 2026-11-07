package dagda_testing

import "core:strings"
import test "core:testing"
import app "../app"
import config "../config"
import http "../http"

make_app :: proc() -> ^app.App {
    settings, error := config.parse(config.Values{database_url="host=/tmp/dagda-test-only dbname=unused"})
    assert(error.field == "")
    a := new(app.App)
    app.init(a, settings)
    return a
}
free_app :: proc(a: ^app.App) {
    settings := a.config
    app.destroy(a)
    config.destroy(&settings)
    free(a)
}
Sample :: struct { name, query: string }
sample :: proc(c: ^http.Context) {
    name, _ := http.param(c, "name")
    query, _ := http.query(c, "q")
    http.respond_json(c, 200, Sample{name, query})
}
mark :: proc(c: ^http.Context, next: ^http.Next, _: rawptr) {
    http.set_header(c, "x-mark", "middleware")
    http.next(next)
}

@(test)
request_uses_shared_routes_middleware_and_owned_responses :: proc(t: ^test.T) {
    a := make_app()
    defer free_app(a)
    test.expect(t, app.use(a, {handle=mark}))
    test.expect_value(t, app.route(a, .Get, "/hello/:name", sample), .None)
    first, error := request(a, {.Get, "/hello/%44agda?q=odin", nil, ""})
    test.expect_value(t, error, .None)
    defer destroy(&first)
    test.expect_value(t, first.status, 200)
    test.expect_value(t, header(&first, "X-Mark"), "middleware")
    value: Sample
    test.expect(t, decode_json(&first, &value) == nil)
    test.expect_value(t, value.name, "Dagda")
    test.expect_value(t, value.query, "odin")
    test.expect_value(t, first.completions, 1)
    test.expect_value(t, first.completion.route, "/hello/:name")
    test.expect_value(t, first.completion.request_id, header(&first, "x-request-id"))
    second, error2 := request(a, {.Get, "/hello/other", nil, ""})
    test.expect_value(t, error2, .None)
    defer destroy(&second)
    test.expect(t, first.completion.request_id != second.completion.request_id)
    test.expect_value(t, value.name, "Dagda") // still alive after another request
    test.expect_value(t, a.state, .Configured)
}

@(test)
routing_head_and_input_bounds :: proc(t: ^test.T) {
    a := make_app()
    defer free_app(a)
    app.route(a, .Get, "/hello/:name", sample)
    app.route(a, .Head, "/hello/:name", sample)
    for method in ([]http.Method{.Get, .Head}) {
        response, error := request(a, {method=method, target="/hello/Dagda"})
        test.expect_value(t, error, .None)
        defer destroy(&response)
        test.expect_value(t, response.status, 200)
        test.expect_value(t, header(&response, "content-length"), "27")
        if method == .Head { test.expect_value(t, response.body, "") }
    }
    response, error := request(a, {method=.Delete, target="/hello/Dagda"})
    test.expect_value(t, error, .None)
    defer destroy(&response)
    test.expect_value(t, response.status, 405)
    allow := header(&response, "allow")
    test.expect(t, strings.contains(allow, "GET") && strings.contains(allow, "HEAD"))
    missing, missing_error := request(a, {method=.Get, target="/missing"})
    test.expect_value(t, missing_error, .None)
    defer destroy(&missing)
    test.expect_value(t, missing.status, 404)
    bad, bad_error := request(a, {method=.Get, target="/hello/%2f"})
    test.expect_value(t, bad_error, .None)
    defer destroy(&bad)
    test.expect_value(t, bad.status, 400)
    oversized := make([]byte, 8193)
    defer delete(oversized)
    large, large_error := request(a, {method=.Post, target="/hello", body=string(oversized)})
    test.expect_value(t, large_error, .None)
    defer destroy(&large)
    test.expect_value(t, large.status, 413)
    invalid, invalid_error := request(a, {method=.Get, target="/", headers={{"x-test", "x\r\ny"}}})
    test.expect_value(t, invalid_error, .Invalid_Request)
    destroy(&invalid)
}

database :: proc(c: ^http.Context) { http.query_text(c, "SELECT 1") }
no_response :: proc(_: ^http.Context) {}
@(test)
unsupported_dependencies_are_test_errors_and_missing_reply_is_500 :: proc(t: ^test.T) {
    a := make_app()
    defer free_app(a)
    app.route(a, .Get, "/db", database)
    app.route(a, .Get, "/empty", no_response)
    response, error := request(a, {method=.Get, target="/db"})
    test.expect_value(t, error, .Database_Not_Supported)
    test.expect(t, response._arena == nil)
    empty, empty_error := request(a, {method=.Get, target="/empty"})
    test.expect_value(t, empty_error, .None)
    defer destroy(&empty)
    test.expect_value(t, empty.status, 500)
    a.state = .Running
    invalid, invalid_error := request(a, {method=.Get, target="/"})
    test.expect_value(t, invalid_error, .Invalid_App_State)
    destroy(&invalid)
    a.state = .Configured
}

invalid_json :: proc(c: ^http.Context) { http.json_text(c, 200, `{} {}`) }
@(test)
response_decoder_rejects_trailing_data_without_mutating_destination :: proc(t: ^test.T) {
    a := make_app()
    defer free_app(a)
    app.route(a, .Get, "/invalid", invalid_json)
    response, error := request(a, {method=.Get, target="/invalid"})
    test.expect_value(t, error, .None)
    defer destroy(&response)
    value := Sample{name="unchanged"}
    test.expect(t, decode_json(&response, &value) != nil)
    test.expect_value(t, value.name, "unchanged")
}

wide_integer :: proc(c: ^http.Context) { http.respond_json(c, 200, struct {value: u64}{max(u64)}) }
@(test)
response_decoder_preserves_unsigned_64_bit_values :: proc(t: ^test.T) {
    a := make_app()
    defer free_app(a)
    app.route(a, .Get, "/wide", wide_integer)
    response, error := request(a, {method=.Get, target="/wide"})
    test.expect_value(t, error, .None)
    defer destroy(&response)
    value: struct {value: u64}
    test.expect(t, decode_json(&response, &value) == nil)
    test.expect_value(t, value.value, max(u64))
}
