class_name ResourceGatherSystem
extends Node3D
## Modular resource gathering system using spatial-hashed proxies over existing
## Terrain3D MultiMesh foliage plus deterministic ground props (rocks & branches).
## Does not modify Terrain3D or remove MultiMesh vegetation instances.

signal resource_harvested(node_id: String, drops: Array[Dictionary], position: Vector3)

const CELL_SIZE := 16.0
const INTERACT_RANGE := 3.5

## Configurable yields and respawn times per resource source kind.
const RESOURCE_PROFILES := {
	&"tree": {
		"label": "Tree",
		"respawn": 120.0,
		"tool_kind": &"wood",
		"drops": [
			{ "item_id": &"wood", "min": 2, "max": 3 },
			{ "item_id": &"leaves", "min": 1, "max": 1 },
		],
	},
	&"branch": {
		"label": "Fallen Branch",
		"respawn": 75.0,
		"tool_kind": &"wood",
		"drops": [
			{ "item_id": &"wood", "min": 2, "max": 2 },
		],
	},
	&"rock": {
		"label": "Stone Deposit",
		"respawn": 90.0,
		"tool_kind": &"stone",
		"drops": [
			{ "item_id": &"stone", "min": 2, "max": 3 },
		],
	},
	&"grass": {
		"label": "Island Grass",
		"respawn": 60.0,
		"tool_kind": &"foliage",
		"drops": [
			{ "item_id": &"plant_fiber", "min": 2, "max": 3 },
		],
	},
	&"tropical_plant": {
		"label": "Tropical Plant",
		"respawn": 60.0,
		"tool_kind": &"foliage",
		"drops": [
			{ "item_id": &"leaves", "min": 2, "max": 2 },
			{ "item_id": &"plant_fiber", "min": 1, "max": 1 },
		],
	},
}

var _terrain: Terrain3D
var _inventory: InventorySystem
var _database: GameDatabase
var _static_cells: Dictionary = {} # Vector2i -> Array[Dictionary]
var _nodes_by_id: Dictionary = {} # String -> Dictionary
var _prop_nodes: Dictionary = {} # String -> Node3D
var _depleted_until: Dictionary = {} # String -> float
var _elapsed_time := 0.0
var _indexed := false
var _rock_mesh: ArrayMesh
var _branch_mesh: ArrayMesh
var _rock_material: StandardMaterial3D
var _branch_material: StandardMaterial3D


func setup(terrain: Terrain3D, inventory: InventorySystem, database: GameDatabase) -> void:
	_terrain = terrain
	_inventory = inventory
	_database = database
	_build_prop_assets()
	_build_index.call_deferred()


func _process(delta: float) -> void:
	_elapsed_time += delta
	if _depleted_until.is_empty():
		return
	var expired: Array[String] = []
	for id: String in _depleted_until:
		if float(_depleted_until[id]) <= _elapsed_time:
			expired.append(id)
	for id in expired:
		_depleted_until.erase(id)
		_set_prop_active(id, true)


func is_depleted(node_id: String) -> bool:
	return _depleted_until.has(node_id) and float(_depleted_until[node_id]) > _elapsed_time


func find_nearest_target(player_pos: Vector3, forward_dir: Vector3) -> Dictionary:
	if not _indexed:
		return {}
	var best: Dictionary = {}
	var best_score := INF
	var center_cell := _cell(player_pos.x, player_pos.z)
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var bucket: Array = _static_cells.get(center_cell + Vector2i(dx, dz), [])
			for node in bucket:
				var score := _score_candidate(node, player_pos, forward_dir)
				if score < best_score:
					best_score = score
					best = node

	# Also check active near-field ValleyUndergrowth tile samples without mutating foliage.
	var undergrowth := get_node_or_null("../../ValleyUndergrowth")
	if undergrowth and undergrowth.get("tiles") is Dictionary:
		var tiles: Dictionary = undergrowth.tiles
		var p_tile := Vector2i(floori(player_pos.x / 24.0), floori(player_pos.z / 24.0))
		for tz in range(-1, 2):
			for tx in range(-1, 2):
				var tile := tiles.get(p_tile + Vector2i(tx, tz), null) as Node3D
				if tile == null or not tile.has_meta("harvest_samples"):
					continue
				var samples: Array = tile.get_meta("harvest_samples")
				for sample: Dictionary in samples:
					var kind := _kind_from_undergrowth(int(sample["kind"]))
					var pos: Vector3 = sample["pos"]
					var id := _make_id(kind, pos)
					var candidate := { "id": id, "kind": kind, "pos": pos }
					var score := _score_candidate(candidate, player_pos, forward_dir)
					if score < best_score:
						best_score = score
						best = candidate
	return best


