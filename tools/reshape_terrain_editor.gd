@tool
extends EditorScript
## Run once from the Godot editor: open this file in the Script editor and use
## File > Run (Ctrl+Shift+X). It backs up the terrain, reshapes it, re-seats the
## foliage, moves the Player to flat coastal ground, saves, and reloads the scene.

const Reshaper := preload("res://tools/terrain_reshaper.gd")


func _run() -> void:
	if Reshaper.already_ran():
		push_error("Terrain was already reshaped. Delete res://tools/.terrain_reshaped to run again (restore a backup first to avoid double-smoothing).")
		return
	var root := EditorInterface.get_edited_scene_root()
	if root == null or root.scene_file_path != Reshaper.SCENE_PATH:
		EditorInterface.open_scene_from_path(Reshaper.SCENE_PATH)
		root = EditorInterface.get_edited_scene_root()
	var terrain: Node = root.get_node_or_null("Terrain3D") if root else null
	if terrain == null:
		push_error("Could not find Terrain3D in " + Reshaper.SCENE_PATH)
		return

	var r := Reshaper.new()
	r.backup()
	var result: Dictionary = r.reshape(terrain)
	if result.is_empty():
		return
	r.update_foliage()

	var player := root.get_node_or_null("Player") as Node3D
	if player and result.spawn != Vector3.ZERO:
		player.position = result.spawn
	EditorInterface.mark_scene_as_unsaved()
	EditorInterface.save_scene()
	EditorInterface.get_resource_filesystem().scan()
	EditorInterface.reload_scene_from_path(Reshaper.SCENE_PATH)
	print("Terrain reshape complete. ", result.stats)
