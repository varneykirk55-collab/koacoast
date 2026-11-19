extends SceneTree
## Same-camera shots of the three valleys, a coastal plain, and the overlook.

const SHOTS := [
	["north_valley", Vector3(70.0, 0.0, 200.0), Vector3(-10.0, 0.0, 150.0)],
	["east_valley", Vector3(560.0, 0.0, 10.0), Vector3(420.0, 0.0, -20.0)],
	["south_valley", Vector3(-220.0, 0.0, -530.0), Vector3(-120.0, 0.0, -470.0)],
	["coastal_plain", Vector3(-280.0, 0.0, 420.0), Vector3(-80.0, 0.0, 280.0)],
]


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var scene := (load("res://scenes/KoaCoast.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	for _i in 8:
		await process_frame
	var player := scene.get_node_or_null("Player")
	if player:
		player.set_process(false)
		player.set_physics_process(false)
		player.set_process_unhandled_input(false)
	var data = scene.get_node("Terrain3D").data
	var cam := Camera3D.new()
	scene.add_child(cam)
	cam.current = true
	cam.fov = 60.0
	for shot in SHOTS:
		var eye: Vector3 = shot[1]
		var look: Vector3 = shot[2]
		var h: float = data.get_height(eye)
		var lh: float = data.get_height(look)
		cam.global_position = Vector3(eye.x, h + 1.7, eye.z)
		cam.look_at(Vector3(look.x, lh + 1.4, look.z), Vector3.UP)
		await _save("res://docs/lush_%s.png" % str(shot[0]))
	var overlook := scene.get_node("CoastalOverlook") as Camera3D
	cam.global_transform = overlook.global_transform
	cam.fov = overlook.fov
	await _save("res://docs/lush_overview.png")
	print("LUSH_SHOTS_OK")
	quit(0)


func _save(res_path: String) -> void:
	for _i in 3:
		await RenderingServer.frame_post_draw
	var image := root.get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path(res_path)
	var err := image.save_png(path)
	print("SHOT ", path, " ", image.get_width(), "x", image.get_height(), " err=", err)
