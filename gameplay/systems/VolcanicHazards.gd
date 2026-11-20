class_name VolcanicHazards
extends Node3D

enum Phase { DORMANT, UNREST, ESCALATION, ERUPTION, RECOVERY }
const LABELS := ["Dormant", "Unrest", "Escalation", "Eruption", "Recovery"]
const SUMMIT := Vector2(48, -126)
const LAVA_FIELD := Vector2(534, 106)
const GRID_SIZE := 24
const CELL := 96.0
const GRID_ORIGIN := Vector2(-1152, -1152)
const FLOW_SPEED := 7.0
const FLOW_WARNING := 24.0
const FLOW_LENGTH := 38.0
const FLOW_WIDTH := 7.0
const DRAINAGE := [Vector2(560,150), Vector2(576,166), Vector2(588,182),
	Vector2(580,198), Vector2(592,214), Vector2(588,230), Vector2(576,246),
	Vector2(572,262), Vector2(556,278), Vector2(544,294), Vector2(544,310),
	Vector2(544,326), Vector2(552,342), Vector2(560,350)]

@export var dormant_min := 2400.0
@export var dormant_max := 4200.0
@export var unrest_duration := 95.0
@export var escalation_duration := 80.0
@export var eruption_duration := 215.0
@export var recovery_duration := 240.0
@export var eruption_strength := 0.9
@export var water_recovery_seconds := 420.0
@export_range(0, 0.25) var regrowth_bonus := 0.16

var phase := Phase.DORMANT
var remaining := 0.0
var elapsed := 0.0
var activity := 0.0
var intensity := 0.0
var respiratory := 0.0
var mud_head := -FLOW_WARNING * FLOW_SPEED
var mud_active := false
var mud_cooldown := 0.0
var next_tremor := 0.0
var tremor := 0.0
var airborne := 0.0
var pending := 0.0
var surface_timer := 0.0
var announced_distress := false
var ash := PackedFloat32Array()
var contamination := PackedFloat32Array()
var fertility := PackedFloat32Array()
var path := Curve3D.new()
var game: SurvivalSystem
var terrain: Terrain3D
var visual: VolcanicEffects
var vent := Vector3.ZERO
var lava := Vector3.ZERO
var ash_image := Image.create_empty(GRID_SIZE, GRID_SIZE, false, Image.FORMAT_RF)
var ash_texture := ImageTexture.create_from_image(ash_image)
var rng := RandomNumberGenerator.new()

func setup(survival: SurvivalSystem, ground: Terrain3D, island_audio: Node) -> void:
	game = survival
	terrain = ground
	rng.randomize()
	vent = ground_point(SUMMIT)
	lava = ground_point(LAVA_FIELD)
	for point: Vector2 in DRAINAGE:
		path.add_point(ground_point(point))
	visual = VolcanicEffects.new()
	add_child(visual)
	visual.setup(vent, island_audio, game.weather.player)
	visual.build_flow(path, ground)
	for i in GRID_SIZE * GRID_SIZE:
		var cell_center := Vector2(i % GRID_SIZE, floori(float(i) / GRID_SIZE)) + Vector2.ONE * .5
		_surface_offsets.append(GRID_ORIGIN + cell_center * CELL - SUMMIT)
	terrain.material.set_shader_param("volcanic_deposit", ash_texture)
	deserialize({})

func ground_point(point: Vector2) -> Vector3:
	var world := Vector3(point.x, 0, point.y)
	world.y = terrain.data.get_height(world)
	return world

func _physics_process(delta: float) -> void:
	pending += delta
	if pending >= .25:
		step(pending)
		pending = 0

func begin(next: Phase) -> void:
	phase = next
	elapsed = 0
	match phase:
		Phase.DORMANT: remaining = rng.randf_range(dormant_min, maxf(dormant_min, dormant_max))
		Phase.UNREST:
			remaining = unrest_duration
			next_tremor = 4
			game.vitals.critical_warning.emit(&"volcano", "A deep rumble carries from the summit.")
		Phase.ESCALATION:
			remaining = escalation_duration
			next_tremor = 3
			game.vitals.critical_warning.emit(&"volcano", "The summit is venting. Leave the crater and lava field.")
		Phase.ERUPTION:
			remaining = eruption_duration
			next_tremor = 6
		Phase.RECOVERY: remaining = recovery_duration

