package main

import "core:strings"
import "core:unicode/utf8"
import sdl "vendor:sdl3"

// Font uses SDL3's built-in RenderDebugText so the Linux window requires only
// libSDL3.so with no extra font libraries or compiled vendor archives.
Font :: struct {}

font_init :: proc(font: ^Font) -> bool {
	return true
}

font_destroy :: proc(font: ^Font) {}

font_scale_for_height :: proc(px_height: f32) -> f32 {
	return max(px_height / f32(sdl.DEBUG_TEXT_FONT_CHARACTER_SIZE), 1.0)
}

font_measure_width :: proc(font: ^Font, text: string, px_height: f32) -> f32 {
	if len(text) == 0 {
		return 0
	}
	scale := font_scale_for_height(px_height)
	return f32(utf8.rune_count_in_string(text)) * f32(sdl.DEBUG_TEXT_FONT_CHARACTER_SIZE) * scale
}

font_draw_text :: proc(
	font: ^Font,
	renderer: ^sdl.Renderer,
	text: string,
	x, y: f32,
	px_height: f32,
	color: sdl.Color,
) -> f32 {
	if len(text) == 0 {
		return 0
	}
	scale := font_scale_for_height(px_height)
	prev_sx, prev_sy: f32
	sdl.GetRenderScale(renderer, &prev_sx, &prev_sy)
	sdl.SetRenderScale(renderer, scale, scale)
	sdl.SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a)
	cstr := strings.clone_to_cstring(text)
	defer delete(cstr)
	sdl.RenderDebugText(renderer, x / scale, y / scale, cstr)
	sdl.SetRenderScale(renderer, prev_sx, prev_sy)
	return font_measure_width(font, text, px_height)
}
