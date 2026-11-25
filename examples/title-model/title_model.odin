package title_model

import "core:mem"
import "core:unicode/utf8"
import "dagda:dagda"

Error :: enum {
	None,
	Unknown_Object,
	Stale_Revision,
	Invalid_Text,
	Alloc_Failed,
}

Change_Kind :: enum {
	Commit,
	Undo,
}

// Change observer, called synchronously on the model-owner thread
// exactly once after a commit or undo has advanced the revision.
// The snapshot passed to the callback borrows the model's text:
// it stays valid only until the next successful mutation or
// destroy, so copy anything worth keeping. The observer must
// not mutate the model (commit, undo, set_observer, destroy)
// from inside its callback.
Observer :: #type proc(user_data: rawptr, kind: Change_Kind, snap: Snapshot)

// One title with a stable ID, an owned semantic role and
// document-owned UTF-8 text. Storage is owned by the model
// for its whole lifetime; call destroy to release it.
Model :: struct {
	object:        dagda.Object_Info,
	revision:      dagda.Revision,
	allocator:     mem.Allocator,
	role:          []u8,
	text:          []u8,
	history:       []u8,
	has_history:   bool,
	observer:      Observer,
	observer_data: rawptr,
	has_observer:  bool,
}

// set_observer attaches (or replaces) the single change observer.
set_observer :: proc(model: ^Model, observer: Observer, user_data: rawptr = nil) {
	model.observer = observer
	model.observer_data = user_data
	model.has_observer = observer != nil
}

// clear_observer detaches the observer, if any.
clear_observer :: proc(model: ^Model) {
	model.observer = nil
	model.observer_data = nil
	model.has_observer = false
}

notify_change :: proc(model: ^Model, kind: Change_Kind) {
	if model.has_observer {
		model.observer(model.observer_data, kind, snapshot(model))
	}
}

// Borrowed view of the committed title. text stays valid until the
// next successful mutation (commit or undo) or destroy.
Snapshot :: struct {
	object:   dagda.Object_Info,
	revision: dagda.Revision,
	text:     string,
}

// An independent, owned preview of a proposed rename. It never
// mutates the model; call preview_destroy to release it.
Preview :: struct {
	target:    dagda.Action_Target,
	allocator: mem.Allocator,
	storage:   []u8,
	text:      string,
}

clone_bytes :: proc(text: string, allocator: mem.Allocator) -> ([]u8, Error) {
	storage, err := make([]u8, len(text), allocator)
	if err != nil {
		return nil, .Alloc_Failed
	}
	copy(storage, text)
	return storage, .None
}

clone_text :: proc(text: string, allocator: mem.Allocator) -> ([]u8, Error) {
	if !utf8.valid_string(text) {
		return nil, .Invalid_Text
	}
	storage, err := make([]u8, len(text), allocator)
	if err != nil {
		return nil, .Alloc_Failed
	}
	copy(storage, text)
	return storage, .None
}

action_error :: proc(err: dagda.Action_Error) -> Error {
	switch err {
	case .None:
		return .None
	case .Unknown_Object:
		return .Unknown_Object
	case .Stale_Revision:
		return .Stale_Revision
	}
	return .None
}

// init clones role and text into document-owned storage at
// revision 0 with no undo history, so neither borrows caller
// storage. On failure any partial allocation is released and
// the model is left zeroed.
init :: proc(model: ^Model, object: dagda.Object_Info, text: string, allocator := context.allocator) -> Error {
	storage, err := clone_text(text, allocator)
	if err != .None {
		model^ = {}
		return err
	}
	role, role_err := clone_bytes(object.role, allocator)
	if role_err != .None {
		delete(storage, allocator)
		model^ = {}
		return role_err
	}
	owned := object
	owned.role = string(role)
	model^ = {object = owned, revision = 0, allocator = allocator, role = role, text = storage}
	return .None
}

destroy :: proc(model: ^Model) {
	delete(model.text, model.allocator)
	delete(model.role, model.allocator)
	if model.has_history {
		delete(model.history, model.allocator)
	}
	model^ = {}
}

snapshot :: proc(model: ^Model) -> Snapshot {
	return {object = model.object, revision = model.revision, text = string(model.text)}
}

// preview checks target and clones new_text into preview-owned
// storage without touching the model, its history or its revision.
preview :: proc(model: ^Model, target: dagda.Action_Target, new_text: string) -> (Preview, Error) {
	if err := action_error(dagda.check_target(target, model.object, model.revision)); err != .None {
		return {}, err
	}
	storage, err := clone_text(new_text, model.allocator)
	if err != .None {
		return {}, err
	}
	return {target = target, allocator = model.allocator, storage = storage, text = string(storage)}, .None
}

preview_destroy :: proc(p: ^Preview) {
	delete(p.storage, p.allocator)
	p^ = {}
}

// commit applies a revision-checked rename. Unknown ID, stale
// revision, invalid text or a failed allocation leaves committed
// text, history and revision untouched. Input may be reused or
// freed by the caller as soon as commit returns.
commit :: proc(model: ^Model, target: dagda.Action_Target, new_text: string) -> Error {
	if err := action_error(dagda.check_target(target, model.object, model.revision)); err != .None {
		return err
	}
	if !utf8.valid_string(new_text) {
		return .Invalid_Text
	}
	if new_text == string(model.text) {
		return .None
	}
	storage, err := clone_text(new_text, model.allocator)
	if err != .None {
		return err
	}
	if model.has_history {
		delete(model.history, model.allocator)
	}
	model.history = model.text
	model.has_history = true
	model.text = storage
	model.revision += 1
	notify_change(model, .Commit)
	return .None
}

// undo restores the text from before the last real commit and
// advances revision once. It reports false, changing nothing,
// when there is no history (including after a no-op-only sequence).
undo :: proc(model: ^Model) -> (changed: bool) {
	if !model.has_history {
		return false
	}
	delete(model.text, model.allocator)
	model.text = model.history
	model.history = nil
	model.has_history = false
	model.revision += 1
	notify_change(model, .Undo)
	return true
}
