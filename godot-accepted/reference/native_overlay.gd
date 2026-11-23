class_name TbNativeOverlay
extends Control
## Own 2-D renderer for immutable native glyph records. No text decoding or VM.

const RussianOverlayFont = preload("res://reference/russian_overlay_font.gd")

var _font: Array[Texture2D] = []
var _russian_font: RussianOverlayFont
var _glyphs: Array = []
var _boxes: Array = []
var _problems: Array[String] = []
var _source_font_count: int = 0

const MASKS: Array[Color] = [Color(1,1,1,1), Color(1,1,0,1), Color(0,1,0,1), Color(0,0,1,1), Color(1,0,0,1)]

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()

func clear_overlay() -> void:
	_font.clear()
	_russian_font = null
	_glyphs.clear()
	_boxes.clear()
	_problems.clear()
	_source_font_count = 0
	queue_redraw()

func configure_scene(scene: Dictionary, textures: Array[Texture2D]) -> void:
	clear_overlay()
	if str(scene.get("language", "")).to_upper() == "RU":
		_russian_font = RussianOverlayFont.new()
	var indices: PackedInt32Array = scene.get("overlay_font", PackedInt32Array())
	var source_textures: Array = scene.get("textures", [])
	_source_font_count = indices.size()
	# Apply the source PC texel curve only to a private overlay image. Neither
	# the immutable native RGBA bytes nor the world's textures are modified.
	var gamma_value: float = float(scene.get("pc_tex_gamma", 1.0))
	for index: int in indices:
		if index < 0 or index >= textures.size() or textures[index] == null:
			_font.append(null)
			continue
		var texture: Texture2D = textures[index]
		if is_finite(gamma_value) and gamma_value > 0.0 and gamma_value != 1.0:
			var image: Image = texture.get_image()
			if image != null and not image.is_empty():
				var rgba: PackedByteArray = image.get_data()
				for pixel: int in range(0, rgba.size(), 4):
					for channel: int in range(3):
						rgba[pixel + channel] = clampi(int(floor(256.0 * pow(float(rgba[pixel + channel]) / 256.0, gamma_value))), 0, 255)
				image = Image.create_from_data(image.get_width(), image.get_height(), false, Image.FORMAT_RGBA8, rgba)
				texture = ImageTexture.create_from_image(image)
		_font.append(texture)
		if _russian_font != null and index < source_textures.size() and source_textures[index] is Dictionary:
			_russian_font.register_letter(_font.size(), source_textures[index])
	queue_redraw()

func set_native_frame(overlay: Dictionary) -> void:
	_glyphs = overlay.get("glyphs", []).duplicate(true)
	_boxes = overlay.get("text_boxes", []).duplicate(true)
	_problems.clear()
	for value: Variant in _glyphs:
		if not value is Dictionary:
			_problems.append("invalid_glyph_record")
			continue
		var glyph: int = int(value.get("glyph", 0))
		if glyph <= 0 or glyph > _font.size() or _font[glyph - 1] == null:
			_problems.append("missing_glyph_texture:" + str(glyph))
	for value: Variant in _boxes:
		if not value is PackedInt32Array or value.size() != 4 or value[2] < 0 or value[3] < 0:
			_problems.append("invalid_text_box")
	queue_redraw()

func native_scale() -> Vector2:
	return Vector2(size.y / 384.0, size.y / 240.0)

func glyph_rect(record: Dictionary) -> Rect2:
	var glyph: int = int(record.get("glyph", 0))
	if glyph <= 0 or glyph > _font.size() or _font[glyph - 1] == null:
		return Rect2()
	var scale_value := native_scale()
	var origin := size * 0.5
	var position_value := origin + Vector2(int(float(record.get("x", 0)) * size.y / 384.0), int(float(record.get("y", 0)) * size.y / 240.0))
	return Rect2(position_value, _font[glyph - 1].get_size() * scale_value)

func covers_bottom(pixels: float) -> bool:
	var viewport_rect := Rect2(Vector2.ZERO, size)
	for value: Variant in _glyphs:
		if value is Dictionary:
			var rect := glyph_rect(value)
			if rect.has_area() and rect.intersects(viewport_rect) and rect.end.y > size.y - pixels:
				return true
	return false

func palette_mask(index: int) -> Color:
	return MASKS[index] if index >= 0 and index < MASKS.size() else Color.WHITE

func metrics() -> Dictionary:
	return {"glyph_records":_glyphs.size(), "text_boxes":_boxes.size(), "font_records":_source_font_count,
		"valid_font_textures":_font.filter(func(value): return value != null).size(), "problems":_problems.duplicate(),
		"readable_russian_cells":_russian_font.registered_count() if _russian_font != null else 0,
		"scale":native_scale(), "center":size * 0.5, "mouse_filter":mouse_filter, "focus_mode":focus_mode}

func _box(rect: Rect2, scale_value: Vector2) -> void:
	var inner := Color(0.25, 0.25, 0.25, 0.25)
	var outer := Color(0.15, 0.15, 0.15, 0.25)
	draw_rect(rect, inner)
	var outside := rect.grow_individual(11.0 * scale_value.x, 6.0 * scale_value.y, 11.0 * scale_value.x, 6.0 * scale_value.y)
	var a := [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]
	var b := [outside.position, Vector2(outside.end.x, outside.position.y), outside.end, Vector2(outside.position.x, outside.end.y)]
	for edge: int in range(4):
		var next: int = (edge + 1) % 4
		draw_polygon(PackedVector2Array([a[edge], a[next], b[next], b[edge]]), PackedColorArray([inner, inner, outer, outer]))
	# PC draws the center twice over the glyphs.
	draw_rect(rect, inner)

func _draw() -> void:
	var scale_value := native_scale()
	for value: Variant in _glyphs:
		if not value is Dictionary:
			continue
		var rect := glyph_rect(value)
		if rect.has_area():
			var glyph := int(value.glyph)
			var palette := int(value.get("pal", 0))
			if _russian_font != null and _russian_font.draw_letter(self, glyph, rect.position, scale_value, palette):
				continue
			draw_texture_rect(_font[glyph - 1], rect, false, palette_mask(palette))
	for value: Variant in _boxes:
		if value is PackedInt32Array and value.size() == 4 and value[2] >= 0 and value[3] >= 0:
			_box(Rect2(size * 0.5 + Vector2(value[0], value[1]) * scale_value, Vector2(value[2], value[3]) * scale_value), scale_value)
