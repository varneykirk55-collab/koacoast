class_name WildlifeSystem
extends Node3D
## Modular nocturnal & daytime wildlife simulation for KoaCoast:
## - Wild Pigs (Hawaiian feral boars): forage/flee by day, bolder/territorial at night,
##   investigate nearby camps via sensory range (no magic global tracking), scratch/damage
##   unreinforced exterior shelter walls, and retreat from active campfires, reinforced walls,
##   or direct player confrontation.
## - Reef Sharks: patrol valid coastal reef waters, become more active after dark, detect
##   swimmers via proximity & movement, circle with a clear warning before attacking, and
##   break off immediately when the player escapes to shallow water or shore.
## Note: Uses clearly identifiable procedural 3D placeholder meshes until dedicated art assets are added.

signal wildlife_warning(category: StringName, message: String, world_pos: Vector3)

const WATER_LEVEL := 0.0
const PIG_COUNT := 7
const SHARK_COUNT := 4

const PIG_DAY_FLEE_RADIUS := 12.0
const PIG_CORNERED_RADIUS := 3.5
const PIG_SHELTER_DETECT_RADIUS := 32.0
const PIG_CAMPFIRE_DETER_RADIUS := 9.5
const PIG_CONFRONT_RADIUS := 4.5
const PIG_SCRATCH_RANGE := 2.6
const PIG_SCRATCH_INTERVAL := 2.2
const PIG_SCRATCH_DAMAGE := 12.0
const PIG_FAR_THROTTLE_DIST := 120.0

const SHARK_MIN_WATER_HEIGHT := -18.0
const SHARK_MAX_WATER_HEIGHT := -0.75
const SHARK_SWIM_Y := -0.55
const SHARK_DAY_DETECT_RADIUS := 14.0
const SHARK_NIGHT_DETECT_RADIUS := 28.0
const SHARK_INVESTIGATE_TIME := 3.0
const SHARK_BITE_DAMAGE := 32.0
const SHARK_BITE_RANGE := 2.3
const SHARK_BITE_COOLDOWN := 2.6

var pigs: Array[Dictionary] = []
var sharks: Array[Dictionary] = []

var _terrain: Terrain3D
var _player: Node3D
var _day_night: DayNightSystem
var _buildings: BuildingSystem
var _vitals: SurvivalVitalsSystem
var _audio: AudioFeedback

var _pigs_root: Node3D
var _sharks_root: Node3D
var _rng := RandomNumberGenerator.new()
var _sim_time := 0.0
var _last_player_pos := Vector3.ZERO
var _player_speed := 0.0
var _alert_cooldown := 0.0
var _initialized := false


func setup(terrain: Terrain3D, player: Node3D, day_night: DayNightSystem, buildings: BuildingSystem, vitals: SurvivalVitalsSystem, audio: AudioFeedback) -> void:
	_terrain = terrain
	_player = player
	_day_night = day_night
	_buildings = buildings
	_vitals = vitals
	_audio = audio

	if _pigs_root == null:
		_pigs_root = Node3D.new()
		_pigs_root.name = "WildPigs"
		add_child(_pigs_root)
	if _sharks_root == null:
		_sharks_root = Node3D.new()
		_sharks_root.name = "ReefSharks"
		add_child(_sharks_root)

	if _player:
		_last_player_pos = _player.global_position
	_rng.seed = 904217
	_spawn_all()
	_initialized = true


func reset_all() -> void:
	for p in pigs:
		var node := p.get("node", null) as Node3D
		if is_instance_valid(node):
			node.queue_free()
	pigs.clear()
	for s in sharks:
		var node := s.get("node", null) as Node3D
		if is_instance_valid(node):
			node.queue_free()
	sharks.clear()
	_rng.seed = 904217
	_sim_time = 0.0
	_alert_cooldown = 0.0
	_spawn_all()


func _process(delta: float) -> void:
	if not _initialized:
		return
	step_simulation(delta)


func step_simulation(delta: float) -> void:
	if delta <= 0.0:
		return
	_sim_time += delta
	_alert_cooldown = maxf(0.0, _alert_cooldown - delta)

	if _player:
		var cur := _player.global_position
		_player_speed = cur.distance_to(_last_player_pos) / maxf(0.001, delta)
		_last_player_pos = cur

	var is_night := _day_night.is_night() if _day_night else false
	var active_fires: Array[Dictionary] = _buildings.get_active_campfires() if _buildings else []
	var shelter_pieces: Array[Dictionary] = _buildings.get_exterior_shelter_pieces() if _buildings else []

	for pig in pigs:
		_update_pig(pig, delta, is_night, active_fires, shelter_pieces)

	for shark in sharks:
		_update_shark(shark, delta, is_night)


