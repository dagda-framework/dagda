package main

import "core:encoding/json"
import "core:fmt"
import db "../../dagda/db"
import http "../../dagda/http"
import validation "../../dagda/validation"

// Test-only transfer example. The fixture creates its schema; migrations and
// application-owned resources follow in the next M2 slice.
Transfer :: struct { amount: i64, delay_ms: i64 }
transfer :: proc(c: ^http.Context) {
    input: Transfer
    if !http.decode_json(c, &input) { return }
    errors: validation.Errors
    validation.integer_range(&errors, "amount", input.amount, 1, 1000000)
    validation.integer_range(&errors, "delay_ms", input.delay_ms, 0, 2000)
    if !http.validate(c, &errors) { return }
    http.database(c, transfer_work, transmute([]byte)c.body, transfer_result)
}
transfer_work :: proc(s: ^db.Session, input: []byte) -> (string, db.Failure) {
    value: Transfer
    if json.unmarshal(input, &value, spec=.JSON) != nil { return "", {kind=.Invalid_Input} }
    if failure := db.transaction(s, transfer_queries, &value); failure.kind != .None { return "", failure }
    return `{"transferred":true}`, {}
}
transfer_queries :: proc(s: ^db.Session, data: rawptr) -> db.Failure {
    value := cast(^Transfer)data
    if value.delay_ms > 0 {
        _, failure := db.exec(s, "SELECT pg_sleep($1::double precision / 1000)", {{text=fmt.tprintf("%d", value.delay_ms)}})
        if failure.kind != .None { return failure }
    }
    amount := fmt.tprintf("%d", value.amount)
    _, failure := db.exec(s, "UPDATE dagda_m2_accounts SET balance=balance-$1::bigint WHERE id=1", {{text=amount}})
    if failure.kind != .None { return failure }
    _, failure = db.exec(s, "UPDATE dagda_m2_accounts SET balance=balance+$1::bigint WHERE id=2", {{text=amount}})
    return failure
}
transfer_result :: proc(c: ^http.Context, body: string, failure: db.Failure) {
    if failure.kind == .Constraint {
        http.respond_error(c, 409, "balance_constraint", "Transfer violates balance constraints")
    } else if failure.kind == .None {
        http.json_text(c, 200, body)
    } else {
        // Delegate to the standard public mapping without exposing SQLSTATE/data.
        http.database_result(c, body, failure)
    }
}

abandon_transaction :: proc(c: ^http.Context) { http.database(c, abandon_work) }
abandon_work :: proc(s: ^db.Session, _: []byte) -> (string, db.Failure) {
    if failure := db.begin(s); failure.kind != .None { return "", failure }
    _, failure := db.exec(s, "UPDATE dagda_m2_accounts SET balance=0 WHERE id=1")
    // Intentionally forget the transaction: the worker must roll it back.
    return `{"should_not_succeed":true}`, failure
}
