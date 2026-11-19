extends SceneTree
## Scripted check of Kekoa: spawns, stands on Terrain3D, walks, sprints, jumps.
## Godot --path . --script res://tools/test_kekoa.gd -- [--shots=/tmp/kekoa]
## (headless works for the logic; screenshots need a real display/GPU.)

var _player: CharacterBody3D
var _playback: AnimationNodeStateMachinePlayback
var _tree: AnimationTree
var _frame := 0
var _shots := ""
var _log := []
var _spawn := Vector3.ZERO
var _phase_start := Vector3.ZERO
var _jump_peak := -INF
var _jump_start_y := 0.0
var _saw_states := {}
var _failures := []

# frame-indexed script (60 physics fps)
const SETTLE := 90


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shots="):
			_shots = arg.trim_prefix("--shots=")
	if _shots != "":
		DirAccess.make_dir_recursive_absolute(_shots)
	var scene := (load("res://scenes/KoaCoast.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	_player = scene.get_node("Player")
	_tree = _player.get_node("Visual/AnimationTree")


func _physics_process(_delta: float) -> bool:
	_frame += 1
	if _playback == null:
		_playback = _tree.get("parameters/playback")
	var state := String(_playback.get_current_node()) if _playback else ""
	_saw_states[state] = true
	var p := _player.global_position
	match _frame:
		SETTLE:
			_spawn = p
			var terrain_h: float = _player.get_node("../Terrain3D").data.get_height(p)
			var skel: Skeleton3D = _player.get_node("Visual/Kekoa/Skeleton3D")
			var head := skel.get_bone_global_pose(skel.find_bone("mixamorig_HeadTop_End"))
			var head_y: float = (skel.global_transform * head).origin.y - p.y
			_report("SPAWN pos=%s on_floor=%s terrain_h=%.2f gap=%.3f state=%s headtop_above_feet=%.2f" % [p, _player.is_on_floor(), terrain_h, p.y - terrain_h, state, head_y])
			if not _player.is_on_floor():
				_failures.append("not on floor at spawn")
			_shot("01_idle")
			Input.action_press("move_forward")
			_phase_start = p
		SETTLE + 120:
			var d := Vector2(p.x - _phase_start.x, p.z - _phase_start.z).length()
			_report("WALK 2s dist=%.2f m speed=%.2f on_floor=%s state=%s blend=%.2f" % [d, Vector2(_player.velocity.x, _player.velocity.z).length(), _player.is_on_floor(), state, _tree.get("parameters/Move/Locomotion/blend_position")])
			if d < 2.0:
				_failures.append("walk moved only %.2f m" % d)
			_shot("02_walk")
			Input.action_press("sprint")
			_phase_start = p
		SETTLE + 240:
			var d := Vector2(p.x - _phase_start.x, p.z - _phase_start.z).length()
			_report("SPRINT 2s dist=%.2f m speed=%.2f on_floor=%s state=%s blend=%.2f" % [d, Vector2(_player.velocity.x, _player.velocity.z).length(), _player.is_on_floor(), state, _tree.get("parameters/Move/Locomotion/blend_position")])
			if d < 7.0:
				_failures.append("sprint moved only %.2f m" % d)
			_shot("03_sprint")
			Input.action_release("sprint")
			Input.action_release("move_forward")
		SETTLE + 300:
			_jump_start_y = p.y
			Input.action_press("jump")
		SETTLE + 302:
			Input.action_release("jump")
		SETTLE + 320:
			_report("JUMP mid: rise=%.2f state=%s on_floor=%s" % [p.y - _jump_start_y, state, _player.is_on_floor()])
			_shot("04_jump")
		SETTLE + 420:
			_report("LANDED peak_rise=%.2f on_floor=%s state=%s states_seen=%s" % [_jump_peak - _jump_start_y, _player.is_on_floor(), state, _saw_states.keys()])
			if _jump_peak - _jump_start_y < 0.8:
				_failures.append("jump too low")
			if not _player.is_on_floor():
				_failures.append("not on floor after landing")
			_shot("05_landed")
			# Turn left 90 degrees and walk, to check the model faces travel.
			_player.get_node("CameraPivot").rotation.y += PI * 0.5
			Input.action_press("move_forward")
		SETTLE + 520:
			Input.action_release("move_forward")
			var fwd: Vector3 = _player.get_node("Visual/Kekoa").global_basis.z
			var vel := Vector3(_player.velocity.x, 0, _player.velocity.z).normalized()
			_report("FACING model_forward=%s last_move_dir=%s" % [fwd, vel])
		SETTLE + 560:
			_report("RESULT " + ("PASS" if _failures.is_empty() else "FAIL " + str(_failures)))
			quit(0 if _failures.is_empty() else 1)
	if _frame > SETTLE + 300:
		_jump_peak = maxf(_jump_peak, p.y)
	if _frame > SETTLE + 302 and _frame < SETTLE + 420 and _frame % 6 == 0:
		_log.append("%s %.2f" % [state, p.y - _jump_start_y])
	if _frame == SETTLE + 419:
		_report("JUMP trace " + ", ".join(_log))
	return false


func _report(s: String) -> void:
	print("[kekoa-test] ", s)


func _shot(name: String) -> void:
	if _shots == "" or DisplayServer.get_name() == "headless":
		return
	var vp := root.get_viewport()
	await RenderingServer.frame_post_draw
	vp.get_texture().get_image().save_png(_shots.path_join(name + ".png"))
