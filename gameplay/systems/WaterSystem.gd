class_name WaterSystem
extends Node3D
## Manages freshwater vs. saltwater source detection and placed Rainwater Collection Tarps.
## Integrates with watersheds.json, SurvivalVitalsSystem rain input, InventorySystem, and SaveSystem.

signal collector_placed(uid: String, pos: Vector3)

const WATERWAYS := preload("res://freshwater/watersheds.json")
const CELL_SIZE := 16.0
const FRESHWATER_RANGE := 4.8
const COLLECTOR_INTERACT_RANGE := 3.2

@export var collector_capacity := 100.0
@export var rain_fill_rate_per_sec := 5.0

var volcano: VolcanicHazards
var buildings: BuildingSystem
var _terrain: Terrain3D
var _vitals: SurvivalVitalsSystem
var _inventory: InventorySystem
var _resources: ResourceGatherSystem
var _freshwater_cells: Dictionary = {} # Vector2i -> Array[Vector3]
var _collectors: Dictionary = {} # String uid -> Dictionary
var _next_uid := 1

var _tarp_mat: StandardMaterial3D
var _pole_mat: StandardMaterial3D
var _water_mat: StandardMaterial3D


func setup(terrain: Terrain3D, vitals: SurvivalVitalsSystem, inventory: InventorySystem, resources: ResourceGatherSystem) -> void:
	_terrain = terrain
	_vitals = vitals
	_inventory = inventory
	_resources = resources
	_build_materials()
	_index_freshwater()


func _process(delta: float) -> void:
	if _vitals == null or _collectors.is_empty():
		return
	var rain := _vitals.rain_intensity
	if rain <= 0.001:
		return
	var gain := rain_fill_rate_per_sec * rain * delta
	for entry: Dictionary in _collectors.values():
		if buildings and buildings.weather_cover(entry.pos + Vector3.UP).x > 0:
			continue
		var quality := WaterQuality.evaluate_source_quality(&"rainwater", float(entry.get("ash_load", 0)))
		var cur := float(entry["stored_water"])
		if cur < collector_capacity:
			var next_val := minf(collector_capacity, cur + gain)
			if cur <= 0.01:
				entry["water_quality"] = quality
			elif not WaterQuality.is_safe(quality):
				entry["water_quality"] = quality
			entry["stored_water"] = next_val
			_update_collector_visual(entry)


func detect_water_source(player_pos: Vector3) -> Dictionary:
	# 1. Check nearby freshwater channels from watersheds.json.
	var c := _cell(player_pos.x, player_pos.z)
	var best_fw := Vector3.INF
	var best_d2 := FRESHWATER_RANGE * FRESHWATER_RANGE
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var bucket: Array = _freshwater_cells.get(c + Vector2i(dx, dz), [])
			for wp: Vector3 in bucket:
				if absf(wp.y - player_pos.y) > 2.6:
					continue
				var d2 := Vector2(wp.x - player_pos.x, wp.z - player_pos.z).length_squared()
				if d2 < best_d2:
					best_d2 = d2
					best_fw = wp
	if best_fw != Vector3.INF:
		var q := WaterQuality.evaluate_source_quality(&"freshwater", volcano.water_ash(best_fw) if volcano else 0.0)
		return {
			"type": &"freshwater",
			"quality": q,
			"pos": best_fw,
			"label": "Freshwater Stream",
		}

	# 2. Check ocean shoreline (saltwater — unsafe to drink!).
	if _terrain and _terrain.data:
		var h: float = _terrain.data.get_height(player_pos)
		if is_finite(h) and h <= 0.65:
			return {
				"type": &"saltwater",
				"quality": WaterQuality.Quality.SALTWATER,
				"pos": Vector3(player_pos.x, 0.0, player_pos.z),
				"label": "Ocean Saltwater",
			}
	return {}


func find_nearest_collector(player_pos: Vector3) -> Dictionary:
	var best: Dictionary = {}
	var best_d2 := COLLECTOR_INTERACT_RANGE * COLLECTOR_INTERACT_RANGE
	for entry: Dictionary in _collectors.values():
		var pos: Vector3 = entry["pos"]
		if absf(pos.y - player_pos.y) > 2.5:
			continue
		var d2 := Vector2(pos.x - player_pos.x, pos.z - player_pos.z).length_squared()
		if d2 < best_d2:
			best_d2 = d2
			best = entry
	return best


