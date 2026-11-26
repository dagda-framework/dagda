package sdlhost

import "core:math"
import "core:sync"
import "core:testing"
import "dagda:dagda"
import sdl "vendor:sdl3"

@(private = "file")
Menu_Test_App :: struct {
	elements: [2]dagda.Canvas_Element,
	editable: [2]dagda.Object_Id,
	a_text:   string,
	b_text:   string,
	file_it:  [3]Menu_Item,
	view_it:  [1]Menu_Item,
	menus:    [2]Menu,
	a_ctx_it: [2]Menu_Item,
	b_ctx_it: [2]Menu_Item,
	contexts: [2]Context_Menu,
}

@(private = "file")
menu_test_canvas :: proc(user_data: rawptr) -> dagda.Canvas {
	app := (^Menu_Test_App)(user_data)
	app.elements = {
		{info = {id = 10, role = "slide.a"}, kind = .Label, text = app.a_text, bounds = {x = 40, y = 60, width = 380, height = 56}},
		{info = {id = 11, role = "slide.b"}, kind = .Label, text = app.b_text, bounds = {x = 40, y = 160, width = 380, height = 56}},
	}
	return {size = {width = 480, height = 300}, elements = app.elements[:]}
}

@(private = "file")
menu_test_setup_host :: proc(t: ^testing.T, state: ^Menu_Test_App, viewport: dagda.Size, surface: ^sdl.Surface, renderer: ^sdl.Renderer) -> (h: Host, ok: bool) {
	state.a_text = "abcd"
	state.b_text = "Beta"
	state.editable = {10, 11}
	state.file_it = {
		{info = {id = 100, role = "cmd.stamp"}, text = "Stamp", enabled = true},
		{info = {id = 101, role = "cmd.locked"}, text = "Locked", enabled = false},
		{info = {id = 102, role = "cmd.mark"}, text = "Mark", enabled = true},
	}
	state.view_it = {
		{info = {id = 103, role = "cmd.flip"}, text = "Flip", enabled = true},
	}
	state.menus = {
		{text = "File", items = state.file_it[:]},
		{text = "View", items = state.view_it[:]},
	}
	state.a_ctx_it = {
		{info = {id = 200, role = "slide.a.lock"}, text = "Lock A", enabled = false},
		{info = {id = 201, role = "slide.a.mark"}, text = "Mark A", enabled = true},
	}
	state.b_ctx_it = {
		{info = {id = 202, role = "slide.b.lock"}, text = "Lock B", enabled = false},
		{info = {id = 203, role = "slide.b.mark"}, text = "Mark B", enabled = true},
	}
	state.contexts = {
		{target_id = 10, items = state.a_ctx_it[:]},
		{target_id = 11, items = state.b_ctx_it[:]},
	}

	h.app = App{
		title                 = "Menu Test",
		width                 = i32(viewport.width),
		height                = i32(viewport.height),
		user_data             = state,
		canvas                = menu_test_canvas,
		text_edit             = {enabled = true},
		editable_text_targets = state.editable[:],
		menus                 = state.menus[:],
		context_menus         = state.contexts[:],
	}
	h.viewport = viewport
	h.renderer = renderer
	h.menu.highlighted = -1
	if !testing.expect(t, font_init(&h.font)) {
		return {}, false
	}
	if !testing.expect(t, host_rebuild_frame(&h)) {
		font_destroy(&h.font)
		return {}, false
	}
	return h, true
}

@(private = "file")
read_px :: proc(surface: ^sdl.Surface, x, y: i32) -> [4]u8 {
	r, g, b, a: u8
	_ = sdl.ReadSurfacePixel(surface, x, y, &r, &g, &b, &a)
	return {r, g, b, a}
}

@(private = "file")
max_luminance_in_rect :: proc(surface: ^sdl.Surface, x0, y0, x1, y1: i32) -> int {
	best := 0
	for y in y0 ..< y1 {
		for x in x0 ..< x1 {
			p := read_px(surface, x, y)
			lum := int(p[0]) + int(p[1]) + int(p[2])
			if lum > best {
				best = lum
			}
		}
	}
	return best
}

