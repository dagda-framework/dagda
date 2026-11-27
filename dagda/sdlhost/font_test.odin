package sdlhost

import "core:bytes"
import "core:c"
import "core:math"
import "core:mem"
import "core:os"
import "core:sync"
import "core:testing"
import "dagda:dagda"
import sdl "vendor:sdl3"

@(test)
test_font_hit_test_caret :: proc(t: ^testing.T) {
	sync.mutex_lock(&sdl_test_mu)
	defer sync.mutex_unlock(&sdl_test_mu)
	surface := sdl.CreateSurface(256, 96, .RGBA8888)
	if !testing.expect(t, surface != nil) { return }
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	if !testing.expect(t, renderer != nil) { return }
	defer sdl.DestroyRenderer(renderer)
	font: Font
	if !testing.expect(t, font_init(&font)) { return }
	defer font_destroy(&font)

	line := "Wie\u0301!"
	stops := [?]int{0, 1, 2, 5, len(line)}
	origin :: f32(17)
	sizes := [?]f32{13, 31}
	for px in sizes {
		// Use the pen positions from the drawing path as an independent
		// reference for the hit test, including both sides of the accent.
		left: f32 = 0
		for end, i in stops[1:] {
			sdl.SetRenderDrawColor(renderer, 0, 0, 0, 255)
			sdl.RenderClear(renderer)
			start := stops[i]
			right := font_draw_text(&font, renderer, line[:end], origin, 4, px, {255, 255, 255, 255})
			mid := origin + (left + right) * 0.5
			testing.expect(t, right > left)
			testing.expect_value(t, font_hit_test_caret(&font, line, px, mid - 0.25 - origin), start)
			testing.expect_value(t, font_hit_test_caret(&font, line, px, mid - origin), end)
			hit := font_hit_test_caret(&font, line, px, mid + 0.25 - origin)
			testing.expect_value(t, hit, end)

			// Paint the caret from the returned byte offset. Check its pixel
			// at the actual prefix pen position, below all painted glyphs.
			caret_x := origin + font_measure_width(&font, line[:hit], px)
			sdl.SetRenderDrawColor(renderer, 0, 255, 0, 255)
			rect := sdl.FRect{x = caret_x, y = 75, w = 1, h = 5}
			testing.expect(t, sdl.RenderFillRect(renderer, &rect))
			testing.expect(t, sdl.FlushRenderer(renderer))
			r, g, b, a: u8
			testing.expect(t, sdl.ReadSurfacePixel(surface, i32(origin + right), 77, &r, &g, &b, &a))
			testing.expect_value(t, [4]u8{r, g, b, a}, [4]u8{0, 255, 0, 255})
			left = right
		}
		testing.expect_value(t, font_hit_test_caret(&font, line, px, -2), 0)
		testing.expect_value(t, font_hit_test_caret(&font, line, px, left + 2), len(line))
		testing.expect_value(t, font_hit_test_caret(&font, "", px, 10), 0)
	}
}

@(private = "file")
TEST_HANGUL_RUNES :: [?]rune{'ㅎ', '하', '한', '글'}

@(private = "file")
face_covers_all :: proc(font: ^Font, runes: []rune) -> bool {
	for ch in runes {
		if FT_Get_Char_Index(font.face, c.ulong(ch)) == 0 {
			return false
		}
	}
	return true
}

@(private = "file")
face_lacks_all :: proc(font: ^Font, runes: []rune) -> bool {
	for ch in runes {
		if FT_Get_Char_Index(font.face, c.ulong(ch)) != 0 {
			return false
		}
	}
	return true
}

