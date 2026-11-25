package main

import title_model "../title-model"
import "dagda:dagda"

title_model_error :: proc(err: title_model.Error) -> Model_Error {
	switch err {
	case .None:
		return .None
	case .Unknown_Object:
		return .Unknown_Object
	case .Stale_Revision:
		return .Stale_Revision
	case .Invalid_Text:
		return .Invalid_Text
	case .Alloc_Failed:
		return .Alloc_Failed
	}
	return .None
}

title_model_snapshot_proc :: proc(ctx: rawptr) -> Title_Snapshot {
	m := (^title_model.Model)(ctx)
	snap := title_model.snapshot(m)
	return Title_Snapshot{
		id       = snap.object.id,
		revision = snap.revision,
		text     = snap.text,
	}
}

title_model_commit_proc :: proc(ctx: rawptr, target: dagda.Action_Target, text: string) -> Commit_Result {
	m := (^title_model.Model)(ctx)
	err := title_model.commit(m, target, text)
	return Commit_Result{
		err      = title_model_error(err),
		snapshot = title_model_snapshot_proc(ctx),
	}
}

title_model_undo_proc :: proc(ctx: rawptr) -> Undo_Result {
	m := (^title_model.Model)(ctx)
	undone := title_model.undo(m)
	return Undo_Result{
		undone   = undone,
		snapshot = title_model_snapshot_proc(ctx),
	}
}

// title_model_adapter binds a live examples/title-model Model to the window's
// Model_Adapter callback boundary without copying or taking ownership of it.
title_model_adapter :: proc(m: ^title_model.Model) -> Model_Adapter {
	return Model_Adapter{
		ctx      = m,
		snapshot = title_model_snapshot_proc,
		commit   = title_model_commit_proc,
		undo     = title_model_undo_proc,
	}
}
