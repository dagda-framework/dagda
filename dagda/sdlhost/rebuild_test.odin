package sdlhost

import "core:testing"
import sdl "vendor:sdl3"

@(test)
test_rebuild_handle_lifecycle :: proc(t: ^testing.T) {
	testing.expect_value(t, request_rebuild({}), Rebuild_Result.Stale)
	testing.expect_value(t, request_rebuild({id = 999999, event_type = 1}), Rebuild_Result.Stale)

	if !sdl.Init({.VIDEO}) {
		return
	}
	defer sdl.Quit()
	handle := rebuild_register()
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
	other := rebuild_register()
	defer rebuild_unregister(other)
	forged := Rebuild_Handle{id = other.id, event_type = other.event_type + 1}
	testing.expect_value(t, request_rebuild(forged), Rebuild_Result.Stale)
}
