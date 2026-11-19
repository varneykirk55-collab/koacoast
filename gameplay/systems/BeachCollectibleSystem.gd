class_name BeachCollectibleSystem
extends Node3D
## Reusable sparkling overworld collectible system inspired by Pokemon ground pickups.
## Supports configurable collectible definitions, spawn regions, rarity, safe terrain
## filtering, persistence, and respawning.

signal collectible_picked(spot_id: String, def_id: StringName, item_id: StringName, amount: int, pos: Vector3)

const INTERACT_RANGE := 3.2
const WATERWAYS := preload("res://freshwater/watersheds.json")

var _terrain: Terrain3D
var _inventory: InventorySystem
var _database: GameDatabase
var _spots: Dictionary = {} # String -> Dictionary { id, def_id, pos, visual, active }
var _collected_until: Dictionary = {} # String -> float
var _elapsed_time := 0.0
var _water_points: Array[Vector2] = []
var _sparkle_material: StandardMaterial3D
var _sparkle_mesh: QuadMesh
var _initialized := false


func setup(terrain: Terrain3D, inventory: InventorySystem, database: GameDatabase) -> void:
	_terrain = terrain
	_inventory = inventory
	_database = database
	_build_sparkle_assets()
	_index_water_points()
	_populate_spawns.call_deferred()


func _process(delta: float) -> void:
	_elapsed_time += delta
	# Animate active sparkles gently and handle respawns.
	for id: String in _spots:
		var spot: Dictionary = _spots[id]
		if not spot["active"]:
			if _collected_until.has(id) and float(_collected_until[id]) <= _elapsed_time:
				_collected_until.erase(id)
				_set_spot_active(spot, true)
			continue
		var visual: Node3D = spot["visual"]
		if visual:
			var phase := float(spot["phase"])
			var pulse := 0.72 + 0.35 * sin(_elapsed_time * 3.8 + phase)
			visual.scale = Vector3.ONE * pulse
			visual.position.y = float(spot["base_y"]) + 0.24 + 0.05 * sin(_elapsed_time * 2.5 + phase)
			var star_b := visual.get_child(1) as Node3D
			if star_b:
				star_b.rotation.z = _elapsed_time * 1.4 + phase


func find_nearest_collectible(player_pos: Vector3) -> Dictionary:
	if not _initialized:
		return {}
	var best: Dictionary = {}
	var best_d2 := INTERACT_RANGE * INTERACT_RANGE
	for spot: Dictionary in _spots.values():
		if not spot["active"]:
			continue
		var pos: Vector3 = spot["pos"]
		if absf(pos.y - player_pos.y) > 2.2:
			continue
		var d2 := Vector2(pos.x - player_pos.x, pos.z - player_pos.z).length_squared()
		if d2 < best_d2:
			best_d2 = d2
			best = spot
	return best


func get_prompt_for_spot(spot: Dictionary) -> String:
	if spot.is_empty() or _database == null:
		return ""
	var def := _database.get_collectible(spot["def_id"])
	var label := def.display_name if def else "Collectible"
	return "Collect %s" % label


func collect(spot: Dictionary) -> Dictionary:
	if spot.is_empty() or _inventory == null or _database == null:
		return { "ok": false, "reason": "invalid" }
	var id: String = spot["id"]
	if not spot["active"]:
		return { "ok": false, "reason": "already_collected" }
	var def := _database.get_collectible(spot["def_id"])
	if def == null:
		return { "ok": false, "reason": "missing_def" }
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(id) ^ int(_elapsed_time * 7.0)
	var amt := rng.randi_range(def.min_amount, def.max_amount)
	if not _inventory.can_fit(def.item_id, amt):
		_inventory.inventory_full.emit(def.item_id)
		return { "ok": false, "reason": "inventory_full" }
	var added := _inventory.add_item(def.item_id, amt)
	if added <= 0:
		return { "ok": false, "reason": "inventory_full" }
	_set_spot_active(spot, false)
	_collected_until[id] = _elapsed_time + maxf(5.0, def.respawn_seconds)
	collectible_picked.emit(id, def.id, def.item_id, added, spot["pos"])
	return { "ok": true, "item_id": def.item_id, "amount": added }