func get_prompt_for_target(target: Dictionary) -> String:
	if target.is_empty():
		return ""
	var kind: StringName = target["kind"]
	var profile: Dictionary = RESOURCE_PROFILES.get(kind, {})
	var label := String(profile.get("label", "Resource"))
	return "Gather %s" % label


func harvest(target: Dictionary) -> Dictionary:
	if target.is_empty() or _inventory == null:
		return { "ok": false, "reason": "invalid" }
	var node_id: String = target["id"]
	if is_depleted(node_id):
		return { "ok": false, "reason": "depleted" }
	var kind: StringName = target["kind"]
	var profile: Dictionary = RESOURCE_PROFILES.get(kind, {})
	if profile.is_empty():
		return { "ok": false, "reason": "unknown_kind" }

	var rng := RandomNumberGenerator.new()
	rng.seed = hash(node_id) ^ int(_elapsed_time * 10.0)
	var tool_kind: StringName = profile.get("tool_kind", &"")
	var tool_bonus := _inventory.get_tool_bonus(tool_kind) if tool_kind != &"" else 0

	var drops: Array[Dictionary] = []
	for idx in (profile["drops"] as Array).size():
		var d: Dictionary = profile["drops"][idx]
		var item_id: StringName = d["item_id"]
		var amt := rng.randi_range(int(d["min"]), int(d["max"]))
		if idx == 0 and tool_bonus > 0:
			amt += tool_bonus
		elif idx > 0 and tool_bonus >= 2:
			amt += 1 if kind == &"tree" else tool_bonus
		drops.append({ "item_id": item_id, "amount": amt })

	# Verify inventory can accept the primary drop before depleting.
	var primary: Dictionary = drops[0]
	if not _inventory.can_fit(primary["item_id"], int(primary["amount"])):
		_inventory.inventory_full.emit(primary["item_id"])
		return { "ok": false, "reason": "inventory_full" }

	var awarded: Array[Dictionary] = []
	for drop in drops:
		var added := _inventory.add_item(drop["item_id"], int(drop["amount"]))
		if added > 0:
			awarded.append({ "item_id": drop["item_id"], "amount": added })

	if awarded.is_empty():
		return { "ok": false, "reason": "inventory_full" }

	var respawn := float(profile.get("respawn", 90.0))
	_depleted_until[node_id] = _elapsed_time + respawn
	_set_prop_active(node_id, false)
	var pos: Vector3 = target["pos"]
	resource_harvested.emit(node_id, awarded, pos)
	return { "ok": true, "drops": awarded }


func serialize() -> Dictionary:
	var depleted := {}
	for id: String in _depleted_until:
		var remaining := float(_depleted_until[id]) - _elapsed_time
		if remaining > 0.5:
			depleted[id] = snappedf(remaining, 0.1)
	return { "depleted": depleted }


func deserialize(data: Dictionary) -> void:
	for id: String in _depleted_until.keys():
		_set_prop_active(id, true)
	_depleted_until.clear()
	if not data.has("depleted") or not (data["depleted"] is Dictionary):
		return
	var saved: Dictionary = data["depleted"]
	for id_key in saved:
		var id := String(id_key)
		var remaining := float(saved[id_key])
		if remaining > 0.0:
			_depleted_until[id] = _elapsed_time + remaining
			_set_prop_active(id, false)


func reset_all() -> void:
	for id: String in _depleted_until.keys():
		_set_prop_active(id, true)
	_depleted_until.clear()


func _build_index() -> void:
	# Wait a few frames so IslandScenery finishes generating woodland crowns.
	for _i in 3:
		await get_tree().process_frame
	_index_baked_vegetation()
	_index_scenery_trees()
	_spawn_ground_deposits()
	_indexed = true


func _index_baked_vegetation() -> void:
	var veg := get_node_or_null("../../IslandVegetation")
	if veg == null:
		return
	var seen_cells := {}
	for child in veg.get_children():
		if not (child is MultiMeshInstance3D) or child.multimesh == null:
			continue
		var mm: MultiMesh = child.multimesh
		if mm.instance_count <= 0 or mm.mesh == null:
			continue
		var mesh_name := mm.mesh.resource_path.get_file().get_basename()
		var kind: StringName = &""
		var dedup_step := 0.0
		match mesh_name:
			"Broadleaf", "FanPalm":
				kind = &"tree"
			"CoastalShrub", "Fern":
				kind = &"tropical_plant"
				dedup_step = 5.0
			"Sedge":
				kind = &"grass"
				dedup_step = 8.0
			_:
				continue
		var buf := mm.buffer
		if buf.is_empty():
			continue
		var stride := buf.size() / mm.instance_count
		if stride < 12:
			continue
		var node_xf: Transform3D = child.global_transform
		for i in mm.instance_count:
			var base := i * stride
			var sx := Vector3(buf[base], buf[base + 4], buf[base + 8]).length()
			if sx < 0.05:
				continue
			var local_pos := Vector3(buf[base + 3], buf[base + 7], buf[base + 11])
			var world_pos := node_xf * local_pos
			if dedup_step > 0.0:
				var key := Vector3i(kind.hash(), floori(world_pos.x / dedup_step), floori(world_pos.z / dedup_step))
				if seen_cells.has(key):
					continue
				seen_cells[key] = true
			_register_node(kind, world_pos)


