package sdlhost

import "core:strings"
import "core:sync"
import "core:testing"
import "dagda:dagda"
import sdl "vendor:sdl3"

Primary_App :: struct {
	title:     string,
	rev:       u64,
	last_id:   dagda.Object_Id,
	undo_stack: [dynamic]string,
	app_undos:  int,
	editable:  [2]dagda.Object_Id,
	elements:  [2]dagda.Canvas_Element,
}

primary_make_frame :: proc(s: ^Primary_App) -> dagda.Frame {
	s.elements = {
		{info = {id = 1, role = "outline.title"}, kind = .Label, text = s.title, bounds = {x = 40, y = 40, width = 500, height = 60}},
		{info = {id = 2, role = "canvas.title"}, kind = .Label, text = s.title, bounds = {x = 40, y = 140, width = 500, height = 60}},
	}
	frame, ok := dagda.resolve_canvas({size = {width = 960, height = 540}, elements = s.elements[:]}, {width = 800, height = 540})
	assert(ok)
	return frame
}

primary_commit :: proc(user_data: rawptr, id: dagda.Object_Id, new_text: string) -> bool {
	s := (^Primary_App)(user_data)
	if new_text == s.title {
		return false
	}
	cloned, err := strings.clone(new_text)
	if err != nil {
		return false
	}
	append(&s.undo_stack, s.title)
	s.title = cloned
	s.rev += 1
	s.last_id = id
	return true
}

primary_undo :: proc(user_data: rawptr, id: dagda.Object_Id) -> bool {
	s := (^Primary_App)(user_data)
	if len(s.undo_stack) == 0 {
		return false
	}
	delete(s.title)
	s.title = pop(&s.undo_stack)
	s.rev += 1
	s.last_id = id
	return true
}

primary_app_undo :: proc(user_data: rawptr) -> bool {
	s := (^Primary_App)(user_data)
	s.app_undos += 1
	return primary_undo(user_data, s.last_id)
}

@(test)
test_primary_modifier_shortcuts :: proc(t: ^testing.T) {
	s := Primary_App{title = strings.clone("Cafe\u0301 Title"), editable = {1, 2}}
	defer {
		delete(s.title)
		for prev in s.undo_stack {
			delete(prev)
		}
		delete(s.undo_stack)
	}
	h: Host
	h.frame = primary_make_frame(&s)
	h.app = App{
		user_data = &s,
		text_edit = {enabled = true, on_commit = primary_commit, on_undo = primary_undo},
		editable_text_targets = s.editable[:],
		on_undo = primary_app_undo,
	}
	h.clipboard = memory_clipboard_interface(&h.mem_clipboard)
	defer {
		memory_clipboard_destroy(&h.mem_clipboard)
		text_edit_destroy(&h.text_edit)
		dagda.frame_destroy(&h.frame)
	}

	dispatch :: proc(h: ^Host, s: ^Primary_App, key: sdl.Keycode, mod: sdl.Keymod = {}) {
		ev: sdl.Event
		ev.type = .KEY_DOWN
		ev.key.key = key
		ev.key.mod = mod
		rebuild, has_pending, pending := host_dispatch_key_event(h, &ev)
		if rebuild {
			dagda.frame_destroy(&h.frame)
			h.frame = primary_make_frame(s)
			if has_pending {
				text_edit_apply_committed(&h.text_edit, nil, nil, h.frame, h.app.text_edit, &pending)
			} else {
				text_edit_reconcile(&h.text_edit, nil, nil, h.frame, h.app.text_edit, h.app.editable_text_targets)
			}
		}
	}
	primary := primary_modifier()
	other := non_primary_modifier()

	// Select all and cut the decomposed text with the platform
	// primary modifier; exact UTF-8 lands on the test clipboard.
	testing.expect(t, text_edit_focus_id(&h.text_edit, nil, nil, h.frame, h.app.text_edit, 1, s.editable[:]))
	dispatch(&h, &s, sdl.K_A, primary)
	start, end := dagda.selection_bounds(&h.text_edit.session)
	testing.expect_value(t, s.title[start:end], "Cafe\u0301 Title")
	dispatch(&h, &s, sdl.K_C, primary)
	testing.expect_value(t, h.mem_clipboard.text, "Cafe\u0301 Title")
	dispatch(&h, &s, sdl.K_X, primary)
	testing.expect_value(t, s.title, "")
	testing.expect_value(t, s.rev, u64(1))

	// Paste into the second field and undo to the original bytes.
	testing.expect(t, text_edit_focus_id(&h.text_edit, nil, nil, h.frame, h.app.text_edit, 2, s.editable[:]))
	dispatch(&h, &s, sdl.K_V, primary)
	testing.expect_value(t, s.title, "Cafe\u0301 Title")
	testing.expect_value(t, s.rev, u64(2))
	testing.expect_value(t, s.last_id, dagda.Object_Id(2))
	dispatch(&h, &s, sdl.K_Z, primary) // focused-field undo
	testing.expect_value(t, s.title, "")
	testing.expect_value(t, s.rev, u64(3))
	testing.expect_value(t, s.app_undos, 0) // exactly one handler ran

	// The other platform's modifier does none of this.
	dispatch(&h, &s, sdl.K_A, other)
	dispatch(&h, &s, sdl.K_Z, other)
	testing.expect_value(t, s.rev, u64(3))
	testing.expect_value(t, s.app_undos, 0)

	// An active preedit survives a primary paste shortcut.
	pre: sdl.Event
	pre.type = .TEXT_EDITING
	pre.edit.text = "e"
	_ = text_edit_handle_event(&h.text_edit, nil, nil, h.frame, h.app.text_edit, &s, &pre, s.editable[:], h.clipboard)
	testing.expect(t, dagda.is_composing(&h.text_edit.session))
	dispatch(&h, &s, sdl.K_V, primary)
	testing.expect(t, dagda.is_composing(&h.text_edit.session))
	testing.expect_value(t, s.title, "")

	// After moving focus away, one primary Z reaches exactly
	// the app-level undo handler once.
	_ = text_edit_blur(&h.text_edit, nil)
	dispatch(&h, &s, sdl.K_Z, primary)
	testing.expect_value(t, s.app_undos, 1)
	testing.expect_value(t, s.title, "Cafe\u0301 Title")
	testing.expect_value(t, s.rev, u64(4))
}
