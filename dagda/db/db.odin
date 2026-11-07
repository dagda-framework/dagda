package dagda_db

import "core:mem"
import "core:strings"
import platform "../platform"

Error :: enum { None, Unavailable, Deadline, Query, Unexpected_Result }

// Parse with libpq itself, including quoting and repeated option semantics.
// M0 supports one Unix socket directory or one numeric loopback address.
valid_local_conninfo :: proc(conninfo: cstring) -> bool {
    message: cstring
    options := PQconninfoParse(conninfo, &message)
    defer if message != nil { PQfreemem(rawptr(message)) }
    if options == nil { return false }
    defer PQconninfoFree(options)
    host, address: string
    for i := 0; options[i].keyword != nil; i += 1 {
        option := options[i]
        if option.val == nil { continue }
        value := string(option.val)
        switch string(option.keyword) {
        case "host": host = value
        case "hostaddr": address = value
        case "service": if value != "" { return false }
        }
    }
    if address != "" { return address == "127.0.0.1" || address == "::1" }
    return strings.has_prefix(host, "/") && !strings.contains(host, ",")
}

// libpq 17+ supplies asynchronous cancellation. Spend at most 100 ms sending
// cancellation, then discard the original connection regardless of the outcome.
// This cleanup budget is separate from the application request deadline.
cancel_and_close :: proc(conn: ^^Conn) {
    if conn^ == nil { return }
    cancel := PQcancelCreate(conn^)
    if cancel != nil {
        defer PQcancelFinish(cancel)
        if PQcancelStart(cancel) == 1 {
            deadline := platform.monotonic_ms() + 100
            for platform.monotonic_ms() < deadline {
                status := PQcancelPoll(cancel)
                if status != 1 && status != 2 { break }
                fd := PQcancelSocket(cancel)
                if fd < 0 { break }
                if platform.wait_socket(fd, i32(1) if status == 2 else i32(0), 10) < 0 { break }
            }
        }
    }
    close(conn)
}

close :: proc(conn: ^^Conn) {
    if conn^ != nil {
        PQfinish(conn^)
        conn^ = nil
    }
}

wait_ready :: proc(conn: ^Conn, writing: bool, deadline_ms: i64) -> Error {
    for {
        remaining := deadline_ms - platform.monotonic_ms()
        if remaining <= 0 { return .Deadline }
        fd := PQsocket(conn)
        if fd < 0 { return .Unavailable }
        result := platform.wait_socket(fd, i32(1) if writing else i32(0), i32(min(remaining, 25)))
        if result < 0 { return .Unavailable }
        if result > 0 { return .None }
    }
}

// The prototype accepts local sockets or numeric hosts. DNS resolution inside
// PQconnectStart is not deadline-bounded; named remote hosts are not supported.
connect :: proc(conninfo: cstring, deadline_ms: i64) -> (conn: ^Conn, err: Error) {
    if platform.monotonic_ms() >= deadline_ms { return nil, .Deadline }
    conn = PQconnectStart(conninfo)
    if conn == nil { return nil, .Unavailable }
    for {
        if platform.monotonic_ms() >= deadline_ms { err = .Deadline; break }
        status := PQconnectPoll(conn)
        switch status {
        case 0: err = .Unavailable
        case 1: err = wait_ready(conn, false, deadline_ms)
        case 2: err = wait_ready(conn, true, deadline_ms)
        case 3:
            if PQsetnonblocking(conn, 1) != 0 { err = .Unavailable; break }
            return conn, .None
        case: err = .Unavailable
        }
        if err != .None { break }
    }
    close(&conn)
    return
}

// One query at a time per leased connection. Copy the first text column into
// caller-owned storage, and drain ALL results before permitting connection reuse.
query_text :: proc(conn: ^^Conn, query: cstring, parameters: []cstring,
                   deadline_ms: i64, allocator: mem.Allocator) -> (value: string, err: Error) {
    if conn^ == nil { return "", .Unavailable }
    if platform.monotonic_ms() >= deadline_ms { return "", .Deadline }
    if PQsendQueryParams(conn^, query, i32(len(parameters)), nil,
                         raw_data(parameters), nil, nil, 0) != 1 {
        close(conn)
        return "", .Unavailable
    }
    for {
        flush := PQflush(conn^)
        if flush == 0 { break }
        if flush < 0 { close(conn); return "", .Unavailable }
        err = wait_ready(conn^, true, deadline_ms)
        if err != .None { cancel_and_close(conn); return "", err }
    }
    seen := false
    query_error := Error.None
    for {
        if platform.monotonic_ms() >= deadline_ms {
            cancel_and_close(conn)
            return "", .Deadline
        }
        if PQconsumeInput(conn^) != 1 { close(conn); return "", .Unavailable }
        if PQisBusy(conn^) != 0 {
            err = wait_ready(conn^, false, deadline_ms)
            if err != .None { cancel_and_close(conn); return "", err }
            continue
        }
        result := PQgetResult(conn^)
        if result == nil { break }
        if PQresultStatus(result) != 2 { // PGRES_TUPLES_OK
            query_error = .Query
        } else if seen || PQntuples(result) != 1 || PQgetisnull(result, 0, 0) != 0 {
            query_error = .Unexpected_Result
        } else if PQgetlength(result, 0, 0) > 8192 {
            query_error = .Query
        } else {
            value = strings.clone(string(PQgetvalue(result, 0, 0)), allocator)
        }
        seen = true
        PQclear(result)
    }
    // A disconnected backend can deliver a fatal result before libpq marks the
    // connection bad. It is an availability failure, not an application SQL error.
    if PQstatus(conn^) != 0 {
        close(conn)
        return "", .Unavailable
    }
    if !seen && query_error == .None { query_error = .Unexpected_Result }
    return value, query_error
}
