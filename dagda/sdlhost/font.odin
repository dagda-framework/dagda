package sdlhost

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
import sdl "vendor:sdl3"

when ODIN_OS == .Windows {
	foreign import freetype "system:freetype.lib"
} else {
	foreign import freetype "system:freetype"
}

FT_Error :: c.int
FT_Long :: c.long
FT_Pos :: c.long
FT_Fixed :: c.long
FT_Int :: c.int
FT_UInt :: c.uint
FT_Short :: i16
FT_UShort :: u16
FT_Library :: distinct rawptr
FT_Face :: ^FT_FaceRec

FT_LOAD_RENDER :: 4

FT_PIXEL_MODE_NONE  :: u8(0)
FT_PIXEL_MODE_MONO  :: u8(1)
FT_PIXEL_MODE_GRAY  :: u8(2)
FT_PIXEL_MODE_GRAY2 :: u8(3)
FT_PIXEL_MODE_GRAY4 :: u8(4)
FT_PIXEL_MODE_LCD   :: u8(5)
FT_PIXEL_MODE_LCD_V :: u8(6)
FT_PIXEL_MODE_BGRA  :: u8(7)

FT_Vector :: struct {
	x: FT_Pos,
	y: FT_Pos,
}

FT_BBox :: struct {
	xMin: FT_Pos,
	yMin: FT_Pos,
	xMax: FT_Pos,
	yMax: FT_Pos,
}

FT_Generic :: struct {
	data:      rawptr,
	finalizer: rawptr,
}

FT_ListRec :: struct {
	head: rawptr,
	tail: rawptr,
}

FT_Bitmap :: struct {
	rows:         FT_UInt,
	width:        FT_UInt,
	pitch:        FT_Int,
	buffer:       [^]u8,
	num_grays:    u16,
	pixel_mode:   u8,
	palette_mode: u8,
	palette:      rawptr,
}

FT_Outline :: struct {
	n_contours: u16,
	n_points:   u16,
	points:     rawptr,
	tags:       rawptr,
	contours:   rawptr,
	flags:      FT_Int,
}

FT_Glyph_Metrics :: struct {
	width:        FT_Pos,
	height:       FT_Pos,
	horiBearingX: FT_Pos,
	horiBearingY: FT_Pos,
	horiAdvance:  FT_Pos,
	vertBearingX: FT_Pos,
	vertBearingY: FT_Pos,
	vertAdvance:  FT_Pos,
}

FT_Size_Metrics :: struct {
	x_ppem:      FT_UShort,
	y_ppem:      FT_UShort,
	x_scale:     FT_Fixed,
	y_scale:     FT_Fixed,
	ascender:    FT_Pos,
	descender:   FT_Pos,
	height:      FT_Pos,
	max_advance: FT_Pos,
}

FT_SizeRec :: struct {
	face:     FT_Face,
	generic:  FT_Generic,
	metrics:  FT_Size_Metrics,
	internal: rawptr,
}

FT_GlyphSlotRec :: struct {
	library:           FT_Library,
	face:              FT_Face,
	next:              ^FT_GlyphSlotRec,
	glyph_index:       FT_UInt,
	generic:           FT_Generic,
	metrics:           FT_Glyph_Metrics,
	linearHoriAdvance: FT_Fixed,
	linearVertAdvance: FT_Fixed,
	advance:           FT_Vector,
	format:            u32,
	bitmap:            FT_Bitmap,
	bitmap_left:       FT_Int,
	bitmap_top:        FT_Int,
	outline:           FT_Outline,
	num_subglyphs:     FT_UInt,
	subglyphs:         rawptr,
	control_data:      rawptr,
	control_len:       FT_Long,
	lsb_delta:         FT_Pos,
	rsb_delta:         FT_Pos,
	other:             rawptr,
	internal:          rawptr,
}

