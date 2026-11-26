package sdlhost

import "core:mem"
import "core:strings"
import "core:testing"
import "dagda:dagda"
import sdl "vendor:sdl3"

@(test)
test_composition_snapshot_lifecycle_and_alloc_failure :: proc(t: ^testing.T) {
	State :: struct {
		text:     string,
		elements: [1]dagda.Canvas_Element,
		map_calls: int,
	}
	canvas :: proc(user_data: rawptr) -> dagda.Canvas {
		s := (^State)(user_data)
		s.elements = {{info = {id = 1, role = "field"}, kind = .Label, text = s.text, bounds = {x = 40, y = 40, width = 500, height = 60}}}
		return {size = {width = 960, height = 540}, elements = s.elements[:]}
	}
	commit :: proc(user_data: rawptr, id: dagda.Object_Id, new_text: string) -> bool { return true }
	remap :: proc(user_data: rawptr, field_id: dagda.Object_Id, old_text: string, new_text: string, anchor: int, caret: int) -> Composition_Remap_Decision {
		s := (^State)(user_data)
		s.map_calls += 1
		shift := len(new_text) - len(old_text)
		return {kind = .Mapped, anchor = anchor + shift, caret = caret + shift}
	}
	make_frame :: proc(s: ^State) -> dagda.Frame {
		frame, ok := dagda.resolve_canvas(canvas(s), {width = 800, height = 540})
		assert(ok)
		return frame
	}
	preedit :: proc() -> sdl.Event {
		ev: sdl.Event
		ev.type = .TEXT_EDITING
		ev.edit.text = "pre"
		ev.edit.start = 0
		ev.edit.length = 3
		return ev
	}

	s := State{text = strings.clone("A old Z")}
	defer delete(s.text)
	h: Host
	h.frame = make_frame(&s)
	targets := [1]dagda.Object_Id{1}
	h.app = App{
		user_data = &s, canvas = canvas,
		text_edit = {enabled = true, on_commit = commit},
		editable_text_targets = targets[:], on_composition_remap = remap,
	}
	defer {
		text_edit_destroy(&h.text_edit)
		dagda.frame_destroy(&h.frame)
	}
	testing.expect(t, text_edit_focus_id(&h.text_edit, nil, nil, h.frame, h.app.text_edit, 1, targets[:]))
	h.text_edit.session.anchor, h.text_edit.session.caret = 2, 5

	// Establishing the snapshot under a nil allocator: the
	// composition must not survive to accept a final edit.
	h.text_edit.session.allocator = mem.nil_allocator()
	ev := preedit()
	_ = text_edit_handle_event(&h.text_edit, nil, nil, h.frame, h.app.text_edit, &s, &ev, targets[:], h.clipboard)
	testing.expect(t, !dagda.is_composing(&h.text_edit.session))
	testing.expect(t, !h.text_edit.has_composition_snapshot)

	// With a working allocator the snapshot is the old text.
	h.text_edit.session.allocator = context.allocator
	ev = preedit()
	_ = text_edit_handle_event(&h.text_edit, nil, nil, h.frame, h.app.text_edit, &s, &ev, targets[:], h.clipboard)
	testing.expect(t, dagda.is_composing(&h.text_edit.session))
	testing.expect_value(t, h.text_edit.composition_snapshot, "A old Z")

	// Unchanged rebuild: no mapper call, snapshot kept.
	testing.expect(t, host_rebuild_frame(&h))
	testing.expect_value(t, s.map_calls, 0)
	testing.expect(t, dagda.is_composing(&h.text_edit.session))

	// First replacement maps and advances the snapshot.
	delete(s.text)
	s.text = strings.clone("새 A old Z")
	testing.expect(t, host_rebuild_frame(&h))
	testing.expect_value(t, s.map_calls, 1)
	testing.expect_value(t, h.text_edit.session.anchor, 6)
	testing.expect_value(t, h.text_edit.session.caret, 9)
	testing.expect_value(t, h.text_edit.composition_snapshot, "새 A old Z")

	// Second replacement maps from the advanced snapshot.
	delete(s.text)
	s.text = strings.clone("Y 새 A old Z")
	testing.expect(t, host_rebuild_frame(&h))
	testing.expect_value(t, s.map_calls, 2)
	testing.expect_value(t, h.text_edit.session.anchor, 8)
	testing.expect_value(t, h.text_edit.composition_snapshot, "Y 새 A old Z")

	// Advancing the snapshot under a nil allocator cancels
	// instead of leaving a final edit on stale offsets.
	h.text_edit.session.allocator = mem.nil_allocator()
	delete(s.text)
	s.text = strings.clone("Z Y 새 A old Z")
	testing.expect(t, host_rebuild_frame(&h))
	testing.expect(t, !dagda.is_composing(&h.text_edit.session))
	testing.expect(t, !h.text_edit.has_composition_snapshot)
	// The advance-failure fallback collapses to the old
	// selection start (8), not the two endpoints clamped
	// independently (which would have left caret at 11).
	testing.expect_value(t, h.text_edit.session.anchor, 8)
	testing.expect_value(t, h.text_edit.session.caret, 8)
}

