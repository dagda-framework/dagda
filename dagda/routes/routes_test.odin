package dagda_routes

import "core:mem/virtual"
import "core:testing"
import http "../http"

noop :: proc(_: ^http.Context) {}

@(test)
precedence_params_methods_and_registration :: proc(t: ^testing.T) {
    router: Router
    init(&router)
    defer destroy(&router)
    testing.expect_value(t, add(&router, .Get, "/items/:id", noop), .None)
    testing.expect_value(t, add(&router, .Post, "/items/new", noop), .None)
    testing.expect_value(t, add(&router, .Get, "/items/:other", noop), .Duplicate)
    testing.expect_value(t, add(&router, .Delete, "/items/:key", noop), .None)
    testing.expect_value(t, add(&router, .Get, "/:id/:id", noop), .Invalid_Pattern)
    testing.expect_value(t, add(&router, .Get, "/items//id", noop), .Invalid_Pattern)
    testing.expect_value(t, add(&router, .Get, "/items/:9bad", noop), .Invalid_Pattern)
    testing.expect_value(t, add(&router, .Get, "/items/..", noop), .Invalid_Pattern)
    storage: [64 * 1024]byte
    arena: virtual.Arena
    testing.expect(t, virtual.arena_init_buffer(&arena, storage[:]) == nil)
    allocator := virtual.arena_allocator(&arena)
    r := match(&router, .Get, "/items/%31", allocator)
    testing.expect_value(t, r.state, .Found)
    testing.expect_value(t, r.params[0].name, "id")
    testing.expect_value(t, r.params[0].value, "1")
    r = match(&router, .Delete, "/items/2", allocator)
    testing.expect_value(t, r.params[0].name, "key")
    // Static path precedence applies before method selection: no accidental
    // fallback to GET /items/:id when /items/new exists only for POST.
    r = match(&router, .Get, "/items/new", allocator)
    testing.expect_value(t, r.state, .Method_Not_Allowed)
    testing.expect(t, .Post in r.allow && .Get not_in r.allow)
    r = match(&router, .Put, "/items/2", allocator)
    testing.expect_value(t, r.state, .Method_Not_Allowed)
    testing.expect(t, .Get in r.allow && .Delete in r.allow)
    testing.expect_value(t, match(&router, .Get, "/missing", allocator).state, .Not_Found)
    testing.expect_value(t, match(&router, .Get, "/items/1/", allocator).state, .Not_Found)
    router.frozen = true
    testing.expect_value(t, add(&router, .Get, "/late", noop), .Frozen)
}

@(test)
invalid_and_ambiguous_paths :: proc(t: ^testing.T) {
    router: Router
    init(&router)
    defer destroy(&router)
    add(&router, .Get, "/items/:id", noop)
    storage: [64 * 1024]byte
    arena: virtual.Arena
    testing.expect(t, virtual.arena_init_buffer(&arena, storage[:]) == nil)
    allocator := virtual.arena_allocator(&arena)
    paths := []string{"/items/%", "/items/%xy", "/items/%2fadmin", "/items/%5cadmin", "/items/%00",
                      "/items/%7f", "/items/%ff", "/items/%2e%2e", "/items/.", "/items//2", "items/2"}
    for path in paths { testing.expect_value(t, match(&router, .Get, path, allocator).state, .Bad_Path) }
    r := match(&router, .Get, "/items/%252f", allocator)
    testing.expect_value(t, r.state, .Found)
    testing.expect_value(t, r.params[0].value, "%2f") // never decode twice
}