@(private = "file")
find_primary_and_hangul_pair :: proc() -> (primary_path: string, secondary_path: string, ok: bool) {
	runes := TEST_HANGUL_RUNES
	for path in DEFAULT_FONT_PATHS {
		f: Font
		if font_init_with_paths(&f, path) {
			if FT_Get_Char_Index(f.face, c.ulong('A')) != 0 && face_lacks_all(&f, runes[:]) {
				primary_path = path
				font_destroy(&f)
				break
			}
			font_destroy(&f)
		}
	}
	if len(primary_path) == 0 {
		return "", "", false
	}
	for path in DEFAULT_FALLBACK_FONT_PATHS {
		if path == primary_path {
			continue
		}
		f: Font
		if font_init_with_paths(&f, path) {
			if face_covers_all(&f, runes[:]) {
				secondary_path = path
				font_destroy(&f)
				return primary_path, secondary_path, true
			}
			font_destroy(&f)
		}
	}
	return "", "", false
}

@(private = "file")
snapshot_surface_region :: proc(surface: ^sdl.Surface, x0, y0, w, h: i32, allocator := context.temp_allocator) -> []u8 {
	out := make([]u8, int(w * h) * 4, allocator)
	idx := 0
	for y in y0 ..< y0 + h {
		for x in x0 ..< x0 + w {
			r, g, b, a: u8
			_ = sdl.ReadSurfacePixel(surface, x, y, &r, &g, &b, &a)
			out[idx + 0] = r
			out[idx + 1] = g
			out[idx + 2] = b
			out[idx + 3] = a
			idx += 4
		}
	}
	return out
}

@(private = "file")
glyph_equal :: proc(a, b: ^Cached_Glyph) -> bool {
	return a.width == b.width &&
		a.height == b.height &&
		a.bearing_x == b.bearing_x &&
		a.bearing_y == b.bearing_y &&
		a.advance_x == b.advance_x &&
		bytes.equal(a.alpha, b.alpha)
}

@(test)
test_font_fallback_hangul_glyphs_and_metrics :: proc(t: ^testing.T) {
	sync.mutex_lock(&sdl_test_mu)
	defer sync.mutex_unlock(&sdl_test_mu)

	primary_path, secondary_path, found := find_primary_and_hangul_pair()
	if !testing.expect(t, found, "expected a Latin-only primary font and a Hangul-capable secondary font") {
		return
	}

	primary_only, secondary_only, combined: Font
	if !testing.expect(t, font_init_with_paths(&primary_only, primary_path)) { return }
	defer font_destroy(&primary_only)
	if !testing.expect(t, font_init_with_paths(&secondary_only, secondary_path)) { return }
	defer font_destroy(&secondary_only)
	fb_paths := [1]string{secondary_path}
	if !testing.expect(t, font_init_with_paths(&combined, primary_path, fb_paths[:])) { return }
	defer font_destroy(&combined)

	px :: f32(22)

	// Primary face stays authoritative for characters it covers.
	for ch in ([?]rune{'A', 'a', 'l', '!'}) {
		gp := font_get_glyph(&primary_only, ch, px)
		gc := font_get_glyph(&combined, ch, px)
		testing.expect(t, glyph_equal(gp, gc), "primary-covered Latin glyph must come from primary face")
	}

	// Secondary face supplies missing Hangul glyphs with matching bitmaps and advances,
	// and each Hangul glyph is distinguishable from the others and from primary's .notdef box.
	hangul := TEST_HANGUL_RUNES
	notdef := font_get_glyph(&primary_only, 'ㅎ', px)
	for ch, i in hangul {
		gs := font_get_glyph(&secondary_only, ch, px)
		gc := font_get_glyph(&combined, ch, px)
		testing.expect(t, gc.width > 0 && gc.height > 0 && len(gc.alpha) > 0)
		testing.expect(t, glyph_equal(gs, gc), "fallback Hangul glyph must match secondary reference")
		testing.expect(t, !glyph_equal(notdef, gc), "fallback Hangul glyph must not be primary missing-glyph box")
		for j in i + 1 ..< len(hangul) {
			other := font_get_glyph(&combined, hangul[j], px)
			testing.expect(t, !glyph_equal(gc, other), "distinct Hangul glyphs must produce distinct bitmaps")
		}
	}

	// Custom DAGDA_FONT choice still selects the requested primary face without duplicating it as fallback.
	prev_env, had_prev := os.lookup_env("DAGDA_FONT", context.allocator)
	defer {
		if had_prev {
			_ = os.set_env("DAGDA_FONT", prev_env)
			delete(prev_env)
		} else {
			_ = os.unset_env("DAGDA_FONT")
		}
	}
	testing.expect(t, os.set_env("DAGDA_FONT", secondary_path) == nil)
	custom: Font
	if !testing.expect(t, font_init(&custom)) { return }
	defer font_destroy(&custom)
	testing.expect_value(t, custom.font_path, secondary_path)
	for fb in custom.fallbacks {
		testing.expect(t, fb.path != secondary_path, "custom primary font must not be duplicated as fallback")
	}
}