func place_rain_collector(pos: Vector3, rot_y := 0.0, consume_item := true) -> Dictionary:
	if _terrain == null or _terrain.data == null:
		return { "ok": false, "reason": "Terrain unavailable" }
	var h: float = _terrain.data.get_height(pos)
	if not is_finite(h) or h < 0.55:
		return { "ok": false, "reason": "Cannot place rain tarp underwater or on wet shore" }
	var normal: Vector3 = _terrain.data.get_normal(pos)
	if normal.y < 0.85:
		return { "ok": false, "reason": "Ground is too steep for rain tarp" }
	for entry: Dictionary in _collectors.values():
		if Vector2((entry["pos"] as Vector3).x - pos.x, (entry["pos"] as Vector3).z - pos.z).length() < 2.5:
			return { "ok": false, "reason": "Too close to another rain collector" }
	if consume_item and _inventory:
		if not _inventory.remove_item(&"rain_tarp", 1):
			return { "ok": false, "reason": "Need 1x Rainwater Collection Tarp" }

	var grounded_pos := Vector3(pos.x, h, pos.z)
	var tree_anchors := _count_nearby_trees(grounded_pos, 9.0) >= 2
	var uid := "rc_%d" % _next_uid
	_next_uid += 1
	_spawn_collector(uid, grounded_pos, rot_y, 0.0, WaterQuality.Quality.RAINWATER, tree_anchors)
	collector_placed.emit(uid, grounded_pos)
	return { "ok": true, "uid": uid, "pos": grounded_pos, "anchored_to_trees": tree_anchors }


func transfer_to_container(uid: String) -> Dictionary:
	if not _collectors.has(uid) or _inventory == null:
		return { "ok": false, "reason": "Invalid collector" }
	var entry: Dictionary = _collectors[uid]
	var avail := float(entry["stored_water"])
	if avail <= 0.1:
		return { "ok": false, "reason": "Rain collector is empty (wait for rain)" }
	var slot_idx := _inventory.find_container_slot(true, false)
	if slot_idx < 0:
		return { "ok": false, "reason": "No water container with free space in bag" }
	var q := int(entry["water_quality"])
	var transferred := _inventory.fill_container(slot_idx, avail, q)
	if transferred <= 0.0:
		return { "ok": false, "reason": "Container is already full" }
	entry["stored_water"] = maxf(0.0, avail - transferred)
	_update_collector_visual(entry)
	return { "ok": true, "transferred": transferred, "quality": q }


func drink_from_collector(uid: String) -> Dictionary:
	if not _collectors.has(uid) or _vitals == null:
		return { "ok": false, "reason": "Invalid collector" }
	var entry: Dictionary = _collectors[uid]
	var avail := float(entry["stored_water"])
	if avail <= 0.1:
		return { "ok": false, "reason": "Rain collector is empty (wait for rain)" }
	var sip := minf(50.0, avail)
	var q := int(entry["water_quality"])
	entry["stored_water"] = maxf(0.0, avail - sip)
	_update_collector_visual(entry)
	var eff := _vitals.drink_water(sip, q)
	eff["ok"] = true
	return eff


func get_collector_count() -> int:
	return _collectors.size()


func get_collector(uid: String) -> Dictionary:
	return _collectors.get(uid, {})


func clear_all() -> void:
	for entry: Dictionary in _collectors.values():
		var node := entry.get("node", null) as Node3D
		if node:
			node.queue_free()
	_collectors.clear()
	_next_uid = 1


func serialize() -> Dictionary:
	var list: Array[Dictionary] = []
	for entry: Dictionary in _collectors.values():
		var p: Vector3 = entry["pos"]
		list.append({
			"uid": String(entry["uid"]),
			"pos": [p.x, p.y, p.z],
			"rot_y": float(entry["rot_y"]),
			"stored_water": float(entry["stored_water"]),
			"water_quality": int(entry["water_quality"]),
			"ash_load": float(entry.get("ash_load", 0)),
			"anchored_to_trees": bool(entry.get("anchored_to_trees", false)),
		})
	return { "next_uid": _next_uid, "collectors": list }


func deserialize(data: Dictionary) -> void:
	clear_all()
	_next_uid = maxi(1, int(data.get("next_uid", 1)))
	if not data.has("collectors") or not (data["collectors"] is Array):
		return
	for raw in data["collectors"]:
		if not (raw is Dictionary):
			continue
		var pos_arr = raw.get("pos", [])
		if not (pos_arr is Array) or pos_arr.size() < 3:
			continue
		var pos := Vector3(float(pos_arr[0]), float(pos_arr[1]), float(pos_arr[2]))
		var uid := String(raw.get("uid", ""))
		var rot_y := float(raw.get("rot_y", 0.0))
		var stored := clampf(float(raw.get("stored_water", 0.0)), 0.0, collector_capacity)
		var q := int(raw.get("water_quality", WaterQuality.Quality.RAINWATER))
		var anchored := bool(raw.get("anchored_to_trees", false))
		_spawn_collector(uid, pos, rot_y, stored, q, anchored)
		if _collectors.has(uid):
			_collectors[uid]["ash_load"] = clampf(float(raw.get("ash_load", 0)), 0, 1)


