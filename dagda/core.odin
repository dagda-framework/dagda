package dagda

Object_Id :: distinct u64
Revision :: distinct u64

// Several views can expose the same document object.
Object_Info :: struct {
	id:   Object_Id,
	role: string,
}

Action_Target :: struct {
	id:            Object_Id,
	base_revision: Revision,
}

Action_Error :: enum {
	None,
	Unknown_Object,
	Stale_Revision,
}

check_target :: proc(target: Action_Target, object: Object_Info, revision: Revision) -> Action_Error {
	if target.id != object.id {
		return .Unknown_Object
	}
	if target.base_revision != revision {
		return .Stale_Revision
	}
	return .None
}

// Find objects by exact role. Writes matching IDs into output in input
// order and returns how many were written plus the total number of
// matches, so a caller can detect truncation when total > written.
// Read-only and allocates no memory; the unused tail of output is
// left untouched, and output may have zero capacity.
find_by_role :: proc(objects: []Object_Info, role: string, output: []Object_Id) -> (written: int, total: int) {
	for object in objects {
		if object.role == role {
			if written < len(output) {
				output[written] = object.id
				written += 1
			}
			total += 1
		}
	}
	return written, total
}
