class_name BuildingSystem
extends Node3D
## Fortnite/Valheim-inspired modular snap-placement building system.
## Supports piece selection, rotation, socket snapping, terrain/support/overlap
## validation, green/red ghost previews, door interaction, removal, and saving.

signal build_mode_changed(active: bool)
signal selected_piece_changed(piece_id: StringName)
signal selected_material_changed(material_id: StringName)
signal piece_placed(uid: String, piece_id: StringName, pos: Vector3)
signal piece_removed(uid: String, piece_id: StringName)
signal piece_damaged(uid: String, amount: float, hp_left: float, destroyed: bool)
signal piece_reinforced(uid: String)

const CELL := BuildingPieceBuilder.CELL
const HALF := BuildingPieceBuilder.HALF
const WALL_H := BuildingPieceBuilder.WALL_H
const MAX_BUILD_RANGE := 14.0
const SNAP_SEARCH_RADIUS := 7.0
const DOOR_INTERACT_RANGE := 3.2

var _terrain: Terrain3D
var _inventory: InventorySystem
var _database: GameDatabase
var _player: Node3D
var _camera: Camera3D

var build_mode := false
var selected_index := 0
var selected_material_id: StringName = &"wood"
var rotation_steps := 0

var _placed: Dictionary = {} # String uid -> Dictionary
var _campfires: Dictionary = {} # String uid -> Dictionary
var _base_storage: Dictionary = {} # StringName item_id -> int amount
var _body_to_uid: Dictionary = {} # int instance_id -> String uid
var _next_uid := 1
var _fire_flicker_t := 0.0

var _preview_root: Node3D
var _preview_piece_id: StringName = &""
var _preview_meshes: Array[MeshInstance3D] = []
var _preview_valid_mat: StandardMaterial3D
var _preview_invalid_mat: StandardMaterial3D
var _last_eval: Dictionary = { "valid": false, "reason": "", "pos": Vector3.ZERO, "rot_y": 0.0, "support_uid": "" }


func setup(terrain: Terrain3D, inventory: InventorySystem, database: GameDatabase, player: Node3D) -> void:
	_terrain = terrain
	_inventory = inventory
	_database = database
	_player = player
	_camera = player.get_node_or_null("CameraPivot/SpringArm3D/Camera3D") as Camera3D
	_build_preview_materials()


func _process(delta: float) -> void:
	# Smoothly animate hinged doors.
	for entry: Dictionary in _placed.values():
		var hinge := entry.get("door_hinge", null) as Node3D
		if hinge:
			var target_yaw := PI * 0.52 if bool(entry.get("door_open", false)) else 0.0
			hinge.rotation.y = lerpf(hinge.rotation.y, target_yaw, clampf(10.0 * delta, 0.0, 1.0))

	_fire_flicker_t += delta
	for cf: Dictionary in _campfires.values():
		var light := cf.get("light", null) as OmniLight3D
		if light and bool(cf.get("lit", true)):
			light.light_energy = 2.6 + 0.35 * sin(_fire_flicker_t * 9.5 + float(cf.get("phase", 0.0)))

	if build_mode:
		_update_preview()


func set_build_mode(active: bool) -> void:
	if build_mode == active:
		return
	build_mode = active
	if build_mode:
		_ensure_preview_mesh()
		_update_preview()
	else:
		_clear_preview_mesh()
	build_mode_changed.emit(build_mode)


func get_selected_piece_id() -> StringName:
	if _database == null or _database.building_piece_order.is_empty():
		return &""
	selected_index = posmod(selected_index, _database.building_piece_order.size())
	return _database.building_piece_order[selected_index]


func get_selected_piece_def() -> BuildingPieceDef:
	var pid := get_selected_piece_id()
	return _database.get_building_piece(pid) if _database else null


func select_piece_by_index(idx: int) -> void:
	if _database == null or _database.building_piece_order.is_empty():
		return
	selected_index = posmod(idx, _database.building_piece_order.size())
	_ensure_preview_mesh()
	selected_piece_changed.emit(get_selected_piece_id())


func cycle_piece(delta_idx: int) -> void:
	select_piece_by_index(selected_index + delta_idx)


func rotate_piece(delta_steps: int) -> void:
	rotation_steps = posmod(rotation_steps + delta_steps, 4)


func cycle_material(delta_idx: int) -> void:
	if _database == null or _database.building_material_order.is_empty():
		return
	var order := _database.building_material_order
	var cur_idx := maxi(0, order.find(selected_material_id))
	var next_idx := posmod(cur_idx + delta_idx, order.size())
	set_material(order[next_idx])


func set_material(mat_id: StringName) -> void:
	if _database == null or not _database.building_materials.has(mat_id):
		return
	if selected_material_id == mat_id:
		return
	selected_material_id = mat_id
	selected_material_changed.emit(selected_material_id)


func get_preview_status() -> Dictionary:
	return _last_eval


