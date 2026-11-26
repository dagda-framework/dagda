package sdlhost

import "core:sync"
import "core:testing"
import "dagda:dagda"
import sdl "vendor:sdl3"

@(test)
test_window_composition_callback_order :: proc(t: ^testing.T) {
	sync.mutex_guard(&sdl_test_mu)

	Phase :: enum { Start, Rejected, Accepted, End }
	Entry :: struct {
		phase: Phase,
		field: dagda.Object_Id,
		base, revision: int,
	}
	Fixture :: struct {
		t:             ^testing.T,
		host_thread:   int,
		revision:      int,
		base:          int,
		input_queued:  bool,
		fields:        [2]dagda.Canvas_Element,
		log:           [dynamic]Entry,
	}

	observe :: proc(ctx: rawptr, id: dagda.Object_Id, composing: bool) {
		s := (^Fixture)(ctx)
		testing.expect_value(s.t, sync.current_thread_id(), s.host_thread)
		if composing {
			s.base = s.revision
		}
		append(&s.log, Entry{composing ? .Start : .End, id, s.base, s.revision})
		if !composing {
			s.base = 0
		}
	}
	commit :: proc(ctx: rawptr, id: dagda.Object_Id, proposal: string) -> bool {
		s := (^Fixture)(ctx)
		if proposal == "a!" {
			append(&s.log, Entry{.Rejected, id, s.base, s.revision})
			return false
		}
		testing.expect_value(s.t, proposal, "aé")
		s.revision += 1
		s.fields[0].text = "aé"
		append(&s.log, Entry{.Accepted, id, s.base, s.revision})
		return true
	}

	queue :: proc(t: ^testing.T, kind: sdl.EventType, text: cstring = nil, key: sdl.Keycode = 0) {
		ev: sdl.Event
		ev.type = kind
		#partial switch kind {
		case .KEY_DOWN: ev.key.key = key
		case .TEXT_EDITING: ev.edit.text = text
		case .TEXT_INPUT: ev.text.text = text
		}
		testing.expect(t, sdl.PushEvent(&ev))
	}

	canvas :: proc(ctx: rawptr) -> dagda.Canvas {
		s := (^Fixture)(ctx)
		if !s.input_queued {
			s.input_queued = true
			queue(s.t, .KEY_DOWN, key = sdl.K_TAB) // First visual field, ID 0.
			queue(s.t, .TEXT_EDITING, "e")
			queue(s.t, .WINDOW_EXPOSED) // Rebuild with a newer app revision.
			queue(s.t, .TEXT_EDITING, "é")
			queue(s.t, .TEXT_INPUT, "!") // Rejected, original start remains available.
			queue(s.t, .TEXT_INPUT, "é") // Successful retry.
			queue(s.t, .TEXT_EDITING, "x")
			queue(s.t, .KEY_DOWN, key = sdl.K_TAB) // Blocked while composing.
			queue(s.t, .KEY_DOWN, key = sdl.K_ESCAPE)
			queue(s.t, .KEY_DOWN, key = sdl.K_ESCAPE)
			queue(s.t, .KEY_DOWN, key = sdl.K_TAB) // Second field.
			queue(s.t, .TEXT_EDITING, "y")
			queue(s.t, .WINDOW_FOCUS_LOST)
			queue(s.t, .WINDOW_FOCUS_LOST)
			queue(s.t, .KEY_DOWN, key = sdl.K_TAB)
			queue(s.t, .TEXT_EDITING, "z")
			queue(s.t, .QUIT) // Shutdown ends the final active composition.
		} else if s.base == 1 && s.revision == 1 {
			s.revision = 2
		}
		return {size = {width = 320, height = 160}, elements = s.fields[:]}
	}

	s := Fixture{
		t = t, host_thread = sync.current_thread_id(), revision = 1,
		fields = {
			{info = {id = 0, role = "first"}, kind = .Label, text = "a", bounds = {10, 10, 200, 40}},
			{info = {id = 2, role = "second"}, kind = .Label, text = "b", bounds = {10, 70, 200, 40}},
		},
	}
	defer delete(s.log)
	ids := [?]dagda.Object_Id{0, 2}
	app := App{
		user_data = &s, canvas = canvas, editable_text_targets = ids[:],
		text_edit = {enabled = true, on_commit = commit}, on_composition = observe,
	}
	testing.expect_value(t, run(app, {control_stdin = true}), 0)
	expected := [?]Entry{
		{.Start, 0, 1, 1}, {.Rejected, 0, 1, 2}, {.Accepted, 0, 1, 3}, {.End, 0, 1, 3},
		{.Start, 0, 3, 3}, {.End, 0, 3, 3}, {.Start, 2, 3, 3}, {.End, 2, 3, 3},
		{.Start, 0, 3, 3}, {.End, 0, 3, 3},
	}
	testing.expect_value(t, len(s.log), len(expected))
	for actual, i in s.log[:min(len(expected), len(s.log))] {
		testing.expect_value(t, actual, expected[i])
	}
}
