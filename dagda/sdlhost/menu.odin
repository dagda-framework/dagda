package sdlhost

import "core:c"
import "core:math"
import "dagda:dagda"
import sdl "vendor:sdl3"

// Menu_Item describes one command inside a menu bar menu or a context menu.
// The app owns the command ID, semantic role, label text, and enabled state.
// Choosing an enabled item locally closes the popup and dispatches .Activate
// through App.handle with current_action_origin() == .Local.
Menu_Item :: struct {
	info:    dagda.Object_Info,
	text:    string,
	enabled: bool,
}

// Menu describes one top-level menu in the window's menu bar.
Menu :: struct {
	text:  string,
	items: []Menu_Item,
}

// Context_Menu binds a slice of commands to a stable element ID (for example,
// a slide row). Secondary-clicking that element or pressing Shift+F10 while
// it has keyboard focus opens this menu without moving keyboard focus or
// ending the live text session.
Context_Menu :: struct {
	target_id: dagda.Object_Id,
	items:     []Menu_Item,
}

Menu_Popup_Kind :: enum {
	None,
	Menu_Bar,
	Context,
}

Menu_State :: struct {
	kind:          Menu_Popup_Kind,
	menu_index:    int,
	context_index: int,
	context_id:    dagda.Object_Id,
	anchor:        dagda.Point,
	highlighted:   int,
	mouse_pos:     dagda.Point,
	has_mouse:     bool,
	// Set when a MOUSE_BUTTON_DOWN was consumed by the menu bar or popup so
	// the matching MOUSE_BUTTON_UP is also swallowed cleanly.
	swallow_up:    bool,
}

MENU_BAR_HEIGHT :: f32(32)
MENU_TITLE_PAD_X :: f32(12)
MENU_TITLE_MIN_W :: f32(56)
MENU_TITLE_GAP :: f32(4)
MENU_TITLE_Y :: f32(2)
MENU_TITLE_H :: f32(28)
MENU_FONT_PX :: f32(15)
MENU_ITEM_HEIGHT :: f32(30)
MENU_POPUP_PAD_Y :: f32(4)
MENU_POPUP_MIN_W :: f32(180)
MENU_ITEM_PAD_X :: f32(16)

menu_is_open :: proc(m: ^Menu_State) -> bool {
	return m.kind != .None
}

menu_close :: proc(h: ^Host) -> bool {
	if h.menu.kind == .None {
		return false
	}
	h.menu.kind = .None
	h.menu.menu_index = 0
	h.menu.context_index = 0
	h.menu.context_id = 0
	h.menu.highlighted = -1
	h.needs_redraw = true
	host_sync_driver_frame(h)
	return true
}

menu_active_items :: proc(h: ^Host) -> []Menu_Item {
	switch h.menu.kind {
	case .None:
		return nil
	case .Menu_Bar:
		if h.menu.menu_index >= 0 && h.menu.menu_index < len(h.app.menus) {
			return h.app.menus[h.menu.menu_index].items
		}
	case .Context:
		if h.menu.context_index >= 0 && h.menu.context_index < len(h.app.context_menus) {
			return h.app.context_menus[h.menu.context_index].items
		}
	}
	return nil
}

menu_first_enabled :: proc(items: []Menu_Item) -> int {
	for item, i in items {
		if item.enabled {
			return i
		}
	}
	return -1
}

menu_last_enabled :: proc(items: []Menu_Item) -> int {
	for i := len(items) - 1; i >= 0; i -= 1 {
		if items[i].enabled {
			return i
		}
	}
	return -1
}

menu_step_enabled :: proc(items: []Menu_Item, current: int, delta: int) -> int {
	n := len(items)
	if n == 0 {
		return -1
	}
	if current < 0 || current >= n {
		return delta >= 0 ? menu_first_enabled(items) : menu_last_enabled(items)
	}
	step := delta >= 0 ? 1 : -1
	for k in 1 ..= n {
		idx := (current + k * step + n * 2) % n
		if items[idx].enabled {
			return idx
		}
	}
	return -1
}