func try_place_current() -> Dictionary:
	if not build_mode:
		return { "ok": false, "reason": "not_in_build_mode" }
	_update_preview()
	if not bool(_last_eval.get("valid", false)):
		return { "ok": false, "reason": String(_last_eval.get("reason", "Invalid placement")) }
	var piece_def := get_selected_piece_def()
	if piece_def == null:
		return { "ok": false, "reason": "Missing piece definition" }
	return _commit_piece(
		piece_def.id,
		selected_material_id,
		_last_eval["pos"],
		float(_last_eval["rot_y"]),
		String(_last_eval.get("support_uid", "")),
		true
	)


func place_piece_explicit(piece_id: StringName, pos: Vector3, rot_y: float, consume_item := true, material_id := &"") -> Dictionary:
	var piece_def := _database.get_building_piece(piece_id) if _database else null
	if piece_def == null:
		return { "ok": false, "reason": "Unknown piece" }
	var mat_id := material_id if material_id != &"" else selected_material_id
	var support_uid := _find_support_uid(piece_def, pos, rot_y)
	var eval := _validate_placement(piece_def, pos, rot_y, support_uid, consume_item, mat_id)
	if not eval["valid"]:
		return { "ok": false, "reason": eval["reason"] }
	return _commit_piece(piece_id, mat_id, pos, rot_y, support_uid, consume_item)


func try_remove_targeted() -> Dictionary:
	var uid := _raycast_placed_piece()
	if uid == "":
		uid = _find_nearest_placed_piece(_get_aim_point(6.0), 3.0)
	if uid == "":
		return { "ok": false, "reason": "No structure targeted" }
	return remove_piece(uid, true)


func remove_piece(uid: String, refund := true) -> Dictionary:
	if not _placed.has(uid):
		return { "ok": false, "reason": "Missing piece" }
	var entry: Dictionary = _placed[uid]
	var piece_id: StringName = entry["piece_id"]
	var mat_id: StringName = entry["material_id"]
	var node: Node3D = entry["node"]
	_unregister_bodies(node)
	node.queue_free()
	_placed.erase(uid)

	var refunded := false
	if refund and _inventory and _database:
		var item_id := _database.get_building_item_id(piece_id, mat_id)
		if item_id == &"":
			var def := _database.get_building_piece(piece_id)
			item_id = def.item_id if def else &""
		if item_id != &"" and _inventory.can_fit(item_id, 1):
			_inventory.add_item(item_id, 1)
			refunded = true

	piece_removed.emit(uid, piece_id)
	return { "ok": true, "piece_id": piece_id, "refunded": refunded }


func find_nearest_door(player_pos: Vector3) -> Dictionary:
	var best: Dictionary = {}
	var best_d2 := DOOR_INTERACT_RANGE * DOOR_INTERACT_RANGE
	for entry: Dictionary in _placed.values():
		if entry["piece_id"] != &"door":
			continue
		var pos: Vector3 = entry["pos"]
		if absf(pos.y - player_pos.y) > 2.5:
			continue
		var d2 := Vector2(pos.x - player_pos.x, pos.z - player_pos.z).length_squared()
		if d2 < best_d2:
			best_d2 = d2
			best = entry
	return best


func toggle_door(uid: String) -> bool:
	if not _placed.has(uid):
		return false
	var entry: Dictionary = _placed[uid]
	if entry["piece_id"] != &"door":
		return false
	entry["door_open"] = not bool(entry.get("door_open", false))
	return true


func get_placed_count() -> int:
	return _placed.size()


func get_base_markers() -> Array[Vector3]:
	var clusters: Array[Vector3] = []
	for entry: Dictionary in _placed.values():
		var p: Vector3 = entry["pos"]
		var merged := false
		for i in clusters.size():
			if Vector2(clusters[i].x - p.x, clusters[i].z - p.z).length() < 28.0:
				merged = true
				break
		if not merged:
			clusters.append(p)
	return clusters


func serialize() -> Dictionary:
	var pieces: Array[Dictionary] = []
	for entry: Dictionary in _placed.values():
		var p: Vector3 = entry["pos"]
		pieces.append({
			"uid": String(entry["uid"]),
			"piece_id": String(entry["piece_id"]),
			"material_id": String(entry["material_id"]),
			"pos": [p.x, p.y, p.z],
			"rot_y": float(entry["rot_y"]),
			"support_uid": String(entry.get("support_uid", "")),
			"door_open": bool(entry.get("door_open", false)),
			"hp": snappedf(float(entry.get("hp", 100.0)), 0.1),
			"max_hp": snappedf(float(entry.get("max_hp", 100.0)), 0.1),
			"reinforced": bool(entry.get("reinforced", false)),
		})
	var fires: Array[Dictionary] = []
	for cf: Dictionary in _campfires.values():
		var fp: Vector3 = cf["pos"]
		fires.append({
			"uid": String(cf["uid"]),
			"pos": [fp.x, fp.y, fp.z],
			"lit": bool(cf.get("lit", true)),
		})
	var storage_out: Dictionary = {}
	for k in _base_storage:
		storage_out[String(k)] = int(_base_storage[k])
	return { "next_uid": _next_uid, "pieces": pieces, "campfires": fires, "base_storage": storage_out }


