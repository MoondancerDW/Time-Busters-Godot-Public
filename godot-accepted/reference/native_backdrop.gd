extends CanvasLayer
## Render the authored backdrop with a private depth buffer, before the world.

const SKY_LAYER := 20
const SKY_MASK := 1 << (SKY_LAYER - 1)
const BACKGROUND_LAYER := -10

var _target: SubViewport
var _camera: Camera3D
var _image: TextureRect
var _black: Environment
var _composite: Environment
var _world_camera: Camera3D
var _world_environment: WorldEnvironment


func configure(world_camera: Camera3D) -> void:
	_world_camera = world_camera
	layer = BACKGROUND_LAYER
	_black = Environment.new()
	_black.background_mode = Environment.BG_COLOR
	_black.background_color = Color.BLACK
	_composite = Environment.new()
	_composite.background_mode = Environment.BG_CANVAS
	_composite.background_canvas_max_layer = BACKGROUND_LAYER
	_world_environment = WorldEnvironment.new()
	_world_environment.name = "NativeWorldEnvironment"
	add_child(_world_environment)

	_target = SubViewport.new()
	_target.name = "BackdropViewport"
	_target.world_3d = _world_camera.get_viewport().find_world_3d()
	add_child(_target)
	_camera = Camera3D.new()
	_camera.name = "BackdropCamera"
	_camera.environment = _black
	_camera.current = true
	_camera.cull_mask = SKY_MASK
	_target.add_child(_camera)
	_world_camera.set_cull_mask_value(SKY_LAYER, false)

	_image = TextureRect.new()
	_image.name = "BackdropImage"
	_image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_image.texture = _target.get_texture()
	add_child(_image)
	_image.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_world_camera.get_viewport().size_changed.connect(_resize)
	_resize()
	set_active(false, _world_camera.far)


func _resize() -> void:
	var size := Vector2i(_world_camera.get_viewport().get_visible_rect().size)
	_target.size = size.max(Vector2i(2, 2))


func prepare_mesh(instance: MeshInstance3D) -> void:
	instance.layers = SKY_MASK


func set_active(active: bool, far_clip: float) -> void:
	_image.visible = active
	_target.render_target_update_mode = SubViewport.UPDATE_ALWAYS if active else SubViewport.UPDATE_DISABLED
	_world_environment.environment = _composite if active else _black
	_camera.far = far_clip


func follow() -> void:
	_camera.near = _world_camera.near
	_camera.fov = _world_camera.fov
	_camera.keep_aspect = _world_camera.keep_aspect
	_camera.global_transform = _world_camera.global_transform
