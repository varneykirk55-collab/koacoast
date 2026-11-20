class_name DeathRecoverySystem
extends Node3D
## Centralized hardcore death, equipment-cache drop, safe respawn priority,
## and Survival Trauma recovery coordinator for KoaCoast.

signal death_started(cause: StringName, cause_label: String, cache_uid: String)
signal player_respawned(respawn_info: Dictionary, latest_cache_uid: String)
signal cache_recovered(uid: String, fully_emptied: bool, recovered_items: int, remaining_items: int)

@export_group("Death & Respawn Timing")
@export var collapse_duration := 2.4
@export var cache_interact_range := 3.4
@export var wildlife_safe_radius := 14.0

@export_group("Respawn Vitals")
@export var respawn_health_ratio := 0.60
@export var respawn_hunger := 40.0
@export var respawn_thirst := 40.0
@export var respawn_stamina_ratio := 0.50

var starting_spawn_pos := Vector3(48.0, 3.0, 576.0)
var has_home_shelter := false
var home_shelter_pos := Vector3.ZERO
var last_respawn_pos := Vector3(48.0, 3.0, 576.0)
var last_respawn_source: StringName = &"starting_spawn"

var _caches: Array[Dictionary] = []
var _next_cache_uid := 1
var _death_in_progress := false
var _collapse_timer := 0.0
var _pending_cause: StringName = &""
var _pending_cause_label := ""
var _latest_cache_uid := ""

var _terrain: Terrain3D
var _player: Node3D
var _inventory: InventorySystem
var _buildings: BuildingSystem
var _vitals: SurvivalVitalsSystem
var _day_night: DayNightSystem
var _wildlife: WildlifeSystem
var weather: TropicalWeather
var volcano: VolcanicHazards
var _caches_root: Node3D


func setup(terrain: Terrain3D, player: Node3D, inventory: InventorySystem, buildings: BuildingSystem, vitals: SurvivalVitalsSystem, day_night: DayNightSystem, wildlife: WildlifeSystem) -> void:
	_terrain = terrain
	_player = player
	_inventory = inventory
	_buildings = buildings
	_vitals = vitals
	_day_night = day_night
	_wildlife = wildlife

	if _player:
		starting_spawn_pos = _player.global_position
		last_respawn_pos = starting_spawn_pos

	if _caches_root == null:
		_caches_root = Node3D.new()
		_caches_root.name = "DeathCaches"
		add_child(_caches_root)

	if _vitals and not _vitals.player_died.is_connected(handle_player_death):
		_vitals.player_died.connect(handle_player_death)


func set_starting_spawn(pos: Vector3) -> void:
	starting_spawn_pos = pos
	if last_respawn_pos == Vector3.ZERO:
		last_respawn_pos = pos


func set_home_shelter(pos: Vector3) -> void:
	has_home_shelter = true
	home_shelter_pos = pos


func clear_home_shelter() -> void:
	has_home_shelter = false
	home_shelter_pos = Vector3.ZERO


func is_death_in_progress() -> bool:
	return _death_in_progress


func get_caches() -> Array[Dictionary]:
	return _caches


func get_cache_count() -> int:
	return _caches.size()


func clear_all() -> void:
	for c in _caches:
		var node := c.get("node", null) as Node3D
		if is_instance_valid(node):
			node.queue_free()
	_caches.clear()
	_next_cache_uid = 1
	_death_in_progress = false
	_collapse_timer = 0.0
	_latest_cache_uid = ""
	has_home_shelter = false
	home_shelter_pos = Vector3.ZERO
	last_respawn_pos = starting_spawn_pos
	last_respawn_source = &"starting_spawn"
	_restore_player_pose()