menu_find_context :: proc(contexts: []Context_Menu, id: dagda.Object_Id) -> int {
	for ctx, i in contexts {
		if ctx.target_id == id {
			return i
		}
	}
	return -1
}

ascii_lower :: proc(b: u8) -> u8 {
	if b >= 'A' && b <= 'Z' {
		return b + ('a' - 'A')
	}
	return b
}

menu_find_by_letter :: proc(menus: []Menu, letter: u8) -> int {
	want := ascii_lower(letter)
	for m, i in menus {
		if len(m.text) > 0 && ascii_lower(m.text[0]) == want {
			return i
		}
	}
	return -1
}

menu_bar_title_rect :: proc(h: ^Host, index: int) -> dagda.Rect {
	if index < 0 || index >= len(h.app.menus) {
		return {}
	}
	x: f32 = 8
	for i in 0 ..= index {
		tw := font_measure_width(&h.font, h.app.menus[i].text, MENU_FONT_PX)
		w := max(math.ceil(tw) + MENU_TITLE_PAD_X * 2, MENU_TITLE_MIN_W)
		if i == index {
			return {x = x, y = MENU_TITLE_Y, width = w, height = MENU_TITLE_H}
		}
		x += w + MENU_TITLE_GAP
	}
	return {}
}

menu_popup_rect :: proc(h: ^Host) -> dagda.Rect {
	items := menu_active_items(h)
	if h.menu.kind == .None || len(items) == 0 {
		return {}
	}
	w := MENU_POPUP_MIN_W
	for item in items {
		tw := font_measure_width(&h.font, item.text, MENU_FONT_PX)
		w = max(w, math.ceil(tw) + MENU_ITEM_PAD_X * 2)
	}
	ht := f32(len(items)) * MENU_ITEM_HEIGHT + MENU_POPUP_PAD_Y * 2

	vp_w := h.viewport.width > 0 ? h.viewport.width : 960
	vp_h := h.viewport.height > 0 ? h.viewport.height : 540
	w = min(w, vp_w)
	ht = min(ht, vp_h)

	x, y: f32
	switch h.menu.kind {
	case .None:
		return {}
	case .Menu_Bar:
		tr := menu_bar_title_rect(h, h.menu.menu_index)
		x = tr.x
		y = MENU_BAR_HEIGHT
	case .Context:
		x = h.menu.anchor.x
		y = h.menu.anchor.y
	}

	if x + w > vp_w {
		x = vp_w - w
	}
	if x < 0 {
		x = 0
	}
	if y + ht > vp_h {
		y = vp_h - ht
	}
	if y < 0 {
		y = 0
	}
	return {x = x, y = y, width = w, height = ht}
}

menu_popup_item_rect :: proc(h: ^Host, popup: dagda.Rect, item_index: int) -> dagda.Rect {
	items := menu_active_items(h)
	if item_index < 0 || item_index >= len(items) || popup.width <= 0 || popup.height <= 0 {
		return {}
	}
	return {
		x      = popup.x + 2,
		y      = popup.y + MENU_POPUP_PAD_Y + f32(item_index) * MENU_ITEM_HEIGHT,
		width  = max(popup.width - 4, 0),
		height = MENU_ITEM_HEIGHT,
	}
}

menu_open_bar :: proc(h: ^Host, index: int, highlight_first: bool) {
	if index < 0 || index >= len(h.app.menus) {
		return
	}
	h.menu.kind = .Menu_Bar
	h.menu.menu_index = index
	h.menu.context_index = 0
	h.menu.context_id = 0
	h.menu.highlighted = highlight_first ? menu_first_enabled(h.app.menus[index].items) : -1
	h.needs_redraw = true
	host_sync_driver_frame(h)
}

menu_open_context :: proc(h: ^Host, ctx_index: int, anchor: dagda.Point, highlight_first: bool) {
	if ctx_index < 0 || ctx_index >= len(h.app.context_menus) {
		return
	}
	ctx := h.app.context_menus[ctx_index]
	h.menu.kind = .Context
	h.menu.context_index = ctx_index
	h.menu.context_id = ctx.target_id
	h.menu.anchor = anchor
	h.menu.highlighted = highlight_first ? menu_first_enabled(ctx.items) : -1
	h.needs_redraw = true
	host_sync_driver_frame(h)
}

