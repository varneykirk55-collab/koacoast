extends Node3D
## F6 cycles the island rendering preset during play. The ocean and terrain
## retain their full extent at every setting.

const PRESETS := ["Low", "Medium", "High"]
const FADES := [Vector3(95, 170, 235), Vector3(135, 235, 320), Vector3(185, 310, 435)]
const LEAF_MATERIAL := preload("res://foliage/materials/Foliage.tres")
const CANOPY_SHADER := preload("res://scenery/DistantCanopy.gdshader")
const PATCH_SIZE := 96.0
const CROWN_CELL := 7.0

@export_enum("Low", "Medium", "High") var quality := 1
@onready var _baked: Node3D = $"../IslandVegetation"
@onready var _terrain: Terrain3D = $"../Terrain3D"
var _detail: Array[Array] = [[], [], []]
var _leaves: Array[ShaderMaterial] = []
var _canopy := ShaderMaterial.new()
var _canopy_nodes: Array[MultiMeshInstance3D] = []


func _ready() -> void:
	_setup.call_deferred()


func _setup() -> void:
	for index in 3:
		_leaves.append(LEAF_MATERIAL.duplicate())
	var crowns := {}
	for batch in _baked.get_children():
		if not batch is MultiMeshInstance3D or not batch.multimesh:
			continue
		var mesh_name: String = batch.multimesh.mesh.resource_path.get_file().get_basename()
		var category := 0
		match mesh_name:
			"Broadleaf", "FanPalm": category = 2
			"CoastalShrub", "Fern": category = 1
		_detail[category].append(batch)
		batch.material_override = _leaves[category]
		if mesh_name == "Broadleaf" or mesh_name == "CoastalShrub":
			_collect_crowns(batch, mesh_name == "Broadleaf", crowns)

	_canopy.shader = CANOPY_SHADER
	_build_canopy(crowns)
	apply_quality(quality)


func _collect_crowns(batch: MultiMeshInstance3D, tall: bool, crowns: Dictionary) -> void:
	for index in batch.multimesh.instance_count:
		var plant := batch.global_transform * batch.multimesh.get_instance_transform(index)
		var p := plant.origin
		var cell := Vector2i(floori(p.x / CROWN_CELL), floori(p.z / CROWN_CELL))
		var size := plant.basis.x.length()
		if not tall and (size < 1.15 or hash(cell) % 4 == 0):
			continue
		var height := size * (3.9 if tall else 1.45)
		if crowns.has(cell) and crowns[cell].w >= height:
			continue
		crowns[cell] = Vector4(p.x, p.y, p.z, height)


func _build_canopy(crowns: Dictionary) -> void:
	var patches := {}
	for crown: Vector4 in crowns.values():
		var patch := Vector2i(floori(crown.x / PATCH_SIZE), floori(crown.z / PATCH_SIZE))
		if not patches.has(patch):
			patches[patch] = []
		patches[patch].append(crown)

	var crown_mesh := SphereMesh.new()
	crown_mesh.radial_segments = 5
	crown_mesh.rings = 2
	for key: Vector2i in patches:
		var batch := MultiMesh.new()
		batch.transform_format = MultiMesh.TRANSFORM_3D
		batch.use_colors = true
		batch.mesh = crown_mesh
		batch.instance_count = patches[key].size()
		var origin := Vector3(key.x * PATCH_SIZE, 0, key.y * PATCH_SIZE)
		for i in batch.instance_count:
			var crown: Vector4 = patches[key][i]
			var variation := float(posmod(hash(Vector2(crown.x, crown.z)), 101)) / 100.0
			var radius := clampf(crown.w * 0.55 + 0.65, 1.4, 3.6)
			var p := Vector3(crown.x, crown.y + crown.w * 0.72, crown.z) - origin
			batch.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3(radius * 2.0, crown.w * 0.75, radius * 1.75)), p))
			batch.set_instance_color(i, Color(0.08 + variation * 0.055, 0.20 + variation * 0.11, 0.055 + variation * 0.035))
		var node := MultiMeshInstance3D.new()
		node.multimesh = batch
		node.material_override = _canopy
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(node)
		node.position = origin
		_canopy_nodes.append(node)


func apply_quality(level: int) -> void:
	quality = clampi(level, 0, PRESETS.size() - 1)
	if _leaves.is_empty():
		return
	var ranges: Vector3 = FADES[quality]
	for category in 3:
		var distance: float = ranges[category]
		_leaves[category].set_shader_parameter("detail_range", distance)
		for node: MultiMeshInstance3D in _detail[category]:
			# Keep every instance in the batch alive until its shader fade has ended.
			node.visibility_range_end = distance + node.get_aabb().size.length() * 0.5
	var canopy_start := ranges.z - 115.0
	_canopy.set_shader_parameter("canopy_start", canopy_start)
	for node in _canopy_nodes:
		node.visibility_range_begin = maxf(0.0, canopy_start - node.get_aabb().size.length() * 0.5)
	$"../ValleyUndergrowth".set_quality(quality)
	$"../IslandFreshwater".set_quality(quality)
	_terrain.mesh_lods = 7
	_terrain.mesh_size = [32, 48, 64][quality]
	get_viewport().msaa_3d = Viewport.MSAA_2X if quality == 2 else Viewport.MSAA_DISABLED
	print("KoaCoast graphics preset ", PRESETS[quality])


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F6:
		apply_quality((quality + 1) % PRESETS.size())
		get_viewport().set_input_as_handled()