FT_FaceRec :: struct {
	num_faces:           FT_Long,
	face_index:          FT_Long,
	face_flags:          FT_Long,
	style_flags:         FT_Long,
	num_glyphs:          FT_Long,
	family_name:         cstring,
	style_name:          cstring,
	num_fixed_sizes:     FT_Int,
	available_sizes:     rawptr,
	num_charmaps:        FT_Int,
	charmaps:            rawptr,
	generic:             FT_Generic,
	bbox:                FT_BBox,
	units_per_EM:        FT_UShort,
	ascender:            FT_Short,
	descender:           FT_Short,
	height:              FT_Short,
	max_advance_width:   FT_Short,
	max_advance_height:  FT_Short,
	underline_position:  FT_Short,
	underline_thickness: FT_Short,
	glyph:               ^FT_GlyphSlotRec,
	size:                ^FT_SizeRec,
	charmap:             rawptr,
	driver:              rawptr,
	memory:              rawptr,
	stream:              rawptr,
	sizes_list:          FT_ListRec,
	autohint:            FT_Generic,
	extensions:          rawptr,
	internal:            rawptr,
}

#assert(size_of(FT_Bitmap) == 40)
#assert(offset_of(FT_Bitmap, buffer) == 16)
#assert(offset_of(FT_Bitmap, pixel_mode) == 26)
#assert(offset_of(FT_SizeRec, metrics) == 24)
when ODIN_OS == .Windows {
	// Windows x64 (LLP64): c.long / FT_Long / FT_Pos is 4 bytes.
	#assert(size_of(FT_Size_Metrics) == 28)
	#assert(offset_of(FT_Size_Metrics, ascender) == 12)
	#assert(size_of(FT_SizeRec) == 64)
	#assert(size_of(FT_GlyphSlotRec) == 248)
	#assert(offset_of(FT_GlyphSlotRec, advance) == 88)
	#assert(offset_of(FT_GlyphSlotRec, bitmap) == 104)
	#assert(offset_of(FT_GlyphSlotRec, bitmap_left) == 144)
	#assert(offset_of(FT_GlyphSlotRec, bitmap_top) == 148)
	#assert(size_of(FT_FaceRec) == 216)
	#assert(offset_of(FT_FaceRec, glyph) == 120)
	#assert(offset_of(FT_FaceRec, size) == 128)
} else {
	// Linux / macOS 64-bit (LP64): c.long / FT_Long / FT_Pos is 8 bytes.
	#assert(size_of(FT_Size_Metrics) == 56)
	#assert(offset_of(FT_Size_Metrics, ascender) == 24)
	#assert(size_of(FT_SizeRec) == 88)
	#assert(size_of(FT_GlyphSlotRec) == 304)
	#assert(offset_of(FT_GlyphSlotRec, advance) == 128)
	#assert(offset_of(FT_GlyphSlotRec, bitmap) == 152)
	#assert(offset_of(FT_GlyphSlotRec, bitmap_left) == 192)
	#assert(offset_of(FT_GlyphSlotRec, bitmap_top) == 196)
	#assert(size_of(FT_FaceRec) == 248)
	#assert(offset_of(FT_FaceRec, glyph) == 152)
	#assert(offset_of(FT_FaceRec, size) == 160)
}

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
	width:        int,
	height:       int,
	bearing_x:    int,
	bearing_y:    int,
	advance_x:    f32,
	alpha:        []u8,
	texture:      ^sdl.Texture,
	tex_renderer: ^sdl.Renderer,
}

Fallback_Face :: struct {
	face:       FT_Face,
	path:       string,
	current_px: u32,
}

Font :: struct {
	lib:        FT_Library,
	face:       FT_Face,
	loaded:     bool,
	font_path:  string,
	current_px: u32,
	fallbacks:  [dynamic]Fallback_Face,
	glyphs:     map[Glyph_Key]Cached_Glyph,
}

DEFAULT_FONT_PATHS :: [?]string{
	"/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
	"/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
	"/usr/share/fonts/liberation-sans/LiberationSans-Regular.ttf",
	"/usr/share/fonts/TTF/DejaVuSans.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
	"/usr/share/fonts/noto/NotoSans-Regular.ttf",
	"/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
	"/System/Library/Fonts/Supplemental/Arial.ttf",
	"/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
	"/Library/Fonts/LiberationSans-Regular.ttf",
	"C:/Windows/Fonts/arial.ttf",
	"C:/Windows/Fonts/segoeui.ttf",
}

