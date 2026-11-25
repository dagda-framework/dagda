package main

import title_model "../title-model"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:sys/posix"
import "core:testing"
import "dagda:dagda"
import driver "dagda:examples/title-driver"
import sdl "vendor:sdl3"

TEST_TITLE_BOX :: sdl.FRect{x = 56, y = 112, w = 748, h = 72}

make_test_model :: proc(t: ^testing.T, text := "Quarterly results") -> title_model.Model {
	model: title_model.Model
	err := title_model.init(&model, {id = 1, role = "slide.title"}, text)
	testing.expect_value(t, err, title_model.Error.None)
	return model
}

Fail_Alloc_State :: struct {
	backing:     mem.Allocator,
	fail_allocs: bool,
}

fail_alloc_proc :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	state := (^Fail_Alloc_State)(data)
	if state.fail_allocs && (mode == .Alloc || mode == .Alloc_Non_Zeroed) {
		return nil, .Out_Of_Memory
	}
	return state.backing.procedure(state.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

@(test)
test_composition_does_not_commit_and_blocks_external_commits :: proc(t: ^testing.T) {
	model := make_test_model(t)
	defer title_model.destroy(&model)
	adapter := title_model_adapter(&model)

	state: Editor_State
	editor_init(&state, adapter)
	defer editor_destroy(&state)

	testing.expect_value(t, editor_is_composing(&state), false)
	testing.expect_value(t, editor_external_commit_gate(&state), External_Commit_Gate.Ready)

	// Inject SDL TEXT_EDITING preedit event.
	preedit_ev: sdl.Event
	preedit_ev.type = .TEXT_EDITING
	preedit_ev.edit.text = "café"
	preedit_ev.edit.start = 4
	preedit_ev.edit.length = 0
	editor_handle_sdl_event(&state, adapter, &preedit_ev, TEST_TITLE_BOX)

	testing.expect_value(t, editor_is_composing(&state), true)
	testing.expect_value(t, editor_external_commit_gate(&state), External_Commit_Gate.Busy_Composing)
	testing.expect_value(t, state.preedit_text, "café")
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
	model := make_test_model(t)
	defer title_model.destroy(&model)
	adapter := title_model_adapter(&model)

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
	model := make_test_model(t)
	defer title_model.destroy(&model)
	adapter := title_model_adapter(&model)

	state: Editor_State
	editor_init(&state, adapter)
	defer editor_destroy(&state)

	state.needs_redraw = false
	testing.expect_value(t, state.focused, true)

	// External commit while focused keeps focus and marks redraw.
	snap := adapter_snapshot(adapter)
	res := adapter_commit(adapter, dagda.Action_Target{id = snap.id, base_revision = snap.revision}, "Revenue grew 12%")
	testing.expect_value(t, res.err, Model_Error.None)

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
	testing.expect_value(t, res.err, Model_Error.None)

	state.needs_redraw = false
	changed = editor_sync_from_model(&state, adapter)
	testing.expect_value(t, changed, true)
	testing.expect_value(t, state.needs_redraw, true)
	testing.expect_value(t, state.focused, false)
	testing.expect_value(t, state.caret, len("Short"))
}

@(test)
test_keyboard_undo_restores_title_advances_revision_and_keeps_focus :: proc(t: ^testing.T) {
	model := make_test_model(t)
	defer title_model.destroy(&model)
	adapter := title_model_adapter(&model)

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
	testing.expect_value(t, stale.err, Model_Error.Stale_Revision)
}

@(test)
test_utf8_backspace_and_noop_commit :: proc(t: ^testing.T) {
	model := make_test_model(t, "Café")
	defer title_model.destroy(&model)
	adapter := title_model_adapter(&model)

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
	testing.expect_value(t, noop.err, Model_Error.None)
	testing.expect_value(t, noop.snapshot.revision, dagda.Revision(1))
}

@(test)
test_real_adapter_type_preview_commit_undo_stale_and_busy_preedit :: proc(t: ^testing.T) {
	model := make_test_model(t, "Quarterly results")
	defer title_model.destroy(&model)
	adapter := title_model_adapter(&model)

	state: Editor_State
	editor_init(&state, adapter)
	defer editor_destroy(&state)

	// 1. Human types in the window through the real adapter.
	type_ev: sdl.Event
	type_ev.type = .TEXT_INPUT
	type_ev.text.text = " — Q4"
	editor_handle_sdl_event(&state, adapter, &type_ev, TEST_TITLE_BOX)

	after_type := title_model.snapshot(&model)
	testing.expect_value(t, after_type.object.id, dagda.Object_Id(1))
	testing.expect_value(t, after_type.revision, dagda.Revision(1))
	testing.expect_value(t, after_type.text, "Quarterly results — Q4")
	testing.expect_value(t, state.committed_text, "Quarterly results — Q4")

	// 2. External caller previews against inspected revision 1 without mutating the model.
	inspected := dagda.Action_Target{id = after_type.object.id, base_revision = after_type.revision}
	p, prev_err := title_model.preview(&model, inspected, "Revenue grew 12%")
	testing.expect_value(t, prev_err, title_model.Error.None)
	testing.expect_value(t, p.text, "Revenue grew 12%")
	title_model.preview_destroy(&p)

	still_rev1 := title_model.snapshot(&model)
	testing.expect_value(t, still_rev1.revision, dagda.Revision(1))
	testing.expect_value(t, still_rev1.text, "Quarterly results — Q4")

	// 3. Stale external edit against revision 0 is rejected without mutating model.
	stale_res := adapter_commit(adapter, dagda.Action_Target{id = 1, base_revision = 0}, "Stale rename")
	testing.expect_value(t, stale_res.err, Model_Error.Stale_Revision)
	testing.expect_value(t, title_model.snapshot(&model).revision, dagda.Revision(1))
	testing.expect_value(t, title_model.snapshot(&model).text, "Quarterly results — Q4")

	// 4. Busy external commit during active preedit is blocked by the host gate.
	edit_ev: sdl.Event
	edit_ev.type = .TEXT_EDITING
	edit_ev.edit.text = "draft"
	edit_ev.edit.start = 5
	edit_ev.edit.length = 0
	editor_handle_sdl_event(&state, adapter, &edit_ev, TEST_TITLE_BOX)
	testing.expect_value(t, editor_external_commit_gate(&state), External_Commit_Gate.Busy_Composing)
	testing.expect_value(t, title_model.snapshot(&model).revision, dagda.Revision(1))

	esc_ev: sdl.Event
	esc_ev.type = .KEY_DOWN
	esc_ev.key.key = sdl.K_ESCAPE
	editor_handle_sdl_event(&state, adapter, &esc_ev, TEST_TITLE_BOX)
	testing.expect_value(t, editor_external_commit_gate(&state), External_Commit_Gate.Ready)

	// 5. External commit against inspected revision 1 succeeds and syncs to window without stealing focus.
	commit_res := adapter_commit(adapter, inspected, "Revenue grew 12%")
	testing.expect_value(t, commit_res.err, Model_Error.None)
	testing.expect_value(t, commit_res.snapshot.revision, dagda.Revision(2))
	testing.expect_value(t, commit_res.snapshot.text, "Revenue grew 12%")

	synced := editor_sync_from_model(&state, adapter)
	testing.expect_value(t, synced, true)
	testing.expect_value(t, state.committed_text, "Revenue grew 12%")
	testing.expect_value(t, state.snapshot_revision, dagda.Revision(2))
	testing.expect_value(t, state.focused, true)

	// 6. Keyboard Undo from the window restores the pre-external title and advances revision to 3 on the same model.
	undo_ev: sdl.Event
	undo_ev.type = .KEY_DOWN
	undo_ev.key.key = sdl.K_Z
	undo_ev.key.mod = sdl.KMOD_LCTRL
	editor_handle_sdl_event(&state, adapter, &undo_ev, TEST_TITLE_BOX)

	after_undo := title_model.snapshot(&model)
	testing.expect_value(t, after_undo.text, "Quarterly results — Q4")
	testing.expect_value(t, after_undo.revision, dagda.Revision(3))
	testing.expect_value(t, state.committed_text, "Quarterly results — Q4")
	testing.expect_value(t, state.focused, true)

	// One-step history: second Undo makes no further change, and prior revisions remain stale.
	editor_handle_sdl_event(&state, adapter, &undo_ev, TEST_TITLE_BOX)
	testing.expect_value(t, title_model.snapshot(&model).revision, dagda.Revision(3))
	testing.expect_value(t, adapter_commit(adapter, inspected, "Late").err, Model_Error.Stale_Revision)
}

@(test)
test_real_adapter_surfaces_all_model_errors :: proc(t: ^testing.T) {
	fail_state := Fail_Alloc_State{backing = context.allocator}
	alloc := mem.Allocator{procedure = fail_alloc_proc, data = &fail_state}

	model: title_model.Model
	testing.expect_value(t, title_model.init(&model, {id = 1, role = "slide.title"}, "Quarterly results", alloc), title_model.Error.None)
	defer title_model.destroy(&model)
	adapter := title_model_adapter(&model)

	testing.expect_value(t, adapter_commit(adapter, {id = 999, base_revision = 0}, "Other").err, Model_Error.Unknown_Object)
	testing.expect_value(t, adapter_commit(adapter, {id = 1, base_revision = 5}, "Other").err, Model_Error.Stale_Revision)
	testing.expect_value(t, adapter_commit(adapter, {id = 1, base_revision = 0}, "\xff\xfe").err, Model_Error.Invalid_Text)

	fail_state.fail_allocs = true
	alloc_res := adapter_commit(adapter, {id = 1, base_revision = 0}, "Out of memory")
	fail_state.fail_allocs = false
	testing.expect_value(t, alloc_res.err, Model_Error.Alloc_Failed)
	testing.expect_value(t, alloc_res.snapshot.text, "Quarterly results")
	testing.expect_value(t, alloc_res.snapshot.revision, dagda.Revision(0))
}

@(test)
test_rendered_non_ascii_glyphs_distinguish_e_acute_and_n_tilde :: proc(t: ^testing.T) {
	font: Font
	testing.expect(t, font_init(&font), "Expected FreeType font to initialize")
	defer font_destroy(&font)

	e_img := font_rasterize_line(&font, "é", TITLE_PX)
	defer rasterized_line_destroy(&e_img)
	n_img := font_rasterize_line(&font, "ñ", TITLE_PX)
	defer rasterized_line_destroy(&n_img)

	e_ink := 0
	for p in e_img.pixels {
		if p > 0 {
			e_ink += 1
		}
	}
	n_ink := 0
	for p in n_img.pixels {
		if p > 0 {
			n_ink += 1
		}
	}
	testing.expect(t, e_ink > 0, "Expected non-empty rendered glyph for 'é'")
	testing.expect(t, n_ink > 0, "Expected non-empty rendered glyph for 'ñ'")
	testing.expect(t, e_img.width != n_img.width || e_img.height != n_img.height || !slice.equal(e_img.pixels, n_img.pixels),
		"Expected rendered glyphs for 'é' and 'ñ' to be visually distinct")

	cafe := font_rasterize_line(&font, "Café", TITLE_PX)
	defer rasterized_line_destroy(&cafe)
	cane := font_rasterize_line(&font, "Cañé", TITLE_PX)
	defer rasterized_line_destroy(&cane)
	testing.expect(t, cafe.width != cane.width || !slice.equal(cafe.pixels, cane.pixels),
		"Expected rendered non-ASCII strings 'Café' and 'Cañé' to differ")
}

@(test)
test_nonterminal_preedit_caret_selection_and_composing_replacement :: proc(t: ^testing.T) {
	font: Font
	testing.expect(t, font_init(&font), "Expected FreeType font to initialize")
	defer font_destroy(&font)

	model := make_test_model(t)
	defer title_model.destroy(&model)
	adapter := title_model_adapter(&model)

	state: Editor_State
	editor_init(&state, adapter)
	defer editor_destroy(&state)

	// Select "results" (last 7 bytes).
	state.anchor = len("Quarterly ")
	state.caret = len("Quarterly results")

	// Start composing "ñandú" with a nonterminal caret at rune index 2 ("ñ a | n d ú").
	edit_ev: sdl.Event
	edit_ev.type = .TEXT_EDITING
	edit_ev.edit.text = "ñandú"
	edit_ev.edit.start = 2
	edit_ev.edit.length = 0
	editor_handle_sdl_event(&state, adapter, &edit_ev, TEST_TITLE_BOX)

	layout := compute_title_layout(&font, &state, TEST_TITLE_BOX, TITLE_PX)
	testing.expect_value(t, layout.before_text, "Quarterly ")
	testing.expect_value(t, layout.preedit_text, "ñandú")
	testing.expect_value(t, layout.after_text, "")
	testing.expect_value(t, layout.has_committed_sel, false)
	testing.expect_value(t, layout.has_preedit_sel, false)

	expected_caret_x := layout.preedit_x + font_measure_width(&font, "ña", TITLE_PX)
	testing.expect_value(t, layout.caret_x, expected_caret_x)
	testing.expect(t, layout.caret_x > layout.preedit_x && layout.caret_x < layout.preedit_x + layout.preedit_w,
		"Expected nonterminal preedit caret strictly inside preedit width")
	testing.expect_value(t, layout.candidate_cursor_x, c.int(layout.caret_x - TEST_TITLE_BOX.x))

	// Update preedit with an active preedit selection subrange (start=1, length=2 -> "an").
	edit_ev.edit.start = 1
	edit_ev.edit.length = 2
	editor_handle_sdl_event(&state, adapter, &edit_ev, TEST_TITLE_BOX)

	sel_layout := compute_title_layout(&font, &state, TEST_TITLE_BOX, TITLE_PX)
	testing.expect_value(t, sel_layout.has_preedit_sel, true)
	testing.expect_value(t, sel_layout.preedit_sel_x, sel_layout.preedit_x + font_measure_width(&font, "ñ", TITLE_PX))
	testing.expect_value(t, sel_layout.preedit_sel_w, font_measure_width(&font, "an", TITLE_PX))
	testing.expect_value(t, sel_layout.caret_x, sel_layout.preedit_sel_x + sel_layout.preedit_sel_w)
	testing.expect_value(t, sel_layout.candidate_cursor_x, c.int(sel_layout.caret_x - TEST_TITLE_BOX.x))

	// Escape cancels composition cleanly and leaves committed text & selection intact.
	esc_ev: sdl.Event
	esc_ev.type = .KEY_DOWN
	esc_ev.key.key = sdl.K_ESCAPE
	editor_handle_sdl_event(&state, adapter, &esc_ev, TEST_TITLE_BOX)
	testing.expect_value(t, editor_is_composing(&state), false)
	testing.expect_value(t, state.committed_text, "Quarterly results")
	testing.expect_value(t, state.anchor, len("Quarterly "))
	testing.expect_value(t, state.caret, len("Quarterly results"))
}

@(test)
test_ft_bitmap_copy_positive_and_negative_padded_pitch :: proc(t: ^testing.T) {
	// Positive pitch (top-to-bottom) with 2 trailing padding bytes per row.
	pos_buf := [?]u8{
		10, 20, 30, 0xEE, 0xEE, // row 0 (top)
		40, 50, 60, 0xEE, 0xEE, // row 1 (bottom)
	}
	pos_bmp := FT_Bitmap{
		rows       = 2,
		width      = 3,
		pitch      = 5,
		buffer     = raw_data(pos_buf[:]),
		num_grays  = 256,
		pixel_mode = FT_PIXEL_MODE_GRAY,
	}
	pos_alpha, pos_ok := copy_ft_bitmap_alpha(pos_bmp)
	defer delete(pos_alpha)
	testing.expect_value(t, pos_ok, true)
	testing.expect(t, slice.equal(pos_alpha, []u8{10, 20, 30, 40, 50, 60}),
		"Expected top-to-bottom 3x2 pixels with padding stripped")

	// Negative pitch (bottom-to-top): buffer[0..4] is bottom row, buffer[4..8] is top row.
	neg_buf := [?]u8{
		40, 50, 60, 0xDD, // bottom row
		10, 20, 30, 0xDD, // top row
	}
	neg_bmp := FT_Bitmap{
		rows       = 2,
		width      = 3,
		pitch      = -4,
		buffer     = raw_data(neg_buf[:]),
		num_grays  = 256,
		pixel_mode = FT_PIXEL_MODE_GRAY,
	}
	neg_alpha, neg_ok := copy_ft_bitmap_alpha(neg_bmp)
	defer delete(neg_alpha)
	testing.expect_value(t, neg_ok, true)
	testing.expect(t, slice.equal(neg_alpha, []u8{10, 20, 30, 40, 50, 60}),
		"Expected negative-pitch bottom-up rows flipped to top-to-bottom with padding stripped")
}

@(test)
test_ft_bitmap_copy_rejects_unsupported_formats_and_invalid_strides :: proc(t: ^testing.T) {
	dummy := [16]u8{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}

	// Empty bitmap is valid and allocates nothing.
	empty_alpha, empty_ok := copy_ft_bitmap_alpha(FT_Bitmap{width = 0, rows = 0, buffer = nil})
	testing.expect_value(t, empty_ok, true)
	testing.expect_value(t, len(empty_alpha), 0)

	cases := []FT_Bitmap{
		// Unsupported pixel modes
		{width = 3, rows = 2, pitch = 3, buffer = raw_data(dummy[:]), num_grays = 256, pixel_mode = FT_PIXEL_MODE_MONO},
		{width = 3, rows = 2, pitch = 12, buffer = raw_data(dummy[:]), num_grays = 256, pixel_mode = FT_PIXEL_MODE_BGRA},
		{width = 3, rows = 2, pitch = 9, buffer = raw_data(dummy[:]), num_grays = 256, pixel_mode = FT_PIXEL_MODE_LCD},
		// Unsupported gray levels
		{width = 3, rows = 2, pitch = 3, buffer = raw_data(dummy[:]), num_grays = 16, pixel_mode = FT_PIXEL_MODE_GRAY},
		// Invalid / undersized strides (zero, positive < width, negative abs < width)
		{width = 3, rows = 2, pitch = 0, buffer = raw_data(dummy[:]), num_grays = 256, pixel_mode = FT_PIXEL_MODE_GRAY},
		{width = 3, rows = 2, pitch = 2, buffer = raw_data(dummy[:]), num_grays = 256, pixel_mode = FT_PIXEL_MODE_GRAY},
		{width = 3, rows = 2, pitch = -2, buffer = raw_data(dummy[:]), num_grays = 256, pixel_mode = FT_PIXEL_MODE_GRAY},
		// Non-empty dimensions with nil buffer
		{width = 2, rows = 2, pitch = 2, buffer = nil, num_grays = 256, pixel_mode = FT_PIXEL_MODE_GRAY},
	}

	for bmp in cases {
		alpha, ok := copy_ft_bitmap_alpha(bmp)
		testing.expect_value(t, ok, false)
		testing.expect_value(t, len(alpha), 0)
	}
}

@(test)
test_driver_dispatch_during_composition_and_nonblocking_partial_client :: proc(t: ^testing.T) {
	model := make_test_model(t, "Quarterly results")
	defer title_model.destroy(&model)
	adapter := title_model_adapter(&model)

	state: Editor_State
	editor_init(&state, adapter)
	defer editor_destroy(&state)

	// Commit one edit so undo would be valid when idle.
	type_ev: sdl.Event
	type_ev.type = .TEXT_INPUT
	type_ev.text.text = "!"
	editor_handle_sdl_event(&state, adapter, &type_ev, TEST_TITLE_BOX)
	testing.expect_value(t, title_model.snapshot(&model).revision, dagda.Revision(1))

	// Enter active composition.
	edit_ev: sdl.Event
	edit_ev.type = .TEXT_EDITING
	edit_ev.edit.text = "café"
	edit_ev.edit.start = 2
	edit_ev.edit.length = 0
	editor_handle_sdl_event(&state, adapter, &edit_ev, TEST_TITLE_BOX)
	testing.expect_value(t, editor_is_composing(&state), true)

	// Inspect and preview succeed during composition.
	insp := dispatch_window_line(&model, &state, adapter, `{"op":"inspect","role":"slide.title"}`)
	defer delete(insp)
	testing.expect_value(t, insp, `{"ok":true,"id":1,"revision":1,"text":"Quarterly results!","role":"slide.title"}`)

	prev := dispatch_window_line(&model, &state, adapter, `{"op":"preview","id":1,"base_revision":1,"text":"Revenue grew 12%"}`)
	defer delete(prev)
	testing.expect_value(t, prev, `{"ok":true,"id":1,"revision":1,"text":"Revenue grew 12%"}`)

	// Valid external commit and undo during composition return Busy_Composing and preserve document, preedit, and focus.
	busy_commit := dispatch_window_line(&model, &state, adapter, `{"op":"commit","id":1,"base_revision":1,"text":"Revenue grew 12%"}`)
	defer delete(busy_commit)
	testing.expect_value(t, busy_commit, `{"ok":false,"error":"Busy_Composing"}`)

	busy_undo := dispatch_window_line(&model, &state, adapter, `{"op":"undo","id":1,"base_revision":1}`)
	defer delete(busy_undo)
	testing.expect_value(t, busy_undo, `{"ok":false,"error":"Busy_Composing"}`)

	// Stale commit during composition still reports Stale_Revision rather than Busy_Composing.
	stale_during_comp := dispatch_window_line(&model, &state, adapter, `{"op":"commit","id":1,"base_revision":0,"text":"Stale"}`)
	defer delete(stale_during_comp)
	testing.expect_value(t, stale_during_comp, `{"ok":false,"error":"Stale_Revision","revision":1}`)

	testing.expect_value(t, title_model.snapshot(&model).text, "Quarterly results!")
	testing.expect_value(t, title_model.snapshot(&model).revision, dagda.Revision(1))
	testing.expect_value(t, state.preedit_text, "café")
	testing.expect_value(t, state.composing, true)
	testing.expect_value(t, state.focused, true)

	// Cancel composition, then verify non-blocking server handles a partial client without blocking another client.
	esc_ev: sdl.Event
	esc_ev.type = .KEY_DOWN
	esc_ev.key.key = sdl.K_ESCAPE
	editor_handle_sdl_event(&state, adapter, &esc_ev, TEST_TITLE_BOX)

	sock_dir := fmt.tprintf("/tmp/dagda-win-drv-test-%d", posix.getpid())
	_ = os.make_directory(sock_dir)
	defer _ = os.remove(sock_dir)
	sock_path := fmt.tprintf("%s/title.sock", sock_dir)

	srv: Window_Driver_Server
	testing.expect(t, driver_server_start(&srv, sock_path), "Expected driver server to start")
	defer driver_server_stop(&srv)

	// Client 1 connects and sends only a partial line (no newline yet).
	c1, c1_ok := driver.connect_unix(sock_path)
	testing.expect(t, c1_ok)
	defer posix.close(c1)
	testing.expect(t, driver.write_all(c1, `{"op":"insp`))
	driver_server_poll(&srv, &model, &state, adapter)

	// Client 2 connects while Client 1 is still partial and completes a commit immediately.
	c2, c2_ok := driver.connect_unix(sock_path)
	testing.expect(t, c2_ok)
	defer posix.close(c2)
	testing.expect(t, driver.write_all(c2, "{\"op\":\"commit\",\"id\":1,\"base_revision\":1,\"text\":\"Revenue grew 12%\"}\n"))
	driver_server_poll(&srv, &model, &state, adapter)
	driver_server_poll(&srv, &model, &state, adapter)

	r2 := driver.Line_Reader{fd = c2}
	rep2, ok2 := driver.read_line(&r2)
	defer delete(rep2)
	testing.expect(t, ok2)
	testing.expect_value(t, rep2, `{"ok":true,"id":1,"revision":2,"text":"Revenue grew 12%"}`)
	testing.expect_value(t, state.committed_text, "Revenue grew 12%")
	testing.expect_value(t, state.focused, true)

	// Client 1 now finishes its partial inspect line and observes rev 2.
	testing.expect(t, driver.write_all(c1, "ect\",\"role\":\"slide.title\"}\n"))
	driver_server_poll(&srv, &model, &state, adapter)
	driver_server_poll(&srv, &model, &state, adapter)

	r1 := driver.Line_Reader{fd = c1}
	rep1, ok1 := driver.read_line(&r1)
	defer delete(rep1)
	testing.expect(t, ok1)
	testing.expect_value(t, rep1, `{"ok":true,"id":1,"revision":2,"text":"Revenue grew 12%","role":"slide.title"}`)
}

@(test)
test_busy_status_uses_guard_outcome_not_reply_text :: proc(t: ^testing.T) {
	model := make_test_model(t, "Busy_Composing")
	defer title_model.destroy(&model)
	adapter := title_model_adapter(&model)

	state: Editor_State
	editor_init(&state, adapter)
	defer editor_destroy(&state)

	state.needs_redraw = false

	// Successful inspect whose title text equals "Busy_Composing" must preserve UI status.
	insp := dispatch_window_line(&model, &state, adapter, `{"op":"inspect","role":"slide.title"}`)
	defer delete(insp)
	testing.expect_value(t, insp, `{"ok":true,"id":1,"revision":0,"text":"Busy_Composing","role":"slide.title"}`)
	testing.expect_value(t, state.last_status, "Ready")
	testing.expect_value(t, state.needs_redraw, false)

	// Successful preview whose text equals "Busy_Composing" must also preserve UI status.
	prev := dispatch_window_line(&model, &state, adapter, `{"op":"preview","id":1,"base_revision":0,"text":"Busy_Composing"}`)
	defer delete(prev)
	testing.expect_value(t, prev, `{"ok":true,"id":1,"revision":0,"text":"Busy_Composing"}`)
	testing.expect_value(t, state.last_status, "Ready")
	testing.expect_value(t, state.needs_redraw, false)

	// During composition, successful reads still preserve the composing status.
	edit_ev: sdl.Event
	edit_ev.type = .TEXT_EDITING
	edit_ev.edit.text = "café"
	edit_ev.edit.start = 2
	edit_ev.edit.length = 0
	editor_handle_sdl_event(&state, adapter, &edit_ev, TEST_TITLE_BOX)
	state.needs_redraw = false

	insp2 := dispatch_window_line(&model, &state, adapter, `{"op":"inspect","role":"slide.title"}`)
	defer delete(insp2)
	testing.expect_value(t, state.last_status, "Composing (uncommitted preedit)")
	testing.expect_value(t, state.needs_redraw, false)

	// A genuine composition rejection sets the busy status and requests a redraw.
	busy := dispatch_window_line(&model, &state, adapter, `{"op":"commit","id":1,"base_revision":0,"text":"Other"}`)
	defer delete(busy)
	testing.expect_value(t, busy, `{"ok":false,"error":"Busy_Composing"}`)
	testing.expect_value(t, state.last_status, "Driver blocked: Busy_Composing (retry after preedit)")
	testing.expect_value(t, state.needs_redraw, true)
}

@(test)
test_watch_stream_events_and_no_spurious_notifications :: proc(t: ^testing.T) {
	model := make_test_model(t, "Quarterly results")
	defer title_model.destroy(&model)
	adapter := title_model_adapter(&model)

	state: Editor_State
	editor_init(&state, adapter)
	defer editor_destroy(&state)

	sock_dir := fmt.tprintf("/tmp/dagda-win-watch-test-%d", posix.getpid())
	_ = os.make_directory(sock_dir)
	defer _ = os.remove(sock_dir)
	sock_path := fmt.tprintf("%s/title.sock", sock_dir)

	srv: Window_Driver_Server
	testing.expect(t, driver_server_start(&srv, sock_path), "Expected driver server to start")
	driver_server_attach_model(&srv, &model)
	defer title_model.clear_observer(&model)
	defer driver_server_stop(&srv)

	// Watcher connects and subscribes to slide.title.
	w1, w1_ok := driver.connect_unix(sock_path)
	testing.expect(t, w1_ok)
	defer posix.close(w1)
	testing.expect(t, driver.write_all(w1, "{\"op\":\"watch\",\"role\":\"slide.title\"}\n"))
	driver_server_poll(&srv, &model, &state, adapter)
	driver_server_poll(&srv, &model, &state, adapter)

	r1 := driver.Line_Reader{fd = w1}
	init_line, ok_init := driver.read_line(&r1)
	defer delete(init_line)
	testing.expect(t, ok_init)
	testing.expect_value(t, init_line, `{"ok":true,"id":1,"revision":0,"text":"Quarterly results","role":"slide.title"}`)

	// Preview, no-op commit, stale commit, and busy commit during preedit must emit NO events.
	prev := dispatch_window_line(&model, &state, adapter, `{"op":"preview","id":1,"base_revision":0,"text":"Preview only"}`)
	delete(prev)
	noop := dispatch_window_line(&model, &state, adapter, `{"op":"commit","id":1,"base_revision":0,"text":"Quarterly results"}`)
	delete(noop)
	stale := dispatch_window_line(&model, &state, adapter, `{"op":"commit","id":1,"base_revision":9,"text":"Stale"}`)
	delete(stale)

	edit_ev: sdl.Event
	edit_ev.type = .TEXT_EDITING
	edit_ev.edit.text = "café"
	edit_ev.edit.start = 2
	edit_ev.edit.length = 0
	editor_handle_sdl_event(&state, adapter, &edit_ev, TEST_TITLE_BOX)
	busy := dispatch_window_line(&model, &state, adapter, `{"op":"commit","id":1,"base_revision":0,"text":"Blocked"}`)
	delete(busy)
	esc_ev: sdl.Event
	esc_ev.type = .KEY_DOWN
	esc_ev.key.key = sdl.K_ESCAPE
	editor_handle_sdl_event(&state, adapter, &esc_ev, TEST_TITLE_BOX)
	driver_server_poll(&srv, &model, &state, adapter)

	// Confirm watcher socket has no pending bytes after non-mutating/rejected operations.
	pfd := posix.pollfd{fd = w1, events = {.IN}}
	testing.expect_value(t, posix.poll(&pfd, 1, 0), c.int(0))

	// Human typing emits commit at rev 1.
	type_ev: sdl.Event
	type_ev.type = .TEXT_INPUT
	type_ev.text.text = "!"
	editor_handle_sdl_event(&state, adapter, &type_ev, TEST_TITLE_BOX)
	driver_server_poll(&srv, &model, &state, adapter)

	ev1, ok1 := driver.read_line(&r1)
	defer delete(ev1)
	testing.expect(t, ok1)
	testing.expect_value(t, ev1, `{"event":"commit","id":1,"revision":1,"text":"Quarterly results!"}`)

	// External commit emits commit at rev 2.
	ext := dispatch_window_line(&model, &state, adapter, `{"op":"commit","id":1,"base_revision":1,"text":"Revenue grew 12%"}`)
	delete(ext)
	driver_server_poll(&srv, &model, &state, adapter)

	ev2, ok2 := driver.read_line(&r1)
	defer delete(ev2)
	testing.expect(t, ok2)
	testing.expect_value(t, ev2, `{"event":"commit","id":1,"revision":2,"text":"Revenue grew 12%"}`)

	// Keyboard undo emits undo at rev 3.
	undo_ev: sdl.Event
	undo_ev.type = .KEY_DOWN
	undo_ev.key.key = sdl.K_Z
	undo_ev.key.mod = sdl.KMOD_LCTRL
	editor_handle_sdl_event(&state, adapter, &undo_ev, TEST_TITLE_BOX)
	driver_server_poll(&srv, &model, &state, adapter)

	ev3, ok3 := driver.read_line(&r1)
	defer delete(ev3)
	testing.expect(t, ok3)
	testing.expect_value(t, ev3, `{"event":"undo","id":1,"revision":3,"text":"Quarterly results!"}`)

	// Reconnect a second watcher: receives latest snapshot at rev 3 immediately.
	w2, w2_ok := driver.connect_unix(sock_path)
	testing.expect(t, w2_ok)
	defer posix.close(w2)
	testing.expect(t, driver.write_all(w2, "{\"op\":\"watch\",\"role\":\"slide.title\"}\n"))
	driver_server_poll(&srv, &model, &state, adapter)
	driver_server_poll(&srv, &model, &state, adapter)

	r2 := driver.Line_Reader{fd = w2}
	reconn, ok_reconn := driver.read_line(&r2)
	defer delete(reconn)
	testing.expect(t, ok_reconn)
	testing.expect_value(t, reconn, `{"ok":true,"id":1,"revision":3,"text":"Quarterly results!","role":"slide.title"}`)
}
