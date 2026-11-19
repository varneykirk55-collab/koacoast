extends CharacterBody3D
## Simple third-person controller: walk, sprint, crouch, jump, plus a live speed adjuster.
##
## Controls
##   WASD / Arrows  - move
##   Mouse          - look (click to capture, Esc to release)
##   Shift          - sprint (hold)
##   Ctrl / C       - crouch (hold)
##   Space          - jump
##   Mouse wheel or + / -  - adjust speed multiplier (0 resets)

@export_group("Speeds (m/s)")
@export var walk_speed := 5.0
@export var sprint_speed := 9.0
@export var crouch_speed := 2.5
@export var jump_velocity := 5.5

@export_group("Speed Adjuster")
@export var speed_multiplier := 1.0
@export var min_multiplier := 0.25
@export var max_multiplier := 4.0
@export var multiplier_step := 0.25

@export_group("Feel")
@export var acceleration := 12.0
@export var air_control := 0.3
@export var turn_speed := 10.0
@export var mouse_sensitivity := 0.003
@export var stand_height := 1.8
@export var crouch_height := 1.0

@export_group("Spawn")
## If true, the player is snapped onto the terrain surface at start.
@export var snap_to_terrain := true
@export var terrain_path: NodePath

@onready var _collision: CollisionShape3D = $Collision
@onready var _body_mesh: MeshInstance3D = $BodyMesh
@onready var _pivot: Node3D = $CameraPivot
@onready var _spring: SpringArm3D = $CameraPivot/SpringArm3D
@onready var _hud: Label = $HUD/Info

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var _crouching := false
var _sprinting := false
var _current_height := 1.8


func _ready() -> void:
	_register_inputs()
	_current_height = stand_height
	_apply_height(stand_height)
	_spring.add_excluded_object(get_rid())
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
		"crouch": [KEY_CTRL, KEY_C],
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
		global_position.y = height + 0.5
		velocity = Vector3.ZERO


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
		_spring.rotation.x = clampf(_spring.rotation.x - event.relative.y * mouse_sensitivity, -1.3, 0.6)
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
	# --- Crouch (only stand up if there is headroom) ---
	var want_crouch := Input.is_action_pressed("crouch")
	if want_crouch:
		_crouching = true
	elif _crouching and _has_headroom():
		_crouching = false
	var target_h := crouch_height if _crouching else stand_height
	if not is_equal_approx(_current_height, target_h):
		_current_height = move_toward(_current_height, target_h, delta * 6.0)
		_apply_height(_current_height)

	# --- Gravity & jump ---
	if not is_on_floor():
		velocity.y -= _gravity * delta
	elif Input.is_action_just_pressed("jump") and not _crouching:
		velocity.y = jump_velocity

	# --- Movement relative to camera ---
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var dir := (_pivot.global_basis * Vector3(input.x, 0.0, input.y))
	dir.y = 0.0
	dir = dir.normalized()

	_sprinting = Input.is_action_pressed("sprint") and not _crouching and input.length() > 0.1
	var base := crouch_speed if _crouching else (sprint_speed if _sprinting else walk_speed)
	var speed := base * speed_multiplier

	var accel := acceleration if is_on_floor() else acceleration * air_control
	var target := dir * speed
	velocity.x = lerpf(velocity.x, target.x, clampf(accel * delta, 0.0, 1.0))
	velocity.z = lerpf(velocity.z, target.z, clampf(accel * delta, 0.0, 1.0))

	# Turn the visible body toward movement direction.
	if dir.length() > 0.01:
		var yaw := atan2(-dir.x, -dir.z)
		_body_mesh.rotation.y = lerp_angle(_body_mesh.rotation.y, yaw, clampf(turn_speed * delta, 0.0, 1.0))

	move_and_slide()
	_update_hud()


func _has_headroom() -> bool:
	var params := PhysicsTestMotionParameters3D.new()
	params.from = global_transform
	params.motion = Vector3.UP * (stand_height - _current_height)
	params.exclude_bodies = [get_rid()]
	return not PhysicsServer3D.body_test_motion(get_rid(), params)


func _apply_height(h: float) -> void:
	var capsule := _collision.shape as CapsuleShape3D
	capsule.height = h
	_collision.position.y = h * 0.5
	var mesh := _body_mesh.mesh as CapsuleMesh
	mesh.height = h
	_body_mesh.position.y = h * 0.5
	_pivot.position.y = h * 0.85


func _update_hud() -> void:
	var state := "Air"
	if is_on_floor():
		if _crouching:
			state = "Crouch"
		elif _sprinting:
			state = "Sprint"
		elif Vector2(velocity.x, velocity.z).length() > 0.2:
			state = "Walk"
		else:
			state = "Idle"
	var hspeed := Vector2(velocity.x, velocity.z).length()
	_hud.text = "%s   %.1f m/s   Speed x%.2f\n[Wheel / + -] adjust   [0] reset   [Shift] sprint   [Ctrl/C] crouch   [Space] jump" % [state, hspeed, speed_multiplier]