menu_reconcile :: proc(h: ^Host) {
	switch h.menu.kind {
	case .None:
		return
	case .Menu_Bar:
		if h.menu.menu_index < 0 || h.menu.menu_index >= len(h.app.menus) {
			h.menu.kind = .None
			h.menu.highlighted = -1
			return
		}
		items := h.app.menus[h.menu.menu_index].items
		if h.menu.highlighted >= len(items) || (h.menu.highlighted >= 0 && !items[h.menu.highlighted].enabled) {
			h.menu.highlighted = -1
		}
	case .Context:
		idx := menu_find_context(h.app.context_menus, h.menu.context_id)
		if idx < 0 {
			h.menu.kind = .None
			h.menu.highlighted = -1
			return
		}
		h.menu.context_index = idx
		items := h.app.context_menus[idx].items
		if h.menu.highlighted >= len(items) || (h.menu.highlighted >= 0 && !items[h.menu.highlighted].enabled) {
			h.menu.highlighted = -1
		}
	}
}

menu_activate_local :: proc(h: ^Host, id: dagda.Object_Id) -> bool {
	if h.app.handle == nil {
		return false
	}
	local_action := Action_Dispatch{handler = h.app.handle, user_data = h.app.user_data, origin = .Local}
	return action_dispatch_trampoline(&local_action, id, .Activate)
}

menu_is_composing :: proc(h: ^Host) -> bool {
	return h.text_edit.focused && h.text_edit.session.composing
}

// menu_handle_key_event handles keyboard navigation/dismissal/activation while
// a popup is open, and keyboard opening shortcuts (F10, Alt+<letter>,
// Shift+F10) when no popup is open and the IME is not composing.
menu_handle_key_event :: proc(h: ^Host, ev: ^sdl.Event) -> (consumed: bool, needs_rebuild: bool) {
	if ev.type == .WINDOW_FOCUS_LOST {
		if menu_close(h) {
			h.needs_redraw = true
		}
		return false, false
	}

	if menu_is_open(&h.menu) {
		if ev.type != .KEY_DOWN {
			return true, false
		}
		key := ev.key.key
		items := menu_active_items(h)

		switch key {
		case sdl.K_ESCAPE:
			_ = menu_close(h)
			return true, false

		case sdl.K_DOWN:
			next := menu_step_enabled(items, h.menu.highlighted, +1)
			if next != h.menu.highlighted {
				h.menu.highlighted = next
				h.needs_redraw = true
			}
			return true, false

		case sdl.K_UP:
			next := menu_step_enabled(items, h.menu.highlighted, -1)
			if next != h.menu.highlighted {
				h.menu.highlighted = next
				h.needs_redraw = true
			}
			return true, false

		case sdl.K_RIGHT:
			if h.menu.kind == .Menu_Bar && len(h.app.menus) > 0 {
				next_menu := (h.menu.menu_index + 1) % len(h.app.menus)
				menu_open_bar(h, next_menu, h.menu.highlighted >= 0)
			}
			return true, false

		case sdl.K_LEFT:
			if h.menu.kind == .Menu_Bar && len(h.app.menus) > 0 {
				n := len(h.app.menus)
				next_menu := (h.menu.menu_index - 1 + n) % n
				menu_open_bar(h, next_menu, h.menu.highlighted >= 0)
			}
			return true, false

		case sdl.K_RETURN, sdl.K_KP_ENTER:
			if ev.key.repeat {
				return true, false
			}
			hi := h.menu.highlighted
			if hi >= 0 && hi < len(items) && items[hi].enabled {
				item_id := items[hi].info.id
				_ = menu_close(h)
				if menu_activate_local(h, item_id) {
					return true, true
				}
			}
			return true, false
		}
		// All other keys are swallowed while a popup is open so nothing
		// reaches the underlying text field or buttons.
		return true, false
	}

	// Popup is closed: check keyboard opening shortcuts unless IME is composing.
	if ev.type != .KEY_DOWN || ev.key.repeat || menu_is_composing(h) {
		return false, false
	}

	key := ev.key.key
	mod := ev.key.mod
	has_shift := (mod & sdl.KMOD_SHIFT) != {}
	has_alt := (mod & sdl.KMOD_ALT) != {}
	has_ctrl_gui := (mod & (sdl.KMOD_CTRL | sdl.KMOD_GUI)) != {}

	// Shift+F10 opens the context menu for the keyboard-focused element
	// (never the hovered row).
	if key == sdl.K_F10 && has_shift && !has_alt && !has_ctrl_gui {
		if len(h.app.context_menus) == 0 {
			return false, false
		}
		has_target := false
		target_id: dagda.Object_Id
		if h.text_edit.focused {
			has_target = true
			target_id = h.text_edit.active_id
		} else if h.focus.has_focus {
			has_target = true
			target_id = h.focus.focused_id
		}
		if !has_target {
			return false, false
		}
		ctx_idx := menu_find_context(h.app.context_menus, target_id)
		if ctx_idx < 0 {
			return false, false
		}
		anchor := dagda.Point{x = 16, y = len(h.app.menus) > 0 ? MENU_BAR_HEIGHT + 8 : 16}
		if el, ok := dagda.find(h.frame, target_id); ok {
			anchor = {x = el.bounds.x + 16, y = el.bounds.y + el.bounds.height}
		}
		menu_open_context(h, ctx_idx, anchor, true)
		return true, false
	}

	// Unmodified F10 opens the first menu bar menu with its first enabled item highlighted.
	if key == sdl.K_F10 && !has_shift && !has_alt && !has_ctrl_gui {
		if len(h.app.menus) > 0 {
			menu_open_bar(h, 0, true)
			return true, false
		}
		return false, false
	}

	// Alt+<letter> opens the menu bar menu whose title starts with that letter.
	if has_alt && !has_ctrl_gui && key >= sdl.K_A && key <= sdl.K_Z {
		letter := u8('a') + u8(key - sdl.K_A)
		idx := menu_find_by_letter(h.app.menus, letter)
		if idx >= 0 {
			menu_open_bar(h, idx, true)
			return true, false
		}
	}

	return false, false
}

