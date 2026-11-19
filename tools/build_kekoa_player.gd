extends SceneTree
## Builds res://player/KekoaPlayer.tscn (node tree + AnimationTree).
## Godot --headless --path . --script res://tools/build_kekoa_player.gd

const OUT := "res://player/KekoaPlayer.tscn"


func _own(n: Node, owner_node: Node) -> void:
	n.owner = owner_node


func _initialize() -> void:
	var lib: AnimationLibrary = load("res://player/kekoa/anims/KekoaAnims.tres")
	var speeds: Dictionary = lib.get_meta("ground_speed", {"Walk": 1.7, "Run": 5.6})

	var root := CharacterBody3D.new()
	root.name = "Player"
	root.set_script(load("res://player/KekoaPlayer.gd"))
	root.floor_snap_length = 0.45
	root.floor_max_angle = deg_to_rad(50.0)
	root.floor_constant_speed = true
	root.collision_layer = 2
	root.collision_mask = 1
	root.set("walk_speed", speeds.Walk)
	root.set("sprint_speed", speeds.Run)

	var col := CollisionShape3D.new()
	col.name = "Collision"
	var cap := CapsuleShape3D.new()
	cap.radius = 0.3
	cap.height = 1.75
	col.shape = cap
	col.position.y = 0.875
	root.add_child(col)
	_own(col, root)

	var visual := Node3D.new()
	visual.name = "Visual"
	root.add_child(visual)
	_own(visual, root)

	var model: Node3D = (load("res://player/kekoa/Kekoa.fbx") as PackedScene).instantiate()
	model.name = "Kekoa"
	visual.add_child(model)
	_own(model, root)

	var ap := AnimationPlayer.new()
	ap.name = "AnimationPlayer"
	visual.add_child(ap)
	_own(ap, root)
	ap.root_node = NodePath("../Kekoa")
	ap.add_animation_library("", lib)

	var tree := AnimationTree.new()
	tree.name = "AnimationTree"
	visual.add_child(tree)
	_own(tree, root)
	tree.anim_player = NodePath("../AnimationPlayer")
	tree.root_node = NodePath("../Kekoa")
	tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS
	tree.tree_root = _make_state_machine(speeds)
	tree.active = false  # the script turns it on after loading any new clips

	var pivot := Node3D.new()
	pivot.name = "CameraPivot"
	pivot.position.y = 1.55
	root.add_child(pivot)
	_own(pivot, root)
	var arm := SpringArm3D.new()
	arm.name = "SpringArm3D"
	arm.rotation.x = -0.25
	arm.spring_length = 4.0
	arm.margin = 0.25
	arm.collision_mask = 1  # Terrain3D
	var ball := SphereShape3D.new()
	ball.radius = 0.25
	arm.shape = ball
	pivot.add_child(arm)
	_own(arm, root)
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	cam.fov = 70.0
	cam.near = 0.05
	cam.far = 65000.0
	cam.current = true
	cam.position.x = 0.35  # slight over-the-shoulder offset
	arm.add_child(cam)
	_own(cam, root)

	var hud := CanvasLayer.new()
	hud.name = "HUD"
	root.add_child(hud)
	_own(hud, root)
	var label := Label.new()
	label.name = "Info"
	label.offset_left = 12
	label.offset_top = 10
	label.offset_right = 900
	label.offset_bottom = 60
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 4)
	label.text = "Idle"
	hud.add_child(label)
	_own(label, root)

	var packed := PackedScene.new()
	var err := packed.pack(root)
	if err == OK:
		err = ResourceSaver.save(packed, OUT)
	print("SAVED ", OUT, " err=", err)
	root.free()
	quit(err)


func _make_state_machine(speeds: Dictionary) -> AnimationNodeStateMachine:
	var sm := AnimationNodeStateMachine.new()

	var move := AnimationNodeBlendTree.new()
	var loco := AnimationNodeBlendSpace1D.new()
	loco.min_space = 0.0
	loco.max_space = 8.0
	loco.snap = 0.01
	loco.value_label = "m/s"
	for pair in [["Idle", 0.0], ["Walk", speeds.Walk], ["Run", speeds.Run]]:
		var a := AnimationNodeAnimation.new()
		a.animation = pair[0]
		loco.add_blend_point(a, pair[1], -1, StringName(pair[0]))
	var pace := AnimationNodeTimeScale.new()
	move.add_node("Locomotion", loco, Vector2(0, 0))
	move.add_node("Pace", pace, Vector2(240, 0))
	move.connect_node("Pace", 0, "Locomotion")
	move.connect_node("output", 0, "Pace")

	var jump := AnimationNodeAnimation.new()
	jump.animation = "Jump"
	var fall := AnimationNodeAnimation.new()
	fall.animation = "Fall"

	sm.add_node("Move", move, Vector2(300, 100))
	sm.add_node("Jump", jump, Vector2(550, 0))
	sm.add_node("Fall", fall, Vector2(550, 200))

	sm.add_transition("Start", "Move", _tr(0.0, true))
	sm.add_transition("Move", "Jump", _tr(0.1))
	sm.add_transition("Move", "Fall", _tr(0.25))
	var at_end := _tr(0.15, true)
	at_end.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_AT_END
	sm.add_transition("Jump", "Fall", at_end)
	sm.add_transition("Jump", "Move", _tr(0.15))
	sm.add_transition("Fall", "Move", _tr(0.15))
	return sm


func _tr(xfade: float, auto := false) -> AnimationNodeStateMachineTransition:
	var t := AnimationNodeStateMachineTransition.new()
	t.xfade_time = xfade
	if auto:
		t.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO
	return t
