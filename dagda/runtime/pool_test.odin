package dagda_runtime

import "core:nbio"
import "core:testing"
import "core:time"
import platform "../platform"

Test_Handoff :: struct {
    pool: ^Pool,
    completed: int,
    failed: bool,
}

test_completion :: proc(op: ^nbio.Operation) {
    state := cast(^Test_Handoff)op.user_data[0]
    slot := cast(^Slot)op.user_data[1]
    // This runs on the test's event loop, after the actual worker publishes.
    if slot.state != .Ready || slot.status != 503 ||
       slot.body != `{"error":{"code":"deadline_exceeded","message":"Request deadline exceeded"}}` {
        state.failed = true
    }
    release(state.pool, slot)
    state.completed += 1
}

@(test)
bounded_worker_handoff_and_reuse :: proc(t: ^testing.T) {
    loop_error := nbio.acquire_thread_event_loop()
    if !testing.expect_value(t, loop_error, nil) { return }
    defer nbio.release_thread_event_loop()
    p := new(Pool)
    defer free(p)
    // Already-expired work exercises the real queue/threads/completion path,
    // while proving expired queued requests never attempt database connection.
    if !testing.expect(t, start(p, "invalid-connection-never-used")) { return }
    defer stop(p)
    state := Test_Handoff{pool = p}
    for batch in 0..<100 {
        for _ in 0..<CAPACITY {
            slot := reserve(p, Work{query = "SELECT 1", deadline_ms = platform.monotonic_ms() - 1})
            if !testing.expect(t, slot != nil) { return }
            completion := nbio.prep_timeout(0, test_completion)
            completion.user_data[0] = &state
            completion.user_data[1] = slot
            slot.completion = completion
            submit(p, slot)
        }
        // Completed-but-unconsumed work still occupies capacity. A worker's
        // completion cannot cause another producer to reuse borrowed storage.
        testing.expect(t, reserve(p, Work{query = "SELECT 1"}) == nil)
        expected := (batch + 1) * CAPACITY
        deadline := platform.monotonic_ms() + 5000
        for state.completed != expected && platform.monotonic_ms() < deadline {
            testing.expect(t, nbio.tick(20 * time.Millisecond) == nil)
        }
        if !testing.expect_value(t, state.completed, expected) { return }
        testing.expect_value(t, active(p), 0)
    }
    testing.expect(t, !state.failed)
}

@(test)
work_owns_query_and_parameter_bytes :: proc(t: ^testing.T) {
    p := new(Pool)
    defer free(p)
    query_bytes := [10]byte{'S','E','L','E','C','T',' ','$','1',0}
    value_bytes := [2]byte{'1',0}
    parameters := [1]cstring{cstring(raw_data(value_bytes[:]))}
    work := Work{query = cstring(raw_data(query_bytes[:])), parameters = parameters[:]}
    slot := reserve(p, work)
    if !testing.expect(t, slot != nil) { return }
    query_bytes[0] = 'X'
    value_bytes[0] = '2'
    testing.expect_value(t, string(slot.work.query), "SELECT $1")
    testing.expect_value(t, string(slot.work.parameters[0]), "1")
    // No worker was started; complete the reservation for deterministic cleanup.
    slot.state = .Ready
    release(p, slot)
    testing.expect_value(t, active(p), 0)
    testing.expect(t, !valid_work(Work{}))
}
