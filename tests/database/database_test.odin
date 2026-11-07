package database_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import db "../../dagda/db"
import platform "../../dagda/platform"

connect :: proc(t: ^testing.T) -> ^db.Conn {
    info := os.get_env("DAGDA_DATABASE_URL", context.allocator)
    defer delete(info)
    cs := strings.clone_to_cstring(info, context.allocator)
    defer delete(cs)
    connection, error := db.connect(cs, platform.monotonic_ms()+5000)
    testing.expect_value(t, error, .None)
    return connection
}
execute :: proc(t: ^testing.T, s: ^db.Session, sql: string, params: []db.Param = nil) {
    _, failure := db.exec(s, sql, params)
    testing.expect(t, failure.kind == .None, sql)
}
scalar :: proc(t: ^testing.T, s: ^db.Session, sql: string) -> i64 {
    rows, failure := db.query_rows(s, sql)
    defer db.destroy_rows(&rows)
    testing.expect_value(t, failure.kind, .None)
    value: struct { value: i64 }
    testing.expect_value(t, db.scan(&rows, 0, &value).kind, .None)
    return value.value
}

@(test)
parameters_rows_and_mapping :: proc(t: ^testing.T) {
    connection := connect(t)
    if connection == nil { return }
    defer db.close(&connection)
    session := db.Session{connection=&connection, deadline_ms=platform.monotonic_ms()+5000}
    rows, error := db.query_rows(&session, `SELECT $1::text AS label, $2::bigint AS id,
        true AS enabled, $3::text AS note, ''::text AS empty,
        '00000000-0000-4000-8000-000000000001'::uuid AS uuid,
        '2026-11-06 12:34:56.123456+00'::timestamptz AS created,
        12345678901234567890.123456789::numeric AS amount,
        '{"ok":true}'::jsonb AS data, '\x0001ff'::bytea AS bytes`,
        { {text="'; DROP TABLE anything; --"}, {text="9223372036854775807"}, db.null_param() })
    defer db.destroy_rows(&rows)
    testing.expect_value(t, error.kind, .None)
    DTO :: struct {
        label: string, id: i64, enabled: bool, note: db.Nullable(string), empty: string,
        uuid: db.UUID, created: db.Timestamp, amount: db.Decimal, data: db.JSON, bytes: []byte,
    }
    value: DTO
    testing.expect_value(t, db.scan(&rows, 0, &value).kind, .None)
    testing.expect_value(t, value.label, "'; DROP TABLE anything; --")
    testing.expect_value(t, value.id, max(i64))
    testing.expect(t, value.enabled && !value.note.valid && value.empty == "")
    testing.expect_value(t, string(value.amount), "12345678901234567890.123456789")
    testing.expect_value(t, string(value.uuid), "00000000-0000-4000-8000-000000000001")
    testing.expect(t, strings.contains(string(value.created), ".123456"))
    testing.expect(t, strings.contains(string(value.data), "true"))
    testing.expect(t, len(value.bytes) == 3 && value.bytes[0] == 0 && value.bytes[2] == 255)
    // Another query and freeing its result cannot invalidate the first result.
    testing.expect_value(t, scalar(t, &session, "SELECT 7::bigint AS value"), 7)
    testing.expect_value(t, value.label, "'; DROP TABLE anything; --")
    empty, empty_error := db.query_rows(&session, "SELECT 1 AS value WHERE false")
    defer db.destroy_rows(&empty)
    testing.expect_value(t, empty_error.kind, .None)
    testing.expect_value(t, empty.count, 0)
    testing.expect_value(t, db.scan(&empty, 0, &value).kind, .Mapping)
    bad, bad_error := db.query_rows(&session, "SELECT $1::text", {{text="a\x00b"}})
    defer db.destroy_rows(&bad)
    testing.expect_value(t, bad_error.kind, .Invalid_Input)
    testing.expect_value(t, scalar(t, &session, "SELECT 8::bigint AS value"), 8)
}

@(test)
transactions_constraints_and_reuse :: proc(t: ^testing.T) {
    connection := connect(t)
    if connection == nil { return }
    defer db.close(&connection)
    s := db.Session{connection=&connection, deadline_ms=platform.monotonic_ms()+5000}
    execute(t, &s, "CREATE TEMP TABLE balances (id bigint PRIMARY KEY, value bigint NOT NULL CHECK (value >= 0))")
    execute(t, &s, "INSERT INTO balances VALUES (1, 100), (2, 0)")
    testing.expect_value(t, db.begin(&s).kind, .None)
    affected, failure := db.exec(&s, "UPDATE balances SET value=value-$1::bigint WHERE id=1", {{text="25"}})
    testing.expect_value(t, failure.kind, .None)
    testing.expect_value(t, affected, 1)
    execute(t, &s, "UPDATE balances SET value=value+25 WHERE id=2")
    testing.expect_value(t, db.commit(&s).kind, .None)
    testing.expect_value(t, scalar(t, &s, "SELECT value FROM balances WHERE id=1"), 75)
    testing.expect_value(t, scalar(t, &s, "SELECT value FROM balances WHERE id=2"), 25)
    testing.expect_value(t, db.begin(&s).kind, .None)
    execute(t, &s, "UPDATE balances SET value=0 WHERE id=1")
    _, failure = db.exec(&s, "UPDATE balances SET value=-1 WHERE id=2")
    testing.expect_value(t, failure.kind, .Constraint)
    testing.expect_value(t, db.state_code(&failure), "23514")
    // Ignoring a query error must never turn COMMIT's implicit rollback into success.
    testing.expect_value(t, db.commit(&s).kind, .Invalid_State)
    testing.expect_value(t, scalar(t, &s, "SELECT value FROM balances WHERE id=1"), 75)
    testing.expect_value(t, db.begin(&s).kind, .None)
    execute(t, &s, "UPDATE balances SET value=0 WHERE id=1")
    testing.expect_value(t, db.finish(&s).kind, .Invalid_State)
    testing.expect_value(t, scalar(t, &s, "SELECT value FROM balances WHERE id=1"), 75)
    testing.expect_value(t, db.finish(&s).kind, .None)
    _, failure = db.exec(&s, "INSERT INTO balances VALUES (1, 1)")
    testing.expect_value(t, db.state_code(&failure), "23505")
    testing.expect_value(t, scalar(t, &s, "SELECT 1::bigint AS value"), 1)
    // Failed deferred constraints at COMMIT have a known, structured outcome.
    execute(t, &s, "CREATE TEMP TABLE deferred_unique (value int UNIQUE DEFERRABLE INITIALLY DEFERRED)")
    testing.expect_value(t, db.begin(&s).kind, .None)
    execute(t, &s, "INSERT INTO deferred_unique VALUES (1), (1)")
    failure = db.commit(&s)
    testing.expect_value(t, failure.kind, .Constraint)
    testing.expect_value(t, scalar(t, &s, "SELECT count(*) AS value FROM deferred_unique"), 0)
}

