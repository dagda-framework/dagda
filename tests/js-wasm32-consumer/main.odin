package main

import "dagda:dagda"

main :: proc() {
	object := dagda.Object_Info{id = 1, role = "title"}
	target := dagda.Action_Target{id = object.id, base_revision = 0}
	assert(dagda.check_target(target, object, 0) == .None)
}
