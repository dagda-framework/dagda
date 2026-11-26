package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "dagda:dagda"
import "dagda:dagda/sdlhost"
import sdl "vendor:sdl3"

// Worker-rebuild proof app. A worker thread publishes a model
// update under the app's own mutex, then asks the host to
// rebuild through the public Rebuild_Handle. Modes come from
// the environment so one binary drives every process case:
//   WORKER_MODE=request    publish, then request_rebuild
//   WORKER_MODE=publish    publish only (negative control)
//   WORKER_MODE=stale      request with a stale handle from file
//   WORKER_MODE=idle       no worker action
// WORKER_TRIGGER=go       publish tick 1 (the label)
// WORKER_TRIGGER=other    publish the other element instead

State :: struct {
	mu:            sync.Mutex,
	label:         string,
	other:         string,
	field:         string,
	field_hist:    string,
	has_hist:      bool,
	tick:          int,
	handle:        sdlhost.Rebuild_Handle,
	host_tid:      u64,
	builder_tid:   u64,
	built_label:   [64]u8,
	built_len:     int,
	other_buf:     [64]u8,
	other_len:     int,
	stop:          bool,
	stale_worker:  ^thread.Thread,
	elements:      [3]dagda.Element,
	present_path:  string,
	result_path:   string,
	trigger_path:  string,
	stale_path:    string,
	mode:          string,
	worker:        ^thread.Thread,
	runs:          int,
	first_handle:  sdlhost.Rebuild_Handle,
}

env_or :: proc(name, fallback: string) -> string {
	if v, ok := os.lookup_env(name, context.temp_allocator); ok {
		return v
	}
	return fallback
}

write_file :: proc(path, text: string) {
	if len(path) > 0 {
		_ = os.write_entire_file(path, transmute([]u8)text)
	}
}

app_view :: proc(user_data: rawptr) -> dagda.View {
	s := (^State)(user_data)
	sync.mutex_lock(&s.mu)
	label := fmt.bprintf(s.built_label[:], "%s", s.label)
	s.built_len = len(label)
	s.builder_tid = u64(sdl.GetCurrentThreadID())
	other_text := fmt.bprintf(s.other_buf[:], "%s", s.other)
	s.other_len = len(other_text)
	field := s.field
	sync.mutex_unlock(&s.mu)
	s.elements = {
		{info = {id = 1, role = "worker.label"}, kind = .Label, text = string(s.built_label[:s.built_len])},
		{info = {id = 2, role = "worker.field"}, kind = .Label, text = field},
		{info = {id = 3, role = "worker.other"}, kind = .Label, text = string(s.other_buf[:s.other_len])},
	}
	return {elements = s.elements[:]}
}

app_present :: proc(user_data: rawptr) {
	s := (^State)(user_data)
	sync.mutex_lock(&s.mu)
	text := fmt.tprintf("present label=%q other=%q builder=%d host=%d\n", string(s.built_label[:s.built_len]), string(s.other_buf[:s.other_len]), s.builder_tid, s.host_tid)
	path := s.present_path
	sync.mutex_unlock(&s.mu)
	write_file(path, text)
}

publish :: proc(s: ^State, trigger: string) {
	sync.mutex_lock(&s.mu)
	if trigger == "other" {
		delete(s.other)
		s.other = strings.clone("other 1")
	} else {
		s.tick += 1
		delete(s.label)
		s.label = strings.clone(fmt.tprintf("tick %d", s.tick))
	}
	sync.mutex_unlock(&s.mu)
}