func deserialize(data: Dictionary) -> void:
	clear_all()
	_next_uid = maxi(1, int(data.get("next_uid", 1)))
	if data.has("pieces") and data["pieces"] is Array:
		for raw in data["pieces"]:
			if not (raw is Dictionary):
				continue
			var piece_id := StringName(String(raw.get("piece_id", "")))
			var mat_id := StringName(String(raw.get("material_id", "wood")))
			var pos_arr = raw.get("pos", [])
			if not (pos_arr is Array) or pos_arr.size() < 3:
				continue
			var pos := Vector3(float(pos_arr[0]), float(pos_arr[1]), float(pos_arr[2]))
			var rot_y := float(raw.get("rot_y", 0.0))
			var support_uid := String(raw.get("support_uid", ""))
			var uid := String(raw.get("uid", ""))
			var door_open := bool(raw.get("door_open", false))
			var reinforced := bool(raw.get("reinforced", false))
			var base_hp := _base_hp_for_material(mat_id) * (2.0 if reinforced else 1.0)
			var saved_max := float(raw.get("max_hp", base_hp))
			var saved_hp := clampf(float(raw.get("hp", saved_max)), 1.0, maxf(1.0, saved_max))
			_spawn_loaded_piece(uid, piece_id, mat_id, pos, rot_y, support_uid, door_open, saved_hp, saved_max, reinforced)
	if data.has("campfires") and data["campfires"] is Array:
		for raw_f in data["campfires"]:
			if not (raw_f is Dictionary):
				continue
			var fp_arr = raw_f.get("pos", [])
			if not (fp_arr is Array) or fp_arr.size() < 3:
				continue
			_spawn_campfire(String(raw_f.get("uid", "")), Vector3(float(fp_arr[0]), float(fp_arr[1]), float(fp_arr[2])), bool(raw_f.get("lit", true)))
	if data.has("base_storage") and data["base_storage"] is Dictionary:
		for k in data["base_storage"]:
			var amt := int(data["base_storage"][k])
			if amt > 0:
				_base_storage[StringName(String(k))] = amt


func clear_all() -> void:
	for entry: Dictionary in _placed.values():
		var node := entry.get("node", null) as Node3D
		if node:
			node.queue_free()
	for cf: Dictionary in _campfires.values():
		var fnode := cf.get("node", null) as Node3D
		if fnode:
			fnode.queue_free()
	_placed.clear()
	_campfires.clear()
	_base_storage.clear()
	_body_to_uid.clear()
	_next_uid = 1


func reinforce_piece(uid: String, consume_resources := true) -> Dictionary:
	if not _placed.has(uid):
		return { "ok": false, "reason": "Structure not found" }
	var entry: Dictionary = _placed[uid]
	if bool(entry.get("reinforced", false)):
		return { "ok": false, "reason": "Already reinforced" }
	if consume_resources and _inventory:
		var reqs: Array[Dictionary] = [{ "item_id": &"wood", "amount": 2 }, { "item_id": &"stone", "amount": 2 }]
		if not _inventory.has_items(reqs):
			return { "ok": false, "reason": "Need 2 Wood + 2 Stone to reinforce" }
		_inventory.remove_item(&"wood", 2)
		_inventory.remove_item(&"stone", 2)
	entry["reinforced"] = true
	entry["max_hp"] = _base_hp_for_material(entry["material_id"]) * 2.0
	entry["hp"] = entry["max_hp"]
	_attach_reinforcement_visual(entry["node"], entry["piece_id"])
	piece_reinforced.emit(uid)
	return { "ok": true, "uid": uid, "hp": entry["hp"] }


func damage_piece(uid: String, raw_damage: float) -> Dictionary:
	if not _placed.has(uid) or raw_damage <= 0.0:
		return { "ok": false, "applied": 0.0, "destroyed": false }
	var entry: Dictionary = _placed[uid]
	var is_reinf := bool(entry.get("reinforced", false))
	var mat_id: StringName = entry["material_id"]
	var effective := raw_damage
	if is_reinf:
		# Reinforced structures resist nighttime wildlife scratching (minimal/no damage).
		effective = 0.0 if raw_damage <= 15.0 else raw_damage * 0.15
	elif mat_id == &"stone":
		effective = raw_damage * 0.20
	if effective <= 0.0:
		piece_damaged.emit(uid, 0.0, float(entry["hp"]), false)
		return { "ok": true, "applied": 0.0, "hp": float(entry["hp"]), "resisted": true, "destroyed": false }
	entry["hp"] = maxf(0.0, float(entry["hp"]) - effective)
	var destroyed := float(entry["hp"]) <= 0.0
	piece_damaged.emit(uid, effective, float(entry["hp"]), destroyed)
	if destroyed:
		remove_piece(uid, false)
	return { "ok": true, "applied": effective, "hp": float(entry.get("hp", 0.0)), "resisted": false, "destroyed": destroyed }


