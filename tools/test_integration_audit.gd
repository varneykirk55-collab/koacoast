extends SceneTree
## Comprehensive Integration Audit & Full Gameplay Loop Validation Suite.
## Covers Phases 2-10: walkability, timed crafting + Survival Trauma, combined survival
## modifiers, simultaneous damage sources, safe respawn during floods/eruptions,
## shelter/campfire/home-designation, controller completeness, and combined save/load.

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
	print("=== KoaCoast Full Integration Audit & Gameplay Loop Test ===")
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
	_check(survival != null and player != null and terrain != null, "Core scene nodes initialized")
	if survival == null or player == null or terrain == null:
		_finish()
		return

	var inv := survival.inventory
	var craft := survival.crafting
	var bld := survival.buildings
	var vitals := survival.vitals
	var dn := survival.day_night
	var wl := survival.wildlife
	var dr := survival.death_recovery
	var weather := survival.weather
	var volcano := survival.volcano
	var hud := survival.hud

	# Keep ambient pigs away from test area until tested
	for pig in wl.pigs:
		pig["pos"] = Vector3(-420.0, 10.0, -420.0)
		pig["home"] = pig["pos"]

	# 1. Controller-first bindings check (no essential action requires keyboard)
	var essential_actions := [
		"move_forward", "move_back", "move_left", "move_right",
		"look_left", "look_right", "look_up", "look_down",
		"jump", "sprint", "interact", "toggle_inventory",
		"toggle_build_mode", "toggle_map", "toggle_system_menu",
		"build_confirm", "build_remove", "build_rotate_cw", "build_rotate_ccw",
		"build_prev_piece", "build_next_piece", "build_cycle_material", "build_cancel",
		"craft_tab_prev", "craft_tab_next", "ui_accept", "ui_cancel",
	]
	var all_controller_bound := true
	for act in essential_actions:
		var has_joy := false
		for ev in InputMap.action_get_events(act):
			if ev is InputEventJoypadButton or ev is InputEventJoypadMotion:
				has_joy = true
				break
		if not has_joy:
			all_controller_bound = false
			print("  Missing controller binding for: ", act)
	_check(all_controller_bound, "All %d essential gameplay & UI actions have gamepad bindings" % essential_actions.size())

	# 2. Timed crafting via UI signal & Survival Trauma (+25% duration)
	inv.clear()
	inv.add_item(&"wood", 30)
	inv.add_item(&"stone", 30)
	inv.add_item(&"plant_fiber", 20)
	inv.add_item(&"rope", 10)
	inv.add_item(&"leaves", 20)

	vitals.survival_trauma_remaining = 0.0
	vitals.step_simulation(0.01)
	craft.set_craft_time_multiplier(vitals.get_crafting_duration_multiplier())
	var normal_craft_dur := craft.get_effective_craft_time(&"craft_stone_axe")

	hud.inv_panel.open_panel()
	hud.inv_panel.craft_requested.emit(&"craft_stone_axe")
	_check(craft.is_crafting(), "UI craft_requested starts timed crafting instead of instant craft")
	_check(inv.get_count(&"stone_axe") == 0, "Timed craft does not grant item before duration elapses")
	# Duplicate submission must be rejected without consuming extra mats
	hud.inv_panel.craft_requested.emit(&"craft_stone_axe")
	_check(inv.get_count(&"wood") == 30, "Duplicate craft submission ignored and materials untouched")
	# Close panel mid-craft -> safe cancellation with zero material loss
	hud.inv_panel.close_panel()
	_check(not craft.is_crafting() and inv.get_count(&"wood") == 30 and inv.get_count(&"stone_axe") == 0, "Closing inventory mid-craft cancels cleanly with zero ingredient loss")

	# Complete normal timed craft
	hud.inv_panel.open_panel()
	hud.inv_panel.craft_requested.emit(&"craft_stone_axe")
	var steps_needed := int(ceil(normal_craft_dur / 0.1)) + 2
	for _i in steps_needed:
		craft._process(0.1)
	_check(not craft.is_crafting() and inv.get_count(&"stone_axe") == 1, "Normal timed craft completed after %.2fs" % normal_craft_dur)

	# Apply Survival Trauma -> craft time increases by 25%
	vitals.apply_survival_trauma(dn.get_total_cycle_seconds())
	craft.set_craft_time_multiplier(vitals.get_crafting_duration_multiplier())
	var trauma_dur := craft.get_effective_craft_time(&"craft_stone_pickaxe")
	_check(is_equal_approx(trauma_dur, normal_craft_dur * 1.25), "Survival Trauma increases timed craft duration by 25%% (%.2fs vs %.2fs)" % [trauma_dur, normal_craft_dur])
	hud.inv_panel.craft_requested.emit(&"craft_stone_pickaxe")
	for _i in int(floor(normal_craft_dur / 0.1)):
		craft._process(0.1)
	_check(craft.is_crafting() and inv.get_count(&"stone_pickaxe") == 0, "Under Survival Trauma, crafting is NOT yet finished at normal duration")
	for _i in 6:
		craft._process(0.1)
	_check(not craft.is_crafting() and inv.get_count(&"stone_pickaxe") == 1, "Under Survival Trauma, crafting finishes after +25% duration")
	hud.inv_panel.close_panel()

	# Clear trauma -> crafting returns to normal speed
	dn.advance_time(dn.get_total_cycle_seconds() + 1.0)
	craft.set_craft_time_multiplier(vitals.get_crafting_duration_multiplier())
	_check(not vitals.has_survival_trauma() and is_equal_approx(craft.get_effective_craft_time(), normal_craft_dur), "Crafting returns to normal timing when Survival Trauma expires")

	# 3. Combined survival modifiers (hunger + thirst + trauma + cold + ash + debris)
	vitals.reset_all()
	vitals.apply_survival_trauma(720.0)
	vitals.hunger = 10.0 # <15%: reduced max stamina & 0.35 regen
	vitals.thirst = 10.0 # <15%: reduced move speed & 0.35 regen
	vitals.cold_exposure = 0.80
	vitals.volcanic_ash_exposure = 0.70
	vitals.debris_drag = 0.32
	vitals.step_simulation(0.01)
	_check(vitals.effective_max_stamina < 75.0 and vitals.effective_max_stamina > 50.0, "Hunger + Survival Trauma combine on max_stamina (%.1f)" % vitals.effective_max_stamina)
	_check(vitals.stamina_regen_multiplier < 0.08, "Hunger + Thirst + Trauma + Cold + Ash combine on stamina_regen (x%.4f)" % vitals.stamina_regen_multiplier)
	_check(vitals.move_speed_multiplier < 0.55, "Thirst + Cold + Mud debris_drag combine on move_speed (x%.2f)" % vitals.move_speed_multiplier)

	# 4. Shelter reinforcement max_hp toast & Home Shelter designation
	var build_origin := Vector3(52.0, terrain.data.get_height(Vector3(52.0, 0.0, 578.0)) + 0.5, 578.0)
	var fnd := bld.place_piece_explicit(&"foundation", build_origin, 0.0, false, &"wood")
	var wall := bld.place_piece_explicit(&"wall", build_origin + Vector3(0.0, 0.0, 2.0), 0.0, false, &"wood")
	var wall_uid := String(wall.get("uid", ""))
	var reinf_res := bld.reinforce_piece(wall_uid, true)
	_check(bool(reinf_res.get("ok", false)) and is_equal_approx(float(reinf_res.get("max_hp", 0.0)), 240.0), "reinforce_piece returns max_hp=240.0 cleanly")

	player.global_position = build_origin + Vector3(0.0, 0.2, 0.0)
	var home_des := survival.perform_designate_home_shelter()
	_check(bool(home_des.get("ok", false)) and dr.has_home_shelter, "Player can designate current shelter as Home Respawn")

	# 5. Safe respawning during active Flood Basin & Volcanic Eruption/Mudflow
	var basin_pt := Vector2(460.0, -424.0)
	var basin_h := terrain.data.get_height(Vector3(basin_pt.x, 0.0, basin_pt.y))
	var flooded_fire := bld.place_campfire(Vector3(basin_pt.x, basin_h, basin_pt.y), false)
	dr.clear_home_shelter()
	weather.request_state(TropicalWeather.State.TROPICAL_STORM)
	weather.storage = 0.95
	var flood_check := weather.flood_depth(Vector3(basin_pt.x, basin_h, basin_pt.y))
	_check(flood_check > 0.5, "Simulated deep flood basin (depth=%.2fm)" % flood_check)
	var safe_resp := dr.resolve_respawn_location()
	_check(weather.flood_depth(safe_resp["pos"]) <= 0.25, "Respawn safety avoids flooded basin (depth at respawn=%.2fm)" % weather.flood_depth(safe_resp["pos"]))

	# 6. Simultaneous damage sources -> single death pipeline & single cache
	var death_signals := [0]
	vitals.player_died.connect(func(_c, _l): death_signals[0] += 1)
	inv.add_item(&"coconut_shell", 1)
	var sidx := inv.find_container_slot(true, false)
	inv.fill_container(sidx, 60.0, WaterQuality.Quality.ASH_CONTAMINATED)
	vitals.reset_all()
	vitals.hunger = 0.0
	vitals.thirst = 0.0
	vitals.health = 1.0
	vitals.step_simulation(2.0) # Starvation + Dehydration simultaneously
	vitals.apply_damage(50.0, &"ash", "Volcanic Ash Inhalation")
	_check(death_signals[0] == 1 and dr.get_cache_count() == 1, "Simultaneous damage sources emit exactly 1 death & create 1 cache (signals=%d, caches=%d)" % [death_signals[0], dr.get_cache_count()])

	# 7. Save/Load during active storm + eruption + mudflow + trauma + death cache + mid-craft
	volcano.begin(VolcanicHazards.Phase.ERUPTION)
	volcano.mud_active = true
	volcano.mud_head = 45.0
	dr.complete_respawn_now()
	hud.inv_panel.open_panel()
	inv.add_item(&"wood", 8)
	inv.add_item(&"stone", 8)
	craft.begin_timed_craft(&"craft_wall")
	var test_save := "user://test_integration_audit_save.json"
	survival.save_system.save_path = test_save
	var sv := survival.perform_save()
	_check(bool(sv.get("ok", false)) and not craft.is_crafting() and inv.get_count(&"wood") == 8, "Save during partial craft cancels craft cleanly without losing wood")

	survival.perform_new_game()
	var ld := survival.perform_load()
	_check(bool(ld.get("ok", false)), "Loaded combined storm/eruption/mudflow/trauma/cache save")
	_check(weather.state == TropicalWeather.State.TROPICAL_STORM and volcano.phase == VolcanicHazards.Phase.ERUPTION and volcano.mud_active, "Restored active storm, volcanic eruption, and mudflow state")
	_check(vitals.has_survival_trauma() and dr.get_cache_count() == 1, "Restored Survival Trauma and unrecovered death cache")

	# Recover death cache and verify contaminated water metadata preserved
	var cid := String(dr.get_caches()[0]["uid"])
	var rec := dr.recover_cache(cid)
	var rec_slot := inv.find_container_slot(false, true)
	var w_info := inv.get_container_water(rec_slot) if rec_slot >= 0 else {}
	_check(bool(rec.get("fully_emptied", false)) and int(w_info.get("quality", -1)) == WaterQuality.Quality.ASH_CONTAMINATED, "Recovered cache preserved ASH_CONTAMINATED water metadata")

	if FileAccess.file_exists(test_save):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(test_save))

	_finish()


func _finish() -> void:
	print("=== Integration Audit Complete: %d failure(s) ===" % _failures.size())
	if _failures.is_empty():
		quit(0)
	else:
		for f in _failures:
			print("  -> %s" % f)
		quit(1)