func trigger_shelter_threat_test() -> Dictionary:
	if _day_night and not _day_night.is_night():
		_day_night.set_to_phase(&"night")
	var pieces: Array[Dictionary] = _buildings.get_exterior_shelter_pieces() if _buildings else []
	if pieces.is_empty():
		return { "ok": false, "reason": "No exterior shelter wall/doorway placed yet. Build a wall first." }

	var ref_pos := _player.global_position if _player else (pieces[0]["pos"] as Vector3)
	var target_piece: Dictionary = pieces[0]
	var best_score := INF
	for piece in pieces:
		var d := (piece["pos"] as Vector3).distance_to(ref_pos)
		var is_wall_like: bool = (piece["piece_id"] == &"wall" or piece["piece_id"] == &"doorway")
		var score := d - (100.0 if is_wall_like else 0.0)
		if score < best_score:
			best_score = score
			target_piece = piece

	if pigs.is_empty():
		return { "ok": false, "reason": "No wild pigs spawned" }

	var pig := pigs[0]
	var tpos: Vector3 = target_piece["pos"]
	var spawn_dir := Vector3(1.0, 0.0, 0.4).normalized()
	var test_pos := tpos + spawn_dir * 7.5
	var gh := _sample_height(test_pos)
	if is_finite(gh) and gh > 0.3:
		test_pos.y = gh
	else:
		test_pos = tpos + Vector3(2.2, 0.0, 0.0)
	pig["pos"] = test_pos
	pig["home"] = test_pos
	pig["state"] = &"investigate_camp"
	pig["target_uid"] = String(target_piece["uid"])
	pig["scratch_timer"] = 0.25
	pig["resist_hits"] = 0
	pig["retreat_timer"] = 0.0
	var node := pig["node"] as Node3D
	if is_instance_valid(node):
		node.global_position = test_pos
	_emit_alert(&"shelter_threat", "Debug Threat: Wild boar prowling near shelter!", test_pos, true)
	return { "ok": true, "pig_id": String(pig["id"]), "target_uid": String(target_piece["uid"]) }


func get_debug_summary() -> String:
	var pig_counts: Dictionary = {}
	var nearest_pig_d := INF
	var nearest_shark_d := INF
	var ppos := _player.global_position if _player else Vector3.ZERO
	for pig in pigs:
		var st := String(pig["state"])
		pig_counts[st] = int(pig_counts.get(st, 0)) + 1
		if _player:
			nearest_pig_d = minf(nearest_pig_d, (pig["pos"] as Vector3).distance_to(ppos))
	var shark_counts: Dictionary = {}
	for shark in sharks:
		var st := String(shark["state"])
		shark_counts[st] = int(shark_counts.get(st, 0)) + 1
		if _player:
			nearest_shark_d = minf(nearest_shark_d, (shark["pos"] as Vector3).distance_to(ppos))

	var p_parts: Array[String] = []
	for k in pig_counts:
		p_parts.append("%s:%d" % [k, int(pig_counts[k])])
	var s_parts: Array[String] = []
	for k in shark_counts:
		s_parts.append("%s:%d" % [k, int(shark_counts[k])])
	var p_dist := "%.0fm" % nearest_pig_d if nearest_pig_d < 9000.0 else "n/a"
	var s_dist := "%.0fm" % nearest_shark_d if nearest_shark_d < 9000.0 else "n/a"
	return "Pigs(%d, near %s): %s | Sharks(%d, near %s): %s" % [
		pigs.size(), p_dist, ", ".join(p_parts),
		sharks.size(), s_dist, ", ".join(s_parts),
	]


func get_pig_states() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for pig in pigs:
		out.append({
			"id": pig["id"],
			"state": pig["state"],
			"pos": pig["pos"],
			"target_uid": pig["target_uid"],
		})
	return out


func get_shark_states() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for shark in sharks:
		out.append({
			"id": shark["id"],
			"state": shark["state"],
			"pos": shark["pos"],
		})
	return out


# --- Spawning -----------------------------------------------------------------

func _spawn_all() -> void:
	_spawn_pigs()
	_spawn_sharks()