func _index_scenery_trees() -> void:
	var scenery := get_node_or_null("../../IslandScenery")
	if scenery and scenery.has_method("get_forest_crowns"):
		var crowns: Array = scenery.get_forest_crowns()
		for c: Vector4 in crowns:
			_register_node(&"tree", Vector3(c.x, c.y, c.z))


func _spawn_ground_deposits() -> void:
	if _terrain == null or _terrain.data == null:
		return
	var data := _terrain.data
	var rng := RandomNumberGenerator.new()
	rng.seed = 40819

	# Guarantee accessible starter deposits around spawn (48, 576) without crowding spawn.
	var starter_offsets := [
		[&"branch", Vector2(56.0, 566.0)],
		[&"branch", Vector2(38.0, 564.0)],
		[&"rock", Vector2(59.0, 581.0)],
		[&"rock", Vector2(36.0, 583.0)],
		[&"rock", Vector2(64.0, 568.0)],
		[&"branch", Vector2(40.0, 592.0)],
	]
	for entry: Array in starter_offsets:
		var xz: Vector2 = entry[1]
		var h: float = data.get_height(Vector3(xz.x, 0.0, xz.y))
		if is_finite(h) and h > 0.4:
			_spawn_prop(entry[0], Vector3(xz.x, h, xz.y), rng.randf() * TAU, rng.randf_range(0.95, 1.15))

	# Scatter deterministic basalt rocks and fallen branches island-wide on walkable ground.
	var cell_step := 26.0
	for gz in range(-28, 29):
		for gx in range(-36, 37):
			var wx := (float(gx) + rng.randf_range(0.15, 0.85)) * cell_step
			var wz := (float(gz) + rng.randf_range(0.15, 0.85)) * cell_step
			var probe := Vector3(wx, 0.0, wz)
			var h: float = data.get_height(probe)
			if not is_finite(h) or h < 0.65 or h > 220.0:
				continue
			var n: Vector3 = data.get_normal(probe)
			if n.y < 0.80:
				continue
			var tex: Vector3 = data.get_texture_id(probe)
			var basalt := _surface_weight(tex, 0) + _surface_weight(tex, 4)
			var grass := _surface_weight(tex, 2)
			var roll := rng.randf()
			if roll < (0.28 if basalt > 0.35 else 0.14):
				_spawn_prop(&"rock", Vector3(wx, h, wz), rng.randf() * TAU, rng.randf_range(0.85, 1.35))
			elif roll > (0.86 if grass > 0.25 else 0.92):
				_spawn_prop(&"branch", Vector3(wx, h, wz), rng.randf() * TAU, rng.randf_range(0.9, 1.25))


func _spawn_prop(kind: StringName, pos: Vector3, yaw: float, scale_factor: float) -> void:
	var id := _make_id(kind, pos)
	if _nodes_by_id.has(id):
		return
	_register_node(kind, pos, id)
	var holder := Node3D.new()
	holder.name = id
	holder.position = pos
	holder.rotation.y = yaw
	holder.scale = Vector3.ONE * scale_factor

	var mi := MeshInstance3D.new()
	mi.mesh = _rock_mesh if kind == &"rock" else _branch_mesh
	mi.material_override = _rock_material if kind == &"rock" else _branch_material
	holder.add_child(mi)

	var body := StaticBody3D.new()
	body.collision_layer = 1
	var col := CollisionShape3D.new()
	if kind == &"rock":
		var sphere := SphereShape3D.new()
		sphere.radius = 0.55
		col.shape = sphere
		col.position = Vector3(0.0, 0.28, 0.0)
	else:
		var box := BoxShape3D.new()
		box.size = Vector3(1.5, 0.25, 0.3)
		col.shape = box
		col.position = Vector3(0.0, 0.12, 0.0)
	body.add_child(col)
	holder.add_child(body)
	add_child(holder)
	_prop_nodes[id] = holder
	if is_depleted(id):
		_set_prop_active(id, false)


