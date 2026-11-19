extends SceneTree
## Reload the saved terrain. Check spawn, collision rays, and foliage seating.
##   godot --headless --path . --script res://tools/walkability_validate.gd

const FOLIAGE := "res://foliage/IslandVegetation.scn"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var scene := (load("res://scenes/KoaCoast.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	for _i in 8:
		await process_frame
	var terrain := scene.get_node("Terrain3D")
	var data = terrain.data
	var spawn := Vector3(48.0, 0.0, 576.0)
	var sh: float = data.get_height(spawn)
	var sn: Vector3 = data.get_normal(spawn)
	print("SPAWN_H %.4f" % sh)
	print("SPAWN_SLOPE %.3f" % rad_to_deg(sn.angle_to(Vector3.UP)))
	print("RANGE ", data.get_height_range())
	var space: PhysicsDirectSpaceState3D = scene.get_world_3d().direct_space_state
	# Collision is dynamic in a radius around collision_target. Move that
	# target along each sample so the ray is inside the generated body.
	# This does not change the saved scene.
	var anchor := Node3D.new()
	anchor.name = "CollisionProbe"
	scene.add_child(anchor)
	terrain.set("collision_target", anchor)
	var routes: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("/tmp/koacoast_routes.json"))
	var misses := 0
	var rays := 0
	var max_gap := 0.0
	for route in routes["routes"]:
		var path: Array = route["path"]
		var step := maxi(1, int(path.size() / 50))
		var i := 0
		while i < path.size():
			var z := int(path[i][0])
			var x := int(path[i][1])
			var origin: Array = routes["origin"]
			var spacing := float(routes["spacing"])
			var wx := float(origin[0]) + float(x) * spacing
			var wz := float(origin[1]) + float(z) * spacing
			var expected: float = data.get_height(Vector3(wx, 0.0, wz))
			anchor.global_position = Vector3(wx, expected + 2.0, wz)
			await process_frame
			await process_frame
			var from := Vector3(wx, expected + 80.0, wz)
			var to := Vector3(wx, expected - 80.0, wz)
			var q := PhysicsRayQueryParameters3D.create(from, to)
			var hit: Dictionary = space.intersect_ray(q)
			rays += 1
			if hit.is_empty():
				misses += 1
				if misses <= 12:
					print("MISS ", wx, " ", wz, " expected ", expected)
			else:
				max_gap = maxf(max_gap, absf(float(hit.position.y) - expected))
			i += step
	# Coarse land grid, every 32 samples.
	var meta := FileAccess.get_file_as_string("/tmp/koacoast_grid.txt").split(" ")
	var w := int(meta[0])
	var d := int(meta[1])
	var spacing2 := float(meta[2])
	var minx := int(meta[3]) * int(meta[7]) * spacing2
	var minz := int(meta[4]) * int(meta[7]) * spacing2
	var grid_miss := 0
	var grid_n := 0
	for z in range(24, d - 24, 64):
		for x in range(24, w - 24, 64):
			var wx := minx + float(x) * spacing2
			var wz := minz + float(z) * spacing2
			var expected: float = data.get_height(Vector3(wx, 0.0, wz))
			if expected < 4.0:
				continue
			anchor.global_position = Vector3(wx, expected + 2.0, wz)
			await process_frame
			var q := PhysicsRayQueryParameters3D.create(Vector3(wx, expected + 80.0, wz), Vector3(wx, expected - 80.0, wz))
			var hit: Dictionary = space.intersect_ray(q)
			grid_n += 1
			if hit.is_empty():
				grid_miss += 1
				if grid_miss <= 8:
					print("GRID_MISS ", wx, " ", wz)
			else:
				max_gap = maxf(max_gap, absf(float(hit.position.y) - expected))
	print("ROUTE_RAYS ", rays, " MISSES ", misses, " MAX_GAP ", max_gap)
	print("GRID_RAYS ", grid_n, " MISSES ", grid_miss)
	_foliage(data)
	quit(0 if misses == 0 and grid_miss == 0 else 2)


func _foliage(data) -> void:
	var packed := load(FOLIAGE) as PackedScene
	if packed == null:
		push_error("Could not load foliage")
		return
	var root := packed.instantiate()
	var old_bytes := FileAccess.get_file_as_bytes("/tmp/koacoast_heights.f32")
	var old_h := old_bytes.to_float32_array()
	var meta := FileAccess.get_file_as_string("/tmp/koacoast_grid.txt").split(" ")
	var w := int(meta[0])
	var d := int(meta[1])
	var spacing := float(meta[2])
	var origin_x := int(meta[3]) * int(meta[7]) * spacing
	var origin_z := int(meta[4]) * int(meta[7]) * spacing
	var counts := {"seated": 0, "floating": 0, "buried": 0}
	var samples: Array = []
	_walk(root, root, Transform3D.IDENTITY, data, old_h, w, d, spacing, origin_x, origin_z, counts, samples)
	root.free()
	print("FOLIAGE seated ", counts["seated"], " floating ", counts["floating"], " buried ", counts["buried"])
	samples.sort_custom(func(a, b): return absf(float(a["dh"])) > absf(float(b["dh"])))
	var shown := 0
	for item in samples:
		if shown >= 12:
			break
		print("FOLIAGE_SPOT ", item["x"], " ", item["z"], " dh ", item["dh"], " ", item["kind"])
		shown += 1


func _walk(node: Node, root: Node, parent_xf: Transform3D, data, old_h: PackedFloat32Array, w: int, d: int, spacing: float, origin_x: float, origin_z: float, counts: Dictionary, samples: Array) -> void:
	var xf := parent_xf
	if node is Node3D:
		xf = parent_xf * (node as Node3D).transform
	if node is MultiMeshInstance3D:
		var mm: MultiMesh = (node as MultiMeshInstance3D).multimesh
		if mm != null and mm.transform_format == MultiMesh.TRANSFORM_3D and mm.instance_count > 0:
			var buf := mm.buffer
			var stride := int(buf.size() / mm.instance_count)
			if stride >= 12:
				for k in mm.instance_count:
					var base := k * stride
					var local := Vector3(buf[base + 3], buf[base + 7], buf[base + 11])
					var world: Vector3 = xf * local
					_classify(world, data, old_h, w, d, spacing, origin_x, origin_z, counts, samples)
		return
	for child in node.get_children():
		_walk(child, root, xf, data, old_h, w, d, spacing, origin_x, origin_z, counts, samples)


func _classify(world: Vector3, data, old_h: PackedFloat32Array, w: int, d: int, spacing: float, origin_x: float, origin_z: float, counts: Dictionary, samples: Array) -> void:
	var gx := int(round((world.x - origin_x) / spacing))
	var gz := int(round((world.z - origin_z) / spacing))
	if gx < 1 or gz < 1 or gx >= w - 1 or gz >= d - 1:
		return
	var prev: float = old_h[gz * w + gx]
	var now: float = data.get_height(Vector3(world.x, 0.0, world.z))
	if absf(world.y - prev) > 3.0:
		return
	counts["seated"] = int(counts["seated"]) + 1
	var dh := now - prev
	if dh < -1.5:
		counts["floating"] = int(counts["floating"]) + 1
		if samples.size() < 40:
			samples.append({"x": snappedf(world.x, 0.1), "z": snappedf(world.z, 0.1), "dh": snappedf(dh, 0.01), "kind": "floating"})
	elif dh > 1.2:
		counts["buried"] = int(counts["buried"]) + 1
		if samples.size() < 40:
			samples.append({"x": snappedf(world.x, 0.1), "z": snappedf(world.z, 0.1), "dh": snappedf(dh, 0.01), "kind": "buried"})
