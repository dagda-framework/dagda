package dagda

import "core:mem"
import "core:strings"

// Advertised edits: an app declares, per stable object, which
// edits it offers and what argument each one accepts. Callers
// discover the declarations, preview an edit without mutating
// anything, and commit through the app's handler, which keeps
// all document policy (revisions, validation, undo) in the app.
// The existing Activate action API is unchanged; an advertised
// edit is a separate, named capability.

Edit_Argument_Kind :: enum {
	None,
	Text,
	Rect,
}

// The argument value handed to a preview or commit. Exactly the
// field matching kind is meaningful.
Edit_Argument :: struct {
	kind: Edit_Argument_Kind,
	text: string,
	rect: Rect,
}

argument_none :: proc() -> Edit_Argument {
	return {kind = .None}
}

argument_text :: proc(text: string) -> Edit_Argument {
	return {kind = .Text, text = text}
}

argument_rect :: proc(rect: Rect) -> Edit_Argument {
	return {kind = .Rect, rect = rect}
}

// One advertised edit. edit is the app-chosen name (for example
// "replace_text" or "set_rect"); strings are borrowed from the app.
//
// Duplicate rule: at most one declaration counts per
// (object_id, edit name). When an app declares the same pair
// twice, the first declaration wins and later ones are ignored
// consistently by discovery, lookup, preview, and commit. The
// same edit name on a different object is a separate declaration.
Advertised_Edit :: struct {
	object_id: Object_Id,
	edit:      string,
	argument:  Edit_Argument_Kind,
}

// edits_for writes the edits advertised for one object into out
// in declaration order (first declaration per edit name) and
// returns how many were written plus the total for that object.
edits_for :: proc(edits: []Advertised_Edit, id: Object_Id, out: []Advertised_Edit) -> (written: int, total: int) {
	for edit, i in edits {
		if edit.object_id != id {
			continue
		}
		duplicate := false
		for prev in edits[:i] {
			if prev.object_id == id && prev.edit == edit.edit {
				duplicate = true
				break
			}
		}
		if duplicate {
			continue
		}
		if written < len(out) {
			out[written] = edit
			written += 1
		}
		total += 1
	}
	return written, total
}

find_edit :: proc(edits: []Advertised_Edit, id: Object_Id, name: string) -> (Advertised_Edit, bool) {
	for edit in edits {
		if edit.object_id == id && edit.edit == name {
			return edit, true
		}
	}
	return {}, false
}

Edit_Result :: enum {
	Applied,
	Unknown_Object,
	Unknown_Edit,
	Wrong_Argument,
	Stale_Revision,
	Alloc_Failed,
	Not_Handled,
}

// An owned preview of a proposed edit: both the edit name and
// the text payload are copied, so the caller may reuse all of
// its source buffers immediately. It changes no app state;
// release it with preview_destroy.
Edit_Preview :: struct {
	target:    Action_Target,
	edit:      string, // owned by the preview
	argument:  Edit_Argument, // text owned when kind is Text
	allocator: mem.Allocator,
}

preview_destroy :: proc(preview: ^Edit_Preview) {
	delete(preview.edit, preview.allocator)
	if preview.argument.kind == .Text {
		delete(preview.argument.text, preview.allocator)
	}
	preview^ = {}
}

validate_edit :: proc(edits: []Advertised_Edit, id: Object_Id, name: string, arg: Edit_Argument) -> (Advertised_Edit, Edit_Result) {
	advertised, found := find_edit(edits, id, name)
	if !found {
		// Distinguish an unknown object from an unknown edit on it.
		for edit in edits {
			if edit.object_id == id {
				return {}, .Unknown_Edit
			}
		}
		return {}, .Unknown_Object
	}
	if arg.kind != advertised.argument {
		return {}, .Wrong_Argument
	}
	return advertised, .Applied
}

// preview_edit validates that the edit is advertised for the
// object and that the argument matches the declared kind, then
// returns an owned copy of the proposal. Nothing is mutated.
preview_edit :: proc(edits: []Advertised_Edit, target: Action_Target, name: string, arg: Edit_Argument, allocator := context.allocator) -> (Edit_Preview, Edit_Result) {
	advertised, validation := validate_edit(edits, target.id, name, arg)
	if validation != .Applied {
		return {}, validation
	}
	// Own the edit name first; if the text clone then fails,
	// release the name so a partway failure owns nothing.
	name_clone, name_err := strings.clone(advertised.edit, allocator)
	if name_err != nil || len(name_clone) != len(advertised.edit) {
		return {}, .Alloc_Failed
	}
	preview := Edit_Preview{target = target, edit = name_clone, argument = arg, allocator = allocator}
	if arg.kind == .Text {
		cloned, err := strings.clone(arg.text, allocator)
		if err != nil || len(cloned) != len(arg.text) {
			delete(name_clone, allocator)
			return {}, .Alloc_Failed
		}
		preview.argument.text = cloned
	}
	return preview, .Applied
}

// The app's edit handler. It receives the validated target,
// edit name, and argument, enforces document policy (including
// the target revision), applies the edit, and reports the
// outcome. Returning Stale_Revision must leave state untouched.
Edit_Handler :: #type proc(user_data: rawptr, target: Action_Target, edit: string, arg: Edit_Argument) -> Edit_Result

// commit_edit validates the proposal exactly like preview_edit
// and then dispatches it to the app handler. A wrong argument
// or an unadvertised edit never reaches the handler.
commit_edit :: proc(edits: []Advertised_Edit, target: Action_Target, name: string, arg: Edit_Argument, handler: Edit_Handler, user_data: rawptr = nil) -> Edit_Result {
	_, validation := validate_edit(edits, target.id, name, arg)
	if validation != .Applied {
		return validation
	}
	if handler == nil {
		return .Not_Handled
	}
	return handler(user_data, target, name, arg)
}
