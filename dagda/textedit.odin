package dagda

import "core:mem"
import "core:strings"
import "core:unicode/utf8"

// Headless single-line text editing. The app owns the committed
// text, its revision, and its undo history; a Text_Session owns
// only the caret, the selection anchor, and the temporary IME
// composition (preedit). Editing operations compute one whole
// replacement string from the committed text the app passes in;
// the app commits that replacement through its own store (and
// can therefore reject, revise, or undo it). SDL or any other
// host event translation stays in the host.
//
// All caret and selection offsets are byte offsets on grapheme
// cluster boundaries, so movement and deletion operate on whole
// user-perceived characters (combining sequences, ZWJ emoji,
// flags, and modified emoji each count as one).

Text_Session :: struct {
	caret:          int,
	anchor:         int,
	preedit:        string, // owned by the session
	preedit_start:  int, // rune index into preedit
	preedit_length: int, // runes
	composing:      bool,
	allocator:      mem.Allocator,
}

// One computed edit. text is owned by the caller (delete it with
// the session allocator, or use edit_destroy); when changed is
// false, text is empty and the app must not commit anything.
Text_Edit :: struct {
	text:    string,
	caret:   int,
	changed: bool,
}

edit_destroy :: proc(session: ^Text_Session, edit: ^Text_Edit) {
	delete(edit.text, session.allocator)
	edit^ = {}
}

text_session_init :: proc(session: ^Text_Session, committed: string, allocator := context.allocator) {
	session^ = {caret = len(committed), anchor = len(committed), allocator = allocator}
}

text_session_destroy :: proc(session: ^Text_Session) {
	delete(session.preedit, session.allocator)
	session^ = {}
}

// text_session_sync re-anchors the caret and selection after the
// committed text changed outside the session (an app commit, an
// undo, or an external edit).
text_session_sync :: proc(session: ^Text_Session, committed: string) {
	session.caret = clamp_grapheme_boundary(committed, session.caret)
	session.anchor = clamp_grapheme_boundary(committed, session.anchor)
}

is_composing :: proc(session: ^Text_Session) -> bool {
	return session.composing
}

selection_bounds :: proc(session: ^Text_Session) -> (start: int, end: int) {
	if session.anchor <= session.caret {
		return session.anchor, session.caret
	}
	return session.caret, session.anchor
}

has_selection :: proc(session: ^Text_Session) -> bool {
	return session.anchor != session.caret
}

clamp_grapheme_boundary :: proc(s: string, offset: int) -> int {
	if offset <= 0 {
		return 0
	}
	if offset >= len(s) {
		return len(s)
	}
	// Largest grapheme start at or before offset.
	result := 0
	it := utf8.decode_grapheme_iterator_make(s)
	for {
		_, grapheme, ok := utf8.decode_grapheme_iterate(&it)
		if !ok || grapheme.byte_index > offset {
			break
		}
		result = grapheme.byte_index
	}
	return result
}

prev_grapheme_boundary :: proc(s: string, offset: int) -> int {
	boundary := clamp_grapheme_boundary(s, offset)
	if boundary == offset && offset > 0 {
		// Step to the start of the grapheme ending at offset.
		prev := 0
		it := utf8.decode_grapheme_iterator_make(s)
		for {
			text, grapheme, ok := utf8.decode_grapheme_iterate(&it)
			if !ok || grapheme.byte_index >= offset {
				break
			}
			_ = text
			prev = grapheme.byte_index
		}
		return prev
	}
	return boundary
}

next_grapheme_boundary :: proc(s: string, offset: int) -> int {
	it := utf8.decode_grapheme_iterator_make(s)
	for {
		text, grapheme, ok := utf8.decode_grapheme_iterate(&it)
		if !ok {
			return len(s)
		}
		end := grapheme.byte_index + len(text)
		if end > offset {
			return end
		}
	}
	return len(s)
}

