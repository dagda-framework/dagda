package sdlhost

import "core:sync"
import "core:testing"
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