DEFAULT_FALLBACK_FONT_PATHS :: [?]string{
	"/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
	"/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
	"/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc",
	"/usr/share/fonts/google-noto-sans-cjk-fonts/NotoSansCJK-Regular.ttc",
	"/usr/share/fonts/noto-cjk/NotoSansKR-Regular.otf",
	"/usr/share/fonts/opentype/noto/NotoSansKR-Regular.otf",
	"/usr/share/fonts/truetype/nanum/NanumGothic.ttf",
	"/usr/share/fonts/nanum/NanumGothic.ttf",
	"/usr/share/fonts/TTF/DejaVuSans.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
	"/System/Library/Fonts/AppleSDGothicNeo.ttc",
	"/System/Library/Fonts/Supplemental/AppleGothic.ttf",
	"/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
	"/System/Library/Fonts/Hiragino Sans GB.ttc",
	"C:/Windows/Fonts/malgun.ttf",
}

font_init :: proc(font: ^Font) -> bool {
	if FT_Init_FreeType(&font.lib) != 0 {
		fmt.eprintln("FT_Init_FreeType failed")
		return false
	}
	loaded := false
	if custom_path, ok := os.lookup_env("DAGDA_FONT", context.allocator); ok {
		defer delete(custom_path)
		if font_load_face(font, custom_path) {
			loaded = true
		}
	}
	if !loaded {
		for path in DEFAULT_FONT_PATHS {
			if font_load_face(font, path) {
				loaded = true
				break
			}
		}
	}
	if !loaded {
		FT_Done_FreeType(font.lib)
		font.lib = nil
		fmt.eprintln("No TrueType font found. Set DAGDA_FONT or install ttf-liberation / fonts-liberation.")
		return false
	}
	for path in DEFAULT_FALLBACK_FONT_PATHS {
		_ = font_add_fallback_face(font, path)
	}
	return true
}