menu_hit_bar_title :: proc(h: ^Host, p: dagda.Point) -> int {
	for i in 0 ..< len(h.app.menus) {
		if dagda.contains(menu_bar_title_rect(h, i), p) {
			return i
		}
	}
	return -1
}

menu_hit_popup_item :: proc(h: ^Host, p: dagda.Point) -> (in_popup: bool, item_index: int) {
	popup := menu_popup_rect(h)
	if !dagda.contains(popup, p) {
		return false, -1
	}
	items := menu_active_items(h)
	for i in 0 ..< len(items) {
		if dagda.contains(menu_popup_item_rect(h, popup, i), p) {
			return true, i
		}
	}
	return true, -1
}

// menu_handle_mouse_event handles menu bar clicks, popup clicks/hover/dismissal,
// and secondary-click context menu opening. Returns consumed=true when the host
// should not forward the event to text editing, canvas pointer gestures, or
// element activation.
menu_handle_mouse_event :: proc(h: ^Host, ev: ^sdl.Event) -> (consumed: bool, needs_rebuild: bool) {
	#partial switch ev.type {
	case .MOUSE_MOTION:
		p := dagda.Point{x = ev.motion.x, y = ev.motion.y}
		h.menu.mouse_pos = p
		h.menu.has_mouse = true
		if !menu_is_open(&h.menu) {
			return false, false
		}
		in_popup, item_idx := menu_hit_popup_item(h, p)
		if in_popup {
			items := menu_active_items(h)
			next := (item_idx >= 0 && item_idx < len(items) && items[item_idx].enabled) ? item_idx : -1
			if next != h.menu.highlighted {
				h.menu.highlighted = next
				h.needs_redraw = true
			}
		}
		return true, false

	case .MOUSE_BUTTON_DOWN:
		p := dagda.Point{x = ev.button.x, y = ev.button.y}
		h.menu.mouse_pos = p
		h.menu.has_mouse = true

		if ev.button.button == sdl.BUTTON_LEFT {
			if menu_is_open(&h.menu) {
				in_popup, item_idx := menu_hit_popup_item(h, p)
				if in_popup {
					h.menu.swallow_up = true
					items := menu_active_items(h)
					if item_idx >= 0 && item_idx < len(items) && items[item_idx].enabled {
						item_id := items[item_idx].info.id
						_ = menu_close(h)
						if menu_activate_local(h, item_id) {
							return true, true
						}
					}
					return true, false
				}
				if title_idx := menu_hit_bar_title(h, p); title_idx >= 0 {
					h.menu.swallow_up = true
					if h.menu.kind == .Menu_Bar && h.menu.menu_index == title_idx {
						_ = menu_close(h)
					} else {
						menu_open_bar(h, title_idx, false)
					}
					return true, false
				}
				// Click outside closes the popup without disturbing focus/selection.
				h.menu.swallow_up = true
				_ = menu_close(h)
				return true, false
			}

			// No popup open: check menu bar title click.
			if title_idx := menu_hit_bar_title(h, p); title_idx >= 0 {
				h.menu.swallow_up = true
				menu_open_bar(h, title_idx, false)
				return true, false
			}
			return false, false
		}

		if ev.button.button == sdl.BUTTON_RIGHT {
			if h.pointer.active {
				pres := host_handle_pointer_cancel_event(h, ev)
				if pres.changed {
					needs_rebuild = true
				}
			}
			if len(h.app.context_menus) > 0 {
				if id, hit := dagda.hit_test(h.frame, p); hit {
					if ctx_idx := menu_find_context(h.app.context_menus, id); ctx_idx >= 0 {
						h.menu.swallow_up = true
						menu_open_context(h, ctx_idx, p, false)
						return true, needs_rebuild
					}
				}
			}
			if menu_is_open(&h.menu) {
				h.menu.swallow_up = true
				_ = menu_close(h)
				return true, needs_rebuild
			}
			return false, needs_rebuild
		}

	case .MOUSE_BUTTON_UP:
		if h.menu.swallow_up {
			h.menu.swallow_up = false
			return true, false
		}
		if menu_is_open(&h.menu) {
			return true, false
		}
	}

	return false, false
}