func handle_player_death(cause: StringName, cause_label: String) -> void:
	# Prevent repeated death triggers, duplicate drops, or simultaneous respawns.
	if _death_in_progress:
		return
	_death_in_progress = true
	_collapse_timer = collapse_duration
	_pending_cause = cause
	_pending_cause_label = cause_label if not cause_label.is_empty() else "Survival Hazard"

	# Immediately lock player movement & interactions.
	if _player:
		if "gameplay_input_blocked" in _player:
			_player.set("gameplay_input_blocked", true)
		if _player is CharacterBody3D:
			(_player as CharacterBody3D).velocity = Vector3.ZERO

	# Atomically transfer all carried inventory & equipment into a recoverable death cache.
	var original_pos := _player.global_position if _player else starting_spawn_pos
	var dropped_items: Array[Dictionary] = _inventory.extract_all_slots() if _inventory else []
	var cache_uid := ""
	if not dropped_items.is_empty():
		var valid_pos := find_valid_cache_position(original_pos)
		var entry := _create_cache_entry(valid_pos, original_pos, _pending_cause_label, dropped_items)
		cache_uid = String(entry["uid"])
		_latest_cache_uid = cache_uid

	death_started.emit(_pending_cause, _pending_cause_label, cache_uid)


func _process(delta: float) -> void:
	if not _death_in_progress:
		return
	_collapse_timer -= delta
	var progress := clampf(1.0 - (_collapse_timer / maxf(0.05, collapse_duration)), 0.0, 1.0)
	if _player:
		var visual := _player.get_node_or_null("Visual") as Node3D
		if visual:
			visual.rotation.z = lerpf(0.0, deg_to_rad(78.0), minf(1.0, progress * 2.2))
			visual.position.y = lerpf(0.0, -0.35, minf(1.0, progress * 2.2))
		if _player is CharacterBody3D:
			(_player as CharacterBody3D).velocity = Vector3.ZERO
	if _collapse_timer <= 0.0:
		complete_respawn_now()


## Completes the pending respawn immediately (called automatically after collapse_duration or by tests).
func complete_respawn_now() -> Dictionary:
	if not _death_in_progress:
		return { "ok": false, "reason": "no_death_in_progress" }
	_death_in_progress = false
	_collapse_timer = 0.0

	var respawn_info := resolve_respawn_location()
	var target_pos: Vector3 = respawn_info["pos"]
	last_respawn_pos = target_pos
	last_respawn_source = respawn_info["source"]

	_restore_player_pose()
	if _player:
		_player.global_position = target_pos
		if _player is CharacterBody3D:
			(_player as CharacterBody3D).velocity = Vector3.ZERO
		var pivot := _player.get_node_or_null("CameraPivot") as Node3D
		if pivot:
			pivot.global_position = target_pos + Vector3.UP * 1.55
		if "gameplay_input_blocked" in _player:
			_player.set("gameplay_input_blocked", false)

	# Apply Survival Trauma for one complete in-game day-night cycle (resets duration on repeated deaths).
	var trauma_duration := _day_night.get_total_cycle_seconds() if _day_night else 720.0
	if _vitals:
		_vitals.apply_survival_trauma(trauma_duration)
		_vitals.apply_respawn_vitals(respawn_health_ratio, respawn_hunger, respawn_thirst, respawn_stamina_ratio)

	player_respawned.emit(respawn_info, _latest_cache_uid)
	return { "ok": true, "pos": target_pos, "source": last_respawn_source }


# --- Death Cache Creation & Recovery ------------------------------------------

func find_nearest_cache(player_pos: Vector3) -> Dictionary:
	var best: Dictionary = {}
	var best_d2 := cache_interact_range * cache_interact_range
	for c in _caches:
		var p: Vector3 = c["pos"]
		if absf(p.y - player_pos.y) > 2.8:
			continue
		var d2 := Vector2(p.x - player_pos.x, p.z - player_pos.z).length_squared()
		if d2 < best_d2:
			best_d2 = d2
			best = c
	return best


