package main

import "core:testing"
import "dagda:dagda"
import sdl "vendor:sdl3"

TEST_TITLE_BOX :: sdl.FRect{x = 56, y = 112, w = 748, h = 72}

@(test)
test_composition_does_not_commit_and_blocks_external_commits :: proc(t: ^testing.T) {
	fixture: Local_Fixture
	fixture_init(&fixture, "Quarterly results", 1)
	defer fixture_destroy(&fixture)
	adapter := fixture_adapter(&fixture)

	state: Editor_State
	editor_init(&state, adapter)
	defer editor_destroy(&state)

	testing.expect_value(t, editor_is_composing(&state), false)
	testing.expect_value(t, editor_external_commit_gate(&state), External_Commit_Gate.Ready)

	// Inject SDL TEXT_EDITING preedit event.
	preedit_ev: sdl.Event
	preedit_ev.type = .TEXT_EDITING
	preedit_ev.edit.text = "nihon"
	preedit_ev.edit.start = 5
	preedit_ev.edit.length = 0
	editor_handle_sdl_event(&state, adapter, &preedit_ev, TEST_TITLE_BOX)

	testing.expect_value(t, editor_is_composing(&state), true)
	testing.expect_value(t, editor_external_commit_gate(&state), External_Commit_Gate.Busy_Composing)
	testing.expect_value(t, state.preedit_text, "nihon")
	testing.expect_value(t, state.commit_count, 0)

	// Model remains untouched during composition.
	snap := adapter_snapshot(adapter)
	testing.expect_value(t, snap.revision, dagda.Revision(0))
	testing.expect_value(t, snap.text, "Quarterly results")

	// Editing keys during composition must not mutate committed text.
	bs_ev: sdl.Event
	bs_ev.type = .KEY_DOWN
	bs_ev.key.key = sdl.K_BACKSPACE
	editor_handle_sdl_event(&state, adapter, &bs_ev, TEST_TITLE_BOX)
	testing.expect_value(t, adapter_snapshot(adapter).text, "Quarterly results")
	testing.expect_value(t, state.commit_count, 0)

	// Final IME commit arrives as TEXT_INPUT: clears preedit and commits exactly once.
	input_ev: sdl.Event
	input_ev.type = .TEXT_INPUT
	input_ev.text.text = "!"
	editor_handle_sdl_event(&state, adapter, &input_ev, TEST_TITLE_BOX)

	testing.expect_value(t, editor_is_composing(&state), false)
	testing.expect_value(t, editor_external_commit_gate(&state), External_Commit_Gate.Ready)
	testing.expect_value(t, state.preedit_text, "")
	testing.expect_value(t, state.commit_count, 1)
	testing.expect_value(t, adapter_snapshot(adapter).revision, dagda.Revision(1))
	testing.expect_value(t, adapter_snapshot(adapter).text, "Quarterly results!")
}

@(test)
test_escape_cancels_composition_cleanly_and_preserves_focus :: proc(t: ^testing.T) {
	fixture: Local_Fixture
	fixture_init(&fixture, "Quarterly results", 1)
	defer fixture_destroy(&fixture)
	adapter := fixture_adapter(&fixture)

	state: Editor_State
	editor_init(&state, adapter)
	defer editor_destroy(&state)

	preedit_ev: sdl.Event
	preedit_ev.type = .TEXT_EDITING
	preedit_ev.edit.text = "draft"
	preedit_ev.edit.start = 0
	preedit_ev.edit.length = 5
	editor_handle_sdl_event(&state, adapter, &preedit_ev, TEST_TITLE_BOX)
	testing.expect_value(t, editor_is_composing(&state), true)

	esc_ev: sdl.Event
	esc_ev.type = .KEY_DOWN
	esc_ev.key.key = sdl.K_ESCAPE
	editor_handle_sdl_event(&state, adapter, &esc_ev, TEST_TITLE_BOX)

	testing.expect_value(t, editor_is_composing(&state), false)
	testing.expect_value(t, editor_external_commit_gate(&state), External_Commit_Gate.Ready)
	testing.expect_value(t, state.preedit_text, "")
	testing.expect_value(t, state.needs_clear_composition, true)
	testing.expect_value(t, state.focused, true)
	testing.expect_value(t, state.commit_count, 0)
	testing.expect_value(t, adapter_snapshot(adapter).revision, dagda.Revision(0))
	testing.expect_value(t, adapter_snapshot(adapter).text, "Quarterly results")
}

