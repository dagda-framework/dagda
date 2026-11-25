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

// find_by_role writes IDs of objects whose role exactly matches role into out
// in input order, leaving any unused tail of out untouched. It allocates no
// memory and returns the number of IDs written and the total number of matches.
find_by_role :: proc(objects: []Object_Info, role: string, out: []Object_Id) -> (written: int, total: int) {
	for object in objects {
		if object.role != role {
			continue
		}
		if written < len(out) {
			out[written] = object.id
			written += 1
		}
		total += 1
	}
	return written, total
}
