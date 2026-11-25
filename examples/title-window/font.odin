package main

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import sdl "vendor:sdl3"

foreign import freetype "system:freetype"

FT_Error :: c.int
FT_Library :: distinct rawptr
FT_Face :: ^FT_FaceRec

FT_LOAD_RENDER :: 4

FT_Vector :: struct {
	x: c.long,
	y: c.long,
}

FT_Bitmap :: struct {
	rows:         u32,
	width:        u32,
	pitch:        i32,
	_pad0:        u32,
	buffer:       [^]u8,
	num_grays:    u16,
	pixel_mode:   u8,
	palette_mode: u8,
	_pad1:        u32,
	palette:      rawptr,
}

FT_Size_Metrics :: struct {
	_pad:        [24]u8,
	ascender:    c.long,
	descender:   c.long,
	height:      c.long,
	max_advance: c.long,
}

FT_SizeRec :: struct {
	_pad:    [24]u8,
	metrics: FT_Size_Metrics,
	_tail:   [8]u8,
}

FT_GlyphSlotRec :: struct {
	_pad0:       [128]u8,
	advance:     FT_Vector,
	_pad1:       [8]u8,
	bitmap:      FT_Bitmap,
	bitmap_left: c.int,
	bitmap_top:  c.int,
	_tail:       [104]u8,
}

FT_FaceRec :: struct {
	_pad0: [152]u8,
	glyph: ^FT_GlyphSlotRec,
	size:  ^FT_SizeRec,
	_tail: [80]u8,
}

#assert(size_of(FT_Bitmap) == 40)
#assert(offset_of(FT_Bitmap, buffer) == 16)
#assert(offset_of(FT_Bitmap, pixel_mode) == 26)
#assert(size_of(FT_Size_Metrics) == 56)
#assert(offset_of(FT_Size_Metrics, ascender) == 24)
#assert(size_of(FT_SizeRec) == 88)
#assert(offset_of(FT_SizeRec, metrics) == 24)
#assert(size_of(FT_GlyphSlotRec) == 304)
#assert(offset_of(FT_GlyphSlotRec, advance) == 128)
#assert(offset_of(FT_GlyphSlotRec, bitmap) == 152)
#assert(offset_of(FT_GlyphSlotRec, bitmap_left) == 192)
#assert(offset_of(FT_GlyphSlotRec, bitmap_top) == 196)
#assert(size_of(FT_FaceRec) == 248)
#assert(offset_of(FT_FaceRec, glyph) == 152)
#assert(offset_of(FT_FaceRec, size) == 160)

@(default_calling_convention = "c")
foreign freetype {
	FT_Init_FreeType   :: proc(alibrary: ^FT_Library) -> FT_Error ---
	FT_Done_FreeType   :: proc(library: FT_Library) -> FT_Error ---
	FT_New_Face        :: proc(library: FT_Library, filepathname: cstring, face_index: c.long, aface: ^FT_Face) -> FT_Error ---
	FT_Done_Face       :: proc(face: FT_Face) -> FT_Error ---
	FT_Set_Pixel_Sizes :: proc(face: FT_Face, pixel_width: u32, pixel_height: u32) -> FT_Error ---
	FT_Get_Char_Index  :: proc(face: FT_Face, charcode: c.ulong) -> u32 ---
	FT_Load_Glyph      :: proc(face: FT_Face, glyph_index: u32, load_flags: i32) -> FT_Error ---
}

Glyph_Key :: struct {
	codepoint: rune,
	px_height: u32,
}

Cached_Glyph :: struct {
	width:       int,
	height:      int,
	bearing_x:   int,
	bearing_y:   int,
	advance_x:   f32,
	alpha:       []u8,
	texture:     ^sdl.Texture,
	tex_renderer: ^sdl.Renderer,
}

Font :: struct {
	lib:           FT_Library,
	face:          FT_Face,
	loaded:        bool,
	font_path:     string,
	current_px:    u32,
	glyphs:        map[Glyph_Key]Cached_Glyph,
}

