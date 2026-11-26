package sdlhost

import "core:sync"
import "core:testing"
import sdl "vendor:sdl3"

@(test)
test_rebuild_handle_lifecycle :: proc(t: ^testing.T) {
	sync.mutex_guard(&sdl_test_mu)
	testing.expect_value(t, request_rebuild({}), Rebuild_Result.Stale)
	testing.expect_value(t, request_rebuild({id = 999999, event_type = 1}), Rebuild_Result.Stale)

	if !sdl.Init({.VIDEO}) {
		return
	}
	defer sdl.Quit()
	handle, registered := rebuild_register()
	testing.expect(t, registered)
	testing.expect(t, handle.id != 0 && handle.event_type != 0)
	testing.expect_value(t, request_rebuild(handle), Rebuild_Result.Posted)
	// Drain the queued wake so it cannot leak into another test.
	ev: sdl.Event
	for sdl.PollEvent(&ev) {
	}
	rebuild_mark_closing(handle)
	testing.expect_value(t, request_rebuild(handle), Rebuild_Result.Closed)
	rebuild_unregister(handle)
	testing.expect_value(t, request_rebuild(handle), Rebuild_Result.Stale)
	// A copy with a forged event type never matches a live entry.
	other, other_registered := rebuild_register()
	testing.expect(t, other_registered)
	defer rebuild_unregister(other)
	forged := Rebuild_Handle{id = other.id, event_type = other.event_type + 1}
	testing.expect_value(t, request_rebuild(forged), Rebuild_Result.Stale)
}

@(test)
test_rebuild_requests_coalesce :: proc(t: ^testing.T) {
	sync.mutex_guard(&sdl_test_mu)
	if !sdl.Init({.VIDEO}) {
		return
	}
	defer sdl.Quit()
	handle, registered := rebuild_register()
	testing.expect(t, registered)
	defer rebuild_unregister(handle)

	count_wakes :: proc(handle: Rebuild_Handle) -> int {
		count := 0
		ev: sdl.Event
		for sdl.PollEvent(&ev) {
			if u32(ev.type) == handle.event_type {
				count += 1
			}
		}
		return count
	}

	// A burst of 100 requests queues exactly one wake.
	for i in 0 ..< 100 {
		testing.expect_value(t, request_rebuild(handle), Rebuild_Result.Posted)
	}
	testing.expect_value(t, count_wakes(handle), 1)

	// Once the host consumes that wake, the next request queues
	// a fresh one (the snapshot-then-publish-101 ordering).
	rebuild_consume_pending(handle)
	testing.expect_value(t, request_rebuild(handle), Rebuild_Result.Posted)
	testing.expect_value(t, count_wakes(handle), 1)
}
