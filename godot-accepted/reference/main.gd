class_name TbReferenceGame
extends Node3D
## Own presentation. Simulation and poses come from the external research backend.

var auto_start: bool = true
var automatic_simulation: bool = true
var game_root: String = OS.get_environment("TIMEBUSTERS_DATA")
var loaded: bool = false
var last_error: String = ""
var last_frame: Dictionary = {}
var scene_info: Dictionary = {}
var bridge: RefCounted
var manual_steps: int = 0
var physics_callbacks: int = 0
var cooperative: bool = false
var simulation_paused: bool = false
var _save_button: Button
var _checkpoint_hint: Label
var _resume_warning: String = ""
var _active_slot := "slot1"
var has_input_focus: bool = true
const CAMPAIGN_START_LEVEL := "CCINTRO"
const NativeOverlayScript = preload("res://reference/native_overlay.gd")
const NativeHudSpritesScript = preload("res://reference/native_hud_sprites.gd")
const NativeAudioScript = preload("res://reference/native_audio.gd")
const NativeBackdropScript = preload("res://reference/native_backdrop.gd")
const PcTranslucency = preload("res://reference/pc_translucency.gd")
const NativeEffectsScript = preload("res://reference/native_effects.gd")
const CameraObstruction = preload("res://reference/camera_obstruction.gd")
const WORLD_NEAR_CLIP := 0.03
const LEGACY_FAR_CLIP := 1000.0
const AssetLayoutScript = preload("res://reference/asset_layout.gd")
const CheckpointStoreScript = preload("res://reference/checkpoint_store.gd")
var checkpoint_store = CheckpointStoreScript.new()
var checkpoint_directory: String:
	get:
		return checkpoint_store.save_directory
	set(value):
		checkpoint_store.save_directory = value
var session_notice: String = ""
var _session_generation: int = -1
var _extension: GDExtension
var _world: Node3D
var _world_zone_meshes: Dictionary = {}
var _drawn_world_zones: PackedInt32Array
var _texture_link_indices: PackedInt32Array
var _linked_world_materials: Array[Dictionary] = []
var _actors: Node3D
var _native_effects
var _sky: Node3D
var _backdrop
var _camera: Camera3D
var _textures: Array[Texture2D] = []
var _materials: Dictionary = {}
var _pc_texture_variants: Dictionary = {}
var _actor_nodes: Dictionary = {}
var _geometry_cache: Dictionary = {}
var _native_audio
var native_audio_enabled: bool = OS.get_environment("TIMEBUSTERS_NATIVE_AUDIO") != "0"
var _speech_player: AudioStreamPlayer
var _speech_key: String = ""
var _status: Label
var _root_edit: LineEdit
var _levels: OptionButton
var _languages: OptionButton
var _pause_button: Button
var _coop_button: CheckButton
var _host_panel: PanelContainer
var _panel_toggle: Button
var _hud: Label
var _fade_multiply: CanvasItemMaterial
var _actions: Array[String] = []
var _native_overlay
var _native_hud_sprites
var _fade: ColorRect
var _top_bar: ColorRect
var _bottom_bar: ColorRect

const BUTTONS := {"up":0x1000, "right":0x2000, "down":0x4000, "left":0x8000,
	"cross":0x40, "square":0x80, "circle":0x20, "triangle":0x10,
	"switch":0x08, "call":0x04, "l2":0x01, "r2":0x02, "pause":0x800}

func _ready() -> void:
	var bundled := AssetLayoutScript.is_bundled()
	if bundled or game_root.is_empty():
		game_root = AssetLayoutScript.default_data_root()
	Engine.max_fps = 60
	_world = Node3D.new()
	_world.name = "OriginalWorld"
	add_child(_world)
	_sky = Node3D.new()
	_sky.name = "OriginalSky"
	add_child(_sky)
	_actors = Node3D.new()
	_actors.name = "OriginalActors"
	add_child(_actors)
	_native_effects = NativeEffectsScript.new()
	_native_effects.name = "OriginalEffects"
	add_child(_native_effects)
	_native_effects.configure(_make_instance, _make_mesh, _material, _same_geometry)
	_camera = Camera3D.new()
	_camera.name = "GameCamera"
	_camera.current = true
	_camera.near = WORLD_NEAR_CLIP
	_camera.far = LEGACY_FAR_CLIP
	_camera.fov = 60.0
	add_child(_camera)
	_backdrop = NativeBackdropScript.new()
	_backdrop.name = "NativeBackdrop"
	add_child(_backdrop)
	_backdrop.configure(_camera)
	_native_audio = NativeAudioScript.new()
	add_child(_native_audio)
	_speech_player = AudioStreamPlayer.new()
	_speech_player.volume_linear = 1.0
	add_child(_speech_player)
	_native_audio.bind_speech(_speech_player)
	_create_ui()
	_setup_input()
	var initial_level: String = CAMPAIGN_START_LEVEL
	var initial_language: String = "RU"
	var continue_saved: bool = false
	var continue_slot := ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--data-root=") and not bundled:
			game_root = arg.trim_prefix("--data-root=")
		elif arg.begins_with("--level="):
			initial_level = arg.trim_prefix("--level=").to_upper()
		elif arg.begins_with("--language="):
			initial_language = arg.trim_prefix("--language=").to_upper()
		elif arg == "--continue":
			continue_saved = true
		elif arg.begins_with("--slot="):
			continue_slot = arg.trim_prefix("--slot=")
	_root_edit.text = game_root
	_root_edit.editable = not bundled
	_refresh_levels()
	if auto_start:
		if continue_saved:
			if continue_slot.is_empty():
				continue_slot = checkpoint_store.newest_numbered_slot()
			load_checkpoint(continue_slot)
		else:
			start_level(initial_level, initial_language)

