package dagda_runtime

import "core:mem/virtual"
import "core:nbio"
import "core:strings"
import "core:sync"
import "core:thread"
import db "../db"
import platform "../platform"

CAPACITY :: 8
WORKERS :: 2
ARENA_BYTES :: 32 * 1024

State :: enum { Free, Queued, Running, Ready }

Work :: struct {
    query: cstring,
    parameters: []cstring,
    deadline_ms: i64,
}

valid_work :: proc(work: Work) -> bool {
    if work.query == nil || len(string(work.query)) == 0 || len(string(work.query)) > 4096 || len(work.parameters) > 8 { return false }
    size := len(string(work.query))
    for value in work.parameters { size += len(string(value)) + 1 }
    return size <= 8192
}

Slot :: struct {
    state: State, // guarded by Pool.mu
    work: Work,
    arena: virtual.Arena,
    storage: [ARENA_BYTES]byte,
    status: int,
    error: db.Error,
    body: string,
    completion: ^nbio.Operation, // allocated on the destination event loop
    transport_data: rawptr, // accessed only by the event loop
}

Worker :: struct {
    pool: ^Pool,
    thread: ^thread.Thread,
    connection: ^db.Conn, // exclusively owned by this worker
}

Pool :: struct {
    mu: sync.Mutex,
    available: sync.Cond,
    slots: [CAPACITY]Slot,
    queue: [CAPACITY]int,
    head, tail, queued, inflight: int,
    stopping: bool,
    conninfo: cstring, // application-owned until stop() joins every worker
    workers: [WORKERS]Worker,
}

start :: proc(p: ^Pool, conninfo: cstring) -> bool {
    p.conninfo = conninfo
    for &worker in p.workers {
        worker.pool = p
        worker.thread = thread.create_and_start_with_poly_data(&worker, worker_main)
        if worker.thread == nil {
            stop(p)
            return false
        }
    }
    return true
}

// Called on the event loop. A slot reserves both dispatch and completion space.
reserve :: proc(p: ^Pool, work: Work) -> ^Slot {
    if !valid_work(work) { return nil }
    sync.mutex_lock(&p.mu)
    defer sync.mutex_unlock(&p.mu)
    if p.stopping || p.inflight == CAPACITY { return nil }
    for &slot in p.slots {
        if slot.state != .Free { continue }
        slot.work = work
        slot.status = 500
        slot.error = .None
        slot.body = ""
        slot.completion = nil
        slot.transport_data = nil
        slot.arena = {}
        if virtual.arena_init_buffer(&slot.arena, slot.storage[:]) != nil { return nil }
        allocator := virtual.arena_allocator(&slot.arena)
        slot.work.query = strings.clone_to_cstring(string(work.query), allocator)
        slot.work.parameters = make([]cstring, len(work.parameters), allocator)
        for value, i in work.parameters {
            if value != nil { slot.work.parameters[i] = strings.clone_to_cstring(string(value), allocator) }
        }
        slot.state = .Queued
        p.inflight += 1
        return &slot
    }
    return nil
}

// Publish only after the adapter has installed completion and transport_data.
submit :: proc(p: ^Pool, slot: ^Slot) {
    sync.mutex_lock(&p.mu)
    defer sync.mutex_unlock(&p.mu)
    assert(slot.state == .Queued && slot.completion != nil)
    index := -1
    for &candidate, i in p.slots {
        if &candidate == slot { index = i; break }
    }
    assert(index >= 0 && p.queued < CAPACITY)
    p.queue[p.tail] = index
    p.tail = (p.tail + 1) % CAPACITY
    p.queued += 1
    sync.cond_signal(&p.available)
}

// The event loop calls this only after copying response bytes into transport
// storage. The completed worker never touches the slot after publishing it.
release :: proc(p: ^Pool, slot: ^Slot) {
    sync.mutex_lock(&p.mu)
    defer sync.mutex_unlock(&p.mu)
    assert(slot.state == .Ready)
    slot.state = .Free
    slot.body = ""
    slot.transport_data = nil
    slot.completion = nil
    p.inflight -= 1
}

active :: proc(p: ^Pool) -> int {
    sync.mutex_lock(&p.mu)
    defer sync.mutex_unlock(&p.mu)
    return p.inflight
}

stop :: proc(p: ^Pool) {
    sync.mutex_lock(&p.mu)
    p.stopping = true
    sync.cond_broadcast(&p.available)
    sync.mutex_unlock(&p.mu)
    for &worker in p.workers {
        if worker.thread != nil {
            thread.destroy(worker.thread)
            worker.thread = nil
        }
    }
}

worker_main :: proc(worker: ^Worker) {
    p := worker.pool
    defer db.close(&worker.connection)
    for {
        sync.mutex_lock(&p.mu)
        for p.queued == 0 && !p.stopping { sync.cond_wait(&p.available, &p.mu) }
        if p.queued == 0 && p.stopping { sync.mutex_unlock(&p.mu); return }
        slot := &p.slots[p.queue[p.head]]
        p.head = (p.head + 1) % CAPACITY
        p.queued -= 1
        slot.state = .Running
        sync.mutex_unlock(&p.mu)

        execute(worker, slot)

        sync.mutex_lock(&p.mu)
        slot.state = .Ready
        completion := slot.completion
        sync.mutex_unlock(&p.mu)
        // Publication transfers ownership. Do not touch slot after this call.
        nbio.exec(completion)
    }
}

execute :: proc(worker: ^Worker, slot: ^Slot) {
    allocator := virtual.arena_allocator(&slot.arena)
    context.allocator = allocator
    context.temp_allocator = allocator
    err := db.Error.None
    if platform.monotonic_ms() >= slot.work.deadline_ms {
        err = .Deadline
    } else if worker.connection == nil {
        worker.connection, err = db.connect(worker.pool.conninfo, slot.work.deadline_ms)
    }
    if err == .None {
        slot.body, err = db.query_text(&worker.connection, slot.work.query, slot.work.parameters, slot.work.deadline_ms, allocator)
    }
    slot.error = err
    switch err {
    case .None: slot.status = 200
    case .Deadline:
        slot.status = 503
        slot.body = `{"error":{"code":"deadline_exceeded","message":"Request deadline exceeded"}}`
    case .Unavailable:
        slot.status = 503
        slot.body = `{"error":{"code":"database_unavailable","message":"Database unavailable"}}`
    case .Unexpected_Result:
        slot.status = 404
        slot.body = `{"error":{"code":"not_found","message":"Item not found"}}`
    case .Query:
        slot.status = 500
        slot.body = `{"error":{"code":"query_failed","message":"Database query failed"}}`
    }
}
