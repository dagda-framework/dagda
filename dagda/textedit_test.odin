#+build !js
package dagda

import "core:mem"
import "core:strings"
import "core:testing"

// App owns committed text, revision, and one-step undo history.
Test_App :: struct {
	text:     string,
	revision: int,
	history:  string,
	has_hist: bool,
}

app_init :: proc(app: ^Test_App, text: string) {
	app.text = strings.clone(text)
}

app_destroy :: proc(app: ^Test_App) {
	delete(app.text)
	delete(app.history)
	app^ = {}
}

app_commit :: proc(app: ^Test_App, session: ^Text_Session, edit: ^Text_Edit) -> bool {
	if !edit.changed {
		return false
	}
	delete(app.history)
	app.history = app.text
	app.has_hist = true
	app.text = strings.clone(edit.text)
	app.revision += 1
	apply_edit(session, edit^, app.text) // accepted: caret moves now
	return true
}

app_undo :: proc(app: ^Test_App, session: ^Text_Session) -> bool {
	if !app.has_hist {
		return false
	}
	delete(app.text)
	app.text = app.history
	app.history = ""
	app.has_hist = false
	app.revision += 1
	session.caret = len(app.text)
	session.anchor = session.caret
	return true
}

apply :: proc(app: ^Test_App, session: ^Text_Session, edit: ^Text_Edit) -> bool {
	committed := app_commit(app, session, edit)
	edit_destroy(session, edit)
	return committed
}

@(test)
test_backspace_decomposed_and_emoji :: proc(t: ^testing.T) {
	// Decomposed "Cafe" + combining acute (U+0301, bytes CC 81):
	// one Backspace removes the whole grapheme, leaving "Caf".
	app: Test_App
	app_init(&app, "Cafe\xcc\x81")
	defer app_destroy(&app)
	session: Text_Session
	text_session_init(&session, app.text)
	defer text_session_destroy(&session)

	edit := backspace(&session, app.text)
	testing.expect_value(t, edit.text, "Caf")
	testing.expect(t, apply(&app, &session, &edit))
	testing.expect_value(t, app.text, "Caf")
	testing.expect_value(t, app.revision, 1)
	testing.expect(t, app_undo(&app, &session))
	testing.expect_value(t, app.text, "Cafe\xcc\x81") // exact original bytes
	testing.expect_value(t, app.revision, 2)

	// "A" + woman technologist (ZWJ emoji sequence): one
	// Backspace removes the whole sequence, leaving "A".
	app2: Test_App
	app_init(&app2, "A👩‍💻")
	defer app_destroy(&app2)
	session2: Text_Session
	text_session_init(&session2, app2.text)
	defer text_session_destroy(&session2)

	edit2 := backspace(&session2, app2.text)
	testing.expect_value(t, edit2.text, "A")
	testing.expect(t, apply(&app2, &session2, &edit2))
	testing.expect(t, app_undo(&app2, &session2))
	testing.expect_value(t, app2.text, "A👩‍💻") // exact original bytes
}

fail_alloc_proc :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	if mode == .Alloc || mode == .Alloc_Non_Zeroed {
		return nil, .Out_Of_Memory
	}
	return nil, nil
}

