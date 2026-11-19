class_name KekoaAnimTools
extends RefCounted
## Helpers that turn a Mixamo clip into a clip Kekoa can play.
##
## - Clips downloaded on Kekoa himself are only cleaned up (in place, scaled, looped).
## - Clips from a different Mixamo character are retargeted bone by bone in
##   global space so limbs point the same way, then cleaned up the same way.

const HIPS := "mixamorig_Hips"
const SAMPLE_FPS := 30.0

## Preferred child used to find the direction a bone points.
const AIM_CHILD := {
	"mixamorig_Spine": "mixamorig_Spine1",
	"mixamorig_Spine1": "mixamorig_Spine2",
	"mixamorig_Spine2": "mixamorig_Neck",
	"mixamorig_Neck": "mixamorig_Head",
	"mixamorig_Head": "mixamorig_HeadTop_End",
	"mixamorig_LeftShoulder": "mixamorig_LeftArm",
	"mixamorig_LeftArm": "mixamorig_LeftForeArm",
	"mixamorig_LeftForeArm": "mixamorig_LeftHand",
	"mixamorig_LeftHand": "mixamorig_LeftHandMiddle1",
	"mixamorig_RightShoulder": "mixamorig_RightArm",
	"mixamorig_RightArm": "mixamorig_RightForeArm",
	"mixamorig_RightForeArm": "mixamorig_RightHand",
	"mixamorig_RightHand": "mixamorig_RightHandMiddle1",
	"mixamorig_LeftUpLeg": "mixamorig_LeftLeg",
	"mixamorig_LeftLeg": "mixamorig_LeftFoot",
	"mixamorig_LeftFoot": "mixamorig_LeftToeBase",
	"mixamorig_LeftToeBase": "mixamorig_LeftToe_End",
	"mixamorig_RightUpLeg": "mixamorig_RightLeg",
	"mixamorig_RightLeg": "mixamorig_RightFoot",
	"mixamorig_RightFoot": "mixamorig_RightToeBase",
	"mixamorig_RightToeBase": "mixamorig_RightToe_End",
}


## Returns the first Skeleton3D and first Animation found in an imported Mixamo scene.
static func read_scene(scene: PackedScene) -> Dictionary:
	var root := scene.instantiate()
	var out := {"skeleton": null, "animation": null, "root": root}
	var skels := root.find_children("*", "Skeleton3D", true, false)
	if skels.size() > 0:
		out.skeleton = skels[0]
	for ap in root.find_children("*", "AnimationPlayer", true, false):
		for lib_name in ap.get_animation_library_list():
			var lib: AnimationLibrary = ap.get_animation_library(lib_name)
			for anim_name in lib.get_animation_list():
				if anim_name == "RESET":
					continue
				out.animation = lib.get_animation(anim_name)
				return out
	return out


static func _bone_of(path: NodePath) -> String:
	return String(path.get_concatenated_subnames())


static func _same_rest(a: Skeleton3D, b: Skeleton3D) -> bool:
	for i in b.get_bone_count():
		var j := a.find_bone(b.get_bone_name(i))
		if j < 0:
			continue
		var qa := a.get_bone_rest(j).basis.get_rotation_quaternion()
		var qb := b.get_bone_rest(i).basis.get_rotation_quaternion()
		if qa.angle_to(qb) > deg_to_rad(0.5):
			return false
	return true


static func _global_rest_rot(s: Skeleton3D, bone: int) -> Quaternion:
	return s.get_bone_global_rest(bone).basis.get_rotation_quaternion()


static func _aim_dir(s: Skeleton3D, bone: int) -> Vector3:
	var name := s.get_bone_name(bone)
	if not AIM_CHILD.has(name):
		return Vector3.ZERO
	var child := s.find_bone(AIM_CHILD[name])
	if child < 0:
		return Vector3.ZERO
	var d := s.get_bone_global_rest(child).origin - s.get_bone_global_rest(bone).origin
	return d.normalized() if d.length() > 1e-9 else Vector3.ZERO


