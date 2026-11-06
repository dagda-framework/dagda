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