font_init_with_paths :: proc(font: ^Font, primary_path: string, fallback_paths: []string = nil) -> bool {
	if FT_Init_FreeType(&font.lib) != 0 {
		return false
	}
	if !font_load_face(font, primary_path) {
		FT_Done_FreeType(font.lib)
		font.lib = nil
		return false
	}
	for path in fallback_paths {
		_ = font_add_fallback_face(font, path)
	}
	return true
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

font_add_fallback_face :: proc(font: ^Font, path: string) -> bool {
	if !font.loaded || font.lib == nil || len(path) == 0 {
		return false
	}
	if path == font.font_path {
		return false
	}
	for fb in font.fallbacks {
		if fb.path == path {
			return false
		}
	}
	cpath_buf, cpath_err := make([]u8, len(path) + 1)
	if cpath_err != nil || len(cpath_buf) != len(path) + 1 {
		delete(cpath_buf)
		return false
	}
	defer delete(cpath_buf)
	copy(cpath_buf, path)
	cpath_buf[len(path)] = 0
	cpath := cstring(raw_data(cpath_buf))
	face: FT_Face
	if FT_New_Face(font.lib, cpath, 0, &face) != 0 {
		return false
	}
	path_buf, path_err := make([]u8, len(path))
	if path_err != nil || len(path_buf) != len(path) {
		delete(path_buf)
		FT_Done_Face(face)
		return false
	}
	copy(path_buf, path)
	cloned_path := string(path_buf)
	prev_len := len(font.fallbacks)
	if _, append_err := append(&font.fallbacks, Fallback_Face{
		face = face,
		path = cloned_path,
	}); append_err != nil || len(font.fallbacks) != prev_len + 1 {
		delete(cloned_path)
		FT_Done_Face(face)
		return false
	}
	return true
}

// font_destroy_textures releases all cached SDL textures while their owning
// SDL_Renderer is still alive.
font_destroy_textures :: proc(font: ^Font) {
	for _, &g in font.glyphs {
		if g.texture != nil {
			sdl.DestroyTexture(g.texture)
			g.texture = nil
			g.tex_renderer = nil
		}
	}
}

font_destroy :: proc(font: ^Font) {
	font_destroy_textures(font)
	for _, &g in font.glyphs {
		delete(g.alpha)
	}
	delete(font.glyphs)
	delete(font.font_path)
	font.font_path = ""
	for &fb in font.fallbacks {
		delete(fb.path)
		if fb.face != nil {
			FT_Done_Face(fb.face)
			fb.face = nil
		}
	}
	delete(font.fallbacks)
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

copy_ft_bitmap_alpha :: proc(bmp: FT_Bitmap, allocator := context.allocator) -> (alpha: []u8, ok: bool) {
	w := int(bmp.width)
	h := int(bmp.rows)
	if w == 0 || h == 0 {
		return nil, true
	}
	if bmp.buffer == nil {
		return nil, false
	}
	if bmp.pixel_mode != FT_PIXEL_MODE_GRAY || bmp.num_grays != 256 {
		return nil, false
	}
	pitch := int(bmp.pitch)
	stride := pitch >= 0 ? pitch : -pitch
	if stride < w {
		return nil, false
	}
	alpha = make([]u8, w * h, allocator)
	for row in 0 ..< h {
		src_row := pitch > 0 ? row * stride : (h - 1 - row) * stride
		for col in 0 ..< w {
			alpha[row * w + col] = bmp.buffer[src_row + col]
		}
	}
	return alpha, true
}

font_resolve_glyph :: proc(font: ^Font, ch: rune, px: u32) -> (face: FT_Face, glyph_idx: u32) {
	glyph_idx = FT_Get_Char_Index(font.face, c.ulong(ch))
	if glyph_idx != 0 {
		font_set_size(font, px)
		return font.face, glyph_idx
	}
	for &fb in font.fallbacks {
		fb_idx := FT_Get_Char_Index(fb.face, c.ulong(ch))
		if fb_idx != 0 {
			if fb.current_px != px {
				_ = FT_Set_Pixel_Sizes(fb.face, 0, px)
				fb.current_px = px
			}
			return fb.face, fb_idx
		}
	}
	font_set_size(font, px)
	return font.face, 0
}

font_get_glyph :: proc(font: ^Font, ch: rune, px_height: f32) -> ^Cached_Glyph {
	px := u32(max(math.round(px_height), 1))
	key := Glyph_Key{codepoint = ch, px_height = px}
	if g, ok := &font.glyphs[key]; ok {
		return g
	}
	face, glyph_idx := font_resolve_glyph(font, ch, px)
	if FT_Load_Glyph(face, glyph_idx, FT_LOAD_RENDER) != 0 {
		font.glyphs[key] = Cached_Glyph{advance_x = px_height * 0.5}
		return &font.glyphs[key]
	}
	slot := face.glyph
	bmp := slot.bitmap
	alpha, bmp_ok := copy_ft_bitmap_alpha(bmp)
	w, h := 0, 0
	if bmp_ok && len(alpha) > 0 {
		w = int(bmp.width)
		h = int(bmp.rows)
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

// Return the nearest caret in a single left-to-right line of UTF-8 text,
// as a byte offset on a grapheme boundary (0 through len(text)). At a
// midpoint the trailing boundary wins. An empty line returns 0.
//
// Use the font and px_height passed to font_draw_text. line_x is measured
// from that call's text origin, in the same units as font_measure_width.
// Subtract the text origin after converting the pointer to drawing space.
// If a pane scales the finished drawing, undo that transform first. If it
// draws at a scaled font size, use that size and the rendered coordinates.
font_hit_test_caret :: proc(font: ^Font, text: string, px_height, line_x: f32) -> int {
	if line_x <= 0 || !font.loaded {
		return 0
	}
	left: f32
	it := utf8.decode_grapheme_iterator_make(text)
	for {
		cluster, grapheme, ok := utf8.decode_grapheme_iterate(&it)
		if !ok {
			return len(text)
		}
		advance := font_measure_width(font, cluster, px_height)
		if line_x < left + advance * 0.5 {
			return grapheme.byte_index
		}
		left += advance
	}
}

font_draw_text :: proc(
	font: ^Font,
	renderer: ^sdl.Renderer,
	text: string,
	x, y: f32,
	px_height: f32,
	color: sdl.Color,
	scale_x: f32 = 1.0,
	scale_y: f32 = 1.0,
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
					x = (math.floor(pen_x) + f32(g.bearing_x)) * scale_x,
					y = (math.floor(baseline) - f32(g.bearing_y)) * scale_y,
					w = f32(g.width) * scale_x,
					h = f32(g.height) * scale_y,
				}
				sdl.RenderTexture(renderer, g.texture, nil, &dst)
			}
		}
		pen_x += g.advance_x
	}
	return pen_x - x
}
