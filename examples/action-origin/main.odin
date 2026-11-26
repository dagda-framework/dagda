package main

import "core:fmt"
import "core:os"
import "core:strings"
import "dagda:dagda"
import "dagda:dagda/sdlhost"

CURRENT_TITLE_ID :: dagda.Object_Id(1)
ADD_BUTTON_ID :: dagda.Object_Id(2)
STATUS_ID :: dagda.Object_Id(3)
ITEM_BASE_ID :: dagda.Object_Id(10)

MAX_DISPLAY_ITEMS :: 6

Origin_Fixture :: struct {
	items:                [dynamic]string,
	selected:             int,
	last_origin:          sdlhost.Action_Origin,
	frame_origin:         sdlhost.Action_Origin,
	local_count:          int,
	driver_count:         int,
	treat_driver_as_local: bool,
	status_buf:           [160]u8,
	item_roles:           [MAX_DISPLAY_ITEMS]string,
	elements:             [3 + MAX_DISPLAY_ITEMS]dagda.Canvas_Element,
}

origin_name :: proc(o: sdlhost.Action_Origin) -> string {
	switch o {
	case .None:
		return "None"
	case .Local:
		return "Local"
	case .Driver:
		return "Driver"
	}
	return "None"
}

fixture_init :: proc(s: ^Origin_Fixture, treat_driver_as_local: bool) {
	s^ = {
		treat_driver_as_local = treat_driver_as_local,
		item_roles            = {"item.0", "item.1", "item.2", "item.3", "item.4", "item.5"},
	}
	append(&s.items, strings.clone("abcd"))
}

fixture_destroy :: proc(s: ^Origin_Fixture) {
	for item in s.items {
		delete(item)
	}
	delete(s.items)
	s^ = {}
}

fixture_canvas :: proc(user_data: rawptr) -> dagda.Canvas {
	s := (^Origin_Fixture)(user_data)
	s.frame_origin = sdlhost.current_action_origin()
	cur_text := s.selected >= 0 && s.selected < len(s.items) ? s.items[s.selected] : ""
	status := fmt.bprintf(
		s.status_buf[:],
		"count=%d selected=%d last_origin=%s local=%d driver=%d frame_origin=%s",
		len(s.items),
		s.selected,
		origin_name(s.last_origin),
		s.local_count,
		s.driver_count,
		origin_name(s.frame_origin),
	)
	n := 0
	s.elements[n] = {
		info   = {id = CURRENT_TITLE_ID, role = "item.current"},
		kind   = .Label,
		text   = cur_text,
		bounds = {x = 60, y = 40, width = 560, height = 72},
	}
	n += 1
	s.elements[n] = {
		info   = {id = ADD_BUTTON_ID, role = "item.add"},
		kind   = .Button,
		text   = "Add",
		bounds = {x = 650, y = 40, width = 140, height = 72},
	}
	n += 1
	s.elements[n] = {
		info   = {id = STATUS_ID, role = "origin.status"},
		kind   = .Label,
		text   = status,
		bounds = {x = 60, y = 136, width = 730, height = 52},
	}
	n += 1
	shown := min(len(s.items), MAX_DISPLAY_ITEMS)
	for i in 0 ..< shown {
		s.elements[n] = {
			info   = {id = ITEM_BASE_ID + dagda.Object_Id(i), role = s.item_roles[i]},
			kind   = .Label,
			text   = s.items[i],
			bounds = {x = 60, y = f32(210 + i * 48), width = 730, height = 40},
		}
		n += 1
	}
	return {
		size     = {width = 860, height = 540},
		elements = s.elements[:n],
	}
}

fixture_handle :: proc(user_data: rawptr, id: dagda.Object_Id, action: dagda.Action) -> bool {
	s := (^Origin_Fixture)(user_data)
	if id != ADD_BUTTON_ID || action != .Activate {
		return false
	}
	origin := sdlhost.current_action_origin()
	if s.treat_driver_as_local && origin == .Driver {
		origin = .Local
	}
	s.last_origin = origin
	switch origin {
	case .Local:
		s.local_count += 1
	case .Driver:
		s.driver_count += 1
	case .None:
	}

	next_num := len(s.items) + 1
	label := fmt.aprintf("Item %d", next_num)
	append(&s.items, label)
	if origin == .Local {
		s.selected = len(s.items) - 1
	}
	return true
}

fixture_commit :: proc(user_data: rawptr, id: dagda.Object_Id, new_text: string) -> bool {
	s := (^Origin_Fixture)(user_data)
	if id != CURRENT_TITLE_ID || s.selected < 0 || s.selected >= len(s.items) {
		return false
	}
	if !dagda.valid_single_line(new_text) || new_text == s.items[s.selected] {
		return false
	}
	cloned, err := strings.clone(new_text)
	if err != nil {
		return false
	}
	delete(s.items[s.selected])
	s.items[s.selected] = cloned
	return true
}

main :: proc() {
	treat_driver_as_local := false
	host_args: [dynamic]string
	defer delete(host_args)
	for arg in os.args[1:] {
		if arg == "--treat-driver-as-local" {
			treat_driver_as_local = true
		} else {
			append(&host_args, arg)
		}
	}

	opts, ok := sdlhost.parse_cli_args(host_args[:])
	if !ok {
		fmt.eprintln("usage: action-origin [--treat-driver-as-local] [--size WxH] [--socket <path>] [--control-stdin]")
		os.exit(2)
	}

	state: Origin_Fixture
	fixture_init(&state, treat_driver_as_local)
	defer fixture_destroy(&state)

	app := sdlhost.App{
		title     = "Dagda — Action Origin Fixture",
		width     = 800,
		height    = 540,
		user_data = &state,
		canvas    = fixture_canvas,
		handle    = fixture_handle,
		text_edit = {
			enabled   = true,
			target_id = CURRENT_TITLE_ID,
			on_commit = fixture_commit,
		},
	}
	if code := sdlhost.run(app, opts); code != 0 {
		os.exit(code)
	}
}
