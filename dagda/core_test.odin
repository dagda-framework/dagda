package dagda

import "core:mem"
import "core:testing"

@(test)
test_find_by_role_zero_matches :: proc(t: ^testing.T) {
	out := [2]Object_Id{99, 100}

	written, total := find_by_role(nil, "slide.title", out[:])
	testing.expect_value(t, written, 0)
	testing.expect_value(t, total, 0)
	testing.expect_value(t, out[0], Object_Id(99))
	testing.expect_value(t, out[1], Object_Id(100))

	objects := []Object_Info{
		{id = 1, role = "slide.subtitle"},
		{id = 2, role = "Slide.Title"},
		{id = 3, role = "slide.title "},
		{id = 4, role = "slide"},
	}

	written, total = find_by_role(objects, "slide.title", out[:])
	testing.expect_value(t, written, 0)
	testing.expect_value(t, total, 0)
	testing.expect_value(t, out[0], Object_Id(99))
	testing.expect_value(t, out[1], Object_Id(100))
}

@(test)
test_find_by_role_single_match_and_untouched_tail :: proc(t: ^testing.T) {
	objects := []Object_Info{
		{id = 10, role = "slide.header"},
		{id = 42, role = "slide.title"},
		{id = 11, role = "slide.footer"},
	}
	out := [3]Object_Id{901, 902, 903}

	written, total := find_by_role(objects, "slide.title", out[:])
	testing.expect_value(t, written, 1)
	testing.expect_value(t, total, 1)
	testing.expect_value(t, out[0], Object_Id(42))
	testing.expect_value(t, out[1], Object_Id(902))
	testing.expect_value(t, out[2], Object_Id(903))
}

@(test)
test_find_by_role_multiple_matches_preserve_order :: proc(t: ^testing.T) {
	objects := []Object_Info{
		{id = 30, role = "slide.bullet"},
		{id = 10, role = "slide.title"},
		{id = 5, role = "slide.bullet"},
		{id = 20, role = "slide.note"},
		{id = 99, role = "slide.bullet"},
	}
	out := [5]Object_Id{701, 702, 703, 704, 705}

	written, total := find_by_role(objects, "slide.bullet", out[:])
	testing.expect_value(t, written, 3)
	testing.expect_value(t, total, 3)
	testing.expect_value(t, out[0], Object_Id(30))
	testing.expect_value(t, out[1], Object_Id(5))
	testing.expect_value(t, out[2], Object_Id(99))
	testing.expect_value(t, out[3], Object_Id(704))
	testing.expect_value(t, out[4], Object_Id(705))
}

@(test)
test_find_by_role_truncated_result :: proc(t: ^testing.T) {
	objects := []Object_Info{
		{id = 7, role = "slide.bullet"},
		{id = 1, role = "slide.title"},
		{id = 3, role = "slide.bullet"},
		{id = 9, role = "slide.bullet"},
	}
	backing := [4]Object_Id{501, 502, 503, 504}

	written, total := find_by_role(objects, "slide.bullet", backing[:2])
	testing.expect_value(t, written, 2)
	testing.expect_value(t, total, 3)
	testing.expect_value(t, backing[0], Object_Id(7))
	testing.expect_value(t, backing[1], Object_Id(3))
	testing.expect_value(t, backing[2], Object_Id(503))
	testing.expect_value(t, backing[3], Object_Id(504))
}

@(test)
test_find_by_role_zero_capacity :: proc(t: ^testing.T) {
	objects := []Object_Info{
		{id = 1, role = "slide.title"},
		{id = 2, role = "slide.bullet"},
		{id = 3, role = "slide.title"},
	}

	written, total := find_by_role(objects, "slide.title", nil)
	testing.expect_value(t, written, 0)
	testing.expect_value(t, total, 2)

	backing := [2]Object_Id{801, 802}
	written, total = find_by_role(objects, "slide.title", backing[:0])
	testing.expect_value(t, written, 0)
	testing.expect_value(t, total, 2)
	testing.expect_value(t, backing[0], Object_Id(801))
	testing.expect_value(t, backing[1], Object_Id(802))
}

@(test)
test_find_by_role_no_allocations :: proc(t: ^testing.T) {
	context.allocator = mem.panic_allocator()

	objects := []Object_Info{
		{id = 1, role = "slide.title"},
		{id = 2, role = "slide.title"},
	}
	out: [2]Object_Id

	written, total := find_by_role(objects, "slide.title", out[:])
	testing.expect_value(t, written, 2)
	testing.expect_value(t, total, 2)
	testing.expect_value(t, out[0], Object_Id(1))
	testing.expect_value(t, out[1], Object_Id(2))
}