func find_nearest_reinforceable(player_pos: Vector3) -> Dictionary:
	var best: Dictionary = {}
	var best_d2 := 3.4 * 3.4
	for entry: Dictionary in _placed.values():
		if bool(entry.get("reinforced", false)):
			continue
		if not (entry["piece_id"] in [&"wall", &"doorway", &"foundation"]):
			continue
		var p: Vector3 = entry["pos"]
		if absf(p.y - player_pos.y) > 2.6:
			continue
		var d2 := Vector2(p.x - player_pos.x, p.z - player_pos.z).length_squared()
		if d2 < best_d2:
			best_d2 = d2
			best = entry
	return best


func get_exterior_shelter_pieces() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry: Dictionary in _placed.values():
		if entry["piece_id"] in [&"wall", &"doorway", &"foundation"]:
			out.append(entry)
	return out


func place_campfire(pos: Vector3, consume_item := true) -> Dictionary:
	if _terrain == null or _terrain.data == null:
		return { "ok": false, "reason": "Terrain unavailable" }
	var h: float = _terrain.data.get_height(pos)
	if not is_finite(h) or h < 0.45:
		return { "ok": false, "reason": "Cannot place campfire underwater" }
	if consume_item and _inventory:
		if not _inventory.remove_item(&"campfire", 1):
			return { "ok": false, "reason": "Need 1x Campfire" }
	var uid := "cf_%d" % _next_uid
	_next_uid += 1
	var grounded := Vector3(pos.x, h, pos.z)
	_spawn_campfire(uid, grounded, true)
	return { "ok": true, "uid": uid, "pos": grounded }


func find_nearest_campfire(player_pos: Vector3) -> Dictionary:
	var best: Dictionary = {}
	var best_d2 := 3.0 * 3.0
	for cf: Dictionary in _campfires.values():
		var p: Vector3 = cf["pos"]
		if absf(p.y - player_pos.y) > 2.2:
			continue
		var d2 := Vector2(p.x - player_pos.x, p.z - player_pos.z).length_squared()
		if d2 < best_d2:
			best_d2 = d2
			best = cf
	return best


func toggle_campfire(uid: String) -> bool:
	if not _campfires.has(uid):
		return false
	var cf: Dictionary = _campfires[uid]
	var next_lit := not bool(cf.get("lit", true))
	cf["lit"] = next_lit
	var light := cf.get("light", null) as OmniLight3D
	var flame := cf.get("flame", null) as MeshInstance3D
	if light:
		light.visible = next_lit
	if flame:
		flame.visible = next_lit
	return true


func get_active_campfires() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for cf: Dictionary in _campfires.values():
		if bool(cf.get("lit", true)):
			out.append(cf)
	return out


## Returns all constructed campfires (lit or unlit) for respawn eligibility.
func get_all_campfires() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for cf: Dictionary in _campfires.values():
		out.append(cf)
	return out


func has_shelter_near(pos: Vector3, radius := 12.0) -> bool:
	var r2 := radius * radius
	for entry: Dictionary in _placed.values():
		var p: Vector3 = entry["pos"]
		if Vector2(p.x - pos.x, p.z - pos.z).length_squared() <= r2:
			return true
	return false


func is_position_blocked_by_structure(pos: Vector3, clearance := 0.85) -> bool:
	var c2 := clearance * clearance
	for entry: Dictionary in _placed.values():
		var pid: StringName = entry["piece_id"]
		if pid == &"foundation" or pid == &"floor" or pid == &"roof":
			continue
		var p: Vector3 = entry["pos"]
		if absf(p.y - pos.y) > 2.6:
			continue
		if Vector2(p.x - pos.x, p.z - pos.z).length_squared() < c2:
			return true
	for cf: Dictionary in _campfires.values():
		var fp: Vector3 = cf["pos"]
		if Vector2(fp.x - pos.x, fp.z - pos.z).length_squared() < 0.75 * 0.75:
			return true
	return false


func store_base_item(item_id: StringName, amount: int) -> void:
	if item_id == &"" or amount <= 0:
		return
	_base_storage[item_id] = int(_base_storage.get(item_id, 0)) + amount


func get_base_storage_count(item_id: StringName) -> int:
	return int(_base_storage.get(item_id, 0))


func _base_hp_for_material(mat_id: StringName) -> float:
	match mat_id:
		&"thatch":
			return 60.0
		&"stone":
			return 260.0
		_:
			return 120.0


