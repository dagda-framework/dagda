package main

import "dagda:dagda"

// Model_Error mirrors the declared failure modes of the backing title model.
Model_Error :: enum {
	None,
	Unknown_Object,
	Stale_Revision,
	Invalid_Text,
	Alloc_Failed,
}

// Title_Snapshot is a borrowed read-only view of the shared title exposed to
// the window. The text slice stays valid until the next successful mutation
// (commit or undo) or destruction of the backing model; callers that retain
// it across frames must copy it.
Title_Snapshot :: struct {
	id:       dagda.Object_Id,
	revision: dagda.Revision,
	text:     string,
}

Commit_Result :: struct {
	err:      Model_Error,
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
// and the backing document model.
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