@(test)
test_proposed_edit_safety :: proc(t: ^testing.T) {
	app: Test_App
	app_init(&app, "\xcc\x81abc") // leading combining acute
	defer app_destroy(&app)
	session: Text_Session
	text_session_init(&session, app.text)
	defer text_session_destroy(&session)
	session.caret = 0
	session.anchor = 0

	// Inserting "e" before U+0301 forms one grapheme: the
	// proposed caret lands after the whole character, and the
	// session does not move until the app accepts.
	edit := insert_text(&session, app.text, "e")
	testing.expect_value(t, edit.err, Edit_Error.None)
	testing.expect_value(t, edit.text, "e\xcc\x81abc")
	testing.expect_value(t, edit.caret, len("e\xcc\x81"))
	testing.expect_value(t, session.caret, 0)
	testing.expect(t, apply(&app, &session, &edit))
	testing.expect_value(t, session.caret, len("e\xcc\x81"))

	// Identical replacement is a no-op with empty text. The
	// endpoints span the whole formed grapheme (e + U+0301).
	session.caret = 0
	session.anchor = len("e\xcc\x81")
	noop := replace_range(&session, app.text, 0, len("e\xcc\x81"), "e\xcc\x81")
	testing.expect_value(t, noop.err, Edit_Error.None)
	testing.expect(t, !noop.changed)
	testing.expect_value(t, noop.text, "")
	edit_destroy(&session, &noop)

	// Invalid inputs and ranges fail explicitly, session intact.
	bad_input := insert_text(&session, app.text, "a\nb")
	testing.expect_value(t, bad_input.err, Edit_Error.Invalid_Input)
	testing.expect(t, !bad_input.changed && bad_input.text == "")
	bad_range := replace_range(&session, app.text, 0, 999, "x")
	testing.expect_value(t, bad_range.err, Edit_Error.Invalid_Range)
	// Endpoints splitting a grapheme or a UTF-8 code point are
	// invalid too, including when the edit would be a no-op.
	split_grapheme := replace_range(&session, app.text, 1, len("e\xcc\x81"), "e")
	testing.expect_value(t, split_grapheme.err, Edit_Error.Invalid_Range)
	testing.expect(t, !split_grapheme.changed && split_grapheme.text == "")
	split_rune := replace_range(&session, "A\xf0\x9f\x91\xa9B", 1, 2, "x")
	testing.expect_value(t, split_rune.err, Edit_Error.Invalid_Range)
	testing.expect_value(t, session.caret, 0)
	testing.expect_value(t, session.anchor, len("e\xcc\x81"))

	// Allocation failure: explicit error, nothing to commit,
	// prior caret/selection and prior preedit preserved.
	testing.expect_value(t, begin_composition(&session, "old", 0, 0), Edit_Error.None)
	saved_allocator := session.allocator
	session.allocator = mem.Allocator{procedure = fail_alloc_proc, data = nil}
	failed := backspace(&session, app.text)
	testing.expect_value(t, failed.err, Edit_Error.Alloc_Failed)
	testing.expect(t, !failed.changed && failed.text == "")
	testing.expect_value(t, begin_composition(&session, "new", 0, 0), Edit_Error.Alloc_Failed)
	testing.expect_value(t, session.preedit, "old")
	testing.expect(t, is_composing(&session))
	// The nil allocator reports no error but supplies no storage:
	// the same explicit failure, with state preserved.
	session.allocator = mem.nil_allocator()
	nil_failed := backspace(&session, app.text)
	testing.expect_value(t, nil_failed.err, Edit_Error.Alloc_Failed)
	testing.expect(t, !nil_failed.changed && nil_failed.text == "")
	testing.expect_value(t, begin_composition(&session, "new", 0, 0), Edit_Error.Alloc_Failed)
	testing.expect_value(t, session.preedit, "old")
	testing.expect(t, is_composing(&session))
	session.allocator = saved_allocator
	testing.expect(t, cancel_composition(&session))
}

@(test)
test_caret_selection_and_delete :: proc(t: ^testing.T) {
	app: Test_App
	app_init(&app, "A👩‍💻B")
	defer app_destroy(&app)
	session: Text_Session
	text_session_init(&session, app.text)
	defer text_session_destroy(&session)

	// Caret moves by grapheme: end -> before B -> before the emoji.
	move_left(&session, app.text)
	testing.expect_value(t, session.caret, len("A👩‍💻"))
	move_left(&session, app.text)
	testing.expect_value(t, session.caret, len("A"))
	move_right(&session, app.text, true) // extend over the emoji
	testing.expect(t, has_selection(&session))
	edit := backspace(&session, app.text)
	testing.expect_value(t, edit.text, "AB")
	testing.expect(t, apply(&app, &session, &edit))

	// Delete removes the grapheme ahead of the caret.
	move_home(&session)
	edit2 := delete_forward(&session, app.text)
	testing.expect_value(t, edit2.text, "B")
	testing.expect(t, apply(&app, &session, &edit2))
	testing.expect_value(t, app.text, "B")
}