func _create_ui() -> void:
	var overlay := CanvasLayer.new()
	add_child(overlay)
	var gui := Control.new()
	gui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	gui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(gui)
	_fade = ColorRect.new()
	_fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade.color = Color(0,0,0,0)
	_fade_multiply = CanvasItemMaterial.new()
	_fade_multiply.blend_mode = CanvasItemMaterial.BLEND_MODE_MUL
	gui.add_child(_fade)
	_top_bar = ColorRect.new()
	_top_bar.color = Color.BLACK
	_top_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gui.add_child(_top_bar)
	_bottom_bar = ColorRect.new()
	_bottom_bar.color = Color.BLACK
	_bottom_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gui.add_child(_bottom_bar)
	_native_hud_sprites = NativeHudSpritesScript.new()
	_native_hud_sprites.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	gui.add_child(_native_hud_sprites)
	# Native text sits above the HUD-sheet artwork, including the credits backdrop.
	_native_overlay = NativeOverlayScript.new()
	_native_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	gui.add_child(_native_overlay)
	# Native order: bars/boxes/text first, then multiply fade; host controls above.
	gui.move_child(_fade, gui.get_child_count() - 1)
	var panel := PanelContainer.new()
	_host_panel = panel
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	panel.offset_bottom = 110
	gui.add_child(panel)
	_panel_toggle = Button.new()
	_panel_toggle.focus_mode = Control.FOCUS_NONE
	_panel_toggle.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_panel_toggle.offset_left = -150
	_panel_toggle.offset_right = -8
	_panel_toggle.offset_top = 3
	_panel_toggle.offset_bottom = 29
	_panel_toggle.text = "Скрыть · F10"
	_panel_toggle.tooltip_text = "Панель: F10. Игровая пауза: P. Сохранение: F5."
	_panel_toggle.pressed.connect(_on_host_panel_toggle)
	gui.add_child(_panel_toggle)
	var margin := MarginContainer.new()
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	panel.add_child(margin)
	var column := VBoxContainer.new()
	margin.add_child(column)
	var title := Label.new()
	title.text = "Time Busters · Меню: Enter/Space — выбор, Esc/R — назад"
	column.add_child(title)
	var row := HBoxContainer.new()
	column.add_child(row)
	_levels = OptionButton.new()
	_levels.custom_minimum_size.x = 160
	_levels.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_levels)
	_languages = OptionButton.new()
	_languages.add_item("RU")
	_languages.add_item("EN")
	row.add_child(_languages)
	var new_game_button := Button.new()
	new_game_button.text = "Новая игра"
	new_game_button.pressed.connect(_on_new_campaign_pressed)
	row.add_child(new_game_button)
	var load_button := Button.new()
	load_button.text = "Открыть ресурс"
	load_button.tooltip_text = "Отладочный запуск выбранного ресурса с новым прогрессом."
	load_button.pressed.connect(_on_load_pressed)
	row.add_child(load_button)
	var restart_button := Button.new()
	restart_button.text = "Сбросить уровень"
	restart_button.tooltip_text = "Заново открыть текущий уровень без накопленного прогресса."
	restart_button.pressed.connect(_on_restart_pressed)
	row.add_child(restart_button)
	_coop_button = CheckButton.new()
	_coop_button.text = "Два игрока"
	_coop_button.toggled.connect(set_coop)
	row.add_child(_coop_button)
	_pause_button = Button.new()
	_pause_button.text = "Пауза"
	_pause_button.toggle_mode = true
	_pause_button.toggled.connect(_on_pause_toggled)
	row.add_child(_pause_button)
	var session_row := HBoxContainer.new()
	column.add_child(session_row)
	for spec: Array in [["Повторить уровень", _on_reload_pressed], ["Сохранить · F5", _on_save_pressed], ["Продолжить · F9", _on_restore_pressed]]:
		var button := Button.new()
		button.text = spec[0]
		if str(spec[0]).begins_with("Сохранить"):
			_save_button = button
		button.pressed.connect(spec[1])
		session_row.add_child(button)
	_checkpoint_hint = Label.new()
	_checkpoint_hint.text = "Игровая пауза: P → F5. Возврат к входу на уровень."
	_checkpoint_hint.add_theme_font_size_override("font_size", 13)
	session_row.add_child(_checkpoint_hint)
	var path_row := HBoxContainer.new()
	column.add_child(path_row)
	var path_label := Label.new()
	path_label.text = "Данные:"
	path_row.add_child(path_label)
	_root_edit = LineEdit.new()
	_root_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_row.add_child(_root_edit)
	_status = Label.new()
	_hud = Label.new()
	for label: Label in [_status, _hud]:
		label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
		label.offset_left = 8.0
		label.offset_right = -8.0
		label.offset_top = -8.0
		label.offset_bottom = -8.0
		label.grow_vertical = Control.GROW_DIRECTION_BEGIN
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		gui.add_child(label)
		label.minimum_size_changed.connect(_layout_host_footer)
	_status.text = "WASD/стрелки: движение · Space: прыжок · F/E/R: действия · Tab: смена · Q: позвать · Z/C: камера/вид от лица · Esc: пропуск речи"
	_hud.add_theme_color_override("font_shadow_color", Color.BLACK)
	_hud.add_theme_constant_override("shadow_offset_x", 1)
	_hud.add_theme_constant_override("shadow_offset_y", 1)
	gui.resized.connect(_layout_host_footer)
	_layout_host_footer()
	for button: Node in gui.find_children("*", "BaseButton", true, false):
		(button as Control).focus_mode = Control.FOCUS_NONE

func _layout_host_footer() -> void:
	var hud_bottom := _status.offset_bottom - _status.get_combined_minimum_size().y - 4.0
	_hud.offset_bottom = hud_bottom
	_hud.offset_top = hud_bottom
	if not loaded:
		return
	var footer_height := maxf(70.0, -hud_bottom + _hud.get_combined_minimum_size().y)
	var bottom_text: bool = _native_overlay.covers_bottom(footer_height)
	var session: Dictionary = last_frame.get("session", {})
	_hud.visible = not bottom_text and not _native_hud_sprites.covers_bottom(footer_height)
	_status.visible = not bottom_text or not str(session.get("transition_error", "")).is_empty() or session.get("quit_requested", false)

