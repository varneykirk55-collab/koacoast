extends SceneTree
## Run with godot --headless -s tools/test_tropical_weather.gd

var failures := 0
var checks := 0

func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(label)
	else:
		print("PASS ", label)

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var scene := (load("res://scenes/KoaCoast.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	for i in 8:
		await process_frame
	var game: SurvivalSystem = scene.get_node("SurvivalSystem")
	var w := game.weather
	var v := game.vitals
	var b := game.buildings
	var water := game.water_system
	var clock := game.day_night
	var audio = scene.get_node("IslandAudio")
	var terrain: Terrain3D = scene.get_node("Terrain3D")
	var p := w.player.global_position
	game.save_system.save_path = "user://weather_suite.json"
	for state in 5:
		var previous := w.climate
		w.request_state(state)
		w.step(.1)
		check(w.climate.distance_to(previous)<.01, "Smooth onset " + w.LABELS[state])
		w.step(25)
		check(w.transition == 1 and w.climate.distance_to(w.CLIMATE[state]) < .15, "Reached " + w.LABELS[state])
	clock.set_to_phase(&"day")
	var sunlight := clock._sun.light_energy
	clock.set_to_phase(&"night")
	check(clock.night_factor > .6 and clock._sun.light_energy < sunlight, "Storm respects day and night")
	water._spawn_collector("test", p+Vector3.RIGHT*18, 0, 0, WaterQuality.Quality.RAINWATER,false)
	var collector := water.get_collector("test")
	w.request_state(w.State.LIGHT_RAIN)
	w.step(30)
	water._process(1.0)
	var light := float(collector.stored_water)
	w.request_state(w.State.HEAVY_RAIN)
	w.step(30)
	water._process(1.0)
	check(light > 0 and collector.stored_water - light > 2*light, "Collector scales with rainfall")
	water._process(9999)
	check(collector.stored_water == water.collector_capacity and WaterQuality.is_safe(collector.water_quality), "Collector capacity and water quality")
	w.request_state(w.State.CLEAR)
	w.step(25)
	collector.stored_water = 17
	water._process(4)
	check(collector.stored_water == 17, "Dry collector stops filling")

	w.request_state(w.State.TROPICAL_STORM)
	w.step(25)
	w.reset_exposure()
	w.step(12)
	check(w.wetness > .1 and w.rain.emitting, "Exposed rain wets player and emits drops")
	b._spawn_loaded_piece("roof_test",&"roof",&"wood",p+Vector3.UP*3,PI/2,"",false)
	b._spawn_loaded_piece("wall_test",&"wall",&"wood",p+Vector3.FORWARD*2,0,"",false)
	var open_wall := b.weather_cover(p).y
	b.reinforce_piece("wall_test",false)
	check(b.weather_cover(p).y > open_wall, "Reinforcement improves wind shelter")
	var soaked := w.wetness
	w.step(8)
	check(w.roofed and not w.rain.visible and w.wetness < soaked, "Roof blocks rain and accelerates drying")
	b._spawn_campfire("inside",p,true)
	b._spawn_campfire("outside",p+Vector3.RIGHT*10,true)
	w.exposure = .65
	w.wetness = .9
	for i in 60:
		w.step(1)
	check(b._campfires.inside.lit and not b._campfires.outside.lit, "Only exposed fire extinguishes after sustained rain")
	check(w.exposure < .05 and w.wetness < .1, "Prepared player recovers in storm by sheltered fire")
	audio._process(.5)
	check(audio.bed.rain_roof.volume_db > -60 and audio.thunderstorm, "Roof patter and storm audio linked to location")
	audio.thunder_timer = 0
	audio._process(.01)
	check(audio.thunder.playing and audio.thunder.global_position.distance_to(p) > 22, "Thunder plays at distance")
	w.wetness = 1
	w.exposure = .1
	w.climate = Vector3(.8,.1,.7)
	w.update_exposure(4,0,Vector2.ZERO,0,0,20)
	var day_exposure := w.exposure
	w.exposure = .1
	w.climate.y = 1
	w.update_exposure(4,0,Vector2.ZERO,0,1,300)
	check(w.exposure > day_exposure, "Wind, night and altitude compound chilling")
	w.exposure = .95
	var hp := v.health
	w.update_exposure(4,0,Vector2.ZERO,0,1,300)
	v.step_simulation(1,&"sprinting")
	check(v.health < hp and v.last_damage_cause == &"exposure", "Severe cold uses centralized damage")
	check(v.stamina_regen_multiplier < .7 and v.move_speed_multiplier < .9 and v.stamina < v.base_max_stamina-v.stamina_sprint_drain, "Cold affects regeneration, movement and sprint cost")
	w.reset_exposure()
	w.climate = w.CLIMATE[w.State.CLEAR]
	w.player.global_position = Vector3(950,-1,850)
	w.request_state(w.State.CLEAR)
	w.step(30)
	check(w.wetness > .5, "Deep ocean water soaks player in clear weather")
	w.player.global_position = p
	var valid := true
	for i in w.BASINS.size():
		var center := w.basins[i].position
		for edge in range(-12,13):
			for off in [Vector3(edge,0,12),Vector3(edge,0,-12),Vector3(12,0,edge),Vector3(-12,0,edge)]:
				valid = valid and terrain.data.get_height(center+off) > w.bottoms[i]+w.MAX_DEPTH
	check(valid, "All four flood footprints contained by actual terrain rims")
	var basin := w.basins[0].position
	basin.y = w.bottoms[0]
	b._spawn_loaded_piece("low_foundation",&"foundation",&"wood",basin,0,"",false)
	w.storage = 0
	w.request_state(w.State.TROPICAL_STORM)
	for i in 120:
		w.step(1)
	check(w.flood_depth(basin) > .9 and w.flood_depth(basin+Vector3.RIGHT*20)==0 and w.basins[0].visible, "Sustained runoff floods low ground only")
	check(b._placed.low_foundation.hp < b._placed.low_foundation.max_hp, "Submerged wood structure takes damage")
	w.request_state(w.State.HEAVY_RAIN)
	w.step(4)
	var saved := w.serialize()
	check(game.perform_save().ok, "Save during transition")
	w.deserialize({})
	var loaded := bool(game.perform_load().ok)
	var restored := w.serialize()
	var equivalent: bool = loaded and saved.state == restored.state and saved.rng == restored.rng
	for key in ["remaining", "elapsed", "transition", "wetness", "exposure", "storage"]:
		equivalent = equivalent and is_equal_approx(saved[key], restored[key])
	for key in ["origin", "climate"]:
		for component in 3:
			equivalent = equivalent and is_equal_approx(saved[key][component], restored[key][component])
	check(equivalent, "File round trip preserves weather, transition, storm timing, exposure and flood")
	check(not b._campfires.outside.lit and b._campfires.inside.lit and water.get_collector("test").stored_water==17, "Campfires and collector survive reload")
	w.request_state(w.State.CLEAR)
	for i in 170:
		w.step(1)
	check(w.storage == 0 and not w.basins[0].visible, "Flood drains after rainfall")
	w.deserialize({})
	check(w.state == w.State.CLEAR and w.wetness == 0 and w.exposure == 0, "Legacy default and new-game climate")
	w.probabilities = PackedFloat32Array([0,0,0,0,1])
	w.remaining = .01
	w.step(.2)
	check(w.state == w.State.TROPICAL_STORM and w.remaining >= w.minimum_seconds[4], "Automatic weighted forecast and configured duration")
	w.step(25)
	v.health = 1
	w.exposure = 1
	w.wetness = 1
	w.update_exposure(2,0,Vector2.ZERO,0,1,300)
	check(v.is_dead and game.death_recovery.is_death_in_progress(), "Cold death enters existing recovery sequence")
	var recovery := game.death_recovery.complete_respawn_now()
	check(recovery.ok and not v.is_dead and w.wetness == 0 and w.exposure == 0, "Respawn clears personal exposure and retains active storm")
	var start := Time.get_ticks_usec()
	for i in 500:
		w.step(.2)
	print("Weather tick mean (scene fixture): %.1f microseconds" % ((Time.get_ticks_usec()-start)/500.0))
	audio.stop_audio()
	scene.queue_free()
	await process_frame
	print("Weather checks: %d, failures: %d" % [checks,failures])
	quit(1 if failures else 0)