// host_driver_frame returns the frame exposed to external driver requests
// (inspect, invoke, hit-test). When no menus are declared it returns &h.frame
// directly; otherwise it returns &h.driver_frame, which appends menu bar titles
// and all menu/context-menu items (with actual bounds when open and zero bounds
// when closed) without turning them into Tab stops or canvas elements.
host_driver_frame :: proc(h: ^Host) -> ^dagda.Frame {
	if len(h.app.menus) == 0 && len(h.app.context_menus) == 0 {
		return &h.frame
	}
	return &h.driver_frame
}

menu_id_used :: proc(elements: []dagda.Resolved_Element, menus: []Menu, contexts: []Context_Menu, id: dagda.Object_Id) -> bool {
	for el in elements {
		if el.info.id == id {
			return true
		}
	}
	for m in menus {
		for item in m.items {
			if item.info.id == id {
				return true
			}
		}
	}
	for ctx in contexts {
		for item in ctx.items {
			if item.info.id == id {
				return true
			}
		}
	}
	return false
}

host_sync_driver_frame :: proc(h: ^Host) {
	dagda.frame_destroy(&h.driver_frame)
	if len(h.app.menus) == 0 && len(h.app.context_menus) == 0 {
		return
	}

	total := len(h.frame.elements) + len(h.app.menus)
	for m in h.app.menus {
		total += len(m.items)
	}
	for ctx in h.app.context_menus {
		total += len(ctx.items)
	}

	elems, err := make([]dagda.Resolved_Element, total)
	if err != nil || len(elems) != total {
		delete(elems)
		return
	}
	n := copy(elems, h.frame.elements)

	// Assign synthetic non-colliding IDs for menu bar titles.
	next_title_id := max(u64) - 1
	for m, i in h.app.menus {
		for menu_id_used(elems[:n], h.app.menus, h.app.context_menus, dagda.Object_Id(next_title_id)) {
			next_title_id -= 1
		}
		tr := menu_bar_title_rect(h, i)
		elems[n] = dagda.Resolved_Element{
			info   = {id = dagda.Object_Id(next_title_id), role = "menu.title"},
			kind   = .Label,
			text   = m.text,
			bounds = tr,
		}
		n += 1
		next_title_id -= 1
	}

	popup := menu_popup_rect(h)
	for m, mi in h.app.menus {
		is_open := h.menu.kind == .Menu_Bar && h.menu.menu_index == mi
		for item, ii in m.items {
			b := is_open ? menu_popup_item_rect(h, popup, ii) : dagda.Rect{}
			elems[n] = dagda.Resolved_Element{
				info    = item.info,
				kind    = item.enabled ? .Button : .Label,
				text    = item.text,
				bounds  = b,
				actions = item.enabled ? {.Activate} : {},
			}
			n += 1
		}
	}

	for ctx, ci in h.app.context_menus {
		is_open := h.menu.kind == .Context && h.menu.context_index == ci
		for item, ii in ctx.items {
			b := is_open ? menu_popup_item_rect(h, popup, ii) : dagda.Rect{}
			elems[n] = dagda.Resolved_Element{
				info    = item.info,
				kind    = item.enabled ? .Button : .Label,
				text    = item.text,
				bounds  = b,
				actions = item.enabled ? {.Activate} : {},
			}
			n += 1
		}
	}

	h.driver_frame = dagda.Frame{
		elements   = elems[:n],
		allocator  = context.allocator,
		transform  = h.frame.transform,
		has_canvas = h.frame.has_canvas,
	}
}

