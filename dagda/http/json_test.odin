package dagda_http

import "core:math"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import transport "../../vendor/odin-http"

JSON_Probe :: struct { status: int, body: string, replies: int }
json_reply :: proc(c: ^Context, status: int, body: string) {
    probe := cast(^JSON_Probe)c.user_data
    probe.status = status
    probe.body = strings.clone(body, c.allocator)
    probe.replies += 1
}
DTO :: struct {
    name: string,
    count: i8,
    enabled: bool,
    labels: []string,
    nested: struct { value: u16 `json:"number"` },
    note: union {string},
}

@(test)
typed_json_decode_round_trip_and_ownership :: proc(t: ^testing.T) {
    arena: virtual.Arena
    testing.expect(t, virtual.arena_init_growing(&arena) == nil)
    defer virtual.arena_destroy(&arena)
    allocator := virtual.arena_allocator(&arena)
    context.temp_allocator = allocator
    request: transport.Request
    transport.request_init(&request, allocator)
    transport.headers_set_unsafe(&request.headers, "content-type", "Application/JSON; charset=\"UTF-8\"")
    body := strings.clone(`{"name":"Odin\n☘","count":127,"enabled":true,"labels":["a","b"],"nested":{"number":65535},"note":"optional"}`, allocator)
    probe: JSON_Probe
    c := Context{allocator=allocator, body=body, _request=&request, _reply=json_reply, user_data=&probe}
    input: DTO
    testing.expect(t, decode_json(&c, &input))
    testing.expect_value(t, input.name, "Odin\n☘")
    testing.expect_value(t, input.count, i8(127))
    testing.expect_value(t, input.nested.value, u16(65535))
    testing.expect(t, input.note != nil)
    if input.note != nil { testing.expect_value(t, input.note.(string), "optional") }
    testing.expect_value(t, len(input.labels), 2)
    // Input views cannot borrow mutable transport storage.
    for &ch in transmute([]byte)body { ch = ' ' }
    testing.expect_value(t, input.name, "Odin\n☘")
    testing.expect(t, respond_json(&c, 201, input))
    testing.expect_value(t, probe.status, 201)
    testing.expect(t, strings.contains(probe.body, `"number":65535`))
    testing.expect(t, !respond_json(&c, 200, input))
    testing.expect_value(t, probe.replies, 1)
}

@(test)
typed_json_rejects_ambiguous_syntax_types_and_ranges :: proc(t: ^testing.T) {
    arena: virtual.Arena
    testing.expect(t, virtual.arena_init_growing(&arena) == nil)
    defer virtual.arena_destroy(&arena)
    allocator := virtual.arena_allocator(&arena)
    context.temp_allocator = allocator
    request: transport.Request
    transport.request_init(&request, allocator)
    transport.headers_set_unsafe(&request.headers, "content-type", "application/json")
    cases := []string{
        "", " ", "null", "[]", `{} {}`, `{} trailing`, `{"name":"a",}`, `{name:"a"}`, `{'name':'a'}`,
        `/*comment*/{}`, `{"unknown":true}`, `{"nested":{"unknown":1}}`, `{"name":"a","name":"b"}`,
        `{"name":"a","\u006eame":"b"}`, `{"":1}`, `{"count":128}`, `{"count":-129}`,
        `{"count":1.0}`, `{"count":"1"}`, `{"name":null}`, `{"enabled":0}`, `{"labels":[1]}`,
        `{"nested":{"number":-1}}`, `{"nested":{"number":65536}}`, `{"count":9223372036854775808}`,
        `{"count":1e999}`, `{"count":NaN}`, `{"count":0x10}`, "{\"name\":\"\xff\"}",
    }
    for body in cases {
        probe: JSON_Probe
        c := Context{allocator=allocator, body=body, _request=&request, _reply=json_reply, user_data=&probe}
        input := DTO{name="unchanged", count=42}
        testing.expect(t, !decode_json(&c, &input), body)
        testing.expect_value(t, probe.status, 400)
        testing.expect_value(t, input.name, "unchanged")
        testing.expect_value(t, input.count, i8(42))
    }
    deep := strings.concatenate({strings.repeat("[", 33, allocator), strings.repeat("]", 33, allocator)}, allocator)
    testing.expect(t, !json_syntax_safe(deep))
}