func step(dt: float) -> void:
	remaining -= dt
	if remaining <= 0:
		begin(posmod(phase + 1, LABELS.size()) as Phase)
	elapsed += dt
	var target: float = [0.0, .22, .62, 1.0, 0.0][phase]
	activity = move_toward(activity, target, dt * .018)
	var erupting := phase == Phase.ERUPTION
	intensity = move_toward(intensity, eruption_strength if erupting else 0.0, dt * (.035 if erupting else .012))
	var player_pos := game.weather.player.global_position
	var cover := game.buildings.weather_cover(player_pos) if intensity > 0 else Vector2.ZERO
	var wind := game.weather.climate.y
	var rain := game.weather.climate.x
	airborne = ash_at(player_pos, wind, rain)
	game.day_night.volcanic_haze = airborne
	game.weather.ash_cooling = airborne * (1.0 - .65 * cover.x)
	tremor = move_toward(tremor, 0, dt * .44)
	if phase in [Phase.UNREST, Phase.ESCALATION, Phase.ERUPTION]:
		next_tremor -= dt
		if next_tremor <= 0:
			tremor = rng.randf_range(.74, 1.0) * activity
			next_tremor = rng.randf_range(12, 26) / maxf(.5, activity)
			visual.rumble(vent, tremor)
			if erupting and elapsed > 25 and tremor > .72:
				_shake_structures()
	var player_mud := _step_mud(dt, rain, player_pos)
	if not game.vitals.is_dead:
		_update_survival(dt, cover, player_pos, player_mud)
	surface_timer += dt
	if surface_timer >= 1:
		if intensity > 0 or phase == Phase.RECOVERY or has_deposits:
			_update_surface(surface_timer, wind, rain)
		game.water_system.expose_collectors(surface_timer, wind)
		surface_timer = 0
	visual.show_flow(mud_active and mud_head >= 0, mud_head, FLOW_LENGTH)
	if intensity != _published_glow:
		_published_glow = intensity
		terrain.material.set_shader_param("volcanic_glow", intensity)
	var mud_pos := path.sample_baked(clampf(mud_head - 4, 0, path.get_baked_length()))
	visual.present(activity, intensity, airborne * (1.0 - cover.x), tremor, game.weather.wind_direction.normalized() * wind, player_pos,
		mud_active and mud_head >= 0 and mud_head < path.get_baked_length()+FLOW_LENGTH, mud_pos)

var has_deposits := false
var _surface_offsets := PackedVector2Array()
var _published_glow := -1.0

func ash_at(point: Vector3, wind: float, rain: float) -> float:
	if intensity <= 0:
		return 0.0
	var offset := Vector2(point.x, point.z) - SUMMIT
	return _plume_at(offset, game.weather.wind_direction.normalized(), wind) * (1.0 - .58 * rain)

func _plume_at(offset: Vector2, direction: Vector2, wind: float) -> float:
	var along := offset.dot(direction)
	var across := absf(offset.cross(direction))
	var reach := lerpf(230, 1240, wind)
	var width := 102.0 + maxf(0, along) * .65
	var carried := (1.0 - smoothstep(0, reach, maxf(0, along))) * (1.0 - smoothstep(width * .18, width, across))
	carried *= 1.0 - smoothstep(0, 150, -along)
	var local := 1.0 - smoothstep(36, lerpf(205, 135, wind), offset.length())
	return intensity * maxf(carried, local)

func _cell(point: Vector3) -> int:
	var index := Vector2i(((Vector2(point.x, point.z) - GRID_ORIGIN) / CELL).floor())
	if index.x < 0 or index.y < 0 or index.x >= GRID_SIZE or index.y >= GRID_SIZE:
		return -1
	return index.y * GRID_SIZE + index.x

func deposited_at(point: Vector3) -> float:
	var i := _cell(point)
	return ash[i] if i >= 0 else 0.0

func water_ash(point: Vector3) -> float:
	var i := _cell(point)
	return contamination[i] if i >= 0 else 0.0

