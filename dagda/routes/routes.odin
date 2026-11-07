package dagda_routes

import "core:mem"
import "core:strings"
import "core:unicode/utf8"
import http "../http"

MAX_SEGMENTS :: 16
MAX_PARAMS :: 8
MAX_ROUTES :: 256
Error :: enum { None, Frozen, Invalid_Pattern, Duplicate, Invalid_Handler, Capacity }
Match_State :: enum { Found, Not_Found, Method_Not_Allowed, Bad_Path }
Segment :: struct { value: string, parameter: bool }
Route :: struct {
    method: http.Method,
    pattern: string,
    segments: [MAX_SEGMENTS]Segment,
    count: int,
    priority: u32,
    handler: http.Handler,
    data: rawptr,
    middleware: []http.Middleware,
}
Router :: struct { entries: [dynamic]Route, allocator: mem.Allocator, frozen: bool }
Match :: struct {
    state: Match_State,
    route: ^Route,
    allow: bit_set[http.Method],
    params: [MAX_PARAMS]http.Param,
    count: int,
}

init :: proc(r: ^Router, allocator := context.allocator) { r.allocator = allocator; r.entries.allocator = allocator }
destroy :: proc(r: ^Router) {
    for entry in r.entries { delete(entry.pattern, r.allocator); delete(entry.middleware, r.allocator) }
    delete(r.entries)
    r^ = {}
}

split :: proc(path: string) -> (segments: [MAX_SEGMENTS]string, count: int, ok: bool) {
    if len(path) == 0 || path[0] != '/' { return }
    if path == "/" { return segments, 0, true }
    start := 1
    for i := 1; i <= len(path); i += 1 {
        if i < len(path) && path[i] != '/' { continue }
        if count == MAX_SEGMENTS || (i == start && i < len(path)) { return }
        segments[count] = path[start:i]
        count += 1
        start = i + 1
    }
    return segments, count, true
}

add :: proc(r: ^Router, method: http.Method, pattern: string, handler: http.Handler,
            data: rawptr = nil, middleware: []http.Middleware = nil) -> Error {
    if r.frozen { return .Frozen }
    if len(pattern) > 8000 { return .Invalid_Pattern }
    if handler == nil { return .Invalid_Handler }
    if len(r.entries) >= MAX_ROUTES || len(middleware) > 16 { return .Capacity }
    for m in middleware { if m.handle == nil { return .Invalid_Handler } }
    parts, count, ok := split(pattern)
    if !ok || !utf8.valid_string(pattern) { return .Invalid_Pattern }
    entry := Route{method = method, count = count, handler = handler, data = data}
    params: [MAX_PARAMS]string
    n := 0
    for part, i in parts[:count] {
        for ch in part { if ch < 32 || ch == 127 || ch == '%' || ch == '?' || ch == '#' || ch == '\\' { return .Invalid_Pattern } }
        if part == "." || part == ".." { return .Invalid_Pattern }
        parameter := strings.has_prefix(part, ":")
        if parameter {
            name := part[1:]
            if len(name) == 0 || n == MAX_PARAMS { return .Invalid_Pattern }
            for ch, index in name {
                if !(('a' <= ch && ch <= 'z') || ('A' <= ch && ch <= 'Z') || ch == '_' || (index > 0 && '0' <= ch && ch <= '9')) { return .Invalid_Pattern }
            }
            for previous in params[:n] { if previous == name { return .Invalid_Pattern } }
            params[n] = name
            n += 1
        } else { entry.priority |= 1 << u32(MAX_SEGMENTS - i - 1) }
        entry.segments[i] = Segment{part, parameter}
    }
    for previous in r.entries {
        if previous.method != method || previous.count != count { continue }
        same := true
        for segment, i in entry.segments[:count] {
            other := previous.segments[i]
            if segment.parameter != other.parameter || (!segment.parameter && segment.value != other.value) { same = false; break }
        }
        if same { return .Duplicate }
    }
    entry.pattern = strings.clone(pattern, r.allocator)
    owned, _, _ := split(entry.pattern)
    for part, i in owned[:count] { entry.segments[i].value = part[1:] if entry.segments[i].parameter else part }
    entry.middleware = make([]http.Middleware, len(middleware), r.allocator)
    copy(entry.middleware, middleware)
    append(&r.entries, entry)
    return .None
}

// Decode once, without allowing encoded separators to change route boundaries.
decode_path :: proc(path: string, allocator: mem.Allocator) -> (decoded: string, ok: bool) {
    if len(path) > 8000 || !strings.has_prefix(path, "/") { return }
    bytes := make([]byte, len(path), allocator)
    n := 0
    for i := 0; i < len(path); i += 1 {
        ch := path[i]
        if ch == '%' {
            if i + 2 >= len(path) { delete(bytes, allocator); return }
            hex :: proc(ch: byte) -> int {
                if '0' <= ch && ch <= '9' { return int(ch - '0') }
                if 'a' <= ch && ch <= 'f' { return int(ch - 'a') + 10 }
                if 'A' <= ch && ch <= 'F' { return int(ch - 'A') + 10 }
                return -1
            }
            a, b := hex(path[i+1]), hex(path[i+2])
            if a < 0 || b < 0 { delete(bytes, allocator); return }
            ch = byte(a * 16 + b)
            if ch == '/' { delete(bytes, allocator); return }
            i += 2
        } else if ch == '#' || ch == '?' { delete(bytes, allocator); return }
        if ch < 32 || ch == 127 || ch == '\\' { delete(bytes, allocator); return }
        bytes[n] = ch
        n += 1
    }
    decoded = string(bytes[:n])
    if !utf8.valid_string(decoded) { delete(bytes, allocator); return "", false }
    parts, count, valid := split(decoded)
    if !valid { delete(bytes, allocator); return "", false }
    for part in parts[:count] { if part == "." || part == ".." { delete(bytes, allocator); return "", false } }
    return decoded, true
}

match :: proc(r: ^Router, method: http.Method, path: string, allocator := context.temp_allocator) -> (result: Match) {
    result.state = .Not_Found
    decoded, ok := decode_path(path, allocator)
    if !ok { result.state = .Bad_Path; return }
    parts, count, _ := split(decoded)
    best: u32
    seen := false
    for &entry in r.entries {
        if entry.count != count { continue }
        matches := true
        for segment, i in entry.segments[:count] {
            if (segment.parameter && parts[i] == "") || (!segment.parameter && segment.value != parts[i]) { matches = false; break }
        }
        if !matches || (seen && entry.priority < best) { continue }
        if !seen || entry.priority > best {
            seen = true
            best = entry.priority
            result = Match{state = .Method_Not_Allowed, route = &entry}
        }
        result.allow += {entry.method}
        if entry.method != method { continue }
        result.state = .Found
        result.route = &entry
        result.count = 0
        for segment, i in entry.segments[:count] {
            if segment.parameter {
                result.params[result.count] = http.Param{segment.value, parts[i]}
                result.count += 1
            }
        }
    }
    return
}
