package main

import "core:mem"
import "core:strings"
import "core:testing"
import "dagda:dagda"

Budget_State :: struct {
	backing: mem.Allocator,
	allowed: int,
}

budget_alloc_proc :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	state := (^Budget_State)(data)
	if mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed {
		if state.allowed <= 0 {
			return nil, .Out_Of_Memory
		}
		state.allowed -= 1
	}
	return state.backing.procedure(state.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

make_slide :: proc(t: ^testing.T) -> Slide_Canvas {
	slide := Slide_Canvas{headline = strings.clone("Slide Canvas"), card = {x = 1, y = 2, width = 3, height = 4}}
	slide.headline_rev = 5
	append(&slide.undo_stack, Undo_Entry{kind = .Card_Rect, rect = slide.card})
	return slide
}

assert_preserved :: proc(t: ^testing.T, s: ^Slide_Canvas) {
	testing.expect_value(t, s.headline, "Slide Canvas")
	testing.expect_value(t, s.headline_rev, u64(5))
	testing.expect(t, len(s.undo_stack) == 1)
	testing.expect_value(t, s.undo_stack[0].kind, Undo_Kind.Card_Rect)
}

@(test)
test_headline_commit_clone_alloc_failure :: proc(t: ^testing.T) {
	slide := make_slide(t)
	defer slide_destroy(&slide)
	state := Budget_State{backing = context.allocator, allowed = 0}
	saved := context.allocator
	context.allocator = mem.Allocator{procedure = budget_alloc_proc, data = &state}
	result := slide_commit_headline(&slide, "New title")
	context.allocator = saved
	testing.expect_value(t, result, dagda.Edit_Result.Alloc_Failed)
	assert_preserved(t, &slide)
}

@(test)
test_headline_commit_history_alloc_failure :: proc(t: ^testing.T) {
	slide := make_slide(t)
	defer slide_destroy(&slide)
	// Force the undo stack to grow on the next append (len == cap).
	delete(slide.undo_stack)
	slide.undo_stack = make([dynamic]Undo_Entry, 0, 1)
	append(&slide.undo_stack, Undo_Entry{kind = .Card_Rect, rect = slide.card})
	// The text clone (first allocation) succeeds; growing the
	// undo history (second) fails, the clone is released, and
	// the original text, revision, and history are preserved.
	state := Budget_State{backing = context.allocator, allowed = 1}
	saved := context.allocator
	context.allocator = mem.Allocator{procedure = budget_alloc_proc, data = &state}
	result := slide_commit_headline(&slide, "New title")
	context.allocator = saved
	testing.expect_value(t, result, dagda.Edit_Result.Alloc_Failed)
	assert_preserved(t, &slide)

	// The same commit succeeds with a working allocator.
	testing.expect_value(t, slide_commit_headline(&slide, "New title"), dagda.Edit_Result.Applied)
	testing.expect_value(t, slide.headline, "New title")
	testing.expect_value(t, slide.headline_rev, u64(6))
	testing.expect(t, len(slide.undo_stack) == 2)
}