@(private = "file")
has_caret_pixel_in_band :: proc(surface: ^sdl.Surface, x_center, y0, y1: i32) -> bool {
	for y in y0 ..< y1 {
		for x in x_center - 2 ..= x_center + 2 {
			p := read_px(surface, x, y)
			// Caret color in text_edit.odin is sdl.Color{255, 214, 102, 255}.
			if p[0] >= 245 && p[1] >= 200 && p[2] <= 115 {
				return true
			}
		}
	}
	return false
}

@(test)
test_menu_rendering_two_scales :: proc(t: ^testing.T) {
	sync.mutex_lock(&sdl_test_mu)
	defer sync.mutex_unlock(&sdl_test_mu)

	viewport := dagda.Size{width = 480, height = 300}
	scales := [?]i32{1, 2}

	for scale in scales {
		out_w := i32(viewport.width) * scale
		out_h := i32(viewport.height) * scale
		surface := sdl.CreateSurface(out_w, out_h, .RGBA8888)
		if !testing.expect(t, surface != nil) { return }
		defer sdl.DestroySurface(surface)
		renderer := sdl.CreateSoftwareRenderer(surface)
		if !testing.expect(t, renderer != nil) { return }
		defer sdl.DestroyRenderer(renderer)

		state: Menu_Test_App
		h, ok := menu_test_setup_host(t, &state, viewport, surface, renderer)
		if !ok { return }
		defer {
			font_destroy_textures(&h.font)
			font_destroy(&h.font)
			text_edit_destroy(&h.text_edit)
			dagda.frame_destroy(&h.driver_frame)
			dagda.frame_destroy(&h.frame)
		}

		// Focus A (id=10) with caret at ab|cd (byte offset 2).
		testing.expect(t, text_edit_focus_id(&h.text_edit, nil, &h.font, h.frame, h.app.text_edit, 10, h.app.editable_text_targets))
		h.text_edit.session.anchor = 2
		h.text_edit.session.caret = 2

		a_el, a_found := dagda.find(h.frame, 10)
		b_el, b_found := dagda.find(h.frame, 11)
		if !testing.expect(t, a_found && b_found) { return }

		caret_x, caret_y, caret_px := text_edit_caret_pos(&h.text_edit, &h.font, h.frame, a_el.bounds, state.a_text, false)
		caret_px_x := i32(math.round(caret_x * f32(scale)))
		caret_y0 := i32(math.floor(caret_y * f32(scale)))
		caret_y1 := i32(math.ceil((caret_y + caret_px) * f32(scale)))

		b_y0 := i32(math.floor(b_el.bounds.y * f32(scale)))
		b_y1 := i32(math.ceil((b_el.bounds.y + b_el.bounds.height) * f32(scale)))

		// 1. Baseline draw: caret is visible on A at ab|cd and absent on B.
		host_draw(&h)
		testing.expect(t, sdl.FlushRenderer(renderer))
		testing.expect(t, has_caret_pixel_in_band(surface, caret_px_x, caret_y0, caret_y1), "A caret must be painted before menu opens")

		// 2. Open menu bar "File" with item 0 ("Stamp") highlighted.
		//    File dropdown sits at y=32..130, overlapping canvas element A's left edge.
		menu_open_bar(&h, 0, true)
		testing.expect_value(t, h.menu.highlighted, 0)
		host_draw(&h)
		testing.expect(t, sdl.FlushRenderer(renderer))

		popup := menu_popup_rect(&h)
		r0 := menu_popup_item_rect(&h, popup, 0) // Stamp (enabled, highlighted)
		r1 := menu_popup_item_rect(&h, popup, 1) // Locked (disabled)
		r2 := menu_popup_item_rect(&h, popup, 2) // Mark (enabled, unhighlighted)

		// Highlighted row background matches MENU_ITEM_HIGHLIGHT_BG; unhighlighted row matches MENU_POPUP_BG.
		hi_bg := read_px(surface, i32((r0.x + r0.width - 6) * f32(scale)), i32((r0.y + r0.height * 0.5) * f32(scale)))
		norm_bg := read_px(surface, i32((r2.x + r2.width - 6) * f32(scale)), i32((r2.y + r2.height * 0.5) * f32(scale)))
		testing.expect_value(t, hi_bg, [4]u8{MENU_ITEM_HIGHLIGHT_BG.r, MENU_ITEM_HIGHLIGHT_BG.g, MENU_ITEM_HIGHLIGHT_BG.b, 255})
		testing.expect_value(t, norm_bg, [4]u8{MENU_POPUP_BG.r, MENU_POPUP_BG.g, MENU_POPUP_BG.b, 255})

		// Disabled item ("Locked") text is visibly dimmer than enabled item ("Mark") text.
		dis_lum := max_luminance_in_rect(
			surface,
			i32((r1.x + 8) * f32(scale)),
			i32((r1.y + 4) * f32(scale)),
			i32((r1.x + 90) * f32(scale)),
			i32((r1.y + r1.height - 4) * f32(scale)),
		)
		en_lum := max_luminance_in_rect(
			surface,
			i32((r2.x + 8) * f32(scale)),
			i32((r2.y + 4) * f32(scale)),
			i32((r2.x + 90) * f32(scale)),
			i32((r2.y + r2.height - 4) * f32(scale)),
		)
		testing.expect(t, dis_lum > int(MENU_POPUP_BG.r) + int(MENU_POPUP_BG.g) + int(MENU_POPUP_BG.b) + 30, "disabled item text must be visible")
		testing.expect(t, en_lum > dis_lum + 80, "enabled item text must be visibly brighter than disabled item text")

		// 3. Open context menu on B anchored near bottom-right corner (460, 280):
		//    must clamp/clip inside the window, paint over the canvas, and preserve A's caret
		//    while never placing a caret on B.
		menu_open_context(&h, 1, {x = 460, y = 280}, false)
		ctx_popup := menu_popup_rect(&h)
		testing.expect(t, ctx_popup.x >= 0 && ctx_popup.y >= 0)
		testing.expect(t, ctx_popup.x + ctx_popup.width <= viewport.width)
		testing.expect(t, ctx_popup.y + ctx_popup.height <= viewport.height)

		host_draw(&h)
		testing.expect(t, sdl.FlushRenderer(renderer))
		// Popup interior paints MENU_POPUP_BG over the canvas.
		ctx_bg := read_px(surface, i32((ctx_popup.x + ctx_popup.width - 6) * f32(scale)), i32((ctx_popup.y + ctx_popup.height - 6) * f32(scale)))
		testing.expect_value(t, ctx_bg, [4]u8{MENU_POPUP_BG.r, MENU_POPUP_BG.g, MENU_POPUP_BG.b, 255})
		// A's caret is still at ab|cd (not lost or moved to B).
		testing.expect(t, has_caret_pixel_in_band(surface, caret_px_x, caret_y0, caret_y1), "A caret must remain at ab|cd while B context menu is open")
		testing.expect(t, !has_caret_pixel_in_band(surface, caret_px_x, b_y0, b_y1), "B must not acquire a caret while its context menu is open")

		// 4. Dismiss popup with Escape and verify A's caret stays at the exact same column.
		esc: sdl.Event
		esc.type = .KEY_DOWN
		esc.key.key = sdl.K_ESCAPE
		esc.key.down = true
		_, _, _ = host_dispatch_key_event(&h, &esc)
		testing.expect(t, !menu_is_open(&h.menu))
		host_draw(&h)
		testing.expect(t, sdl.FlushRenderer(renderer))
		testing.expect(t, has_caret_pixel_in_band(surface, caret_px_x, caret_y0, caret_y1), "A caret must stay at ab|cd after menu dismissal")
	}
}

