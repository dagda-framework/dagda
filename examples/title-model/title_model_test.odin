package title_model

import "core:mem"
import "core:testing"
import "dagda:dagda"

Fail_State :: struct {
	backing:     mem.Allocator,
	fail_allocs: bool,
}

fail_allocator_proc :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	state := (^Fail_State)(data)
	if state.fail_allocs && (mode == .Alloc || mode == .Alloc_Non_Zeroed) {
		return nil, .Out_Of_Memory
	}
	return state.backing.procedure(state.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

make_model :: proc(t: ^testing.T, text := "Quarterly results") -> Model {
	model: Model
	err := init(&model, {id = 1, role = "slide.title"}, text)
	testing.expect_value(t, err, Error.None)
	return model
}

target_at :: proc(model: ^Model) -> dagda.Action_Target {
	snap := snapshot(model)
	return {id = snap.object.id, base_revision = snap.revision}
}

@(test)
test_transient_input_buffers :: proc(t: ^testing.T) {
	init_buf := []u8{'D', 'r', 'a', 'f', 't'}
	model: Model
	testing.expect_value(t, init(&model, {id = 1, role = "slide.title"}, string(init_buf)), Error.None)
	defer destroy(&model)
	init_buf[0] = 'X'
	testing.expect_value(t, snapshot(&model).text, "Draft")

	commit_buf := []u8{'F', 'i', 'n', 'a', 'l'}
	testing.expect_value(t, commit(&model, target_at(&model), string(commit_buf)), Error.None)
	commit_buf[0] = 'X'
	snap := snapshot(&model)
	testing.expect_value(t, snap.text, "Final")
	testing.expect_value(t, snap.revision, dagda.Revision(1))
}

@(test)
test_preview_independent_and_cleanup :: proc(t: ^testing.T) {
	model := make_model(t)
	defer destroy(&model)
	buf := []u8{'N', 'e', 'x', 't'}
	p, err := preview(&model, target_at(&model), string(buf))
	testing.expect_value(t, err, Error.None)
	buf[0] = 'X'
	testing.expect_value(t, p.text, "Next")
	snap := snapshot(&model)
	testing.expect_value(t, snap.text, "Quarterly results")
	testing.expect_value(t, snap.revision, dagda.Revision(0))
	preview_destroy(&p)
	testing.expect_value(t, p.text, "")
	// Discarding the preview left the document untouched.
	testing.expect_value(t, snapshot(&model).text, "Quarterly results")
	testing.expect(t, !undo(&model))
}

@(test)
test_unknown_and_stale_leave_state_untouched :: proc(t: ^testing.T) {
	model := make_model(t)
	defer destroy(&model)
	snap := snapshot(&model)
	bad_id := dagda.Action_Target{id = 999, base_revision = snap.revision}
	testing.expect_value(t, commit(&model, bad_id, "Other"), Error.Unknown_Object)
	stale := dagda.Action_Target{id = snap.object.id, base_revision = snap.revision + 1}
	testing.expect_value(t, commit(&model, stale, "Other"), Error.Stale_Revision)
	after := snapshot(&model)
	testing.expect_value(t, after.text, "Quarterly results")
	testing.expect_value(t, after.revision, dagda.Revision(0))
	testing.expect(t, !undo(&model))
}

@(test)
test_noop_and_undo_after_noop :: proc(t: ^testing.T) {
	model := make_model(t)
	defer destroy(&model)
	// No-op at revision 0 creates no history.
	testing.expect_value(t, commit(&model, target_at(&model), "Quarterly results"), Error.None)
	testing.expect_value(t, snapshot(&model).revision, dagda.Revision(0))
	testing.expect(t, !undo(&model))
	// Real commit, then a no-op, then one undo restores the original.
	testing.expect_value(t, commit(&model, target_at(&model), "Revenue grew 12%"), Error.None)
	testing.expect_value(t, snapshot(&model).revision, dagda.Revision(1))
	testing.expect_value(t, commit(&model, target_at(&model), "Revenue grew 12%"), Error.None)
	testing.expect_value(t, snapshot(&model).revision, dagda.Revision(1))
	testing.expect(t, undo(&model))
	snap := snapshot(&model)
	testing.expect_value(t, snap.text, "Quarterly results")
	testing.expect_value(t, snap.revision, dagda.Revision(2))
	testing.expect(t, !undo(&model))
	testing.expect_value(t, snapshot(&model).revision, dagda.Revision(2))
}

@(test)
test_stale_retry_after_undo :: proc(t: ^testing.T) {
	model := make_model(t)
	defer destroy(&model)
	rev0 := target_at(&model)
	testing.expect_value(t, commit(&model, rev0, "Revenue grew 12%"), Error.None)
	rev1 := target_at(&model)
	testing.expect(t, undo(&model))
	testing.expect_value(t, snapshot(&model).revision, dagda.Revision(2))
	testing.expect_value(t, commit(&model, rev1, "Late edit"), Error.Stale_Revision)
	testing.expect_value(t, commit(&model, rev0, "Late edit"), Error.Stale_Revision)
	snap := snapshot(&model)
	testing.expect_value(t, snap.text, "Quarterly results")
	testing.expect_value(t, snap.revision, dagda.Revision(2))
}

@(test)
test_empty_undo_reports_no_change :: proc(t: ^testing.T) {
	model := make_model(t)
	defer destroy(&model)
	testing.expect(t, !undo(&model))
	snap := snapshot(&model)
	testing.expect_value(t, snap.text, "Quarterly results")
	testing.expect_value(t, snap.revision, dagda.Revision(0))
}

@(test)
test_alloc_failure_leaves_state_untouched :: proc(t: ^testing.T) {
	state := Fail_State{backing = context.allocator}
	allocator := mem.Allocator{procedure = fail_allocator_proc, data = &state}
	model: Model
	testing.expect_value(t, init(&model, {id = 1, role = "slide.title"}, "Quarterly results", allocator), Error.None)
	defer destroy(&model)
	testing.expect_value(t, commit(&model, target_at(&model), "Revenue grew 12%"), Error.None)

	state.fail_allocs = true
	testing.expect_value(t, commit(&model, target_at(&model), "Blocked"), Error.Alloc_Failed)
	_, preview_err := preview(&model, target_at(&model), "Blocked")
	testing.expect_value(t, preview_err, Error.Alloc_Failed)
	state.fail_allocs = false

	snap := snapshot(&model)
	testing.expect_value(t, snap.text, "Revenue grew 12%")
	testing.expect_value(t, snap.revision, dagda.Revision(1))
	// History from the successful commit survived the failed attempts.
	testing.expect(t, undo(&model))
	testing.expect_value(t, snapshot(&model).text, "Quarterly results")
	testing.expect_value(t, snapshot(&model).revision, dagda.Revision(2))
}

Budget_State :: struct {
	backing: mem.Allocator,
	allowed: int,
}

budget_allocator_proc :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	state := (^Budget_State)(data)
	if mode == .Alloc || mode == .Alloc_Non_Zeroed {
		if state.allowed <= 0 {
			return nil, .Out_Of_Memory
		}
		state.allowed -= 1
	}
	return state.backing.procedure(state.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

@(test)
test_role_owned_not_borrowed :: proc(t: ^testing.T) {
	role_buf := []u8{'s', 'l', 'i', 'd', 'e', '.', 't', 'i', 't', 'l', 'e'}
	model: Model
	testing.expect_value(t, init(&model, {id = 7, role = string(role_buf)}, "Quarterly results"), Error.None)
	defer destroy(&model)
	// Reusing the caller's storage must not change the model's role.
	for &b in role_buf {
		b = 'x'
	}
	snap := snapshot(&model)
	testing.expect_value(t, snap.object.role, "slide.title")
	objects := [1]dagda.Object_Info{snap.object}
	ids: [1]dagda.Object_Id = {999}
	written, total := dagda.find_by_role(objects[:], "slide.title", ids[:])
	testing.expect_value(t, written, 1)
	testing.expect_value(t, total, 1)
	testing.expect_value(t, ids[0], dagda.Object_Id(7))
}

@(test)
test_init_partial_alloc_failure_cleans_up :: proc(t: ^testing.T) {
	// Only the first allocation (text) succeeds; the role clone fails.
	state := Budget_State{backing = context.allocator, allowed = 1}
	allocator := mem.Allocator{procedure = budget_allocator_proc, data = &state}
	model: Model
	testing.expect_value(t, init(&model, {id = 1, role = "slide.title"}, "Quarterly results", allocator), Error.Alloc_Failed)
	testing.expect_value(t, snapshot(&model).text, "")
	testing.expect_value(t, snapshot(&model).object.role, "")
}

@(test)
test_invalid_text_rejected :: proc(t: ^testing.T) {
	model := make_model(t)
	defer destroy(&model)
	testing.expect_value(t, commit(&model, target_at(&model), "\xff\xfe"), Error.Invalid_Text)
	snap := snapshot(&model)
	testing.expect_value(t, snap.text, "Quarterly results")
	testing.expect_value(t, snap.revision, dagda.Revision(0))
}
