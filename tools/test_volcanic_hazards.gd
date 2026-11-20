extends SceneTree

var checks := 0
var failures := 0

func _initialize() -> void:
	run.call_deferred()

func check(condition: bool, label: String) -> void:
	checks += 1
	if condition:
		print("PASS ", label)
	else:
		failures += 1
		push_error(label)

func run() -> void:
	var island := (load("res://scenes/KoaCoast.tscn") as PackedScene).instantiate()
	root.add_child(island)
	for i in 8:
		await process_frame
	var game: SurvivalSystem = island.get_node("SurvivalSystem")
	var volcano := game.volcano
	var weather := game.weather
	var vitals := game.vitals
	var water := game.water_system
	var buildings := game.buildings
	var player := weather.player
	var spawn := player.global_position
	volcano.set_physics_process(false)
	weather.set_process(false)
	vitals.set_process(false)
	game.save_system.save_path = "user://volcanic_validation.json"
	volcano.rng.seed = 678042
	check(volcano.phase == volcano.Phase.DORMANT and volcano.remaining >= 2400, "Conservative dormant interval")
	check(game.perform_save().ok and game.perform_load().ok and volcano.phase == volcano.Phase.DORMANT, "Dormant forecast round-trips")
	var windward := volcano.vent - Vector3.RIGHT * 380
	var downwind := volcano.vent + Vector3.RIGHT * 380
	player.global_position = volcano.vent + Vector3(80,0,0)
	weather.climate = Vector3(0,.86,0)
	for expected in range(1,5):
		volcano.remaining = .01
		volcano.step(.1)
		check(volcano.phase == expected, "Timed phase " + volcano.LABELS[expected])
		for i in 28:
			volcano.step(.25)
		if expected <= volcano.Phase.ESCALATION:
			check(volcano.visual.smoke.emitting and volcano.heat_at(volcano.vent) == 0, "Smoke warning precedes heat in " + volcano.LABELS[expected])
		var snapshot := volcano.serialize()
		check(game.perform_save().ok, "Saved " + volcano.LABELS[expected])
		volcano.deserialize({})
		check(game.perform_load().ok and volcano.phase == expected and is_equal_approx(volcano.remaining, float(snapshot.remaining))
			and is_equal_approx(volcano.intensity, float(snapshot.intensity)), "Reloaded phase and timing")

	volcano.begin(volcano.Phase.ERUPTION)
	volcano.elapsed = 40
	volcano.intensity = .9
	volcano.activity = 1
	volcano.step(.25)
	check(volcano.visual.cinders.emitting, "Eruption enables incandescent ejecta")
	check(volcano.ash_at(downwind,.9,0) > .30 and volcano.ash_at(windward,.9,0) == 0, "Downwind ash footprint")
	weather.wind_direction = Vector2.LEFT
	check(volcano.ash_at(windward,.9,0) > .30 and volcano.ash_at(downwind,.9,0) == 0, "Reversing wind reverses plume direction")
	weather.wind_direction = Vector2(1,.13)
	check(volcano.ash_at(downwind,.9,0) > volcano.ash_at(downwind,.04,0), "Strong wind carries ash farther")
	check(volcano.ash_at(volcano.vent,.9,.9) < volcano.ash_at(volcano.vent,.9,0), "Rain lowers airborne ash")
	var vent_index := volcano._cell(volcano.vent)
	volcano.ash[vent_index] = 0
	volcano._update_surface(15,.9,0)
	var dry_deposit := volcano.ash[vent_index]
	volcano.ash[vent_index] = 0
	volcano._update_surface(15,.9,.9)
	check(volcano.ash[vent_index] > dry_deposit * 2, "Rain accelerates deposition")
	check(volcano.heat_at(volcano.vent) > .65 and volcano.heat_at(volcano.lava) > .13 and volcano.heat_at(spawn)==0, "Heat restricted to volcanic zones")
	check(game.day_night.volcanic_haze > 0 and weather.ash_cooling > 0, "Plume feeds lighting and cold exposure")
	volcano.airborne = .90
	volcano.reset_personal()
	volcano._update_survival(35,Vector2(1,.98),spawn,false)
	var sheltered_exposure := volcano.respiratory
	volcano._update_survival(35,Vector2.ZERO,spawn,false)
	vitals.step_simulation(1,&"sprinting")
	check(sheltered_exposure == 0 and volcano.respiratory > .40 and vitals.stamina_regen_multiplier < .95
		and vitals.stamina < vitals.base_max_stamina - vitals.stamina_sprint_drain, "Sheltered respiration and outdoor stamina penalty")
	volcano.respiratory = 1
	var hp := vitals.health
	volcano._update_survival(4,Vector2.ZERO,spawn,false)
	check(vitals.health < hp and vitals.last_damage_cause == &"ash", "Prolonged ash enters centralized damage")
	weather.wetness = 1
	weather.exposure = .1
	weather.ash_cooling = 0
	weather.update_exposure(5,0,Vector2.ZERO,0,.5,80)
	var normal_cold := weather.exposure
	weather.exposure = .1
	weather.ash_cooling = .9
	weather.update_exposure(5,0,Vector2.ZERO,0,.5,80)
	check(weather.exposure > normal_cold, "Cooling adds to existing wet cold model")

	var p := volcano.vent
	var q := p + Vector3.RIGHT * 8
	water._spawn_collector("open",p,0,29.147,WaterQuality.Quality.RAINWATER,false)
	water._spawn_collector("roofed",q,0,29.147,WaterQuality.Quality.RAINWATER,false)
	buildings._spawn_loaded_piece("roof",&"roof",&"wood",q+Vector3.UP*3,0,"",false)
	for i in 50:
		water.expose_collectors(1,.9)
	check(water.get_collector("open").water_quality == WaterQuality.Quality.ASH_CONTAMINATED
		and water.get_collector("roofed").water_quality == WaterQuality.Quality.RAINWATER, "Exposed stored water contaminated, roofed supply protected")
	check(game.perform_save().ok and game.perform_load().ok and is_equal_approx(water.get_collector("open").stored_water,29.147)
		and water.get_collector("open").water_quality == WaterQuality.Quality.ASH_CONTAMINATED, "Collector volume and unsafe quality round-trip")
	var fresh := Vector3.ZERO
	for bucket: Array in water._freshwater_cells.values():
		for point: Vector3 in bucket:
			if point.y > 20 and point.distance_to(volcano.vent) < 380:
				fresh = point
				break
		if fresh != Vector3.ZERO:
			break
	var fresh_index := volcano._cell(fresh)
	volcano.contamination[fresh_index] = .8
	check(fresh != Vector3.ZERO and water.detect_water_source(fresh).get("quality") == WaterQuality.Quality.ASH_CONTAMINATED, "Freshwater queries use source cell quality")
	volcano.begin(volcano.Phase.RECOVERY)
	volcano.intensity = 0
	volcano._update_surface(volcano.water_recovery_seconds, .8, 0)
	check(water.detect_water_source(fresh).get("quality") == WaterQuality.Quality.CLEAN_FRESHWATER, "Surface water recovers")

	buildings._spawn_loaded_piece("plain",&"wall",&"wood",p+Vector3.RIGHT*3,0,"",false)
	buildings._spawn_loaded_piece("reinforced",&"wall",&"wood",p+Vector3.LEFT*3,0,"",false)
	buildings.reinforce_piece("reinforced",false)
	volcano.tremor = .95
	volcano._shake_structures()
	check(buildings._placed.plain.hp < buildings._placed.plain.max_hp
		and buildings._placed.reinforced.hp == buildings._placed.reinforced.max_hp, "Reinforcement resists severe local tremor")

	var downhill := true
	for i in range(1, volcano.path.point_count):
		downhill = downhill and volcano.path.get_point_position(i).y < volcano.path.get_point_position(i-1).y
	var channel := volcano.path.sample_baked(0)
	volcano.ash[volcano._cell(channel)] = .8
	volcano._step_mud(1,0,channel)
	check(downhill and not volcano.mud_active, "Surveyed channel descends and requires heavy rain")
	volcano._step_mud(1,.85,channel)
	check(volcano.mud_active and volcano.mud_head < 0 and not volcano.in_mud(channel), "Mudflow warning precedes arrival")
	volcano._step_mud(volcano.FLOW_WARNING,.85,channel)
	check(volcano.in_mud(channel) and not volcano.in_mud(spawn), "Moving hazard confined to channel")
	var flow_progress := volcano.mud_head
	check(game.perform_save().ok and game.perform_load().ok and is_equal_approx(volcano.mud_head, flow_progress)
		and volcano.in_mud(channel) and volcano.deposited_at(channel) > .7, "Mud and ash accumulation restore in progress")
	volcano._step_mud(100,0,channel)
	check(not volcano.mud_active and volcano.mud_cooldown > 0, "Flow recedes and cooldown applies")
	volcano.fertility[fresh_index] = .8
	check(volcano.regrowth_at(fresh)==1, "Fertility dormant during recovery")
	volcano.begin(volcano.Phase.DORMANT)
	check(volcano.regrowth_at(fresh)<1, "Post-recovery fertility shortens gather regrowth")
	player.global_position = spawn
	game.inventory.add_item(&"coconut_shell",1)
	var clean_slot := game.inventory.find_container_slot(true,false)
	game.inventory.fill_container(clean_slot,100,WaterQuality.Quality.CLEAN_FRESHWATER)
	game.inventory.add_item(&"coconut_shell",1)
	game.inventory.fill_container(game.inventory.find_container_slot(true,false),16.483,WaterQuality.Quality.ASH_CONTAMINATED)
	water.expose_collectors(30,.9)
	check(game.inventory.get_container_water(clean_slot).quality == WaterQuality.Quality.CLEAN_FRESHWATER, "Carried clean water stays safe")
	vitals.health = .1
	volcano.airborne = 1
	volcano.respiratory = 1
	volcano._update_survival(1,Vector2.ZERO,spawn,false)
	var death := game.death_recovery
	check(death.is_death_in_progress() and death.get_cache_count() > 0, "Ash death drops existing inventory cache")
	check(game.perform_save().ok and game.perform_load().ok, "Mid-death save safely restores the cache and respawns")
	var cache: Dictionary = death.get_caches()[0]
	death.recover_cache(cache.uid)
	var slot := {}
	for i in game.inventory.slots.size():
		var candidate := game.inventory.get_slot(i)
		if int(candidate.get("water_quality",0)) == WaterQuality.Quality.ASH_CONTAMINATED:
			slot = candidate
			break
	check(not vitals.is_dead and volcano.respiratory == 0 and is_equal_approx(float(slot.get("water_amount",0)),16.483)
		and int(slot.get("water_quality",0)) == WaterQuality.Quality.ASH_CONTAMINATED, "Respawn and cached container preserve quantity and quality")
	volcano.deserialize({})
	volcano.begin(volcano.Phase.ERUPTION)
	for i in 200:
		weather.climate = Vector3(0,.65,0)
		volcano.step(1)
	var natural_deposit := volcano.deposited_at(channel)
	print("Headwater accumulation: ", natural_deposit)
	volcano.begin(volcano.Phase.RECOVERY)
	weather.climate = Vector3(.95,.92,1)
	for i in 12:
		volcano.step(1)
	check(natural_deposit > .24 and volcano.mud_active, "Ordinary eruption fallout triggers mudflow in next storm")
	volcano.deserialize({})
	volcano.step(.25)
	check(not volcano.visual.smoke.emitting and not volcano.visual.cinders.emitting and not volcano.mud_active, "Reset clears volcanic effects")
	island.get_node("IslandAudio").stop_audio()
	island.queue_free()
	await process_frame
	print("Volcanic checks: %d, failures: %d" % [checks,failures])
	quit(1 if failures else 0)
