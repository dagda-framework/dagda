package dagda

import "core:fmt"
import "core:mem"
import "core:testing"

// Counter is the first consumer: the app owns the count and builds
// a view with a value label and an Increment button.
Counter :: struct {
	count:     int,
	label_buf: [32]u8,
	label_len: int,
	elements:  [2]Element,
}

counter_view :: proc(c: ^Counter) -> View {
	text := fmt.bprintf(c.label_buf[:], "%d", c.count)
	c.label_len = len(text)
	c.elements = {
		{info = {id = 1, role = "counter.value"}, kind = .Label, text = string(c.label_buf[:c.label_len])},
		{info = {id = 2, role = "counter.increment"}, kind = .Button, text = "Increment"},
	}
	return {elements = c.elements[:]}
}

counter_handle :: proc(user_data: rawptr, id: Object_Id, action: Action) -> bool {
	c := (^Counter)(user_data)
	if id == 2 && action == .Activate {
		c.count += 1
		return true
	}
	return false
}

counter_frame :: proc(t: ^testing.T, c: ^Counter) -> Frame {
	frame, ok := resolve(counter_view(c), {width = 320, height = 200})
	testing.expect(t, ok)
	return frame
}

@(test)
test_counter_acceptance :: proc(t: ^testing.T) {
	counter: Counter

	// Start at 0 and discover the button by role.
	frame := counter_frame(t, &counter)
	objects: [2]Object_Info
	for element, i in frame.elements {
		objects[i] = element.info
	}
	ids: [1]Object_Id
	written, total := find_by_role(objects[:], "counter.increment", ids[:])
	testing.expect_value(t, written, 1)
	testing.expect_value(t, total, 1)
	button_id := ids[0]

	// Hit-test a point inside the button and activate it there.
	button, found := find(frame, button_id)
	testing.expect(t, found)
	centre := Point{x = button.bounds.x + button.bounds.width / 2, y = button.bounds.y + button.bounds.height / 2}
	hit_id, hit := hit_test(frame, centre)
	testing.expect(t, hit)
	testing.expect_value(t, hit_id, button_id)
	testing.expect_value(t, click(frame, centre, counter_handle, &counter), Invoke_Result.Applied)
	testing.expect_value(t, counter.count, 1)
	frame_destroy(&frame)

	// Rebuild: the label now displays 1.
	frame = counter_frame(t, &counter)
	label, has_label := find(frame, 1)
	testing.expect(t, has_label)
	testing.expect_value(t, label.text, "1")

	// Invoke activate by the same stable button ID: now 2.
	testing.expect_value(t, invoke(frame, button_id, .Activate, counter_handle, &counter), Invoke_Result.Applied)
	testing.expect_value(t, counter.count, 2)
	frame_destroy(&frame)

	frame = counter_frame(t, &counter)
	label, _ = find(frame, 1)
	testing.expect_value(t, label.text, "2")

	// A point outside the button and an unsupported action
	// leave the count unchanged.
	testing.expect_value(t, click(frame, {x = 2, y = 2}, counter_handle, &counter), Invoke_Result.Unknown_Object)
	testing.expect_value(t, invoke(frame, 1, .Activate, counter_handle, &counter), Invoke_Result.Unsupported_Action)
	testing.expect_value(t, invoke(frame, 999, .Activate, counter_handle, &counter), Invoke_Result.Unknown_Object)
	testing.expect_value(t, counter.count, 2)
	frame_destroy(&frame)
}

@(test)
test_resolved_inspection_and_empty :: proc(t: ^testing.T) {
	counter: Counter
	frame := counter_frame(t, &counter)
	defer frame_destroy(&frame)
	testing.expect_value(t, len(frame.elements), 2)
	label := frame.elements[0]
	button := frame.elements[1]
	testing.expect_value(t, label.info.role, "counter.value")
	testing.expect_value(t, label.text, "0")
	testing.expect(t, Action.Activate not_in label.actions)
	testing.expect_value(t, button.info.role, "counter.increment")
	testing.expect_value(t, button.text, "Increment")
	testing.expect(t, Action.Activate in button.actions)
	// Bounds are top-inclusive and bottom/right-exclusive.
	testing.expect(t, contains(button.bounds, {x = button.bounds.x, y = button.bounds.y}))
	testing.expect(t, !contains(button.bounds, {x = button.bounds.x + button.bounds.width, y = button.bounds.y}))
	_, hit := hit_test(frame, {x = -1, y = -1})
	testing.expect(t, !hit)

	empty, ok := resolve({}, {width = 100, height = 100})
	testing.expect(t, ok)
	defer frame_destroy(&empty)
	testing.expect_value(t, len(empty.elements), 0)
}

@(test)
test_duplicate_ids_rejected :: proc(t: ^testing.T) {
	// Regression: a label and a button sharing ID 1 must not
	// resolve (hit-testing would name the button, then dispatch
	// would find the label and report Unsupported_Action).
	view := View{elements = {
		{info = {id = 1, role = "counter.value"}, kind = .Label, text = "0"},
		{info = {id = 1, role = "counter.increment"}, kind = .Button, text = "Increment"},
	}}
	frame, ok := resolve(view, {width = 320, height = 200})
	testing.expect(t, !ok)
	testing.expect_value(t, len(frame.elements), 0)
}

