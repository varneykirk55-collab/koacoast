class_name SurvivalVitalsSystem
extends Node
## Hardcore Hunger, Thirst, Stamina, and Health simulation with activity-dependent
## depletion, starvation/dehydration penalties, recovery, and future environment hooks.

signal critical_warning(category: StringName, message: String)
signal vitals_changed

@export_group("Core Vitals")
@export var max_health := 100.0
@export var base_max_stamina := 100.0

@export_group("Hunger Depletion (per sec)")
@export var hunger_rate_standing := 0.025
@export var hunger_rate_walking := 0.065
@export var hunger_rate_sprinting := 0.18
@export var hunger_rate_chopping := 0.45
@export var hunger_rate_heavy_gather := 0.38
@export var hunger_rate_light_gather := 0.12
@export var starvation_dps := 1.2

@export_group("Thirst Depletion (per sec)")
@export var thirst_rate_standing := 0.045
@export var thirst_rate_walking := 0.11
@export var thirst_rate_sprinting := 0.32
@export var thirst_rate_strenuous := 0.55
@export var thirst_rate_light_gather := 0.16
@export var dehydration_base_dps := 1.0
@export var dehydration_max_dps := 3.0
@export var dehydration_ramp_seconds := 60.0
@export var ash_thirst_multiplier := 0.75

@export_group("Stamina")
@export var stamina_sprint_drain := 14.0
@export var stamina_base_regen := 16.0
@export var exhaustion_recover_threshold := 15.0

var health := 100.0
var stamina := 100.0
var hunger := 100.0
var thirst := 100.0

## Extensible environment hooks (populated by future weather/day-night/volcano systems).
var daytime_heat_multiplier := 1.0
var volcanic_ash_exposure := 0.0
var rain_intensity := 0.0

## Live computed telemetry for debug readout & player controller integration.
var current_activity: StringName = &"standing"
var current_hunger_rate := 0.0
var current_thirst_rate := 0.0
var effective_max_stamina := 100.0
var stamina_regen_multiplier := 1.0
var move_speed_multiplier := 1.0
var exhausted := false
var starvation_damage_rate := 0.0
var dehydration_damage_rate := 0.0

var _player: CharacterBody3D
var _activity_override: StringName = &""
var _activity_timer := 0.0
var _dehydration_zero_time := 0.0
var _warned_states: Dictionary = {}


func setup(player: CharacterBody3D) -> void:
	_player = player
	reset_all()


func reset_all() -> void:
	health = max_health
	stamina = base_max_stamina
	hunger = 100.0
	thirst = 100.0
	effective_max_stamina = base_max_stamina
	stamina_regen_multiplier = 1.0
	move_speed_multiplier = 1.0
	exhausted = false
	starvation_damage_rate = 0.0
	dehydration_damage_rate = 0.0
	_activity_override = &""
	_activity_timer = 0.0
	_dehydration_zero_time = 0.0
	_warned_states.clear()
	_sync_player_modifiers()
	vitals_changed.emit()


func set_environment_hooks(heat_mult: float, ash_exp: float, rain: float) -> void:
	daytime_heat_multiplier = clampf(heat_mult, 0.5, 3.0)
	volcanic_ash_exposure = clampf(ash_exp, 0.0, 1.0)
	rain_intensity = clampf(rain, 0.0, 1.0)


func register_harvest_activity(resource_kind: StringName) -> void:
	match resource_kind:
		&"tree", &"palm_tree", &"branch":
			_activity_override = &"chopping_wood"
			_activity_timer = 2.5
			stamina = maxf(0.0, stamina - 10.0)
			hunger = maxf(0.0, hunger - 0.65)
			thirst = maxf(0.0, thirst - 0.85)
		&"rock":
			_activity_override = &"heavy_gathering"
			_activity_timer = 2.5
			stamina = maxf(0.0, stamina - 12.0)
			hunger = maxf(0.0, hunger - 0.60)
			thirst = maxf(0.0, thirst - 0.90)
		_:
			_activity_override = &"light_gathering"
			_activity_timer = 1.5
			stamina = maxf(0.0, stamina - 3.0)
			hunger = maxf(0.0, hunger - 0.15)
			thirst = maxf(0.0, thirst - 0.20)
	if stamina <= 0.0:
		exhausted = true
	_recompute_penalties()
	_sync_player_modifiers()


