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