// Distinct colors for menu chrome, highlighted items, and disabled items.
MENU_BAR_BG :: sdl.Color{20, 24, 33, 255}
MENU_BAR_BORDER :: sdl.Color{54, 62, 80, 255}
MENU_TITLE_OPEN_BG :: sdl.Color{56, 108, 196, 255}
MENU_TITLE_TEXT :: sdl.Color{236, 240, 248, 255}
MENU_POPUP_BG :: sdl.Color{30, 35, 46, 255}
MENU_POPUP_BORDER :: sdl.Color{92, 108, 138, 255}
MENU_ITEM_HIGHLIGHT_BG :: sdl.Color{58, 118, 212, 255}
MENU_ITEM_ENABLED_TEXT :: sdl.Color{242, 246, 252, 255}
MENU_ITEM_DISABLED_TEXT :: sdl.Color{120, 128, 146, 255}

menu_window_clip_px :: proc(h: ^Host, scale_x, scale_y: f32) -> sdl.Rect {
	out_w, out_h: c.int
	if h.renderer != nil && sdl.GetCurrentRenderOutputSize(h.renderer, &out_w, &out_h) && out_w > 0 && out_h > 0 {
		return {x = 0, y = 0, w = out_w, h = out_h}
	}
	return {
		x = 0,
		y = 0,
		w = max(c.int(math.round(h.viewport.width * scale_x)), 1),
		h = max(c.int(math.round(h.viewport.height * scale_y)), 1),
	}
}

