extends SceneTree
## Headless integration test for NEON Prompt 3: Hardcore Death, Respawning & Equipment Recovery.
## Validates all 20 Phase 9 requirements: starvation/dehydration/wildlife death pipeline,
## control lockout, atomic metadata-preserving cache drop, base persistence, unreachable-death
## cache relocation, respawn priority & safety, Survival Trauma penalties/expiry/non-stacking,
## multi-cache & capacity-limited recovery, save/load integrity, and older-save compatibility.

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
	print("=== KoaCoast Hardcore Death, Respawning & Equipment Recovery Test ===")
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

	_check(survival != null and survival.death_recovery != null, "SurvivalSystem and DeathRecoverySystem initialized")
	if survival == null or survival.death_recovery == null:
		_finish()
		return

	var dr := survival.death_recovery
	var vitals := survival.vitals
	var inv := survival.inventory
	var bld := survival.buildings
	var dn := survival.day_night
	var wl := survival.wildlife
	var craft := survival.crafting

	# Keep wildlife far away during controlled setup so ambient pigs don't interfere
	var spawn_pos := player.global_position
	for pig in wl.pigs:
		pig["pos"] = Vector3(-400.0, 10.0, -400.0)
		pig["home"] = pig["pos"]

	# Prepare base structures, base storage, and carried equipment + water container with metadata
	var build_origin := Vector3(52.0, terrain.data.get_height(Vector3(52.0, 0.0, 578.0)) + 0.5, 578.0)
	var fnd := bld.place_piece_explicit(&"foundation", build_origin, 0.0, false, &"wood")
	var wall := bld.place_piece_explicit(&"wall", build_origin + Vector3(0.0, 0.0, 2.0), 0.0, false, &"wood")
	bld.reinforce_piece(String(wall.get("uid", "")), false)
	bld.store_base_item(&"wood", 25)
	bld.store_base_item(&"wild_berries", 12)
	var cf_res := bld.place_campfire(build_origin + Vector3(18.0, 0.0, 0.0), false)
	var cf_uid := String(cf_res.get("uid", ""))
	# Extinguish campfire to verify unlit campfires still serve as valid respawn points!
	bld.toggle_campfire(cf_uid)

	inv.clear()
	inv.add_item(&"stone_axe", 1)
	inv.add_item(&"wood", 10)
	inv.add_item(&"coconut_shell", 1)
	var shell_slot := inv.find_container_slot(true, false)
	inv.fill_container(shell_slot, 75.0, WaterQuality.Quality.CLEAN_FRESHWATER)

	# 1. Starvation triggers death through centralized pipeline
	var died_causes: Array[StringName] = []
	vitals.player_died.connect(func(c: StringName, _lbl: String): died_causes.append(c))

	dn.day_number = 2
	dn.cycle_time = 200.0
	vitals.hunger = 0.0
	vitals.thirst = 80.0
	vitals.health = 2.0
	vitals.step_simulation(3.0)
	_check(vitals.is_dead and dr.is_death_in_progress(), "Starvation triggered centralized death sequence")
	_check(died_causes.size() == 1 and died_causes[0] == &"starvation", "Death cause recorded as starvation exactly once")
	_check(bool(player.get("gameplay_input_blocked")), "Player controls disabled during death collapse")

	# Re-entrancy check: extra damage during death must NOT duplicate death or drops
	vitals.apply_damage(50.0, &"wildlife_attack", "Wild Boar Attack")
	dr.handle_player_death(&"wildlife_attack", "Wild Boar Attack")
	_check(died_causes.size() == 1 and dr.get_cache_count() == 1, "Prevented duplicate death events and duplicate equipment caches")
	_check(inv.get_used_slot_count() == 0, "Carried inventory emptied atomically into death cache")

	# Check base structures, base storage, and environmental clock remained intact
	_check(bld.get_placed_count() == 2 and bld.get_base_storage_count(&"wood") == 25 and bld.get_base_storage_count(&"wild_berries") == 12, "Built structures and stored base supplies remained untouched on death")
	_check(dn.day_number == 2 and dn.cycle_time >= 200.0, "Environmental time & day progression preserved on death")

	# 2. Complete respawn -> Priority 2 (unlit campfire, since no home shelter designated yet)
	var resp1 := dr.complete_respawn_now()
	_check(bool(resp1.get("ok", false)) and resp1.get("source") == &"campfire", "Respawned at nearest valid constructed campfire even when unlit (source=%s)" % String(resp1.get("source")))
	_check(not bool(player.get("gameplay_input_blocked")), "Player controls re-enabled after respawn")

	# Verify exact respawn vitals + Survival Trauma penalties
	_check(is_equal_approx(vitals.health, 60.0), "Health restored to 60%% on respawn (%.1f)" % vitals.health)
	_check(is_equal_approx(vitals.hunger, 40.0) and is_equal_approx(vitals.thirst, 40.0), "Hunger (%.1f%%) and Thirst (%.1f%%) restored to 40%%" % [vitals.hunger, vitals.thirst])
	_check(vitals.has_survival_trauma() and is_equal_approx(vitals.survival_trauma_remaining, dn.get_total_cycle_seconds()), "Survival Trauma active for one complete in-game cycle (%.0fs)" % vitals.survival_trauma_remaining)
	_check(is_equal_approx(vitals.effective_max_stamina, 75.0), "Survival Trauma reduced max stamina by 25%% (%.1f)" % vitals.effective_max_stamina)
	_check(is_equal_approx(vitals.stamina, 37.5), "Stamina restored to 50%% of trauma-reduced max stamina (%.1f)" % vitals.stamina)
	_check(is_equal_approx(vitals.stamina_regen_multiplier, 0.80), "Survival Trauma reduced stamina regen by 20%% (x%.2f)" % vitals.stamina_regen_multiplier)
	craft.set_craft_time_multiplier(vitals.get_crafting_duration_multiplier())
	_check(is_equal_approx(craft.get_effective_craft_time(), craft.base_craft_duration * 1.25), "Survival Trauma increased crafting duration by 25%% (%.2fs)" % craft.get_effective_craft_time())

	# Check trauma integrates with low hunger/thirst without overwriting them
	vitals.hunger = 20.0 # <30% -> 0.55x regen
	vitals.step_simulation(0.01)
	_check(is_equal_approx(vitals.stamina_regen_multiplier, 0.55 * 0.80), "Survival Trauma multiplies cleanly with hunger regen penalty (x%.3f)" % vitals.stamina_regen_multiplier)

	# 3. Verify recovery indicator points to latest death cache
	var ind := dr.get_latest_cache_indicator(player.global_position)
	_check(bool(ind.get("active", false)) and float(ind.get("distance", -1.0)) >= 0.0 and not String(ind.get("direction", "")).is_empty(), "Recovery indicator shows direction (%s) and distance (%.0fm)" % [String(ind.get("direction", "")), float(ind.get("distance", 0.0))])

	# 4. Priority 1: Designated Home Shelter overrides campfire
	dr.set_home_shelter(build_origin)
	var home_res := dr.resolve_respawn_location()
	_check(home_res.get("source") == &"home_shelter", "Respawn priority #1 selects valid designated home shelter")

	# Verify respawn avoids nearby wildlife
	wl.pigs[0]["pos"] = home_res["pos"]
	var avoided_res := dr.resolve_respawn_location()
	_check((avoided_res["pos"] as Vector3).distance_to(wl.pigs[0]["pos"]) >= dr.wildlife_safe_radius - 0.1, "Respawn safety check avoids direct overlap with nearby wildlife")
	wl.pigs[0]["pos"] = Vector3(-400.0, 10.0, -400.0)

	# 5. Dehydration death + underwater unreachable-cache relocation + non-stacking trauma reset
	inv.add_item(&"stone_pickaxe", 1)
	inv.add_item(&"shark_tooth", 3)
	# Place player underwater in ocean
	var ocean_pos := Vector3(48.0, -2.5, 740.0)
	player.global_position = ocean_pos
	vitals.hunger = 80.0
	vitals.thirst = 0.0
	vitals.health = 1.5
	vitals.survival_trauma_remaining = 120.0 # Partially elapsed trauma
	vitals.step_simulation(3.0)
	_check(vitals.is_dead and died_causes.size() == 2 and died_causes[1] == &"dehydration", "Dehydration triggered centralized death pipeline")
	_check(dr.get_cache_count() == 2, "Second death created a separate second death cache (count=%d)" % dr.get_cache_count())

	var ocean_cache: Dictionary = dr.get_caches()[1]
	var cpos: Vector3 = ocean_cache["pos"]
	var ch := terrain.data.get_height(cpos)
	_check(ch >= 0.45 and (ocean_cache["original_death_pos"] as Vector3).distance_to(ocean_pos) < 0.5, "Underwater death cache relocated to reachable land (h=%.2f) while preserving original_death_pos" % ch)

	dr.complete_respawn_now()
	_check(is_equal_approx(vitals.survival_trauma_remaining, dn.get_total_cycle_seconds()) and is_equal_approx(vitals.effective_max_stamina, 75.0), "Repeated death reset Survival Trauma duration without stacking stamina penalty")

	# 6. Wildlife damage triggers death (Shark Attack)
	vitals.health = 20.0
	vitals.apply_damage(32.0, &"shark_attack", "Shark Attack")
	_check(vitals.is_dead and died_causes.size() == 3 and died_causes[2] == &"shark_attack", "Wildlife (Shark Attack) damage triggered centralized death pipeline")
	dr.complete_respawn_now()

	# 7. Save & Load persistence of multiple death caches, metadata, respawn pos, and trauma
	var test_save_path := "user://test_death_recovery_save.json"
	survival.save_system.save_path = test_save_path
	vitals.survival_trauma_remaining = 450.0
	var save_res := survival.perform_save()
	_check(bool(save_res.get("ok", false)), "Saved game with 2 unrecovered death caches and active Survival Trauma")

	survival.perform_new_game()
	_check(dr.get_cache_count() == 0 and not vitals.has_survival_trauma(), "New Game cleared death caches and Survival Trauma")

	var load_res := survival.perform_load()
	_check(bool(load_res.get("ok", false)), "Loaded saved game with death caches and Survival Trauma")
	_check(dr.get_cache_count() == 2, "Restored both unrecovered death caches across save/load")
	_check(is_equal_approx(vitals.survival_trauma_remaining, 450.0), "Restored remaining Survival Trauma duration (%.1fs)" % vitals.survival_trauma_remaining)

	# 8. Capacity-limited recovery & full metadata preservation without duplication
	# Fill all 24 inventory slots except 1 slot so cache #1 can only partially recover!
	inv.clear()
	for _s in 23:
		inv.add_item(&"stone_axe", 1) # non-stackable (max_stack=1) fills 23 slots
	var cache1_uid := String(dr.get_caches()[0]["uid"])
	var partial := dr.recover_cache(cache1_uid)
	_check(not bool(partial.get("fully_emptied", true)) and int(partial.get("remaining_items", 0)) > 0 and dr.get_cache_count() == 2, "Inventory capacity limit respected: leftover items stayed in cache (%d remaining)" % int(partial.get("remaining_items", 0)))

	# Free space and recover remaining items from cache #1
	inv.clear()
	var full1 := dr.recover_cache(cache1_uid)
	_check(bool(full1.get("fully_emptied", false)) and dr.get_cache_count() == 1, "Empty death cache disappeared after full recovery (remaining caches=%d)" % dr.get_cache_count())
	var rec_shell_slot := inv.find_container_slot(false, true)
	var rec_water := inv.get_container_water(rec_shell_slot) if rec_shell_slot >= 0 else {}
	_check(rec_shell_slot >= 0 and is_equal_approx(float(rec_water.get("amount", 0.0)), 75.0) and int(rec_water.get("quality", -1)) == WaterQuality.Quality.CLEAN_FRESHWATER, "Water container metadata (75 mL Clean Freshwater) survived death, save/load, and recovery")
	_check(inv.get_count(&"wood") == 10, "Exact item quantity recovered without duplication (wood=%d)" % inv.get_count(&"wood"))

	# Recover second cache -> all caches gone & indicator hides
	var cache2_uid := String(dr.get_caches()[0]["uid"])
	var full2 := dr.recover_cache(cache2_uid)
	_check(bool(full2.get("fully_emptied", false)) and dr.get_cache_count() == 0, "Second death cache fully recovered and removed")
	_check(not bool(dr.get_latest_cache_indicator(player.global_position).get("active", true)), "Recovery indicator automatically hides when all caches are recovered")

	# 9. Survival Trauma expires automatically after one full in-game cycle
	vitals.hunger = 80.0
	vitals.thirst = 80.0
	dn.advance_time(500.0)
	_check(not vitals.has_survival_trauma() and is_equal_approx(vitals.effective_max_stamina, 100.0) and is_equal_approx(vitals.stamina_regen_multiplier, 1.0), "Survival Trauma expired after full cycle and restored full stamina & regen")
	craft.set_craft_time_multiplier(vitals.get_crafting_duration_multiplier())
	_check(is_equal_approx(craft.get_effective_craft_time(), craft.base_craft_duration), "Crafting duration returned to normal after Survival Trauma expired")

	# 10. Priority 3: Original safe starting location when no home shelter or campfire exists
	bld.clear_all()
	dr.clear_home_shelter()
	var start_res := dr.resolve_respawn_location()
	_check(start_res.get("source") == &"starting_spawn", "Respawn priority #3 falls back to safe starting spawn when no shelter/campfire exists")

	# 11. Older compatible save (no death_recovery / no survival_trauma_remaining) loads safely
	var legacy_path := "user://test_legacy_v1_save.json"
	var legacy_payload := {
		"version": 1,
		"player": { "position": [spawn_pos.x, spawn_pos.y, spawn_pos.z] },
		"inventory": { "capacity": 24, "slots": [{ "slot": 0, "item_id": "wood", "amount": 5 }] },
		"resources": {},
		"collectibles": {},
		"buildings": { "next_uid": 1, "pieces": [] },
		"vitals": { "health": 90.0, "stamina": 80.0, "hunger": 75.0, "thirst": 70.0 },
	}
	var lf := FileAccess.open(legacy_path, FileAccess.WRITE)
	lf.store_string(JSON.stringify(legacy_payload))
	lf.close()
	survival.save_system.save_path = legacy_path
	var legacy_res := survival.perform_load()
	_check(bool(legacy_res.get("ok", false)) and inv.get_count(&"wood") == 5 and dr.get_cache_count() == 0 and not vitals.has_survival_trauma(), "Older compatible v1 save loaded cleanly without errors")

	for p_clean in [test_save_path, legacy_path]:
		if FileAccess.file_exists(p_clean):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p_clean))

	_finish()


func _finish() -> void:
	print("=== Test Complete: %d failure(s) ===" % _failures.size())
	if _failures.is_empty():
		quit(0)
	else:
		for f in _failures:
			print("  -> %s" % f)
		quit(1)
