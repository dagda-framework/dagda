# Database API (M2 foundation)

`dagda/db` now supports parameterized commands, owned row sets, typed struct
mapping, structured SQLSTATE errors, and explicit transactions. HTTP applications
use `http.database` to run a multi-query operation on an existing bounded worker.
The worker owns its connection throughout that operation.

This is the first M2 slice. Migrations, seeds tooling, general connection-pool
leasing outside the HTTP worker pool, repository/resource generation, and invoice
CRUD remain subsequent work. The existing two-worker/eight-slot runtime budget
has not changed.

## Run work from an HTTP handler

```odin
import "core:encoding/json"
import db "path/to/dagda/db"
import http "path/to/dagda/http"

get_account :: proc(c: ^http.Context) {
    // Validate input first. Work gets copied bytes, never the HTTP Context.
    http.database(c, account_work, transmute([]byte)"1")
}

Account :: struct { id: i64, name: string }
account_work :: proc(s: ^db.Session, input: []byte) -> (string, db.Failure) {
    rows, failure := db.query_rows(s,
        "SELECT id, name FROM accounts WHERE id=$1::bigint",
        {{text=string(input)}})
    defer db.destroy_rows(&rows)
    if failure.kind != .None { return "", failure }
    if rows.count == 0 { return `{"found":false}`, {} }
    account: Account
    if failure := db.scan(&rows, 0, &account); failure.kind != .None {
        return "", failure
    }
    // Encode while account still borrows the owned rows.
    bytes, error := json.marshal(account, {spec=.JSON})
    if error != nil { return "", {kind=.Mapping} }
    return string(bytes), {}
}
```

Callbacks execute synchronously on a database worker. Never call HTTP response
procedures from them, retain the session/input, or share the connection across
threads. A callback may issue multiple queries or a transaction. The request
remains pending while the event loop handles other clients.

The result is already-encoded JSON, capped at 8 KiB. Input is copied into the
reserved slot and capped at 8 KiB. Worker scratch storage is released after the
result is copied; the result callback runs on the HTTP loop after the slot is
released. The optional callback receives `(c, body, failure)` and may translate
application-specific constraints into public errors. Raw SQL errors are never
included in default HTTP responses. See the test-only transfer example in
[`examples/api/database.odin`](../examples/api/database.odin).

The existing `http.query_text` API remains available. The in-process HTTP test
client explicitly rejects live database work; database integration tests use a
real isolated PostgreSQL instance.

## Queries and ownership

- `db.query_rows(session, sql, parameters)` returns `(Rows, Failure)`.
- `db.exec(session, sql, parameters)` returns `(affected_rows, Failure)` and frees
  the result internally. `INSERT ... RETURNING` belongs in `query_rows`.
- `db.Param{text="..."}` supplies a positional text value; `db.null_param()` is
  SQL NULL. An empty string is a non-null value. Use explicit SQL casts where
  PostgreSQL cannot infer a parameter type. NUL bytes in SQL/text parameters are
  rejected before execution.
- Bytea parameters use PostgreSQL hex syntax (for example `\x0001ff`) with a
  `$1::bytea` cast. SQL identifiers are application-authored, never client input.
- `db.destroy_rows(&rows)` frees owned column names, cells, and arrays. Call once,
  usually with `defer`, including on error. Errors return an empty, safe-to-destroy
  result; partial rows are discarded.

Rows are copied out of libpq before its result is freed. They survive subsequent
queries and connection closure. Do not copy a `Rows` value and destroy both copies.
`query_rows` accepts an optional allocator, defaulting to `context.allocator`.
Inside a worker this is operation-scoped scratch storage. Keeping a result past
that operation requires explicitly allocating/copying it into longer-lived storage
and a separate ownership contract; HTTP handlers should return serialized DTOs.

## Typed mapping

`db.scan(&rows, index, &destination)` maps column names to struct fields. A
`db:"column_name"` field tag overrides the name. Columns/fields must match exactly;
missing, duplicate, extra, unsupported, or out-of-range mappings fail with
`.Mapping`. The destination changes only when the complete row succeeds. Zero
rows are a successful query; check `rows.count` before scanning.

| PostgreSQL value | Odin destination |
| --- | --- |
| smallint/integer/bigint | Signed/unsigned integers up to 64 bits, with range checks |
| boolean | `bool` |
| text/varchar/char/name | `string` |
| uuid | `db.UUID` (distinct string) |
| timestamptz | `db.Timestamp` (distinct string preserving offset and precision) |
| numeric | `db.Decimal` (exact distinct string, including PostgreSQL special values) |
| json/jsonb | `db.JSON` (distinct string) |
| bytea | `[]byte`, decoded from PostgreSQL's default hex output |
| SQL NULL | `db.Nullable(T){valid=false}` |