@(test)
test_font_fallback_preedit_and_committed_pixels :: proc(t: ^testing.T) {
	sync.mutex_lock(&sdl_test_mu)
	defer sync.mutex_unlock(&sdl_test_mu)

	primary_path, secondary_path, found := find_primary_and_hangul_pair()
	if !testing.expect(t, found, "expected a Latin-only primary font and a Hangul-capable secondary font") {
		return
	}

	primary_only, secondary_only, combined: Font
	if !testing.expect(t, font_init_with_paths(&primary_only, primary_path)) { return }
	defer font_destroy(&primary_only)
	if !testing.expect(t, font_init_with_paths(&secondary_only, secondary_path)) { return }
	defer font_destroy(&secondary_only)
	fb_paths := [1]string{secondary_path}
	if !testing.expect(t, font_init_with_paths(&combined, primary_path, fb_paths[:])) { return }
	defer font_destroy(&combined)

	surface := sdl.CreateSurface(400, 120, .RGBA8888)
	if !testing.expect(t, surface != nil) { return }
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	if !testing.expect(t, renderer != nil) { return }
	defer sdl.DestroyRenderer(renderer)

	px :: f32(22)
	text_x :: f32(20)
	text_y :: f32(30)
	prefix := "Alpha "
	prefix_w := font_measure_width(&combined, prefix, px)
	// Align secondary-only reference to combined's primary baseline so rendered
	// Hangul pixels can be compared directly byte-for-byte.
	ref_y := text_y + (font_ascender(&combined, px) - font_ascender(&secondary_only, px))

	render_region :: proc(
		renderer: ^sdl.Renderer,
		surface: ^sdl.Surface,
		font: ^Font,
		text: string,
		x, y, px: f32,
		color: sdl.Color,
		rx, ry, rw, rh: i32,
	) -> []u8 {
		sdl.SetRenderDrawColor(renderer, 18, 22, 30, 255)
		sdl.RenderClear(renderer)
		_ = font_draw_text(font, renderer, text, x, y, px, color)
		_ = sdl.FlushRenderer(renderer)
		return snapshot_surface_region(surface, rx, ry, rw, rh)
	}

	// 1. Preedit: "Alpha " + preedit "하" vs "한" (drawn in preedit color).
	preedit_color :: sdl.Color{255, 244, 196, 255}
	pre_x := text_x + prefix_w
	rx := i32(math.floor(pre_x)) - 2
	ry := i32(text_y) - 4
	rw := i32(math.ceil(font_measure_width(&combined, "한글", px))) + 8
	rh := i32(44)

	comb_pre_ha := render_region(renderer, surface, &combined, "하", pre_x, text_y, px, preedit_color, rx, ry, rw, rh)
	ref_pre_ha := render_region(renderer, surface, &secondary_only, "하", pre_x, ref_y, px, preedit_color, rx, ry, rw, rh)
	prim_pre_ha := render_region(renderer, surface, &primary_only, "하", pre_x, text_y, px, preedit_color, rx, ry, rw, rh)
	comb_pre_han := render_region(renderer, surface, &combined, "한", pre_x, text_y, px, preedit_color, rx, ry, rw, rh)
	ref_pre_han := render_region(renderer, surface, &secondary_only, "한", pre_x, ref_y, px, preedit_color, rx, ry, rw, rh)

	testing.expect(t, bytes.equal(comb_pre_ha, ref_pre_ha), "preedit '하' must match secondary-face reference pixels")
	testing.expect(t, !bytes.equal(comb_pre_ha, prim_pre_ha), "preedit '하' must differ from primary missing-glyph box")
	testing.expect(t, bytes.equal(comb_pre_han, ref_pre_han), "preedit '한' must match secondary-face reference pixels")
	testing.expect(t, !bytes.equal(comb_pre_ha, comb_pre_han), "preedit '하' and '한' must paint distinguishable pixels")

	// 2. Committed mixed Latin/Hangul: "Alpha 한글".
	commit_color :: sdl.Color{240, 244, 250, 255}
	sdl.SetRenderDrawColor(renderer, 18, 22, 30, 255)
	sdl.RenderClear(renderer)
	_ = font_draw_text(&combined, renderer, "Alpha 한글", text_x, text_y, px, commit_color)
	_ = sdl.FlushRenderer(renderer)
	comb_latin := snapshot_surface_region(surface, i32(text_x) - 2, ry, i32(math.floor(prefix_w)) - 2, rh)
	comb_hangul := snapshot_surface_region(surface, rx, ry, rw, rh)

	prim_latin := render_region(renderer, surface, &primary_only, prefix, text_x, text_y, px, commit_color, i32(text_x) - 2, ry, i32(math.floor(prefix_w)) - 2, rh)
	ref_hangul := render_region(renderer, surface, &secondary_only, "한글", pre_x, ref_y, px, commit_color, rx, ry, rw, rh)
	prim_hangul := render_region(renderer, surface, &primary_only, "한글", pre_x, text_y, px, commit_color, rx, ry, rw, rh)

	testing.expect(t, bytes.equal(comb_latin, prim_latin), "Latin prefix in mixed string must match primary face pixels")
	testing.expect(t, bytes.equal(comb_hangul, ref_hangul), "committed '한글' must match secondary-face reference pixels")
	testing.expect(t, !bytes.equal(comb_hangul, prim_hangul), "committed '한글' must differ from primary missing-glyph boxes")

	font_destroy_textures(&combined)
	font_destroy_textures(&primary_only)
	font_destroy_textures(&secondary_only)
}