func set_host_panel_visible(value: bool) -> void:
	if not is_instance_valid(_host_panel):
		return
	if not value:
		var focus: Control = get_viewport().gui_get_focus_owner()
		if focus != null and _host_panel.is_ancestor_of(focus):
			focus.release_focus()
	_host_panel.visible = value
	_panel_toggle.text = "Скрыть · F10" if value else "Панель · F10"

func _on_host_panel_toggle() -> void:
	set_host_panel_visible(not _host_panel.visible)

func _input(event: InputEvent) -> void:
	if has_input_focus and event is InputEventKey and event.pressed and not event.echo and (event.keycode == KEY_F10 or event.physical_keycode == KEY_F10):
		_on_host_panel_toggle()
		get_viewport().set_input_as_handled()

func _ensure_bridge() -> bool:
	if bridge != null:
		_sync_key_prompt_names()
		return true
	_extension = load("res://native/tb_reference.gdextension") as GDExtension
	if _extension == null or not _extension.is_library_open() or not ClassDB.class_exists("TbReferenceBridge"):
		_show_error("Игровой модуль не загружен. Проверьте локальную сборку расширения.")
		return false
	bridge = ClassDB.instantiate("TbReferenceBridge") as RefCounted
	if bridge == null:
		_show_error("Не удалось создать игровой мир.")
		return false
	if not bridge.has_method("set_audio_output_enabled"):
		_show_error("Нужна текущая версия игрового модуля с выводом звука.")
		return false
	_sync_key_prompt_names()
	var output: Dictionary = bridge.call("set_audio_output_enabled", native_audio_enabled)
	_native_audio.consume_packets(output.get("audio_output", []))
	return true

func _refresh_levels() -> void:
	_levels.clear()
	var names: Array[String] = []
	var directory := DirAccess.open(game_root.path_join("BZE"))
	if directory != null:
		for file: String in directory.get_files():
			if file.get_extension().to_lower() in ["bze", "bzr"]:
				var level := file.get_basename().to_upper()
				if level not in names:
					names.append(level)
	names.sort()
	if names.is_empty():
		names.assign(["GRANNY", "ARCA01"])
	for name_value: String in names:
		_levels.add_item(name_value)

func start_new_campaign(language: String = "RU") -> bool:
	clear_input_focus()
	restore_input_focus()
	_set_local_pause(false)
	return start_level(CAMPAIGN_START_LEVEL, language)

func start_level(level: String, language: String) -> bool:
	_resume_warning = ""
	_active_slot = "slot1"
	_clear_world()
	manual_steps = 0
	physics_callbacks = 0
	last_error = ""
	session_notice = ""
	if not _ensure_bridge():
		return false
	var result: Dictionary = bridge.call("load_level", game_root, level, language)
	_native_audio.consume_packets(result.get("audio_output", []))
	if not result.get("ok", false):
		_show_error(str(result.get("error", result)))
		return false
	if not bridge.has_method("set_session_enabled"):
		_show_error("Нужна текущая локальная сборка игрового модуля с поддержкой сохранений.")
		return false
	bridge.call("set_session_enabled", true)
	return _install_loaded_world(true)

func _install_loaded_world(apply_preferred_coop: bool = false) -> bool:
	scene_info = bridge.call("get_scene")
	if not scene_info.get("ok", false) or scene_info.get("placeholder", true):
		_show_error("Ресурсы исходного уровня не подтверждены.")
		return false
	for spec: Dictionary in scene_info.get("textures", []):
		var width: int = int(spec.get("width", 0))
		var height: int = int(spec.get("height", 0))
		var rgba: PackedByteArray = spec.get("rgba", PackedByteArray())
		if width < 1 or height < 1 or rgba.size() != width * height * 4:
			_show_error("Повреждены размеры текстуры исходного уровня.")
			_clear_world()
			return false
		var image := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, rgba)
		_textures.append(ImageTexture.create_from_image(image))
	_native_overlay.configure_scene(scene_info, _textures)
	_native_hud_sprites.configure_scene(scene_info, _textures)
	for mesh_data: Dictionary in scene_info.get("static_meshes", []):
		var instance := _make_instance(mesh_data, false)
		if instance == null:
			_show_error("Недопустимая геометрия уровня.")
			_clear_world()
			return false
		_world.add_child(instance)
		_track_texture_link(instance, mesh_data, false)
		var zone: int = int(mesh_data.get("zone", -1))
		if zone > 0:
			if not _world_zone_meshes.has(zone):
				_world_zone_meshes[zone] = []
			_world_zone_meshes[zone].append(instance)
	var authored_far: float = float(scene_info.get("world_far_clip", 0.0))
	_camera.far = authored_far if authored_far > _camera.near else LEGACY_FAR_CLIP
	var backdrop_far: float = _camera.far
	for mesh_data: Dictionary in scene_info.get("sky_meshes", []):
		var instance := _make_instance(mesh_data, true)
		if instance == null:
			continue
		_backdrop.prepare_mesh(instance)
		_sky.add_child(instance)
		_track_texture_link(instance, mesh_data, true)
		backdrop_far = maxf(backdrop_far, float(mesh_data.get("far_clip", 0.0)))
	_backdrop.set_active(_sky.get_child_count() > 0, backdrop_far)
	loaded = true
	for index: int in range(_levels.item_count):
		if _levels.get_item_text(index) == str(scene_info.get("level", "")).to_upper():
			_levels.select(index)
	_languages.select(1 if str(scene_info.get("language", "RU")) == "EN" else 0)
	if apply_preferred_coop and cooperative:
		bridge.call("set_coop", true)
	last_frame = bridge.call("get_frame")
	cooperative = bool(last_frame.get("coop", false))
	_coop_button.set_pressed_no_signal(cooperative)
	_session_generation = int(last_frame.get("session", {}).get("generation", -1))
	_present(last_frame)
	get_viewport().gui_release_focus()
	_update_status()
	return true