@(test)
test_menu_one_popup_ime_precedence_and_driver_discovery :: proc(t: ^testing.T) {
	sync.mutex_lock(&sdl_test_mu)
	defer sync.mutex_unlock(&sdl_test_mu)

	viewport := dagda.Size{width = 480, height = 300}
	surface := sdl.CreateSurface(480, 300, .RGBA8888)
	if !testing.expect(t, surface != nil) { return }
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	if !testing.expect(t, renderer != nil) { return }
	defer sdl.DestroyRenderer(renderer)

	state: Menu_Test_App
	h, ok := menu_test_setup_host(t, &state, viewport, surface, renderer)
	if !ok { return }
	defer {
		font_destroy_textures(&h.font)
		font_destroy(&h.font)
		text_edit_destroy(&h.text_edit)
		dagda.frame_destroy(&h.driver_frame)
		dagda.frame_destroy(&h.frame)
	}

	// Closed menu items are discoverable in host_driver_frame (with zero bounds),
	// and absent from h.frame (so they are never Tab stops).
	_, in_canvas := dagda.find(h.frame, 100)
	testing.expect(t, !in_canvas, "menu items must not be canvas/Tab elements")
	df := host_driver_frame(&h)
	stamp_el, stamp_ok := dagda.find(df^, 100)
	locked_el, locked_ok := dagda.find(df^, 101)
	testing.expect(t, stamp_ok && locked_ok)
	testing.expect_value(t, stamp_el.actions, dagda.Action_Set{.Activate})
	testing.expect_value(t, locked_el.actions, dagda.Action_Set{})
	testing.expect_value(t, stamp_el.bounds.width, f32(0))

	// One popup per window: opening File then context B replaces the open popup.
	menu_open_bar(&h, 0, true)
	testing.expect_value(t, h.menu.kind, Menu_Popup_Kind.Menu_Bar)
	menu_open_context(&h, 1, {x = 120, y = 180}, false)
	testing.expect_value(t, h.menu.kind, Menu_Popup_Kind.Context)
	testing.expect_value(t, h.menu.context_id, dagda.Object_Id(11))
	_ = menu_close(&h)

	// During live IME composition, F10, Alt+V, and Shift+F10 must NOT open menus.
	testing.expect(t, text_edit_focus_id(&h.text_edit, nil, &h.font, h.frame, h.app.text_edit, 10, h.app.editable_text_targets))
	h.text_edit.session.composing = true
	for shortcut in ([?]struct{ key: sdl.Keycode, mod: sdl.Keymod }{
		{sdl.K_F10, {}},
		{sdl.K_F10, sdl.KMOD_LSHIFT},
		{sdl.K_V, sdl.KMOD_LALT},
	}) {
		ev: sdl.Event
		ev.type = .KEY_DOWN
		ev.key.key = shortcut.key
		ev.key.mod = shortcut.mod
		ev.key.down = true
		consumed, _ := menu_handle_key_event(&h, &ev)
		testing.expect(t, !consumed, "menu shortcut must yield to active IME composition")
		testing.expect(t, !menu_is_open(&h.menu))
	}
	h.text_edit.session.composing = false

	// Shift+F10 targets focused row A even when mouse pointer is hovered over row B.
	b_el, _ := dagda.find(h.frame, 11)
	move_ev: sdl.Event
	move_ev.type = .MOUSE_MOTION
	move_ev.motion.x = b_el.bounds.x + 20
	move_ev.motion.y = b_el.bounds.y + 20
	_ = host_dispatch_mouse_event(&h, &move_ev)

	sf10: sdl.Event
	sf10.type = .KEY_DOWN
	sf10.key.key = sdl.K_F10
	sf10.key.mod = sdl.KMOD_LSHIFT
	sf10.key.down = true
	_, _, _ = host_dispatch_key_event(&h, &sf10)
	testing.expect_value(t, h.menu.kind, Menu_Popup_Kind.Context)
	testing.expect_value(t, h.menu.context_id, dagda.Object_Id(10))
}