@(test)
test_composition_cancel_fallbacks_collapse :: proc(t: ^testing.T) {
	State :: struct {
		text:     string,
		mode:     int,
		elements: [1]dagda.Canvas_Element,
	}
	canvas :: proc(user_data: rawptr) -> dagda.Canvas {
		s := (^State)(user_data)
		s.elements = {{info = {id = 1, role = "field"}, kind = .Label, text = s.text, bounds = {x = 40, y = 40, width = 500, height = 60}}}
		return {size = {width = 960, height = 540}, elements = s.elements[:]}
	}
	make_frame :: proc(s: ^State) -> dagda.Frame {
		frame, ok := dagda.resolve_canvas(canvas(s), {width = 800, height = 540})
		assert(ok)
		return frame
	}
	commit :: proc(user_data: rawptr, id: dagda.Object_Id, new_text: string) -> bool { return true }
	remap :: proc(user_data: rawptr, field_id: dagda.Object_Id, old_text: string, new_text: string, anchor: int, caret: int) -> Composition_Remap_Decision {
		s := (^State)(user_data)
		switch s.mode {
		case 1:
			return {} // zero value must safely cancel
		case 2:
			return {kind = .Mapped, anchor = 1, caret = 1} // splits 새 in the new text
		case 3:
			return {kind = .Cancel_At, caret = 1} // splits 새 in the new text
		}
		return {kind = .Cancel}
	}
	preedit :: proc() -> sdl.Event {
		ev: sdl.Event
		ev.type = .TEXT_EDITING
		ev.edit.text = "pre"
		ev.edit.start = 0
		ev.edit.length = 3
		return ev
	}

	// mode: -1 no mapper, 1 zero-value decision, 2 invalid
	// mapped endpoints, 3 invalid Cancel_At caret.
	for mode in ([?]int{-1, 1, 2, 3}) {
		s := State{text = strings.clone("A old Z"), mode = mode}
		h: Host
		h.frame = make_frame(&s)
		targets := [1]dagda.Object_Id{1}
		h.app = App{
			user_data = &s, canvas = canvas,
			text_edit = {enabled = true, on_commit = commit},
			editable_text_targets = targets[:],
		}
		if mode >= 0 {
			h.app.on_composition_remap = remap
		}
		testing.expect(t, text_edit_focus_id(&h.text_edit, nil, nil, h.frame, h.app.text_edit, 1, targets[:]))
		h.text_edit.session.anchor, h.text_edit.session.caret = 2, 5
		ev := preedit()
		_ = text_edit_handle_event(&h.text_edit, nil, nil, h.frame, h.app.text_edit, &s, &ev, targets[:], h.clipboard)
		testing.expect(t, dagda.is_composing(&h.text_edit.session))

		new_text := (mode >= 2) ? "새  Z" : "A  Z"
		delete(s.text)
		s.text = strings.clone(new_text)
		testing.expect(t, host_rebuild_frame(&h))
		testing.expect(t, !dagda.is_composing(&h.text_edit.session))
		testing.expect(t, !h.text_edit.has_composition_snapshot)
		want_caret := (mode >= 2) ? 0 : 2
		testing.expect_value(t, h.text_edit.session.anchor, want_caret)
		testing.expect_value(t, h.text_edit.session.caret, want_caret)

		// Typing a marker inserts at the collapsed caret and
		// every byte of the externally edited text survives.
		edit := dagda.insert_text(&h.text_edit.session, s.text, "X")
		testing.expect_value(t, edit.err, dagda.Edit_Error.None)
		testing.expect_value(t, edit.text, (mode >= 2) ? "X새  Z" : "A X Z")
		dagda.edit_destroy(&h.text_edit.session, &edit)

		text_edit_destroy(&h.text_edit)
		dagda.frame_destroy(&h.frame)
		delete(s.text)
	}
}