func _spawn_pigs() -> void:
	var player_pos := _player.global_position if _player else Vector3(48.0, 3.0, 576.0)
	var candidate_rings: Array[Vector2] = [
		Vector2(48.0, 520.0), Vector2(110.0, 540.0), Vector2(-35.0, 510.0),
		Vector2(170.0, 440.0), Vector2(-120.0, 460.0), Vector2(20.0, 400.0),
		Vector2(220.0, 320.0), Vector2(-190.0, 340.0), Vector2(95.0, 290.0),
		Vector2(-60.0, 250.0), Vector2(260.0, 180.0), Vector2(-240.0, 200.0),
	]
	var spawned := 0
	for base_xz in candidate_rings:
		if spawned >= PIG_COUNT:
			break
		var pos := _find_valid_pig_spot(base_xz, player_pos)
		if pos == Vector3.ZERO:
			continue
		spawned += 1
		var pid := "pig_%d" % spawned
		var mesh_root := _build_pig_mesh(pid)
		_pigs_root.add_child(mesh_root)
		mesh_root.global_position = pos
		pigs.append({
			"id": pid,
			"node": mesh_root,
			"pos": pos,
			"home": pos,
			"waypoint": pos,
			"state": &"forage",
			"state_timer": _rng.randf_range(2.0, 5.0),
			"yaw": _rng.randf_range(0.0, TAU),
			"target_uid": "",
			"scratch_timer": 0.0,
			"bite_cooldown": 0.0,
			"retreat_timer": 0.0,
			"deter_cooldown": 0.0,
			"resist_hits": 0,
			"throttle_acc": 0.0,
		})


func _find_valid_pig_spot(center_xz: Vector2, avoid_pos: Vector3) -> Vector3:
	for attempt in 24:
		var angle := _rng.randf_range(0.0, TAU)
		var rad := _rng.randf_range(0.0, 55.0) if attempt > 0 else 0.0
		var x := center_xz.x + cos(angle) * rad
		var z := center_xz.y + sin(angle) * rad
		var p := Vector3(x, 0.0, z)
		var h := _sample_height(p)
		if not is_finite(h) or h < 1.5 or h > 72.0:
			continue
		var n := _sample_normal(p)
		if n.y < 0.85:
			continue
		var candidate := Vector3(x, h, z)
		if candidate.distance_to(avoid_pos) < 28.0:
			continue
		var too_close := false
		for existing in pigs:
			if (existing["pos"] as Vector3).distance_to(candidate) < 26.0:
				too_close = true
				break
		if not too_close:
			return candidate
	return Vector3.ZERO


func _spawn_sharks() -> void:
	var player_pos := _player.global_position if _player else Vector3(48.0, 3.0, 576.0)
	var coastal_anchors: Array[Vector2] = [
		Vector2(48.0, 680.0), Vector2(210.0, 650.0), Vector2(-140.0, 660.0),
		Vector2(420.0, 520.0), Vector2(-380.0, 520.0), Vector2(580.0, 120.0),
		Vector2(-560.0, 160.0), Vector2(80.0, -680.0),
	]
	var spawned := 0
	for base_xz in coastal_anchors:
		if spawned >= SHARK_COUNT:
			break
		var pos := _find_valid_shark_spot(base_xz, player_pos)
		if pos == Vector3.ZERO:
			continue
		spawned += 1
		var sid := "shark_%d" % spawned
		var mesh_root := _build_shark_mesh(sid)
		_sharks_root.add_child(mesh_root)
		mesh_root.global_position = pos
		sharks.append({
			"id": sid,
			"node": mesh_root,
			"pos": pos,
			"home": pos,
			"waypoint": pos,
			"state": &"patrol",
			"yaw": _rng.randf_range(0.0, TAU),
			"investigate_timer": 0.0,
			"circle_angle": _rng.randf_range(0.0, TAU),
			"bite_cooldown": 0.0,
			"warned": false,
		})


func _find_valid_shark_spot(center_xz: Vector2, avoid_pos: Vector3) -> Vector3:
	for attempt in 30:
		var angle := _rng.randf_range(0.0, TAU)
		var rad := _rng.randf_range(0.0, 80.0) if attempt > 0 else 0.0
		var x := center_xz.x + cos(angle) * rad
		var z := center_xz.y + sin(angle) * rad
		var h := _sample_height(Vector3(x, 0.0, z))
		if not is_finite(h) or h > -1.2 or h < SHARK_MIN_WATER_HEIGHT:
			continue
		var candidate := Vector3(x, SHARK_SWIM_Y, z)
		if candidate.distance_to(avoid_pos) < 28.0:
			continue
		var too_close := false
		for existing in sharks:
			if (existing["pos"] as Vector3).distance_to(candidate) < 45.0:
				too_close = true
				break
		if not too_close:
			return candidate
	return Vector3.ZERO


# --- Wild Pig AI --------------------------------------------------------------

