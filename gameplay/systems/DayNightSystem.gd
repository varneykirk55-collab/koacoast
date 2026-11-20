class_name DayNightSystem
extends Node
## Continuous day-night environmental clock driving lighting, sky, atmosphere,
## survival heat pressure, nocturnal audio transitions, and wildlife schedules.

signal phase_changed(new_phase: StringName, day_number: int)

@export var day_duration_seconds := 360.0 # 6 real-world minutes
@export var night_duration_seconds := 360.0 # 6 real-world minutes
@export var time_scale := 1.0

var day_number := 1
## Seconds elapsed inside the current full cycle [0 .. day_duration + night_duration).
## [0 .. day_duration) = Day (sunrise -> midday -> sunset).
## [day_duration .. total) = Night.
var cycle_time := 96.0 # Starts in late morning (~10:00 AM) to preserve KoaCoast daytime spawn.

var current_phase: StringName = &"day"
var night_factor := 0.0
var twilight_factor := 0.0
var heat_factor := 1.0

var _sun: DirectionalLight3D
var _world_env: WorldEnvironment
var _sky_mat: ShaderMaterial
var _vitals: SurvivalVitalsSystem
var _island_audio: Node

# Cached daytime defaults from KoaCoast.tscn so daytime appearance is preserved verbatim.
var _day_sun_color := Color(1.0, 0.912, 0.775, 1.0)
var _day_sun_energy := 1.19
var _day_ambient_color := Color(0.83, 0.89, 0.97, 1.0)
var _day_ambient_energy := 0.62
var _day_fog_color := Color(0.70, 0.82, 0.88, 1.0)


func setup(sun: DirectionalLight3D, world_env: WorldEnvironment, vitals: SurvivalVitalsSystem, island_audio: Node) -> void:
	_sun = sun
	_world_env = world_env
	_vitals = vitals
	_island_audio = island_audio
	if _sun:
		_day_sun_color = _sun.light_color
		_day_sun_energy = _sun.light_energy
	if _world_env and _world_env.environment:
		var env := _world_env.environment
		_day_ambient_color = env.ambient_light_color
		_day_ambient_energy = env.ambient_light_energy
		_day_fog_color = env.fog_light_color
		if env.sky and env.sky.sky_material is ShaderMaterial:
			_sky_mat = env.sky.sky_material as ShaderMaterial
	_apply_environment()


func reset_all() -> void:
	day_number = 1
	cycle_time = day_duration_seconds * 0.26
	current_phase = &"day"
	_apply_environment()


func get_total_cycle_seconds() -> float:
	return maxf(10.0, day_duration_seconds) + maxf(10.0, night_duration_seconds)


func is_night() -> bool:
	return cycle_time >= maxf(1.0, day_duration_seconds)


func get_normalized_cycle() -> float:
	return clampf(cycle_time / get_total_cycle_seconds(), 0.0, 1.0)


func get_clock_string() -> String:
	var day_dur := maxf(1.0, day_duration_seconds)
	var night_dur := maxf(1.0, night_duration_seconds)
	var hour_float := 6.0
	if cycle_time < day_dur:
		hour_float = 6.0 + (cycle_time / day_dur) * 12.0 # 06:00 -> 18:00
	else:
		hour_float = fposmod(18.0 + ((cycle_time - day_dur) / night_dur) * 12.0, 24.0) # 18:00 -> 06:00
	var hrs := int(floorf(hour_float))
	var mins := int(floorf((hour_float - float(hrs)) * 60.0))
	return "Day %d — %02d:%02d (%s)" % [day_number, hrs, mins, String(current_phase).capitalize()]


func advance_time(seconds: float) -> void:
	if seconds <= 0.0:
		return
	var total := get_total_cycle_seconds()
	cycle_time += seconds
	while cycle_time >= total:
		cycle_time -= total
		day_number += 1
	if _vitals:
		_vitals.tick_survival_trauma(seconds)
	_apply_environment()


func set_to_phase(phase: StringName) -> void:
	var day_dur := maxf(1.0, day_duration_seconds)
	var night_dur := maxf(1.0, night_duration_seconds)
	match phase:
		&"sunrise":
			cycle_time = day_dur * 0.04
		&"day":
			cycle_time = day_dur * 0.45
		&"sunset":
			cycle_time = day_dur * 0.94
		&"night":
			cycle_time = day_dur + night_dur * 0.45
	_apply_environment()


func toggle_day_night() -> void:
	if is_night():
		set_to_phase(&"day")
	else:
		set_to_phase(&"night")


func _process(delta: float) -> void:
	if time_scale <= 0.0:
		return
	advance_time(delta * time_scale)


