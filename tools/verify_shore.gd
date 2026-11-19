extends SceneTree
## Confirms the player spawns on the ground near the coast and can walk the beach
## without falling through the terrain. Headless; no screenshots.

var _frames := 0
var _phase := 0
var _player: CharacterBody3D
var _data
var _floor_frames := 0
var _walk_frames := 0
var _min_y := 10000.0
var _max_sink := 0.0
var _start := Vector3.ZERO
var _spawn := Vector3.ZERO
var _spawn_floor := false
var _sea_near_spawn := false


func _initialize() -> void:
	var scene := (load("res://scenes/KoaCoast.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	_player = scene.get_node("Player")
	_data = scene.get_node("Terrain3D").data


func _process(delta: float) -> bool:
	_frames += 1
	if _phase == 0:
		if _frames < 20:
			return false
		if _player.is_on_floor() or _frames > 180:
			_spawn = _player.global_position
			_spawn_floor = _player.is_on_floor()
			var h: float = _data.get_height(_spawn)
			_sea_near_spawn = _sea_within(_spawn, 180.0)
			print("SPAWN pos ", _spawn, " terrain ", h, " floor ", _spawn_floor, " sea ", _sea_near_spawn)
			_player.global_position = Vector3(-78.0, h + 2.0, 604.0)
			_player.velocity = Vector3.ZERO
			_phase = 1
			_frames = 0
		return false
	if _phase == 1:
		# Let the body settle on the beach before walking.
		if _player.is_on_floor() and _frames > 20 or _frames > 120:
			_start = _player.global_position
			_phase = 2
			_frames = 0
			print("BEACH_START ", _start, " floor ", _player.is_on_floor(), " terrain ", _data.get_height(_start))
		return false
	# Walk along the shore for about 4 seconds, steering to stay near 1.2 m.
	var pos := _player.global_position
	var sea := Vector3(-0.3826834, 0.0, 0.9238795)
	var inland := -sea
	var along := Vector3(-sea.z, 0.0, sea.x)
	var h: float = _data.get_height(pos)
	var prefer := along
	if not is_nan(h):
		if h < 0.55:
			prefer = (along + inland * 0.9).normalized()
		elif h > 2.1:
			prefer = (along + sea * 0.9).normalized()
	var yaw := atan2(-prefer.x, -prefer.z)
	_player.get_node("CameraPivot").rotation.y = yaw
	if not InputMap.has_action("move_forward"):
		InputMap.add_action("move_forward")
	Input.action_press("move_forward")
	_walk_frames += 1
	if _player.is_on_floor():
		_floor_frames += 1
	_min_y = minf(_min_y, pos.y)
	if not is_nan(h):
		_max_sink = maxf(_max_sink, h - pos.y)
	if _frames < 240:
		return false
	Input.action_release("move_forward")
	var traveled := Vector2(pos.x - _start.x, pos.z - _start.z).length()
	var floor_ratio := float(_floor_frames) / float(maxi(_walk_frames, 1))
	var spawn_h: float = _data.get_height(_spawn)
	var pass_spawn := _spawn_floor and not is_nan(spawn_h) and spawn_h > 1.0 and spawn_h < 40.0 and _sea_near_spawn
	var pass_walk := floor_ratio > 0.7 and _min_y > -1.0 and _max_sink < 0.75 and traveled > 6.0
	print("WALK frames ", _walk_frames, " floor_ratio ", floor_ratio, " min_y ", _min_y, " max_sink ", _max_sink, " traveled ", traveled, " end ", pos)
	_print_invariants()
	print("RESULT spawn ", pass_spawn, " walk ", pass_walk)
	quit(0 if pass_spawn and pass_walk else 1)
	return true


func _print_invariants() -> void:
	var terrain: Node = root.get_node("KoaCoast/Terrain3D")
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var pixels := 0
	for region in terrain.data.get_regions_active():
		var raw: PackedByteArray = region.height_map.get_data()
		ctx.update(raw)
		pixels += region.height_map.get_width() * region.height_map.get_height()
	print("HEIGHTMAP_SHA256 ", ctx.finish().hex_encode(), " pixels ", pixels)
	var tally := {"inst": 0, "mms": 0}
	var fctx := HashingContext.new()
	fctx.start(HashingContext.HASH_SHA256)
	_hash_foliage(root.get_node("KoaCoast/IslandVegetation"), fctx, tally)
	print("FOLIAGE_INSTANCES ", tally.inst, " MULTIMESHES ", tally.mms)
	print("FOLIAGE_XFORM_SHA256 ", fctx.finish().hex_encode())


func _hash_foliage(n: Node, ctx: HashingContext, tally: Dictionary) -> void:
	if n is MultiMeshInstance3D:
		var mm: MultiMesh = (n as MultiMeshInstance3D).multimesh
		tally.mms += 1
		if mm:
			tally.inst += mm.instance_count
			for i in mm.instance_count:
				ctx.update(var_to_bytes(mm.get_instance_transform(i)))
	elif n is Node3D:
		ctx.update(var_to_bytes((n as Node3D).transform))
	for c in n.get_children():
		_hash_foliage(c, ctx, tally)


func _sea_within(p: Vector3, radius: float) -> bool:
	for k in 12:
		var a := TAU * float(k) / 12.0
		var h: float = _data.get_height(p + Vector3(cos(a), 0.0, sin(a)) * radius)
		if not is_nan(h) and h < 0.0:
			return true
	return false
