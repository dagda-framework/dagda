package main

import "core:mem"
import "core:testing"
import "dagda:dagda/sdlhost"

@(test)
test_fixture_handle_atomic_and_leak_free_on_items_alloc_failure :: proc(t: ^testing.T) {
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

	state: Origin_Fixture
	testing.expect(t, fixture_init(&state, false))
	defer fixture_destroy(&state)

	// Replace items backing with an exact-capacity 1-entry slice using a failing
	// allocator so append must grow and fail, while label allocation succeeds.
	orig_item := state.items[0]
	delete(state.items)
	state.items = make([dynamic]string, 1, 1)
	state.items[0] = orig_item
	state.items.allocator = mem.Allocator{procedure = fail_proc}

	ok := fixture_handle(&state, ADD_BUTTON_ID, .Activate)
	testing.expect_value(t, ok, false)
	testing.expect_value(t, len(state.items), 1)
	testing.expect_value(t, state.items[0], "abcd")
	testing.expect_value(t, state.selected, 0)
	testing.expect_value(t, state.last_origin, sdlhost.Action_Origin.None)
	testing.expect_value(t, state.local_count, 0)
	testing.expect_value(t, state.driver_count, 0)

	// Restore real allocator before fixture_destroy frees state.items.
	state.items.allocator = state.allocator
}
