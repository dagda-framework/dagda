// menu-bar is the fixture for the menu bar request.
//
// One window holds a single-line editable title, a button, a status
// line, and two menus: File (Stamp, Locked, Mark) and View (Flip).
// Locked is never available. The app owns the text and four counters. It
// never sees a key, a caret, a selection or which menu is open: it
// answers the host's commit callback and its action handler, and prints
// one line for each so a script can check exactly what the host handed
// over, in what order, and where it came from.
//
//	COMMIT text=abXcd
//	ACTION stamp origin=local
//	ACTION mark origin=driver
//
// Build it against today's host and the menus are made of what there is:
// a button per title, and a column of buttons that the app adds to the
// canvas while a menu is open. That is what the script's first run
// drives. Build with -define:MENUS=true once the host has menus: the
// lines under `when MENUS` are the whole opt-in, and their names are
// placeholders for whatever Dagda calls them.
package main

import "core:fmt"
import "core:os"
import "dagda:dagda"
import "dagda:dagda/sdlhost"

MENUS :: #config(MENUS, false)

TITLE_ID :: dagda.Object_Id(1)
STATUS_ID :: dagda.Object_Id(2)
BUMP_ID :: dagda.Object_Id(3)
STAMP_ID :: dagda.Object_Id(10)
LOCKED_ID :: dagda.Object_Id(11)
MARK_ID :: dagda.Object_Id(12)
FLIP_ID :: dagda.Object_Id(13)
// Used only by the menu the app builds for itself on today's host.
FILE_ID :: dagda.Object_Id(20)
VIEW_ID :: dagda.Object_Id(21)

ROLE_MENU_TITLE :: "menu.title"

when MENUS {
	Menu_Storage :: struct {
		file_items: [3]sdlhost.Menu_Item,
		view_items: [1]sdlhost.Menu_Item,
		menus:      [2]sdlhost.Menu,
	}
} else {
	Menu_Storage :: struct {}
}

Note_App :: struct {
	text:     string,
	buf:      [256]u8,
	stamp:    int,
	mark:     int,
	flip:     int,
	bump:     int,
	status:   [96]u8,
	// 0 for none, else FILE_ID or VIEW_ID. Today's host only.
	open:     dagda.Object_Id,
	elements: [10]dagda.Canvas_Element,
	editable: [1]dagda.Object_Id,
	menus:    Menu_Storage,
}

SIZE :: dagda.Size{width = 960, height = 540}

canvas :: proc(user_data: rawptr) -> dagda.Canvas {
	app := (^Note_App)(user_data)
	status := fmt.bprintf(app.status[:], "stamp=%d mark=%d flip=%d bump=%d", app.stamp, app.mark, app.flip, app.bump)
	n := 0
	app.elements[n] = {info = {id = TITLE_ID, role = "note.title"}, kind = .Label, text = app.text, bounds = {80, 120, 800, 60}}
	n += 1
	app.elements[n] = {info = {id = BUMP_ID, role = "note.bump"}, kind = .Button, text = "Bump", bounds = {80, 220, 200, 48}}
	n += 1
	app.elements[n] = {info = {id = STATUS_ID, role = "note.status"}, kind = .Label, text = status, bounds = {80, 300, 800, 48}}
	n += 1
	when !MENUS {
		file := dagda.Rect{16, 4, 80, 32}
		view := dagda.Rect{104, 4, 80, 32}
		app.elements[n] = {info = {id = FILE_ID, role = ROLE_MENU_TITLE}, kind = .Button, text = "File", bounds = file}
		n += 1
		app.elements[n] = {info = {id = VIEW_ID, role = ROLE_MENU_TITLE}, kind = .Button, text = "View", bounds = view}
		n += 1
		item := dagda.Rect{file.x, 40, 200, 36}
		if app.open == FILE_ID {
			app.elements[n] = {info = {id = STAMP_ID, role = "cmd.stamp"}, kind = .Button, text = "Stamp", bounds = item}
			item.y += 36
			app.elements[n + 1] = {info = {id = LOCKED_ID, role = "cmd.locked"}, kind = .Label, text = "Locked", bounds = item}
			item.y += 36
			app.elements[n + 2] = {info = {id = MARK_ID, role = "cmd.mark"}, kind = .Button, text = "Mark", bounds = item}
			n += 3
		} else if app.open == VIEW_ID {
			item.x = view.x
			app.elements[n] = {info = {id = FLIP_ID, role = "cmd.flip"}, kind = .Button, text = "Flip", bounds = item}
			n += 1
		}
	}
	return {size = SIZE, elements = app.elements[:n]}
}