DEFAULT_FONT_PATHS :: [?]string{
	"/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
	"/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
	"/usr/share/fonts/liberation-sans/LiberationSans-Regular.ttf",
	"/usr/share/fonts/TTF/DejaVuSans.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
	"/usr/share/fonts/noto/NotoSans-Regular.ttf",
	"/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
}

font_init :: proc(font: ^Font) -> bool {
	if FT_Init_FreeType(&font.lib) != 0 {
		fmt.eprintln("FT_Init_FreeType failed")
		return false
	}

	if custom_path, ok := os.lookup_env("DAGDA_FONT", context.allocator); ok {
		defer delete(custom_path)
		if font_load_face(font, custom_path) {
			return true
		}
		fmt.eprintf("DAGDA_FONT=%q could not be loaded; falling back to system font search\n", custom_path)
	}

	for path in DEFAULT_FONT_PATHS {
		if font_load_face(font, path) {
			return true
		}
	}

	FT_Done_FreeType(font.lib)
	font.lib = nil
	fmt.eprintln("No TrueType font found. Set DAGDA_FONT=/path/to/font.ttf or install ttf-liberation / fonts-liberation / dejavu-sans-fonts.")
	return false
}

font_load_face :: proc(font: ^Font, path: string) -> bool {
	if len(path) == 0 {
		return false
	}
	cpath := strings.clone_to_cstring(path)
	defer delete(cpath)
	if FT_New_Face(font.lib, cpath, 0, &font.face) != 0 {
		return false
	}
	font.loaded = true
	font.font_path = strings.clone(path)
	font.current_px = 0
	return true
}

font_destroy :: proc(font: ^Font) {
	for _, &g in font.glyphs {
		if g.texture != nil {
			sdl.DestroyTexture(g.texture)
			g.texture = nil
		}
		delete(g.alpha)
	}
	delete(font.glyphs)
	delete(font.font_path)
	font.font_path = ""
	if font.face != nil {
		FT_Done_Face(font.face)
		font.face = nil
	}
	if font.lib != nil {
		FT_Done_FreeType(font.lib)
		font.lib = nil
	}
	font.loaded = false
}

font_set_size :: proc(font: ^Font, px_height: u32) {
	if font.current_px != px_height {
		_ = FT_Set_Pixel_Sizes(font.face, 0, px_height)
		font.current_px = px_height
	}
}

font_ascender :: proc(font: ^Font, px_height: f32) -> f32 {
	if !font.loaded {
		return px_height
	}
	px := u32(max(math.round(px_height), 1))
	font_set_size(font, px)
	return f32(font.face.size.metrics.ascender) / 64.0
}

font_get_glyph :: proc(font: ^Font, ch: rune, px_height: f32) -> ^Cached_Glyph {
	px := u32(max(math.round(px_height), 1))
	key := Glyph_Key{codepoint = ch, px_height = px}
	if g, ok := &font.glyphs[key]; ok {
		return g
	}

	font_set_size(font, px)
	glyph_idx := FT_Get_Char_Index(font.face, c.ulong(ch))
	if FT_Load_Glyph(font.face, glyph_idx, FT_LOAD_RENDER) != 0 {
		font.glyphs[key] = Cached_Glyph{advance_x = px_height * 0.5}
		return &font.glyphs[key]
	}

	slot := font.face.glyph
	bmp := slot.bitmap
	w := int(bmp.width)
	h := int(bmp.rows)
	pitch := int(bmp.pitch)

	alpha: []u8
	if w > 0 && h > 0 && bmp.buffer != nil {
		alpha = make([]u8, w * h)
		for row in 0 ..< h {
			src_row := pitch >= 0 ? row * pitch : (h - 1 - row) * (-pitch)
			for col in 0 ..< w {
				alpha[row * w + col] = bmp.buffer[src_row + col]
			}
		}
	}

	font.glyphs[key] = Cached_Glyph{
		width     = w,
		height    = h,
		bearing_x = int(slot.bitmap_left),
		bearing_y = int(slot.bitmap_top),
		advance_x = f32(slot.advance.x) / 64.0,
		alpha     = alpha,
	}
	return &font.glyphs[key]
}