func get_active_spot_positions() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for spot: Dictionary in _spots.values():
		if spot["active"]:
			out.append(spot["pos"])
	return out


func serialize() -> Dictionary:
	var collected := {}
	for id: String in _collected_until:
		var remaining := float(_collected_until[id]) - _elapsed_time
		if remaining > 0.5:
			collected[id] = snappedf(remaining, 0.1)
	return { "collected": collected }


func deserialize(data: Dictionary) -> void:
	_collected_until.clear()
	for spot: Dictionary in _spots.values():
		_set_spot_active(spot, true)
	if not data.has("collected") or not (data["collected"] is Dictionary):
		return
	var saved: Dictionary = data["collected"]
	for id_key in saved:
		var id := String(id_key)
		var remaining := float(saved[id_key])
		if remaining > 0.0 and _spots.has(id):
			_collected_until[id] = _elapsed_time + remaining
			_set_spot_active(_spots[id], false)


func reset_all() -> void:
	_collected_until.clear()
	for spot: Dictionary in _spots.values():
		_set_spot_active(spot, true)


func _populate_spawns() -> void:
	for _i in 4:
		await get_tree().process_frame
	if _terrain == null or _terrain.data == null:
		return
	var data := _terrain.data
	var rng := RandomNumberGenerator.new()
	rng.seed = 918273

	var candidates: Array[Vector3] = []
	# First include curated south black-sand coastal search range, then scan island shoreline.
	for z in range(-720, 740, 18):
		for x in range(-960, 960, 18):
			var jx := float(x) + rng.randf_range(-5.0, 5.0)
			var jz := float(z) + rng.randf_range(-5.0, 5.0)
			var p := Vector3(jx, 0.0, jz)
			if _is_valid_beach_spot(data, p):
				p.y = data.get_height(p)
				candidates.append(p)

	# Prioritize south beach near spawn plus distributed coastal beaches around the island.
	var selected: Array[Vector3] = []
	var south_beach: Array[Vector3] = []
	var other_beaches: Array[Vector3] = []
	for c in candidates:
		if Vector2(c.x - 48.0, c.z - 624.0).length() < 120.0:
			south_beach.append(c)
		else:
			other_beaches.append(c)

	_shuffle_with_rng(south_beach, rng)
	_shuffle_with_rng(other_beaches, rng)

	for c in south_beach:
		if _far_enough(c, selected, 22.0):
			selected.append(c)
			if selected.size() >= 6:
				break
	for c in other_beaches:
		if _far_enough(c, selected, 42.0):
			selected.append(c)
			if selected.size() >= 34:
				break

	for pos in selected:
		var def := _pick_collectible_def(rng)
		if def:
			_create_spot(def, pos, rng.randf() * TAU)
	_initialized = true


func _is_valid_beach_spot(data, p: Vector3) -> bool:
	var h: float = data.get_height(p)
	if not is_finite(h) or h < 0.45 or h > 4.2:
		return false
	var n: Vector3 = data.get_normal(p)
	if n.y < 0.90:
		return false
	var tex: Vector3 = data.get_texture_id(p)
	var sand := _surface_weight(tex, 3)
	if sand < 0.40:
		return false
	var xy := Vector2(p.x, p.z)
	for wp in _water_points:
		if xy.distance_squared_to(wp) < 36.0:
			return false
	# Ensure spot is not inside a rock deposit or solid prop.
	var space := get_world_3d().direct_space_state
	if space:
		var query := PhysicsPointQueryParameters3D.new()
		query.position = Vector3(p.x, h + 0.35, p.z)
		query.collision_mask = 1
		var hits := space.intersect_point(query, 4)
		for hit in hits:
			if hit.get("collider") != _terrain:
				return false
	return true