func eat_food(hunger_gain: float, thirst_gain := 0.0) -> Dictionary:
	var h_before := hunger
	var t_before := thirst
	hunger = clampf(hunger + maxf(0.0, hunger_gain), 0.0, 100.0)
	if thirst_gain > 0.0:
		thirst = clampf(thirst + thirst_gain, 0.0, 100.0)
	if thirst > 0.0:
		_dehydration_zero_time = 0.0
	_clear_recovered_warnings()
	_recompute_penalties()
	_sync_player_modifiers()
	vitals_changed.emit()
	return {
		"hunger_restored": hunger - h_before,
		"thirst_restored": thirst - t_before,
	}


func drink_water(volume: float, quality: int) -> Dictionary:
	var effect := WaterQuality.evaluate_drink_effect(quality, volume)
	var t_before := thirst
	thirst = clampf(thirst + float(effect["thirst_delta"]), 0.0, 100.0)
	health = clampf(health + float(effect["health_delta"]), 0.0, max_health)
	if bool(effect["safe"]) and thirst > 0.0:
		_dehydration_zero_time = 0.0
	_clear_recovered_warnings()
	_recompute_penalties()
	_sync_player_modifiers()
	vitals_changed.emit()
	effect["actual_thirst_delta"] = thirst - t_before
	return effect


func step_simulation(delta: float, activity_override_for_step: StringName = &"") -> void:
	if delta <= 0.0:
		return
	if _activity_timer > 0.0:
		_activity_timer = maxf(0.0, _activity_timer - delta)
		if _activity_timer <= 0.0:
			_activity_override = &""

	var activity := activity_override_for_step if activity_override_for_step != &"" else _detect_activity()
	current_activity = activity

	var h_rate := _hunger_rate_for_activity(activity)
	var t_rate := _thirst_rate_for_activity(activity)
	var env_thirst_mult := daytime_heat_multiplier * (1.0 + volcanic_ash_exposure * ash_thirst_multiplier)
	t_rate *= env_thirst_mult

	current_hunger_rate = h_rate
	current_thirst_rate = t_rate

	hunger = clampf(hunger - h_rate * delta, 0.0, 100.0)
	thirst = clampf(thirst - t_rate * delta, 0.0, 100.0)

	if thirst <= 0.0:
		_dehydration_zero_time += delta
	else:
		_dehydration_zero_time = 0.0

	_recompute_penalties()

	# Stamina drain / regen.
	if activity == &"sprinting" and not exhausted:
		stamina = maxf(0.0, stamina - stamina_sprint_drain * delta)
		if stamina <= 0.0:
			exhausted = true
			_emit_warning_once(&"exhausted", "Exhausted! Rest to recover stamina.")
	else:
		stamina = minf(effective_max_stamina, stamina + stamina_base_regen * stamina_regen_multiplier * delta)
		if exhausted and stamina >= exhaustion_recover_threshold:
			exhausted = false
			_warned_states.erase(&"exhausted")

	# Continuous starvation & progressive dehydration damage (never instant kill).
	var total_dps := starvation_damage_rate + dehydration_damage_rate
	if total_dps > 0.0:
		health = maxf(0.0, health - total_dps * delta)

	_check_threshold_warnings()
	_sync_player_modifiers()
	vitals_changed.emit()


func _process(delta: float) -> void:
	step_simulation(delta)


