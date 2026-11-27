// Left and Right change the counter. Escape resets it. Focus the field or
// open the menu to give the same keys to the host's editor or menu instead.
package main

import "core:fmt"
import "core:os"
import "dagda:dagda"
import "dagda:dagda/sdlhost"

FIELD :: dagda.Object_Id(2)
RESET :: dagda.Object_Id(3)

State :: struct {
	count:    int,
	number:   [32]u8,
	text:     string,
	storage:  [128]u8,
	elements: [2]dagda.Canvas_Element,
}

canvas :: proc(data: rawptr) -> dagda.Canvas {
	s := (^State)(data)
	s.elements = {
		{info = {id = 1, role = "keys.count"}, kind = .Label,
		 text = fmt.bprintf(s.number[:], "%d", s.count), bounds = {16, 48, 260, 44}},
		{info = {id = FIELD, role = "keys.field"}, kind = .Label,
		 text = s.text, bounds = {16, 108, 260, 44}},
	}
	return {size = {320, 180}, elements = s.elements[:]}
}

on_key :: proc(data: rawptr, key: sdlhost.Key, mods: sdlhost.Key_Mods, repeat: bool) -> bool {
	s := (^State)(data)
	if mods != {} || repeat {
		return false
	}
	switch key {
	case .Left:   s.count -= 1
	case .Right:  s.count += 1
	case .Escape:
		if s.count == 0 { return false }
		s.count = 0
	}
	return true
}

handle :: proc(data: rawptr, id: dagda.Object_Id, action: dagda.Action) -> bool {
	if id != RESET || action != .Activate { return false }
	(^State)(data).count = 0
	return true
}

commit :: proc(data: rawptr, id: dagda.Object_Id, proposed: string) -> bool {
	s := (^State)(data)
	if id != FIELD || len(proposed) > len(s.storage) { return false }
	n := copy(s.storage[:], proposed)
	s.text = string(s.storage[:n])
	return true
}

main :: proc() {
	opts, ok := sdlhost.parse_cli_args(os.args[1:])
	if !ok { os.exit(2) }
	state := State{text = "abcd"}
	items := [1]sdlhost.Menu_Item{{info = {id = RESET, role = "keys.reset"}, text = "Reset", enabled = true}}
	menus := [1]sdlhost.Menu{{text = "Counter", items = items[:]}}
	os.exit(sdlhost.run({
		title = "Application keys", width = 320, height = 180, user_data = &state,
		canvas = canvas, handle = handle, on_key = on_key, menus = menus[:],
		text_edit = {enabled = true, target_id = FIELD, on_commit = commit},
	}, opts))
}
