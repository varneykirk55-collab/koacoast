extends SceneTree
## Renders the shoreline from the third-person camera.
## Usage: godot --path . --script res://tools/capture_shore.gd -- --out /tmp/shore_shots/before

var _out := "/tmp/shore_shots"
var _frames := 0
var _shot := 0
var _player: CharacterBody3D
var _shots: Array = []


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(_out)
	var scene := (load("res://scenes/KoaCoast.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	_player = scene.get_node("Player")
	_player.get_node("HUD").visible = false
	# Viewpoints on the unchanged beach near (-80, 1.2, 608). Sea is toward (-0.38, 0.92).
	var look_sea := 2.748
	var look_inland := look_sea + PI
	var look_along := look_sea + PI * 0.5
	_shots = [
		{"name": "01_black_sand", "pos": Vector3(-78.0, 4.0, 604.0), "yaw": look_sea, "pitch": -0.72},
		{"name": "02_wet_band", "pos": Vector3(-82.5, 4.0, 614.0), "yaw": look_sea, "pitch": -0.42},
		{"name": "03_transition", "pos": Vector3(-86.0, 4.0, 618.0), "yaw": look_inland, "pitch": -0.28},
		{"name": "04_foam", "pos": Vector3(-83.0, 4.0, 612.0), "yaw": look_along, "pitch": -0.22},
	]


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 8:
		return false
	if _shot >= _shots.size():
		quit(0)
		return true
	var spec: Dictionary = _shots[_shot]
	var hold := 8 + _shot * 12
	if _frames == hold:
		_player.global_position = spec.pos
		_player.velocity = Vector3.ZERO
		_player.get_node("CameraPivot").rotation = Vector3(0.0, spec.yaw, 0.0)
		_player.get_node("CameraPivot/SpringArm3D").rotation = Vector3(spec.pitch, 0.0, 0.0)
	if _frames == hold + 10:
		var img := root.get_viewport().get_texture().get_image()
		var path := _out.path_join(str(spec.name) + ".png")
		var err := img.save_png(path)
		print("SHOT ", spec.name, " ", img.get_width(), "x", img.get_height(), " err ", err, " player ", _player.global_position, " floor ", _player.is_on_floor())
		_shot += 1
	if _frames > 200:
		push_error("capture timed out")
		quit(1)
		return true
	return false