func _update_pig(pig: Dictionary, delta: float, is_night: bool, active_fires: Array[Dictionary], shelter_pieces: Array[Dictionary]) -> void:
	var pos: Vector3 = pig["pos"]
	var ppos := _player.global_position if _player else Vector3(9999.0, 0.0, 9999.0)
	var dist_player := pos.distance_to(ppos)

	# Distance throttling for distant pigs outside shelter interactions.
	var state: StringName = pig["state"]
	if dist_player > PIG_FAR_THROTTLE_DIST and state != &"investigate_camp" and state != &"scratch_shelter":
		pig["throttle_acc"] = float(pig["throttle_acc"]) + delta
		if float(pig["throttle_acc"]) < 0.5:
			return
		delta = float(pig["throttle_acc"])
		pig["throttle_acc"] = 0.0

	pig["bite_cooldown"] = maxf(0.0, float(pig["bite_cooldown"]) - delta)
	pig["retreat_timer"] = maxf(0.0, float(pig["retreat_timer"]) - delta)
	pig["deter_cooldown"] = maxf(0.0, float(pig.get("deter_cooldown", 0.0)) - delta)
	pig["state_timer"] = maxf(0.0, float(pig["state_timer"]) - delta)

	# Active campfire deterrence (both day and night, especially important at night).
	var near_fire := _find_nearest_fire(pos, active_fires, PIG_CAMPFIRE_DETER_RADIUS)
	if not near_fire.is_empty():
		var fpos: Vector3 = near_fire["pos"]
		var away := (pos - fpos)
		away.y = 0.0
		if away.length_squared() < 0.01:
			away = Vector3.RIGHT
		pig["waypoint"] = pos + away.normalized() * 18.0
		if state != &"retreat":
			pig["state"] = &"retreat"
			pig["retreat_timer"] = 4.0
			pig["target_uid"] = ""
			if _audio:
				_audio.play_spatial(&"pig_grunt", pos)
			if dist_player < 26.0:
				_emit_alert(&"campfire_deter", "Campfire drove away a prowling wild boar!", pos)

	state = pig["state"]

	if state == &"retreat":
		_move_pig_toward(pig, pig["waypoint"], 5.2, delta)
		if float(pig["retreat_timer"]) <= 0.0 or (pig["pos"] as Vector3).distance_to(pig["waypoint"]) < 2.0:
			pig["state"] = &"prowl" if is_night else &"wander"
			pig["state_timer"] = 3.0
		return

	if not is_night:
		# --- DAYTIME BEHAVIOR: forage, wander, flee player, defensive if cornered ---
		if state == &"prowl" or state == &"investigate_camp" or state == &"scratch_shelter":
			pig["state"] = &"wander"
			pig["target_uid"] = ""
			state = &"wander"

		if _player and dist_player < PIG_CORNERED_RADIUS:
			pig["state"] = &"defensive"
			if float(pig["bite_cooldown"]) <= 0.0 and _vitals:
				_vitals.health = maxf(0.0, _vitals.health - 12.0)
				_vitals.vitals_changed.emit()
				pig["bite_cooldown"] = 3.0
				if _audio:
					_audio.play_spatial(&"pig_grunt", pos)
				_emit_alert(&"pig_defensive", "Cornered wild boar charged!", pos)
			var away := (pos - ppos)
			away.y = 0.0
			pig["waypoint"] = pos + (away.normalized() if away.length() > 0.05 else Vector3.FORWARD) * 16.0
			pig["state"] = &"flee"
			pig["state_timer"] = 3.5
		elif _player and dist_player < PIG_DAY_FLEE_RADIUS:
			pig["state"] = &"flee"
			var away := (pos - ppos)
			away.y = 0.0
			var target := pos + (away.normalized() if away.length() > 0.05 else Vector3.FORWARD) * 14.0
			_move_pig_toward(pig, target, 4.8, delta)
		elif state == &"flee":
			if float(pig["state_timer"]) <= 0.0:
				pig["state"] = &"forage"
				pig["state_timer"] = _rng.randf_range(3.0, 6.0)
			else:
				_move_pig_toward(pig, pig["waypoint"], 4.4, delta)
		elif state == &"forage":
			if float(pig["state_timer"]) <= 0.0:
				pig["state"] = &"wander"
				pig["waypoint"] = _pick_pig_wander_target(pig["home"], 18.0)
				pig["state_timer"] = _rng.randf_range(4.0, 8.0)
		else: # wander
			_move_pig_toward(pig, pig["waypoint"], 1.9, delta)
			if float(pig["state_timer"]) <= 0.0 or (pig["pos"] as Vector3).distance_to(pig["waypoint"]) < 1.5:
				pig["state"] = &"forage"
				pig["state_timer"] = _rng.randf_range(2.5, 5.5)
	else:
		# --- NIGHTTIME BEHAVIOR: bolder, sensory camp/shelter investigation & scratching ---
		if _player and dist_player < PIG_CONFRONT_RADIUS:
			# Direct player confrontation drives the pig back.
			var away := (pos - ppos)
			away.y = 0.0
			pig["state"] = &"retreat"
			pig["retreat_timer"] = 4.5
			pig["target_uid"] = ""
			pig["waypoint"] = pos + (away.normalized() if away.length() > 0.05 else Vector3.FORWARD) * 18.0
			if _audio:
				_audio.play_spatial(&"pig_grunt", pos)
			return

		if state == &"forage" or state == &"wander" or state == &"flee":
			pig["state"] = &"prowl"
			pig["waypoint"] = _pick_pig_wander_target(pig["home"], 34.0)
			pig["state_timer"] = _rng.randf_range(3.5, 7.0)
			state = &"prowl"

		if state == &"prowl":
			# Sensory check: only detect shelter pieces within PIG_SHELTER_DETECT_RADIUS (no magic global tracking).
			if float(pig.get("deter_cooldown", 0.0)) <= 0.0:
				var detected := _find_nearest_shelter_piece(pos, shelter_pieces, PIG_SHELTER_DETECT_RADIUS)
				if not detected.is_empty():
					var dpos: Vector3 = detected["pos"]
					# Don't commit to a piece guarded by an active campfire.
					if _find_nearest_fire(dpos, active_fires, PIG_CAMPFIRE_DETER_RADIUS).is_empty():
						pig["state"] = &"investigate_camp"
						pig["target_uid"] = String(detected["uid"])
						pig["resist_hits"] = 0
						if _audio and dist_player < 45.0:
							_audio.play_spatial(&"pig_grunt", pos)
						return
			_move_pig_toward(pig, pig["waypoint"], 2.7, delta)
			if float(pig["state_timer"]) <= 0.0 or (pig["pos"] as Vector3).distance_to(pig["waypoint"]) < 2.0:
				pig["waypoint"] = _pick_pig_wander_target(pig["home"], 36.0)
				pig["state_timer"] = _rng.randf_range(3.5, 7.0)

		elif state == &"investigate_camp":
			var target_piece := _find_piece_by_uid(String(pig["target_uid"]), shelter_pieces)
			if target_piece.is_empty():
				pig["state"] = &"prowl"
				pig["target_uid"] = ""
				return
			var tpos: Vector3 = target_piece["pos"]
			if not _find_nearest_fire(tpos, active_fires, PIG_CAMPFIRE_DETER_RADIUS).is_empty():
				var away := (pos - tpos)
				away.y = 0.0
				pig["state"] = &"retreat"
				pig["retreat_timer"] = 4.0
				pig["target_uid"] = ""
				pig["waypoint"] = pos + (away.normalized() if away.length() > 0.05 else Vector3.RIGHT) * 16.0
				return
			var dist_piece := Vector2(pos.x - tpos.x, pos.z - tpos.z).length()
			if dist_piece <= PIG_SCRATCH_RANGE:
				pig["state"] = &"scratch_shelter"
				pig["scratch_timer"] = 0.4
			else:
				_move_pig_toward(pig, tpos, 3.2, delta)

		elif state == &"scratch_shelter":
			var target_piece := _find_piece_by_uid(String(pig["target_uid"]), shelter_pieces)
			if target_piece.is_empty():
				pig["state"] = &"prowl"
				pig["target_uid"] = ""
				return
			var tpos: Vector3 = target_piece["pos"]
			_orient_node_toward(pig, tpos, delta)
			pig["scratch_timer"] = float(pig["scratch_timer"]) - delta
			if float(pig["scratch_timer"]) <= 0.0:
				pig["scratch_timer"] = PIG_SCRATCH_INTERVAL
				if _audio:
					_audio.play_spatial(&"scratch", tpos)
					_audio.play_spatial(&"wall_impact", tpos)
				var dmg_res := _buildings.damage_piece(String(target_piece["uid"]), PIG_SCRATCH_DAMAGE) if _buildings else {}
				if bool(dmg_res.get("resisted", false)):
					pig["resist_hits"] = int(pig["resist_hits"]) + 1
					if dist_player < 35.0:
						_emit_alert(&"shelter_held", "Reinforced shelter wall resisted a wild boar!", tpos)
					if int(pig["resist_hits"]) >= 2:
						var away := (pos - tpos)
						away.y = 0.0
						pig["state"] = &"retreat"
						pig["retreat_timer"] = 5.0
						pig["deter_cooldown"] = 18.0
						pig["target_uid"] = ""
						pig["waypoint"] = pos + (away.normalized() if away.length() > 0.05 else Vector3.RIGHT) * 18.0
						if _audio:
							_audio.play_spatial(&"pig_grunt", pos)
				elif bool(dmg_res.get("destroyed", false)):
					_emit_alert(&"shelter_breach", "A wild boar broke through an unreinforced wall!", tpos, true)
					pig["state"] = &"prowl"
					pig["target_uid"] = ""
				else:
					if dist_player < 35.0:
						_emit_alert(&"shelter_scratch", "Something is scratching at your shelter wall! (%.0f HP)" % float(dmg_res.get("hp", 0.0)), tpos)


