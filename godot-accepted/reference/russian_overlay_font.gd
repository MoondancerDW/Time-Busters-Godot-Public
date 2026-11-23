extends RefCounted
## Draws a high-contrast typeface in the letter cells of the Russian PC atlas.

const FONT_SIZE := 64
const LATIN := "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
const DIGITS := "0123456789"

# The Russian PC atlas reuses several Latin and accented slots. These are
# verified visible shapes indexed by the native one-based glyph ID, not byte
# values. Slots used by prompts, arrows or ambiguous accents keep the atlas.
const LETTERS := {
	0x4f: "Е", 0x51: "Ъ", 0x52: "Х", 0x53: "Ч", 0x54: "У",
	0x55: "Ц", 0x56: "Ш", 0x57: "Ы", 0x58: "Ь", 0x59: "Щ",
	0x5b: "Я", 0x5c: "Э", 0x62: "Ф", 0x63: "Ю", 0x6f: "Т",
	0x70: "А", 0x71: "Б", 0x72: "В", 0x73: "Г", 0x74: "Д",
	0x75: "Ж", 0x76: "З", 0x77: "И", 0x78: "К", 0x79: "Л",
	0x7a: "М", 0x7b: "Н", 0x7c: "О", 0x7d: "П", 0x7e: "Р", 0x7f: "С",
}
const TEXT_COLORS: Array[Color] = [
	Color("#fffdf6"), Color("#ffeb73"), Color("#b5f58a"), Color("#bfdaff"), Color("#ffb8a6"),
]
const OUTLINE := Color("#151822")

var _typeface := FontVariation.new()
var _text_server := TextServerManager.get_primary_interface()
var _letters: Dictionary[int, Dictionary] = {}


func _init() -> void:
	_typeface.base_font = ThemeDB.fallback_font
	_typeface.variation_embolden = 1.15


static func _character(glyph: int) -> String:
	if glyph >= 0x01 and glyph <= 0x0a:
		return DIGITS[glyph - 0x01]
	if glyph >= 0x0b and glyph <= 0x24:
		return LATIN[glyph - 0x0b]
	# A–G's nominal large slots contain punctuation in this atlas.
	if glyph >= 0x2c and glyph <= 0x3e:
		return LATIN[glyph - 0x25]
	return LETTERS.get(glyph, "")


static func _ink_bounds(image: Image) -> Rect2:
	if image == null or image.is_empty():
		return Rect2()
	var first := image.get_size()
	var last := Vector2i(-1, -1)
	for y: int in range(image.get_height()):
		for x: int in range(image.get_width()):
			var pixel := image.get_pixel(x, y)
			# Keep the source's letter proportions and baseline without fitting
			# to the baked black drop shadow or unused texture padding.
			if pixel.a < 0.5 or pixel.get_luminance() < 0.5:
				continue
			first = Vector2i(mini(first.x, x), mini(first.y, y))
			last = Vector2i(maxi(last.x, x), maxi(last.y, y))
	if last.x < 0:
		return Rect2()
	return Rect2(Vector2(first), Vector2(last - first + Vector2i.ONE))


func register_letter(glyph: int, source_texture: Dictionary) -> void:
	var character := _character(glyph)
	if character.is_empty():
		return
	var width := int(source_texture.get("width", 0))
	var height := int(source_texture.get("height", 0))
	var rgba: PackedByteArray = source_texture.get("rgba", PackedByteArray())
	if width <= 0 or height <= 0 or rgba.size() != width * height * 4:
		return
	var ink := _ink_bounds(Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, rgba))
	if not ink.has_area():
		return
	var cache_size := Vector2i(FONT_SIZE, 0)
	for font_rid: RID in _typeface.get_rids():
		var index := _text_server.font_get_glyph_index(font_rid, FONT_SIZE, character.unicode_at(0), 0)
		if index == 0:
			continue
		_text_server.font_render_glyph(font_rid, cache_size, index)
		var bounds := _text_server.font_get_glyph_size(font_rid, cache_size, index)
		if bounds.x <= 0.0 or bounds.y <= 0.0:
			continue
		_letters[glyph] = {
			"font": font_rid, "index": index, "ink": ink, "size": bounds,
			"offset": _text_server.font_get_glyph_offset(font_rid, cache_size, index),
		}
		return


func registered_count() -> int:
	return _letters.size()


func draw_letter(control: Control, glyph: int, origin: Vector2, scale_value: Vector2, palette: int) -> bool:
	if not _letters.has(glyph):
		return false
	var letter := _letters[glyph]
	var ink: Rect2 = letter.ink
	var bounds: Vector2 = letter.size
	var offset: Vector2 = letter.offset
	var fitted_scale := ink.size * scale_value / bounds
	control.draw_set_transform(origin + ink.position * scale_value, 0.0, fitted_scale)
	var canvas := control.get_canvas_item()
	var color := TEXT_COLORS[palette] if palette >= 0 and palette < TEXT_COLORS.size() else TEXT_COLORS[0]
	_text_server.font_draw_glyph_outline(letter.font, canvas, FONT_SIZE, 4, -offset, letter.index, OUTLINE, 1.0)
	_text_server.font_draw_glyph(letter.font, canvas, FONT_SIZE, -offset, letter.index, color, 1.0)
	control.draw_set_transform(Vector2.ZERO)
	return true
