package main

import "core:mem"
import "core:strings"
import "core:testing"
import "dagda:dagda"

@(test)
test_commit_clone_failure_and_empty_replacement :: proc(t: ^testing.T) {
	s: State
	f := &s.fields[int(WRITER)-1]
	f.text = strings.clone("old")
	f.history = make([dynamic]string, 0, 1)
	defer {
		delete(f.text)
		for previous in f.history { delete(previous) }
		delete(f.history)
	}

	accepted: bool
	{
		context.allocator = mem.nil_allocator()
		accepted = commit(&s, WRITER, "new")
	}
	testing.expect(t, !accepted)
	testing.expect_value(t, f.text, "old")
	testing.expect_value(t, f.revision, dagda.Revision(0))
	testing.expect_value(t, len(f.history), 0)
	if accepted { return }

	testing.expect(t, commit(&s, WRITER, ""))
	testing.expect_value(t, f.text, "")
	testing.expect_value(t, f.revision, dagda.Revision(1))
	testing.expect_value(t, len(f.history), 1)
	if len(f.history) == 1 { testing.expect_value(t, f.history[0], "old") }
}
