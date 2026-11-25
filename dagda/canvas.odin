package dagda

// Canvas geometry: an app declares a logical canvas size and
// places elements with rectangles in canvas coordinates. The
// canvas is scaled uniformly (aspect preserved) to fit the
// viewport and centered, leaving letterbox margins when the
// aspect ratios differ.

// An element placed on a canvas. The app supplies the stable ID,
// semantic role, and its rectangle in canvas coordinates.
Canvas_Element :: struct {
	info:   Object_Info,
	kind:   Element_Kind,
	text:   string,
	bounds: Rect, // canvas coordinates
}

// A logical canvas: its declared size plus its placed elements.
// Views and their strings are borrowed exactly as in View.
Canvas :: struct {
	size:     Size, // logical canvas dimensions
	elements: []Canvas_Element,
}

// The affine map between canvas and window coordinates for one
// viewport: window = offset + canvas * scale.
Canvas_Transform :: struct {
	scale:    f32,
	offset:   Point,
	canvas:   Size,
	viewport: Size,
}

// canvas_transform computes the uniform, centered fit of a
// canvas into a viewport. A zero-sized canvas or viewport is
// safe and yields a zero scale that maps and hits nothing.
canvas_transform :: proc(canvas: Size, viewport: Size) -> Canvas_Transform {
	if canvas.width <= 0 || canvas.height <= 0 || viewport.width <= 0 || viewport.height <= 0 {
		return {canvas = canvas, viewport = viewport}
	}
	scale := min(viewport.width / canvas.width, viewport.height / canvas.height)
	return {
		scale = scale,
		offset = {
			x = (viewport.width - canvas.width * scale) / 2,
			y = (viewport.height - canvas.height * scale) / 2,
		},
		canvas = canvas,
		viewport = viewport,
	}
}

canvas_point_to_window :: proc(t: Canvas_Transform, p: Point) -> Point {
	return {x = t.offset.x + p.x * t.scale, y = t.offset.y + p.y * t.scale}
}

canvas_rect_to_window :: proc(t: Canvas_Transform, r: Rect) -> Rect {
	origin := canvas_point_to_window(t, {x = r.x, y = r.y})
	return {x = origin.x, y = origin.y, width = r.width * t.scale, height = r.height * t.scale}
}

// window_point_to_canvas is the inverse mapping. It reports
// false for points in the letterbox (outside the scaled canvas),
// on the far canvas edge, or when the transform has zero scale,
// so pointer input and inspection always agree.
window_point_to_canvas :: proc(t: Canvas_Transform, p: Point) -> (Point, bool) {
	if t.scale <= 0 {
		return {}, false
	}
	canvas_p := Point{x = (p.x - t.offset.x) / t.scale, y = (p.y - t.offset.y) / t.scale}
	if canvas_p.x < 0 || canvas_p.y < 0 || canvas_p.x >= t.canvas.width || canvas_p.y >= t.canvas.height {
		return {}, false
	}
	return canvas_p, true
}

// resolve_canvas resolves a canvas for a viewport into the same
// Frame the flow layout produces: each Resolved_Element keeps
// its original canvas_bounds and gains resolved window bounds.
// Element IDs must be unique within the canvas, as in resolve.
// A zero-sized viewport resolves safely with empty window bounds.
resolve_canvas :: proc(canvas: Canvas, viewport: Size, allocator := context.allocator) -> (Frame, bool) {
	elements, err := make([]Resolved_Element, len(canvas.elements), allocator)
	if err != nil {
		return {}, false
	}
	for element, i in canvas.elements {
		for prev in canvas.elements[:i] {
			if prev.info.id == element.info.id {
				delete(elements, allocator)
				return {}, false
			}
		}
	}
	transform := canvas_transform(canvas.size, viewport)
	for element, i in canvas.elements {
		elements[i] = {
			info = element.info,
			kind = element.kind,
			text = element.text,
			bounds = canvas_rect_to_window(transform, element.bounds),
			canvas_bounds = element.bounds,
			actions = actions_for(element.kind),
		}
	}
	return {elements = elements, allocator = allocator, transform = transform, has_canvas = true}, true
}

// hit_test_canvas hit-tests a window point against a canvas
// frame: the point must land inside the canvas (a letterbox
// click misses even when an element extends past the canvas
// edge), and the last-drawn matching element wins.
hit_test_canvas :: proc(frame: Frame, p: Point) -> (Object_Id, bool) {
	if !frame.has_canvas {
		return hit_test(frame, p)
	}
	canvas_p, inside := window_point_to_canvas(frame.transform, p)
	if !inside {
		return 0, false
	}
	for i := len(frame.elements) - 1; i >= 0; i -= 1 {
		if contains(frame.elements[i].canvas_bounds, canvas_p) {
			return frame.elements[i].info.id, true
		}
	}
	return 0, false
}