func _move_pig_toward(pig: Dictionary, target: Vector3, speed: float, delta: float) -> void:
	var pos: Vector3 = pig["pos"]
	var flat := Vector3(target.x - pos.x, 0.0, target.z - pos.z)
	if flat.length_squared() < 0.01:
		return
	var dir := flat.normalized()
	var step := minf(flat.length(), speed * delta)
	var next_pos := pos + dir * step
	var h := _sample_height(next_pos)
	if not is_finite(h) or h < 0.45:
		# Avoid walking into the ocean.
		pig["waypoint"] = pig["home"]
		return
	var n := _sample_normal(next_pos)
	if n.y < 0.72:
		pig["waypoint"] = pig["home"]
		return
	next_pos.y = h
	pig["pos"] = next_pos
	pig["yaw"] = lerp_angle(float(pig["yaw"]), atan2(dir.x, dir.z), clampf(delta * 6.5, 0.0, 1.0))
	var node := pig["node"] as Node3D
	if is_instance_valid(node):
		node.global_position = next_pos
		node.rotation.y = float(pig["yaw"])


func _orient_node_toward(entity: Dictionary, target: Vector3, delta: float) -> void:
	var pos: Vector3 = entity["pos"]
	var flat := Vector3(target.x - pos.x, 0.0, target.z - pos.z)
	if flat.length_squared() > 0.01:
		entity["yaw"] = lerp_angle(float(entity["yaw"]), atan2(flat.x, flat.z), clampf(delta * 8.0, 0.0, 1.0))
		var node := entity["node"] as Node3D
		if is_instance_valid(node):
			node.rotation.y = float(entity["yaw"])