@(test)
test_external_model_change_redraws_without_stealing_or_dropping_focus :: proc(t: ^testing.T) {
	fixture: Local_Fixture
	fixture_init(&fixture, "Quarterly results", 1)
	defer fixture_destroy(&fixture)
	adapter := fixture_adapter(&fixture)

	state: Editor_State
	editor_init(&state, adapter)
	defer editor_destroy(&state)

	state.needs_redraw = false
	testing.expect_value(t, state.focused, true)

	// External commit while focused keeps focus and marks redraw.
	snap := adapter_snapshot(adapter)
	res := adapter_commit(adapter, dagda.Action_Target{id = snap.id, base_revision = snap.revision}, "Revenue grew 12%")
	testing.expect_value(t, res.err, dagda.Action_Error.None)

	changed := editor_sync_from_model(&state, adapter)
	testing.expect_value(t, changed, true)
	testing.expect_value(t, state.needs_redraw, true)
	testing.expect_value(t, state.focused, true)
	testing.expect_value(t, state.committed_text, "Revenue grew 12%")
	testing.expect_value(t, state.snapshot_revision, dagda.Revision(1))

	// Next keystroke still goes to the title.
	input_ev: sdl.Event
	input_ev.type = .TEXT_INPUT
	input_ev.text.text = "!"
	editor_handle_sdl_event(&state, adapter, &input_ev, TEST_TITLE_BOX)
	testing.expect_value(t, adapter_snapshot(adapter).text, "Revenue grew 12%!")

	// Blur the title; another external commit must NOT steal focus back.
	blur_ev: sdl.Event
	blur_ev.type = .MOUSE_BUTTON_DOWN
	blur_ev.button.button = sdl.BUTTON_LEFT
	blur_ev.button.x = 10
	blur_ev.button.y = 10
	editor_handle_sdl_event(&state, adapter, &blur_ev, TEST_TITLE_BOX)
	testing.expect_value(t, state.focused, false)

	snap = adapter_snapshot(adapter)
	res = adapter_commit(adapter, dagda.Action_Target{id = snap.id, base_revision = snap.revision}, "Short")
	testing.expect_value(t, res.err, dagda.Action_Error.None)

	state.needs_redraw = false
	changed = editor_sync_from_model(&state, adapter)
	testing.expect_value(t, changed, true)
	testing.expect_value(t, state.needs_redraw, true)
	testing.expect_value(t, state.focused, false)
	testing.expect_value(t, state.caret, len("Short"))
}

@(test)
test_keyboard_undo_restores_title_advances_revision_and_keeps_focus :: proc(t: ^testing.T) {
	fixture: Local_Fixture
	fixture_init(&fixture, "Quarterly results", 1)
	defer fixture_destroy(&fixture)
	adapter := fixture_adapter(&fixture)

	state: Editor_State
	editor_init(&state, adapter)
	defer editor_destroy(&state)

	// Select all and replace in one input operation.
	sel_all: sdl.Event
	sel_all.type = .KEY_DOWN
	sel_all.key.key = sdl.K_A
	sel_all.key.mod = sdl.KMOD_LCTRL
	editor_handle_sdl_event(&state, adapter, &sel_all, TEST_TITLE_BOX)

	input_ev: sdl.Event
	input_ev.type = .TEXT_INPUT
	input_ev.text.text = "Revenue grew 12%"
	editor_handle_sdl_event(&state, adapter, &input_ev, TEST_TITLE_BOX)
	testing.expect_value(t, state.commit_count, 1)
	testing.expect_value(t, adapter_snapshot(adapter).revision, dagda.Revision(1))
	testing.expect_value(t, adapter_snapshot(adapter).text, "Revenue grew 12%")

	// Ctrl+Z undoes, advances revision to 2, and preserves focus.
	undo_ev: sdl.Event
	undo_ev.type = .KEY_DOWN
	undo_ev.key.key = sdl.K_Z
	undo_ev.key.mod = sdl.KMOD_LCTRL
	editor_handle_sdl_event(&state, adapter, &undo_ev, TEST_TITLE_BOX)

	snap := adapter_snapshot(adapter)
	testing.expect_value(t, snap.text, "Quarterly results")
	testing.expect_value(t, snap.revision, dagda.Revision(2))
	testing.expect_value(t, state.focused, true)
	testing.expect_value(t, state.committed_text, "Quarterly results")

	// Old revision 0 proposal must still be rejected as stale after undo.
	stale := adapter_commit(adapter, dagda.Action_Target{id = snap.id, base_revision = 0}, "Stale")
	testing.expect_value(t, stale.err, dagda.Action_Error.Stale_Revision)
}

@(test)
test_utf8_backspace_and_noop_commit :: proc(t: ^testing.T) {
	fixture: Local_Fixture
	fixture_init(&fixture, "Café", 1)
	defer fixture_destroy(&fixture)
	adapter := fixture_adapter(&fixture)

	state: Editor_State
	editor_init(&state, adapter)
	defer editor_destroy(&state)

	// Backspace removes the entire 2-byte UTF-8 rune 'é' in one commit.
	bs_ev: sdl.Event
	bs_ev.type = .KEY_DOWN
	bs_ev.key.key = sdl.K_BACKSPACE
	editor_handle_sdl_event(&state, adapter, &bs_ev, TEST_TITLE_BOX)

	testing.expect_value(t, state.commit_count, 1)
	testing.expect_value(t, state.committed_text, "Caf")
	testing.expect_value(t, adapter_snapshot(adapter).revision, dagda.Revision(1))

	// No-op commit leaves revision unchanged.
	snap := adapter_snapshot(adapter)
	noop := adapter_commit(adapter, dagda.Action_Target{id = snap.id, base_revision = snap.revision}, "Caf")
	testing.expect_value(t, noop.err, dagda.Action_Error.None)
	testing.expect_value(t, noop.snapshot.revision, dagda.Revision(1))
}
