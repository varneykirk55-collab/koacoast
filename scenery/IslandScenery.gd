extends Node3D
## F6 cycles the island rendering preset during play. The ocean and terrain
## retain their full extent at every setting.

const PRESETS := ["Low", "Medium", "High"]
const FADES := [Vector3(95, 170, 235), Vector3(135, 235, 320), Vector3(185, 310, 435)]
const LEAF_MATERIAL := preload("res://foliage/materials/Foliage.tres")
const FOREST_DETAIL := preload("res://foliage/meshes/Broadleaf.obj")
const CANOPY_SHADER := preload("res://scenery/DistantCanopy.gdshader")
const PATCH_SIZE := 96.0
const CROWN_CELL := 8.0
const FOREST_STEP := 6.6
const FOREST_SPACING_CELL := 5.0
const WATERWAYS := preload("res://freshwater/watersheds.json")

@export_enum("Low", "Medium", "High") var quality := 1
@onready var _baked: Node3D = $"../IslandVegetation"
@onready var _terrain: Terrain3D = $"../Terrain3D"
var _detail: Array[Array] = [[], [], []]
var _leaves: Array[ShaderMaterial] = []
var _canopy := ShaderMaterial.new()
var _canopy_nodes: Array[MultiMeshInstance3D] = []
var _forest_material: ShaderMaterial
var _forest_leaves: ShaderMaterial
var _forest_detail_nodes: Array[MultiMeshInstance3D] = []
var _forest_crowns: Array[Vector4] = []
var _water_cells := {}


func get_forest_crowns() -> Array[Vector4]:
	return _forest_crowns


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
		if category == 2:
			_collect_crowns(batch, crowns)

	_canopy.shader = CANOPY_SHADER
	_forest_material = _canopy.duplicate()
	_forest_material.set_shader_parameter("canopy_span", 28.0)
	_forest_leaves = LEAF_MATERIAL.duplicate()
	_forest_leaves.set_shader_parameter("fade_span", 28.0)
	_index_waterways()
	var forest := _plant_forest(crowns)
	_forest_crowns.clear()
	for crown: Vector4 in forest.values():
		_forest_crowns.append(crown)
	var tree_mesh := _tree_mesh()
	_build_canopy(crowns, tree_mesh, _canopy)
	_build_canopy(forest, tree_mesh, _forest_material)
	_build_canopy(forest, FOREST_DETAIL, _forest_leaves, true)
	print("KoaCoast canopy ", crowns.size(), " tree LODs and ", forest.size(), " woodland trees")
	apply_quality(quality)


func _collect_crowns(batch: MultiMeshInstance3D, crowns: Dictionary) -> void:
	for index in batch.multimesh.instance_count:
		var plant := batch.global_transform * batch.multimesh.get_instance_transform(index)
		if plant.basis.x.is_zero_approx():
			continue
		var p := plant.origin
		var cell := _cell(p.x, p.z)
		var height := plant.basis.x.length() * 5.2
		if crowns.has(cell) and crowns[cell].w >= height:
			continue
		crowns[cell] = Vector4(p.x, p.y, p.z, height)


func _cell(x: float, z: float) -> Vector2i:
	return Vector2i(floori(x / CROWN_CELL), floori(z / CROWN_CELL))


func _index_waterways() -> void:
	for watershed: Dictionary in WATERWAYS.data:
		for channel: Dictionary in [watershed.river] + watershed.streams:
			for point: Array in channel.points:
				var xy := Vector2(point[0], point[1])
				var key := _cell(xy.x, xy.y)
				if not _water_cells.has(key):
					_water_cells[key] = []
				_water_cells[key].append(xy)


func _beside_water(p: Vector2) -> bool:
	var key := _cell(p.x, p.y)
	for z in range(-1, 2):
		for x in range(-1, 2):
			for point: Vector2 in _water_cells.get(key + Vector2i(x, z), []):
				if p.distance_squared_to(point) < 49.0:
					return true
	return false


