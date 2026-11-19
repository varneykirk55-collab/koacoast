extends SceneTree
## Captures the normal view and the slope overlay. Requires a display (Xvfb is enough).
##   godot --path <project> --display-driver x11 --audio-driver Dummy --script res://tools/capture_slope_views.gd

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var scene := (load("res://scenes/KoaCoast.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	for _i in 6:
		await process_frame
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var player := scene.get_node_or_null("Player")
	if player:
		player.set_process(false)
		player.set_physics_process(false)
		player.set_process_unhandled_input(false)
	var overlook := scene.get_node_or_null("CoastalOverlook") as Camera3D
	if overlook:
		overlook.current = true
	var overlay = scene.get_node_or_null("SlopeAnalysis")
	if overlay == null:
		push_error("Capture: SlopeAnalysis node missing.")
		quit(1)
		return
	overlay.show_overlay = false
	await _settle()
	_save("res://docs/slope_overlay_off.png")
	overlay.view_mode = 0
	overlay.show_overlay = true
	await _settle()
	_save("res://docs/slope_overlay_on.png")
	overlay.view_mode = 2
	overlay.set_top_down(true)
	var plants := scene.get_node_or_null("IslandVegetation")
	if plants:
		plants.visible = false
	await _settle()
	_save("res://docs/slope_overlay_topdown.png")
	print("CAPTURE_OK")
	quit(0)


func _settle() -> void:
	for _i in 4:
		await RenderingServer.frame_post_draw


func _save(res_path: String) -> void:
	var image := root.get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path(res_path)
	var err := image.save_png(path)
	print("SHOT ", path, " ", image.get_width(), "x", image.get_height(), " err=", err)