func _pick_pig_wander_target(home: Vector3, radius: float) -> Vector3:
	for _i in 10:
		var a := _rng.randf_range(0.0, TAU)
		var r := _rng.randf_range(4.0, radius)
		var cand := Vector3(home.x + cos(a) * r, 0.0, home.z + sin(a) * r)
		var h := _sample_height(cand)
		if is_finite(h) and h >= 1.0 and h <= 85.0:
			var n := _sample_normal(cand)
			if n.y >= 0.80:
				cand.y = h
				return cand
	return home


# --- Reef Shark AI ------------------------------------------------------------

func _update_shark(shark: Dictionary, delta: float, is_night: bool) -> void:
	var pos: Vector3 = shark["pos"]
	shark["bite_cooldown"] = maxf(0.0, float(shark["bite_cooldown"]) - delta)

	var swimmer_valid := false
	var ppos := Vector3.ZERO
	var dist_player := INF
	if _player:
		ppos = _player.global_position
		dist_player = Vector2(pos.x - ppos.x, pos.z - ppos.z).length()
		var player_ground_h := _sample_height(ppos)
		swimmer_valid = (ppos.y <= 0.35 and is_finite(player_ground_h) and player_ground_h <= SHARK_MAX_WATER_HEIGHT)

	var detect_radius := SHARK_NIGHT_DETECT_RADIUS if is_night else SHARK_DAY_DETECT_RADIUS
	# Moving/splashing swimmers are detected farther away.
	if _player_speed > 2.5:
		detect_radius += 6.0

	var state: StringName = shark["state"]

	# Player escaped to shallow water or shore -> immediately break off!
	if not swimmer_valid and (state == &"investigate" or state == &"attack"):
		shark["state"] = &"patrol"
		shark["investigate_timer"] = 0.0
		shark["warned"] = false
		shark["waypoint"] = _pick_shark_patrol_target(shark["home"])
		state = &"patrol"

	if state == &"patrol":
		if swimmer_valid and dist_player <= detect_radius:
			shark["state"] = &"investigate"
			shark["investigate_timer"] = SHARK_INVESTIGATE_TIME
			shark["circle_angle"] = atan2(pos.z - ppos.z, pos.x - ppos.x)
			shark["warned"] = false
			return
		var patrol_speed := 4.6 if is_night else 3.2
		_move_shark_toward(shark, shark["waypoint"], patrol_speed, delta)
		if Vector2(pos.x - (shark["waypoint"] as Vector3).x, pos.z - (shark["waypoint"] as Vector3).z).length() < 4.0:
			shark["waypoint"] = _pick_shark_patrol_target(shark["home"])

	elif state == &"investigate":
		if not bool(shark["warned"]):
			shark["warned"] = true
			if _audio:
				_audio.play_spatial(&"shark_splash", pos)
			_emit_alert(&"shark_warning", "Reef shark circling nearby — swim to shallow water!", pos, true)
		shark["circle_angle"] = float(shark["circle_angle"]) + delta * 1.15
		var orbit := Vector3(ppos.x + cos(float(shark["circle_angle"])) * 6.5, SHARK_SWIM_Y, ppos.z + sin(float(shark["circle_angle"])) * 6.5)
		_move_shark_toward(shark, orbit, 5.4, delta)
		shark["investigate_timer"] = float(shark["investigate_timer"]) - delta
		if float(shark["investigate_timer"]) <= 0.0:
			shark["state"] = &"attack"

	elif state == &"attack":
		var attack_target := Vector3(ppos.x, SHARK_SWIM_Y, ppos.z)
		_move_shark_toward(shark, attack_target, 7.2, delta)
		var new_dist := Vector2((shark["pos"] as Vector3).x - ppos.x, (shark["pos"] as Vector3).z - ppos.z).length()
		if new_dist <= SHARK_BITE_RANGE and float(shark["bite_cooldown"]) <= 0.0:
			shark["bite_cooldown"] = SHARK_BITE_COOLDOWN
			if _audio:
				_audio.play_spatial(&"shark_splash", shark["pos"])
			if _vitals:
				_vitals.health = maxf(0.0, _vitals.health - SHARK_BITE_DAMAGE)
				_vitals.vitals_changed.emit()
			_emit_alert(&"shark_bite", "Shark attack! Get to shallow water!", shark["pos"], true)
			# Brief circle-back after bite so the player has a window to escape.
			shark["state"] = &"investigate"
			shark["investigate_timer"] = 1.8
			shark["circle_angle"] = atan2((shark["pos"] as Vector3).z - ppos.z, (shark["pos"] as Vector3).x - ppos.x) + 1.2


