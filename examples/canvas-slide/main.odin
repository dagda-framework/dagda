package main

import "core:fmt"
import "core:os"
import "dagda:dagda"
import "dagda:dagda/sdlhost"

CARD_ID :: dagda.Object_Id(2)
UNDO_ID :: dagda.Object_Id(3)
RESIZE_HANDLE_SIZE :: f32(28)
MIN_CARD_WIDTH :: f32(80)
MIN_CARD_HEIGHT :: f32(60)

Gesture_Kind :: enum {
	None,
	Move,
	Resize,
}

// Slide_Canvas is an app-owned fixed-aspect (16:9) canvas fixture.
// Slide-specific state (selection, geometry, gestures, and undo history)
// stays in the consuming app, outside Dagda core and sdlhost.
Slide_Canvas :: struct {
	card:                   dagda.Rect,
	selected:               bool,
	clicks:                 int,
	undo_stack:             [dynamic]dagda.Rect,
	gesture:                Gesture_Kind,
	gesture_start_rect:     dagda.Rect,
	gesture_start_point:    dagda.Point,
	gesture_start_selected: bool,
	headline_buf:           [96]u8,
	elements:               [3]dagda.Canvas_Element,
}

apply_gesture_point :: proc(s: ^Slide_Canvas, point: dagda.Point) {
	dx := point.x - s.gesture_start_point.x
	dy := point.y - s.gesture_start_point.y
	#partial switch s.gesture {
	case .Move:
		s.card = {
			x      = s.gesture_start_rect.x + dx,
			y      = s.gesture_start_rect.y + dy,
			width  = s.gesture_start_rect.width,
			height = s.gesture_start_rect.height,
		}
	case .Resize:
		s.card = {
			x      = s.gesture_start_rect.x,
			y      = s.gesture_start_rect.y,
			width  = max(MIN_CARD_WIDTH, s.gesture_start_rect.width + dx),
			height = max(MIN_CARD_HEIGHT, s.gesture_start_rect.height + dy),
		}
	}
}

slide_canvas :: proc(user_data: rawptr) -> dagda.Canvas {
	s := (^Slide_Canvas)(user_data)
	headline := fmt.bprintf(
		s.headline_buf[:],
		"Slide Canvas (selected=%v, clicks=%d, undo=%d)",
		s.selected,
		s.clicks,
		len(s.undo_stack),
	)
	s.elements = {
		{
			info   = {id = 1, role = "slide.headline"},
			kind   = .Label,
			text   = headline,
			bounds = {x = 80, y = 60, width = 640, height = 80},
		},
		{
			info   = {id = UNDO_ID, role = "slide.undo"},
			kind   = .Button,
			text   = "Undo",
			bounds = {x = 740, y = 60, width = 140, height = 80},
		},
		{
			info   = {id = CARD_ID, role = "slide.card"},
			kind   = .Button,
			text   = s.selected ? "Selected Card" : "Filled Card",
			bounds = s.card,
		},
	}
	return {
		size     = {width = 960, height = 540},
		elements = s.elements[:],
	}
}

slide_handle :: proc(user_data: rawptr, id: dagda.Object_Id, action: dagda.Action) -> bool {
	s := (^Slide_Canvas)(user_data)
	if action != .Activate {
		return false
	}
	if id == CARD_ID {
		s.selected = true
		s.clicks += 1
		return true
	}
	if id == UNDO_ID {
		if s.gesture != .None || len(s.undo_stack) == 0 {
			return false
		}
		s.card = pop(&s.undo_stack)
		return true
	}
	return false
}

slide_pointer :: proc(user_data: rawptr, ev: sdlhost.Pointer_Event) -> bool {
	s := (^Slide_Canvas)(user_data)
	switch ev.phase {
	case .Press:
		if ev.has_target && ev.target_id == CARD_ID {
			s.gesture_start_rect = s.card
			s.gesture_start_point = ev.point
			s.gesture_start_selected = s.selected
			s.selected = true
			in_resize_corner :=
				ev.point.x >= s.card.x + s.card.width - RESIZE_HANDLE_SIZE &&
				ev.point.y >= s.card.y + s.card.height - RESIZE_HANDLE_SIZE
			s.gesture = in_resize_corner ? .Resize : .Move
			return true
		}
		if !ev.has_target && s.selected {
			s.selected = false
			return true
		}
		return false

	case .Move:
		if s.gesture == .None {
			return false
		}
		apply_gesture_point(s, ev.point)
		return true

	case .Release:
		if s.gesture == .None {
			return false
		}
		apply_gesture_point(s, ev.point)
		if s.card != s.gesture_start_rect {
			append(&s.undo_stack, s.gesture_start_rect)
		}
		s.gesture = .None
		return true

	case .Cancel:
		if s.gesture == .None {
			return false
		}
		s.card = s.gesture_start_rect
		s.selected = s.gesture_start_selected
		s.gesture = .None
		return true
	}
	return false
}

main :: proc() {
	slide := Slide_Canvas{
		card = {x = 220, y = 200, width = 520, height = 220},
	}
	defer delete(slide.undo_stack)

	host_args := make([dynamic]string, 0, len(os.args))
	defer delete(host_args)
	for arg in os.args[1:] {
		if arg == "--overflow-card" {
			// Extends above and below the 960x540 canvas with fractional f32 x/width.
			slide.card = {x = 93.125, y = -40, width = 200.0625, height = 620}
		} else {
			append(&host_args, arg)
		}
	}

	opts, ok := sdlhost.parse_cli_args(host_args[:])
	if !ok {
		fmt.eprintln("usage: canvas-slide [--size WxH] [--socket <socket-path>] [--overflow-card]")
		os.exit(2)
	}
	app := sdlhost.App{
		title      = "Dagda — Canvas Slide",
		width      = 800,
		height     = 540,
		user_data  = &slide,
		canvas     = slide_canvas,
		handle     = slide_handle,
		on_pointer = slide_pointer,
	}
	if code := sdlhost.run(app, opts); code != 0 {
		os.exit(code)
	}
}
