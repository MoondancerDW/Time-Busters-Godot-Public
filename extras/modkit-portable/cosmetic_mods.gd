extends RefCounted
## Cosmetic overlays and one-shot PCM substitution. All selectors use original source identity.

const MAX_FILE_BYTES := 8 * 1024 * 1024
const MAX_OUTPUT_FRAMES := 262144
const MAX_ENTRIES := 64
const GAIN_STEP := 2000.0
const RAD_PER_NATIVE_UNIT := TAU / 4096.0
const ARABIA_REST_BOX := "be56218eb50e87b07bf0e4ca19dc888dd7867ce2e09d5d8f5c8fdf03f643da0a:84429:253"
const REST_BOX_MIN := Vector3(-0.105, 0.0, -0.105)
const REST_BOX_MAX := Vector3(0.105, 0.21, 0.105)
const REST_BOX_TOLERANCE := 0.001

var _models: Dictionary = {}
var _sounds: Dictionary = {}
var _visuals: Dictionary = {}
var _reported: Dictionary = {}
var _generation := -1
var _trace := false
var _model_instances_created := 0
var _one_shots_replaced := 0


func configure() -> void:
	var directory := OS.get_environment("TIMEBUSTERS_COSMETIC_MOD")
	_trace = OS.get_environment("TIMEBUSTERS_COSMETIC_TRACE") == "1"
	var disabled := false
	for option: String in OS.get_cmdline_user_args():
		if option.begins_with("--cosmetic-mod="):
			directory = option.trim_prefix("--cosmetic-mod=")
		elif option == "--no-cosmetic-mod":
			disabled = true
		elif option == "--cosmetic-trace":
			_trace = true
	if disabled or directory.is_empty():
		return
	directory = directory.replace("\\", "/").simplify_path()
	var manifest := directory.path_join("mod.json")
	var file := FileAccess.open(manifest, FileAccess.READ)
	if file == null or file.get_length() > 65536:
		_notice("manifest", "Cannot read bounded manifest " + manifest)
		return
	var value: Variant = JSON.parse_string(file.get_as_text())
	if not value is Dictionary or not _integer(value.get("schema_version"), 2, 2):
		_notice("schema", "Expected cosmetic schema_version 2")
		return
	_load_models(directory, value.get("models", []))
	_load_sounds(directory, value.get("sounds", []))
	print("TB_COSMETIC_MOD ", str(value.get("name", directory)), " models=", _models.size(), " one-shot sounds=", _sounds.size())


func _notice(key: String, message: String) -> void:
	if not _reported.has(key):
		_reported[key] = true
		push_warning("Time Busters cosmetic: " + message)


func _integer(value: Variant, low: int, high: int) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and \
		float(value) == floor(float(value)) and value >= low and value <= high


func _valid_source(value: Variant) -> bool:
	if not value is String or value.length() != 64:
		return false
	for index: int in range(value.length()):
		if not value[index] in "0123456789abcdef":
			return false
	return true


func _asset(directory: String, value: Variant, extension: String) -> String:
	if not value is String or value.is_empty() or value.contains("\\") or value.contains(":") \
			or value.begins_with("/") or not value.ends_with(extension):
		return ""
	for part: String in value.split("/", true):
		if part in ["", ".", ".."]:
			return ""
	var path := directory.path_join(value)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() < 1 or file.get_length() > MAX_FILE_BYTES:
		return ""
	return path