func _attach_reinforcement_visual(root: Node3D, piece_id: StringName) -> void:
	if root == null or root.get_node_or_null("ReinforceBraces") != null:
		return
	var brace_holder := Node3D.new()
	brace_holder.name = "ReinforceBraces"
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.24, 0.22, 0.20)
	mat.roughness = 0.85
	var b1 := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(CELL * 0.96, 0.16, 0.34) if piece_id != &"foundation" else Vector3(CELL + 0.08, 0.14, CELL + 0.08)
	b1.mesh = box
	b1.material_override = mat
	b1.position = Vector3(0.0, 0.35 if piece_id != &"foundation" else -0.18, 0.0)
	brace_holder.add_child(b1)
	if piece_id == &"wall" or piece_id == &"doorway":
		var b2 := b1.duplicate() as MeshInstance3D
		b2.position = Vector3(0.0, 2.55, 0.0)
		brace_holder.add_child(b2)
	root.add_child(brace_holder)


func _spawn_campfire(uid: String, pos: Vector3, lit: bool) -> void:
	if uid == "" or _campfires.has(uid):
		uid = "cf_%d" % _next_uid
		_next_uid += 1
	var root := Node3D.new()
	root.name = uid
	root.position = pos

	var stone_mat := StandardMaterial3D.new()
	stone_mat.albedo_color = Color(0.32, 0.33, 0.35)
	var rock := SphereMesh.new()
	rock.radius = 0.16
	rock.height = 0.22
	for i in 8:
		var ang := TAU * float(i) / 8.0
		var rmi := MeshInstance3D.new()
		rmi.mesh = rock
		rmi.material_override = stone_mat
		rmi.position = Vector3(cos(ang) * 0.52, 0.09, sin(ang) * 0.52)
		root.add_child(rmi)

	var flame_mat := StandardMaterial3D.new()
	flame_mat.albedo_color = Color(1.0, 0.58, 0.14)
	flame_mat.emission_enabled = true
	flame_mat.emission = Color(1.0, 0.45, 0.08)
	flame_mat.emission_energy_multiplier = 3.0
	var flame := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.04
	cone.bottom_radius = 0.24
	cone.height = 0.52
	flame.mesh = cone
	flame.material_override = flame_mat
	flame.position = Vector3(0.0, 0.28, 0.0)
	flame.visible = lit
	root.add_child(flame)

	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.66, 0.32)
	light.light_energy = 2.6
	light.omni_range = 16.0
	light.omni_attenuation = 1.4
	light.position = Vector3(0.0, 0.75, 0.0)
	light.visible = lit
	root.add_child(light)

	add_child(root)
	_campfires[uid] = {
		"uid": uid,
		"pos": pos,
		"lit": lit,
		"node": root,
		"light": light,
		"flame": flame,
		"phase": float(uid.hash() % 100) * 0.1,
	}


func _commit_piece(piece_id: StringName, mat_id: StringName, pos: Vector3, rot_y: float, support_uid: String, consume_item: bool) -> Dictionary:
	var piece_def := _database.get_building_piece(piece_id)
	if piece_def == null:
		return { "ok": false, "reason": "Unknown piece" }
	var req_item_id := _database.get_building_item_id(piece_id, mat_id)
	if req_item_id == &"":
		return { "ok": false, "reason": "Unsupported material for %s" % piece_def.display_name }
	if consume_item and _inventory:
		if not _inventory.remove_item(req_item_id, 1):
			var item_def := _database.get_item(req_item_id)
			var nm := item_def.display_name if item_def else piece_def.display_name
			return { "ok": false, "reason": "Missing %s" % nm }
	var uid := "b_%d" % _next_uid
	_next_uid += 1
	_spawn_loaded_piece(uid, piece_id, mat_id, pos, rot_y, support_uid, false)
	piece_placed.emit(uid, piece_id, pos)
	return { "ok": true, "uid": uid, "piece_id": piece_id, "material_id": mat_id, "pos": pos }


func _spawn_loaded_piece(uid: String, piece_id: StringName, mat_id: StringName, pos: Vector3, rot_y: float, support_uid: String, door_open: bool, hp := -1.0, max_hp := -1.0, reinforced := false) -> void:
	if _database == null:
		return
	var piece_def := _database.get_building_piece(piece_id)
	var mat_def := _database.get_building_material(mat_id)
	if piece_def == null:
		return
	if mat_def == null:
		mat_def = _database.get_building_material(&"wood")
	if uid == "" or _placed.has(uid):
		uid = "b_%d" % _next_uid
		_next_uid += 1
	var built := BuildingPieceBuilder.build_piece_node(piece_def, mat_def, false)
	var node: Node3D = built["root"]
	node.name = uid
	node.position = pos
	node.rotation.y = rot_y
	add_child(node)
	_register_bodies(node, uid)
	var hinge := built.get("door_hinge", null) as Node3D
	if hinge and door_open:
		hinge.rotation.y = PI * 0.52
	var m_hp := max_hp if max_hp > 0.0 else _base_hp_for_material(mat_def.id) * (2.0 if reinforced else 1.0)
	var c_hp := hp if hp > 0.0 else m_hp
	if reinforced:
		_attach_reinforcement_visual(node, piece_id)
	_placed[uid] = {
		"uid": uid,
		"piece_id": piece_id,
		"material_id": mat_def.id,
		"pos": pos,
		"rot_y": rot_y,
		"support_uid": support_uid,
		"door_open": door_open,
		"hp": c_hp,
		"max_hp": m_hp,
		"reinforced": reinforced,
		"node": node,
		"door_hinge": hinge,
	}