Non-null nullable values have `valid=true` and their mapped `value`. Empty text,
zero, and false are distinct from NULL. Mapped strings/byte slices borrow the
owned result. Clone them if they must outlive `Rows`. Timestamp wrappers do not
perform date arithmetic or normalize offsets; decimal values never silently
convert to floats. Unsupported types (including floats, arrays, composites, and
custom enums) require an explicit supported SQL cast or return `.Mapping`.

## Transactions

```odin
transfer_work :: proc(s: ^db.Session, input: []byte) -> (string, db.Failure) {
    // Parse/validate input into operation-owned data here.
    failure := db.transaction(s, transfer_queries)
    if failure.kind != .None { return "", failure }
    return `{"transferred":true}`, {}
}
transfer_queries :: proc(s: ^db.Session, _: rawptr) -> db.Failure {
    _, failure := db.exec(s, "UPDATE accounts SET balance=balance-25 WHERE id=1")
    if failure.kind != .None { return failure }
    _, failure = db.exec(s, "UPDATE accounts SET balance=balance+25 WHERE id=2")
    return failure
}
```

`db.transaction` begins, invokes the callback, and commits on success. Callback
failure causes rollback. Alternatively use `begin`, `commit`, and `rollback`
explicitly. Nested transactions/savepoints are not implemented. Use transaction
helpers exclusively; do not send BEGIN/COMMIT/ROLLBACK as ordinary SQL or manually
end the transaction inside a `transaction` callback.

A failed query poisons the active transaction. Ignoring its error and calling
`commit` rolls back and returns `.Invalid_State`. Commit-time constraint errors
return their SQLSTATE. A transport failure/deadline while attempting COMMIT
returns `.Commit_Unknown` and discards the connection; it does not claim rollback.
There are no automatic retries. Applications must use idempotency or reconciliation
when an outcome is uncertain.

Worker cleanup calls `db.finish` on every callback return. An abandoned transaction
is rolled back and cannot produce a successful response; a non-idle connection
that cannot be cleaned is discarded. Rollback has a separate 100 ms cleanup
budget, and cancellation may consume up to another 100 ms before closing the
connection. A failed cleanup never permits dirty connection reuse.

Outside HTTP workers, create a `Session{connection=&connection, deadline_ms=...}`
for an exclusively owned connection and call `finish` before releasing it. Sessions
are borrowed operation handles, not a connection pool. Application startup
configuration restricts connection targets to local sockets/numeric loopback.

## Errors and bounds

`Failure` contains a kind and a fixed five-byte SQLSTATE (when PostgreSQL supplied
one), accessible with `db.state_code(&failure)`. It owns no borrowed libpq memory
and includes no server message, SQL, parameters, constraint detail, or credentials.
Kinds distinguish constraints, serialization failures, deadlocks, cancellation,
availability, deadline, invalid input/state, mapping, result limits, and unknown
commit outcome. HTTP applications choose which business errors to expose.

Current limits per query are 32 parameters, 16 KiB combined SQL/parameter storage,
128 rows, 32 columns, and 64 KiB of column-name/value bytes. Bytea's hex wire text
counts toward the byte cap. A session allows 32 data commands; transaction control
and cleanup have separate accounting. Results use libpq single-row mode and are
fully drained before reuse; unsupported COPY/protocol modes and exceeded result
limits cancel/discard the connection.

The result cap bounds retained application data, not every allocation inside
libpq: one individual server row may be buffered before its size is checked.
Use explicit SQL projections, LIMIT, and schema constraints for large data.
Callbacks are trusted application code; CPU loops and unrelated blocking calls
are not preempted by a request deadline. Query/connect waits enforce the deadline.

The implementation follows PostgreSQL's [asynchronous processing contract](https://www.postgresql.org/docs/current/libpq-async.html)
and [parameter/result interfaces](https://www.postgresql.org/docs/current/libpq-exec.html).

## Verification

`dagda/db` has pure Odin tests for SQLSTATE classification, nullable values, numeric
range checking, column names, and atomic mapping. `tests/database` contains Odin
tests against PostgreSQL for typed rows, parameter separation, ownership,
commit/rollback/reuse, deferred constraints, partial results, limits, cancellation,
unsupported COPY, and an interrupted COMMIT. The Python driver only owns external
service/process lifecycle and HTTP checks. Memory-tracker warnings fail this gate.

`python3 tests/database.py` uses the built example API and its own temporary
PostgreSQL cluster. It also verifies worker transactions over HTTP: successful
transfers, constraint rollback, abandoned-transaction cleanup, responsive liveness,
deadlines, and subsequent connection reuse. The complete gate is included in
`./scripts/test.sh`.

The full regression suite passed on 2026-11-06: 45 Odin tests (including four
PostgreSQL tests), seven Python harness tests, and seven integration suites. No
Odin memory warnings were reported. See the
[validation record](validation/2026-11-06-database.json).