func _load_models(directory: String, rows: Variant) -> void:
	if not rows is Array or rows.size() > MAX_ENTRIES:
		_notice("models", "Expected a bounded models array")
		return
	for index: int in range(rows.size()):
		var row: Variant = rows[index]
		var label := "models[%d]" % index
		if not row is Dictionary or not _valid_source(row.get("resource_sha256")) \
				or not _integer(row.get("source_chunk"), 1, 0xffffffff) or not _integer(row.get("source_id"), 0, 65535):
			_notice(label, "Invalid model selector " + label)
			continue
		var scale_value: Variant = row.get("scale", 1.0)
		var path := _asset(directory, row.get("file"), ".glb")
		if not (scale_value is int or scale_value is float) or not is_finite(float(scale_value)) \
				or float(scale_value) < 0.01 or float(scale_value) > 10.0 or path.is_empty():
			_notice(label, "Invalid model scale or GLB path in " + label)
			continue
		var key := "%s:%d:%d" % [row["resource_sha256"], int(row["source_chunk"]), int(row["source_id"])]
		if _models.has(key):
			_notice(label, "Duplicate model selector " + key)
			continue
		var extent := _reference_extent(row.get("reference_extent_m"))
		if extent == Vector3.ZERO:
			_notice(label, "Invalid reference extent in " + label)
			continue
		_models[key] = {"file":path, "scale":float(scale_value), "reference_extent":extent,
			"scene":null, "loaded_generation":-1, "fingerprint":""}


func _reference_extent(value: Variant) -> Vector3:
	if not value is Array or value.size() != 3:
		return Vector3.ZERO
	for axis: Variant in value:
		if not (axis is int or axis is float) or not is_finite(float(axis)) or axis < 0.001 or axis > 100.0:
			return Vector3.ZERO
	return Vector3(float(value[0]), float(value[1]), float(value[2]))


func _load_sounds(directory: String, rows: Variant) -> void:
	if not rows is Array or rows.size() > MAX_ENTRIES:
		_notice("sounds", "Expected a bounded sounds array")
		return
	for index: int in range(rows.size()):
		var row: Variant = rows[index]
		var label := "sounds[%d]" % index
		if not row is Dictionary or not _valid_source(row.get("resource_sha256")) or not _integer(row.get("blob"), 1, 127):
			_notice(label, "Invalid sound selector " + label)
			continue
		var path := _asset(directory, row.get("file"), ".wav")
		var key := "%s:%d" % [row["resource_sha256"], int(row["blob"])]
		if path.is_empty() or _sounds.has(key):
			_notice(label, "Invalid WAV path or repeated selector " + label)
			continue
		var clip := _wav(path)
		if clip.is_empty():
			_notice(label, "Expected uncompressed 16-bit mono or stereo WAV in " + label)
			continue
		_sounds[key] = clip


