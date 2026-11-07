package main

import "core:bytes"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import http "../../vendor/odin-http"

@(test)
formatted_json_survives_response_framing :: proc(t: ^testing.T) {
    storage: [64 * 1024]byte
    arena: virtual.Arena
    if !testing.expect(t, virtual.arena_init_buffer(&arena, storage[:]) == nil) { return }
    context.temp_allocator = virtual.arena_allocator(&arena)
    server: http.Server
    connection := http.Connection{server = &server}
    response := http.Response{_conn = &connection}
    http.response_init(&response, context.temp_allocator)
    response.status = .OK
    http.headers_set_close(&response.headers)
    http.headers_set_content_type(&response.headers, "application/json")
    body := pool_state_json(2, 8)
    testing.expect_value(t, body, `{"inflight":2,"capacity":8}`)
    http.body_set(&response, body)
    wire := string(bytes.buffer_to_bytes(&response._buf))
    testing.expect(t, strings.has_suffix(wire, "\r\n\r\n" + `{"inflight":2,"capacity":8}`))
    testing.expect(t, strings.contains(wire, "content-length: 27\r\n"))
}

@(test)
malformed_headers_are_rejected :: proc(t: ^testing.T) {
    storage: [32 * 1024]byte
    arena: virtual.Arena
    if !testing.expect(t, virtual.arena_init_buffer(&arena, storage[:]) == nil) { return }
    context.temp_allocator = virtual.arena_allocator(&arena)
    invalid := []string{
        " Bad: folded", "\tBad: folded", "Bad\t: name", "Bad(Name): value",
        "X-Value: before\x00after", "X-Value: before\x7fafter", "Bad Name: value",
    }
    for line in invalid {
        headers: http.Headers
        http.headers_init(&headers, context.temp_allocator)
        _, ok := http.header_parse(&headers, line)
        testing.expect(t, !ok)
    }
    headers: http.Headers
    http.headers_init(&headers, context.temp_allocator)
    _, ok := http.header_parse(&headers, "X-Test: before\tafter")
    testing.expect(t, ok)
}