func recover_cache(uid: String) -> Dictionary:
	if _inventory == null:
		return { "ok": false, "reason": "No inventory" }
	var idx := -1
	for i in _caches.size():
		if String(_caches[i]["uid"]) == uid:
			idx = i
			break
	if idx == -1:
		return { "ok": false, "reason": "Cache not found" }

	var cache: Dictionary = _caches[idx]
	var items: Array = cache["items"]
	var remaining: Array[Dictionary] = []
	var recovered_total := 0
	var remaining_total := 0

	for raw_entry in items:
		if not (raw_entry is Dictionary):
			continue
		var entry: Dictionary = raw_entry.duplicate(true)
		var amt := int(entry.get("amount", 0))
		if amt <= 0:
			continue
		var added := _inventory.add_slot_entry(entry)
		recovered_total += added
		var leftover := amt - added
		if leftover > 0:
			entry["amount"] = leftover
			remaining.append(entry)
			remaining_total += leftover

	cache["items"] = remaining
	var fully_emptied := remaining.is_empty()
	if fully_emptied:
		var node := cache.get("node", null) as Node3D
		if is_instance_valid(node):
			node.queue_free()
		_caches.remove_at(idx)
		if _latest_cache_uid == uid:
			_latest_cache_uid = String(_caches[_caches.size() - 1]["uid"]) if not _caches.is_empty() else ""

	cache_recovered.emit(uid, fully_emptied, recovered_total, remaining_total)
	return {
		"ok": recovered_total > 0 or fully_emptied,
		"recovered_items": recovered_total,
		"remaining_items": remaining_total,
		"fully_emptied": fully_emptied,
	}


func get_latest_cache_indicator(player_pos: Vector3) -> Dictionary:
	if _caches.is_empty():
		return { "active": false }
	var target: Dictionary = _caches[_caches.size() - 1]
	for c in _caches:
		if String(c["uid"]) == _latest_cache_uid:
			target = c
			break
	var cpos: Vector3 = target["pos"]
	var delta := cpos - player_pos
	var dist := Vector2(delta.x, delta.z).length()
	var dir_label := _compass_direction(delta.x, delta.z)
	return {
		"active": true,
		"uid": String(target["uid"]),
		"pos": cpos,
		"distance": dist,
		"direction": dir_label,
		"item_count": _count_cache_items(target),
	}


# --- Respawn Location & Safety Checks -----------------------------------------

func resolve_respawn_location() -> Dictionary:
	# Priority 1: Player-designated home shelter (if still valid).
	if has_home_shelter and _buildings and _buildings.has_shelter_near(home_shelter_pos, 14.0):
		var safe_home := _find_safe_respawn_near(home_shelter_pos, 14.0)
		if safe_home != Vector3.INF:
			return { "pos": safe_home, "source": &"home_shelter" }

	# Priority 2: Nearest valid constructed campfire (lit OR unlit).
	if _buildings:
		var campfires: Array[Dictionary] = _buildings.get_all_campfires()
		if not campfires.is_empty():
			var ref_pos := _player.global_position if _player else starting_spawn_pos
			campfires.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				return (a["pos"] as Vector3).distance_squared_to(ref_pos) < (b["pos"] as Vector3).distance_squared_to(ref_pos)
			)
			for cf in campfires:
				var safe_fire := _find_safe_respawn_near(cf["pos"] as Vector3, 14.0)
				if safe_fire != Vector3.INF:
					return { "pos": safe_fire, "source": &"campfire" }

	# Priority 3: Original safe starting location.
	var safe_start := _find_safe_respawn_near(starting_spawn_pos, 22.0)
	if safe_start != Vector3.INF:
		return { "pos": safe_start, "source": &"starting_spawn" }

	return { "pos": starting_spawn_pos, "source": &"starting_spawn" }


