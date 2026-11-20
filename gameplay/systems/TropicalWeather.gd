class_name TropicalWeather
extends Node3D

enum State { CLEAR, PARTLY_CLOUDY, LIGHT_RAIN, HEAVY_RAIN, TROPICAL_STORM }
const LABELS := ["Clear", "Partly cloudy", "Light rain", "Heavy rain", "Tropical storm"]
# Rain, wind and cloud cover.
const CLIMATE := [Vector3(0, .08, 0), Vector3(0, .24, .32), Vector3(.28, .32, .5),
	Vector3(.78, .60, .77), Vector3(.95, .97, 1)]
# Surveyed closed contours on the 2 m Terrain3D grid. All four rims clear 1.3 m.
const BASINS := [Vector2(460,-424), Vector2(-262,-604), Vector2(-480,-196), Vector2(182,232)]
const HALF_EXTENT := 12.0
const MAX_DEPTH := 1.25
@export var probabilities := PackedFloat32Array([40, 31, 18, 9, 2])
@export var minimum_seconds := PackedFloat32Array([180, 100, 70, 90, 150])
@export var maximum_seconds := PackedFloat32Array([420, 260, 150, 210, 320])
@export var transition_seconds := 24.0

var state := State.CLEAR
var remaining := 180.0
var elapsed := 0.0
var transition := 1.0
var origin: Vector3 = CLIMATE[0]
var climate: Vector3 = CLIMATE[0]
var wetness := 0.0
var exposure := 0.0
var storage := 0.0
var local_depth := 0.0
var roofed := false
var rng := RandomNumberGenerator.new()
var basins: Array[MeshInstance3D] = []
var bottoms := PackedFloat32Array()
var rain := GPUParticles3D.new()
var drops := ParticleProcessMaterial.new()
var rain_material := ShaderMaterial.new()
var buildings: BuildingSystem
var vitals: SurvivalVitalsSystem
var clock: DayNightSystem
var player: Node3D
var island_audio: Node
var pending := 0.0
var flood_warning := false
var warned_stage := 0

func setup(terrain: Terrain3D, body: Node3D, structures: BuildingSystem, stats: SurvivalVitalsSystem, day: DayNightSystem, audio: Node) -> void:
	buildings = structures
	vitals = stats
	clock = day
	player = body
	island_audio = audio
	rng.randomize()
	var surface := StandardMaterial3D.new()
	surface.albedo_color = Color(.18,.30,.27,.78)
	surface.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	surface.roughness = .31
	var plane := PlaneMesh.new()
	plane.size = Vector2.ONE * HALF_EXTENT * 2.0
	plane.material = surface
	for site: Vector2 in BASINS:
		var center := Vector3(site.x, 0, site.y)
		var bottom := terrain.data.get_height(center)
		var patch := MeshInstance3D.new()
		patch.mesh = plane
		patch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(patch)
		patch.position = center + Vector3.UP * bottom
		patch.hide()
		basins.append(patch)
		bottoms.append(bottom)
	_setup_rain()

func _setup_rain() -> void:
	rain_material.shader = preload("res://materials/LocalRain.gdshader")
	var streak := BoxMesh.new()
	streak.size = Vector3(.018,.48,.018)
	streak.material = rain_material
	rain.draw_pass_1 = streak
	rain.amount = 640
	rain.lifetime = .8
	rain.fixed_fps = 24
	rain.local_coords = false
	rain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	rain.visibility_aabb = AABB(Vector3(-20,-15,-20),Vector3(40,29,40))
	drops.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	drops.emission_box_extents = Vector3(10,1,10)
	drops.direction = Vector3.DOWN
	drops.spread = 2
	drops.initial_velocity_min = 13
	drops.initial_velocity_max = 16
	drops.particle_flag_align_y = true
	rain.process_material = drops
	rain.emitting = false
	add_child(rain)

func request_state(next: int) -> void:
	state = clampi(next, 0, CLIMATE.size()-1) as State
	origin = climate
	transition = 0.0
	elapsed = 0
	remaining = rng.randf_range(minimum_seconds[state], maximum_seconds[state])
	if state == State.TROPICAL_STORM:
		vitals.critical_warning.emit(&"weather", "Storm approaching. Find a roof and leave low ground.")

func _process(delta: float) -> void:
	rain.global_position = player.global_position + Vector3(-climate.y * 2,8,0)
	pending += delta
	if pending >= .2:
		step(pending)
		pending = 0

func step(dt: float) -> void:
	remaining -= dt
	if remaining <= 0:
		request_state(rng.rand_weighted(probabilities))
	elapsed += dt
	transition = minf(1, transition + dt / maxf(1, transition_seconds))
	var target: Vector3 = CLIMATE[state]
	if state == State.TROPICAL_STORM:
		target.x += .05 * sin(elapsed * .12) - .05
		target.y -= .045 * (1.0 - cos(elapsed * .23))
	climate = origin.lerp(target, smoothstep(0, 1, transition))
	vitals.rain_intensity = climate.x
	clock.weather_cloud = climate.z
	var p := player.global_position
	var shelter := buildings.weather_cover(p)
	roofed = shelter.x > 0
	storage = clampf(storage + (maxf(0, climate.x-.52)*.025 - maxf(0,.48-climate.x)*.017)*dt, 0, 1)
	for i in basins.size():
		basins[i].position.y = bottoms[i] + storage * MAX_DEPTH
		basins[i].visible = storage > .015
	local_depth = flood_depth(p)
	var at_risk := local_depth > .05 and climate.x > .52
	if at_risk and not flood_warning:
		vitals.critical_warning.emit(&"flood", "Water is rising here. Move to higher ground.")
	flood_warning = at_risk
	var warmth := _update_fires(p, dt)
	if storage > .3:
		for piece in buildings.get_exterior_shelter_pieces():
			var depth := flood_depth(piece.pos)
			if depth > .45:
				buildings.damage_piece(piece.uid, .15 * depth * dt)
	if not vitals.is_dead:
		var immersion := maxf(local_depth, island_audio.water_depth(p))
		update_exposure(dt, immersion, shelter, warmth, clock.night_factor, p.y)
	_present(p)