func _clear_world() -> void:
	loaded = false
	if is_instance_valid(_native_audio):
		_native_audio.clear_sfx()
	last_frame = {}
	scene_info = {}
	_speech_key = ""
	if is_instance_valid(_speech_player):
		_speech_player.stop()
	for parent: Node3D in [_world, _actors, _sky]:
		if not is_instance_valid(parent):
			continue
		for child: Node in parent.get_children():
			parent.remove_child(child)
			child.queue_free()
	if is_instance_valid(_native_overlay):
		_native_overlay.clear_overlay()
	if is_instance_valid(_native_hud_sprites):
		_native_hud_sprites.clear_overlay()
	_native_effects.clear_effects()
	_world_zone_meshes.clear()
	_texture_link_indices = PackedInt32Array()
	_linked_world_materials.clear()
	_drawn_world_zones = PackedInt32Array()
	_actor_nodes.clear()
	_geometry_cache.clear()
	_materials.clear()
	_pc_texture_variants.clear()
	_textures.clear()
	_backdrop.set_active(false, LEGACY_FAR_CLIP)
	if is_instance_valid(_fade):
		_fade.material = null
		_fade.color.a = 0.0
		_fade.visible = true
	if is_instance_valid(_hud):
		_hud.text = ""
		_hud.visible = true
	if is_instance_valid(_status):
		_status.visible = true

func _make_instance(data: Dictionary, background: bool) -> MeshInstance3D:
	var mesh := _make_mesh(data)
	if mesh == null:
		return null
	var instance := MeshInstance3D.new()
	var mesh_name: String = str(data.get("name", "Mesh")).validate_node_name()
	instance.name = "Mesh" if mesh_name.is_empty() else mesh_name
	instance.mesh = mesh
	instance.material_override = _material(data, background)
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance

func _make_mesh(data: Dictionary) -> ArrayMesh:
	var vertices: PackedVector3Array = data.get("vertices", PackedVector3Array())
	var indices: PackedInt32Array = data.get("indices", PackedInt32Array())
	if vertices.is_empty() or indices.is_empty() or indices.size() % 3 != 0:
		return null
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices
	var uvs: PackedVector2Array = data.get("uvs", PackedVector2Array())
	var colors: PackedColorArray = data.get("colors", PackedColorArray())
	if uvs.size() == vertices.size():
		arrays[Mesh.ARRAY_TEX_UV] = uvs
	if colors.size() == vertices.size():
		arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

func _material(data: Dictionary, _background: bool) -> StandardMaterial3D:
	var texture_index: int = int(data.get("texture", -1))
	var link: int = int(data.get("texture_anim", -1))
	if link >= 0 and link < _texture_link_indices.size() and _texture_link_indices[link] >= 0:
		texture_index = _texture_link_indices[link]
	var blend: int = int(data.get("blend", 0))
	var two_sided: bool = bool(data.get("two_sided", false))
	var pc_variant: int = int(data.get("pc_texture_variant", -1))
	var key: String = "%d:%d:%d:%s" % [texture_index, blend, pc_variant, two_sided]
	if _materials.has(key):
		return _materials[key]
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.vertex_color_is_srgb = false
	material.cull_mode = BaseMaterial3D.CULL_DISABLED if two_sided else BaseMaterial3D.CULL_BACK
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	var texture_has_alpha: bool = false
	if texture_index >= 0 and texture_index < _textures.size():
		material.albedo_texture = _textures[texture_index]
		texture_has_alpha = bool(scene_info["textures"][texture_index].get("has_alpha", false))
	if blend == 1 or (blend == 0 and texture_has_alpha):
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		material.alpha_scissor_threshold = 0.1
	elif blend >= 2:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		if pc_variant >= 0 and material.albedo_texture != null:
			material.albedo_texture = _pc_variant_texture(texture_index, pc_variant)
		elif blend == 3:
			material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		elif blend == 4:
			material.blend_mode = BaseMaterial3D.BLEND_MODE_SUB
	material.set_meta("native_texture_slot", texture_index)
	material.set_meta("pc_texture_variant", pc_variant)
	_materials[key] = material
	return material

func _pc_variant_texture(slot: int, mode: int) -> Texture2D:
	var key := Vector2i(slot, mode)
	if not _pc_texture_variants.has(key):
		var spec: Dictionary = scene_info["textures"][slot]
		var input := spec.duplicate()
		if spec.has("pc_raw_rgba"):
			input["rgba"] = spec["pc_raw_rgba"]
		var variant: ImageTexture = PcTranslucency.make_texture(input, mode)
		_pc_texture_variants[key] = variant if variant != null else _textures[slot]
	return _pc_texture_variants[key]


func _track_texture_link(instance: MeshInstance3D, data: Dictionary, background: bool) -> void:
	if int(data.get("texture_anim", -1)) >= 0:
		_linked_world_materials.append({"instance":instance, "data":data, "background":background})


func _present_texture_links(indices: PackedInt32Array) -> bool:
	if _texture_link_indices == indices:
		return false
	_texture_link_indices = indices
	for entry: Dictionary in _linked_world_materials:
		var instance: MeshInstance3D = entry.instance
		instance.material_override = _material(entry.data, entry.background)
	return true


func _present_world_zones(draw_zones: PackedInt32Array) -> void:
	if _world_zone_meshes.size() < 2:
		return
	# The native first draw zone is the camera's authored territory.
	# During an unclassified frame the scene uses its conservative full view.
	var selected := draw_zones
	if not selected.is_empty() and not _world_zone_meshes.has(selected[0]):
		selected = PackedInt32Array()
	if selected == _drawn_world_zones:
		return
	_drawn_world_zones = selected
	for zone: int in _world_zone_meshes:
		var shown: bool = selected.is_empty() or selected.has(zone)
		for instance: MeshInstance3D in _world_zone_meshes[zone]:
			instance.visible = shown