@(test)
test_font_fallback_mixed_caret_and_ime_anchor :: proc(t: ^testing.T) {
	sync.mutex_lock(&sdl_test_mu)
	defer sync.mutex_unlock(&sdl_test_mu)

	primary_path, secondary_path, found := find_primary_and_hangul_pair()
	if !testing.expect(t, found, "expected a Latin-only primary font and a Hangul-capable secondary font") {
		return
	}

	combined: Font
	fb_paths := [1]string{secondary_path}
	if !testing.expect(t, font_init_with_paths(&combined, primary_path, fb_paths[:])) { return }
	defer font_destroy(&combined)

	surface := sdl.CreateSurface(400, 120, .RGBA8888)
	if !testing.expect(t, surface != nil) { return }
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	if !testing.expect(t, renderer != nil) { return }
	defer sdl.DestroyRenderer(renderer)

	// Mixed Latin + Hangul + decomposed combining grapheme + Hangul + ASCII.
	line := "Alpha 한e\u0301글!"
	// Byte offsets: "A"(1) "l"(2) "p"(3) "h"(4) "a"(5) " "(6) "한"(9) "e\u0301"(12) "글"(15) "!"(16)
	stops := [?]int{0, 1, 2, 3, 4, 5, 6, 9, 12, 15, len(line)}
	origin :: f32(16)
	px :: f32(20)

	left: f32 = 0
	for end, i in stops[1:] {
		sdl.SetRenderDrawColor(renderer, 0, 0, 0, 255)
		sdl.RenderClear(renderer)
		start := stops[i]
		right := font_draw_text(&combined, renderer, line[:end], origin, 8, px, {255, 255, 255, 255})
		measured := font_measure_width(&combined, line[:end], px)
		testing.expect(t, math.abs(right - measured) < 0.001, "draw advance and measured width must agree")
		testing.expect(t, right > left)

		mid := (left + right) * 0.5
		testing.expect_value(t, font_hit_test_caret(&combined, line, px, mid - 0.25), start)
		testing.expect_value(t, font_hit_test_caret(&combined, line, px, mid), end)
		testing.expect_value(t, font_hit_test_caret(&combined, line, px, mid + 0.25), end)
		left = right
	}

	// Verify text_edit_caret_pos (which feeds both caret paint and SDL_SetTextInputArea IME anchor)
	// uses the resolved fallback advance for both live preedit and committed Hangul.
	bounds := dagda.Rect{x = 40, y = 60, width = 420, height = 72}
	frame := dagda.Frame{}
	tx, _, layout_px := text_edit_layout(frame, bounds)

	te: Text_Edit_State
	te.focused = true
	te.active_id = 1
	te.session.anchor = 6
	te.session.caret = 11
	te.session.composing = true
	te.session.preedit = "한"
	te.session.preedit_start = 1
	te.session.preedit_length = 0

	pre_cx, _, pre_px := text_edit_caret_pos(&te, &combined, frame, bounds, "Alpha Title", false)
	want_pre_cx := tx + font_measure_width(&combined, "Alpha ", layout_px) + font_measure_width(&combined, "한", layout_px)
	testing.expect(t, math.abs(pre_cx - want_pre_cx) < 0.001, "preedit IME anchor X must use resolved Hangul advance")
	testing.expect_value(t, pre_px, layout_px)

	te.session.composing = false
	te.session.preedit = ""
	te.session.anchor = len("Alpha 한글")
	te.session.caret = len("Alpha 한글")
	com_cx, _, _ := text_edit_caret_pos(&te, &combined, frame, bounds, "Alpha 한글", false)
	want_com_cx := tx + font_measure_width(&combined, "Alpha 한글", layout_px)
	testing.expect(t, math.abs(com_cx - want_com_cx) < 0.001, "committed caret/IME anchor X must use resolved Hangul advance")

	font_destroy_textures(&combined)
}

