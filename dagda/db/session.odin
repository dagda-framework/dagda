package dagda_db

import "core:encoding/hex"
import "core:mem"
import "core:strconv"
import "core:strings"
import platform "../platform"

MAX_ROWS :: 128
MAX_COLUMNS :: 32
MAX_RESULT_BYTES :: 65536
MAX_PARAMETERS :: 32
MAX_QUERY_BYTES :: 16384

Failure_Kind :: enum {
    None, Unavailable, Deadline, Query, Constraint, Serialization, Deadlock,
    Canceled, Invalid_Input, Invalid_State, Result_Limit, Mapping, Commit_Unknown,
}
// Owns only safe metadata: never SQL, submitted values, or server error text.
Failure :: struct { kind: Failure_Kind, sqlstate: [5]byte }
state_code :: proc(f: ^Failure) -> string { return string(f.sqlstate[:]) }

// Exclusively borrowed for one worker operation. Never share across threads.
Session :: struct {
    connection: ^^Conn,
    deadline_ms: i64,
    _transaction, _failed: bool,
    _queries: int,
}
Column :: struct { name: string, oid: u32 }
Cell :: struct { data: string, is_null: bool }
Rows :: struct {
    columns: [dynamic]Column,
    cells: [dynamic]Cell,
    count: int,
    affected: i64,
    _bytes: int,
    _allocator: mem.Allocator,
}
// Results own their data independently of libpq and subsequent queries.
// Do not copy ownership; destroy exactly once. Mapped strings/bytes borrow Rows.
destroy_rows :: proc(rows: ^Rows) {
    for column in rows.columns { delete(column.name, rows._allocator) }
    for cell in rows.cells { if !cell.is_null { delete(cell.data, rows._allocator) } }
    delete(rows.columns)
    delete(rows.cells)
    rows^ = {}
}
classify_state :: proc(code: string) -> Failure {
    f := Failure{kind=.Query}
    if len(code) != 5 { return f }
    copy(f.sqlstate[:], transmute([]byte)code)
    if strings.has_prefix(code, "23") { f.kind = .Constraint }
    switch code {
    case "40001": f.kind = .Serialization
    case "40P01": f.kind = .Deadlock
    case "57014": f.kind = .Canceled
    }
    return f
}
legacy_failure :: proc(error: Error) -> Failure {
    switch error {
    case .None: return {}
    case .Deadline: return {kind=.Deadline}
    case .Unavailable: return {kind=.Unavailable}
    case .Query, .Unexpected_Result: return {kind=.Query}
    }
    unreachable()
}

// Text parameters use nil for SQL NULL; strings may not contain NUL. Binary
// values use PostgreSQL's hex bytea text syntax and an explicit $n::bytea cast.
Param :: struct { text: string, is_null: bool }
null_param :: proc() -> Param { return {is_null=true} }

query_rows :: proc(s: ^Session, sql: string, parameters: []Param = nil,
                   allocator := context.allocator) -> (Rows, Failure) {
    return execute_rows(s, sql, parameters, allocator, false)
}
exec :: proc(s: ^Session, sql: string, parameters: []Param = nil) -> (affected: i64, failure: Failure) {
    rows, error := query_rows(s, sql, parameters)
    defer destroy_rows(&rows)
    return rows.affected, error
}