func find_valid_cache_position(death_pos: Vector3) -> Vector3:
	if _is_valid_cache_spot(death_pos):
		var h := _sample_height(death_pos)
		return Vector3(death_pos.x, h if is_finite(h) else death_pos.y, death_pos.z)

	# Spiral outward to find the nearest valid, reachable land spot (never underwater or on steep cliffs).
	var radii: Array[float] = [2.5, 5.0, 9.0, 15.0, 24.0, 36.0, 52.0, 75.0, 105.0, 145.0, 200.0]
	for rad in radii:
		var steps := 16
		for i in steps:
			var a := (float(i) / float(steps)) * TAU
			var cand := Vector3(
				clampf(death_pos.x + cos(a) * rad, -860.0, 860.0),
				0.0,
				clampf(death_pos.z + sin(a) * rad, -860.0, 860.0)
			)
			if _is_valid_cache_spot(cand):
				return Vector3(cand.x, _sample_height(cand), cand.z)

	# Fallback to nearest safe point around starting shore (never permanently unreachable).
	var fallback := _find_safe_respawn_near(starting_spawn_pos, 18.0)
	return fallback if fallback != Vector3.INF else starting_spawn_pos


func _is_valid_cache_spot(pos: Vector3) -> bool:
	if absf(pos.x) > 880.0 or absf(pos.z) > 880.0:
		return false
	var h := _sample_height(pos)
	if not is_finite(h) or h < 0.45 or h > 220.0:
		return false
	var n := _sample_normal(pos)
	if n.y < 0.78:
		return false
	var grounded := Vector3(pos.x, h, pos.z)
	if _buildings and _buildings.is_position_blocked_by_structure(grounded, 0.7):
		return false
	if weather and weather.flood_depth(grounded) > 0.45:
		return false
	if volcano and (volcano.in_mud(grounded) or volcano.heat_at(grounded) > 0.20):
		return false
	return true


func _find_safe_respawn_near(origin: Vector3, max_radius: float) -> Vector3:
	# Check small offsets around origin first (offset slightly from campfire/wall centers).
	var ring_radii: Array[float] = [2.2, 3.8, 5.5, 8.0, 11.0, max_radius]
	if _is_safe_respawn_spot(origin):
		var h0 := _sample_height(origin)
		return Vector3(origin.x, (h0 if is_finite(h0) else origin.y) + 0.08, origin.z)
	for rad in ring_radii:
		if rad > max_radius + 0.1:
			continue
		for i in 12:
			var a := (float(i) / 12.0) * TAU
			var cand := Vector3(origin.x + cos(a) * rad, 0.0, origin.z + sin(a) * rad)
			if _is_safe_respawn_spot(cand):
				var h := _sample_height(cand)
				return Vector3(cand.x, h + 0.08, cand.z)
	return Vector3.INF


func _is_safe_respawn_spot(pos: Vector3) -> bool:
	if absf(pos.x) > 880.0 or absf(pos.z) > 880.0:
		return false
	var h := _sample_height(pos)
	if not is_finite(h) or h < 0.65 or h > 200.0:
		return false
	var n := _sample_normal(pos)
	if n.y < 0.82:
		return false
	var grounded := Vector3(pos.x, h, pos.z)
	if _buildings and _buildings.is_position_blocked_by_structure(grounded, 0.95):
		return false
	if weather and weather.flood_depth(grounded) > 0.25:
		return false
	if volcano and (volcano.in_mud(grounded) or volcano.heat_at(grounded) > 0.12):
		return false
	if _wildlife:
		for pig in _wildlife.pigs:
			if (pig["pos"] as Vector3).distance_to(grounded) < wildlife_safe_radius:
				return false
		for shark in _wildlife.sharks:
			if (shark["pos"] as Vector3).distance_to(grounded) < wildlife_safe_radius:
				return false
	return true


# --- Serialization ------------------------------------------------------------

