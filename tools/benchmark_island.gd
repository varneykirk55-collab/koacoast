extends SceneTree
## godot --headless --fixed-fps 60 -s tools/benchmark_island.gd
## Omit --headless and set a fixed resolution for rendering comparisons.

const CASES := [
	["coastal_day", Vector2(48,576), 0, false, false, false],
	["jungle_day", Vector2(60,190), 0, false, false, false],
	["mountain_visibility", Vector2(48,-126), 0, false, false, false],
	["jungle_rain", Vector2(60,190), 3, false, false, false],
	["night_campfire_wildlife", Vector2(60,190), 0, true, false, false],
	["eruption_ashfall", Vector2(278,-101), 0, false, true, false],
	["storm_eruption", Vector2(278,-101), 4, false, true, false],
	["rain_mudflow", Vector2(576,166), 3, false, true, true],
	["extended_normal", Vector2(60,190), 0, false, false, false],
	["extended_stress", Vector2(576,166), 4, true, true, true],
]
var island: Node3D
var game: SurvivalSystem
var ground: Terrain3D
var player: CharacterBody3D
var benchmark_failures := 0
var rendered := false

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	rendered = DisplayServer.get_name() != "headless"
	print("ENVIRONMENT ", DisplayServer.get_name(), " ", RenderingServer.get_video_adapter_name(),
		" ", OS.get_processor_name(), " ", OS.get_processor_count(), " logical CPUs")
	var frames := 360 if not rendered else 20
	var args := OS.get_cmdline_user_args()
	var normal_only := "--normal-only" in args
	var selected: Array[String] = []
	for arg in args:
		if arg.begins_with("--case="):
			selected.append(arg.trim_prefix("--case="))
	for sample: Array in CASES:
		if normal_only != (sample[0] == "extended_normal") or (not selected.is_empty() and sample[0] not in selected):
			continue
		await run_case(sample,frames)
	print("BENCHMARK failures=",benchmark_failures)
	quit(1 if benchmark_failures else 0)

func run_case(sample: Array, frames: int) -> void:
	island = load("res://scenes/KoaCoast.tscn").instantiate()
	root.add_child(island)
	game = island.get_node("SurvivalSystem")
	ground = island.get_node("Terrain3D")
	player = island.get_node("Player")
	var scenery := island.get_node("IslandScenery")
	for i in 12:
		await process_frame
	scenery.apply_quality(1)
	var weather := game.weather
	var volcano := game.volcano
	var stress: bool = String(sample[0]).begins_with("extended_")
	var point: Vector2 = sample[1]
	player.global_position = volcano.ground_point(point) + Vector3.UP * .12
	player.get_node("CameraPivot").global_position = player.global_position + Vector3.UP * 1.55
	if sample[2] > 0:
		weather.request_state(sample[2])
		weather.step(25)
	if sample[3]:
		game.day_night.set_to_phase(&"night")
		game.buildings._spawn_campfire("benchmark_fire",player.global_position + Vector3.RIGHT*3,true)
		game.buildings._spawn_loaded_piece("benchmark_wall",&"wall",&"wood",player.global_position + Vector3.RIGHT*5,0,"",false)
		game.wildlife.trigger_shelter_threat_test()
	if sample[4]:
		volcano.begin(volcano.Phase.ERUPTION)
		volcano.step(32)
	if sample[5]:
		volcano.mud_active = true
		volcano.mud_head = 32
	for i in 24 if rendered else 100:
		await process_frame
	var measurements := PackedFloat64Array()
	var peak_memory := 0.0
	var peak_objects := 0.0
	var draw_calls := 0.0
	var visible := 0.0
	var count := (7200 if not rendered else 36) if stress else frames
	var start_memory := OS.get_static_memory_usage()
	var start_nodes := get_node_count()
	var start_hunger := game.vitals.hunger
	var direction := &"move_forward"
	var traveled := 0.0
	for i in count:
		if stress and i % 75 == 0:
			Input.action_release(direction)
			direction = &"move_back" if direction == &"move_forward" else &"move_forward"
			Input.action_press(direction)
		var before := player.global_position
		var begin := Time.get_ticks_usec()
		await process_frame
		measurements.append((Time.get_ticks_usec()-begin)/1000.0)
		traveled += before.distance_to(player.global_position)
		peak_memory = maxf(peak_memory, OS.get_static_memory_usage())
		peak_objects = maxf(peak_objects, Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
		if rendered:
			draw_calls += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
			visible += Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
	Input.action_release(direction)
	var total := 0.0
	for value in measurements:
		total += value
	measurements.sort()
	print("BENCH ",JSON.stringify({"case":sample[0],"frames":count,"mean_ms":total/count,"p99_ms":measurements[ceili(count*.99)-1],
		"max_ms":measurements[-1],"average_fps":1000.0*count/total if rendered else null,
		"draw_calls":draw_calls/count if rendered else null,"visible":visible/count if rendered else null,"static_start":start_memory,"static_peak":peak_memory,
		"static_end":OS.get_static_memory_usage(),"nodes_start":start_nodes,"nodes_peak":peak_objects,
		"nodes_end":get_node_count(),"physics_objects":Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS),
		"rain_capacity":weather.rain.amount,"ash_capacity":volcano.visual.ash.amount,
		"smoke_capacity":volcano.visual.smoke.amount,"cinder_capacity":volcano.visual.cinders.amount}))
	if stress:
		game.save_system.save_path = "user://koa_performance_fixture.json"
		var stored := game.perform_save()
		var loaded := game.perform_load()
		var valid: bool = stored.ok and loaded.ok and is_finite(ground.data.get_height(player.global_position)) 			and traveled > 1.0 and game.vitals.hunger < start_hunger 			and game.get_node("TropicalWeather") == weather 			and game.get_node("VolcanicHazards") == volcano and (rendered or not volcano.mud_active)
		print("STRESS movement=", traveled, " hunger=",game.vitals.hunger," mud_finished=",not volcano.mud_active,
			" save_load=",stored.ok and loaded.ok," valid=",valid)
		benchmark_failures += int(not valid)
	island.get_node("IslandAudio").stop_audio()
	island.queue_free()
	await process_frame
	await process_frame
	print("TEARDOWN ", get_node_count(), " nodes, ", Performance.get_monitor(Performance.OBJECT_COUNT), " objects, ", OS.get_static_memory_usage(), " static bytes")
