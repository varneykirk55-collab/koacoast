extends SceneTree
## Software-GL frame time at two fixed cameras. Not a gameplay FPS number.
##   xvfb-run godot --display-driver x11 --path . --script res://tools/measure_frame_time.gd

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
	var cam := Camera3D.new()
	scene.add_child(cam)
	cam.current = true
	var overlook := scene.get_node("CoastalOverlook") as Camera3D
	cam.global_transform = overlook.global_transform
	cam.fov = overlook.fov
	var overlook_ms := await _sample()
	var data = scene.get_node("Terrain3D").data
	# Midpoint of the north approach, eye height, looking along the valley.
	var eye := Vector3(60.0, 0.0, 190.0)
	var h: float = data.get_height(eye)
	cam.global_position = Vector3(eye.x, h + 1.75, eye.z)
	cam.look_at(Vector3(0.0, h + 1.2, 140.0), Vector3.UP)
	var valley_ms := await _sample()
	print("FRAME_MS overlook_avg %.2f valley_avg %.2f" % [overlook_ms, valley_ms])
	quit(0)


func _sample() -> float:
	for _i in 8:
		await RenderingServer.frame_post_draw
	var acc := 0.0
	var n := 24
	for _i in n:
		var t0 := Time.get_ticks_usec()
		await RenderingServer.frame_post_draw
		acc += float(Time.get_ticks_usec() - t0) / 1000.0
	return acc / float(n)