func serialize() -> Dictionary:
	var out_caches: Array[Dictionary] = []
	for c in _caches:
		var p: Vector3 = c["pos"]
		var orig: Vector3 = c["original_death_pos"]
		var serialized_items: Array[Dictionary] = []
		for item in c["items"]:
			if not (item is Dictionary) or int(item.get("amount", 0)) <= 0:
				continue
			var row := {
				"item_id": String(item.get("item_id", "")),
				"amount": int(item.get("amount", 0)),
			}
			if item.has("water_amount"):
				row["water_amount"] = float(item["water_amount"])
				row["water_quality"] = int(item.get("water_quality", WaterQuality.Quality.CLEAN_FRESHWATER))
			if item.has("metadata") and item["metadata"] is Dictionary:
				row["metadata"] = (item["metadata"] as Dictionary).duplicate(true)
			serialized_items.append(row)
		out_caches.append({
			"uid": String(c["uid"]),
			"pos": [p.x, p.y, p.z],
			"original_death_pos": [orig.x, orig.y, orig.z],
			"cause_label": String(c.get("cause_label", "")),
			"created_day": int(c.get("created_day", 1)),
			"items": serialized_items,
		})
	return {
		"next_cache_uid": _next_cache_uid,
		"latest_cache_uid": _latest_cache_uid,
		"has_home_shelter": has_home_shelter,
		"home_shelter_pos": [home_shelter_pos.x, home_shelter_pos.y, home_shelter_pos.z],
		"last_respawn_pos": [last_respawn_pos.x, last_respawn_pos.y, last_respawn_pos.z],
		"last_respawn_source": String(last_respawn_source),
		"caches": out_caches,
	}


func deserialize(data: Dictionary) -> void:
	clear_all()
	if data.is_empty():
		return
	_next_cache_uid = maxi(1, int(data.get("next_cache_uid", 1)))
	_latest_cache_uid = String(data.get("latest_cache_uid", ""))
	has_home_shelter = bool(data.get("has_home_shelter", false))
	var h_arr = data.get("home_shelter_pos", [])
	if h_arr is Array and h_arr.size() >= 3:
		home_shelter_pos = Vector3(float(h_arr[0]), float(h_arr[1]), float(h_arr[2]))
	var r_arr = data.get("last_respawn_pos", [])
	if r_arr is Array and r_arr.size() >= 3:
		last_respawn_pos = Vector3(float(r_arr[0]), float(r_arr[1]), float(r_arr[2]))
	last_respawn_source = StringName(String(data.get("last_respawn_source", "starting_spawn")))

	if data.has("caches") and data["caches"] is Array:
		for raw in data["caches"]:
			if not (raw is Dictionary):
				continue
			var p_arr = raw.get("pos", [])
			if not (p_arr is Array) or p_arr.size() < 3:
				continue
			var pos := Vector3(float(p_arr[0]), float(p_arr[1]), float(p_arr[2]))
			var orig_arr = raw.get("original_death_pos", p_arr)
			var orig := Vector3(float(orig_arr[0]), float(orig_arr[1]), float(orig_arr[2])) if (orig_arr is Array and orig_arr.size() >= 3) else pos
			var loaded_items: Array[Dictionary] = []
			if raw.has("items") and raw["items"] is Array:
				for raw_item in raw["items"]:
					if not (raw_item is Dictionary):
						continue
					var iid := StringName(String(raw_item.get("item_id", "")))
					var amt := int(raw_item.get("amount", 0))
					if iid == &"" or amt <= 0:
						continue
					var item_entry := { "item_id": iid, "amount": amt }
					if raw_item.has("water_amount"):
						item_entry["water_amount"] = float(raw_item["water_amount"])
						item_entry["water_quality"] = int(raw_item.get("water_quality", WaterQuality.Quality.CLEAN_FRESHWATER))
					if raw_item.has("metadata") and raw_item["metadata"] is Dictionary:
						item_entry["metadata"] = (raw_item["metadata"] as Dictionary).duplicate(true)
					loaded_items.append(item_entry)
			if loaded_items.is_empty():
				continue
			var uid := String(raw.get("uid", ""))
			_create_cache_entry(pos, orig, String(raw.get("cause_label", "")), loaded_items, uid, int(raw.get("created_day", 1)))


# --- Internal Visuals & Helpers -----------------------------------------------

