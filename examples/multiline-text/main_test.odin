package main

import "core:mem"
import "core:testing"
import "dagda:dagda"

@(test)
test_replace_atomic_on_history_growth_and_clone_failure :: proc(t: ^testing.T) {
	// 1. History-growth failure via local note_commit and driver note_edit:
	//    text, revision, and undo history stay untouched and cloned text is freed.
	n1: Note_App
	note_init(&n1, "old", 0)
	defer note_destroy(&n1)
	n1.body.undo.allocator = mem.nil_allocator()

	testing.expect(t, !note_commit(&n1, BODY_ID, "new"))
	testing.expect_value(t, n1.body.text, "old")
	testing.expect_value(t, n1.body.rev, dagda.Revision(0))
	testing.expect_value(t, len(n1.body.undo), 0)

	res1 := note_edit(&n1, {id = BODY_ID, base_revision = 0}, EDIT_REPLACE_TEXT, {kind = .Text, text = "driver\nnew"})
	testing.expect_value(t, res1, dagda.Edit_Result.Not_Handled)
	testing.expect_value(t, n1.body.text, "old")
	testing.expect_value(t, n1.body.rev, dagda.Revision(0))
	testing.expect_value(t, len(n1.body.undo), 0)

	// 2. Clone failure via local note_commit and driver note_edit:
	//    text, revision, and undo history stay untouched.
	n2: Note_App
	note_init(&n2, "old", 0)
	orig_alloc := n2.allocator
	defer {
		n2.allocator = orig_alloc
		note_destroy(&n2)
	}
	n2.allocator = mem.nil_allocator()

	testing.expect(t, !note_commit(&n2, BODY_ID, "new"))
	testing.expect_value(t, n2.body.text, "old")
	testing.expect_value(t, n2.body.rev, dagda.Revision(0))
	testing.expect_value(t, len(n2.body.undo), 0)

	res2 := note_edit(&n2, {id = BODY_ID, base_revision = 0}, EDIT_REPLACE_TEXT, {kind = .Text, text = "driver\nnew"})
	testing.expect_value(t, res2, dagda.Edit_Result.Not_Handled)
	testing.expect_value(t, n2.body.text, "old")
	testing.expect_value(t, n2.body.rev, dagda.Revision(0))
	testing.expect_value(t, len(n2.body.undo), 0)
}
