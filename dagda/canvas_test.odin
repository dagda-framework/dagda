#+build !js
package dagda

import "core:testing"

test_canvas_elements := []Canvas_Element{
	{info = {id = 7, role = "slide.chart"}, kind = .Button, text = "Chart", bounds = {x = 72, y = 240, width = 360, height = 180}},
}

test_canvas :: proc() -> Canvas {
	return {size = {width = 960, height = 540}, elements = test_canvas_elements}
}

// host_example stands in for the SDL host: it obtains the
// transform for its window size and the resolved bounds it
// would hand to the renderer and pointer handling.
host_example :: proc(viewport: Size) -> (Canvas_Transform, Rect, bool) {
	canvas := test_canvas()
	frame, ok := resolve_canvas(canvas, viewport)
	if !ok {
		return {}, {}, false
	}
	defer frame_destroy(&frame)
	return frame.transform, frame.elements[0].bounds, true
}

check_case :: proc(t: ^testing.T, viewport: Size, expected: Rect) {
	canvas := test_canvas()
	frame, ok := resolve_canvas(canvas, viewport)
	testing.expect(t, ok)
	defer frame_destroy(&frame)

	el := frame.elements[0]
	testing.expect_value(t, el.canvas_bounds, Rect{x = 72, y = 240, width = 360, height = 180})
	testing.expect_value(t, el.bounds, expected)

	// An interior canvas point maps to a window point that maps
	// straight back, and both hit paths name the same stable ID.
	canvas_p := Point{x = 100, y = 300}
	window_p := canvas_point_to_window(frame.transform, canvas_p)
	back, inside := window_point_to_canvas(frame.transform, window_p)
	testing.expect(t, inside)
	testing.expect_value(t, back, canvas_p)
	id, hit := hit_test_canvas(frame, window_p)
	testing.expect(t, hit)
	testing.expect_value(t, id, Object_Id(7))
	window_id, window_hit := hit_test(frame, window_p)
	testing.expect(t, window_hit)
	testing.expect_value(t, window_id, Object_Id(7))
}

@(test)
test_canvas_both_viewports :: proc(t: ^testing.T) {
	check_case(t, {width = 1200, height = 540}, {x = 192, y = 240, width = 360, height = 180})
	check_case(t, {width = 720, height = 540}, {x = 54, y = 247.5, width = 270, height = 135})

	// The host example obtains the same transform and bounds.
	transform, bounds, ok := host_example({width = 1200, height = 540})
	testing.expect(t, ok)
	testing.expect_value(t, transform.scale, f32(1))
	testing.expect_value(t, transform.offset, Point{x = 120, y = 0})
	testing.expect_value(t, bounds, Rect{x = 192, y = 240, width = 360, height = 180})
}

@(test)
test_canvas_overlap_edges_letterbox :: proc(t: ^testing.T) {
	canvas := Canvas{
		size = {width = 960, height = 540},
		elements = {
			{info = {id = 1, role = "under"}, kind = .Button, text = "Under", bounds = {x = 0, y = 0, width = 200, height = 200}},
			{info = {id = 2, role = "over"}, kind = .Button, text = "Over", bounds = {x = 100, y = 100, width = 200, height = 200}},
			{info = {id = 3, role = "past.edge"}, kind = .Button, text = "Past", bounds = {x = 900, y = 480, width = 200, height = 120}},
		},
	}
	frame, ok := resolve_canvas(canvas, {width = 1200, height = 540})
	testing.expect(t, ok)
	defer frame_destroy(&frame)

	// Overlap: the last-drawn element wins in canvas and window space.
	overlap_window := canvas_point_to_window(frame.transform, {x = 150, y = 150})
	id, hit := hit_test_canvas(frame, overlap_window)
	testing.expect(t, hit)
	testing.expect_value(t, id, Object_Id(2))
	win_id, win_hit := hit_test(frame, overlap_window)
	testing.expect(t, win_hit)
	testing.expect_value(t, win_id, Object_Id(2))

	// Element edges: interior near the far corner hits, and the
	// far edge itself (x=300 for element 2, outside element 1) misses.
	inside_id, inside := hit_test_canvas(frame, canvas_point_to_window(frame.transform, {x = 299, y = 299}))
	testing.expect(t, inside)
	testing.expect_value(t, inside_id, Object_Id(2))
	_, on_far_edge := hit_test_canvas(frame, canvas_point_to_window(frame.transform, {x = 300, y = 150}))
	testing.expect(t, !on_far_edge)
	_, miss := hit_test_canvas(frame, {x = 120 + 960, y = 270}) // canvas far edge x=960
	testing.expect(t, !miss)

	// Letterbox: points beside the scaled canvas miss, including
	// where the past-edge element's window bounds extend beyond it.
	_, letterbox := hit_test_canvas(frame, {x = 10, y = 270})
	testing.expect(t, !letterbox)
	_, beyond := hit_test_canvas(frame, {x = 1190, y = 520})
	testing.expect(t, !beyond)
	// Inside the canvas portion of that same element does hit.
	past_id, past_hit := hit_test_canvas(frame, canvas_point_to_window(frame.transform, {x = 950, y = 530}))
	testing.expect(t, past_hit)
	testing.expect_value(t, past_id, Object_Id(3))
}