func _pick_collectible_def(rng: RandomNumberGenerator) -> CollectibleDef:
	if _database == null or _database.collectibles.is_empty():
		return null
	var total := 0.0
	for def: CollectibleDef in _database.collectibles.values():
		total += maxf(0.01, def.rarity_weight)
	var pick := rng.randf() * total
	var acc := 0.0
	for def: CollectibleDef in _database.collectibles.values():
		acc += maxf(0.01, def.rarity_weight)
		if pick <= acc:
			return def
	return _database.collectibles.values()[0] as CollectibleDef


func _create_spot(def: CollectibleDef, pos: Vector3, phase: float) -> void:
	var id := "col_%s_%d_%d" % [String(def.id), roundi(pos.x * 2.0), roundi(pos.z * 2.0)]
	if _spots.has(id):
		return
	var visual := Node3D.new()
	visual.name = id
	visual.position = Vector3(pos.x, pos.y + 0.24, pos.z)

	var quad_a := MeshInstance3D.new()
	quad_a.mesh = _sparkle_mesh
	quad_a.material_override = _sparkle_material
	quad_a.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	visual.add_child(quad_a)

	var quad_b := MeshInstance3D.new()
	quad_b.mesh = _sparkle_mesh
	quad_b.material_override = _sparkle_material
	quad_b.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	quad_b.rotation = Vector3(0.0, PI * 0.5, PI * 0.25)
	visual.add_child(quad_b)

	add_child(visual)
	var spot := {
		"id": id,
		"def_id": def.id,
		"pos": pos,
		"base_y": pos.y,
		"phase": phase,
		"visual": visual,
		"active": true,
	}
	_spots[id] = spot
	if _collected_until.has(id) and float(_collected_until[id]) > _elapsed_time:
		_set_spot_active(spot, false)


func _set_spot_active(spot: Dictionary, active: bool) -> void:
	spot["active"] = active
	var visual := spot.get("visual", null) as Node3D
	if visual:
		visual.visible = active


func _index_water_points() -> void:
	for watershed: Dictionary in WATERWAYS.data:
		for channel: Dictionary in [watershed.river] + watershed.streams:
			for pt: Array in channel.points:
				_water_points.append(Vector2(float(pt[0]), float(pt[1])))


func _surface_weight(texture: Vector3, surface: int) -> float:
	return (1.0 - texture.z if int(texture.x) == surface else 0.0) + (texture.z if int(texture.y) == surface else 0.0)


func _far_enough(pos: Vector3, existing: Array[Vector3], min_dist: float) -> bool:
	var min2 := min_dist * min_dist
	for other in existing:
		if Vector2(pos.x - other.x, pos.z - other.z).length_squared() < min2:
			return false
	return true


func _shuffle_with_rng(arr: Array[Vector3], rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


func _build_sparkle_assets() -> void:
	var tex_size := 32
	var img := Image.create(tex_size, tex_size, false, Image.FORMAT_RGBA8)
	var center := Vector2(15.5, 15.5)
	for y in tex_size:
		for x in tex_size:
			var d := Vector2(x, y) - center
			var ax := absf(d.x)
			var ay := absf(d.y)
			var star := exp(-(ax * 0.45 + ay * 0.08) * 1.4) + exp(-(ay * 0.45 + ax * 0.08) * 1.4)
			var core := exp(-d.length() * 0.32)
			var alpha := clampf((star * 0.7 + core) * 0.95, 0.0, 1.0)
			img.set_pixel(x, y, Color(1.0, 0.97, 0.80, alpha))
	var tex := ImageTexture.create_from_image(img)

	_sparkle_material = StandardMaterial3D.new()
	_sparkle_material.albedo_texture = tex
	_sparkle_material.albedo_color = Color(1.0, 0.97, 0.82, 0.92)
	_sparkle_material.emission_enabled = true
	_sparkle_material.emission = Color(1.0, 0.94, 0.72)
	_sparkle_material.emission_energy_multiplier = 1.6
	_sparkle_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_sparkle_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_sparkle_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_sparkle_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_sparkle_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED

	_sparkle_mesh = QuadMesh.new()
	_sparkle_mesh.size = Vector2(0.42, 0.42)