@(test)
typed_json_defaults_media_and_single_decode :: proc(t: ^testing.T) {
    arena: virtual.Arena
    testing.expect(t, virtual.arena_init_growing(&arena) == nil)
    defer virtual.arena_destroy(&arena)
    allocator := virtual.arena_allocator(&arena)
    context.temp_allocator = allocator
    request: transport.Request
    transport.request_init(&request, allocator)
    probe: JSON_Probe
    c := Context{allocator=allocator, body=`{"note":null}`, _request=&request, _reply=json_reply, user_data=&probe}
    input := DTO{name="old"}
    testing.expect(t, !decode_json(&c, &input))
    testing.expect_value(t, probe.status, 415)
    transport.headers_set_unsafe(&request.headers, "content-type", "application/json")
    c._state = .Open
    c._json_decoded = false
    testing.expect(t, decode_json(&c, &input))
    testing.expect_value(t, input.name, "")
    testing.expect(t, input.note == nil)
    testing.expect(t, !decode_json(&c, &input))
    testing.expect_value(t, probe.status, 500)
    for media in ([]string{"text/plain", "application/jsonp", "application/json; charset=latin1", "application/json;", "application/json; charset=utf-8; charset=utf-8"}) {
        testing.expect(t, !json_media_type(media), media)
    }
}

@(test)
typed_json_response_failures_are_atomic :: proc(t: ^testing.T) {
    arena: virtual.Arena
    testing.expect(t, virtual.arena_init_growing(&arena) == nil)
    defer virtual.arena_destroy(&arena)
    allocator := virtual.arena_allocator(&arena)
    context.temp_allocator = allocator
    probe: JSON_Probe
    c := Context{allocator=allocator, _reply=json_reply, user_data=&probe}
    testing.expect(t, respond_json(&c, 200, struct {value: f64}{math.inf_f64(1)}))
    testing.expect_value(t, probe.status, 500)
    testing.expect_value(t, probe.body, `{"error":{"code":"invalid_response","message":"Internal server error"},"request_id":""}`)
    c._state = .Open
    testing.expect(t, respond_json(&c, 200, strings.repeat("x", MAX_JSON_BYTES, allocator)))
    testing.expect_value(t, probe.status, 500)
    testing.expect_value(t, probe.body, `{"error":{"code":"invalid_response","message":"Internal server error"},"request_id":""}`)
    c._state = .Open
    testing.expect(t, respond_json(&c, 200, strings.repeat("x", MAX_JSON_BYTES-2, allocator)))
    testing.expect_value(t, probe.status, 200)
    testing.expect_value(t, len(probe.body), MAX_JSON_BYTES)
}

@(test)
typed_json_fixed_arrays_float_ranges_and_integer_boundaries :: proc(t: ^testing.T) {
    arena: virtual.Arena
    testing.expect(t, virtual.arena_init_growing(&arena) == nil)
    defer virtual.arena_destroy(&arena)
    allocator := virtual.arena_allocator(&arena)
    context.temp_allocator = allocator
    request: transport.Request
    transport.request_init(&request, allocator)
    transport.headers_set_unsafe(&request.headers, "content-type", "application/json")
    Shape :: struct { count: i64, unsigned: u8, ratio: f32, pair: [2]bool }
    Case :: struct { body: string, valid: bool }
    cases := []Case{
        {`{"count":9223372036854775807,"unsigned":255,"ratio":3.5,"pair":[true,false]}`, true},
        {`{"count":-9223372036854775808}`, true},
        {`{"count":-9223372036854775809}`, false},
        {`{"unsigned":-1}`, false}, {`{"unsigned":256}`, false},
        {`{"ratio":1e40}`, false}, {`{"ratio":true}`, false},
        {`{"pair":[true]}`, false}, {`{"pair":[true,false,true]}`, false},
        {`{"pair":[true,false,]}`, false}, {`{"pair":null}`, false},
        {`{"count":01}`, false}, {`{"count":+1}`, false},
    }
    for entry in cases {
        probe: JSON_Probe
        c := Context{allocator=allocator, body=entry.body, _request=&request, _reply=json_reply, user_data=&probe}
        value: Shape
        testing.expect(t, decode_json(&c, &value) == entry.valid, entry.body)
        if !entry.valid { testing.expect_value(t, probe.status, 400) }
    }
}