func regrowth_at(point: Vector3) -> float:
	var index := _cell(point)
	if phase != Phase.DORMANT or index < 0:
		return 1.0
	return 1.0 - fertility[index] * regrowth_bonus

func _update_surface(dt: float, wind: float, rain: float) -> void:
	has_deposits = false
	var direction := game.weather.wind_direction.normalized()
	var changed := false
	for i in ash.size():
		var plume := _plume_at(_surface_offsets[i], direction, wind) if intensity > 0 else 0.0
		var previous := ash[i]
		var deposit := plume * (.012 + .024 * rain)
		var runoff := ash[i] * rain * .008
		ash[i] = clampf(ash[i] + dt * (deposit - runoff - .0013), 0, 1)
		contamination[i] = clampf(contamination[i] + dt * (plume * .010 + runoff * 1.7 - 1.0 / maxf(30, water_recovery_seconds)), 0, 1)
		changed = changed or ash[i] != previous
		if phase == Phase.RECOVERY:
			fertility[i] = maxf(fertility[i], ash[i])
		has_deposits = has_deposits or ash[i] > 0 or contamination[i] > 0
	if changed:
		_upload_ash()

func _upload_ash() -> void:
	for i in ash.size():
		ash_image.set_pixel(i % GRID_SIZE, floori(float(i) / GRID_SIZE), Color(ash[i], 0, 0))
	ash_texture.update(ash_image)
	terrain.material.set_shader_param("volcanic_has_deposit", ash.count(0.0) != ash.size())

func heat_at(point: Vector3) -> float:
	var vent_heat := 1.0 - smoothstep(28, 116, point.distance_to(vent))
	var lava_dist := (point - lava) / Vector3(1.45, .57, 1)
	var field_heat := 1.0 - smoothstep(34, 90, lava_dist.length())
	if field_heat > 0:
		var material_ids := terrain.data.get_texture_id(point)
		var basalt := (1.0 - material_ids.z if int(material_ids.x) in [0,4] else 0.0) + (material_ids.z if int(material_ids.y) in [0,4] else 0.0)
		field_heat *= .25 + .75 * clampf(basalt, 0, 1)
	return intensity * maxf(vent_heat, field_heat) * smoothstep(5, 33, elapsed)

func _update_survival(dt: float, cover: Vector2, pos: Vector3, mud: bool) -> void:
	var ventilation := 1.0 - .22 * cover.x - .72 * cover.x * cover.y
	var inhaled := airborne * ventilation
	respiratory = clampf(respiratory + dt * (maxf(0, inhaled - .22) * .027 - (1.0 - inhaled) * .007), 0, 1)
	game.vitals.volcanic_ash_exposure = respiratory
	game.vitals.debris_drag = .32 if mud else 0.0
	if respiratory > .37 and not announced_distress:
		game.vitals.critical_warning.emit(&"ash", "Breathing is getting harder. Get indoors or move upwind.")
		announced_distress = true
	elif respiratory < .19:
		announced_distress = false
	if respiratory > .77 and inhaled > .31:
		game.vitals.apply_damage(dt * .95 * smoothstep(.77, 1, respiratory), &"ash", "Volcanic Ash Inhalation")
	var heat := heat_at(pos)
	if heat > .13:
		game.vitals.apply_damage(dt * heat * 2.7, &"volcanic_heat", "Volcanic Heat")
	if mud:
		game.vitals.apply_damage(dt * 1.7, &"mudflow", "Volcanic Debris Flow")

func _shake_structures() -> void:
	for piece in game.buildings.get_exterior_shelter_pieces():
		var local := maxf(1.0 - piece.pos.distance_to(vent) / 250.0, 1.0 - piece.pos.distance_to(lava) / 190.0)
		if local > 0:
			game.buildings.damage_piece(piece.uid, tremor * local * 9.0)