func _plant_forest(crowns: Dictionary) -> Dictionary:
	var data := _terrain.data
	var forest := {}
	var grove := FastNoiseLite.new()
	grove.seed = 2167
	grove.frequency = 0.022
	var rng := RandomNumberGenerator.new()
	rng.seed = 7733
	for z in range(-115, 114):
		for x in range(-145, 147):
			var p := Vector3((x + rng.randf()) * FOREST_STEP, 0, (z + rng.randf()) * FOREST_STEP)
			p.y = data.get_height(p)
			if not is_finite(p.y) or p.y < 7.0 or p.y > 154.0:
				continue
			var normal := data.get_normal(p)
			if normal.y < 0.84:
				continue
			var texture := data.get_texture_id(p)
			var sand := _surface_weight(texture, 3)
			var basalt := _surface_weight(texture, 0)
			if sand > 0.25 or (p.x > 240.0 and p.z > -155.0 and basalt > 0.35):
				continue
			var grass := _surface_weight(texture, 2)
			var grove_weight := smoothstep(-0.31, 0.34, grove.get_noise_2d(p.x, p.z))
			var density := grove_weight * lerpf(0.38, 0.93, grass)
			density *= 1.0 - smoothstep(115.0, 154.0, p.y)
			if rng.randf() > density:
				continue
			var tree_cell := Vector2i(floori(p.x / FOREST_SPACING_CELL), floori(p.z / FOREST_SPACING_CELL))
			var point := Vector2(p.x, p.z)
			if crowns.has(_cell(p.x, p.z)) or forest.has(tree_cell) or _beside_water(point) or _on_trail(point):
				continue
			var height := rng.randf_range(5.1, 9.4)
			forest[tree_cell] = Vector4(p.x, p.y - 0.12, p.z, height)
	return forest


func _surface_weight(texture: Vector3, surface: int) -> float:
	return (1.0 - texture.z if int(texture.x) == surface else 0.0) + (texture.z if int(texture.y) == surface else 0.0)


func _on_trail(point: Vector2) -> bool:
	for trail: Array in $"../ValleyUndergrowth".TRAILS:
		for i in range(1, trail.size()):
			if point.distance_squared_to(Geometry2D.get_closest_point_to_segment(point, trail[i - 1], trail[i])) < 28.0:
				return true
	return false


func _tree_mesh() -> ArrayMesh:
	# A tapered trunk and asymmetrical crowns keep a recognizable tree silhouette
	# at summit distance. Every patch shares this mesh.
	var builder := SurfaceTool.new()
	builder.begin(Mesh.PRIMITIVE_TRIANGLES)
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.018
	trunk.bottom_radius = 0.043
	trunk.height = 0.63
	trunk.radial_segments = 5
	trunk.rings = 0
	builder.append_from(trunk, 0, Transform3D(Basis.IDENTITY, Vector3(0, 0.315, 0)))
	var crown := SphereMesh.new()
	crown.radial_segments = 5
	crown.rings = 1
	builder.append_from(crown, 0, Transform3D(Basis.from_scale(Vector3(0.70, 0.47, 0.63)), Vector3(0.02, 0.70, 0)))
	builder.append_from(crown, 0, Transform3D(Basis.from_scale(Vector3(0.43, 0.43, 0.40)), Vector3(-0.17, 0.56, 0.09)))
	builder.append_from(crown, 0, Transform3D(Basis.from_scale(Vector3(0.49, 0.41, 0.48)), Vector3(0.15, 0.84, -0.08)))
	return builder.commit()


func _build_canopy(crowns: Dictionary, tree_mesh: ArrayMesh, material: ShaderMaterial, detailed := false) -> void:
	var patches := {}
	var patch_size := 36.0 if detailed else PATCH_SIZE
	for crown: Vector4 in crowns.values():
		var patch := Vector2i(floori(crown.x / patch_size), floori(crown.z / patch_size))
		if not patches.has(patch):
			patches[patch] = []
		patches[patch].append(crown)

	for key: Vector2i in patches:
		var batch := MultiMesh.new()
		batch.transform_format = MultiMesh.TRANSFORM_3D
		batch.use_colors = not detailed
		batch.mesh = tree_mesh
		batch.instance_count = patches[key].size()
		var origin := Vector3(key.x * patch_size, 0, key.y * patch_size)
		for i in batch.instance_count:
			var crown: Vector4 = patches[key][i]
			var variation := float(posmod(hash(Vector2(crown.x, crown.z)), 101)) / 100.0
			var span := crown.w * lerpf(0.85, 1.22, variation)
			var p := Vector3(crown.x, crown.y, crown.z) - origin
			var scale := Vector3(span, crown.w, span)
			if detailed:
				scale /= 9.45
			var shape := Basis(Vector3.UP, variation * TAU).scaled(scale)
			batch.set_instance_transform(i, Transform3D(shape, p))
			if not detailed:
				batch.set_instance_color(i, Color(0.072 + variation * 0.058, 0.19 + variation * 0.095, 0.047 + variation * 0.039))
		var node := MultiMeshInstance3D.new()
		node.multimesh = batch
		node.material_override = material
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(node)
		node.position = origin
		if material == _canopy:
			_canopy_nodes.append(node)
		elif detailed:
			_forest_detail_nodes.append(node)


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
	var forest_detail_range: float = [59.0, 76.0, 96.0][quality]
	_forest_leaves.set_shader_parameter("detail_range", forest_detail_range)
	_forest_material.set_shader_parameter("canopy_start", forest_detail_range - 28.0)
	for node in _forest_detail_nodes:
		node.visibility_range_end = forest_detail_range + node.get_aabb().size.length() * 0.5
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
