extends Node3D
## Deterministic near-field planting over the island's baked, distant vegetation.
## A walked-away tile can be discarded and rebuilt with the same plants.

const TILE := 24
const RADIUS := 3
const SPECIES := [
	preload("res://foliage/meshes/Sedge.obj"),
	preload("res://foliage/meshes/Fern.obj"),
	preload("res://foliage/meshes/CoastalShrub.obj"),
	preload("res://foliage/meshes/Broadleaf.obj"),
	preload("res://foliage/meshes/FanPalm.obj"),
]
const LEAVES := preload("res://foliage/materials/Foliage.tres")
# Walkable centerlines sampled on the current heightfield, from the south shore.
const TRAILS := [
	[Vector2(48,576),Vector2(52,176),Vector2(24,148),Vector2(8,140)],
	[Vector2(48,576),Vector2(-96,440),Vector2(-112,440),Vector2(-136,432),Vector2(-204,432),Vector2(-328,308),Vector2(-328,208),Vector2(-324,196),Vector2(-312,184)],
	[Vector2(48,576),Vector2(48,520),Vector2(56,504),Vector2(56,476),Vector2(60,468),Vector2(120,404),Vector2(136,384),Vector2(136,376),Vector2(192,320),Vector2(192,312),Vector2(200,304),Vector2(200,264),Vector2(228,236)],
]

@onready var terrain: Terrain3D = $"../Terrain3D"
var tiles := {}
var pending: Array[Vector2i] = []
var center := Vector2i.MAX

func _process(_delta: float) -> void:
	var camera := get_viewport().get_camera_3d()
	if not camera or not terrain.data or terrain.data.get_region_count() == 0:
		return
	var pos := camera.global_position
	var here := Vector2i(floori(pos.x / TILE), floori(pos.z / TILE))
	if here != center:
		center = here
		pending.clear()
		for key: Vector2i in tiles.keys():
			if _distance(key, here) > RADIUS + 1:
				tiles[key].queue_free()
				tiles.erase(key)
		for z in range(-RADIUS, RADIUS + 1):
			for x in range(-RADIUS, RADIUS + 1):
				var key := here + Vector2i(x,z)
				if not tiles.has(key):
					pending.append(key)
		pending.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			return a.distance_squared_to(here) > b.distance_squared_to(here))
	if not pending.is_empty():
		_plant_tile(pending.pop_back())

func _distance(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))

func _plant_tile(key: Vector2i) -> void:
	var tile := Node3D.new()
	add_child(tile)
	tile.position = Vector3(key.x * TILE, 0, key.y * TILE)
	tiles[key] = tile
	var base := Vector2(tile.position.x, tile.position.z)
	var nearby_segments: Array[Vector2] = []
	var bounds := Rect2(base, Vector2(TILE,TILE)).grow(10)
	for trail: Array in TRAILS:
		for j in range(1, trail.size()):
			var a: Vector2 = trail[j-1]
			var b: Vector2 = trail[j]
			if Rect2(a, b-a).abs().intersects(bounds, true):
				nearby_segments.append_array([a,b])
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(key.x, 971, key.y))
	var groups := [[], [], [], [], []]
	# Independent jittered layers let fern crowns overlap the sedge carpet.
	for layer in 3:
		var cells: int = [15, 8, 2][layer]
		var step_size := float(TILE) / cells
		for z in cells:
			for x in cells:
				var local := (Vector2(x,z) + Vector2(rng.randf(),rng.randf())) * step_size
				var point := base + local
				var p := Vector3(point.x, 0, point.y)
				var h := terrain.data.get_height(p)
				if not is_finite(h) or h < 1.3 or h > 165:
					continue
				if terrain.data.get_normal(p).y < 0.84: # About 33 degrees
					continue
				var tex := terrain.data.get_texture_id(p)
				var grass := _weight(tex, 2)
				if _weight(tex, 3) > 0.45 or _weight(tex, 1) > 0.48:
					continue
				if point.x > 240 and point.y > -160 and _weight(tex, 0) > 0.52:
					continue
				var fill := (1.0 - smoothstep(140, 165, h)) * lerpf(0.72, 1.0, grass)
				if rng.randf() > fill:
					continue
				var kind := 0
				var size := rng.randf_range(1.18, 1.65)
				if layer == 1:
					kind = 1 if rng.randf() < 0.70 else 2
					size = rng.randf_range(1.02, 1.58)
				elif layer == 2:
					kind = 2 if rng.randf() < 0.84 else (3 if rng.randf() < 0.76 else 4)
					size = rng.randf_range(1.65, 2.15) if kind == 2 else rng.randf_range(0.68, 1.05)
				var clearance := 1.6 + size * float([0.86, 1.7, 1.75, 5.5, 6.2][kind])
				if _on_trail(point, clearance, nearby_segments):
					continue
				var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * size)
				groups[kind].append(Transform3D(basis, Vector3(local.x, h - 0.05, local.y)))
	for kind in groups.size():
		var transforms: Array = groups[kind]
		if transforms.is_empty():
			continue
		var batch := MultiMesh.new()
		batch.transform_format = MultiMesh.TRANSFORM_3D
		batch.mesh = SPECIES[kind]
		batch.instance_count = transforms.size()
		for i in transforms.size():
			batch.set_instance_transform(i, transforms[i])
		var display := MultiMeshInstance3D.new()
		display.multimesh = batch
		display.material_override = LEAVES
		display.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		tile.add_child(display)

func _weight(tex: Vector3, id: int) -> float:
	return (1.0 - tex.z if int(tex.x) == id else 0.0) + (tex.z if int(tex.y) == id else 0.0)

func _on_trail(point: Vector2, clearance: float, segments: Array[Vector2]) -> bool:
	for j in range(0, segments.size(), 2):
		var closest := Geometry2D.get_closest_point_to_segment(point, segments[j], segments[j+1])
		if point.distance_squared_to(closest) < clearance * clearance:
			return true
	return false
