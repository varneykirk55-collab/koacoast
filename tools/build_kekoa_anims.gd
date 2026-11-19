extends SceneTree
## Bakes Kekoa's animation library from Mixamo FBX clips.
## Godot --headless --path . --script res://tools/build_kekoa_anims.gd -- --donors=res://player/kekoa/donor_clips
##
## Walk comes from Kekoa's own Mixamo export (player/kekoa/Kekoa.fbx).
## Run and Jump are retargeted from Mixamo clips the owner downloaded earlier
## on another character; Idle and Fall are built from those poses.
## Real Idle/Walk/Run/Jump FBX files dropped in player/kekoa/animations/
## replace these at runtime (see KekoaPlayer.gd).

const OUT := "res://player/kekoa/anims/KekoaAnims.tres"
var _donors := "res://player/kekoa/donor_clips"


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--donors="):
			_donors = arg.trim_prefix("--donors=")
	var kekoa := KekoaAnimTools.read_scene(load("res://player/kekoa/Kekoa.fbx"))
	var skel: Skeleton3D = kekoa.skeleton
	var lib := AnimationLibrary.new()

	var walk := KekoaAnimTools.convert(kekoa.animation, skel, skel, true)
	lib.add_animation("Walk", walk)

	var run_src := KekoaAnimTools.read_scene(load(_donors.path_join("FastRun.fbx")))
	var run := KekoaAnimTools.convert(run_src.animation, run_src.skeleton, skel, true)
	lib.add_animation("Run", run)

	var jump_src := KekoaAnimTools.read_scene(load(_donors.path_join("RunningJump.fbx")))
	var jump_full := KekoaAnimTools.convert(jump_src.animation, jump_src.skeleton, skel, false, true, true)
	# The clip leaves the ground at 0 s and peaks around 0.35 s. Physics does the
	# rising and falling, so Jump is take-off to apex and Fall holds the apex pose.
	lib.add_animation("Jump", _slice(jump_full, 0.0, 0.38, false))
	lib.add_animation("Fall", _slice(jump_full, 0.38, 0.40, true))

	var idle := _make_idle(walk, skel)
	lib.add_animation("Idle", idle)
	# Donor clips have no finger tracks: hold Kekoa's relaxed hands from Idle.
	for n in ["Run", "Jump", "Fall"]:
		_fill_missing(lib.get_animation(n), idle)

	var speeds := {}
	for n in ["Walk", "Run"]:
		speeds[n] = snappedf(KekoaAnimTools.estimate_ground_speed(lib.get_animation(n), skel), 0.01)
	lib.set_meta("ground_speed", speeds)
	print("GROUND_SPEED ", speeds)
	for n in lib.get_animation_list():
		var a := lib.get_animation(n)
		print("CLIP ", n, " len=", snappedf(a.length, 0.001), " tracks=", a.get_track_count(), " loop=", a.loop_mode)
	DirAccess.make_dir_recursive_absolute(OUT.get_base_dir())
	var err := ResourceSaver.save(lib, OUT)
	print("SAVED ", OUT, " err=", err)
	for src in [kekoa, run_src, jump_src]:
		src.root.free()
	quit(err)


## Adds constant tracks (first Idle key) for bones the clip doesn't animate.
func _fill_missing(anim: Animation, base: Animation) -> void:
	for t in base.get_track_count():
		if base.track_get_type(t) != Animation.TYPE_ROTATION_3D:
			continue
		var path := base.track_get_path(t)
		if anim.find_track(path, Animation.TYPE_ROTATION_3D) >= 0:
			continue
		var nt := anim.add_track(Animation.TYPE_ROTATION_3D)
		anim.track_set_path(nt, path)
		anim.rotation_track_insert_key(nt, 0.0, base.rotation_track_interpolate(t, 0.0))


## Copies [from, to] seconds of a clip into a new clip starting at 0.
func _slice(src: Animation, from: float, to: float, loop: bool) -> Animation:
	var out := Animation.new()
	out.length = to - from
	out.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
	var steps := maxi(2, int(round(out.length * 30.0)) + 1)
	for t in src.get_track_count():
		var nt := out.add_track(src.track_get_type(t))
		out.track_set_path(nt, src.track_get_path(t))
		for i in steps:
			var local := out.length * i / (steps - 1)
			if src.track_get_type(t) == Animation.TYPE_ROTATION_3D:
				out.rotation_track_insert_key(nt, local, src.rotation_track_interpolate(t, from + local))
			else:
				out.position_track_insert_key(nt, local, src.position_track_interpolate(t, from + local))
	return out


## Calm standing loop: legs from the rest stance, upper body averaged from the
## walk cycle (arms hang naturally), plus a slow breath in the chest.
func _make_idle(walk: Animation, skel: Skeleton3D) -> Animation:
	var out := Animation.new()
	out.length = 3.0
	out.loop_mode = Animation.LOOP_LINEAR
	var legs := ["UpLeg", "Leg", "Foot", "ToeBase", "Toe_End"]
	for t in walk.get_track_count():
		var bone := String(walk.track_get_path(t).get_concatenated_subnames())
		var nt := out.add_track(walk.track_get_type(t))
		out.track_set_path(nt, walk.track_get_path(t))
		var bi := skel.find_bone(bone)
		if walk.track_get_type(t) == Animation.TYPE_POSITION_3D:
			var p := skel.get_bone_rest(bi).origin
			out.position_track_insert_key(nt, 0.0, p)
			out.position_track_insert_key(nt, 1.5, p + Vector3(0, -0.004, 0))
			out.position_track_insert_key(nt, 3.0, p)
			continue
		var is_leg := false
		for l in legs:
			if bone.ends_with("Left" + l) or bone.ends_with("Right" + l):
				is_leg = true
		var q: Quaternion
		if is_leg:
			q = skel.get_bone_rest(bi).basis.get_rotation_quaternion()
		else:
			# Average the walk cycle for this bone.
			q = walk.rotation_track_interpolate(t, 0.0)
			var n := 24
			for i in range(1, n):
				var qi := walk.rotation_track_interpolate(t, walk.length * i / n)
				if q.dot(qi) < 0.0:
					qi = -qi
				q = q.slerp(qi, 1.0 / float(i + 1))
		var breath := Quaternion.IDENTITY
		if bone.ends_with("Spine1") or bone.ends_with("Spine2"):
			breath = Quaternion(Vector3.RIGHT, deg_to_rad(-1.2))
		out.rotation_track_insert_key(nt, 0.0, q)
		out.rotation_track_insert_key(nt, 1.5, q * breath)
		out.rotation_track_insert_key(nt, 3.0, q)
	return out