// Single-row mode avoids buffering an entire unbounded row set inside libpq.
// One individual server row can still be buffered before its size is checked.
execute_rows :: proc(s: ^Session, sql: string, parameters: []Param, allocator: mem.Allocator,
                     control: bool) -> (rows: Rows, failure: Failure) {
    rows, failure = run_query(s, sql, parameters, allocator, control)
    if failure.kind != .None {
        destroy_rows(&rows)
        if s != nil && s._transaction { s._failed = true }
    }
    return
}
run_query :: proc(s: ^Session, sql: string, parameters: []Param, allocator: mem.Allocator,
                  control: bool) -> (rows: Rows, failure: Failure) {
    rows._allocator = allocator
    rows.columns.allocator = allocator
    rows.cells.allocator = allocator
    if s == nil || s.connection == nil || s.connection^ == nil { return rows, {kind=.Unavailable} }
    if len(sql) == 0 || len(sql) > MAX_QUERY_BYTES || strings.contains(sql, "\x00") || len(parameters) > MAX_PARAMETERS {
        return rows, {kind=.Invalid_Input}
    }
    size := len(sql)
    for parameter in parameters {
        if !parameter.is_null {
            if strings.contains(parameter.text, "\x00") { return rows, {kind=.Invalid_Input} }
            size += len(parameter.text) + 1
        }
    }
    if size > MAX_QUERY_BYTES { return rows, {kind=.Invalid_Input} }
    if !control {
        if s._queries >= 32 { return rows, {kind=.Result_Limit} }
        s._queries += 1
        expected := i32(2) if s._transaction else i32(0)
        if s._failed || PQtransactionStatus(s.connection^) != expected { return rows, {kind=.Invalid_State} }
    }
    if platform.monotonic_ms() >= s.deadline_ms { return rows, {kind=.Deadline} }
    // Parameter conversion is scoped to this call, including arena callers.
    param_memory: [MAX_QUERY_BYTES+1]byte
    offset := 0
    copy(param_memory[:], transmute([]byte)sql)
    command := cstring(raw_data(param_memory[:]))
    offset = len(sql) + 1
    values: [MAX_PARAMETERS]cstring
    for parameter, i in parameters {
        if parameter.is_null { continue }
        values[i] = cstring(&param_memory[offset])
        copy(param_memory[offset:], transmute([]byte)parameter.text)
        offset += len(parameter.text) + 1
    }
    if PQsendQueryParams(s.connection^, command, i32(len(parameters)), nil, &values[0], nil, nil, 0) != 1 {
        close(s.connection)
        return rows, {kind=.Unavailable}
    }
    if PQsetSingleRowMode(s.connection^) != 1 { close(s.connection); return rows, {kind=.Invalid_State} }
    for {
        flush := PQflush(s.connection^)
        if flush == 0 { break }
        if flush < 0 { close(s.connection); return rows, {kind=.Unavailable} }
        error := wait_ready(s.connection^, true, s.deadline_ms)
        if error != .None { cancel_and_close(s.connection); return rows, legacy_failure(error) }
    }
    terminal := false
    for {
        if platform.monotonic_ms() >= s.deadline_ms { cancel_and_close(s.connection); return rows, {kind=.Deadline} }
        if PQconsumeInput(s.connection^) != 1 { close(s.connection); return rows, {kind=.Unavailable} }
        if PQisBusy(s.connection^) != 0 {
            error := wait_ready(s.connection^, false, s.deadline_ms)
            if error != .None { cancel_and_close(s.connection); return rows, legacy_failure(error) }
            continue
        }
        result := PQgetResult(s.connection^)
        if result == nil { break }
        status := PQresultStatus(result)
        switch status {
        case 1, 2, 9: // command, tuples-complete, single tuple
            if terminal { failure = {kind=.Invalid_State} }
            if failure.kind == .None { failure = collect_result(&rows, result) }
            if status != 9 {
                terminal = true
                count := string(PQcmdTuples(result))
                if count != "" {
                    value, ok := strconv.parse_i64(count)
                    if !ok || value < 0 { failure = {kind=.Mapping} } else { rows.affected = value }
                }
                if control && sql == "COMMIT" && string(PQcmdStatus(result)) != "COMMIT" {
                    failure = {kind=.Invalid_State}
                }
            }
        case 7: // fatal error: drain before returning the SQLSTATE
            failure = classify_state(string(PQresultErrorField(result, 'C')))
            terminal = true
        case: // COPY/pipeline/unsupported protocol: never reuse this connection
            failure = {kind=.Invalid_State}
        }
        PQclear(result)
        if failure.kind == .Result_Limit || failure.kind == .Invalid_State {
            cancel_and_close(s.connection)
            return rows, failure
        }
    }
    if PQstatus(s.connection^) != 0 { close(s.connection); return rows, {kind=.Unavailable} }
    if !terminal { close(s.connection); return rows, {kind=.Unavailable} }
    if !control && failure.kind == .None {
        expected := i32(2) if s._transaction else i32(0)
        if PQtransactionStatus(s.connection^) != expected { close(s.connection); return rows, {kind=.Invalid_State} }
    }
    return
}
collect_result :: proc(rows: ^Rows, result: ^Result) -> Failure {
    width := int(PQnfields(result))
    if width > MAX_COLUMNS { return {kind=.Result_Limit} }
    if len(rows.columns) == 0 {
        for i in 0..<width {
            name := string(PQfname(result, i32(i)))
            rows._bytes += len(name)
            if rows._bytes > MAX_RESULT_BYTES { return {kind=.Result_Limit} }
            append(&rows.columns, Column{strings.clone(name, rows._allocator), PQftype(result, i32(i))})
        }
    }
    if width != len(rows.columns) { return {kind=.Mapping} }
    for row in 0..<PQntuples(result) {
        if rows.count == MAX_ROWS { return {kind=.Result_Limit} }
        for col in 0..<width {
            cell := Cell{is_null=PQgetisnull(result, row, i32(col)) != 0}
            if !cell.is_null {
                length := int(PQgetlength(result, row, i32(col)))
                rows._bytes += length
                if rows._bytes > MAX_RESULT_BYTES { return {kind=.Result_Limit} }
                bytes := (cast([^]byte)PQgetvalue(result, row, i32(col)))[:length]
                if rows.columns[col].oid == 17 {
                    if length < 2 || string(bytes[:2]) != "\\x" { return {kind=.Mapping} }
                    decoded, ok := hex.decode(bytes[2:], rows._allocator)
                    if !ok { delete(decoded, rows._allocator); return {kind=.Mapping} }
                    cell.data = string(decoded)
                } else { cell.data = strings.clone(string(bytes), rows._allocator) }
            }
            append(&rows.cells, cell)
        }
        rows.count += 1
    }
    return {}
}