@(test)
test_composition_lifecycle :: proc(t: ^testing.T) {
	app: Test_App
	app_init(&app, "Quarterly results")
	defer app_destroy(&app)
	session: Text_Session
	text_session_init(&session, app.text)
	defer text_session_destroy(&session)

	// Select "results" and start a preedit over it.
	move_end(&session, app.text)
	for _ in 0 ..< len("results") {
		move_left(&session, app.text, true)
	}
	testing.expect(t, has_selection(&session))
	testing.expect(t, !is_composing(&session)) // host guard: external edits allowed

	begin_composition(&session, "café", 2, 0)
	testing.expect(t, is_composing(&session)) // host guard: block external edits
	testing.expect_value(t, app.text, "Quarterly results")
	testing.expect_value(t, app.revision, 0)

	// Cancellation preserves committed text and revision.
	testing.expect(t, cancel_composition(&session))
	testing.expect(t, !is_composing(&session))
	testing.expect_value(t, app.text, "Quarterly results")
	testing.expect_value(t, app.revision, 0)
	testing.expect(t, has_selection(&session))

	// Committing the composed text produces exactly one edit.
	begin_composition(&session, "café", 0, 0)
	edit := commit_composition(&session, app.text)
	testing.expect(t, edit.changed)
	testing.expect(t, apply(&app, &session, &edit))
	testing.expect_value(t, app.text, "Quarterly café")
	testing.expect_value(t, app.revision, 1)
	testing.expect(t, !is_composing(&session))
}

@(test)
test_set_caret_clamps_to_grapheme_boundaries_and_extends_both_directions :: proc(t: ^testing.T) {
	// "Ae\u0301B": 'A' (0..1), 'e' + U+0301 (1..4), 'B' (4..5).
	text := "Ae\u0301B"
	session: Text_Session
	text_session_init(&session, text)
	defer text_session_destroy(&session)

	// Mid-grapheme offset (byte 2, between 'e' and U+0301) clamps to grapheme start (1).
	set_caret(&session, text, 2, false)
	testing.expect_value(t, session.anchor, 1)
	testing.expect_value(t, session.caret, 1)

	// Extend right across decomposed e+U+0301 to byte 4.
	set_caret(&session, text, 4, true)
	testing.expect_value(t, session.anchor, 1)
	testing.expect_value(t, session.caret, 4)

	// Extend past right end clamps to len(text).
	set_caret(&session, text, 99, true)
	testing.expect_value(t, session.anchor, 1)
	testing.expect_value(t, session.caret, len(text))

	// Extend past left end clamps to 0 while anchor stays fixed.
	set_caret(&session, text, -10, true)
	testing.expect_value(t, session.anchor, 1)
	testing.expect_value(t, session.caret, 0)
}

@(test)
test_multiline_session_validation_lines_and_newlines :: proc(t: ^testing.T) {
	testing.expect(t, valid_multiline(""))
	testing.expect(t, valid_multiline("one\ntwo\n"))
	testing.expect(t, !valid_multiline("one\r\ntwo"))
	testing.expect(t, !valid_multiline("one\rtwo"))

	norm, ok := normalize_multiline_newlines("a\r\nb\rc\nd")
	testing.expect(t, ok)
	defer delete(norm)
	testing.expect_value(t, norm, "a\nb\nc\nd")

	norm_fail, ok_fail := normalize_multiline_newlines("a\r\nb", mem.nil_allocator())
	testing.expect(t, !ok_fail)
	testing.expect_value(t, norm_fail, "")

	s := "one\ntwo\nthree\n"
	testing.expect_value(t, line_start_offset(s, 0), 0)
	testing.expect_value(t, line_end_offset(s, 0), 3)
	testing.expect_value(t, line_start_offset(s, 5), 4)
	testing.expect_value(t, line_end_offset(s, 5), 7)
	testing.expect_value(t, line_start_offset(s, len(s)), len(s))
	testing.expect_value(t, line_end_offset(s, len(s)), len(s))

	session: Text_Session
	text_session_init(&session, s, context.allocator, multiline = true)
	defer text_session_destroy(&session)

	set_caret(&session, s, 5, false)
	move_line_home(&session, s, false)
	testing.expect_value(t, session.caret, 4)
	move_line_end(&session, s, true)
	testing.expect_value(t, session.anchor, 4)
	testing.expect_value(t, session.caret, 7)

	// Enter inside middle of line "abcd" at byte 2 proposes "ab\ncd" with caret at 3.
	s2 := "abcd"
	set_caret(&session, s2, 2, false)
	e1 := insert_text(&session, s2, "\n")
	defer edit_destroy(&session, &e1)
	testing.expect_value(t, e1.err, Edit_Error.None)
	testing.expect(t, e1.changed)
	testing.expect_value(t, e1.text, "ab\ncd")
	testing.expect_value(t, e1.caret, 3)
}
