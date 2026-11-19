extends CharacterBody3D
## Kekoa, third-person player.
##
## Controls
##   WASD / Arrows  - move (relative to the camera)
##   Mouse          - look (click to capture, Esc to release)
##   Shift          - sprint (hold)
##   Space          - jump
##   Mouse wheel or + / -  - speed multiplier (0 resets)
##
## Animations live in player/kekoa/anims/KekoaAnims.tres (Idle, Walk, Run, Jump, Fall).
## Drop Mixamo FBX files named Idle.fbx, Walk.fbx, Run.fbx or Jump.fbx into
## player/kekoa/animations/ and they replace the matching clip on the next run.

const ANIM_DIR := "res://player/kekoa/animations"

@export_group("Speeds (m/s)")
## Matches the Walk clip's stride, so feet don't slide.
@export var walk_speed := 1.7
## Matches the Run clip's stride.
@export var sprint_speed := 5.6
@export var jump_velocity := 5.5

@export_group("Speed Adjuster")
@export var speed_multiplier := 1.0
@export var min_multiplier := 0.5
@export var max_multiplier := 2.0
@export var multiplier_step := 0.25

@export_group("Feel")
@export var acceleration := 10.0
@export var air_control := 0.3
@export var turn_speed := 10.0
@export var mouse_sensitivity := 0.003
## How quickly the camera catches up with Kekoa (higher = tighter).
@export var camera_follow := 12.0
@export var camera_height := 1.55

@export_group("Spawn")
## If true, Kekoa is snapped onto the terrain surface at start.
@export var snap_to_terrain := true
@export var terrain_path: NodePath

@onready var _visual: Node3D = $Visual
@onready var _anim_player: AnimationPlayer = $Visual/AnimationPlayer
@onready var _tree: AnimationTree = $Visual/AnimationTree
@onready var _pivot: Node3D = $CameraPivot
@onready var _spring: SpringArm3D = $CameraPivot/SpringArm3D
@onready var _hud: Label = $HUD/Info

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var _sprinting := false
var _jumping := false
var _air_time := 0.0
var _blend := 0.0
var _playback: AnimationNodeStateMachinePlayback


func _ready() -> void:
	_register_inputs()
	_load_dropped_in_clips()
	_playback = _tree.get("parameters/playback")
	_tree.active = true
	_spring.add_excluded_object(get_rid())
	# The camera rig follows smoothly instead of being rigidly parented.
	_pivot.top_level = true
	_pivot.global_position = global_position + Vector3.UP * camera_height
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if snap_to_terrain:
		_snap_to_ground.call_deferred()


func _register_inputs() -> void:
	var map := {
		"move_forward": [KEY_W, KEY_UP],
		"move_back": [KEY_S, KEY_DOWN],
		"move_left": [KEY_A, KEY_LEFT],
		"move_right": [KEY_D, KEY_RIGHT],
		"jump": [KEY_SPACE],
		"sprint": [KEY_SHIFT],
		"speed_up": [KEY_EQUAL, KEY_KP_ADD],
		"speed_down": [KEY_MINUS, KEY_KP_SUBTRACT],
		"speed_reset": [KEY_0, KEY_KP_0],
	}
	for action in map:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		for key in map[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = key
			InputMap.action_add_event(action, ev)


## Swaps in Idle/Walk/Run/Jump clips the owner downloaded from Mixamo.
func _load_dropped_in_clips() -> void:
	var kekoa_skel: Skeleton3D = $Visual/Kekoa/Skeleton3D
	var lib := _anim_player.get_animation_library("")
	for clip in ["Idle", "Walk", "Run", "Jump"]:
		var path := ANIM_DIR.path_join(clip + ".fbx")
		if not ResourceLoader.exists(path):
			continue
		var scene := load(path) as PackedScene
		if scene == null:
			continue
		var src := KekoaAnimTools.read_scene(scene)
		if src.skeleton and src.animation:
			var anim := KekoaAnimTools.convert(src.animation, src.skeleton, kekoa_skel, clip != "Jump", true, clip == "Jump")
			if lib.has_animation(clip):
				lib.remove_animation(clip)
			lib.add_animation(clip, anim)
			print("Kekoa: using ", path)
		src.root.free()


func _snap_to_ground() -> void:
	var height := NAN
	var terrain := get_node_or_null(terrain_path)
	if terrain and terrain.get("data") != null:
		var data = terrain.data
		var here: float = data.get_height(global_position)
		# Keep the placed spawn if it is already good; otherwise search the island.
		if not _is_safe_spot(data, global_position):
			var spot := _find_coastal_flat(terrain)
			if spot != Vector3.INF:
				global_position = Vector3(spot.x, global_position.y, spot.z)
				here = spot.y
		height = here
	if is_nan(height) or height > 1.0e6:
		# Fallback: raycast down from high above.
		await get_tree().physics_frame
		var from := global_position + Vector3.UP * 2000.0
		var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 4000.0)
		q.exclude = [get_rid()]
		var hit := get_world_3d().direct_space_state.intersect_ray(q)
		if hit:
			height = hit.position.y
	if not is_nan(height):
		global_position.y = height + 0.1
		velocity = Vector3.ZERO
		_pivot.global_position = global_position + Vector3.UP * camera_height


## Dry (above sea level), low, and nearly flat within ~8 m.
func _is_safe_spot(data, p: Vector3) -> bool:
	var h: float = data.get_height(p)
	if is_nan(h) or h < 2.0 or h > 30.0:
		return false
	for o in [Vector3(4, 0, 0), Vector3(-4, 0, 0), Vector3(0, 0, 4), Vector3(0, 0, -4),
			Vector3(8, 0, 0), Vector3(-8, 0, 0), Vector3(0, 0, 8), Vector3(0, 0, -8)]:
		var hn: float = data.get_height(p + o)
		if is_nan(hn) or absf(hn - h) > o.length() * 0.2:  # < ~11 deg
			return false
	return true


