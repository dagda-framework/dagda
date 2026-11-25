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

Edit_Error :: enum {
	None,
	Alloc_Failed,
	Invalid_Input, // not valid UTF-8, or contains a line break
	Invalid_Range, // endpoints outside the committed text
}

// One proposed edit. It changes no session state until the app
// accepts it with apply_edit. text is owned by the caller
// (delete it with the session allocator, or use edit_destroy).
// When changed is false the result is a no-op: text is empty and
// the app must not commit anything. When err is not None the
// proposal failed explicitly: text is empty, nothing may be
// committed, and the session (including any prior preedit) is
// exactly as it was before the call.
Text_Edit :: struct {
	text:    string,
	caret:   int, // proposed caret, on a grapheme boundary in text
	changed: bool,
	err:     Edit_Error,
}

// apply_edit accepts a proposed edit after the app has committed
// it: the caret and selection move to the edit's caret, clamped
// to a grapheme boundary of the latest committed text. Until
// this is called (or the session is re-synced), a rejected edit
// leaves the prior caret and selection untouched.
apply_edit :: proc(session: ^Text_Session, edit: Text_Edit, committed: string) {
	session.caret = clamp_grapheme_boundary(committed, edit.caret)
	session.anchor = session.caret
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

valid_single_line :: proc(s: string) -> bool {
	if !utf8.valid_string(s) {
		return false
	}
	for i in 0 ..< len(s) {
		if s[i] == '\n' || s[i] == '\r' {
			return false
		}
	}
	return true
}

// replace_range proposes replacing committed[start:end] with
// inserted. Inputs are validated before any slicing, the
// allocation result is checked, and the session is not mutated:
// the proposed caret (adjusted to a grapheme boundary of the
// resulting text, so inserting before a combining character
// lands after the whole formed character) takes effect only
// when the app accepts the edit with apply_edit.
replace_range :: proc(session: ^Text_Session, committed: string, start, end: int, inserted: string) -> Text_Edit {
	if !valid_single_line(committed) || !valid_single_line(inserted) {
		return {caret = session.caret, err = .Invalid_Input}
	}
	if start < 0 || end < start || end > len(committed) {
		return {caret = session.caret, err = .Invalid_Range}
	}
	if start == end && len(inserted) == 0 {
		return {caret = session.caret}
	}
	total := start + len(inserted) + (len(committed) - end)
	storage, alloc_err := make([]u8, total, session.allocator)
	if alloc_err != nil {
		return {caret = session.caret, err = .Alloc_Failed}
	}
	copy(storage, committed[:start])
	copy(storage[start:], inserted)
	copy(storage[start + len(inserted):], committed[end:])
	text := string(storage)
	proposed := start + len(inserted)
	if proposed > 0 && proposed < len(text) {
		// If the insertion point now falls inside a grapheme
		// (e.g. "e" inserted before a leading U+0301 forms one
		// character), land after that whole character.
		proposed = next_grapheme_boundary(text, proposed - 1)
	}
	if text == committed {
		delete(storage, session.allocator)
		return {caret = proposed} // no-op: empty text, changed=false
	}
	return {text = text, caret = proposed, changed = true}
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
// On failure the prior preedit and composition state are
// preserved untouched.
begin_composition :: proc(session: ^Text_Session, preedit: string, start: int, length: int) -> Edit_Error {
	if !valid_single_line(preedit) {
		return .Invalid_Input
	}
	if len(preedit) == 0 {
		delete(session.preedit, session.allocator)
		session.preedit = ""
		session.preedit_start = 0
		session.preedit_length = 0
		session.composing = false
		return .None
	}
	cloned, clone_err := strings.clone(preedit, session.allocator)
	if clone_err != nil {
		return .Alloc_Failed
	}
	delete(session.preedit, session.allocator)
	session.preedit = cloned
	session.preedit_start = start
	session.preedit_length = length
	session.composing = true
	return .None
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

// commit_composition proposes exactly one edit replacing the
// current selection with the active preedit. The preedit is
// cleared only when the proposal was constructed successfully;
// on failure the composition stays exactly as it was.
commit_composition :: proc(session: ^Text_Session, committed: string) -> Text_Edit {
	if !session.composing {
		return {caret = session.caret}
	}
	edit := insert_text(session, committed, session.preedit)
	if edit.err != .None {
		return edit
	}
	delete(session.preedit, session.allocator)
	session.preedit = ""
	session.preedit_start = 0
	session.preedit_length = 0
	session.composing = false
	return edit
}