func _present(frame: Dictionary) -> void:
	_native_overlay.set_native_frame(frame.get("overlay", {}))
	_native_hud_sprites.set_native_frame(frame.get("overlay", {}))
	if not frame.get("ok", false):
		return
	var camera: Dictionary = frame.get("camera", {})
	var eye: Vector3 = camera.get("eye", Vector3.ZERO)
	var look: Vector3 = camera.get("look", Vector3.FORWARD)
	if eye.is_finite() and look.is_finite() and eye.distance_squared_to(look) > 0.00001:
		_camera.position = eye
		var up := Vector3.UP
		var view := (look - eye).normalized()
		if view.cross(up) == Vector3.ZERO:
			var right: Vector3 = _camera.global_transform.basis.x
			right -= view * right.dot(view)
			if not right.is_finite() or right.length_squared() <= 0.000000000001:
				right = Vector3.RIGHT
			up = right.cross(view).normalized()
		_camera.look_at(look, up)
		_camera.near = CameraObstruction.near_plane(_camera, frame, WORLD_NEAR_CLIP)
		_sky.position = eye
		_backdrop.follow()
	_present_world_zones(frame.get("world_draw_zones", PackedInt32Array()))
	var links_changed := _present_texture_links(frame.get("texture_links", PackedInt32Array()))
	var seen: Dictionary = {}
	for actor: Dictionary in frame.get("actors", []):
		var uid: int = int(actor.get("uid", -1))
		seen[uid] = true
		var node: Node3D = _actor_nodes.get(uid)
		if node == null:
			node = Node3D.new()
			node.name = "Actor_%d" % uid
			_actors.add_child(node)
			_actor_nodes[uid] = node
		var meshes: Array = actor.get("meshes", [])
		node.visible = bool(actor.get("visible", false)) and not meshes.is_empty()
		for index: int in range(meshes.size()):
			var data: Dictionary = meshes[index]
			var cache_key: String = "%d:%d" % [uid, index]
			var instance: MeshInstance3D
			if index >= node.get_child_count():
				instance = _make_instance(data, false)
				if instance == null:
					continue
				node.add_child(instance)
			else:
				instance = node.get_child(index) as MeshInstance3D
			var previous: Dictionary = _geometry_cache.get(cache_key, {})
			if previous.is_empty() or not _same_geometry(previous, data):
				instance.mesh = _make_mesh(data)
				instance.material_override = _material(data, false)
				_geometry_cache[cache_key] = data
			elif links_changed and int(data.get("texture_anim", -1)) >= 0:
				instance.material_override = _material(data, false)
		for index: int in range(node.get_child_count() - 1, meshes.size() - 1, -1):
			var excess := node.get_child(index)
			node.remove_child(excess)
			excess.queue_free()
	for uid: Variant in _actor_nodes.keys():
		if not seen.has(uid):
			var vanished: Node = _actor_nodes[uid]
			_actors.remove_child(vanished)
			vanished.queue_free()
			_actor_nodes.erase(uid)
	_native_effects.present(frame.get("effects_meshes", []))
	var dark: float = clampf(float(frame.get("fade_dark", 0)) / 4096.0, 0.0, 1.0)
	var source_fade: Dictionary = frame.get("visual", {}).get("fade", {})
	var overlay: PackedByteArray = source_fade.get("overlay_rgba8", PackedByteArray())
	if overlay.size() == 4:
		# Native overlay RGB is a per-channel multiplier; A only switches the effect on.
		_fade.material = _fade_multiply
		_fade.color = Color8(overlay[0], overlay[1], overlay[2], 255)
		_fade.visible = overlay[3] != 0
	else:
		_fade.material = null
		_fade.color = Color(0, 0, 0, dark)
		_fade.visible = true
	var bars: float = absf(float(frame.get("bars", 0)))
	var size := get_viewport().get_visible_rect().size
	var bar_height: float = size.y * bars / 120.0
	_top_bar.size = Vector2(size.x, bar_height)
	_bottom_bar.position = Vector2(0, size.y - bar_height)
	_bottom_bar.size = Vector2(size.x, bar_height)

func _same_geometry(before: Dictionary, after: Dictionary) -> bool:
	for key: String in ["vertices", "indices", "uvs", "colors", "texture", "texture_anim", "blend", "pc_texture_variant", "two_sided"]:
		if before.get(key) != after.get(key):
			return false
	return true

func _sync_speech(speech: Dictionary) -> void:
	var pcm: PackedByteArray = speech.get("pcm_s16le", PackedByteArray())
	if not native_audio_enabled or not speech.get("playing", false) or pcm.is_empty():
		_speech_player.stop()
		_speech_key = ""
		return
	var key: String = "%s:%s" % [speech.get("source_path", ""), speech.get("clip", -1)]
	if key != _speech_key:
		_speech_player.stop()
		var wave := AudioStreamWAV.new()
		wave.format = AudioStreamWAV.FORMAT_16_BITS
		wave.mix_rate = int(speech.get("sample_rate", 44100))
		wave.stereo = int(speech.get("channels", 1)) == 2
		wave.data = pcm
		_speech_player.stream = wave
		_speech_player.play()
		_speech_key = key
	_speech_player.stream_paused = simulation_paused

func advance_frame(p1_buttons: int = 0, p2_buttons: int = 0) -> Dictionary:
	manual_steps += 1
	return _advance_native(p1_buttons, p2_buttons)