## Converts `src_anim` (made for `src`) into a clip for `dst`.
## loop: loop the clip. in_place: lock the hips' horizontal position.
## lock_height: also hold the hips at their starting height (for jumps, where
## the physics body already does the rising and falling).
static func convert(src_anim: Animation, src: Skeleton3D, dst: Skeleton3D, loop: bool, in_place := true, lock_height := false) -> Animation:
	var skel_path := "Skeleton3D"
	var length := src_anim.length
	var src_hips := src.find_bone(HIPS)
	var dst_hips := dst.find_bone(HIPS)
	var height_ratio := dst.get_bone_global_rest(dst_hips).origin.y / maxf(src.get_bone_global_rest(src_hips).origin.y, 1e-9)
	var rest_xz := dst.get_bone_rest(dst_hips).origin

	# Source tracks by bone name.
	var rot_tracks := {}
	var pos_track := -1
	for t in src_anim.get_track_count():
		var bone := _bone_of(src_anim.track_get_path(t))
		match src_anim.track_get_type(t):
			Animation.TYPE_ROTATION_3D:
				rot_tracks[bone] = t
			Animation.TYPE_POSITION_3D:
				if bone == HIPS:
					pos_track = t

	var out := Animation.new()
	out.length = length
	out.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
	var frames := maxi(2, int(round(length * SAMPLE_FPS)) + 1)
	var direct := _same_rest(src, dst)

	# Per-bone correction for retargeting: rotate dst rest aim onto src rest aim.
	var corr := {}
	var order: Array[int] = []  # dst bones present in the clip, parents first
	for i in dst.get_bone_count():
		var n := dst.get_bone_name(i)
		if rot_tracks.has(n) and src.find_bone(n) >= 0:
			order.append(i)
			if not direct:
				var si := src.find_bone(n)
				var a := Quaternion.IDENTITY
				var ds := _aim_dir(src, si)
				var dt := _aim_dir(dst, i)
				if ds != Vector3.ZERO and dt != Vector3.ZERO and n != HIPS:
					a = Quaternion(dt, ds)
				corr[i] = _global_rest_rot(src, si).inverse() * a * _global_rest_rot(dst, i)

	var out_tracks := {}
	for i in order:
		var t := out.add_track(Animation.TYPE_ROTATION_3D)
		out.track_set_path(t, NodePath("%s:%s" % [skel_path, dst.get_bone_name(i)]))
		out.track_set_interpolation_type(t, Animation.INTERPOLATION_LINEAR)
		out_tracks[i] = t

	for f in frames:
		var time := minf(length, f / SAMPLE_FPS) if f < frames - 1 else length
		# Source global rotations for this frame.
		var src_glob := {}
		for si in src.get_bone_count():
			var n := src.get_bone_name(si)
			var local: Quaternion
			if rot_tracks.has(n):
				local = src_anim.rotation_track_interpolate(rot_tracks[n], time)
			else:
				local = src.get_bone_rest(si).basis.get_rotation_quaternion()
			var p := src.get_bone_parent(si)
			src_glob[si] = (src_glob[p] * local) if p >= 0 else local
		var dst_glob := {}
		for i in order:
			var n := dst.get_bone_name(i)
			var si := src.find_bone(n)
			var local_q: Quaternion
			if direct:
				local_q = src_anim.rotation_track_interpolate(rot_tracks[n], time)
			else:
				var g: Quaternion = src_glob[si] * corr[i]
				dst_glob[i] = g
				var p := dst.get_bone_parent(i)
				var parent_g := Quaternion.IDENTITY
				if p >= 0:
					parent_g = dst_glob.get(p, _parent_global_rest_chain(dst, p, dst_glob))
				local_q = (parent_g.inverse() * g).normalized()
			out.rotation_track_insert_key(out_tracks[i], time, local_q)

	if pos_track >= 0:
		var t := out.add_track(Animation.TYPE_POSITION_3D)
		out.track_set_path(t, NodePath("%s:%s" % [skel_path, HIPS]))
		var start_y: float = src_anim.position_track_interpolate(pos_track, 0.0).y * height_ratio
		for f in frames:
			var time := minf(length, f / SAMPLE_FPS) if f < frames - 1 else length
			var v: Vector3 = src_anim.position_track_interpolate(pos_track, time) * height_ratio
			if lock_height:
				v.y = start_y
			if in_place:
				v.x = rest_xz.x
				v.z = rest_xz.z
			out.position_track_insert_key(t, time, v)
	return out


## Global rest rotation of a bone, using already-posed ancestors where known.
static func _parent_global_rest_chain(s: Skeleton3D, bone: int, posed: Dictionary) -> Quaternion:
	if posed.has(bone):
		return posed[bone]
	var p := s.get_bone_parent(bone)
	var local := s.get_bone_rest(bone).basis.get_rotation_quaternion()
	return (_parent_global_rest_chain(s, p, posed) * local) if p >= 0 else local


## Speed (m/s, in skeleton units) the clip's planted feet slide backward.
## Works on in-place clips; returns 0 if it can't tell.
static func estimate_ground_speed(anim: Animation, s: Skeleton3D) -> float:
	var feet := [s.find_bone("mixamorig_LeftToeBase"), s.find_bone("mixamorig_RightToeBase")]
	var tracks := {}
	for t in anim.get_track_count():
		tracks["%s|%d" % [_bone_of(anim.track_get_path(t)), anim.track_get_type(t)]] = t
	var steps := maxi(2, int(anim.length * 60.0))
	var dt := anim.length / steps
	var samples := {feet[0]: [], feet[1]: []}
	for f in steps + 1:
		var time := dt * f
		var glob := {}
		for b in s.get_bone_count():
			var n := s.get_bone_name(b)
			var tr := s.get_bone_rest(b)
			var rk := "%s|%d" % [n, Animation.TYPE_ROTATION_3D]
			var pk := "%s|%d" % [n, Animation.TYPE_POSITION_3D]
			if tracks.has(rk):
				tr.basis = Basis(anim.rotation_track_interpolate(tracks[rk], time))
			if tracks.has(pk):
				tr.origin = anim.position_track_interpolate(tracks[pk], time)
			var p := s.get_bone_parent(b)
			glob[b] = (glob[p] * tr) if p >= 0 else tr
		for foot in feet:
			samples[foot].append(glob[foot].origin)
	var speeds: Array[float] = []
	var leg := s.get_bone_global_rest(s.find_bone(HIPS)).origin.y
	for foot in feet:
		var pts: Array = samples[foot]
		var min_y := INF
		for v in pts:
			min_y = minf(min_y, v.y)
		for i in range(1, pts.size()):
			if pts[i].y < min_y + leg * 0.03 and pts[i - 1].y < min_y + leg * 0.03:
				speeds.append(-(pts[i].z - pts[i - 1].z) / dt)
	if speeds.is_empty():
		return 0.0
	speeds.sort()
	return speeds[speeds.size() / 2]
