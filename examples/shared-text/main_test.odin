package main

import "core:mem"
import "core:testing"
import "dagda:dagda"

@(test)
test_shared_commit_atomic_on_undo_stack_alloc_failure :: proc(t: ^testing.T) {
	// Use a failing allocator specifically for undo_stack so strings.clone succeeds
	// while undo_stack growth fails, proving shared_commit rejects atomically and
	// releases the temporary cloned string without leaking or mutating state.
	state: Shared_Text_App
	testing.expect(t, shared_init(&state, "Slide Title"))
	defer shared_destroy(&state)

	state.undo_stack.allocator = mem.panic_allocator()
	// Replace with an allocator that cleanly returns .Out_Of_Memory.
	fail_proc :: proc(
		allocator_data: rawptr,
		mode: mem.Allocator_Mode,
		size, alignment: int,
		old_memory: rawptr,
		old_size: int,
		location := #caller_location,
	) -> ([]byte, mem.Allocator_Error) {
		if mode == .Free || mode == .Free_All {
			return nil, .None
		}
		return nil, .Out_Of_Memory
	}
	state.undo_stack.allocator = mem.Allocator{procedure = fail_proc}

	ok := shared_commit(&state, OUTLINE_TITLE_ID, "ASlide Title")
	testing.expect_value(t, ok, false)
	testing.expect_value(t, state.title, "Slide Title")
	testing.expect_value(t, state.rev, u64(0))
	testing.expect_value(t, len(state.undo_stack), 0)
	testing.expect_value(t, state.last_editor_id, dagda.Object_Id(0))
}
