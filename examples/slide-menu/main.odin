// slide-menu is the acceptance fixture for slide-row context
// menus. Two slides, A (ID 10) and B (ID 11), are editable
// single-line fields with distinct stable IDs. A starts
// selected. Each slide owns a context menu with a disabled
// item and an enabled command; choosing a command reaches
// the app as an ordinary Activate whose target slide the app
// records, and the app's policy is to preserve the current
// selection and both texts.
//
// The app prints one line per observable event so a script
// can check order and origin without learning host internals:
//
//	COMMIT id=10 text=abXcd
//	ACTION mark-b target=11 origin=local
//	COMPOSITION id=10 composing=true
//
// Build with -define:MENUS=true once the host has context
// menus: the declaration under `when MENUS` is the whole
// opt-in. Its type names (sdlhost.Context_Menu) follow the
// menu-bar fixture's placeholder shape and may need to match
// the agreed public API on the candidate branch.
package main

import "core:fmt"
import "core:os"
import "dagda:dagda"
import "dagda:dagda/sdlhost"

MENUS :: #config(MENUS, false)

A_ID :: dagda.Object_Id(10)
B_ID :: dagda.Object_Id(11)
STATUS_ID :: dagda.Object_Id(12)
A_LOCK_ID :: dagda.Object_Id(20)
A_MARK_ID :: dagda.Object_Id(21)
B_LOCK_ID :: dagda.Object_Id(22)
B_MARK_ID :: dagda.Object_Id(23)

when MENUS {
	Menu_Storage :: struct {
		a_items:  [2]sdlhost.Menu_Item,
		b_items:  [2]sdlhost.Menu_Item,
		contexts: [2]sdlhost.Context_Menu,
	}
} else {
	Menu_Storage :: struct {}
}

Slide_App :: struct {
	a_buf:       [128]u8,
	b_buf:       [128]u8,
	a_text:      string,
	b_text:      string,
	selected:    dagda.Object_Id,
	actions_a:   int,
	actions_b:   int,
	status:      [128]u8,
	elements:    [3]dagda.Canvas_Element,
	editable:    [2]dagda.Object_Id,
	menus:       Menu_Storage,
}

canvas :: proc(user_data: rawptr) -> dagda.Canvas {
	app := (^Slide_App)(user_data)
	status := fmt.bprintf(app.status[:], "selected=%d actions_a=%d actions_b=%d", u64(app.selected), app.actions_a, app.actions_b)
	app.elements = {
		{info = {id = A_ID, role = "slide.a"}, kind = .Label, text = app.a_text, bounds = {x = 80, y = 80, width = 800, height = 64}},
		{info = {id = B_ID, role = "slide.b"}, kind = .Label, text = app.b_text, bounds = {x = 80, y = 220, width = 800, height = 64}},
		{info = {id = STATUS_ID, role = "slide.status"}, kind = .Label, text = status, bounds = {x = 80, y = 340, width = 800, height = 48}},
	}
	return {size = {width = 960, height = 540}, elements = app.elements[:]}
}

handle :: proc(user_data: rawptr, id: dagda.Object_Id, action: dagda.Action) -> bool {
	app := (^Slide_App)(user_data)
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
	switch id {
	case A_MARK_ID:
		app.actions_a += 1
		fmt.printf("ACTION mark-a target=%d origin=%s\n", u64(A_ID), origin)
		return true
	case B_MARK_ID:
		app.actions_b += 1
		fmt.printf("ACTION mark-b target=%d origin=%s\n", u64(B_ID), origin)
		return true
	}
	return false
}

commit :: proc(user_data: rawptr, id: dagda.Object_Id, new_text: string) -> bool {
	app := (^Slide_App)(user_data)
	switch id {
	case A_ID:
		if len(new_text) > len(app.a_buf) {
			return false
		}
		app.a_text = string(app.a_buf[:copy(app.a_buf[:], new_text)])
	case B_ID:
		if len(new_text) > len(app.b_buf) {
			return false
		}
		app.b_text = string(app.b_buf[:copy(app.b_buf[:], new_text)])
	case:
		return false
	}
	fmt.printf("COMMIT id=%d text=%s\n", u64(id), new_text)
	return true
}

composition :: proc(user_data: rawptr, field_id: dagda.Object_Id, composing: bool) {
	fmt.printf("COMPOSITION id=%d composing=%v\n", u64(field_id), composing)
	_ = os.flush(os.stdout)
}

ready :: proc(_: rawptr, _: sdlhost.Rebuild_Handle) {
	fmt.println("READY")
}

main :: proc() {
	state: Slide_App
	state.a_text = string(state.a_buf[:copy(state.a_buf[:], "abcd")])
	state.b_text = string(state.b_buf[:copy(state.b_buf[:], "Beta")])
	state.selected = A_ID
	state.editable = {A_ID, B_ID}
	when MENUS {
		state.menus.a_items = {
			{info = {id = A_LOCK_ID, role = "slide.a.cmd.lock"}, text = "Lock A", enabled = false},
			{info = {id = A_MARK_ID, role = "slide.a.cmd.mark"}, text = "Mark A", enabled = true},
		}
		state.menus.b_items = {
			{info = {id = B_LOCK_ID, role = "slide.b.cmd.lock"}, text = "Lock B", enabled = false},
			{info = {id = B_MARK_ID, role = "slide.b.cmd.mark"}, text = "Mark B", enabled = true},
		}
		state.menus.contexts = {
			{target_id = A_ID, items = state.menus.a_items[:]},
			{target_id = B_ID, items = state.menus.b_items[:]},
		}
	}
	opts, ok := sdlhost.parse_cli_args(os.args[1:])
	if !ok {
		fmt.eprintln("usage: slide-menu [--size WxH] [--control-stdin] [--socket PATH]")
		return
	}
	app := sdlhost.App{
		title                 = "Dagda — Slide context menus",
		width                 = 960,
		height                = 540,
		user_data             = &state,
		canvas                = canvas,
		handle                = handle,
		on_ready              = ready,
		on_composition        = composition,
		text_edit             = {enabled = true, on_commit = commit},
		editable_text_targets = state.editable[:],
	}
	when MENUS {
		// Borrowed for the whole run: the state owns both item
		// arrays and the context array behind these slices,
		// and nothing reslices them after startup.
		app.context_menus = state.menus.contexts[:]
	}
	sdlhost.run(app, opts)
}