font_measure_width :: proc(font: ^Font, text: string, px_height: f32) -> f32 {
	if !font.loaded || len(text) == 0 {
		return 0
	}
	width: f32 = 0
	for ch in text {
		g := font_get_glyph(font, ch, px_height)
		width += g.advance_x
	}
	return width
}

font_draw_text :: proc(
	font: ^Font,
	renderer: ^sdl.Renderer,
	text: string,
	x, y: f32,
	px_height: f32,
	color: sdl.Color,
) -> f32 {
	if !font.loaded || len(text) == 0 {
		return 0
	}
	baseline := y + font_ascender(font, px_height)
	pen_x := x

	for ch in text {
		g := font_get_glyph(font, ch, px_height)
		if g.width > 0 && g.height > 0 && len(g.alpha) > 0 {
			if g.texture == nil || g.tex_renderer != renderer {
				if g.texture != nil {
					sdl.DestroyTexture(g.texture)
				}
				pixels := make([]u32, g.width * g.height)
				for i in 0 ..< len(g.alpha) {
					a := u32(g.alpha[i])
					pixels[i] = (a << 24) | 0x00FFFFFF
				}
				tex := sdl.CreateTexture(renderer, .ABGR8888, .STATIC, c.int(g.width), c.int(g.height))
				if tex != nil {
					sdl.SetTextureBlendMode(tex, sdl.BLENDMODE_BLEND)
					sdl.UpdateTexture(tex, nil, raw_data(pixels), c.int(g.width * 4))
				}
				delete(pixels)
				g.texture = tex
				g.tex_renderer = renderer
			}
			if g.texture != nil {
				sdl.SetTextureColorMod(g.texture, color.r, color.g, color.b)
				sdl.SetTextureAlphaMod(g.texture, color.a)
				dst := sdl.FRect{
					x = math.floor(pen_x) + f32(g.bearing_x),
					y = math.floor(baseline) - f32(g.bearing_y),
					w = f32(g.width),
					h = f32(g.height),
				}
				sdl.RenderTexture(renderer, g.texture, nil, &dst)
			}
		}
		pen_x += g.advance_x
	}
	return pen_x - x
}

// Rasterized_Line holds an 8-bit alpha coverage image produced by the same
// FreeType glyph pipeline used for window painting, enabling headless glyph
// regressions for non-ASCII strings.
Rasterized_Line :: struct {
	width:  int,
	height: int,
	pixels: []u8,
}

rasterized_line_destroy :: proc(img: ^Rasterized_Line) {
	delete(img.pixels)
	img.pixels = nil
	img.width = 0
	img.height = 0
}

font_rasterize_line :: proc(font: ^Font, text: string, px_height: f32) -> Rasterized_Line {
	if !font.loaded || len(text) == 0 {
		return {}
	}
	w := max(int(math.ceil(font_measure_width(font, text, px_height))) + 8, 1)
	h := max(int(math.ceil(px_height * 1.4)) + 4, 1)
	baseline := int(math.ceil(font_ascender(font, px_height))) + 2
	pixels := make([]u8, w * h)

	pen_x: f32 = 2
	for ch in text {
		g := font_get_glyph(font, ch, px_height)
		gx := int(math.floor(pen_x)) + g.bearing_x
		gy := baseline - g.bearing_y
		for row in 0 ..< g.height {
			dy := gy + row
			if dy < 0 || dy >= h {
				continue
			}
			for col in 0 ..< g.width {
				dx := gx + col
				if dx < 0 || dx >= w {
					continue
				}
				a := g.alpha[row * g.width + col]
				idx := dy * w + dx
				if a > pixels[idx] {
					pixels[idx] = a
				}
			}
		}
		pen_x += g.advance_x
	}
	return Rasterized_Line{width = w, height = h, pixels = pixels}
}
