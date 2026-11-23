class_name TbNativeHudSprites
extends Control
## Own renderer for copied native HUD-sheet primitives. No simulation or text synthesis.
var _sheet: Array[Texture2D] = []
var _rows: Array = []
var _crop_cache: Dictionary = {}
var _problems: Array[String] = []

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()

func clear_overlay() -> void:
	_sheet.clear()
	_rows.clear()
	_crop_cache.clear()
	_problems.clear()
	queue_redraw()

func configure_scene(scene: Dictionary, textures: Array[Texture2D]) -> void:
	clear_overlay()
	var indices: PackedInt32Array = scene.get("hud_sheet", PackedInt32Array())
	var gamma_value: float = float(scene.get("pc_tex_gamma", 1.0))
	for index: int in indices:
		if index < 0 or index >= textures.size() or textures[index] == null:
			_sheet.append(null)
			continue
		var image: Image = textures[index].get_image()
		if image == null or image.is_empty():
			_sheet.append(null)
			continue
		if is_finite(gamma_value) and gamma_value > 0.0 and gamma_value != 1.0:
			var rgba: PackedByteArray = image.get_data()
			for pixel: int in range(0, rgba.size(), 4):
				for channel: int in range(3):
					rgba[pixel + channel] = clampi(int(floor(256.0 * pow(float(rgba[pixel + channel]) / 256.0, gamma_value))), 0, 255)
			image = Image.create_from_data(image.get_width(), image.get_height(), false, Image.FORMAT_RGBA8, rgba)
		_sheet.append(ImageTexture.create_from_image(image))
	queue_redraw()

func _valid(row: Dictionary) -> bool:
	var frame: int = int(row.get("frame", -1))
	if frame < 0 or frame >= _sheet.size() or _sheet[frame] == null:
		return false
	var dimensions: Vector2 = _sheet[frame].get_size()
	return int(row.get("u", -1)) >= 0 and int(row.get("v", -1)) >= 0 and int(row.get("u", -1)) < dimensions.x and int(row.get("v", -1)) < dimensions.y and int(row.get("w", -1)) >= 0 and int(row.get("h", -1)) >= 0

func set_native_frame(overlay: Dictionary) -> void:
	_rows = overlay.get("hud_sprites", []).duplicate(true)
	_problems.clear()
	for value: Variant in _rows:
		if not value is Dictionary:
			_problems.append("invalid_hud_sprite_record")
		elif value.get("shown", false) and not _valid(value):
			_problems.append("missing_or_invalid_hud_sprite:" + str(value.get("index", -1)))
	queue_redraw()

func native_scale() -> Vector2:
	return Vector2(size.y / 384.0, size.y / 240.0)

func sprite_rect(row: Dictionary) -> Rect2:
	if not _valid(row):
		return Rect2()
	var scale_value := native_scale()
	var origin := size * 0.5 + Vector2(int(float(row.x) * scale_value.x), int(float(row.y) * scale_value.y))
	return Rect2(origin, Vector2(int(row.w) + 1, int(row.h) + 1) * scale_value)

func _crop(row: Dictionary) -> Texture2D:
	var key := "%d/%d/%d/%d/%d" % [row.frame, row.u, row.v, row.w, row.h]
	if _crop_cache.has(key):
		return _crop_cache[key]
	var image: Image = _sheet[int(row.frame)].get_image()
	var region := Rect2i(int(row.u), int(row.v), mini(int(row.w) + 1, image.get_width() - int(row.u)), mini(int(row.h) + 1, image.get_height() - int(row.v)))
	var cropped := ImageTexture.create_from_image(image.get_region(region))
	_crop_cache[key] = cropped
	return cropped

func covers_bottom(pixels: float) -> bool:
	var viewport_rect := Rect2(Vector2.ZERO, size)
	for value: Variant in _rows:
		if value is Dictionary and value.get("shown", false):
			var rect := sprite_rect(value)
			if rect.has_area() and rect.intersects(viewport_rect) and rect.end.y > size.y - pixels:
				return true
	return false

func metrics() -> Dictionary:
	var visible_rows: Array = []
	for row: Variant in _rows:
		if row is Dictionary and row.get("shown", false):
			visible_rows.append({"index":row.get("index", -1), "frame":row.get("frame", -1), "rect":sprite_rect(row), "valid":_valid(row)})
	return {"sheet_records":_sheet.size(), "valid_sheet_textures":_sheet.filter(func(value): return value != null).size(), "sprite_records":_rows.size(), "shown":visible_rows, "cached_crops":_crop_cache.size(), "problems":_problems.duplicate(), "scale":native_scale(), "mouse_filter":mouse_filter, "focus_mode":focus_mode}

func _draw() -> void:
	# Native ordering-table prepend: lower sprite indices are drawn last.
	for i: int in range(_rows.size() - 1, -1, -1):
		var value: Variant = _rows[i]
		if value is Dictionary and value.get("shown", false) and _valid(value):
			draw_texture_rect(_crop(value), sprite_rect(value), false)
