extends RefCounted
## Keep incidental, very close actor surfaces from covering the player's view.

const MAX_DEPTH := 0.24
const NEAR_PADDING := 0.015
const MAX_ACTOR_DISTANCE_SQUARED := 1.5 * 1.5
const SCREEN_SAMPLES := [
	Vector2(0.0, 0.0),
	Vector2(-0.55, -0.55),
	Vector2(0.55, -0.55),
	Vector2(-0.55, 0.55),
	Vector2(0.55, 0.55),
]


static func near_plane(camera: Camera3D, frame: Dictionary, default_near: float) -> float:
	if not camera.is_inside_tree() or camera.projection != Camera3D.PROJECTION_PERSPECTIVE:
		return default_near
	if not _player_camera_active(frame):
		return default_near

	var probe_depth := minf(MAX_DEPTH, camera.far - 2.0 * NEAR_PADDING)
	var rect := camera.get_viewport().get_visible_rect()
	if default_near >= probe_depth or not rect.has_area():
		return default_near

	var transform := camera.get_camera_transform()
	var eye := transform.origin
	var forward := -transform.basis.z.normalized()
	var starts := PackedVector3Array()
	var ends := PackedVector3Array()
	for sample: Vector2 in SCREEN_SAMPLES:
		var pixel := rect.get_center() + sample * rect.size * 0.5
		var ray := camera.project_ray_normal(pixel)
		var forward_fraction := ray.dot(forward)
		if forward_fraction <= 0.0:
			return default_near
		starts.append(eye + ray * (default_near / forward_fraction))
		ends.append(eye + ray * (probe_depth / forward_fraction))

	var near_depth := default_near
	for actor: Dictionary in frame.get("actors", []):
		if bool(actor.get("player", false)) or not bool(actor.get("visible", false)):
			continue
		var center: Vector3 = actor.get("position", Vector3.INF)
		if eye.distance_squared_to(center) > MAX_ACTOR_DISTANCE_SQUARED:
			continue
		var blocked_depth := _covered_depth(actor, eye, forward, starts, ends, default_near, probe_depth)
		if blocked_depth > 0.0:
			near_depth = maxf(near_depth, minf(blocked_depth, probe_depth) + NEAR_PADDING)
	return near_depth


static func _player_camera_active(frame: Dictionary) -> bool:
	var state: PackedByteArray = frame.get("script_state", PackedByteArray())
	var progress: PackedByteArray = frame.get("game_data", PackedByteArray())
	return state.size() > 9 and progress.size() > 0x9f \
		and state[0] == 0 and state[9] == 0 and progress[0x8a] == 0 and progress[0x9f] == 0 \
		and absf(float(frame.get("bars", 0.0))) < 0.05


static func _covered_depth(actor: Dictionary, eye: Vector3, forward: Vector3,
		starts: PackedVector3Array, ends: PackedVector3Array, min_depth: float,
		max_depth: float) -> float:
	var hits := PackedFloat32Array()
	hits.resize(starts.size())
	for mesh: Dictionary in actor.get("meshes", []):
		# Cutouts and translucent surfaces need a texel test before they can count as solid.
		if int(mesh.get("blend", 0)) != 0:
			continue
		var vertices: PackedVector3Array = mesh.get("vertices", PackedVector3Array())
		var indices: PackedInt32Array = mesh.get("indices", PackedInt32Array())
		var two_sided := bool(mesh.get("two_sided", false))
		for index in range(0, indices.size() - 2, 3):
			var ia := indices[index]
			var ib := indices[index + 1]
			var ic := indices[index + 2]
			if mini(ia, mini(ib, ic)) < 0 or maxi(ia, maxi(ib, ic)) >= vertices.size():
				continue
			var a := vertices[ia]
			var b := vertices[ib]
			var c := vertices[ic]
			var da := (a - eye).dot(forward)
			var db := (b - eye).dot(forward)
			var dc := (c - eye).dot(forward)
			if minf(da, minf(db, dc)) > max_depth or maxf(da, maxf(db, dc)) < min_depth:
				continue
			# The bridge indexes front faces clockwise, as Godot expects.
			if not two_sided and (b - a).cross(c - a).dot(a - eye) <= 0.0:
				continue
			for ray_index in starts.size():
				var hit: Variant = Geometry3D.segment_intersects_triangle(
					starts[ray_index], ends[ray_index], a, b, c)
				if hit is Vector3:
					var point: Vector3 = hit
					hits[ray_index] = maxf(hits[ray_index], (point - eye).dot(forward))

	var farthest := 0.0
	for depth: float in hits:
		if depth <= 0.0:
			return 0.0
		farthest = maxf(farthest, depth)
	return farthest