begin :: proc(s: ^Session) -> Failure {
    if s == nil || s.connection == nil || s.connection^ == nil { return {kind=.Unavailable} }
    if s._transaction || PQtransactionStatus(s.connection^) != 0 { return {kind=.Invalid_State} }
    rows, failure := execute_rows(s, "BEGIN", nil, context.allocator, true)
    destroy_rows(&rows)
    if failure.kind == .None { s._transaction = true; s._failed = false }
    return failure
}
commit :: proc(s: ^Session) -> Failure {
    if s == nil || !s._transaction { return {kind=.Invalid_State} }
    if s._failed { rollback(s); return {kind=.Invalid_State} }
    if platform.monotonic_ms() >= s.deadline_ms { rollback(s); return {kind=.Deadline} }
    rows, failure := execute_rows(s, "COMMIT", nil, context.allocator, true)
    destroy_rows(&rows)
    s._transaction = false
    s._failed = false
    if failure.kind == .Unavailable || failure.kind == .Deadline {
        close(s.connection)
        return {kind=.Commit_Unknown}
    }
    if s.connection^ != nil && PQtransactionStatus(s.connection^) != 0 { close(s.connection) }
    return failure
}
// Cleanup has its own 100 ms budget, even after the operation deadline expires.
rollback :: proc(s: ^Session) -> Failure {
    if s == nil || !s._transaction { return {kind=.Invalid_State} }
    original_deadline := s.deadline_ms
    s.deadline_ms = platform.monotonic_ms() + 100
    rows, failure := execute_rows(s, "ROLLBACK", nil, context.allocator, true)
    destroy_rows(&rows)
    s.deadline_ms = original_deadline
    s._transaction = false
    s._failed = false
    if s.connection != nil && s.connection^ != nil && (failure.kind != .None || PQtransactionStatus(s.connection^) != 0) { close(s.connection) }
    return failure
}
// Call at the boundary of a borrowed connection. Unfinished transactions are
// rolled back; a connection in any other non-idle protocol state is discarded.
finish :: proc(s: ^Session) -> Failure {
    if s == nil || s.connection == nil { return {kind=.Invalid_State} }
    if s._transaction { rollback(s); return {kind=.Invalid_State} }
    if s.connection^ != nil && PQtransactionStatus(s.connection^) != 0 { close(s.connection); return {kind=.Invalid_State} }
    return {}
}
Transaction_Work :: proc(s: ^Session, data: rawptr) -> Failure
transaction :: proc(s: ^Session, work: Transaction_Work, data: rawptr = nil) -> Failure {
    if work == nil { return {kind=.Invalid_Input} }
    if failure := begin(s); failure.kind != .None { return failure }
    failure := work(s, data)
    if failure.kind != .None { rollback(s); return failure }
    return commit(s)
}