func _spawn_collector(uid: String, pos: Vector3, rot_y: float, stored_water: float, quality: int, anchored_to_trees: bool) -> void:
	if uid == "" or _collectors.has(uid):
		uid = "rc_%d" % _next_uid
		_next_uid += 1
	var root := Node3D.new()
	root.name = uid
	root.position = pos
	root.rotation.y = rot_y

	# Four corner support stakes.
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.04
	pole_mesh.bottom_radius = 0.05
	pole_mesh.height = 1.25
	for sx in [-0.95, 0.95]:
		for sz in [-0.95, 0.95]:
			var pmi := MeshInstance3D.new()
			pmi.mesh = pole_mesh
			pmi.material_override = _pole_mat
			pmi.position = Vector3(sx, 0.62, sz)
			root.add_child(pmi)

	# Sloped woven-leaf basin walls forming a shallow catchment tarp.
	var tarp_box := BoxMesh.new()
	tarp_box.size = Vector3(1.9, 0.06, 1.9)
	var tarp_mi := MeshInstance3D.new()
	tarp_mi.mesh = tarp_box
	tarp_mi.material_override = _tarp_mat
	tarp_mi.position = Vector3(0.0, 0.72, 0.0)
	root.add_child(tarp_mi)

	# Dynamic water fill plane.
	var water_box := BoxMesh.new()
	water_box.size = Vector3(1.65, 0.04, 1.65)
	var water_mi := MeshInstance3D.new()
	water_mi.mesh = water_box
	water_mi.material_override = _water_mat
	water_mi.position = Vector3(0.0, 0.76, 0.0)
	root.add_child(water_mi)

	# Lightweight collision so player doesn't walk straight through stakes.
	var body := StaticBody3D.new()
	body.collision_layer = 1
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(1.9, 0.85, 1.9)
	col.shape = shape
	col.position = Vector3(0.0, 0.45, 0.0)
	body.add_child(col)
	root.add_child(body)

	add_child(root)
	var entry := {
		"uid": uid,
		"pos": pos,
		"rot_y": rot_y,
		"stored_water": stored_water,
		"water_quality": quality,
		"anchored_to_trees": anchored_to_trees,
		"node": root,
		"water_mesh": water_mi,
	}
	_collectors[uid] = entry
	_update_collector_visual(entry)


func _update_collector_visual(entry: Dictionary) -> void:
	var wmi := entry.get("water_mesh", null) as MeshInstance3D
	if wmi == null:
		return
	var fill := clampf(float(entry["stored_water"]) / maxf(1.0, collector_capacity), 0.0, 1.0)
	wmi.visible = fill > 0.01
	wmi.position.y = lerpf(0.75, 0.94, fill)


func _count_nearby_trees(pos: Vector3, radius: float) -> int:
	if _resources == null:
		return 0
	var count := 0
	var r2 := radius * radius
	for node: Dictionary in _resources._nodes_by_id.values():
		var k: StringName = node["kind"]
		if k != &"tree" and k != &"palm_tree":
			continue
		var p: Vector3 = node["pos"]
		if Vector2(p.x - pos.x, p.z - pos.z).length_squared() <= r2:
			count += 1
			if count >= 2:
				return count
	return count


func _index_freshwater() -> void:
	for watershed: Dictionary in WATERWAYS.data:
		for channel: Dictionary in [watershed.river] + watershed.streams:
			for pt: Array in channel.points:
				var wp := Vector3(float(pt[0]), float(pt[2]), float(pt[1]))
				var key := _cell(wp.x, wp.z)
				if not _freshwater_cells.has(key):
					_freshwater_cells[key] = []
				_freshwater_cells[key].append(wp)


func _cell(x: float, z: float) -> Vector2i:
	return Vector2i(floori(x / CELL_SIZE), floori(z / CELL_SIZE))


func _build_materials() -> void:
	_tarp_mat = StandardMaterial3D.new()
	_tarp_mat.albedo_color = Color(0.26, 0.48, 0.23)
	_tarp_mat.roughness = 0.88

	_pole_mat = StandardMaterial3D.new()
	_pole_mat.albedo_color = Color(0.45, 0.30, 0.16)
	_pole_mat.roughness = 0.90

	_water_mat = StandardMaterial3D.new()
	_water_mat.albedo_color = Color(0.22, 0.68, 0.86, 0.82)
	_water_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_water_mat.roughness = 0.18

## A sheltered vessel keeps its existing water. Residue in exposed empty tarps
## washes through over time. Contaminated water already stored stays unsafe.
func expose_collectors(dt: float, wind: float) -> void:
	for entry: Dictionary in _collectors.values():
		var load := float(entry.get("ash_load", 0))
		if volcano.intensity <= 0 and load <= 0:
			continue
		var p: Vector3 = entry.pos + Vector3.UP
		if buildings.weather_cover(p).x > 0.0:
			continue
		var fallout := volcano.ash_at(p, wind, 0)
		load = clampf(load + dt * (fallout * .030 - .003), 0, 1)
		entry["ash_load"] = load
		if load >= .30 and float(entry.stored_water) > 0:
			entry["water_quality"] = WaterQuality.Quality.ASH_CONTAMINATED
