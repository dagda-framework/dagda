package main

import "core:strings"
import "dagda:dagda"

// Local_Fixture is a tiny standalone title model used until the real shared
// title model is wired in. It owns all committed UTF-8 strings and undo history.
Local_Fixture :: struct {
	object:   dagda.Object_Info,
	revision: dagda.Revision,
	text:     string,
	history:  [dynamic]string,
}

fixture_init :: proc(f: ^Local_Fixture, initial_text := "Quarterly results", id := dagda.Object_Id(1)) {
	f.object = dagda.Object_Info{id = id, role = "slide.title"}
	f.revision = 0
	f.text = strings.clone(initial_text)
	clear(&f.history)
}

fixture_destroy :: proc(f: ^Local_Fixture) {
	delete(f.text)
	f.text = ""
	for prev in f.history {
		delete(prev)
	}
	delete(f.history)
}

fixture_snapshot_proc :: proc(ctx: rawptr) -> Title_Snapshot {
	f := (^Local_Fixture)(ctx)
	return Title_Snapshot{
		id       = f.object.id,
		revision = f.revision,
		text     = f.text,
	}
}

fixture_commit_proc :: proc(ctx: rawptr, target: dagda.Action_Target, text: string) -> Commit_Result {
	f := (^Local_Fixture)(ctx)
	if err := dagda.check_target(target, f.object, f.revision); err != .None {
		return Commit_Result{err = err, snapshot = fixture_snapshot_proc(ctx)}
	}
	// A no-op commit leaves the revision and undo history unchanged.
	if text == f.text {
		return Commit_Result{err = .None, snapshot = fixture_snapshot_proc(ctx)}
	}
	append(&f.history, f.text)
	f.text = strings.clone(text)
	f.revision += 1
	return Commit_Result{err = .None, snapshot = fixture_snapshot_proc(ctx)}
}

fixture_undo_proc :: proc(ctx: rawptr) -> Undo_Result {
	f := (^Local_Fixture)(ctx)
	if len(f.history) == 0 {
		return Undo_Result{undone = false, snapshot = fixture_snapshot_proc(ctx)}
	}
	prev := pop(&f.history)
	delete(f.text)
	f.text = prev
	// Undoing a real edit advances the revision so stale proposals cannot become valid again.
	f.revision += 1
	return Undo_Result{undone = true, snapshot = fixture_snapshot_proc(ctx)}
}

fixture_adapter :: proc(f: ^Local_Fixture) -> Model_Adapter {
	return Model_Adapter{
		ctx      = f,
		snapshot = fixture_snapshot_proc,
		commit   = fixture_commit_proc,
		undo     = fixture_undo_proc,
	}
}