func flood_depth(p: Vector3) -> float:
	if storage <= .015:
		return 0
	for i in BASINS.size():
		var offset: Vector2 = Vector2(p.x,p.z) - BASINS[i]
		if absf(offset.x) <= HALF_EXTENT and absf(offset.y) <= HALF_EXTENT:
			return maxf(0, bottoms[i] + storage * MAX_DEPTH - p.y)
	return 0

func _update_fires(p: Vector3, dt: float) -> float:
	var warmth := 0.0
	for fire in buildings.get_active_campfires():
		var covered := buildings.weather_cover(fire.pos).x > 0
		var soaking := not covered and climate.x >= .70
		var drench := float(fire.get("drench",0))
		drench = maxf(0,drench + (1.0 if soaking else -2.0)*dt)
		fire["drench"] = drench
		if drench >= 55 or flood_depth(fire.pos) > .3:
			buildings.toggle_campfire(fire.uid)
			fire["drench"] = 0.0
			continue
		var distance := p.distance_to(fire.pos)
		warmth = maxf(warmth, (1.0-smoothstep(1,7,distance)) * (.5 if soaking else 1.0))
	return warmth

func update_exposure(dt: float, depth: float, shelter: Vector2, warmth: float, night: float, altitude: float) -> void:
	var rainfall := climate.x * (1.0-shelter.x)
	var wind := climate.y * (1.0-shelter.y)
	var soak := maxf(rainfall * .020, smoothstep(.16,.60,depth) * .065)
	var dry := (.004 + .009*shelter.x + .024*warmth) * (1.0-smoothstep(.02,.20,soak*50))
	wetness = clampf(wetness + dt*(soak-dry),0,1)
	var chill := wetness * (.003 + .007*wind + .004*night + .006*smoothstep(90,320,altitude))
	var recovery := .0035 + .012*shelter.x + .009*shelter.y + .03*warmth
	exposure = clampf(exposure + dt*(chill-recovery),0,1)
	vitals.cold_exposure = exposure
	vitals.wind_load = wind
	var stage := int(exposure >= .25) + int(exposure >= .55) + int(exposure >= .84)
	if stage > warned_stage:
		vitals.critical_warning.emit(&"cold", ["","Shivering. Find shelter or descend.","Cold is slowing you. Warm up by a fire.","Severe exposure! Get dry and warm."][stage])
	warned_stage = stage
	if exposure >= .84 and chill > recovery:
		vitals.apply_damage(dt * smoothstep(.84,1,exposure)*1.1, &"exposure", "Storm Exposure")

func _present(p: Vector3) -> void:
	rain.visible = not roofed and climate.x > .015
	rain.emitting = rain.visible
	rain.amount_ratio = climate.x
	drops.direction = Vector3(climate.y*.55,-1,.05).normalized()
	rain_material.set_shader_parameter("ground_y",p.y-2.5)
	var roofs := buildings.rain_masks(p)
	rain_material.set_shader_parameter("roof_count", roofs.size())
	roofs.resize(64)
	rain_material.set_shader_parameter("roofs",roofs)
	RenderingServer.global_shader_parameter_set("storm_wind", smoothstep(.18,.98,climate.y))
	island_audio.set_weather(climate.x, climate.y, roofed, state == State.TROPICAL_STORM)

func serialize() -> Dictionary:
	return {"state":state, "remaining":remaining, "elapsed":elapsed, "transition":transition,
		"origin":[origin.x,origin.y,origin.z], "climate":[climate.x,climate.y,climate.z],
		"wetness":wetness,"exposure":exposure,"storage":storage,"rng":str(rng.state)}

func deserialize(data: Dictionary) -> void:
	state = clampi(int(data.get("state",0)),0,4) as State
	remaining = maxf(0,float(data.get("remaining",180)))
	elapsed = maxf(0,float(data.get("elapsed",0)))
	transition = clampf(float(data.get("transition",1)),0,1)
	origin = _read_climate(data.get("origin",[]))
	climate = _read_climate(data.get("climate",[]))
	wetness = clampf(float(data.get("wetness",0)),0,1)
	exposure = clampf(float(data.get("exposure",0)),0,1)
	storage = clampf(float(data.get("storage",0)),0,1)
	if data.has("rng"):
		rng.state = int(data.rng)
	warned_stage = 0
	flood_warning = false
	pending = 0
	vitals.rain_intensity = climate.x
	vitals.cold_exposure = exposure
	vitals.wind_load = 0
	clock.weather_cloud = climate.z

func _read_climate(value: Variant) -> Vector3:
	if value is Array and value.size() == 3:
		return Vector3(float(value[0]),float(value[1]),float(value[2])).clamp(Vector3.ZERO,Vector3.ONE)
	return CLIMATE[0]

func debug_summary() -> String:
	return "%s  Rain %.0f%%  Wind %.0f%%  Wet %.0f%%  Cold %.0f%%\nFlood %.2f m / local %.2f m  Roof %s" % [
		LABELS[state],climate.x*100,climate.y*100,wetness*100,exposure*100,storage*MAX_DEPTH,local_depth,roofed]

func reset_exposure() -> void:
	wetness = 0
	exposure = 0
	warned_stage = 0
	vitals.cold_exposure = 0
	vitals.wind_load = 0