func get_active_penalties() -> Array[String]:
	var list: Array[String] = []
	if hunger <= 0.0:
		list.append("STARVATION (-%.1f HP/s)" % starvation_damage_rate)
	elif hunger < 15.0:
		list.append("SEVERE HUNGER (Max Stamina %.0f)" % effective_max_stamina)
	elif hunger < 30.0:
		list.append("HUNGRY (Slower Stamina Regen)")
	if thirst <= 0.0:
		list.append("DEHYDRATION (-50%% Speed, -%.1f HP/s)" % dehydration_damage_rate)
	elif thirst < 15.0:
		list.append("SEVERE THIRST (Speed %.0f%%)" % (move_speed_multiplier * 100.0))
	elif thirst < 30.0:
		list.append("THIRSTY (Slower Stamina Regen)")
	if exhausted:
		list.append("EXHAUSTED (Cannot Sprint)")
	return list


func get_debug_summary() -> String:
	var penalties := get_active_penalties()
	var pen_str := ", ".join(penalties) if not penalties.is_empty() else "None"
	return (
		"SURVIVAL DEBUG [F4 Hide | F3 Rain | F2 -25 Drain]\n"
		+ "Health: %.1f / %.0f   |   Stamina: %.1f / %.0f (Regen x%.2f)\n" % [health, max_health, stamina, effective_max_stamina, stamina_regen_multiplier]
		+ "Hunger: %.1f%% (-%.3f/s)   |   Thirst: %.1f%% (-%.3f/s)\n" % [hunger, current_hunger_rate, thirst, current_thirst_rate]
		+ "Activity: %s   |   Move Speed: %.0f%%\n" % [String(current_activity), move_speed_multiplier * 100.0]
		+ "Env Hooks — Heat: x%.2f  Ash: %.0f%%  Rain: %.0f%%\n" % [daytime_heat_multiplier, volcanic_ash_exposure * 100.0, rain_intensity * 100.0]
		+ "Penalties: %s" % pen_str
	)


func serialize() -> Dictionary:
	return {
		"health": snappedf(health, 0.1),
		"stamina": snappedf(stamina, 0.1),
		"hunger": snappedf(hunger, 0.1),
		"thirst": snappedf(thirst, 0.1),
		"dehydration_zero_time": snappedf(_dehydration_zero_time, 0.1),
		"daytime_heat_multiplier": snappedf(daytime_heat_multiplier, 0.01),
		"volcanic_ash_exposure": snappedf(volcanic_ash_exposure, 0.01),
		"rain_intensity": snappedf(rain_intensity, 0.01),
	}


func deserialize(data: Dictionary) -> void:
	health = clampf(float(data.get("health", max_health)), 0.0, max_health)
	hunger = clampf(float(data.get("hunger", 100.0)), 0.0, 100.0)
	thirst = clampf(float(data.get("thirst", 100.0)), 0.0, 100.0)
	_dehydration_zero_time = maxf(0.0, float(data.get("dehydration_zero_time", 0.0)))
	daytime_heat_multiplier = clampf(float(data.get("daytime_heat_multiplier", 1.0)), 0.5, 3.0)
	volcanic_ash_exposure = clampf(float(data.get("volcanic_ash_exposure", 0.0)), 0.0, 1.0)
	rain_intensity = clampf(float(data.get("rain_intensity", 0.0)), 0.0, 1.0)
	_recompute_penalties()
	stamina = clampf(float(data.get("stamina", effective_max_stamina)), 0.0, effective_max_stamina)
	exhausted = stamina <= 0.0
	_warned_states.clear()
	_sync_player_modifiers()
	vitals_changed.emit()


func _detect_activity() -> StringName:
	if _activity_override != &"" and _activity_timer > 0.0:
		return _activity_override
	if _player == null:
		return &"standing"
	var hspeed := Vector2(_player.velocity.x, _player.velocity.z).length()
	if _player.has_method("is_sprinting") and bool(_player.call("is_sprinting")) and hspeed > 0.4:
		return &"sprinting"
	if hspeed > 0.25:
		return &"walking"
	return &"standing"


func _hunger_rate_for_activity(activity: StringName) -> float:
	match activity:
		&"chopping_wood":
			return hunger_rate_chopping
		&"heavy_gathering":
			return hunger_rate_heavy_gather
		&"light_gathering":
			return hunger_rate_light_gather
		&"sprinting":
			return hunger_rate_sprinting
		&"walking":
			return hunger_rate_walking
		_:
			return hunger_rate_standing


