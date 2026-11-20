extends SceneTree
## godot --headless --fixed-fps 60 -s tools/benchmark_hotspots.gd

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var scene := (load("res://scenes/KoaCoast.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	for i in 8:
		await process_frame
	var game: SurvivalSystem = scene.get_node("SurvivalSystem")
	var audio := scene.get_node("IslandAudio")
	var loop := 3000
	var points := PackedVector3Array()
	for i in loop:
		var x := fposmod(i * 73, 1200) - 600
		var z := fposmod(i * 119, 1250) - 625
		points.append(Vector3(x,0,z))
	var start := Time.get_ticks_usec()
	for point in points:
		audio._update_zone(point)
	print("AUDIO_ZONE_US ", float(Time.get_ticks_usec()-start)/loop)
	var weather := game.weather
	weather.climate = Vector3.ZERO
	start = Time.get_ticks_usec()
	for point in points:
		weather._present(point)
	print("CLEAR_PRESENT_US ", float(Time.get_ticks_usec()-start)/loop)
	var volcano := game.volcano
	volcano.intensity = .9
	start = Time.get_ticks_usec()
	for i in 280:
		volcano._update_surface(1,.9,.8)
	print("ASH_DEPOSIT_US ", float(Time.get_ticks_usec()-start)/280)
	audio.stop_audio()
	scene.queue_free()
	await process_frame
	await create_timer(.03).timeout
	quit()
