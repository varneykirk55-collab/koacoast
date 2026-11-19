extends SceneTree
## Headless entry point:
##   godot --headless --path <project> --script res://tools/reshape_terrain_cli.gd
## Prints the chosen spawn as "SPAWN x y z".

const Reshaper := preload("res://tools/terrain_reshaper.gd")


func _initialize() -> void:
	_go.call_deferred()


func _go() -> void:
	if Reshaper.already_ran() and not "--dry" in OS.get_cmdline_user_args():
		push_error("Terrain already reshaped (delete res://tools/.terrain_reshaped to rerun).")
		quit(1)
		return
	var scene: Node = (load(Reshaper.SCENE_PATH) as PackedScene).instantiate()
	root.add_child(scene)
	for i in 3:
		await process_frame
	var terrain := scene.get_node("Terrain3D")
	var r := Reshaper.new()
	r.dry_run = "--dry" in OS.get_cmdline_user_args()
	if r.dry_run:
		r.reshape(terrain)
		quit(0)
		return
	r.backup()
	var result: Dictionary = r.reshape(terrain)
	if result.is_empty():
		quit(1)
		return
	r.update_foliage()
	var s: Vector3 = result.spawn
	print("SPAWN %.2f %.2f %.2f" % [s.x, s.y, s.z])
	scene.queue_free()
	await process_frame
	quit(0)