@(test)
test_canvas_hit_paths_agree_past_edge :: proc(t: ^testing.T) {
	canvas := Canvas{
		size = {width = 960, height = 540},
		elements = {
			{info = {id = 5, role = "past.edge"}, kind = .Button, text = "Past", bounds = {x = 900, y = 480, width = 200, height = 120}},
		},
	}
	frame, ok := resolve_canvas(canvas, {width = 1200, height = 540})
	testing.expect(t, ok)
	defer frame_destroy(&frame)

	rec: Shared_Recorder
	misses := []Point{{x = 1080, y = 520}, {x = 1190, y = 520}}
	for point in misses {
		_, hit_a := hit_test(frame, point)
		_, hit_b := hit_test_canvas(frame, point)
		testing.expect(t, !hit_a)
		testing.expect(t, !hit_b)
		testing.expect_value(t, click(frame, point, shared_handle, &rec), Invoke_Result.Unknown_Object)
	}
	testing.expect_value(t, rec.calls, 0)

	id, hit := hit_test_canvas(frame, {x = 1079, y = 520})
	testing.expect(t, hit)
	testing.expect_value(t, id, Object_Id(5))
	testing.expect_value(t, click(frame, {x = 1079, y = 520}, shared_handle, &rec), Invoke_Result.Applied)
	testing.expect_value(t, rec.calls, 1)
	testing.expect_value(t, rec.last_id, Object_Id(5))
}

@(test)
test_canvas_left_edge_exact_hit :: proc(t: ^testing.T) {
	canvas := Canvas{
		size = {width = 960, height = 540},
		elements = {
			{info = {id = 9, role = "edge"}, kind = .Button, text = "Edge", bounds = {x = 93, y = 100, width = 50, height = 50}},
		},
	}
	frame, ok := resolve_canvas(canvas, {width = 853, height = 480})
	testing.expect(t, ok)
	defer frame_destroy(&frame)

	bounds := frame.elements[0].bounds
	point := Point{x = bounds.x, y = bounds.y + bounds.height / 2}
	id, hit := hit_test(frame, point)
	testing.expect(t, hit)
	testing.expect_value(t, id, Object_Id(9))
	id2, hit2 := hit_test_canvas(frame, point)
	testing.expect(t, hit2)
	testing.expect_value(t, id2, Object_Id(9))
	rec: Shared_Recorder
	testing.expect_value(t, click(frame, point, shared_handle, &rec), Invoke_Result.Applied)
	testing.expect_value(t, rec.calls, 1)
}

@(test)
test_canvas_zero_viewport :: proc(t: ^testing.T) {
	canvas := test_canvas()
	frame, ok := resolve_canvas(canvas, {width = 0, height = 0})
	testing.expect(t, ok)
	defer frame_destroy(&frame)
	testing.expect_value(t, frame.elements[0].bounds.width, f32(0))
	testing.expect_value(t, frame.elements[0].canvas_bounds, Rect{x = 72, y = 240, width = 360, height = 180})
	_, inside := window_point_to_canvas(frame.transform, {x = 0, y = 0})
	testing.expect(t, !inside)
	_, hit := hit_test_canvas(frame, {x = 0, y = 0})
	testing.expect(t, !hit)

	zero_canvas, zero_ok := resolve_canvas({}, {width = 800, height = 600})
	testing.expect(t, zero_ok)
	defer frame_destroy(&zero_canvas)
	testing.expect_value(t, len(zero_canvas.elements), 0)
}