func _create_cache_entry(pos: Vector3, original_pos: Vector3, cause_label: String, items: Array[Dictionary], explicit_uid := "", created_day := -1) -> Dictionary:
	var uid := explicit_uid if not explicit_uid.is_empty() else "cache_%d" % _next_cache_uid
	_next_cache_uid = maxi(_next_cache_uid + 1, _caches.size() + 2)
	var day_val := created_day if created_day > 0 else (_day_night.day_number if _day_night else 1)

	var node := _build_cache_mesh(uid)
	if _caches_root:
		_caches_root.add_child(node)
	node.global_position = pos

	var entry := {
		"uid": uid,
		"pos": pos,
		"original_death_pos": original_pos,
		"cause_label": cause_label,
		"created_day": day_val,
		"items": items,
		"node": node,
	}
	_caches.append(entry)
	return entry


func _build_cache_mesh(uid: String) -> Node3D:
	var root := Node3D.new()
	root.name = uid

	var stone_mat := StandardMaterial3D.new()
	stone_mat.albedo_color = Color(0.28, 0.27, 0.26)
	stone_mat.roughness = 0.90

	var pack_mat := StandardMaterial3D.new()
	pack_mat.albedo_color = Color(0.54, 0.42, 0.25)
	pack_mat.roughness = 0.85

	var wood_mat := StandardMaterial3D.new()
	wood_mat.albedo_color = Color(0.38, 0.24, 0.14)
	wood_mat.roughness = 0.88

	# Basalt cairn base
	var cairn := MeshInstance3D.new()
	var cmesh := CylinderMesh.new()
	cmesh.top_radius = 0.42
	cmesh.bottom_radius = 0.56
	cmesh.height = 0.26
	cairn.mesh = cmesh
	cairn.material_override = stone_mat
	cairn.position = Vector3(0.0, 0.13, 0.0)
	root.add_child(cairn)

	# Woven survival supply bundle
	var pack := MeshInstance3D.new()
	var pmesh := BoxMesh.new()
	pmesh.size = Vector3(0.55, 0.36, 0.42)
	pack.mesh = pmesh
	pack.material_override = pack_mat
	pack.position = Vector3(0.0, 0.42, 0.08)
	root.add_child(pack)

	# Wooden marker post
	var post := MeshInstance3D.new()
	var post_m := CylinderMesh.new()
	post_m.top_radius = 0.045
	post_m.bottom_radius = 0.06
	post_m.height = 1.15
	post.mesh = post_m
	post.material_override = wood_mat
	post.position = Vector3(0.0, 0.65, -0.22)
	root.add_child(post)

	# Subtle warm glow so cache is spotable at dusk/night
	var beacon := OmniLight3D.new()
	beacon.light_color = Color(1.0, 0.82, 0.48)
	beacon.light_energy = 1.2
	beacon.omni_range = 6.5
	beacon.position = Vector3(0.0, 1.15, -0.22)
	root.add_child(beacon)

	return root


func _restore_player_pose() -> void:
	if _player == null:
		return
	var visual := _player.get_node_or_null("Visual") as Node3D
	if visual:
		visual.rotation.z = 0.0
		visual.position.y = 0.0


func _count_cache_items(cache: Dictionary) -> int:
	var total := 0
	for item in cache.get("items", []):
		if item is Dictionary:
			total += int(item.get("amount", 0))
	return total


func _compass_direction(dx: float, dz: float) -> String:
	# In Godot -Z is North, +X is East.
	var angle := rad_to_deg(atan2(dx, -dz))
	if angle < 0.0:
		angle += 360.0
	var dirs := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
	return dirs[int(round(angle / 45.0)) % 8]


func _sample_height(pos: Vector3) -> float:
	if _terrain and _terrain.data:
		return _terrain.data.get_height(pos)
	return NAN


func _sample_normal(pos: Vector3) -> Vector3:
	if _terrain and _terrain.data:
		var n := _terrain.data.get_normal(pos)
		if n.is_finite() and n.length_squared() > 0.01:
			return n.normalized()
	return Vector3.UP
