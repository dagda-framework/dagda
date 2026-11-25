package dagda

import "core:mem"

// A reusable element: the smallest unit an app can show, hit-test,
// and act on. Elements reuse Object_Id / Object_Info for their
// stable identity and semantic role.

Element_Kind :: enum {
	Label,
	Button,
}

// Actions an element can offer. Only Activate exists in this slice.
Action :: enum {
	Activate,
}

Action_Set :: bit_set[Action]

// An app-supplied element definition. The view borrows the text
// and role strings; the app keeps them alive while the view and
// any frame resolved from it are in use.
Element :: struct {
	info: Object_Info, // stable id + semantic role
	kind: Element_Kind,
	text: string,
}

// A view is a borrowed slice of element definitions owned by the app.
View :: struct {
	elements: []Element,
}

Size :: struct {
	width:  f32,
	height: f32,
}

Point :: struct {
	x: f32,
	y: f32,
}

// Bounds in logical window coordinates: x/y is the top-left
// corner, and the covered range is [x, x+width) x [y, y+height).
Rect :: struct {
	x:      f32,
	y:      f32,
	width:  f32,
	height: f32,
}

contains :: proc(r: Rect, p: Point) -> bool {
	return p.x >= r.x && p.x < r.x + r.width && p.y >= r.y && p.y < r.y + r.height
}

// One element after layout: everything an inspector, hit-tester,
// or agent needs without touching the app's definitions again.
// bounds is in logical window coordinates. canvas_bounds is the
// element's original rectangle in canvas coordinates when the
// frame was resolved from a Canvas (see canvas.odin); for a flow
// layout it equals bounds.
Resolved_Element :: struct {
	info:          Object_Info,
	kind:          Element_Kind,
	text:          string, // borrowed from the view definition
	bounds:        Rect,
	canvas_bounds: Rect,
	actions:       Action_Set,
}

// A resolved frame. Element IDs are unique within a frame and
// stable across rebuilds of the same view; roles may repeat.
// The frame owns its resolved-element storage
// (release it with frame_destroy); the text and role strings it
// points at stay owned by the app's view definitions, so a frame
// must not outlive them or a rebuild of the view.
Frame :: struct {
	elements:  []Resolved_Element,
	allocator: mem.Allocator,
	transform: Canvas_Transform, // valid when has_canvas is set
	has_canvas: bool,
}

actions_for :: proc(kind: Element_Kind) -> Action_Set {
	switch kind {
	case .Label:
		return {}
	case .Button:
		return {.Activate}
	}
	return {}
}

// resolve lays the view out for a viewport. This first slice
// stacks elements vertically with a fixed margin and row height:
// enough to place a label above a button, nothing more.
//
// Element IDs must be unique within a view (roles may repeat):
// an ID names one element in the frame and is meant to stay
// stable for that element across rebuilds, so a duplicate is
// rejected here rather than resolved ambiguously downstream.
resolve :: proc(view: View, viewport: Size, allocator := context.allocator) -> (Frame, bool) {
	elements, err := make([]Resolved_Element, len(view.elements), allocator)
	if err != nil {
		return {}, false
	}
	for element, i in view.elements {
		for prev in view.elements[:i] {
			if prev.info.id == element.info.id {
				delete(elements, allocator)
				return {}, false
			}
		}
	}
	margin: f32 = 16
	row_height: f32 = 40
	gap: f32 = 8
	width := viewport.width - 2 * margin
	if width < 0 {
		width = 0
	}
	for element, i in view.elements {
		bounds := Rect{x = margin, y = margin + f32(i) * (row_height + gap), width = width, height = row_height}
		elements[i] = {
			info = element.info,
			kind = element.kind,
			text = element.text,
			bounds = bounds,
			canvas_bounds = bounds,
			actions = actions_for(element.kind),
		}
	}
	return {elements = elements, allocator = allocator}, true
}

frame_destroy :: proc(frame: ^Frame) {
	delete(frame.elements, frame.allocator)
	frame^ = {}
}

// A forward-only walk over the resolved elements whose role
// matches exactly, in declaration order. Create one with
// query_by_role and pull matches with next_match: break out of
// the loop to stop at the first match, or keep calling until it
// reports false to visit every match. Traversal is a single
// forward pass and allocates nothing.
//
// The returned Resolved_Element is a copy of the frame's record,
// but its text and role strings are borrowed from the view the
// frame was resolved from: use them while that frame is alive.
// After a frame rebuild, discard the old query and start a new
// one against the new frame. The filter string passed to
// query_by_role is borrowed, not copied, and must stay valid
// through the whole traversal.
Role_Query :: struct {
	frame: Frame,
	role:  string,
	index: int,
}

query_by_role :: proc(frame: Frame, role: string) -> Role_Query {
	return {frame = frame, role = role}
}

next_match :: proc(query: ^Role_Query) -> (Resolved_Element, bool) {
	for query.index < len(query.frame.elements) {
		element := query.frame.elements[query.index]
		query.index += 1
		if element.info.role == query.role {
			return element, true
		}
	}
	return {}, false
}

// find returns the resolved element with the given stable ID.
find :: proc(frame: Frame, id: Object_Id) -> (Resolved_Element, bool) {
	for element in frame.elements {
		if element.info.id == id {
			return element, true
		}
	}
	return {}, false
}

// hit_test is the one hit-testing path for every frame. For a
// canvas frame the window point is first clipped to the fitted
// canvas rectangle in window coordinates (so a letterbox click,
// or one beyond the canvas edge on an element that extends past
// it, misses), then resolved window rectangles are tested in
// reverse draw order so the last-drawn element wins. Edges are
// inclusive on the left/top and exclusive on the right/bottom.
hit_test :: proc(frame: Frame, p: Point) -> (Object_Id, bool) {
	if frame.has_canvas {
		fitted := Rect{
			x = frame.transform.offset.x,
			y = frame.transform.offset.y,
			width = frame.transform.canvas.width * frame.transform.scale,
			height = frame.transform.canvas.height * frame.transform.scale,
		}
		if !contains(fitted, p) {
			return 0, false
		}
	}
	for i := len(frame.elements) - 1; i >= 0; i -= 1 {
		if contains(frame.elements[i].bounds, p) {
			return frame.elements[i].info.id, true
		}
	}
	return 0, false
}

// The app's action handler. Pointer clicks and agent invocations
// reach this same procedure. Return true when the action applied.
Action_Handler :: #type proc(user_data: rawptr, id: Object_Id, action: Action) -> bool

Invoke_Result :: enum {
	Applied,
	Unknown_Object,
	Unsupported_Action,
	Not_Handled,
}

// invoke dispatches an action by stable element ID: this is the
// agent path. It changes nothing when the ID is unknown or the
// element does not offer the action.
invoke :: proc(frame: Frame, id: Object_Id, action: Action, handler: Action_Handler, user_data: rawptr = nil) -> Invoke_Result {
	element, found := find(frame, id)
	if !found {
		return .Unknown_Object
	}
	if action not_in element.actions {
		return .Unsupported_Action
	}
	if handler == nil || !handler(user_data, id, action) {
		return .Not_Handled
	}
	return .Applied
}

// click dispatches a pointer press at p: this is the pointer
// path, and it resolves through the very same handler as invoke.
click :: proc(frame: Frame, p: Point, handler: Action_Handler, user_data: rawptr = nil) -> Invoke_Result {
	id, found := hit_test(frame, p)
	if !found {
		return .Unknown_Object
	}
	return invoke(frame, id, .Activate, handler, user_data)
}
