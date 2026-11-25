package main

import "core:fmt"
import "dagda:dagda"

Title :: struct {
	object: dagda.Object_Info,
	text:   string,
}

Slide :: struct {
	revision: dagda.Revision,
	title:    Title,
}

Rename :: struct {
	target: dagda.Action_Target,
	text:   string,
}

// The example's text lives in string literals. A host accepting external input
// would copy committed text into document-owned storage.
apply :: proc(slide: ^Slide, action: Rename) -> dagda.Action_Error {
	if err := dagda.check_target(action.target, slide.title.object, slide.revision); err != .None {
		return err
	}
	if action.text != slide.title.text {
		slide.title.text = action.text
		slide.revision += 1
	}
	return .None
}

main :: proc() {
	slide := Slide{title = {object = {id = 1, role = "slide.title"}, text = "Quarterly results"}}
	objects := [1]dagda.Object_Info{slide.title.object}
	ids: [1]dagda.Object_Id
	written, total := dagda.find_by_role(objects[:], "slide.title", ids[:])
	if written != 1 || total != 1 {
		panic("Expected exactly one slide.title object")
	}

	target := dagda.Action_Target{id = ids[0], base_revision = slide.revision}
	fmt.printf("Inspect  %s #%d at revision %d: %s\n", slide.title.object.role, target.id, slide.revision, slide.title.text)

	proposal := Rename{target, "Revenue grew 12%"}
	preview := slide
	if err := apply(&preview, proposal); err != .None {
		panic("Example preview failed")
	}
	fmt.printf("Preview  %s (document still reads %q)\n", preview.title.text, slide.title.text)

	if err := apply(&slide, proposal); err != .None {
		panic("Example commit failed")
	}
	fmt.printf("Commit   revision %d: %s\n", slide.revision, slide.title.text)

	err := apply(&slide, Rename{target, "An edit based on the old revision"})
	fmt.printf("Retry    %v (document still reads %q)\n", err, slide.title.text)
}