func _advance_native(p1_buttons: int, p2_buttons: int) -> Dictionary:
	if not loaded or bridge == null:
		return {"ok":false, "error":"No loaded world"}
	var frame: Dictionary = bridge.call("step", p1_buttons, p2_buttons)
	_native_audio.consume_packets(frame.get("audio_output", []))
	if not frame.get("ok", false):
		if frame.get("loaded", false) and (frame.get("blocked", false) or frame.get("quit_requested", false)):
			# A recoverable host request must not discard the retained native world.
			last_frame = bridge.call("get_frame")
			session_notice = str(frame.get("error", "Сессия ожидает выбора действия."))
			_set_local_pause(true)
			_update_status()
			return frame
		_clear_world()
		_show_error(str(frame.get("error", "Simulation failed")))
		return frame
	var generation: int = int(frame.get("session", {}).get("generation", _session_generation))
	if generation != _session_generation:
		_clear_world()
		if not _install_loaded_world():
			return {"ok":false, "error":last_error}
		session_notice = "Уровень загружен. Для сохранения: игровая пауза P, затем F5."
	last_frame = frame
	_present(frame)
	var session: Dictionary = frame.get("session", {})
	if not str(session.get("transition_error", "")).is_empty():
		session_notice = "Переход остановлен: " + str(session.transition_error)
		_set_local_pause(true)
	elif session.get("quit_requested", false):
		session_notice = "Игра вернулась в меню. Продолжите сохранение или начните заново."
		_set_local_pause(true)
	elif session.get("save_requested", 0) != 0 and not session.get("transition_pending", false):
		var saved := false
		if session.get("save_requested") == CheckpointStoreScript.AUTHORED_SAVE_REQUEST:
			var result: Dictionary = checkpoint_store.save_progress(game_root, scene_info, frame, _active_slot, true)
			_present_checkpoint_result(result)
			saved = bool(result.get("ok", false))
		bridge.call("ack_save_request", saved)
		last_frame = bridge.call("get_frame")
	_update_status()
	return frame

func _physics_process(_delta: float) -> void:
	physics_callbacks += 1
	if automatic_simulation and has_input_focus:
		if Input.is_action_just_pressed("tb_save_checkpoint") and _gameplay_input_allowed():
			save_checkpoint("")
			return
		if Input.is_action_just_pressed("tb_load_checkpoint"):
			load_checkpoint(checkpoint_store.newest_numbered_slot())
			return
	if not automatic_simulation or not loaded or simulation_paused:
		return
	if Input.is_action_just_pressed("tb_skip_speech") and _gameplay_input_allowed() and not is_native_menu_active():
		request_speech_skip()
	_advance_native(get_input_mask(0), get_input_mask(1))

func request_speech_skip() -> Dictionary:
	if bridge == null or not loaded:
		return {"ok":false, "error":"No loaded world"}
	return bridge.call("skip_speech")

func set_coop(enabled: bool) -> void:
	cooperative = enabled
	if bridge != null and loaded:
		bridge.call("set_coop", enabled)
		last_frame = bridge.call("get_frame")
		_present(last_frame)

func _bind_action(action: String, keys: Array) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	_actions.append(action)
	for code: int in keys:
		var event := InputEventKey.new()
		event.physical_keycode = code
		if not InputMap.action_has_event(action, event):
			InputMap.action_add_event(action, event)

func _sync_key_prompt_names() -> void:
	if not bridge.has_method("set_key_prompt_names"):
		return
	# Native HUD order is Square, Circle, Triangle, Cross, L1, L2, R1, R2,
	# Select, Start, Left, Right, Up, Down, F4. Unwired controls keep their defaults.
	var actions := ["square", "circle", "triangle", "cross", "call", "l2",
		"switch", "r2", "", "pause", "left", "right", "up", "down", ""]
	var player_names: Array[PackedStringArray] = []
	for prefix: String in ["tb_p1_", "tb_p2_"]:
		var names := PackedStringArray()
		for action: String in actions:
			var label := ""
			if not action.is_empty() and InputMap.has_action(prefix + action):
				for event in InputMap.action_get_events(prefix + action):
					if event is InputEventKey and event.physical_keycode != 0:
						label = OS.get_keycode_string(event.physical_keycode).to_lower()
						break
			names.append(label)
		player_names.append(names)
	bridge.call("set_key_prompt_names", player_names[0], player_names[1])


func _setup_input() -> void:
	var p1 := {"up":[KEY_W], "down":[KEY_S], "left":[KEY_A], "right":[KEY_D],
		"cross":[KEY_SPACE, KEY_ENTER], "square":[KEY_F], "circle":[KEY_E], "triangle":[KEY_R],
		"switch":[KEY_TAB], "call":[KEY_Q], "l2":[KEY_Z], "r2":[KEY_C], "pause":[KEY_P]}
	var p2 := {"up":[KEY_UP], "down":[KEY_DOWN], "left":[KEY_LEFT], "right":[KEY_RIGHT],
		"cross":[KEY_KP_0], "square":[KEY_KP_1], "circle":[KEY_KP_2], "triangle":[KEY_KP_3], "l2":[KEY_KP_4], "r2":[KEY_KP_6]}
	var solo := {"up":[KEY_UP], "down":[KEY_DOWN], "left":[KEY_LEFT], "right":[KEY_RIGHT]}
	for key: String in p1:
		_bind_action("tb_p1_" + key, p1[key])
	for key: String in p2:
		_bind_action("tb_p2_" + key, p2[key])
	for key: String in solo:
		_bind_action("tb_solo_" + key, solo[key])
	_bind_action("tb_skip_speech", [KEY_ESCAPE])
	_bind_action("tb_save_checkpoint", [KEY_F5])
	_bind_action("tb_load_checkpoint", [KEY_F9])

func is_native_menu_active() -> bool:
	var source_state: PackedByteArray = last_frame.get("script_state", PackedByteArray())
	# Native S[9]: 1 is paused/menu; 2 requests the native resume handshake.
	return source_state.size() > 9 and source_state[9] != 0

func _gameplay_input_allowed() -> bool:
	return has_input_focus and loaded and not simulation_paused and not (get_viewport().gui_get_focus_owner() is LineEdit) and not _levels.get_popup().visible and not _languages.get_popup().visible