@(test)
test_font_add_fallback_face_alloc_failure :: proc(t: ^testing.T) {
	sync.mutex_lock(&sdl_test_mu)
	defer sync.mutex_unlock(&sdl_test_mu)

	primary_path, secondary_path, found := find_primary_and_hangul_pair()
	if !testing.expect(t, found, "expected a Latin-only primary font and a Hangul-capable secondary font") {
		return
	}

	font, ref_primary: Font
	if !testing.expect(t, font_init_with_paths(&font, primary_path)) { return }
	defer font_destroy(&font)
	if !testing.expect(t, font_init_with_paths(&ref_primary, primary_path)) { return }
	defer font_destroy(&ref_primary)

	// 1. Failing fallbacks array growth must return false, leave zero fallbacks,
	//    and release both the cloned path and FreeType face without leaking.
	orig_fb_alloc := font.fallbacks.allocator
	font.fallbacks.allocator = mem.nil_allocator()
	testing.expect(t, !font_add_fallback_face(&font, secondary_path), "fallback addition must fail when array growth fails")
	testing.expect_value(t, len(font.fallbacks), 0)
	font.fallbacks.allocator = orig_fb_alloc

	// 2. Failing path cloning must also return false with zero fallbacks and no leaks.
	{
		context.allocator = mem.nil_allocator()
		testing.expect(t, !font_add_fallback_face(&font, secondary_path), "fallback addition must fail when path cloning fails")
	}
	testing.expect_value(t, len(font.fallbacks), 0)

	// 3. Primary font remains fully functional after failed fallback additions.
	px :: f32(20)
	g_actual := font_get_glyph(&font, 'A', px)
	g_ref := font_get_glyph(&ref_primary, 'A', px)
	testing.expect(t, g_actual.width > 0 && g_actual.height > 0 && len(g_actual.alpha) > 0)
	testing.expect(t, glyph_equal(g_actual, g_ref), "primary font must remain intact after failed fallback addition")
	testing.expect_value(t, font_measure_width(&font, "Alpha", px), font_measure_width(&ref_primary, "Alpha", px))
}