func _wav(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() < 44 or file.get_length() > MAX_FILE_BYTES:
		return {}
	var buffer := file.get_buffer(file.get_length())
	if buffer.slice(0, 4).get_string_from_ascii() != "RIFF" or buffer.slice(8, 12).get_string_from_ascii() != "WAVE" \
			or buffer.decode_u32(4) + 8 != buffer.size():
		return {}
	var channels := 0
	var sample_rate := 0
	var samples := PackedByteArray()
	var offset := 12
	while offset + 8 <= buffer.size():
		var kind := buffer.slice(offset, offset + 4).get_string_from_ascii()
		var length := buffer.decode_u32(offset + 4)
		var begin := offset + 8
		if length > buffer.size() - begin:
			return {}
		if kind == "fmt ":
			if length < 16 or channels != 0 or buffer.decode_u16(begin) != 1 or buffer.decode_u16(begin + 14) != 16:
				return {}
			channels = buffer.decode_u16(begin + 2)
			sample_rate = buffer.decode_u32(begin + 4)
			if channels not in [1, 2] or sample_rate < 8000 or sample_rate > 192000 \
					or buffer.decode_u16(begin + 12) != channels * 2:
				return {}
		elif kind == "data":
			if not samples.is_empty():
				return {}
			samples = buffer.slice(begin, begin + length)
		offset = begin + length + (length & 1)
	if channels == 0 or samples.is_empty() or samples.size() % (channels * 2) != 0:
		return {}
	return {"samples":samples, "channels":channels, "frames":int(float(samples.size()) / (channels * 2))}


func _admissible_tree(node: Node) -> bool:
	# This layer uses passive art only. Imported animation players, lights and cameras are refused.
	if not node is Node3D:
		return false
	for child: Node in node.get_children():
		if not _admissible_tree(child):
			return false
	return node.get_class() in ["Node3D", "MeshInstance3D"]


func _has_mesh(node: Node) -> bool:
	if node is MeshInstance3D and node.mesh != null and node.mesh.get_surface_count() > 0:
		return true
	for child: Node in node.get_children():
		if _has_mesh(child):
			return true
	return false


func _prepare_meshes(node: Node, root_node: Node) -> void:
	if node != root_node:
		node.owner = root_node
	if node is MeshInstance3D and node.mesh != null:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		for index: int in range(node.mesh.get_surface_count()):
			var old := node.get_active_material(index) as BaseMaterial3D
			var material: BaseMaterial3D = old.duplicate() as BaseMaterial3D if old != null else StandardMaterial3D.new()
			# The stock renderer uses prelit materials and has no GLTF lighting rig.
			material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			node.set_surface_override_material(index, material)
	for child: Node in node.get_children():
		_prepare_meshes(child, root_node)


func _self_contained_glb(bytes: PackedByteArray) -> bool:
	if bytes.size() < 20:
		return false
	var size := bytes.decode_u32(12)
	if bytes.slice(0, 4).get_string_from_ascii() != "glTF" or bytes.decode_u32(4) != 2 \
			or bytes.decode_u32(8) != bytes.size() or size > bytes.size() - 20 \
			or bytes.slice(16, 20).get_string_from_ascii() != "JSON":
		return false
	var value: Variant = JSON.parse_string(bytes.slice(20, 20 + size).get_string_from_utf8())
	if not value is Dictionary:
		return false
	for field: String in ["buffers", "images"]:
		var items: Variant = value.get(field, [])
		if not items is Array:
			return false
		for item: Variant in items:
			if not item is Dictionary:
				return false
			var uri: Variant = item.get("uri", "data:")
			if not uri is String or not uri.begins_with("data:"):
				return false
	for field: String in ["animations", "cameras", "skins", "extensionsRequired"]:
		var items: Variant = value.get(field, [])
		if not items is Array or not items.is_empty():
			return false
	return true


func _model_template(entry: Dictionary, key: String) -> PackedScene:
	if entry["loaded_generation"] == _generation:
		return entry["scene"]
	entry["loaded_generation"] = _generation
	entry["scene"] = null
	entry["fingerprint"] = ""
	var file := FileAccess.open(entry["file"], FileAccess.READ)
	if file == null or file.get_length() > MAX_FILE_BYTES:
		_notice("glb:" + key, "Cannot read passive model " + str(entry["file"]))
		return null
	var bytes := file.get_buffer(file.get_length())
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	# Validate and import the same buffer with no external base path.
	if _self_contained_glb(bytes) and document.append_from_buffer(bytes, "", state) == OK:
		var imported := document.generate_scene(state)
		if imported != null:
			if _admissible_tree(imported) and _has_mesh(imported):
				_prepare_meshes(imported, imported)
				var packed := PackedScene.new()
				if packed.pack(imported) == OK:
					var hash := HashingContext.new()
					hash.start(HashingContext.HASH_SHA256)
					hash.update(bytes)
					entry["fingerprint"] = hash.finish().hex_encode()
					entry["scene"] = packed
			imported.free()
	if entry["scene"] == null:
		_notice("glb:" + key, "Could not import passive model " + str(entry["file"]))
	return entry["scene"]


func clear_models() -> void:
	for uid: Variant in _visuals.keys():
		_drop_model(uid)
	_generation = -1
	for entry: Dictionary in _models.values():
		entry["scene"] = null
		entry["loaded_generation"] = -1
		entry["fingerprint"] = ""


func _drop_model(uid: Variant) -> void:
	var instance: Node3D = _visuals[uid]["node"]
	_visuals.erase(uid)
	if is_instance_valid(instance):
		var parent := instance.get_parent()
		if parent != null:
			parent.remove_child(instance)
		instance.queue_free()


func _local_bounds(actor: Dictionary, rest_box: bool, rotation: Basis, position: Vector3) -> AABB:
	var inverse := rotation.transposed()
	var rest_volume := AABB(REST_BOX_MIN, REST_BOX_MAX - REST_BOX_MIN).grow(REST_BOX_TOLERANCE)
	var have_vertex := false
	var bounds := AABB()
	for mesh: Dictionary in actor.get("meshes", []):
		var vertices: PackedVector3Array = mesh.get("vertices", PackedVector3Array())
		var indices: PackedInt32Array = mesh.get("indices", PackedInt32Array())
		for index: int in indices:
			if index < 0 or index >= vertices.size():
				return AABB()
			var local := inverse * (vertices[index] - position)
			if not local.is_finite():
				return AABB()
			if rest_box:
				# Any rendered point outside the reviewed rest box disables this narrow fit.
				if not rest_volume.has_point(local):
					return AABB()
			bounds = bounds.expand(local) if have_vertex else AABB(local, Vector3.ZERO)
			have_vertex = true
	return bounds


func _rigid_pose(actor: Dictionary, key: String) -> Dictionary:
	var debug: Dictionary = actor.get("research_debug", {})
	if int(debug.get("parent", 0)) != -1 or int(debug.get("ride_record", 1)) != 0 \
			or not actor.get("meshes_worldspace", false):
		return {}
	var parts := int(actor.get("pose_parts", -1))
	var rest_box := key == ARABIA_REST_BOX and int(actor.get("state", -1)) == 331 and parts == 2
	var rotation := Basis.IDENTITY
	if not rest_box:
		if parts != 0 or actor.get("animated", true) or not (debug.has("pitch") and debug.has("yaw") and debug.has("roll")):
			return {}
		var x := float(debug["pitch"]) * RAD_PER_NATIVE_UNIT
		var y := float(debug["yaw"]) * RAD_PER_NATIVE_UNIT
		var z := float(debug["roll"]) * RAD_PER_NATIVE_UNIT
		# Native Rx * Ry * Rz in Godot axes (x, -y, -z).
		rotation = Basis(Vector3.RIGHT, x) * Basis(Vector3.UP, -y) * Basis(Vector3.BACK, -z)
	var position: Vector3 = actor.get("position", Vector3.INF)
	if not position.is_finite():
		return {}
	var bounds := _local_bounds(actor, rest_box, rotation, position)
	if minf(bounds.size.x, minf(bounds.size.y, bounds.size.z)) < 0.0001:
		return {}
	if rest_box and (bounds.position.distance_to(REST_BOX_MIN) > REST_BOX_TOLERANCE \
			or bounds.end.distance_to(REST_BOX_MAX) > REST_BOX_TOLERANCE):
		return {}
	return {"rotation":rotation, "position":position, "extent":bounds.size}


func present_models(frame: Dictionary, scene: Dictionary, stock_nodes: Dictionary, layer: Node3D, generation: int) -> void:
	if _models.is_empty() and not _trace:
		return
	if generation != _generation:
		clear_models()
		_generation = generation
	if generation < 0:
		return
	var source: String = str(scene.get("source_sha256", ""))
	var kept := {}
	for actor: Dictionary in frame.get("actors", []):
		var chunk: int = int(actor.get("source_chunk", 0))
		var id: int = int(actor.get("source_id", -1))
		var uid: int = int(actor.get("uid", -1))
		var stock: Node3D = stock_nodes.get(uid)
		if chunk <= 0 or uid < 0 or actor.get("player", false) or not is_instance_valid(stock) or not stock.visible:
			continue
		var key := "%s:%d:%d" % [source, chunk, id]
		var trace_key := "trace-model:" + key
		var first_trace := _trace and not _reported.has(trace_key)
		var entry: Dictionary = _models.get(key, {})
		if entry.is_empty() and not first_trace:
			continue
		var pose := _rigid_pose(actor, key)
		if first_trace:
			_reported[trace_key] = true
			print("TB_COSMETIC_MODEL level=", scene.get("level", ""), " source=", source,
				" chunk=", chunk, " id=", id, " eligible=", not pose.is_empty(), " extent_m=", pose.get("extent", Vector3.ZERO))
		if entry.is_empty():
			continue
		if pose.is_empty():
			_notice("pose:" + key, "No supported rigid pose for " + key + "; using stock geometry")
			continue
		var asset := _model_template(entry, key)
		if asset == null:
			continue
		var scale: Vector3 = pose["extent"] / entry["reference_extent"] * float(entry["scale"])
		if not scale.is_finite() or minf(scale.x, minf(scale.y, scale.z)) < 0.001 \
				or maxf(scale.x, maxf(scale.y, scale.z)) > 100.0:
			continue
		var identity := [generation, key, entry["fingerprint"], stock.get_instance_id()]
		var cached: Dictionary = _visuals.get(uid, {})
		var instance: Node3D = cached.get("node")
		if not is_instance_valid(instance) or cached.get("identity") != identity:
			if not cached.is_empty():
				_drop_model(uid)
			var imported := asset.instantiate() as Node3D
			if imported == null:
				continue
			instance = Node3D.new()
			instance.name = "Cosmetic_%d" % uid
			instance.add_child(imported)
			layer.add_child(instance)
			_visuals[uid] = {"node":instance, "identity":identity}
			_model_instances_created += 1
		var rotation: Basis = pose["rotation"]
		instance.transform = Transform3D(rotation * Basis.from_scale(scale), pose["position"])
		stock.hide()
		kept[uid] = true
	for uid: Variant in _visuals.keys():
		if not kept.has(uid):
			_drop_model(uid)


func sound_for(command: Dictionary, source: String) -> Dictionary:
	if _sounds.is_empty() and not _trace:
		return command
	if not _valid_source(source) or int(command.get("op", -1)) != 0 \
			or command.get("empty_sound", false) or command.get("loop", false):
		return command
	var key: int = int(command.get("key", -1))
	var blob := int(float(key) / 10.0)
	if blob < 1 or blob > 127:
		return command
	var selector := "%s:%d" % [source, blob]
	if _trace and not _reported.has("trace-sfx:" + selector):
		_reported["trace-sfx:" + selector] = true
		print("TB_COSMETIC_SFX source=", source, " blob=", blob, " copy=", key % 10)
	var clip: Dictionary = _sounds.get(selector, {})
	var frames: int = int(command.get("frames", 0))
	var original: PackedByteArray = command.get("pcm_s16le", PackedByteArray())
	if clip.is_empty() or frames < 1 or frames > MAX_OUTPUT_FRAMES \
			or int(command.get("rate", 0)) <= 0 or original.size() != frames * 4:
		return command
	var samples: PackedByteArray = clip["samples"]
	var sample_frames: int = int(clip["frames"])
	var channels: int = int(clip["channels"])
	var pan: int = int(command.get("pan", 0))
	var left_gain := pow(10.0, -maxf(float(pan), 0.0) / GAIN_STEP)
	var right_gain := pow(10.0, minf(float(pan), 0.0) / GAIN_STEP)
	var result := PackedByteArray()
	result.resize(frames * 4)
	# Fit the replacement to the original one-shot buffer duration and playback clock.
	for index: int in range(frames):
		var sample_index := int(float(index) * sample_frames / frames) * channels * 2
		var left := samples.decode_s16(sample_index)
		var right := samples.decode_s16(sample_index + 2) if channels == 2 else left
		result.encode_s16(index * 4, roundi(float(left) * left_gain))
		result.encode_s16(index * 4 + 2, roundi(float(right) * right_gain))
	var replacement := command.duplicate()
	replacement["pcm_s16le"] = result
	replacement["cosmetic_replacement"] = true
	_one_shots_replaced += 1
	var trace_key := "trace-replaced:" + selector
	if _trace and not _reported.has(trace_key):
		_reported[trace_key] = true
		var hash := HashingContext.new()
		hash.start(HashingContext.HASH_SHA256)
		hash.update(result)
		print("TB_COSMETIC_SFX_REPLACED source=", source, " blob=", blob, " key=", key,
			" frames=", frames, " rate=", command.get("rate"), " pcm_sha256=", hash.finish().hex_encode())
	return replacement


func metrics() -> Dictionary:
	return {"configured_models":_models.size(), "configured_sounds":_sounds.size(),
		"live_model_instances":_visuals.size(), "created_model_instances":_model_instances_created,
		"one_shots_replaced":_one_shots_replaced}
