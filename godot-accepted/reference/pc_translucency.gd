extends RefCounted
## Convert raw native PC BGR555 colours expanded to RGBA8 before brightness.

static func make_texture(spec: Dictionary, mode: int) -> ImageTexture:
	if mode < 0 or mode > 3:
		return null

	var width: int = int(spec.get("width", 0))
	var height: int = int(spec.get("height", 0))
	var source: Variant = spec.get("rgba")
	if width < 1 or height < 1 or not source is PackedByteArray:
		return null
	var rgba: PackedByteArray = source.duplicate()
	if rgba.size() != width * height * 4:
		return null

	for offset: int in range(0, rgba.size(), 4):
		# The native indexed decoder already marks zero-colour texels transparent.
		if rgba[offset + 3] == 0:
			continue
		if mode == 2:
			# The native subtractive palette keeps raw red as alpha and clears RGB.
			rgba[offset + 3] = rgba[offset]
			rgba[offset] = 0
			rgba[offset + 1] = 0
			rgba[offset + 2] = 0
			continue
		var maximum := maxi(rgba[offset], maxi(rgba[offset + 1], rgba[offset + 2]))
		var opacity: int
		match mode:
			0:
				opacity = maximum >> 1
			1:
				opacity = maximum - (maximum >> 2)
			3:
				opacity = maximum >> 2
		var lift := 255 - maximum
		rgba[offset] += lift
		rgba[offset + 1] += lift
		rgba[offset + 2] += lift
		rgba[offset + 3] = opacity

	var image := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, rgba)
	return ImageTexture.create_from_image(image)

