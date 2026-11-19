extends SceneTree
## Walks the third-person camera along the beach and writes numbered frames.
## Godot --path . --script res://tools/capture_walk.gd -- --out=/tmp/shore_walk

var _out := "/tmp/shore_walk"
var _frames := 0
var _player: CharacterBody3D
var _data
var _saved := 0
const FRAME_COUNT := 48


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(_out)
	var scene := (load("res://scenes/KoaCoast.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	_player = scene.get_node("Player")
	_player.get_node("HUD").visible = false
	_data = scene.get_node("Terrain3D").data


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 14:
		return false
	if _saved >= FRAME_COUNT:
		print("WALK_FRAMES ", _saved)
		quit(0)
		return true
	var along := Vector3(-0.9238795, 0.0, -0.3826834)
	var inland := Vector3(0.3826834, 0.0, -0.9238795)
	var p := Vector3(-72.0, 0.0, 606.0) + along * float(_saved) * 0.55
	for _i in 5:
		var h: float = _data.get_height(p)
		if is_nan(h):
			break
		if h < 1.15:
			p += inland * 1.2
		elif h > 2.05:
			p -= inland * 1.2
		else:
			p.y = h
			break
		p.y = h
	_player.global_position = p
	_player.velocity = Vector3.ZERO
	# Look along the shore, slightly down, so the wet edge and the water stay in frame.
	_player.get_node("CameraPivot").rotation = Vector3(0.0, 2.748 + PI * 0.5, 0.0)
	_player.get_node("CameraPivot/SpringArm3D").rotation = Vector3(-0.38, 0.0, 0.0)
	if _frames >= 16 + _saved * 2:
		var img := root.get_viewport().get_texture().get_image()
		var path := _out.path_join("frame_%03d.png" % _saved)
		img.save_png(path)
		if _saved == 0 or _saved == FRAME_COUNT - 1:
			print("FRAME ", _saved, " pos ", p, " floor ", _player.is_on_floor())
		_saved += 1
	if _frames > 400:
		push_error("walk capture timed out at %d" % _saved)
		quit(1)
		return true
	return false