func get_input_mask(player: int) -> int:
	if not _gameplay_input_allowed():
		return 0
	if player == 1 and not cooperative:
		return 0
	var mask: int = 0
	var prefix: String = "tb_p1_" if player == 0 else "tb_p2_"
	for key: String in BUTTONS:
		var action: String = prefix + key
		if InputMap.has_action(action) and Input.is_action_pressed(action):
			mask |= int(BUTTONS[key])
		if player == 0 and not cooperative and key in ["up", "down", "left", "right"]:
			if Input.is_action_pressed("tb_solo_" + key):
				mask |= int(BUTTONS[key])
	if player == 0 and is_native_menu_active() and Input.is_action_pressed("tb_skip_speech"):
		mask |= int(BUTTONS.triangle)
	return mask

func clear_input_focus() -> void:
	has_input_focus = false
	for action: String in _actions:
		Input.action_release(action)

func restore_input_focus() -> void:
	has_input_focus = true

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		clear_input_focus()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		restore_input_focus()

func _on_new_campaign_pressed() -> void:
	game_root = _root_edit.text.strip_edges()
	_refresh_levels()
	start_new_campaign(_languages.get_item_text(_languages.selected))

func _on_load_pressed() -> void:
	game_root = _root_edit.text.strip_edges()
	var level: String = _levels.get_item_text(_levels.selected)
	var language: String = _languages.get_item_text(_languages.selected)
	_refresh_levels()
	start_level(level, language)

func _on_restart_pressed() -> void:
	if loaded:
		start_level(str(scene_info.get("level", "GRANNY")), str(scene_info.get("language", "RU")))

func _on_reload_pressed() -> void:
	restart_level_with_progress()

func restart_level_with_progress() -> Dictionary:
	if bridge == null or not loaded:
		return {"ok":false, "error":"Нет загруженного уровня."}
	var result: Dictionary = bridge.call("request_reload")
	session_notice = "Повтор уровня с сохранением прогресса." if result.get("ok", false) else str(result.get("error", "Ошибка повтора уровня."))
	_set_local_pause(false)
	get_viewport().gui_release_focus()
	return result

func _on_save_pressed() -> void:
	save_checkpoint("")

func _on_restore_pressed() -> void:
	load_checkpoint(checkpoint_store.newest_numbered_slot())

func save_checkpoint(slot: String = "slot1") -> Dictionary:
	if not loaded or bridge == null:
		return {"ok":false, "error":"Нет активной игры для сохранения."}
	# A blank slot is the frontend shortcut for saving the current session.
	var active_write := slot.is_empty()
	var target := _active_slot if active_write else slot
	var result: Dictionary = checkpoint_store.save_progress(game_root, scene_info, bridge.call("get_frame"), target, false, active_write)
	_present_checkpoint_result(result)
	return result

func _present_checkpoint_result(result: Dictionary) -> void:
	session_notice = "Прогресс сохранён. Продолжение начнётся у входа на уровень." if result.get("ok", false) else "Сохранение: " + str(result.get("error", "Ошибка записи."))
	if result.get("ok", false):
		_resume_warning = ""
		var slot := str(result.get("slot", ""))
		if checkpoint_store.numbered_slot_index(slot) > 0:
			_active_slot = slot
	get_viewport().gui_release_focus()
	_update_status()

func validate_native_entry(payload: PackedByteArray, frame: Dictionary) -> Dictionary:
	# Read-only assertions: the sealed input goes unchanged to the native constructor.
	var entry: Variant = frame.get("native_entry")
	if payload.size() != 0x300 or not entry is Dictionary:
		return {"ok":false, "error":"Не подтверждён штатный этап загрузки сохранения."}
	if entry.get("policy") != "original-4395d0-level-entry-v1" or entry.get("stage") != "constructor_complete_before_first_vm_tick" or entry.get("source_kind") != "sealed_persistent_game_data" or entry.get("external_payload_modified") != false:
		return {"ok":false, "error":"Неизвестный этап инициализации сохранения."}
	var expected := payload.duplicate()
	expected[0x9f] = 0 # Expected copy only; the native load performs original 0x43960f.
	var changes := PackedInt32Array()
	if payload[0x9f] != 0:
		changes.append(0x9f)
	# Original 0x436938 may select the surviving player during the native entry.
	if payload[0xa2] & 1:
		expected[0xa4] |= 4
	elif payload[0xa2] & 2:
		expected[0xa4] &= ~4
	if expected[0xa4] != payload[0xa4]:
		changes.append(0xa4)
	if entry.get("payload_game_data") != payload or entry.get("constructor_game_data") != expected or frame.get("game_data") != expected or entry.get("changed_gd_offsets") != changes or entry.get("camera_script_flags") != 0x40 or frame.get("camera", {}).get("native_flags") != 0x40:
		return {"ok":false, "error":"Состояние загрузки отличается от подтверждённой инициализации."}
	if entry.get("payload_sha256") != checkpoint_store._digest(payload) or entry.get("constructor_sha256") != checkpoint_store._digest(expected):
		return {"ok":false, "error":"Не совпадает контрольная сумма этапа загрузки."}
	return {"ok":true, "policy":entry.policy}

func load_checkpoint(slot: String = "slot1") -> Dictionary:
	var saved: Dictionary = checkpoint_store.load_progress(game_root, slot)
	if not saved.get("ok", false):
		session_notice = "Продолжение: " + str(saved.get("error", "Ошибка чтения."))
		if is_instance_valid(_status):
			_status.text = session_notice
		return saved
	if not _ensure_bridge() or not bridge.has_method("load_saved_level"):
		return {"ok":false, "error":"Нет текущего игрового модуля."}
	var result: Dictionary = bridge.call("load_saved_level", game_root, saved.level, saved.profile, saved.game_data, saved.expected_source_sha256)
	_native_audio.consume_packets(result.get("audio_output", []))
	if not result.get("ok", false):
		_clear_world()
		_show_error(str(result.get("error", "Не удалось продолжить игру.")))
		return result
	var entry_check := validate_native_entry(saved.game_data, bridge.call("get_frame"))
	if not entry_check.get("ok", false):
		_clear_world()
		_show_error(str(entry_check.error))
		return entry_check
	_clear_world()
	bridge.call("set_session_enabled", true)
	manual_steps = 0
	physics_callbacks = 0
	last_error = ""
	_set_local_pause(false)
	if not _install_loaded_world():
		return {"ok":false, "error":last_error}
	if checkpoint_store.numbered_slot_index(slot) > 0:
		_active_slot = slot
	_resume_warning = str(saved.get("resume_safety", {}).get("warning", ""))
	session_notice = "Продолжен сохранённый прогресс. Вы у входа на уровень."
	if not _resume_warning.is_empty():
		session_notice = _resume_warning
	_update_status()
	return {"ok":true, "path":saved.path, "payload":saved.payload, "session":get_session_metrics()}