handle :: proc(user_data: rawptr, id: dagda.Object_Id, action: dagda.Action) -> bool {
	app := (^Note_App)(user_data)
	if action != .Activate {
		return false
	}
	origin := "none"
	#partial switch sdlhost.current_action_origin() {
	case .Local:
		origin = "local"
	case .Driver:
		origin = "driver"
	}
	name: string
	switch id {
	case STAMP_ID:
		app.stamp += 1
		name = "stamp"
	case MARK_ID:
		app.mark += 1
		name = "mark"
	case FLIP_ID:
		app.flip += 1
		name = "flip"
	case BUMP_ID:
		app.bump += 1
		name = "bump"
	case FILE_ID, VIEW_ID:
		app.open = app.open == id ? 0 : id
		return true
	case:
		return false
	}
	app.open = 0
	fmt.printf("ACTION %s origin=%s\n", name, origin)
	return true
}

// Today's host only: a press anywhere but on the open menu closes it.
pointer :: proc(user_data: rawptr, ev: sdlhost.Pointer_Event) -> bool {
	app := (^Note_App)(user_data)
	if ev.phase != .Press || app.open == 0 {
		return false
	}
	if ev.has_target && ev.target_id >= STAMP_ID {
		return false
	}
	app.open = 0
	return true
}

commit :: proc(user_data: rawptr, field: dagda.Object_Id, new_text: string) -> bool {
	app := (^Note_App)(user_data)
	if field != TITLE_ID || len(new_text) > len(app.buf) {
		return false
	}
	n := copy(app.buf[:], new_text)
	app.text = string(app.buf[:n])
	fmt.printf("COMMIT text=%s\n", app.text)
	return true
}

ready :: proc(_: rawptr, _: sdlhost.Rebuild_Handle) {
	fmt.println("READY")
}

main :: proc() {
	state: Note_App
	n := copy(state.buf[:], "abcd")
	state.text = string(state.buf[:n])
	state.editable = {TITLE_ID}
	when MENUS {
		state.menus.file_items = {
			{info = {id = STAMP_ID, role = "cmd.stamp"}, text = "Stamp", enabled = true},
			{info = {id = LOCKED_ID, role = "cmd.locked"}, text = "Locked", enabled = false},
			{info = {id = MARK_ID, role = "cmd.mark"}, text = "Mark", enabled = true},
		}
		state.menus.view_items = {{info = {id = FLIP_ID, role = "cmd.flip"}, text = "Flip", enabled = true}}
		state.menus.menus = {{text = "File", items = state.menus.file_items[:]}, {text = "View", items = state.menus.view_items[:]}}
	}
	opts, ok := sdlhost.parse_cli_args(os.args[1:])
	if !ok {
		fmt.eprintln("usage: menu-bar [--size WxH] [--control-stdin] [--socket PATH]")
		return
	}
	app := sdlhost.App {
		title                 = "Menu bar",
		width                 = i32(SIZE.width),
		height                = i32(SIZE.height),
		user_data             = &state,
		canvas                = canvas,
		handle                = handle,
		on_ready              = ready,
		text_edit             = {enabled = true, on_commit = commit},
		editable_text_targets = state.editable[:],
	}
	when MENUS {
		// The whole opt-in. The host draws the bar, opens and closes the
		// menus, moves through them, and reports each item to a driver.
		// An item reaches `handle` like any other activation. The
		// backing arrays live in app state (initialized above), so
		// they stay alive for the whole sdlhost.run below.
		app.menus = state.menus.menus[:]
	} else {
		app.on_pointer = pointer
	}
	sdlhost.run(app, opts)
}