func _move_shark_toward(shark: Dictionary, target: Vector3, speed: float, delta: float) -> void:
	var pos: Vector3 = shark["pos"]
	var flat := Vector3(target.x - pos.x, 0.0, target.z - pos.z)
	if flat.length_squared() < 0.01:
		return
	var dir := flat.normalized()
	var step := minf(flat.length(), speed * delta)
	var next_pos := Vector3(pos.x + dir.x * step, SHARK_SWIM_Y, pos.z + dir.z * step)

	# Hard guard: never cross onto land or too-shallow beach water.
	var ground_h := _sample_height(next_pos)
	if not is_finite(ground_h) or ground_h > SHARK_MAX_WATER_HEIGHT:
		shark["waypoint"] = _pick_shark_patrol_target(shark["home"])
		if shark["state"] != &"patrol":
			shark["state"] = &"patrol"
		return

	shark["pos"] = next_pos
	shark["yaw"] = lerp_angle(float(shark["yaw"]), atan2(dir.x, dir.z), clampf(delta * 4.5, 0.0, 1.0))
	var node := shark["node"] as Node3D
	if is_instance_valid(node):
		node.global_position = next_pos
		node.rotation.y = float(shark["yaw"])
		var tail := node.get_node_or_null("Tail") as Node3D
		if tail:
			tail.rotation.y = sin(_sim_time * (6.0 if shark["state"] == &"attack" else 3.2)) * 0.35


func _pick_shark_patrol_target(home: Vector3) -> Vector3:
	for _i in 16:
		var a := _rng.randf_range(0.0, TAU)
		var r := _rng.randf_range(18.0, 65.0)
		var cand := Vector3(home.x + cos(a) * r, SHARK_SWIM_Y, home.z + sin(a) * r)
		var h := _sample_height(cand)
		if is_finite(h) and h <= -1.2 and h >= SHARK_MIN_WATER_HEIGHT:
			return cand
	return home


# --- Helpers & Procedural Placeholder Meshes ----------------------------------

func _find_nearest_fire(pos: Vector3, fires: Array[Dictionary], radius: float) -> Dictionary:
	var best: Dictionary = {}
	var best_d := radius
	for f in fires:
		var d := (f["pos"] as Vector3).distance_to(pos)
		if d < best_d:
			best_d = d
			best = f
	return best


func _find_nearest_shelter_piece(pos: Vector3, pieces: Array[Dictionary], radius: float) -> Dictionary:
	var best: Dictionary = {}
	var best_d := radius
	for piece in pieces:
		var d := (piece["pos"] as Vector3).distance_to(pos)
		if d < best_d:
			best_d = d
			best = piece
	return best


func _find_piece_by_uid(uid: String, pieces: Array[Dictionary]) -> Dictionary:
	if uid.is_empty():
		return {}
	for piece in pieces:
		if String(piece["uid"]) == uid:
			return piece
	return {}


func _emit_alert(category: StringName, message: String, world_pos: Vector3, bypass_cooldown := false) -> void:
	if not bypass_cooldown and _alert_cooldown > 0.0:
		return
	_alert_cooldown = 3.2
	wildlife_warning.emit(category, message, world_pos)


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


