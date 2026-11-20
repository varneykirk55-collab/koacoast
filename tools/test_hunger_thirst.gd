extends SceneTree
## Comprehensive automated test of KoaCoast's Hardcore Hunger & Thirst Survival System
## in the actual KoaCoast.tscn scene.
## Run:
##   godot --headless --path . --script res://tools/test_hunger_thirst.gd

var _failures: Array[String] = []
var _scene: Node3D
var _player: CharacterBody3D
var _terrain: Terrain3D
var _survival: SurvivalSystem


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_scene = (load("res://scenes/KoaCoast.tscn") as PackedScene).instantiate()
	root.add_child(_scene)
	_player = _scene.get_node("Player")
	_terrain = _scene.get_node("Terrain3D")
	_survival = _scene.get_node("SurvivalSystem")
	_survival.save_system.save_path = "user://koacoast_vitals_test_save.json"

	for _i in 20:
		await process_frame

	var vitals: SurvivalVitalsSystem = _survival.vitals
	var water: WaterSystem = _survival.water_system
	var inv: InventorySystem = _survival.inventory

	_step("1. Activity-Dependent Hunger & Thirst Depletion")
	vitals.reset_all()
	vitals.step_simulation(20.0, &"standing")
	var stand_h_loss := 100.0 - vitals.hunger
	var stand_t_loss := 100.0 - vitals.thirst
	_check(stand_h_loss > 0.0 and stand_t_loss > 0.0, "Hunger (%.2f) and Thirst (%.2f) drain while standing" % [stand_h_loss, stand_t_loss])
	_check(stand_t_loss > stand_h_loss, "Thirst drains faster than Hunger")

	vitals.reset_all()
	vitals.step_simulation(20.0, &"sprinting")
	var sprint_h_loss := 100.0 - vitals.hunger
	var sprint_t_loss := 100.0 - vitals.thirst
	_check(sprint_h_loss > stand_h_loss * 3.0, "Sprinting drains Hunger faster than standing (%.2f vs %.2f)" % [sprint_h_loss, stand_h_loss])
	_check(sprint_t_loss > stand_t_loss * 3.0, "Sprinting drains Thirst faster than standing (%.2f vs %.2f)" % [sprint_t_loss, stand_t_loss])

	# Environment hooks: daytime heat & volcanic ash exposure amplify thirst drain.
	vitals.reset_all()
	vitals.set_environment_hooks(1.5, 0.8, 0.0)
	vitals.step_simulation(20.0, &"sprinting")
	var hot_ash_t_loss := 100.0 - vitals.thirst
	_check(hot_ash_t_loss > sprint_t_loss * 1.8, "Heat & ash hooks amplify Thirst depletion (%.2f vs %.2f)" % [hot_ash_t_loss, sprint_t_loss])
	vitals.set_environment_hooks(1.0, 0.0, 0.0)

	_step("2. Harvesting Activity Modifiers & Berry Bush Gathering")
	vitals.reset_all()
	var h_before_chop := vitals.hunger
	var t_before_chop := vitals.thirst
	vitals.register_harvest_activity(&"tree")
	vitals.step_simulation(2.0)
	_check(vitals.current_activity == &"chopping_wood", "Tree harvest sets chopping_wood activity")
	_check((h_before_chop - vitals.hunger) > 1.0 and (t_before_chop - vitals.thirst) > 1.5, "Chopping wood applies high hunger & thirst modifiers")

	# Validate berry bush placement rules (never underwater, steep cliffs, or basalt/lava).
	var berry_positions: Array[Vector3] = []
	var bad_bushes := 0
	for node: Dictionary in _survival.resources._nodes_by_id.values():
		if node["kind"] != &"berry_bush":
			continue
		var p: Vector3 = node["pos"]
		berry_positions.append(p)
		var bh: float = _terrain.data.get_height(p)
		var bn: Vector3 = _terrain.data.get_normal(p)
		if not is_finite(bh) or bh < 0.5 or bn.y < 0.82:
			bad_bushes += 1
	_check(berry_positions.size() >= 10, "Spawned %d harvestable berry bushes in vegetated areas" % berry_positions.size())
	_check(bad_bushes == 0, "Zero berry bushes on steep cliffs or underwater")

	var nearest_bush := _find_nearest_vec3(berry_positions, _player.global_position)
	_move_player_to(nearest_bush + Vector3(0.7, 0.0, 0.0))
	await _pump(4)
	var bush_target := _survival.resources.find_nearest_target(_player.global_position, Vector3.FORWARD)
	_check(not bush_target.is_empty() and bush_target.get("kind") == &"berry_bush", "Detected nearby Berry Bush for interaction")
	var berry_res := _survival.resources.harvest(bush_target)
	_check(bool(berry_res.get("ok", false)) and inv.get_count(&"wild_berries") >= 2, "Harvested Wild Berries (%d)" % inv.get_count(&"wild_berries"))

	# Eat berries and confirm hunger restores modestly.
	vitals.hunger = 50.0
	var berry_slot := _find_item_slot(inv, &"wild_berries")
	_check(berry_slot >= 0, "Located Wild Berries slot in inventory")
	var eat_res := _survival.use_inventory_slot(berry_slot)
	_check(bool(eat_res.get("ok", false)) and vitals.hunger > 60.0 and vitals.hunger < 70.0, "Eating Wild Berries restored modest Hunger (now %.1f)" % vitals.hunger)

	_step("3. Coconut Shell Container, Freshwater & Saltwater")
	# Gather coconut & stone, craft Hollowed Coconut Shell.
	inv.add_item(&"coconut", 1)
	inv.add_item(&"stone", 1)
	_check(_survival.crafting.craft(&"craft_coconut_shell"), "Crafted Hollowed Coconut Shell")
	var shell_slot := inv.find_container_slot(true, false)
	_check(shell_slot >= 0, "Hollowed Coconut Shell stored as fillable container")

	# Move to Central Ravine freshwater stream near spawn: (10, 576).
	_move_player_to(Vector3(10.0, 0.0, 576.0))
	await _pump(4)
	var fw_src := water.detect_water_source(_player.global_position)
	_check(not fw_src.is_empty() and fw_src["type"] == &"freshwater", "Detected valid Freshwater Stream from watersheds.json")
	var added_fw := inv.fill_container(shell_slot, 150.0, int(fw_src["quality"]))
	var shell_state := inv.get_container_water(shell_slot)
	_check(is_equal_approx(added_fw, 100.0) and is_equal_approx(float(shell_state["amount"]), 100.0), "Coconut Shell respected 100 mL capacity limit")

	# Drink freshwater from container -> restores thirst.
	vitals.thirst = 40.0
	var drink_res := _survival.use_inventory_slot(shell_slot)
	_check(bool(drink_res.get("ok", false)) and bool(drink_res.get("safe", false)) and vitals.thirst > 70.0, "Drinking freshwater from Coconut Shell restored Thirst (now %.1f)" % vitals.thirst)
	var after_sip := inv.get_container_water(shell_slot)
	_check(is_equal_approx(float(after_sip["amount"]), 50.0), "Drinking consumed 50 mL from Coconut Shell (50 mL left)")

	# Saltwater check: move to ocean shoreline (south of black sand, terrain <= 0.3m).
	var salt_pos := _find_ocean_shore_pos()
	_check(salt_pos != Vector3.INF, "Found ocean shoreline for saltwater test")
	_move_player_to(salt_pos)
	await _pump(3)
	var sw_src := water.detect_water_source(_player.global_position)
	_check(not sw_src.is_empty() and sw_src["type"] == &"saltwater" and not WaterQuality.is_safe(int(sw_src["quality"])), "Detected Ocean Saltwater as unsafe")
	vitals.thirst = 50.0
	var hp_before_salt := vitals.health
	var salt_eff := vitals.drink_water(40.0, int(sw_src["quality"]))
	_check(not bool(salt_eff["safe"]) and vitals.thirst < 50.0 and vitals.health < hp_before_salt, "Drinking Saltwater failed to hydrate and penalized vitals")

	_step("4. Rainwater Collection Tarp")
	inv.add_item(&"leaves", 6)
	inv.add_item(&"plant_fiber", 3)
	_check(_survival.crafting.craft(&"craft_rope"), "Crafted Fiber Rope for Rain Tarp")
	inv.add_item(&"wood", 2)
	_check(_survival.crafting.craft(&"craft_rain_tarp"), "Crafted Rainwater Collection Tarp")

	var tarp_pos := Vector3(50.0, 0.0, 570.0)
	var place_res := water.place_rain_collector(tarp_pos, 0.0, true)
	_check(bool(place_res.get("ok", false)), "Placed Rainwater Collection Tarp")
	var rc_uid := String(place_res.get("uid", ""))

	# Confirm NO water collects when rain == 0.
	vitals.rain_intensity = 0.0
	water._process(5.0)
	_check(float(water.get_collector(rc_uid).get("stored_water", 0.0)) <= 0.001, "Rain collector stores 0 mL when not raining")

	# Enable test rain -> confirm water accumulates up to capacity.
	vitals.rain_intensity = 1.0
	water._process(10.0)
	var stored_rain := float(water.get_collector(rc_uid).get("stored_water", 0.0))
	_check(stored_rain >= 45.0 and stored_rain <= water.collector_capacity, "Rain collector accumulated %.1f mL during rainfall" % stored_rain)
	vitals.rain_intensity = 0.0

	# Transfer collected rainwater into Coconut Shell (currently at 50/100 mL).
	var tr_res := water.transfer_to_container(rc_uid)
	_check(bool(tr_res.get("ok", false)) and float(tr_res.get("transferred", 0.0)) >= 45.0, "Transferred rainwater from Rain Tarp to Coconut Shell")
	_check(is_equal_approx(float(inv.get_container_water(shell_slot)["amount"]), 100.0), "Coconut Shell refilled to 100 mL from Rain Tarp")

	_step("5. Starvation, Dehydration Penalties & Full Recovery")
	vitals.reset_all()
	vitals.hunger = 25.0
	vitals.step_simulation(0.1, &"standing")
	_check(vitals.stamina_regen_multiplier < 0.7, "Hunger < 30%% slowed stamina regen (x%.2f)" % vitals.stamina_regen_multiplier)

	vitals.hunger = 10.0
	vitals.step_simulation(0.1, &"standing")
	_check(vitals.effective_max_stamina < vitals.base_max_stamina, "Hunger < 15%% reduced max stamina (%.1f)" % vitals.effective_max_stamina)

	vitals.hunger = 0.0
	var hp_pre_starve := vitals.health
	vitals.step_simulation(3.0, &"standing")
	_check(vitals.health < hp_pre_starve and vitals.health > 0.0, "Hunger at 0%% applies continuous non-instant starvation damage (HP %.1f -> %.1f)" % [hp_pre_starve, vitals.health])

	vitals.reset_all()
	vitals.thirst = 10.0
	vitals.step_simulation(0.1, &"standing")
	_check(vitals.move_speed_multiplier < 1.0 and vitals.move_speed_multiplier > 0.5, "Thirst < 15%% reduced movement speed (%.0f%%)" % (vitals.move_speed_multiplier * 100.0))

	vitals.thirst = 0.0
	var hp_pre_dehyd := vitals.health
	vitals.step_simulation(2.0, &"standing")
	var dps_early := vitals.dehydration_damage_rate
	vitals.step_simulation(20.0, &"standing")
	var dps_late := vitals.dehydration_damage_rate
	_check(is_equal_approx(vitals.move_speed_multiplier, 0.50) and is_equal_approx(_player.survival_speed_scale, 0.50), "Thirst at 0%% reduced movement speed by 50%%")
	_check(vitals.health < hp_pre_dehyd and dps_late > dps_early, "Thirst at 0%% applies progressive dehydration damage (%.2f -> %.2f HP/s)" % [dps_early, dps_late])

	# Recovery clears penalties.
	vitals.eat_food(60.0)
	vitals.drink_water(80.0, WaterQuality.Quality.CLEAN_FRESHWATER)
	_check(is_equal_approx(vitals.move_speed_multiplier, 1.0) and is_equal_approx(vitals.effective_max_stamina, vitals.base_max_stamina), "Eating & drinking restored full speed and max stamina")
	_check(vitals.starvation_damage_rate == 0.0 and vitals.dehydration_damage_rate == 0.0, "Recovery cleared starvation and dehydration damage")

	_step("6. Save & Load Persistence of Survival State")
	vitals.hunger = 62.5
	vitals.thirst = 48.0
	vitals.rain_intensity = 1.0
	water._process(6.0) # store ~30 mL in rain collector
	vitals.rain_intensity = 0.0
	var pre_rc_water := float(water.get_collector(rc_uid)["stored_water"])
	var pre_shell_water := float(inv.get_container_water(shell_slot)["amount"])
	var save_res := _survival.perform_save()
	_check(bool(save_res.get("ok", false)), "Saved game with vitals, containers, berry bush, and rain collector")

	_survival.perform_new_game()
	await _pump(4)
	_check(vitals.hunger >= 99.5 and vitals.thirst >= 99.5 and water.get_collector_count() == 0, "New Game reset vitals and cleared rain collectors")

	var load_res := _survival.perform_load()
	_check(bool(load_res.get("ok", false)), "Reloaded saved game")
	await _pump(4)
	_check(absf(vitals.hunger - 62.5) < 0.5 and absf(vitals.thirst - 48.0) < 0.5, "Hunger (%.1f) and Thirst (%.1f) persisted" % [vitals.hunger, vitals.thirst])
	_check(water.get_collector_count() == 1 and absf(float(water.get_collector(rc_uid)["stored_water"]) - pre_rc_water) < 0.5, "Rain collector and stored water (%.1f mL) persisted" % pre_rc_water)
	var reloaded_shell := inv.find_container_slot(false, true)
	_check(reloaded_shell >= 0 and absf(float(inv.get_container_water(reloaded_shell)["amount"]) - pre_shell_water) < 0.5, "Coconut Shell water level (%.1f mL) persisted" % pre_shell_water)
	_check(_survival.resources.is_depleted(String(bush_target["id"])), "Harvested Berry Bush regeneration state persisted")

	# Clean up test save file.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_survival.save_system.save_path))

	_step("7. Debug Readout Verification")
	_survival.hud.toggle_debug_panel()
	await _pump(2)
	_check(_survival.hud._debug_panel.visible and _survival.hud._debug_label.text.contains("Hunger:") and _survival.hud._debug_label.text.contains("Thirst:"), "Survival debug readout displays live vitals & modifiers")

	print("[vitals-test] SUMMARY failures=%d" % _failures.size())
	if not _failures.is_empty():
		for f in _failures:
			push_error("[vitals-test] FAIL: " + f)
		quit(1)
		return
	print("[vitals-test] ALL CHECKS PASSED")
	quit(0)