func _update_preview() -> void:
	var piece_def := get_selected_piece_def()
	if piece_def == null:
		return
	if _preview_piece_id != piece_def.id:
		_ensure_preview_mesh()
	var target := _compute_target_transform(piece_def)
	var pos: Vector3 = target["pos"]
	var rot_y: float = target["rot_y"]
	var support_uid: String = target["support_uid"]
	var eval := _validate_placement(piece_def, pos, rot_y, support_uid, true, selected_material_id)
	eval["pos"] = pos
	eval["rot_y"] = rot_y
	eval["support_uid"] = support_uid
	_last_eval = eval

	if _preview_root:
		_preview_root.visible = true
		_preview_root.position = pos
		_preview_root.rotation.y = rot_y
		var mat := _preview_valid_mat if bool(eval["valid"]) else _preview_invalid_mat
		for mi in _preview_meshes:
			mi.material_override = mat


func _compute_target_transform(piece_def: BuildingPieceDef) -> Dictionary:
	var aim := _get_aim_hit()
	var aim_pos: Vector3 = aim["pos"]
	var base_yaw := float(rotation_steps) * PI * 0.5
	var best_snap := _find_best_snap(piece_def, aim_pos, base_yaw)
	if not best_snap.is_empty():
		return best_snap

	# Free placement on terrain (for foundation & stairs).
	var snapped_yaw := base_yaw
	if _terrain and _terrain.data:
		var th: float = _terrain.data.get_height(aim_pos)
		if is_finite(th):
			if piece_def.id == &"foundation":
				aim_pos.y = th + 0.45
			else:
				aim_pos.y = th
	return { "pos": aim_pos, "rot_y": snapped_yaw, "support_uid": "" }


func _find_best_snap(piece_def: BuildingPieceDef, aim_pos: Vector3, base_yaw: float) -> Dictionary:
	var best: Dictionary = {}
	var best_dist := SNAP_SEARCH_RADIUS
	for entry: Dictionary in _placed.values():
		var ep: Vector3 = entry["pos"]
		if ep.distance_to(aim_pos) > SNAP_SEARCH_RADIUS + 4.0:
			continue
		for sock: Dictionary in _sockets_for_piece(entry):
			var cats: Array = sock["accepts"]
			if not cats.has(piece_def.id):
				continue
			var sp: Vector3 = sock["pos"]
			var d := sp.distance_to(aim_pos)
			if d < best_dist:
				best_dist = d
				var rot_y: float = float(sock["rot_y"])
				if bool(sock.get("allow_user_rot", false)):
					rot_y = base_yaw
				best = {
					"pos": sp,
					"rot_y": rot_y,
					"support_uid": String(entry["uid"]),
				}
	return best


func _sockets_for_piece(entry: Dictionary) -> Array[Dictionary]:
	var sockets: Array[Dictionary] = []
	var pid: StringName = entry["piece_id"]
	var p: Vector3 = entry["pos"]
	var yaw: float = float(entry["rot_y"])
	var b := Basis(Vector3.UP, yaw)
	match pid:
		&"foundation", &"floor":
			for dir: Vector3 in [Vector3(CELL, 0, 0), Vector3(-CELL, 0, 0), Vector3(0, 0, CELL), Vector3(0, 0, -CELL)]:
				sockets.append({ "pos": p + b * dir, "rot_y": yaw, "accepts": [&"foundation", &"floor"], "allow_user_rot": true })
			var edges := [
				[Vector3(0, 0, -HALF), 0.0],
				[Vector3(HALF, 0, 0), -PI * 0.5],
				[Vector3(0, 0, HALF), PI],
				[Vector3(-HALF, 0, 0), PI * 0.5],
			]
			for e: Array in edges:
				var e_rot := wrapf(yaw + float(e[1]), -PI, PI)
				sockets.append({ "pos": p + b * (e[0] as Vector3), "rot_y": e_rot, "accepts": [&"wall", &"doorway"], "allow_user_rot": false })
			var stair_edges := [
				[Vector3(0, 0, -CELL), 0.0],
				[Vector3(CELL, 0, 0), -PI * 0.5],
				[Vector3(0, 0, CELL), PI],
				[Vector3(-CELL, 0, 0), PI * 0.5],
			]
			for se: Array in stair_edges:
				var s_rot := wrapf(yaw + float(se[1]), -PI, PI)
				sockets.append({ "pos": p + b * (se[0] as Vector3), "rot_y": s_rot, "accepts": [&"stairs"], "allow_user_rot": true })
				var down_rot := wrapf(s_rot + PI, -PI, PI)
				sockets.append({ "pos": p + b * ((se[0] as Vector3) + Vector3(0, -WALL_H, 0)), "rot_y": down_rot, "accepts": [&"stairs"], "allow_user_rot": true })
		&"wall", &"doorway":
			for side_z in [-HALF, HALF]:
				sockets.append({ "pos": p + b * Vector3(0, WALL_H, side_z), "rot_y": yaw, "accepts": [&"floor", &"roof"], "allow_user_rot": true })
			sockets.append({ "pos": p + b * Vector3(0, WALL_H, 0), "rot_y": yaw, "accepts": [&"wall", &"doorway"], "allow_user_rot": false })
			for side_x in [-CELL, CELL]:
				sockets.append({ "pos": p + b * Vector3(side_x, 0, 0), "rot_y": yaw, "accepts": [&"wall", &"doorway"], "allow_user_rot": false })
			if pid == &"doorway":
				sockets.append({ "pos": p, "rot_y": yaw, "accepts": [&"door"], "allow_user_rot": false })
		&"roof":
			for dir: Vector3 in [Vector3(CELL, 0, 0), Vector3(-CELL, 0, 0), Vector3(0, 0, CELL), Vector3(0, 0, -CELL)]:
				sockets.append({ "pos": p + b * dir, "rot_y": yaw, "accepts": [&"roof"], "allow_user_rot": true })
		&"stairs":
			sockets.append({ "pos": p + b * Vector3(0, WALL_H, -CELL), "rot_y": yaw, "accepts": [&"floor", &"foundation"], "allow_user_rot": true })
	return sockets