worker_main :: proc(data: rawptr) {
	s := (^State)(data)
	// Wait for the trigger file so the test controls timing.
	for i in 0 ..< 500 {
		sync.mutex_lock(&s.mu)
		stopped := s.stop
		sync.mutex_unlock(&s.mu)
		if stopped {
			return
		}
		if os.exists(s.trigger_path) {
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	if s.mode == "stale" {
		data_bytes, _ := os.read_entire_file(s.stale_path, context.temp_allocator)
		parts := strings.split(string(data_bytes), ",", context.temp_allocator)
		if len(parts) == 2 {
			id_val := 0
			for ch in parts[0] { id_val = id_val * 10 + int(ch - '0') }
			ev_val := 0
			for ch in parts[1] { ev_val = ev_val * 10 + int(ch - '0') }
			result := sdlhost.request_rebuild({id = u64(id_val), event_type = u32(ev_val)})
			write_file(s.result_path, fmt.tprintf("stale result=%v\n", result))
		}
		return
	}
	// Handle each distinct trigger content once ("go", then
	// "other", ...), publishing and requesting per trigger.
	last := ""
	for i in 0 ..< 3000 {
		sync.mutex_lock(&s.mu)
		stopped := s.stop
		sync.mutex_unlock(&s.mu)
		if stopped {
			return
		}
		data_bytes, read_err := os.read_entire_file(s.trigger_path, context.temp_allocator)
		if read_err == nil && len(data_bytes) > 0 {
			trigger := string(data_bytes)
			if trigger != last {
				last = trigger
				publish(s, trigger)
				if s.mode == "request" {
					result := sdlhost.request_rebuild(s.handle)
					write_file(s.result_path, fmt.tprintf("request result=%v\n", result))
				}
			}
		}
		time.sleep(10 * time.Millisecond)
	}
}

stale_live_worker :: proc(data: rawptr) {
	s := (^State)(data)
	for i in 0 ..< 500 {
		sync.mutex_lock(&s.mu)
		stopped := s.stop
		sync.mutex_unlock(&s.mu)
		if stopped {
			return
		}
		if os.exists(s.trigger_path) {
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	result := sdlhost.request_rebuild(s.first_handle)
	write_file(s.result_path, fmt.tprintf("stale result=%v\n", result))
}

app_ready :: proc(user_data: rawptr, handle: sdlhost.Rebuild_Handle) {
	s := (^State)(user_data)
	s.handle = handle
	if s.runs == 1 {
		s.stale_worker = thread.create_and_start_with_data(s, stale_live_worker)
		return
	}
	s.host_tid = u64(sdl.GetCurrentThreadID())
	write_file(env_or("HANDLE_FILE", ""), fmt.tprintf("%d,%d", handle.id, handle.event_type))
	if s.mode != "idle" && s.mode != "" {
		s.worker = thread.create_and_start_with_data(s, worker_main)
	}
}

field_commit :: proc(user_data: rawptr, id: dagda.Object_Id, new_text: string) -> bool {
	s := (^State)(user_data)
	if id != 2 || new_text == s.field {
		return false
	}
	sync.mutex_lock(&s.mu)
	delete(s.field_hist)
	s.field_hist = s.field
	s.has_hist = true
	s.field = strings.clone(new_text)
	sync.mutex_unlock(&s.mu)
	return true
}

field_undo :: proc(user_data: rawptr, id: dagda.Object_Id) -> bool {
	s := (^State)(user_data)
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	if id != 2 || !s.has_hist {
		return false
	}
	delete(s.field)
	s.field = s.field_hist
	s.field_hist = ""
	s.has_hist = false
	return true
}

main :: proc() {
	state: State
	state.label = strings.clone("tick 0")
	state.other = strings.clone("other 0")
	state.field = strings.clone("Field")
	state.mode = env_or("WORKER_MODE", "idle")
	state.present_path = env_or("PRESENT_FILE", "")
	state.result_path = env_or("RESULT_FILE", "")
	state.trigger_path = env_or("TRIGGER_FILE", "")
	state.stale_path = env_or("STALE_FILE", "")
	defer {
		delete(state.label)
		delete(state.other)
		delete(state.field)
		delete(state.field_hist)
	}

	opts, ok := sdlhost.parse_cli_args(os.args[1:])
	if !ok {
		fmt.eprintln("usage: worker-rebuild [--socket <socket-path>] [--control-stdin]")
		os.exit(2)
	}
	handle_storage: sdlhost.Rebuild_Handle
	app := sdlhost.App{
		title          = "Dagda — Worker Rebuild",
		width          = 360,
		height         = 180,
		user_data      = &state,
		view           = app_view,
		rebuild_handle = &handle_storage,
		on_ready       = app_ready,
		on_present     = app_present,
		text_edit      = {enabled = true, target_id = 2, on_commit = field_commit, on_undo = field_undo},
	}
	code := sdlhost.run(app, opts)
	// A request issued after the window has closed must be safe.
	if env_or("LATE_REQUEST", "") == "1" {
		result := sdlhost.request_rebuild(handle_storage)
		write_file(state.result_path, fmt.tprintf("late result=%v\n", result))
	}
	if code == 0 && env_or("TWO_WINDOWS", "") == "1" {
		// Second window in the same process: the first handle
		// is now a stale generation and must never wake it.
		state.first_handle = handle_storage
		sync.mutex_lock(&state.mu)
		delete(state.label)
		state.label = strings.clone("tick 0")
		state.tick = 0
		sync.mutex_unlock(&state.mu)
		state.runs = 1
		code = sdlhost.run(app, opts)
	}
	sync.mutex_lock(&state.mu)
	state.stop = true
	sync.mutex_unlock(&state.mu)
	if state.worker != nil {
		thread.join(state.worker)
	}
	if state.stale_worker != nil {
		thread.join(state.stale_worker)
	}
	if code != 0 {
		os.exit(code)
	}
}
