extends SceneTree
## godot --headless --path . --script res://tools/verify_freshwater.gd

const WATERSHEDS := preload("res://freshwater/watersheds.json")
const COLUMNS := 7
var _failures: Array[String] = []
var _falls := 0
var _pools := 0
var _streams := 0
var _tris := 0
var _max_clearance := 0.0


func _initialize() -> void:
	_verify.call_deferred()


func _verify() -> void:
	var island := (load("res://scenes/KoaCoast.tscn") as PackedScene).instantiate()
	root.add_child(island)
	await process_frame
	await process_frame
	var water := island.get_node("IslandFreshwater")
	var terrain: Terrain3DData = island.get_node("Terrain3D").data
	for watershed: Dictionary in WATERSHEDS.data:
		var group := water.get_node(NodePath(watershed.name))
		var river: Array = watershed.river.points
		var mouth: Array = river.back()
		_check(mouth[2] <= 0.05 and terrain.get_height(_position(mouth)) <= 0.0, "%s ocean outlet" % watershed.name)
		_channel(watershed.river, group.get_node("River"), terrain)
		for i in watershed.streams.size():
			var stream: Dictionary = watershed.streams[i]
			var join: Array = river[int(stream.join)]
			_check(stream.points.back() == join, "%s tributary joins its river" % watershed.name)
			_channel(stream, group.get_node("Tributary%d" % (i + 1)), terrain)
			_streams += 1
	var spray: MeshInstance3D = water.get_node("WaterfallSpray")
	_check(spray.mesh.surface_get_array_len(0) == _falls * 9 * 6, "Spray at every fall")
	print("RIVERS %d STREAMS %d FALLS %d POOLS %d TRIANGLES %d MAX_CENTER_DEPTH %.2f m" %
		[WATERSHEDS.data.size(), _streams, _falls, _pools, _tris, _max_clearance])
	for failure in _failures:
		push_error(failure)
	print("FRESHWATER ", "PASS" if _failures.is_empty() else "FAIL")
	quit(0 if _failures.is_empty() else 1)


func _channel(channel: Dictionary, instance: MeshInstance3D, terrain: Terrain3DData) -> void:
	var points: Array = channel.points
	var arrays := instance.mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	_check(vertices.size() == points.size() * COLUMNS, "%s mesh rows" % instance.get_path())
	_tris += indices.size() / 3
	for i in points.size():
		var center := _position(points[i])
		if i > 0:
			_check(center.y <= _position(points[i - 1]).y + 0.001, "%s row %d flows uphill" % [instance.get_path(), i])
		var mid := vertices[i * COLUMNS + COLUMNS / 2]
		var depth := center.y - terrain.get_height(center)
		_max_clearance = maxf(_max_clearance, depth)
		_check(mid.distance_to(center) < 0.001 and depth >= -0.01 and depth < 2.1,
			"%s row %d surface departs from channel bed" % [instance.get_path(), i])
		for column in [0, COLUMNS - 1]:
			var bank := vertices[i * COLUMNS + column]
			_check(bank.y <= terrain.get_height(bank) + 0.001 or center.y <= 0.11,
				"%s row %d has an exposed mesh rim" % [instance.get_path(), i])
	for fall: Array in channel.falls:
		var lip := _position(points[int(fall[0])])
		var base := _position(points[int(fall[1])])
		_check(lip.y - base.y >= 3.0 and fall[1] < points.size() - 1, "Fall has a real drop and continues downstream")
		_falls += 1
	for pool: Array in channel.pools:
		var deepest := 0.0
		for i in range(int(pool[0]), int(pool[1]) + 1):
			var center := _position(points[i])
			deepest = maxf(deepest, center.y - terrain.get_height(center))
		_check(deepest > 0.5, "Pool occupies a natural depression")
		_pools += 1


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _position(point: Array) -> Vector3:
	return Vector3(point[0], point[2], point[1])