func _find_support_uid(piece_def: BuildingPieceDef, pos: Vector3, _rot_y: float) -> String:
	for entry: Dictionary in _placed.values():
		for sock: Dictionary in _sockets_for_piece(entry):
			if (sock["accepts"] as Array).has(piece_def.id):
				if (sock["pos"] as Vector3).distance_to(pos) < 0.35:
					return String(entry["uid"])
	return ""


func _validate_placement(piece_def: BuildingPieceDef, pos: Vector3, rot_y: float, support_uid: String, check_inventory: bool, mat_id := &"") -> Dictionary:
	var active_mat := mat_id if mat_id != &"" else selected_material_id
	var req_item_id := _database.get_building_item_id(piece_def.id, active_mat) if _database else piece_def.item_id
	if req_item_id == &"":
		var mat_def := _database.get_building_material(active_mat) if _database else null
		var mat_name := mat_def.display_name if mat_def else String(active_mat).capitalize()
		return { "valid": false, "reason": "%s has no %s piece — press G / D-Down" % [mat_name, piece_def.display_name] }
	if check_inventory and _inventory:
		if _inventory.get_count(req_item_id) < 1:
			var item_def := _database.get_item(req_item_id)
			var nm := item_def.display_name if item_def else piece_def.display_name
			return { "valid": false, "reason": "Need 1x %s (craft in Menu)" % nm }

	if _terrain == null or _terrain.data == null:
		return { "valid": false, "reason": "Terrain unavailable" }

	var data := _terrain.data
	var center_h: float = data.get_height(pos)
	if not is_finite(center_h) or center_h < 0.25 or pos.y < 0.15:
		return { "valid": false, "reason": "Cannot build underwater" }

	if piece_def.requires_support and support_uid == "":
		return { "valid": false, "reason": "Requires structural support" }

	# Check overlaps against already-placed pieces.
	for entry: Dictionary in _placed.values():
		var ep: Vector3 = entry["pos"]
		if ep.distance_to(pos) < 0.45:
			var same_cat := _same_overlap_group(piece_def.id, entry["piece_id"])
			if same_cat:
				return { "valid": false, "reason": "Overlaps existing piece" }

	# Terrain intersection & slope checks.
	var b := Basis(Vector3.UP, rot_y)
	if piece_def.id == &"foundation":
		var grounded_corners := 0
		for corner: Vector3 in [Vector3(0, 0, 0), Vector3(-1.7, 0, -1.7), Vector3(1.7, 0, -1.7), Vector3(-1.7, 0, 1.7), Vector3(1.7, 0, 1.7)]:
			var wp := pos + b * corner
			var th: float = data.get_height(wp)
			if not is_finite(th) or th < 0.15:
				return { "valid": false, "reason": "Cannot build underwater" }
			if th > pos.y + 0.85:
				return { "valid": false, "reason": "Terrain intersects structure" }
			if pos.y - th <= 2.45:
				grounded_corners += 1
		if grounded_corners < 2 and support_uid == "":
			return { "valid": false, "reason": "Foundation too high above ground" }
	elif piece_def.id == &"stairs":
		if support_uid == "" and (pos.y < center_h - 0.55 or pos.y > center_h + 1.2):
			return { "valid": false, "reason": "Stairs need ground or structure support" }
	elif piece_def.id in [&"wall", &"doorway", &"floor"]:
		if center_h > pos.y + 0.85:
			return { "valid": false, "reason": "Major terrain intersection" }

	# Prevent trapping player or overlapping solid rock props.
	if _player and piece_def.id in [&"foundation", &"wall"]:
		var p_dist := Vector2(_player.global_position.x - pos.x, _player.global_position.z - pos.z).length()
		var p_dy := absf(_player.global_position.y - pos.y)
		if piece_def.id == &"wall" and p_dist < 0.65 and p_dy < 2.2:
			return { "valid": false, "reason": "Blocked by player" }

	var space := get_world_3d().direct_space_state
	if space and piece_def.id in [&"foundation", &"wall", &"doorway"]:
		var query := PhysicsShapeQueryParameters3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(maxf(0.2, piece_def.size.x * 0.7), maxf(0.2, piece_def.size.y * 0.7), maxf(0.2, piece_def.size.z * 0.7))
		query.shape = box
		var y_off := -0.2 if piece_def.id == &"foundation" else WALL_H * 0.5
		query.transform = Transform3D(b, pos + Vector3(0.0, y_off, 0.0))
		query.collision_mask = 1
		var hits := space.intersect_shape(query, 8)
		for hit in hits:
			var col = hit.get("collider")
			if col == _terrain or col == _player:
				continue
			if col is Object and _body_to_uid.has((col as Object).get_instance_id()):
				continue
			return { "valid": false, "reason": "Blocked by solid object" }

	return { "valid": true, "reason": "Valid placement" }