func _thirst_rate_for_activity(activity: StringName) -> float:
	match activity:
		&"chopping_wood", &"heavy_gathering":
			return thirst_rate_strenuous
		&"light_gathering":
			return thirst_rate_light_gather
		&"sprinting":
			return thirst_rate_sprinting
		&"walking":
			return thirst_rate_walking
		_:
			return thirst_rate_standing


func _recompute_penalties() -> void:
	# Hunger penalties: <30% slower stamina regen; <15% reduced max stamina; 0% starvation damage.
	var hunger_regen := 1.0
	if hunger < 15.0:
		hunger_regen = 0.35
		effective_max_stamina = lerpf(base_max_stamina * 0.55, base_max_stamina, clampf(hunger / 15.0, 0.0, 1.0))
	elif hunger < 30.0:
		hunger_regen = 0.55
		effective_max_stamina = base_max_stamina
	else:
		effective_max_stamina = base_max_stamina
	stamina = minf(stamina, effective_max_stamina)
	starvation_damage_rate = starvation_dps if hunger <= 0.0 else 0.0

	# Thirst penalties: <30% slower stamina regen; <15% speed drop; 0% -50% speed + progressive damage.
	var thirst_regen := 1.0
	if thirst <= 0.0:
		thirst_regen = 0.25
		move_speed_multiplier = 0.50
		var ramp := clampf(_dehydration_zero_time / maxf(1.0, dehydration_ramp_seconds), 0.0, 1.0)
		dehydration_damage_rate = lerpf(dehydration_base_dps, dehydration_max_dps, ramp)
	elif thirst < 15.0:
		thirst_regen = 0.35
		move_speed_multiplier = lerpf(0.50, 1.0, clampf(thirst / 15.0, 0.0, 1.0))
		dehydration_damage_rate = 0.0
	elif thirst < 30.0:
		thirst_regen = 0.55
		move_speed_multiplier = 1.0
		dehydration_damage_rate = 0.0
	else:
		move_speed_multiplier = 1.0
		dehydration_damage_rate = 0.0

	stamina_regen_multiplier = hunger_regen * thirst_regen


func _sync_player_modifiers() -> void:
	if _player == null:
		return
	if "survival_speed_scale" in _player:
		_player.set("survival_speed_scale", move_speed_multiplier)
	if "can_sprint" in _player:
		_player.set("can_sprint", not exhausted)


func _check_threshold_warnings() -> void:
	if hunger <= 0.0:
		_emit_warning_once(&"starving", "STARVING! You are taking starvation damage — eat immediately.")
	elif hunger < 15.0:
		_emit_warning_once(&"hunger_crit", "Severe Hunger — Max stamina reduced.")
	elif hunger < 30.0:
		_emit_warning_once(&"hunger_low", "Hungry — Stamina recovery slowed.")

	if thirst <= 0.0:
		_emit_warning_once(&"dehydrating", "SEVERE DEHYDRATION! Movement halved and taking damage — drink freshwater.")
	elif thirst < 15.0:
		_emit_warning_once(&"thirst_crit", "Severe Thirst — Movement speed slowing.")
	elif thirst < 30.0:
		_emit_warning_once(&"thirst_low", "Thirsty — Stamina recovery slowed.")


func _clear_recovered_warnings() -> void:
	if hunger >= 30.0:
		_warned_states.erase(&"hunger_low")
	if hunger >= 15.0:
		_warned_states.erase(&"hunger_crit")
	if hunger > 0.0:
		_warned_states.erase(&"starving")
	if thirst >= 30.0:
		_warned_states.erase(&"thirst_low")
	if thirst >= 15.0:
		_warned_states.erase(&"thirst_crit")
	if thirst > 0.0:
		_warned_states.erase(&"dehydrating")


func _emit_warning_once(key: StringName, msg: String) -> void:
	if _warned_states.has(key):
		return
	_warned_states[key] = true
	critical_warning.emit(key, msg)