func _apply_environment() -> void:
	var day_dur := maxf(1.0, day_duration_seconds)
	var night_dur := maxf(1.0, night_duration_seconds)
	var prev_phase := current_phase

	if cycle_time < day_dur:
		var day_t := clampf(cycle_time / day_dur, 0.0, 1.0)
		if day_t < 0.14:
			current_phase = &"sunrise"
			var u := day_t / 0.14
			twilight_factor = sin(u * PI)
			night_factor = (1.0 - smoothstep(0.0, 0.55, u)) * 0.55
		elif day_t > 0.86:
			current_phase = &"sunset"
			var u := (day_t - 0.86) / 0.14
			twilight_factor = sin(u * PI)
			night_factor = smoothstep(0.45, 1.0, u) * 0.65
		else:
			current_phase = &"day"
			twilight_factor = 0.0
			night_factor = 0.0

		# Daytime solar elevation & warm-to-crisp daylight arc.
		var elevation := sin(day_t * PI) # 0 at horizons, 1 at solar noon
		var pitch := -lerpf(0.12, 1.08, elevation)
		var yaw := lerpf(-1.75, 1.25, day_t)
		if _sun:
			_sun.rotation = Vector3(pitch, yaw, 0.0)
			var warm := Color(1.0, 0.60, 0.34, 1.0)
			_sun.light_color = _day_sun_color.lerp(warm, twilight_factor * 0.82)
			_sun.light_energy = lerpf(_day_sun_energy, 0.62, twilight_factor * 0.65)
			_sun.light_energy = lerpf(_sun.light_energy, 0.24, night_factor)

		# Daytime heat multiplier peaks around midday (1.30x) and eases near sunrise/sunset.
		heat_factor = lerpf(0.95, 1.30, smoothstep(0.15, 0.85, elevation))
	else:
		var night_t := clampf((cycle_time - day_dur) / night_dur, 0.0, 1.0)
		current_phase = &"night"
		# Smoothly finish dusk in first 8% of night and begin dawn glow in last 8%.
		if night_t < 0.08:
			var u := night_t / 0.08
			night_factor = lerpf(0.65, 1.0, u)
			twilight_factor = lerpf(0.40, 0.0, u)
		elif night_t > 0.92:
			var u := (night_t - 0.92) / 0.08
			night_factor = lerpf(1.0, 0.55, u)
			twilight_factor = lerpf(0.0, 0.45, u)
		else:
			night_factor = 1.0
			twilight_factor = 0.0

		# Cool tropical moonlight preserving mountain & coastline silhouettes.
		var moon_elev := sin(night_t * PI)
		var moon_pitch := -lerpf(0.28, 0.88, moon_elev)
		var moon_yaw := lerpf(1.35, -1.45, night_t)
		if _sun:
			_sun.rotation = Vector3(moon_pitch, moon_yaw, 0.0)
			var moon_col := Color(0.56, 0.69, 0.94, 1.0)
			_sun.light_color = _day_sun_color.lerp(moon_col, night_factor)
			_sun.light_energy = lerpf(0.45, 0.24, night_factor)

		# Nighttime reduces heat pressure on thirst depletion.
		heat_factor = lerpf(0.95, 0.84, night_factor)

	# Update WorldEnvironment sky, ambient, and fog smoothly.
	if _sky_mat:
		_sky_mat.set_shader_parameter("night_factor", night_factor)
		_sky_mat.set_shader_parameter("twilight_factor", twilight_factor)
	if _world_env and _world_env.environment:
		var env := _world_env.environment
		var twilight_amb := Color(0.78, 0.56, 0.46, 1.0)
		var night_amb := Color(0.14, 0.20, 0.34, 1.0)
		var amb_col := _day_ambient_color.lerp(twilight_amb, twilight_factor * 0.7).lerp(night_amb, night_factor)
		env.ambient_light_color = amb_col
		env.ambient_light_energy = lerpf(_day_ambient_energy, 0.18, night_factor)

		var twilight_fog := Color(0.76, 0.52, 0.42, 1.0)
		var night_fog := Color(0.05, 0.08, 0.14, 1.0)
		env.fog_light_color = _day_fog_color.lerp(twilight_fog, twilight_factor * 0.75).lerp(night_fog, night_factor)

	# Connect to Prompt 1 SurvivalVitalsSystem & Sol's IslandAudio.
	if _vitals:
		_vitals.daytime_heat_multiplier = heat_factor
	if _island_audio and _island_audio.has_method("set_night_factor"):
		_island_audio.call("set_night_factor", night_factor)

	if current_phase != prev_phase:
		phase_changed.emit(current_phase, day_number)


func serialize() -> Dictionary:
	return {
		"day_number": day_number,
		"cycle_time": snappedf(cycle_time, 0.1),
		"day_duration_seconds": day_duration_seconds,
		"night_duration_seconds": night_duration_seconds,
	}


func deserialize(data: Dictionary) -> void:
	day_number = maxi(1, int(data.get("day_number", 1)))
	if data.has("day_duration_seconds"):
		day_duration_seconds = maxf(10.0, float(data["day_duration_seconds"]))
	if data.has("night_duration_seconds"):
		night_duration_seconds = maxf(10.0, float(data["night_duration_seconds"]))
	cycle_time = clampf(float(data.get("cycle_time", day_duration_seconds * 0.26)), 0.0, get_total_cycle_seconds() - 0.01)
	_apply_environment()