func _build_pig_mesh(pid: String) -> Node3D:
	var root := Node3D.new()
	root.name = pid

	var coat_mat := StandardMaterial3D.new()
	coat_mat.albedo_color = Color(0.24, 0.19, 0.16)
	coat_mat.roughness = 0.88

	var snout_mat := StandardMaterial3D.new()
	snout_mat.albedo_color = Color(0.36, 0.27, 0.24)
	snout_mat.roughness = 0.78

	var tusk_mat := StandardMaterial3D.new()
	tusk_mat.albedo_color = Color(0.92, 0.89, 0.80)
	tusk_mat.roughness = 0.45

	var body := MeshInstance3D.new()
	var bmesh := CapsuleMesh.new()
	bmesh.radius = 0.34
	bmesh.height = 1.15
	body.mesh = bmesh
	body.material_override = coat_mat
	body.rotation_degrees.x = 90.0
	body.position = Vector3(0.0, 0.56, 0.0)
	root.add_child(body)

	var head := MeshInstance3D.new()
	var hmesh := BoxMesh.new()
	hmesh.size = Vector3(0.38, 0.34, 0.42)
	head.mesh = hmesh
	head.material_override = coat_mat
	head.position = Vector3(0.0, 0.62, 0.56)
	root.add_child(head)

	var snout := MeshInstance3D.new()
	var smesh := CylinderMesh.new()
	smesh.top_radius = 0.11
	smesh.bottom_radius = 0.14
	smesh.height = 0.22
	snout.mesh = smesh
	snout.material_override = snout_mat
	snout.rotation_degrees.x = 90.0
	snout.position = Vector3(0.0, 0.56, 0.82)
	root.add_child(snout)

	for sx in [-0.12, 0.12]:
		var tusk := MeshInstance3D.new()
		var tmesh := CylinderMesh.new()
		tmesh.top_radius = 0.012
		tmesh.bottom_radius = 0.028
		tmesh.height = 0.16
		tusk.mesh = tmesh
		tusk.material_override = tusk_mat
		tusk.position = Vector3(sx, 0.55, 0.84)
		tusk.rotation_degrees = Vector3(25.0, 0.0, -22.0 if sx > 0.0 else 22.0)
		root.add_child(tusk)

	for lx in [-0.18, 0.18]:
		for lz in [-0.30, 0.28]:
			var leg := MeshInstance3D.new()
			var lmesh := CylinderMesh.new()
			lmesh.top_radius = 0.07
			lmesh.bottom_radius = 0.055
			lmesh.height = 0.40
			leg.mesh = lmesh
			leg.material_override = coat_mat
			leg.position = Vector3(lx, 0.20, lz)
			root.add_child(leg)

	return root


func _build_shark_mesh(sid: String) -> Node3D:
	var root := Node3D.new()
	root.name = sid

	var top_mat := StandardMaterial3D.new()
	top_mat.albedo_color = Color(0.28, 0.34, 0.39)
	top_mat.roughness = 0.38

	var body := MeshInstance3D.new()
	var bmesh := CapsuleMesh.new()
	bmesh.radius = 0.32
	bmesh.height = 2.4
	body.mesh = bmesh
	body.material_override = top_mat
	body.rotation_degrees.x = 90.0
	root.add_child(body)

	# Prominent dorsal fin visible near/above surface.
	var dorsal := MeshInstance3D.new()
	var dmesh := PrismMesh.new()
	dmesh.size = Vector3(0.08, 0.62, 0.55)
	dorsal.mesh = dmesh
	dorsal.material_override = top_mat
	dorsal.position = Vector3(0.0, 0.45, 0.10)
	dorsal.rotation_degrees.x = -12.0
	root.add_child(dorsal)

	# Pectoral fins.
	for sx in [-1.0, 1.0]:
		var pec := MeshInstance3D.new()
		var pmesh := BoxMesh.new()
		pmesh.size = Vector3(0.75, 0.05, 0.32)
		pec.mesh = pmesh
		pec.material_override = top_mat
		pec.position = Vector3(sx * 0.45, -0.08, 0.25)
		pec.rotation_degrees = Vector3(0.0, sx * -22.0, sx * -10.0)
		root.add_child(pec)

	# Caudal tail fin (animated sway).
	var tail := Node3D.new()
	tail.name = "Tail"
	tail.position = Vector3(0.0, 0.0, -1.2)
	root.add_child(tail)

	var tail_fin := MeshInstance3D.new()
	var tfmesh := PrismMesh.new()
	tfmesh.size = Vector3(0.07, 0.78, 0.48)
	tail_fin.mesh = tfmesh
	tail_fin.material_override = top_mat
	tail_fin.position = Vector3(0.0, 0.10, -0.22)
	tail_fin.rotation_degrees.x = -25.0
	tail.add_child(tail_fin)

	return root
