package main

import "dagda:dagda"

// Title_Snapshot is the read-only view of the shared title exposed to the window.
// The text slice is valid until the next mutation of the backing model; callers
// that retain it across frames must copy it.
Title_Snapshot :: struct {
	id:       dagda.Object_Id,
	revision: dagda.Revision,
	text:     string,
}

Commit_Result :: struct {
	err:      dagda.Action_Error,
	snapshot: Title_Snapshot,
}

Undo_Result :: struct {
	undone:   bool,
	snapshot: Title_Snapshot,
}

// External_Commit_Gate lets the integration layer inspect whether the window
// currently owns an active IME preedit composition before applying an external
// commit. When Busy_Composing is returned, the integration layer should return
// a retryable busy result to the caller rather than mutating the document.
External_Commit_Gate :: enum {
	Ready,
	Busy_Composing,
}

// Model_Adapter is the narrow callback boundary between the SDL3 title window
// and the backing document model. The local fixture in fixture.odin implements
// this boundary so the host can run standalone and swap in the real shared
// title model in the next round.
Model_Adapter :: struct {
	ctx:      rawptr,
	snapshot: proc(ctx: rawptr) -> Title_Snapshot,
	commit:   proc(ctx: rawptr, target: dagda.Action_Target, text: string) -> Commit_Result,
	undo:     proc(ctx: rawptr) -> Undo_Result,
}

adapter_snapshot :: proc(adapter: Model_Adapter) -> Title_Snapshot {
	return adapter.snapshot(adapter.ctx)
}

adapter_commit :: proc(adapter: Model_Adapter, target: dagda.Action_Target, text: string) -> Commit_Result {
	return adapter.commit(adapter.ctx, target, text)
}

adapter_undo :: proc(adapter: Model_Adapter) -> Undo_Result {
	return adapter.undo(adapter.ctx)
}