func _step_mud(dt: float, rain: float, player_pos: Vector3) -> bool:
	mud_cooldown = maxf(0, mud_cooldown - dt)
	var headwater := path.sample_baked(0)
	if not mud_active and mud_cooldown <= 0 and rain >= .64 and deposited_at(headwater) > .24:
		if phase == Phase.ERUPTION or phase == Phase.RECOVERY:
			mud_active = true
			mud_head = -FLOW_WARNING * FLOW_SPEED
			visual.rumble(headwater, .75)
			if player_pos.distance_to(headwater) < 500:
				game.vitals.critical_warning.emit(&"mudflow", "Debris is breaking loose on the southeast slope. Leave the gully.")
	if not mud_active:
		return false
	mud_head += dt * FLOW_SPEED
	if mud_head > path.get_baked_length() + FLOW_LENGTH:
		mud_active = false
		mud_cooldown = 155
		return false
	if mud_head >= 0:
		for piece in game.buildings.get_exterior_shelter_pieces():
			if in_mud(piece.pos):
				game.buildings.damage_piece(piece.uid, dt * 2.2)
	return in_mud(player_pos)

func in_mud(point: Vector3) -> bool:
	if not mud_active or mud_head < 0:
		return false
	var offset := path.get_closest_offset(point)
	return offset <= mud_head and offset >= mud_head - FLOW_LENGTH and point.distance_to(path.sample_baked(offset)) < FLOW_WIDTH

func reset_personal() -> void:
	respiratory = 0
	announced_distress = false
	game.vitals.volcanic_ash_exposure = 0
	game.vitals.debris_drag = 0

func serialize() -> Dictionary:
	return {"phase": phase, "remaining": remaining, "elapsed": elapsed, "activity": activity,
		"intensity": intensity, "respiratory": respiratory, "ash": Array(ash),
		"contamination": Array(contamination), "fertility": Array(fertility),
		"mud_head": mud_head, "mud_active": mud_active, "mud_cooldown": mud_cooldown,
		"tremor": tremor, "next_tremor": next_tremor, "surface_timer": surface_timer, "rng": str(rng.state)}

func deserialize(data: Dictionary) -> void:
	phase = clampi(int(data.get("phase", 0)), 0, 4) as Phase
	remaining = float(data.remaining) if data.has("remaining") else rng.randf_range(dormant_min, maxf(dormant_min, dormant_max))
	if data.has("rng"):
		rng.state = int(data.rng)
	elapsed = float(data.get("elapsed", 0))
	activity = float(data.get("activity", 0))
	intensity = float(data.get("intensity", 0))
	mud_head = float(data.get("mud_head", -FLOW_WARNING * FLOW_SPEED))
	mud_active = bool(data.get("mud_active", false))
	mud_cooldown = float(data.get("mud_cooldown", 0))
	tremor = float(data.get("tremor", 0))
	next_tremor = float(data.get("next_tremor", 0))
	surface_timer = float(data.get("surface_timer", 0))
	pending = 0
	ash = _restore_grid(data.get("ash", []))
	contamination = _restore_grid(data.get("contamination", []))
	fertility = _restore_grid(data.get("fertility", []))
	has_deposits = ash.count(0.0) < ash.size() or contamination.count(0.0) < contamination.size()
	reset_personal()
	respiratory = clampf(float(data.get("respiratory", 0)), 0, 1)
	game.vitals.volcanic_ash_exposure = respiratory
	_upload_ash()

func _restore_grid(raw: Variant) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(GRID_SIZE * GRID_SIZE)
	if raw is Array and raw.size() == result.size():
		for i in result.size():
			result[i] = clampf(float(raw[i]), 0, 1)
	return result

func debug_summary() -> String:
	var p := game.weather.player.global_position
	var bearing := fposmod(rad_to_deg(atan2(game.weather.wind_direction.x, -game.weather.wind_direction.y)), 360.0)
	return "%s %.0fs | Ash %.0f%% | Water %.0f%% | Wind %.0f° %.0f%% | Mud %s" % [
		LABELS[phase], remaining, airborne * 100, water_ash(p) * 100, bearing, game.weather.climate.y * 100,
		("warning %.0fs" % (-mud_head / FLOW_SPEED) if mud_head < 0 else "flowing") if mud_active else "idle"]

func debug_mudflow() -> void:
	begin(Phase.RECOVERY)
	var headwater := path.sample_baked(0)
	ash[_cell(headwater)] = .85
	has_deposits = true
	mud_cooldown = 0
	game.weather.request_state(TropicalWeather.State.HEAVY_RAIN)
