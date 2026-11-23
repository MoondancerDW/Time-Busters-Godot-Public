extends Node3D
## Pool the rendered meshes supplied by the native effect and shadow queues.

var _instances: Array[MeshInstance3D] = []
var _previous: Array[Dictionary] = []
var _create_instance: Callable
var _build_mesh: Callable
var _get_material: Callable
var _same_geometry: Callable


func configure(create_instance: Callable, build_mesh: Callable, get_material: Callable,
		same_geometry: Callable) -> void:
	_create_instance = create_instance
	_build_mesh = build_mesh
	_get_material = get_material
	_same_geometry = same_geometry


func present(meshes: Array) -> void:
	var drawn := 0
	for data: Dictionary in meshes:
		if drawn == _instances.size():
			var instance: MeshInstance3D = _create_instance.call(data, false)
			if instance == null:
				continue
			add_child(instance)
			_instances.append(instance)
			_previous.append(data)
		else:
			var instance := _instances[drawn]
			if not bool(_same_geometry.call(_previous[drawn], data)):
				instance.mesh = _build_mesh.call(data)
				instance.material_override = _get_material.call(data, false)
				_previous[drawn] = data
			instance.visible = instance.mesh != null
		drawn += 1
	for index: int in range(drawn, _instances.size()):
		_instances[index].hide()


func clear_effects() -> void:
	for instance: MeshInstance3D in _instances:
		remove_child(instance)
		instance.queue_free()
	_instances.clear()
	_previous.clear()
