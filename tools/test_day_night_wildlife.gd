extends SceneTree
## Headless integration test for NEON Prompt 2: Day-Night Cycle & Nocturnal Wildlife.
## Verifies timing, lighting/sky transitions, survival heat integration, IslandAudio
## nocturnal hook, Wild Pig day/night/shelter/campfire/reinforcement behavior,
## Reef Shark patrol/investigate/attack/shallow-escape, and Save/Load persistence.

var _failures: Array[String] = []


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[PASS] %s" % msg)
	else:
		print("[FAIL] %s" % msg)
		_failures.append(msg)


func _initialize() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	print("=== KoaCoast Day-Night Cycle & Nocturnal Wildlife Test ===")
	var scene := load("res://scenes/KoaCoast.tscn") as PackedScene
	_check(scene != null, "Loaded scenes/KoaCoast.tscn")
	if scene == null:
		_finish()
		return

	var world := scene.instantiate()
	root.add_child(world)
	for _i in 6:
		await process_frame

	var survival := world.get_node_or_null("SurvivalSystem") as SurvivalSystem
	var player := world.get_node_or_null("Player") as CharacterBody3D
	var terrain := world.get_node_or_null("Terrain3D") as Terrain3D
	var sun := world.get_node_or_null("LateMorningSun") as DirectionalLight3D
	var world_env := world.get_node_or_null("TradeWindSky") as WorldEnvironment
	var island_audio := world.get_node_or_null("IslandAudio")

	_check(survival != null and survival.day_night != null and survival.wildlife != null, "SurvivalSystem, DayNightSystem, and WildlifeSystem initialized")
	if survival == null or survival.day_night == null or survival.wildlife == null:
		_finish()
		return

	var dn := survival.day_night
	var wl := survival.wildlife
	var bld := survival.buildings
	var vitals := survival.vitals
	var inv := survival.inventory

	# 1. Default timing & independent configurability
	_check(is_equal_approx(dn.day_duration_seconds, 360.0), "Default daytime duration is 6 minutes (360s)")
	_check(is_equal_approx(dn.night_duration_seconds, 360.0), "Default nighttime duration is 6 minutes (360s)")
	_check(is_equal_approx(dn.get_total_cycle_seconds(), 720.0), "Default full cycle is 12 minutes (720s)")
	dn.day_duration_seconds = 300.0
	dn.night_duration_seconds = 420.0
	_check(is_equal_approx(dn.get_total_cycle_seconds(), 720.0) and is_equal_approx(dn.day_duration_seconds, 300.0), "Day and night durations are independently configurable")
	dn.day_duration_seconds = 360.0
	dn.night_duration_seconds = 360.0
	dn.reset_all()

	# 2. Daytime visual preservation & lighting/sky transitions
	_check(not dn.is_night() and dn.night_factor < 0.05, "Initial state preserves daytime lighting (night_factor=%.3f)" % dn.night_factor)
	var day_sun_energy := sun.light_energy if sun else 1.0
	var day_heat := vitals.daytime_heat_multiplier

	dn.set_to_phase(&"sunset")
	_check(dn.twilight_factor > 0.35, "Sunset raises twilight_factor (%.2f)" % dn.twilight_factor)

	dn.set_to_phase(&"night")
	_check(dn.is_night() and dn.night_factor > 0.85, "Night phase sets is_night=true and high night_factor (%.2f)" % dn.night_factor)
	if sun:
		_check(sun.light_energy < day_sun_energy * 0.5, "Nighttime moonlight energy (%.2f) is substantially lower than daytime sun (%.2f)" % [sun.light_energy, day_sun_energy])
	if world_env and world_env.environment and world_env.environment.sky and world_env.environment.sky.sky_material is ShaderMaterial:
		var sky_mat := world_env.environment.sky.sky_material as ShaderMaterial
		_check(float(sky_mat.get_shader_parameter("night_factor")) > 0.85, "MaritimeSky shader receives night_factor > 0.85 at night")
	if island_audio and "night_factor" in island_audio:
		_check(float(island_audio.get("night_factor")) > 0.85, "IslandAudio receives nocturnal night_factor transition (%.2f)" % float(island_audio.get("night_factor")))

	# 3. Day/night survival heat & thirst integration
	var night_heat := vitals.daytime_heat_multiplier
	_check(day_heat > night_heat + 0.2, "Daytime heat multiplier (%.2f) > nighttime heat multiplier (%.2f)" % [day_heat, night_heat])

	dn.set_to_phase(&"day")
	vitals.reset_all()
	vitals.step_simulation(30.0)
	var day_thirst_after := vitals.thirst

	dn.set_to_phase(&"night")
	vitals.reset_all()
	vitals.step_simulation(30.0)
	var night_thirst_after := vitals.thirst
	_check(day_thirst_after < night_thirst_after, "Daytime heat drains thirst faster (%.2f left) than cooler night (%.2f left)" % [day_thirst_after, night_thirst_after])

	# 4. Day rollover
	dn.reset_all()
	var start_day := dn.day_number
	dn.advance_time(720.0)
	_check(dn.day_number == start_day + 1, "Advancing full 720s cycle increments day_number (%d -> %d)" % [start_day, dn.day_number])

	# 5. Wild Pig spawn validity & daytime flee behavior
	dn.set_to_phase(&"day")
	_check(wl.pigs.size() >= 4, "Spawned %d wild pigs on the island" % wl.pigs.size())
	var all_pigs_valid := true
	for pig in wl.pigs:
		var ppos: Vector3 = pig["pos"]
		var h := terrain.data.get_height(ppos)
		if not is_finite(h) or h < 1.0:
			all_pigs_valid = false
	_check(all_pigs_valid, "All wild pigs spawned on valid land terrain above water")

	var test_pig: Dictionary = wl.pigs[0]
	var pig_start_pos: Vector3 = test_pig["pos"]
	player.global_position = pig_start_pos + Vector3(6.0, 0.0, 0.0)
	wl.step_simulation(0.4)
	_check(test_pig["state"] == &"flee", "During daytime, wild pig flees when player approaches (state=%s)" % String(test_pig["state"]))

	# 6. Nighttime sensory range (no magic global tracking) & shelter scratching
	dn.set_to_phase(&"night")
	inv.clear()
	inv.add_item(&"wood", 40)
	inv.add_item(&"stone", 40)
	inv.add_item(&"plant_fiber", 20)
	inv.add_item(&"leaves", 20)

	# Place player, a foundation, and a thatch wall far (> 60m) from test_pig first -> pig must NOT magically detect it.
	var base_pos := Vector3(52.0, terrain.data.get_height(Vector3(52.0, 0.0, 578.0)) + 0.5, 578.0)
	player.global_position = base_pos + Vector3(12.0, 0.0, 12.0)
	var fnd_res := bld.place_piece_explicit(&"foundation", base_pos, 0.0, false, &"wood")
	_check(bool(fnd_res.get("ok", false)), "Placed test Foundation for shelter")
	var wall_res := bld.place_piece_explicit(&"wall", base_pos + Vector3(0.0, 0.0, 2.0), 0.0, false, &"thatch")
	_check(bool(wall_res.get("ok", false)), "Placed test unreinforced Thatch Wall")
	var wall_uid := String(wall_res.get("uid", ""))
	var wall_entry: Dictionary = {}
	for piece in bld.get_exterior_shelter_pieces():
		if String(piece["uid"]) == wall_uid:
			wall_entry = piece
			break
	_check(not wall_entry.is_empty(), "Located placed Thatch Wall entry (HP=%.0f)" % float(wall_entry.get("hp", 0.0)))

	# Move all pigs > 60m away and verify none magically switch to investigate_camp
	for pig in wl.pigs:
		var far_p := base_pos + Vector3(0.0, 0.0, -75.0)
		far_p.y = maxf(2.0, terrain.data.get_height(far_p))
		pig["pos"] = far_p
		pig["home"] = far_p
		pig["state"] = &"prowl"
		pig["target_uid"] = ""
	wl.step_simulation(0.5)
	var any_magic := false
	for pig in wl.pigs:
		if pig["state"] == &"investigate_camp" or pig["state"] == &"scratch_shelter":
			any_magic = true
	_check(not any_magic, "Nighttime pigs outside sensory range (>60m) do NOT magically track distant shelters")

	# Now trigger controlled shelter threat test (moves pig within sensory range)
	var trig := wl.trigger_shelter_threat_test()
	_check(bool(trig.get("ok", false)), "trigger_shelter_threat_test() succeeded")
	if not wall_entry.is_empty():
		var initial_hp := float(wall_entry["hp"])
		for _s in 30:
			wl.step_simulation(0.25)
		_check(float(wall_entry["hp"]) < initial_hp, "Prowling pig approached and damaged unreinforced wall (HP %.0f -> %.0f)" % [initial_hp, float(wall_entry["hp"])])

		# 7. Reinforce wall -> resists scratching and deters pig
		var reinf_res := bld.reinforce_piece(String(wall_entry["uid"]), true)
		_check(bool(reinf_res.get("ok", false)) and bool(wall_entry["reinforced"]), "Reinforced shelter wall using Wood + Stone (max_hp=%.0f)" % float(wall_entry["max_hp"]))
		var hp_after_reinf := float(wall_entry["hp"])
		test_pig["state"] = &"scratch_shelter"
		test_pig["target_uid"] = String(wall_entry["uid"])
		test_pig["pos"] = (wall_entry["pos"] as Vector3) + Vector3(1.5, 0.0, 0.0)
		test_pig["resist_hits"] = 0
		test_pig["scratch_timer"] = 0.05
		for _s in 25:
			wl.step_simulation(0.25)
		_check(is_equal_approx(float(wall_entry["hp"]), hp_after_reinf), "Reinforced wall resisted pig scratching without HP loss (HP=%.0f)" % float(wall_entry["hp"]))
		_check(test_pig["state"] == &"retreat" or test_pig["state"] == &"prowl", "Pig deterred after failing to scratch reinforced wall (state=%s)" % String(test_pig["state"]))

		# 8. Campfire crafting, placement & deterrence
		var crafted_fire := survival.crafting.craft(&"craft_campfire")
		_check(crafted_fire and inv.get_count(&"campfire") >= 1, "Crafted Campfire from Wood + Stone + Plant Fiber")
		var fire_res := bld.place_campfire(base_pos + Vector3(2.0, 0.0, 0.0), true)
		_check(bool(fire_res.get("ok", false)) and bld.get_active_campfires().size() == 1, "Placed active Campfire near shelter")
		test_pig["pos"] = base_pos + Vector3(5.0, 0.0, 0.0)
		test_pig["state"] = &"investigate_camp"
		test_pig["target_uid"] = String(wall_entry["uid"])
		wl.step_simulation(0.3)
		_check(test_pig["state"] == &"retreat", "Active campfire drives prowling wild boar into retreat (state=%s)" % String(test_pig["state"]))

	# 9. Reef Sharks: valid water spawn, investigate warning, attack, and shallow-water escape
	_check(wl.sharks.size() >= 2, "Spawned %d reef sharks in coastal waters" % wl.sharks.size())
	var all_sharks_valid := true
	for shark in wl.sharks:
		var spos: Vector3 = shark["pos"]
		var sh := terrain.data.get_height(spos)
		if not is_finite(sh) or sh > -1.0:
			all_sharks_valid = false
	_check(all_sharks_valid, "All reef sharks spawned in valid navigable water (terrain_h <= -1.0)")

	var test_shark: Dictionary = wl.sharks[0]
	var shark_pos: Vector3 = test_shark["pos"]
	vitals.reset_all()
	# Place player swimming in deep water near shark at night
	player.global_position = shark_pos + Vector3(12.0, 0.0, 0.0)
	player.global_position.y = -0.3
	wl.step_simulation(0.2)
	_check(test_shark["state"] == &"investigate", "Nighttime reef shark detects swimmer and enters investigate/circle state (state=%s)" % String(test_shark["state"]))

	# Step through investigation into attack & bite
	var hp_before_shark := vitals.health
	for _s in 35:
		wl.step_simulation(0.2)
	_check(vitals.health < hp_before_shark, "Reef shark transitioned to attack and bit swimmer (HP %.0f -> %.0f)" % [hp_before_shark, vitals.health])

	# Player escapes to shore -> shark immediately breaks off and stays in valid water
	player.global_position = base_pos
	wl.step_simulation(0.3)
	var shark_ground_h := terrain.data.get_height(test_shark["pos"])
	_check(test_shark["state"] == &"patrol" and shark_ground_h <= -0.65, "Shark broke off when player escaped to shore and remained in valid water (state=%s, h=%.2f)" % [String(test_shark["state"]), shark_ground_h])

	# 10. Debug controls preserved + new actions registered
	_check(InputMap.has_action("debug_drain_vitals") and InputMap.has_action("debug_toggle_rain") and InputMap.has_action("debug_toggle_vitals"), "Existing F2/F3/F4 debug actions preserved")
	_check(InputMap.has_action("debug_advance_time") and InputMap.has_action("debug_toggle_day_night") and InputMap.has_action("debug_trigger_shelter_threat"), "New F10/F11/F12 day-night & wildlife debug actions registered")

	# 11. Save / Load persistence of day-night clock, reinforcement, and campfires
	var test_save_path := "user://test_day_night_wildlife_save.json"
	survival.save_system.save_path = test_save_path
	dn.day_number = 3
	dn.cycle_time = 510.0 # Nighttime on Day 3
	dn.advance_time(0.01)
	var saved := survival.perform_save()
	_check(bool(saved.get("ok", false)), "Saved game state with Day 3 night, reinforced wall, and campfire")

	survival.perform_new_game()
	_check(dn.day_number == 1 and not dn.is_night() and bld.get_placed_count() == 0 and bld.get_active_campfires().is_empty(), "New Game reset day/time, buildings, and campfires")

	var loaded := survival.perform_load()
	_check(bool(loaded.get("ok", false)), "Loaded saved game state")
	_check(dn.day_number == 3 and dn.is_night() and absf(dn.cycle_time - 510.0) < 1.0, "Restored Day 3 nighttime environmental clock (Day %d, t=%.1f)" % [dn.day_number, dn.cycle_time])
	var restored_reinf := false
	for p_entry in bld.get_exterior_shelter_pieces():
		if bool(p_entry.get("reinforced", false)):
			restored_reinf = true
	_check(bld.get_placed_count() >= 1 and restored_reinf, "Restored reinforced shelter wall state across save/load")
	_check(bld.get_active_campfires().size() == 1, "Restored lit campfire across save/load")

	if FileAccess.file_exists(test_save_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(test_save_path))

	_finish()


func _finish() -> void:
	print("=== Test Complete: %d failure(s) ===" % _failures.size())
	if _failures.is_empty():
		quit(0)
	else:
		for f in _failures:
			print("  -> %s" % f)
		quit(1)
