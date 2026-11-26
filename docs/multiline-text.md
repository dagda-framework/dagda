# Editable multiline text

A single-line field refuses line breaks. A field listed in
`sdlhost.App.multiline_text_targets` accepts hard line breaks
instead, while everything else about editing stays the same:
the host owns the caret, selection and IME composition, and the
app owns the committed text, its revision and its undo history.

This guide uses [examples/multiline-text](../examples/multiline-text/)
as its source. Its window holds an editable body (ID 1) and an
editable title (ID 2). Both IDs are editable; only the body is
multiline, so the title keeps refusing Enter and multi-line
pastes.

## Wiring

```odin
package main

import "core:os"
import "core:strings"
import "core:unicode/utf8"
import "dagda:dagda"
import "dagda:dagda/sdlhost"

BODY_ID :: dagda.Object_Id(1)
TITLE_ID :: dagda.Object_Id(2)

Field :: struct {
	text: string,
	rev:  dagda.Revision,
	undo: [dynamic]string,
}

Note_App :: struct {
	body:         Field,
	title:        Field,
	editable_ids: [2]dagda.Object_Id,
	body_ids:     [1]dagda.Object_Id,
	elements:     [2]dagda.Canvas_Element,
}

replace :: proc(f: ^Field, new_text: string) -> bool {
	cloned, clone_err := strings.clone(new_text)
	if clone_err != nil {
		return false
	}
	if _, push_err := append(&f.undo, f.text); push_err != nil {
		delete(cloned)
		return false
	}
	f.text = cloned
	f.rev += 1
	return true
}

note_commit :: proc(user_data: rawptr, id: dagda.Object_Id, new_text: string) -> bool {
	n := (^Note_App)(user_data)
	f := id == BODY_ID ? &n.body : &n.title
	acceptable := id == BODY_ID ? (utf8.valid_string(new_text) && !strings.contains_rune(new_text, '\r')) : dagda.valid_single_line(new_text)
	if !acceptable || new_text == f.text {
		return false
	}
	return replace(f, new_text)
}

note_undo :: proc(user_data: rawptr, id: dagda.Object_Id) -> bool {
	n := (^Note_App)(user_data)
	f := id == BODY_ID ? &n.body : &n.title
	if len(f.undo) == 0 {
		return false
	}
	delete(f.text)
	f.text = pop(&f.undo)
	f.rev += 1
	return true
}

note_canvas :: proc(user_data: rawptr) -> dagda.Canvas {
	n := (^Note_App)(user_data)
	n.elements = {
		{info = {id = BODY_ID, role = "note.body"}, kind = .Label, text = n.body.text, bounds = {x = 80, y = 40, width = 800, height = 280}},
		{info = {id = TITLE_ID, role = "note.title"}, kind = .Label, text = n.title.text, bounds = {x = 80, y = 350, width = 800, height = 64}},
	}
	return {size = {width = 960, height = 540}, elements = n.elements[:]}
}

main :: proc() {
	state := Note_App{
		body         = {text = strings.clone("")},
		title        = {text = strings.clone("Title")},
		editable_ids = {BODY_ID, TITLE_ID},
		body_ids     = {BODY_ID},
	}
	opts, ok := sdlhost.parse_cli_args(os.args[1:])
	if !ok {
		os.exit(2)
	}
	app := sdlhost.App{
		title                  = "Dagda — Note",
		width                  = 960,
		height                 = 540,
		user_data              = &state,
		canvas                 = note_canvas,
		text_edit              = {enabled = true, on_commit = note_commit, on_undo = note_undo},
		editable_text_targets  = state.editable_ids[:],
		multiline_text_targets = state.body_ids[:],
	}
	if code := sdlhost.run(app, opts); code != 0 {
		os.exit(code)
	}
}
```

Two lists, two jobs:

- `editable_text_targets` names every field the person can
  edit — here both document IDs, `{BODY_ID, TITLE_ID}`.
- `multiline_text_targets` names the subset that may contain
  hard line breaks — here only `{BODY_ID}`. Listing an ID here
  alone does not make it editable; it must also be editable.