@(test)
limits_cancellation_and_unknown_commit :: proc(t: ^testing.T) {
    connection := connect(t)
    if connection == nil { return }
    defer db.close(&connection)
    s := db.Session{connection=&connection, deadline_ms=platform.monotonic_ms()+5000}
    rows, failure := db.query_rows(&s, "SELECT generate_series(1,129) AS value")
    testing.expect(t, len(rows.cells) == 0 && len(rows.columns) == 0 && rows.count == 0)
    db.destroy_rows(&rows)
    testing.expect_value(t, failure.kind, .Result_Limit)
    testing.expect(t, connection == nil)
    connection = connect(t)
    s = {connection=&connection, deadline_ms=platform.monotonic_ms()+5000}
    rows, failure = db.query_rows(&s, "SELECT repeat('x',65537) AS value")
    testing.expect(t, len(rows.cells) == 0 && len(rows.columns) == 0 && rows.count == 0)
    db.destroy_rows(&rows)
    testing.expect_value(t, failure.kind, .Result_Limit)
    testing.expect(t, connection == nil)
    connection = connect(t)
    s = {connection=&connection, deadline_ms=platform.monotonic_ms()+100}
    _, failure = db.exec(&s, "SELECT pg_sleep(1)")
    testing.expect_value(t, failure.kind, .Deadline)
    testing.expect(t, connection == nil)
    connection = connect(t)
    s = {connection=&connection, deadline_ms=platform.monotonic_ms()+5000}
    testing.expect_value(t, scalar(t, &s, "SELECT 9::bigint AS value"), 9)
    execute(t, &s, "CREATE TEMP TABLE delayed_commit (id int)")
    execute(t, &s, `CREATE FUNCTION pg_temp.delay_commit() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN PERFORM pg_sleep(1); RETURN NEW; END $$`)
    execute(t, &s, `CREATE CONSTRAINT TRIGGER delayed AFTER INSERT ON delayed_commit
        DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION pg_temp.delay_commit()`)
    testing.expect_value(t, db.begin(&s).kind, .None)
    execute(t, &s, "INSERT INTO delayed_commit VALUES (1)")
    s.deadline_ms = platform.monotonic_ms()+100
    failure = db.commit(&s)
    testing.expect_value(t, failure.kind, .Commit_Unknown)
    testing.expect(t, connection == nil)
    fmt.println("PASS result limits, query cancellation, and uncertain commit discard connections")
}

@(test)
partial_results_and_protocol_cleanup :: proc(t: ^testing.T) {
    connection := connect(t)
    if connection == nil { return }
    defer db.close(&connection)
    s := db.Session{connection=&connection, deadline_ms=platform.monotonic_ms()+5000}
    rows, failure := db.query_rows(&s, "SELECT 10/(3-i) AS value FROM generate_series(1,3) i")
    testing.expect_value(t, failure.kind, .Query)
    testing.expect_value(t, db.state_code(&failure), "22012")
    testing.expect(t, rows.count == 0 && len(rows.cells) == 0)
    db.destroy_rows(&rows)
    testing.expect_value(t, scalar(t, &s, "SELECT 1::bigint AS value"), 1)
    // COPY is explicitly unsupported and must not leave libpq awaiting a stream.
    _, failure = db.exec(&s, "COPY (SELECT 1) TO STDOUT")
    testing.expect_value(t, failure.kind, .Invalid_State)
    testing.expect(t, connection == nil)
    connection = connect(t)
    s = {connection=&connection, deadline_ms=platform.monotonic_ms()+5000}
    for i in 0..<32 { testing.expect_value(t, scalar(t, &s, "SELECT 1::bigint AS value"), 1) }
    rows, failure = db.query_rows(&s, "SELECT 1")
    db.destroy_rows(&rows)
    testing.expect_value(t, failure.kind, .Result_Limit)
    testing.expect_value(t, db.finish(&s).kind, .None)
    s = {connection=&connection, deadline_ms=platform.monotonic_ms()+5000}
    testing.expect_value(t, scalar(t, &s, "SELECT 2::bigint AS value"), 2)
}