func _same_overlap_group(a: StringName, b: StringName) -> bool:
	if a == b:
		return true
	var walls := [&"wall", &"doorway"]
	if walls.has(a) and walls.has(b):
		return true
	var decks := [&"foundation", &"floor"]
	if decks.has(a) and decks.has(b):
		return true
	return false


func _get_aim_hit() -> Dictionary:
	var space := get_world_3d().direct_space_state
	if _camera and space:
		var vp := get_viewport()
		var center := vp.get_visible_rect().size * 0.5
		var from := _camera.project_ray_origin(center)
		var dir := _camera.project_ray_normal(center)
		var to := from + dir * MAX_BUILD_RANGE
		var query := PhysicsRayQueryParameters3D.create(from, to, 1 | 8)
		if _player is CollisionObject3D:
			query.exclude = [(_player as CollisionObject3D).get_rid()]
		var hit := space.intersect_ray(query)
		if not hit.is_empty():
			return { "pos": hit["position"], "collider": hit.get("collider") }
		return { "pos": from + dir * 8.0, "collider": null }
	return { "pos": _get_aim_point(5.5), "collider": null }


func _get_aim_point(dist: float) -> Vector3:
	if _player == null:
		return Vector3.ZERO
	var visual := _player.get_node_or_null("Visual") as Node3D
	var fwd := Vector3(0, 0, 1)
	if visual:
		fwd = visual.global_basis.z.normalized()
	return _player.global_position + fwd * dist


func _raycast_placed_piece() -> String:
	var hit := _get_aim_hit()
	var col = hit.get("collider")
	if col is Object:
		return String(_body_to_uid.get((col as Object).get_instance_id(), ""))
	return ""


func _find_nearest_placed_piece(point: Vector3, max_dist: float) -> String:
	var best_uid := ""
	var best_d := max_dist
	for uid: String in _placed:
		var d := (_placed[uid]["pos"] as Vector3).distance_to(point)
		if d < best_d:
			best_d = d
			best_uid = uid
	return best_uid


func _register_bodies(root: Node, uid: String) -> void:
	for child in root.get_children():
		if child is CollisionObject3D:
			_body_to_uid[child.get_instance_id()] = uid
		_register_bodies(child, uid)


func _unregister_bodies(root: Node) -> void:
	for child in root.get_children():
		if child is CollisionObject3D:
			_body_to_uid.erase(child.get_instance_id())
		_unregister_bodies(child)


func _ensure_preview_mesh() -> void:
	_clear_preview_mesh()
	var piece_def := get_selected_piece_def()
	if piece_def == null:
		return
	var mat_def := _database.get_building_material(selected_material_id)
	var built := BuildingPieceBuilder.build_piece_node(piece_def, mat_def, true)
	_preview_root = built["root"]
	_preview_meshes = built["meshes"]
	_preview_piece_id = piece_def.id
	add_child(_preview_root)


func _clear_preview_mesh() -> void:
	if _preview_root:
		_preview_root.queue_free()
		_preview_root = null
	_preview_meshes.clear()
	_preview_piece_id = &""


func _build_preview_materials() -> void:
	_preview_valid_mat = StandardMaterial3D.new()
	_preview_valid_mat.albedo_color = Color(0.18, 0.92, 0.42, 0.46)
	_preview_valid_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_preview_valid_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_preview_valid_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	_preview_invalid_mat = StandardMaterial3D.new()
	_preview_invalid_mat.albedo_color = Color(0.95, 0.22, 0.22, 0.46)
	_preview_invalid_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_preview_invalid_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_preview_invalid_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