## Scans the whole terrain for the flattest low ground with sea within ~150 m.
## Returns Vector3(x, height, z) or Vector3.INF.
func _find_coastal_flat(terrain: Node) -> Vector3:
	var data = terrain.data
	var size := float(terrain.region_size) * float(terrain.vertex_spacing)
	var best := Vector3.INF
	var best_score := INF
	var origin := global_position
	for region in data.get_regions_active():
		var loc: Vector2i = region.location
		for ix in range(1, 32):
			for iz in range(1, 32):
				var p := Vector3((loc.x + ix / 32.0) * size, 0.0, (loc.y + iz / 32.0) * size)
				if not _is_safe_spot(data, p):
					continue
				var h: float = data.get_height(p)
				var rough := 0.0
				for o in [Vector3(6, 0, 0), Vector3(-6, 0, 0), Vector3(0, 0, 6), Vector3(0, 0, -6)]:
					rough += absf(data.get_height(p + o) - h)
				var score := rough + Vector2(p.x - origin.x, p.z - origin.z).length() * 0.002
				if is_nan(score) or score >= best_score:
					continue
				var coastal := false
				for k in 8:
					var a := TAU * k / 8.0
					var w: float = data.get_height(p + Vector3(cos(a), 0.0, sin(a)) * 150.0)
					if not is_nan(w) and w < 0.0:
						coastal = true
						break
				if coastal:
					best_score = score
					best = Vector3(p.x, h, p.z)
	return best


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_change_multiplier(multiplier_step)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_change_multiplier(-multiplier_step)
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_pivot.rotation.y -= event.relative.x * mouse_sensitivity
		_spring.rotation.x = clampf(_spring.rotation.x - event.relative.y * mouse_sensitivity, -1.2, 0.5)
	elif event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event.is_action_pressed("speed_up"):
		_change_multiplier(multiplier_step)
	elif event.is_action_pressed("speed_down"):
		_change_multiplier(-multiplier_step)
	elif event.is_action_pressed("speed_reset"):
		speed_multiplier = 1.0


func _change_multiplier(delta_value: float) -> void:
	speed_multiplier = clampf(snappedf(speed_multiplier + delta_value, 0.01), min_multiplier, max_multiplier)


func _physics_process(delta: float) -> void:
	# --- Gravity & jump ---
	var jumped := false
	if not is_on_floor():
		velocity.y -= _gravity * delta
		_air_time += delta
	else:
		_air_time = 0.0
		_jumping = false
		if Input.is_action_just_pressed("jump"):
			velocity.y = jump_velocity
			_jumping = true
			jumped = true

	# --- Movement relative to camera ---
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var dir := _pivot.global_basis * Vector3(input.x, 0.0, input.y)
	dir.y = 0.0
	dir = dir.normalized()

	_sprinting = Input.is_action_pressed("sprint") and input.length() > 0.1
	var speed := (sprint_speed if _sprinting else walk_speed) * speed_multiplier
	var accel := acceleration if is_on_floor() else acceleration * air_control
	var target := dir * speed
	velocity.x = lerpf(velocity.x, target.x, clampf(accel * delta, 0.0, 1.0))
	velocity.z = lerpf(velocity.z, target.z, clampf(accel * delta, 0.0, 1.0))

	# Turn Kekoa toward the way he's moving (the model faces +Z).
	if dir.length() > 0.01:
		var yaw := atan2(dir.x, dir.z)
		_visual.rotation.y = lerp_angle(_visual.rotation.y, yaw, clampf(turn_speed * delta, 0.0, 1.0))

	move_and_slide()
	_update_animation(delta, jumped)
	_update_hud()


func _process(delta: float) -> void:
	# Smooth camera follow; the SpringArm keeps it out of the ground.
	var goal := global_position + Vector3.UP * camera_height
	_pivot.global_position = _pivot.global_position.lerp(goal, clampf(camera_follow * delta, 0.0, 1.0))


func _update_animation(delta: float, jumped: bool) -> void:
	var hspeed := Vector2(velocity.x, velocity.z).length()
	# Blend position is in "clip speed" (m/s at x1), so the playback rate
	# follows the speed multiplier and the feet stay planted.
	_blend = lerpf(_blend, hspeed / speed_multiplier, clampf(10.0 * delta, 0.0, 1.0))
	_tree.set("parameters/Move/Locomotion/blend_position", _blend)
	_tree.set("parameters/Move/Pace/scale", clampf(speed_multiplier, 0.5, 2.0))

	var state := _playback.get_current_node()
	if jumped:
		_playback.travel("Jump")
	elif is_on_floor():
		if state != "Move":
			_playback.travel("Move")
	elif not _jumping and _air_time > 0.25 and state == "Move":
		_playback.travel("Fall")


func _update_hud() -> void:
	var state := "Air"
	if is_on_floor():
		if _sprinting:
			state = "Sprint"
		elif Vector2(velocity.x, velocity.z).length() > 0.2:
			state = "Walk"
		else:
			state = "Idle"
	var hspeed := Vector2(velocity.x, velocity.z).length()
	_hud.text = "%s   %.1f m/s   Speed x%.2f\n[Wheel / + -] adjust   [0] reset   [Shift] sprint   [Space] jump" % [state, hspeed, speed_multiplier]
