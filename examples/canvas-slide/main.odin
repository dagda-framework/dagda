package main

import "core:fmt"
import "core:os"
import "core:strings"
import "dagda:dagda"
import "dagda:dagda/driver"
import "dagda:dagda/sdlhost"

HEADLINE_ID :: dagda.Object_Id(1)
CARD_ID :: dagda.Object_Id(2)
UNDO_ID :: dagda.Object_Id(3)
STATUS_ID :: dagda.Object_Id(4)
RESIZE_HANDLE_SIZE :: f32(28)
MIN_CARD_WIDTH :: f32(80)
MIN_CARD_HEIGHT :: f32(60)

Gesture_Kind :: enum {
	None,
	Move,
	Resize,
}

Undo_Kind :: enum {
	Card_Rect,
	Headline_Text,
}

Undo_Entry :: struct {
	kind: Undo_Kind,
	rect: dagda.Rect,
	text: string, // owned when kind == .Headline_Text
}

// Slide_Canvas is an app-owned fixed-aspect (16:9) canvas fixture.
// Slide-specific state (committed headline text, revision, selection,
// geometry, gestures, and undo history) stays in the consuming app,
// outside Dagda core and sdlhost.
Slide_Canvas :: struct {
	headline:               string,
	headline_rev:           u64,
	card:                   dagda.Rect,
	selected:               bool,
	clicks:                 int,
	undo_stack:             [dynamic]Undo_Entry,
	gesture:                Gesture_Kind,
	gesture_start_rect:     dagda.Rect,
	gesture_start_point:    dagda.Point,
	gesture_start_selected: bool,
	status_buf:             [96]u8,
	elements:               [4]dagda.Canvas_Element,
}

slide_destroy :: proc(s: ^Slide_Canvas) {
	delete(s.headline)
	for entry in s.undo_stack {
		if entry.kind == .Headline_Text {
			delete(entry.text)
		}
	}
	delete(s.undo_stack)
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
	status := fmt.bprintf(
		s.status_buf[:],
		"selected=%v, clicks=%d, rev=%d, undo=%d",
		s.selected,
		s.clicks,
		s.headline_rev,
		len(s.undo_stack),
	)
	s.elements = {
		{
			info   = {id = HEADLINE_ID, role = "slide.headline"},
			kind   = .Label,
			text   = s.headline,
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
		{
			info   = {id = STATUS_ID, role = "slide.status"},
			kind   = .Label,
			text   = status,
			bounds = {x = 320, y = 460, width = 400, height = 44},
		},
	}
	return {
		size     = {width = 960, height = 540},
		elements = s.elements[:],
	}
}

slide_apply_undo :: proc(s: ^Slide_Canvas) -> bool {
	if s.gesture != .None || len(s.undo_stack) == 0 {
		return false
	}
	entry := pop(&s.undo_stack)
	switch entry.kind {
	case .Card_Rect:
		s.card = entry.rect
	case .Headline_Text:
		delete(s.headline)
		s.headline = entry.text
		s.headline_rev += 1
	}
	return true
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
		return slide_apply_undo(s)
	}
	return false
}

slide_edits := []dagda.Advertised_Edit{
	{object_id = HEADLINE_ID, edit = "replace_text", argument = .Text},
}

// slide_edit_handle is the app-owned replace_text handler: it
// enforces the headline revision and records exactly one undo
// entry per accepted replacement, like the keyboard path.
slide_edit_handle :: proc(user_data: rawptr, target: dagda.Action_Target, edit: string, arg: dagda.Edit_Argument) -> dagda.Edit_Result {
	s := (^Slide_Canvas)(user_data)
	if target.id != HEADLINE_ID {
		return .Unknown_Object
	}
	if target.base_revision != dagda.Revision(s.headline_rev) {
		return .Stale_Revision
	}
	return slide_commit_headline(s, arg.text)
}

slide_revision :: proc(user_data: rawptr, id: dagda.Object_Id) -> (dagda.Revision, bool) {
	s := (^Slide_Canvas)(user_data)
	if id != HEADLINE_ID {
		return 0, false
	}
	return dagda.Revision(s.headline_rev), true
}

// slide_commit_headline is the one app-owned mutation path for
// the headline: keyboard composition commits and driver edits
// both land here, so the single-line rule, undo entry, and
// revision advance can never diverge between them.
slide_commit_headline :: proc(s: ^Slide_Canvas, new_text: string) -> dagda.Edit_Result {
	if !dagda.valid_single_line(new_text) || new_text == s.headline {
		return .Not_Handled
	}
	cloned, err := strings.clone(new_text)
	if err != nil || len(cloned) != len(new_text) {
		return .Alloc_Failed
	}
	s.undo_stack.allocator = context.allocator
	if reserve(&s.undo_stack, len(s.undo_stack) + 1) != nil {
		delete(cloned)
		return .Alloc_Failed
	}
	append(&s.undo_stack, Undo_Entry{kind = .Headline_Text, text = s.headline})
	s.headline = cloned
	s.headline_rev += 1
	return .Applied
}

slide_text_commit :: proc(user_data: rawptr, id: dagda.Object_Id, new_text: string) -> bool {
	s := (^Slide_Canvas)(user_data)
	if id != HEADLINE_ID {
		return false
	}
	return slide_commit_headline(s, new_text) == .Applied
}

slide_text_undo :: proc(user_data: rawptr, id: dagda.Object_Id) -> bool {
	s := (^Slide_Canvas)(user_data)
	if id != HEADLINE_ID {
		return false
	}
	return slide_apply_undo(s)
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
			append(&s.undo_stack, Undo_Entry{kind = .Card_Rect, rect = s.gesture_start_rect})
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
		headline = strings.clone("Slide Canvas"),
		card     = {x = 220, y = 200, width = 520, height = 220},
	}
	defer slide_destroy(&slide)

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
		edits      = driver.Edit_Source{edits = slide_edits, handler = slide_edit_handle, user_data = &slide, revision_of = slide_revision},
		text_edit  = {
			enabled   = true,
			target_id = HEADLINE_ID,
			on_commit = slide_text_commit,
			on_undo   = slide_text_undo,
		},
	}
	if code := sdlhost.run(app, opts); code != 0 {
		os.exit(code)
	}
}
