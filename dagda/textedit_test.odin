package dagda

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
	text_session_sync(session, app.text)
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