move_left :: proc(session: ^Text_Session, committed: string, extend_selection := false) {
	if !extend_selection && has_selection(session) {
		start, _ := selection_bounds(session)
		session.caret = start
		session.anchor = start
		return
	}
	session.caret = prev_grapheme_boundary(committed, session.caret)
	if !extend_selection {
		session.anchor = session.caret
	}
}

move_right :: proc(session: ^Text_Session, committed: string, extend_selection := false) {
	if !extend_selection && has_selection(session) {
		_, end := selection_bounds(session)
		session.caret = end
		session.anchor = end
		return
	}
	session.caret = next_grapheme_boundary(committed, session.caret)
	if !extend_selection {
		session.anchor = session.caret
	}
}

move_home :: proc(session: ^Text_Session, extend_selection := false) {
	session.caret = 0
	if !extend_selection {
		session.anchor = 0
	}
}

move_end :: proc(session: ^Text_Session, committed: string, extend_selection := false) {
	session.caret = len(committed)
	if !extend_selection {
		session.anchor = session.caret
	}
}

select_all :: proc(session: ^Text_Session, committed: string) {
	session.anchor = 0
	session.caret = len(committed)
}

replace_range :: proc(session: ^Text_Session, committed: string, start, end: int, inserted: string) -> Text_Edit {
	if start == end && len(inserted) == 0 {
		return {caret = session.caret}
	}
	b: strings.Builder
	strings.builder_init(&b, session.allocator)
	strings.write_string(&b, committed[:start])
	strings.write_string(&b, inserted)
	strings.write_string(&b, committed[end:])
	text := strings.to_string(b)
	caret := start + len(inserted)
	session.caret = caret
	session.anchor = caret
	return {text = text, caret = caret, changed = text != committed}
}

// insert_text replaces the current selection with inserted text
// as one edit (this is what a host calls for committed input).
insert_text :: proc(session: ^Text_Session, committed: string, inserted: string) -> Text_Edit {
	start, end := selection_bounds(session)
	return replace_range(session, committed, start, end, inserted)
}

backspace :: proc(session: ^Text_Session, committed: string) -> Text_Edit {
	start, end := selection_bounds(session)
	if start == end {
		if session.caret == 0 {
			return {caret = session.caret}
		}
		start = prev_grapheme_boundary(committed, session.caret)
		end = session.caret
	}
	return replace_range(session, committed, start, end, "")
}

delete_forward :: proc(session: ^Text_Session, committed: string) -> Text_Edit {
	start, end := selection_bounds(session)
	if start == end {
		if session.caret >= len(committed) {
			return {caret = session.caret}
		}
		start = session.caret
		end = next_grapheme_boundary(committed, session.caret)
	}
	return replace_range(session, committed, start, end, "")
}

// begin_composition starts (or replaces) the temporary preedit.
// The preedit is display state only: it can temporarily replace
// the selection visually, but nothing is committed until
// commit_composition. An empty preedit ends the composition.
begin_composition :: proc(session: ^Text_Session, preedit: string, start: int, length: int) {
	delete(session.preedit, session.allocator)
	session.preedit = ""
	session.preedit_start = 0
	session.preedit_length = 0
	session.composing = false
	if len(preedit) > 0 {
		session.preedit = strings.clone(preedit, session.allocator)
		session.preedit_start = start
		session.preedit_length = length
		session.composing = true
	}
}

// cancel_composition discards the preedit. Committed text, its
// revision, and the selection are all preserved.
cancel_composition :: proc(session: ^Text_Session) -> bool {
	if !session.composing {
		return false
	}
	delete(session.preedit, session.allocator)
	session.preedit = ""
	session.preedit_start = 0
	session.preedit_length = 0
	session.composing = false
	return true
}

// commit_composition turns the active preedit into exactly one
// edit replacing the current selection, then clears it.
commit_composition :: proc(session: ^Text_Session, committed: string) -> Text_Edit {
	if !session.composing {
		return {caret = session.caret}
	}
	preedit := session.preedit
	edit := insert_text(session, committed, preedit)
	delete(preedit, session.allocator)
	session.preedit = ""
	session.preedit_start = 0
	session.preedit_length = 0
	session.composing = false
	return edit
}
