package dagda

import "core:testing"

@(test)
test_find_by_role_zero_matches :: proc(t: ^testing.T) {
	objects := []Object_Info{{id = 1, role = "slide.title"}, {id = 2, role = "slide.body"}}
	output: [2]Object_Id = {99, 99}
	written, total := find_by_role(objects, "slide.footer", output[:])
	testing.expect_value(t, written, 0)
	testing.expect_value(t, total, 0)
	testing.expect_value(t, output[0], Object_Id(99))
	testing.expect_value(t, output[1], Object_Id(99))
}

@(test)
test_find_by_role_empty_input :: proc(t: ^testing.T) {
	output: [1]Object_Id = {99}
	written, total := find_by_role(nil, "slide.title", output[:])
	testing.expect_value(t, written, 0)
	testing.expect_value(t, total, 0)
	testing.expect_value(t, output[0], Object_Id(99))
}

@(test)
test_find_by_role_one_match :: proc(t: ^testing.T) {
	objects := []Object_Info{{id = 1, role = "slide.body"}, {id = 7, role = "slide.title"}}
	output: [2]Object_Id = {99, 99}
	written, total := find_by_role(objects, "slide.title", output[:])
	testing.expect_value(t, written, 1)
	testing.expect_value(t, total, 1)
	testing.expect_value(t, output[0], Object_Id(7))
	testing.expect_value(t, output[1], Object_Id(99))
}

@(test)
test_find_by_role_multiple_matches_preserve_order :: proc(t: ^testing.T) {
	objects := []Object_Info{
		{id = 3, role = "slide.title"},
		{id = 1, role = "slide.body"},
		{id = 9, role = "slide.title"},
		{id = 5, role = "slide.title"},
	}
	output: [4]Object_Id = {99, 99, 99, 99}
	written, total := find_by_role(objects, "slide.title", output[:])
	testing.expect_value(t, written, 3)
	testing.expect_value(t, total, 3)
	testing.expect_value(t, output[0], Object_Id(3))
	testing.expect_value(t, output[1], Object_Id(9))
	testing.expect_value(t, output[2], Object_Id(5))
	testing.expect_value(t, output[3], Object_Id(99))
}

@(test)
test_find_by_role_truncated_result :: proc(t: ^testing.T) {
	objects := []Object_Info{
		{id = 3, role = "slide.title"},
		{id = 9, role = "slide.title"},
		{id = 5, role = "slide.title"},
	}
	output: [2]Object_Id = {99, 99}
	written, total := find_by_role(objects, "slide.title", output[:])
	testing.expect_value(t, written, 2)
	testing.expect_value(t, total, 3)
	testing.expect_value(t, output[0], Object_Id(3))
	testing.expect_value(t, output[1], Object_Id(9))
}

@(test)
test_find_by_role_zero_capacity :: proc(t: ^testing.T) {
	objects := []Object_Info{{id = 3, role = "slide.title"}, {id = 9, role = "slide.title"}}
	written, total := find_by_role(objects, "slide.title", nil)
	testing.expect_value(t, written, 0)
	testing.expect_value(t, total, 2)
}

@(test)
test_find_by_role_untouched_tail :: proc(t: ^testing.T) {
	objects := []Object_Info{{id = 3, role = "slide.title"}}
	output: [3]Object_Id = {42, 43, 44}
	written, total := find_by_role(objects, "slide.title", output[:])
	testing.expect_value(t, written, 1)
	testing.expect_value(t, total, 1)
	testing.expect_value(t, output[0], Object_Id(3))
	testing.expect_value(t, output[1], Object_Id(43))
	testing.expect_value(t, output[2], Object_Id(44))
}

@(test)
test_find_by_role_exact_match :: proc(t: ^testing.T) {
	objects := []Object_Info{{id = 1, role = "slide.title"}, {id = 2, role = "slide.titles"}, {id = 3, role = "Slide.title"}}
	output: [3]Object_Id = {99, 99, 99}
	written, total := find_by_role(objects, "slide.title", output[:])
	testing.expect_value(t, written, 1)
	testing.expect_value(t, total, 1)
	testing.expect_value(t, output[0], Object_Id(1))
}
