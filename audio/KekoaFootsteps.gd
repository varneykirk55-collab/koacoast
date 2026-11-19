extends Node
## Tracks real grounded travel and derives stride from the active locomotion clips.
## No input or movement is changed.

signal foot_contact(surface: String, landing: bool, position: Vector3)

const SURFACES := ["grass", "leaves", "undergrowth", "soil", "rock", "sand", "mud", "water", "brush"]
const SLOTS := 4

@onready var audio = get_parent()
@onready var player: CharacterBody3D = audio.player
@onready var terrain: Terrain3D = audio.terrain
@onready var animation: AnimationPlayer = player.get_node("Visual/AnimationPlayer")

var voices: Array[AudioStreamPlayer3D] = []
var variants: Dictionary = {}
var last_sample: Dictionary = {}
var rng := RandomNumberGenerator.new()
var prior := Vector3.ZERO
var initialized := false
var airborne := 0.0
var fall_speed := 0.0
var stride := 0.0
var brush_time := 0.0
var walk_step := 0.46
var run_step := 1.06
var habitat := FastNoiseLite.new()


func _ready() -> void:
	rng.randomize()
	habitat.seed = 7321
	habitat.frequency = 0.033
	var walk := animation.get_animation("Walk")
	var run := animation.get_animation("Run")
	if walk:
		walk_step = clampf(walk.length * player.walk_speed * 0.5, 0.36, 0.95)
	if run:
		run_step = clampf(run.length * player.sprint_speed * 0.5, 0.76, 2.4)
	for kind: String in SURFACES:
		variants[kind] = [audio.sound(kind + "_1"), audio.sound(kind + "_2")]
	for i in SLOTS:
		var voice := AudioStreamPlayer3D.new()
		voice.bus = "Effects"
		voice.unit_size = 2.5
		voice.max_distance = 24.0
		voice.max_db = -6.0
		add_child(voice)
		voices.append(voice)


func stop_audio() -> void:
	set_physics_process(false)
	for voice in voices:
		voice.stop()


func _physics_process(delta: float) -> void:
	var current := player.global_position
	if not initialized:
		initialized = true
		prior = current
		return
	var travel := current - prior
	prior = current
	if not player.is_on_floor():
		airborne += delta
		fall_speed = maxf(fall_speed, -player.velocity.y)
		stride = 0.0
		return
	var pace := Vector2(player.velocity.x, player.velocity.z).length()
	var running := smoothstep(player.walk_speed, player.sprint_speed, pace / player.speed_multiplier)
	if airborne > 0.12 and fall_speed > 1.6:
		_contact(current, lerpf(-18.0, -9.0, smoothstep(1.6, 9.5, fall_speed)), true)
		stride = 0.0
	airborne = 0.0
	fall_speed = 0.0
	var ground_distance := Vector2(travel.x, travel.z).length()
	if pace < 0.15 or ground_distance > 1.8:
		stride = 0.0
		return
	stride += ground_distance
	var interval := lerpf(walk_step, run_step, running)
	if stride >= interval:
		stride = fmod(stride, interval)
		_contact(current, lerpf(-22.0, -15.0, running), false)
	brush_time = maxf(brush_time - delta, 0.0)


func surface_mix(p: Vector3) -> Dictionary:
	var h := terrain.data.get_height(p)
	if is_finite(h) and absf(h - p.y) < 0.6:
		p.y = h
	var depth: float = audio.water_depth(p)
	var texture := terrain.data.get_texture_id(p)
	var grass: float = audio.material_weight(texture, 2)
	var dirt: float = audio.material_weight(texture, 1)
	var sand: float = audio.material_weight(texture, 3)
	var wet: float = audio.material_weight(texture, 4)
	var rock: float = audio.material_weight(texture, 0) + wet
	# Leaf litter and undergrowth share the grass terrain layer. Habitat and
	# existing grass/soil blends distinguish these sounds without repainting.
	var shelter := smoothstep(-0.34, 0.42, habitat.get_noise_2d(p.x, p.z))
	var lowland := smoothstep(1.8, 10.0, p.y) * (1.0 - smoothstep(105.0, 165.0, p.y))
	var dense := clampf(shelter * lowland * (0.61 + dirt * 0.55), 0.0, 1.0)
	var dry_litter := minf(0.86, smoothstep(0.38, 0.92, 1.0 - shelter) * lowland * (0.83 + dirt * 0.36))
	var splash := smoothstep(0.022, 0.12, depth)
	var mud := clampf(dirt * smoothstep(0.03, 0.38, wet + depth * 1.8) + wet * 0.73, 0.0, 1.0)
	return {
		"grass": grass * (1.0 - dense) * (1.0 - dry_litter) * (1.0 - splash),
		"leaves": grass * dry_litter * (1.0 - splash),
		"undergrowth": grass * dense * (1.0 - splash),
		"soil": dirt * (1.0 - mud) * (1.0 - splash),
		"rock": rock * (1.0 - mud) * (1.0 - splash),
		"sand": sand * (1.0 - splash),
		"mud": mud * (1.0 - splash),
		"water": splash,
	}


func _contact(p: Vector3, level: float, landing: bool) -> void:
	var weights := surface_mix(p)
	var ranked := weights.keys()
	ranked.sort_custom(func(a: String, b: String) -> bool: return weights[a] > weights[b])
	var surface: String = ranked[0] if weights[ranked[0]] > 0.01 else "rock"
	var secondary: String = ranked[1]
	var blend := minf(0.43, weights[secondary] / maxf(weights[surface] + weights[secondary], 0.01))
	_play(surface, p, level + linear_to_db(1.0 - blend), landing)
	if blend > 0.25:
		_play(secondary, p, level + linear_to_db(blend) - 3.0, landing)
	foot_contact.emit(surface, landing, p)
	if not landing and (surface == "undergrowth" or weights.undergrowth > 0.32) and brush_time <= 0.0:
		_play("brush", p + Vector3.UP * 0.45, level - 7.0, false)
		brush_time = rng.randf_range(0.85, 2.4)


func _play(kind: String, p: Vector3, level: float, landing: bool) -> void:
	for voice in voices:
		if voice.playing:
			continue
		var variant := 1 - int(last_sample.get(kind, rng.randi_range(0, 1)))
		last_sample[kind] = variant
		voice.global_position = p
		voice.stream = variants[kind][variant]
		voice.pitch_scale = rng.randf_range(0.83, 0.96) if landing else rng.randf_range(0.92, 1.14)
		voice.volume_db = level + rng.randf_range(-1.7, 1.0)
		voice.play()
		return
