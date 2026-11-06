package dagda_db

// Small ABI surface taken from PostgreSQL's public libpq-fe.h. The client
// implementation remains libpq; Dagda does not implement the wire protocol.
foreign import libpq "system:pq"

Conn :: struct {}
Result :: struct {}
Cancel :: struct {}
Conninfo_Option :: struct {
    keyword, envvar, compiled, val, label, dispchar: cstring,
    dispsize: i32,
}

foreign libpq {
    PQconninfoParse :: proc(conninfo: cstring, error_message: ^cstring) -> [^]Conninfo_Option ---
    PQconninfoFree :: proc(options: [^]Conninfo_Option) ---
    PQfreemem :: proc(pointer: rawptr) ---
    PQconnectStart :: proc(conninfo: cstring) -> ^Conn ---
    PQconnectPoll :: proc(conn: ^Conn) -> i32 ---
    PQsetnonblocking :: proc(conn: ^Conn, enabled: i32) -> i32 ---
    PQstatus :: proc(conn: ^Conn) -> i32 ---
    PQsocket :: proc(conn: ^Conn) -> i32 ---
    PQfinish :: proc(conn: ^Conn) ---
    PQsendQueryParams :: proc(conn: ^Conn, query: cstring, count: i32,
        types: [^]u32, values: [^]cstring, lengths: [^]i32,
        formats: [^]i32, result_format: i32) -> i32 ---
    PQflush :: proc(conn: ^Conn) -> i32 ---
    PQconsumeInput :: proc(conn: ^Conn) -> i32 ---
    PQisBusy :: proc(conn: ^Conn) -> i32 ---
    PQgetResult :: proc(conn: ^Conn) -> ^Result ---
    PQresultStatus :: proc(result: ^Result) -> i32 ---
    PQntuples :: proc(result: ^Result) -> i32 ---
    PQgetisnull :: proc(result: ^Result, row: i32, column: i32) -> i32 ---
    PQgetvalue :: proc(result: ^Result, row: i32, column: i32) -> cstring ---
    PQgetlength :: proc(result: ^Result, row: i32, column: i32) -> i32 ---
    PQclear :: proc(result: ^Result) ---
    PQcancelCreate :: proc(conn: ^Conn) -> ^Cancel ---
    PQcancelStart :: proc(cancel: ^Cancel) -> i32 ---
    PQcancelPoll :: proc(cancel: ^Cancel) -> i32 ---
    PQcancelSocket :: proc(cancel: ^Cancel) -> i32 ---
    PQcancelFinish :: proc(cancel: ^Cancel) ---
}