func _step(label: String) -> void:
	print("[vitals-test] --- %s ---" % label)


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[vitals-test] PASS: ", msg)
	else:
		print("[vitals-test] FAIL: ", msg)
		_failures.append(msg)


func _pump(frames: int) -> void:
	for _i in frames:
		await process_frame


func _move_player_to(xz_target: Vector3) -> void:
	var h: float = _terrain.data.get_height(xz_target)
	var y: float = h + 0.15 if is_finite(h) else xz_target.y
	_player.global_position = Vector3(xz_target.x, y, xz_target.z)
	_player.velocity = Vector3.ZERO


func _find_nearest_vec3(points: Array[Vector3], origin: Vector3) -> Vector3:
	var best := Vector3.INF
	var best_d2 := INF
	for p in points:
		var d2 := Vector2(p.x - origin.x, p.z - origin.z).length_squared()
		if d2 < best_d2:
			best_d2 = d2
			best = p
	return best


func _find_item_slot(inv: InventorySystem, item_id: StringName) -> int:
	for i in inv.slots.size():
		if inv.slots[i].get("item_id", &"") == item_id:
			return i
	return -1


func _find_ocean_shore_pos() -> Vector3:
	for z in range(630, 720, 4):
		var p := Vector3(70.0, 0.0, float(z))
		var h: float = _terrain.data.get_height(p)
		if is_finite(h) and h <= 0.45 and h >= -0.4:
			return Vector3(p.x, h, p.z)
	return Vector3.INF
