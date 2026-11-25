package main

import "core:fmt"
import "dagda:dagda"
import title_model "dagda:examples/title-model"

main :: proc() {
	model: title_model.Model
	if err := title_model.init(&model, {id = 1, role = "slide.title"}, "Quarterly results"); err != .None {
		panic("Example model init failed")
	}
	defer title_model.destroy(&model)

	snap := title_model.snapshot(&model)
	objects := [1]dagda.Object_Info{snap.object}
	ids: [1]dagda.Object_Id
	written, total := dagda.find_by_role(objects[:], "slide.title", ids[:])
	if written != 1 || total != 1 {
		panic("Expected exactly one slide.title object")
	}

	target := dagda.Action_Target{id = ids[0], base_revision = snap.revision}
	fmt.printf("Inspect  %s #%d at revision %d: %s\n", snap.object.role, target.id, snap.revision, snap.text)

	p, preview_err := title_model.preview(&model, target, "Revenue grew 12%")
	if preview_err != .None {
		panic("Example preview failed")
	}
	defer title_model.preview_destroy(&p)
	fmt.printf("Preview  %s (document still reads %q)\n", p.text, title_model.snapshot(&model).text)

	if err := title_model.commit(&model, target, "Revenue grew 12%"); err != .None {
		panic("Example commit failed")
	}
	committed := title_model.snapshot(&model)
	fmt.printf("Commit   revision %d: %s\n", committed.revision, committed.text)

	err := title_model.commit(&model, target, "An edit based on the old revision")
	fmt.printf("Retry    %v (document still reads %q)\n", err, title_model.snapshot(&model).text)
}