menu_draw :: proc(h: ^Host, scale_x, scale_y: f32) {
	if len(h.app.menus) == 0 && !menu_is_open(&h.menu) {
		return
	}
	r := h.renderer
	win_clip := menu_window_clip_px(h, scale_x, scale_y)
	sdl.SetRenderClipRect(r, &win_clip)
	defer sdl.SetRenderClipRect(r, nil)

	// 1. Menu bar strip and titles.
	if len(h.app.menus) > 0 {
		bar := scale_frect({x = 0, y = 0, w = h.viewport.width, h = MENU_BAR_HEIGHT}, scale_x, scale_y)
		sdl.SetRenderDrawColor(r, MENU_BAR_BG.r, MENU_BAR_BG.g, MENU_BAR_BG.b, MENU_BAR_BG.a)
		sdl.RenderFillRect(r, &bar)
		border_y := scale_frect({x = 0, y = MENU_BAR_HEIGHT - 1, w = h.viewport.width, h = 1}, scale_x, scale_y)
		sdl.SetRenderDrawColor(r, MENU_BAR_BORDER.r, MENU_BAR_BORDER.g, MENU_BAR_BORDER.b, MENU_BAR_BORDER.a)
		sdl.RenderFillRect(r, &border_y)

		for m, i in h.app.menus {
			tr := menu_bar_title_rect(h, i)
			tr_px := scale_frect({x = tr.x, y = tr.y, w = tr.width, h = tr.height}, scale_x, scale_y)
			if h.menu.kind == .Menu_Bar && h.menu.menu_index == i {
				sdl.SetRenderDrawColor(r, MENU_TITLE_OPEN_BG.r, MENU_TITLE_OPEN_BG.g, MENU_TITLE_OPEN_BG.b, MENU_TITLE_OPEN_BG.a)
				sdl.RenderFillRect(r, &tr_px)
			}
			tx := tr.x + MENU_TITLE_PAD_X
			ty := tr.y + (tr.height - MENU_FONT_PX) * 0.5
			_ = font_draw_text(&h.font, r, m.text, tx, ty, MENU_FONT_PX, MENU_TITLE_TEXT, scale_x, scale_y)
		}
	}

	// 2. Open popup overlay (menu bar dropdown or context menu).
	if !menu_is_open(&h.menu) {
		return
	}
	popup := menu_popup_rect(h)
	items := menu_active_items(h)
	if popup.width <= 0 || popup.height <= 0 || len(items) == 0 {
		return
	}

	popup_px := scale_frect({x = popup.x, y = popup.y, w = popup.width, h = popup.height}, scale_x, scale_y)
	// Clip popup interior to the intersection of popup_px and the window output rect.
	px0 := max(c.int(math.floor(popup_px.x)), win_clip.x)
	py0 := max(c.int(math.floor(popup_px.y)), win_clip.y)
	px1 := min(c.int(math.ceil(popup_px.x + popup_px.w)), win_clip.x + win_clip.w)
	py1 := min(c.int(math.ceil(popup_px.y + popup_px.h)), win_clip.y + win_clip.h)
	popup_clip := sdl.Rect{x = px0, y = py0, w = max(px1 - px0, 0), h = max(py1 - py0, 0)}
	sdl.SetRenderClipRect(r, &popup_clip)

	sdl.SetRenderDrawColor(r, MENU_POPUP_BG.r, MENU_POPUP_BG.g, MENU_POPUP_BG.b, MENU_POPUP_BG.a)
	sdl.RenderFillRect(r, &popup_px)

	for item, i in items {
		ir := menu_popup_item_rect(h, popup, i)
		ir_px := scale_frect({x = ir.x, y = ir.y, w = ir.width, h = ir.height}, scale_x, scale_y)
		if item.enabled && h.menu.highlighted == i {
			sdl.SetRenderDrawColor(r, MENU_ITEM_HIGHLIGHT_BG.r, MENU_ITEM_HIGHLIGHT_BG.g, MENU_ITEM_HIGHLIGHT_BG.b, MENU_ITEM_HIGHLIGHT_BG.a)
			sdl.RenderFillRect(r, &ir_px)
		}
		color := item.enabled ? MENU_ITEM_ENABLED_TEXT : MENU_ITEM_DISABLED_TEXT
		tx := ir.x + MENU_ITEM_PAD_X - 2
		ty := ir.y + (ir.height - MENU_FONT_PX) * 0.5
		_ = font_draw_text(&h.font, r, item.text, tx, ty, MENU_FONT_PX, color, scale_x, scale_y)
	}

	sdl.SetRenderDrawColor(r, MENU_POPUP_BORDER.r, MENU_POPUP_BORDER.g, MENU_POPUP_BORDER.b, MENU_POPUP_BORDER.a)
	sdl.RenderRect(r, &popup_px)
}
