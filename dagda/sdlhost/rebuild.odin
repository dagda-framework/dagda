package sdlhost

import "core:sync"
import sdl "vendor:sdl3"

// A thread-safe request to rebuild one specific live SDL host
// window. The app acquires the window's Rebuild_Handle while
// its sdlhost.run call is live (through App.rebuild_handle or
// the App.on_ready callback, both on the host thread) and may
// copy it to a worker. The worker publishes its model update
// under the app's own synchronization, then calls
// request_rebuild. The host wakes on its owning thread, calls
// the app's view or canvas builder again through the normal
// rebuild path (including focus and text-session
// reconciliation), and presents the new frame.
//
// Lifetime: a handle names one run of one window by generation.
// Copying it is safe, but it is only meaningful while that
// window is live. After the window closes, request_rebuild
// returns Closed (while shutdown is in progress) or Stale
// (once that generation is gone); a stale handle can never
// wake a later window, because generations are never reused.
Rebuild_Handle :: struct {
	id:         u64,
	event_type: u32,
}

Rebuild_Result :: enum {
	Posted, // a wake was queued for the live window
	Closed, // the window is shutting down
	Stale,  // no live window has this generation
}

@(private)
Rebuild_Entry :: struct {
	id:         u64,
	event_type: u32,
	closing:    bool,
}

@(private)
rebuild_registry_mutex: sync.Mutex
@(private)
rebuild_next_id: u64 = 1
// Fixed storage: the registry itself never allocates, so a
// request racing shutdown cannot fail on allocation either.
@(private)
rebuild_live: [64]Rebuild_Entry
@(private)
rebuild_live_count: int

@(private)
rebuild_register :: proc() -> (Rebuild_Handle, bool) {
	event_type := sdl.RegisterEvents(1)
	if event_type == 0 {
		return {}, false
	}
	sync.mutex_lock(&rebuild_registry_mutex)
	if rebuild_live_count >= len(rebuild_live) {
		sync.mutex_unlock(&rebuild_registry_mutex)
		return {}, false
	}
	id := rebuild_next_id
	rebuild_next_id += 1
	rebuild_live[rebuild_live_count] = {id = id, event_type = u32(event_type)}
	rebuild_live_count += 1
	sync.mutex_unlock(&rebuild_registry_mutex)
	return {id = id, event_type = u32(event_type)}, true
}

@(private)
rebuild_find :: proc(id: u64) -> (Rebuild_Entry, bool) {
	for entry in rebuild_live[:rebuild_live_count] {
		if entry.id == id {
			return entry, true
		}
	}
	return {}, false
}

@(private)
rebuild_mark_closing :: proc(handle: Rebuild_Handle) {
	sync.mutex_lock(&rebuild_registry_mutex)
	for &entry in rebuild_live[:rebuild_live_count] {
		if entry.id == handle.id {
			entry.closing = true
		}
	}
	sync.mutex_unlock(&rebuild_registry_mutex)
}

@(private)
rebuild_unregister :: proc(handle: Rebuild_Handle) {
	sync.mutex_lock(&rebuild_registry_mutex)
	for entry, i in rebuild_live[:rebuild_live_count] {
		if entry.id == handle.id {
			rebuild_live_count -= 1
			rebuild_live[i] = rebuild_live[rebuild_live_count]
			break
		}
	}
	sync.mutex_unlock(&rebuild_registry_mutex)
}

// request_rebuild is safe to call from any thread, including
// concurrently with host shutdown. Multiple requests may be
// coalesced into one presented frame; a host that keeps
// receiving them eventually presents the last published update.
request_rebuild :: proc(handle: Rebuild_Handle) -> Rebuild_Result {
	if handle.id == 0 || handle.event_type == 0 {
		return .Stale
	}
	sync.mutex_lock(&rebuild_registry_mutex)
	entry, found := rebuild_find(handle.id)
	if !found {
		sync.mutex_unlock(&rebuild_registry_mutex)
		return .Stale
	}
	if entry.closing || entry.event_type != handle.event_type {
		result := entry.closing ? Rebuild_Result.Closed : Rebuild_Result.Stale
		sync.mutex_unlock(&rebuild_registry_mutex)
		return result
	}
	// The registry mutex is held across the post, synchronizing
	// with teardown: a request cannot validate against the old
	// lifetime, wait, and then post into a later one.
	ev: sdl.Event
	ev.type = sdl.EventType(handle.event_type)
	ev.user.windowID = 0
	ev.user.code = 0
	ev.user.data1 = rawptr(uintptr(handle.id))
	ev.user.data2 = nil
	posted := sdl.PushEvent(&ev)
	sync.mutex_unlock(&rebuild_registry_mutex)
	return posted ? .Posted : .Closed
}