func _set_prop_active(node_id: String, active: bool) -> void:
	var holder := _prop_nodes.get(node_id, null) as Node3D
	if holder == null:
		return
	holder.visible = active
	for child in holder.get_children():
		if child is StaticBody3D:
			for sub in child.get_children():
				if sub is CollisionShape3D:
					sub.set_deferred("disabled", not active)


func _register_node(kind: StringName, pos: Vector3, explicit_id := "") -> void:
	var id := explicit_id if explicit_id != "" else _make_id(kind, pos)
	if _nodes_by_id.has(id):
		return
	var node := { "id": id, "kind": kind, "pos": pos }
	_nodes_by_id[id] = node
	var key := _cell(pos.x, pos.z)
	if not _static_cells.has(key):
		_static_cells[key] = []
	_static_cells[key].append(node)


func _score_candidate(node: Dictionary, player_pos: Vector3, forward_dir: Vector3) -> float:
	var id: String = node["id"]
	if is_depleted(id):
		return INF
	var pos: Vector3 = node["pos"]
	var horiz_dist := Vector2(pos.x - player_pos.x, pos.z - player_pos.z).length()
	if horiz_dist > INTERACT_RANGE or absf(pos.y - player_pos.y) > 2.6:
		return INF
	var to_node := Vector2(pos.x - player_pos.x, pos.z - player_pos.z).normalized()
	var fwd := Vector2(forward_dir.x, forward_dir.z).normalized()
	var facing_penalty := (1.0 - fwd.dot(to_node)) * 0.9 if fwd.length_squared() > 0.1 and horiz_dist > 0.25 else 0.0
	# Prefer discrete landmarks (trees, rocks, branches) over underfoot grass/foliage.
	var kind_bias := 0.0
	match node["kind"]:
		&"tropical_plant":
			kind_bias = 2.2
		&"grass":
			kind_bias = 3.2
	return horiz_dist + facing_penalty + kind_bias


func _kind_from_undergrowth(kind_idx: int) -> StringName:
	match kind_idx:
		3, 4:
			return &"tree"
		1, 2:
			return &"tropical_plant"
		_:
			return &"grass"


func _make_id(kind: StringName, pos: Vector3) -> String:
	return "%s_%d_%d" % [String(kind), roundi(pos.x * 2.0), roundi(pos.z * 2.0)]


func _cell(x: float, z: float) -> Vector2i:
	return Vector2i(floori(x / CELL_SIZE), floori(z / CELL_SIZE))


func _surface_weight(texture: Vector3, surface: int) -> float:
	return (1.0 - texture.z if int(texture.x) == surface else 0.0) + (texture.z if int(texture.y) == surface else 0.0)


func _build_prop_assets() -> void:
	_rock_material = StandardMaterial3D.new()
	_rock_material.albedo_color = Color(0.29, 0.30, 0.32)
	_rock_material.roughness = 0.92

	_branch_material = StandardMaterial3D.new()
	_branch_material.albedo_color = Color(0.38, 0.25, 0.14)
	_branch_material.roughness = 0.88

	var rock_st := SurfaceTool.new()
	rock_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var main_boulder := SphereMesh.new()
	main_boulder.radial_segments = 7
	main_boulder.rings = 3
	rock_st.append_from(main_boulder, 0, Transform3D(Basis.from_scale(Vector3(0.75, 0.48, 0.65)), Vector3(0.0, 0.22, 0.0)))
	rock_st.append_from(main_boulder, 0, Transform3D(Basis.from_scale(Vector3(0.42, 0.30, 0.38)), Vector3(0.38, 0.14, 0.16)))
	_rock_mesh = rock_st.commit()

	var branch_st := SurfaceTool.new()
	branch_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var log_mesh := CylinderMesh.new()
	log_mesh.top_radius = 0.06
	log_mesh.bottom_radius = 0.11
	log_mesh.height = 1.55
	log_mesh.radial_segments = 6
	var rot := Basis(Vector3.FORWARD, PI * 0.5)
	branch_st.append_from(log_mesh, 0, Transform3D(rot, Vector3(0.0, 0.08, 0.0)))
	var twig := CylinderMesh.new()
	twig.top_radius = 0.025
	twig.bottom_radius = 0.045
	twig.height = 0.55
	twig.radial_segments = 5
	branch_st.append_from(twig, 0, Transform3D(Basis(Vector3.UP, 0.5) * Basis(Vector3.FORWARD, 1.05), Vector3(0.28, 0.15, 0.15)))
	_branch_mesh = branch_st.commit()