func get_session_metrics() -> Dictionary:
	if bridge == null or not bridge.has_method("get_session_status"):
		return {"ok":false, "error":"Нет активной сессии."}
	return bridge.call("get_session_status")

func _set_local_pause(paused: bool) -> void:
	_pause_button.set_pressed_no_signal(paused)
	_on_pause_toggled(paused)

func _on_pause_toggled(paused: bool) -> void:
	simulation_paused = paused
	_speech_player.stream_paused = paused
	_native_audio.set_host_hold(paused)
	get_viewport().gui_release_focus()
	_update_status()

func _update_status() -> void:
	if not loaded:
		return
	var notice: String = "%s · %s | WASD/стрелки: движение · Space: прыжок · F/E/R: действия · Tab: смена · Z/C: камера, вместе: вид от лица · Esc: речь" % [scene_info.get("level", ""), scene_info.get("language", "")]
	if simulation_paused:
		notice = "Пауза · " + notice
	if int(last_frame.get("next_level", -1)) >= 0:
		notice = "Переход на следующий уровень…"
	var session: Dictionary = last_frame.get("session", {})
	if not str(session.get("transition_error", "")).is_empty():
		notice = "Переход остановлен: " + str(session.transition_error)
	elif session.get("quit_requested", false):
		notice = "Игра вернулась в меню. Продолжите сохранение или начните заново."
	elif session.get("transition_pending", false):
		notice = "Загрузка: " + str(session.get("target_level", ""))
	elif not session_notice.is_empty():
		notice = session_notice
	if is_instance_valid(_save_button) and is_instance_valid(_checkpoint_hint):
		var eligibility: Dictionary = checkpoint_store.save_eligibility(last_frame)
		_save_button.disabled = not eligibility.get("ok", false)
		_save_button.tooltip_text = "Сохранить прогресс и продолжить со входа на уровень." if eligibility.get("ok", false) else str(eligibility.get("error", ""))
		_checkpoint_hint.text = "Можно сохранить: F5. Возврат к входу на уровень." if eligibility.get("ok", false) else "Игровая пауза: P → F5. Возврат к входу на уровень."
		if not _resume_warning.is_empty():
			_checkpoint_hint.text = "Старое сохранение: продолжение не проверено. Запись: P → F5."
		if simulation_paused and _resume_warning.is_empty():
			_checkpoint_hint.text = "Кнопка сохранения доступна; для F5 снимите паузу окна." if eligibility.get("ok", false) else "Снимите паузу окна; затем P → F5."
		if eligibility.get("code", "") == "camera_guard_unavailable":
			_checkpoint_hint.text = str(eligibility.error)
		_checkpoint_hint.tooltip_text = _resume_warning
	_status.text = notice
	var hud: Dictionary = last_frame.get("hud", {})
	if not hud.is_empty():
		var health: Variant = hud.get("health", PackedInt32Array([0, 0]))
		_hud.text = "Багз: %d/6   Таз: %d/6   Жизни: %d   Морковки: %d   Всего предметов: %d   Предметы уровня: %d   Прогресс: %d%%" % [int(health[0]), int(health[1]), int(hud.get("lives", 0)), int(hud.get("carrots", 0)), int(hud.get("coins", 0)), int(hud.get("level_collectibles", 0)), int(hud.get("completion_percent", 0))]
	_layout_host_footer()

func _show_error(message: String) -> void:
	loaded = false
	last_error = message
	if is_instance_valid(_status):
		_status.text = "Ошибка: " + message
	push_warning(message)

func presentation_metrics() -> Dictionary:
	var player_meshes: Dictionary = {"0":0, "1":0}
	var actor_meshes: int = 0
	for actor: Dictionary in last_frame.get("actors", []):
		var count: int = 0
		var node: Node3D = _actor_nodes.get(int(actor.get("uid", -1)))
		if node != null and node.visible:
			count = node.get_child_count()
		actor_meshes += count
		if int(actor.get("source_id", -1)) == 2:
			player_meshes["0"] = count
		elif int(actor.get("source_id", -1)) == 3:
			player_meshes["1"] = count
	return {"loaded":loaded, "world_meshes":_world.get_child_count(), "sky_meshes":_sky.get_child_count(),
		"textures":_textures.size(), "actor_meshes":actor_meshes, "player_meshes":player_meshes,
		"native_tick":int(last_frame.get("tick",0)), "manual_steps":manual_steps, "physics_callbacks":physics_callbacks,
		"camera_eye":_camera.position, "camera_look":last_frame.get("camera",{}).get("look",Vector3.ZERO),
		"last_error":last_error, "speech_audio_playing":_speech_player.playing,
		"source_sha256":scene_info.get("source_sha256",""), "backend":"external_local_research"}

func capture_viewport(path: String) -> int:
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	if image == null or image.is_empty():
		return ERR_UNAVAILABLE
	return image.save_png(path)

func _process(_delta: float) -> void:
	if bridge == null or not is_instance_valid(_native_audio):
		return
	if loaded:
		_sync_speech(last_frame.get("speech", {}))
		_native_audio.render_latest(bridge)
	else:
		_native_audio.stop_all()

func native_audio_metrics() -> Dictionary:
	if not is_instance_valid(_native_audio):
		return {}
	return {"consumer":_native_audio.metrics(),"transport":bridge.call("get_audio_output_status") if bridge != null else {}}