Both slices come from arrays stored in the app state itself
(`state.editable_ids`, `state.body_ids`). That storage is the
stable backing the host borrows: `sdlhost.run` copies each
slice descriptor (base address and length) at startup and
reads the backing array until it returns, so keep those arrays
at a stable address for the whole run and only refresh their
entries from the host-thread builder. Reassigning a local
variable to a new slice after startup changes nothing.

## What `on_commit` must do

The host never hands the app a keystroke. For every accepted
gesture it builds the **full proposed replacement** for the
field's text — caret moves, selections and any preedit already
folded in — and calls `on_commit(user_data, id, new_text)`.
Before returning `true`, the app must:

1. Validate the whole proposal under its own rules (the
   example accepts a body only as valid UTF-8 with LF-only
   line breaks and at most a configured line count; the title
   must satisfy `dagda.valid_single_line`).
2. Clone the bytes it will keep. The proposal borrows host
   storage; do not retain the slice itself.
3. Append the field's previous text to its undo history
   exactly once, then install the clone and advance that
   field's revision by exactly one.

Only then return `true`: one accepted edit is one revision
and one undo entry, however many lines it touched. If cloning
or growing the history can fail, do both before publishing
anything, so a failure can still return `false` with the
document untouched — the example's `replace` clones first,
appends second, and only then swaps the text in.

Returning `false` refuses the edit. The committed text,
revision and undo history stay exactly as they were, and the
host preserves the person's caret, selection and any active
composition so they can keep typing or retry.

## Enter, then X: the `ab|cd` walkthrough

Start with the body holding `abcd` and the caret between `b`
and `c` — written `ab|cd`. Pressing Enter does not send the
app an "Enter event". The host proposes the whole replacement
`ab\ncd`, which one accepted commit stores as one revision
and one undo entry, leaving the caret at the start of the new
second line. Typing `X` next proposes `ab\nXcd` — again one
full replacement, one revision, one undo entry. Even when
Enter and `X` arrive queued in the same input batch, the app
sees those two complete proposals in order, never fragments.

## Hard breaks, paste, and refusals

- **Hard line breaks.** Enter inserts a real LF (`\n`) into
  the document. Nothing about wrapping is stored: lines are
  separated only by the LFs the edits put there, and the
  multiline field keeps refusing a raw CR in a proposal.
- **Paste.** The host normalizes clipboard CRLF and lone CR
  to LF before proposing, so pasting `one\r\ntwo\rthree`
  reaches the app as the single proposal `one\ntwo\nthree`.
  One accepted paste is one edit — one revision and one undo
  entry for the whole pasted text, not one per line.
- **Refusals.** If the app returns `false` — say the body
  already has the maximum line count a new break would
  exceed — the proposal is discarded whole: text, revision,
  undo depth, caret and selection all stay put. In the
  example's `--max-lines 2` scenario the body `ab\ncd` refuses
  `ab\nc\nd`, and the next `X` still lands where the caret
  was, committing `ab\ncXd`.

The title shows the contrast: not being in
`multiline_text_targets`, it refuses Enter and a two-line
paste outright, and typing continues on its one line.

## Driver edits

An agent's `replace_text` edit arrives through the app's
driver edit handler, not `on_commit`. For the order of the
revision and composition checks, read `note_edit` in
[examples/multiline-text/main.odin](../examples/multiline-text/main.odin):
it resolves the field, checks `base_revision` against the
field's current revision (`Stale_Revision`), stands aside
while that same field is composing (`Busy_Composing`), and
only then applies the same acceptance rule and one-step
replacement as a keyboard commit.

## Run the example

From a clean checkout, with the pinned compiler installed
(`bash scripts/setup-odin.sh` if needed):

```sh
MULTILINE=1 python3 examples/multiline-text/tests/e2e_multiline_text.py
```

This builds the fixture and the driver client in a temporary
directory under SDL's dummy video driver and drives the real
window process through the scenarios above — hard breaks,
LF-normalized pastes, refusals, compositions and driver
edits. A passing run ends with every scenario marked `PASS`.