Shared_Recorder :: struct {
	last_id: Object_Id,
	calls:   int,
}

shared_handle :: proc(user_data: rawptr, id: Object_Id, action: Action) -> bool {
	r := (^Shared_Recorder)(user_data)
	if action == .Activate {
		r.last_id = id
		r.calls += 1
		return true
	}
	return false
}

@(test)
test_shared_role_distinct_ids_dispatch :: proc(t: ^testing.T) {
	// Roles may repeat: two buttons share a role, and dispatch by
	// ID (agent path) or by point (pointer path) reaches the
	// intended element.
	rec: Shared_Recorder
	view := View{elements = {
		{info = {id = 10, role = "shared.action"}, kind = .Button, text = "First"},
		{info = {id = 20, role = "shared.action"}, kind = .Button, text = "Second"},
	}}
	frame, ok := resolve(view, {width = 320, height = 200})
	testing.expect(t, ok)
	defer frame_destroy(&frame)

	objects: [2]Object_Info
	for element, i in frame.elements {
		objects[i] = element.info
	}
	ids: [2]Object_Id
	written, total := find_by_role(objects[:], "shared.action", ids[:])
	testing.expect_value(t, written, 2)
	testing.expect_value(t, total, 2)

	testing.expect_value(t, invoke(frame, ids[1], .Activate, shared_handle, &rec), Invoke_Result.Applied)
	testing.expect_value(t, rec.last_id, Object_Id(20))

	second := frame.elements[1]
	centre := Point{x = second.bounds.x + 1, y = second.bounds.y + 1}
	testing.expect_value(t, click(frame, centre, shared_handle, &rec), Invoke_Result.Applied)
	testing.expect_value(t, rec.last_id, Object_Id(20))
	testing.expect_value(t, rec.calls, 2)
}

// shared_role_frame builds: button(id 10, role "shared.action"),
// a differently named label between them, button(id 20, same role).
shared_role_frame :: proc(t: ^testing.T) -> Frame {
	view := View{elements = {
		{info = {id = 10, role = "shared.action"}, kind = .Button, text = "First"},
		{info = {id = 99, role = "other.label"}, kind = .Label, text = "Between"},
		{info = {id = 20, role = "shared.action"}, kind = .Button, text = "Second"},
	}}
	frame, ok := resolve(view, {width = 320, height = 200})
	testing.expect(t, ok)
	return frame
}

@(test)
test_role_query_consumer_loop :: proc(t: ^testing.T) {
	frame := shared_role_frame(t)
	defer frame_destroy(&frame)

	// Compilable consumer loop: stop-at-first is just a break;
	// here we walk every match in declaration order.
	seen: [4]Resolved_Element
	count := 0
	query := query_by_role(frame, "shared.action")
	for {
		element, ok := next_match(&query)
		if !ok {
			break
		}
		seen[count] = element
		count += 1
	}
	testing.expect_value(t, count, 2)
	testing.expect_value(t, seen[0].info.id, Object_Id(10))
	testing.expect_value(t, seen[1].info.id, Object_Id(20))
	for i in 0 ..< count {
		testing.expect_value(t, seen[i].kind, Element_Kind.Button)
		testing.expect(t, Action.Activate in seen[i].actions)
		testing.expect_value(t, seen[i].bounds, frame.elements[i * 2].bounds)
	}

	// Restart after exhaustion needs a fresh query; the exhausted
	// one keeps reporting no match.
	_, again := next_match(&query)
	testing.expect(t, !again)
	fresh := query_by_role(frame, "shared.action")
	first, has_first := next_match(&fresh)
	testing.expect(t, has_first)
	testing.expect_value(t, first.info.id, Object_Id(10))

	// No match.
	none := query_by_role(frame, "missing.role")
	_, has_none := next_match(&none)
	testing.expect(t, !has_none)
}

@(test)
test_role_query_empty_and_no_alloc :: proc(t: ^testing.T) {
	empty, ok := resolve({}, {width = 100, height = 100})
	testing.expect(t, ok)
	defer frame_destroy(&empty)
	query := query_by_role(empty, "shared.action")
	_, has := next_match(&query)
	testing.expect(t, !has)
	_, has = next_match(&query)
	testing.expect(t, !has)

	// Traversal allocates nothing: a panic allocator would fail
	// the test on any allocation attempt during the walk.
	frame := shared_role_frame(t)
	defer frame_destroy(&frame)
	saved := context.allocator
	context.allocator = mem.panic_allocator()
	traversal := query_by_role(frame, "shared.action")
	matches := 0
	for {
		_, found := next_match(&traversal)
		if !found {
			break
		}
		matches += 1
	}
	_, found_after := next_match(&traversal)
	context.allocator = saved
	testing.expect_value(t, matches, 2)
	testing.expect(t, !found_after)
}
