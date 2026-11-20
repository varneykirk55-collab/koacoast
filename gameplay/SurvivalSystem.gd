class_name SurvivalSystem
extends Node
## Top-level gameplay coordinator connecting Inventory, Crafting, Resource Gathering,
## Sparkling Beach Collectibles, Modular Building, Navigation Maps, Audio, Save/Load, and HUD.

@export var terrain_path: NodePath = NodePath("../Terrain3D")
@export var player_path: NodePath = NodePath("../Player")

var database: GameDatabase
var inventory: InventorySystem
var crafting: CraftingSystem
var resources: ResourceGatherSystem
var collectibles: BeachCollectibleSystem
var buildings: BuildingSystem
var vitals: SurvivalVitalsSystem
var water_system: WaterSystem
var day_night: DayNightSystem
var wildlife: WildlifeSystem
var death_recovery: DeathRecoverySystem
var save_system: SaveSystem
var audio: AudioFeedback
var hud: SurvivalHUD

var _terrain: Terrain3D
var _player: Node3D
var _current_target: Dictionary = {} # { "type": "resource"|"collectible"|"door", "data": ... }
var _map_initialized := false


func _ready() -> void:
	InputConfig.ensure_actions()
	database = GameDatabase.new()
	_terrain = get_node_or_null(terrain_path) as Terrain3D
	_player = get_node_or_null(player_path) as Node3D

	inventory = InventorySystem.new()
	inventory.name = "InventorySystem"
	add_child(inventory)
	inventory.setup(database)

	crafting = CraftingSystem.new()
	crafting.name = "CraftingSystem"
	add_child(crafting)
	crafting.setup(database, inventory)

	audio = AudioFeedback.new()
	audio.name = "AudioFeedback"
	add_child(audio)

	resources = ResourceGatherSystem.new()
	resources.name = "ResourceGatherSystem"
	add_child(resources)
	resources.setup(_terrain, inventory, database)

	collectibles = BeachCollectibleSystem.new()
	collectibles.name = "BeachCollectibleSystem"
	add_child(collectibles)
	collectibles.setup(_terrain, inventory, database)

	buildings = BuildingSystem.new()
	buildings.name = "BuildingSystem"
	add_child(buildings)
	buildings.setup(_terrain, inventory, database, _player)

	vitals = SurvivalVitalsSystem.new()
	vitals.name = "SurvivalVitalsSystem"
	add_child(vitals)
	vitals.setup(_player as CharacterBody3D)

	water_system = WaterSystem.new()
	water_system.name = "WaterSystem"
	add_child(water_system)
	water_system.setup(_terrain, vitals, inventory, resources)

	day_night = DayNightSystem.new()
	day_night.name = "DayNightSystem"
	add_child(day_night)
	day_night.setup(
		get_node_or_null("../LateMorningSun") as DirectionalLight3D,
		get_node_or_null("../TradeWindSky") as WorldEnvironment,
		vitals,
		get_node_or_null("../IslandAudio")
	)

	wildlife = WildlifeSystem.new()
	wildlife.name = "WildlifeSystem"
	add_child(wildlife)
	wildlife.setup(_terrain, _player, day_night, buildings, vitals, audio)

	death_recovery = DeathRecoverySystem.new()
	death_recovery.name = "DeathRecoverySystem"
	add_child(death_recovery)
	death_recovery.setup(_terrain, _player, inventory, buildings, vitals, day_night, wildlife)

	save_system = SaveSystem.new()
	save_system.name = "SaveSystem"
	add_child(save_system)
	if _player:
		save_system.set_spawn_position(_player.global_position)

	hud = SurvivalHUD.new()
	hud.name = "SurvivalHUD"
	add_child(hud)
	hud.inv_panel.setup(database, inventory, crafting)

	_connect_signals()
	_init_navigation_map.call_deferred()


func _connect_signals() -> void:
	inventory.inventory_full.connect(_on_inventory_full)
	vitals.critical_warning.connect(_on_critical_warning)
	if wildlife:
		wildlife.wildlife_warning.connect(_on_wildlife_warning)
	if day_night:
		day_night.phase_changed.connect(_on_phase_changed)
	if death_recovery:
		death_recovery.death_started.connect(_on_death_started)
		death_recovery.player_respawned.connect(_on_player_respawned)
	hud.inv_panel.close_requested.connect(_close_all_modals)
	hud.inv_panel.craft_requested.connect(_on_craft_requested)
	hud.inv_panel.use_slot_requested.connect(use_inventory_slot)
	hud.map_overlay.close_requested.connect(_close_all_modals)
	hud.system_menu.resume_requested.connect(_close_all_modals)
	hud.system_menu.save_requested.connect(perform_save)
	hud.system_menu.load_requested.connect(perform_load)
	hud.system_menu.new_game_requested.connect(perform_new_game)
	buildings.build_mode_changed.connect(_on_build_mode_changed)


func _init_navigation_map() -> void:
	for _i in 3:
		await get_tree().process_frame
	if _terrain:
		var map_data := IslandMapGenerator.generate_map(_terrain)
		hud.set_map_data(map_data["texture"], map_data["world_rect"])
		_map_initialized = true


func _process(_delta: float) -> void:
	if _player == null:
		return
	var dying := death_recovery != null and death_recovery.is_death_in_progress()
	var modal_open := hud.is_any_modal_open()
	_sync_player_input_flags(modal_open or dying)

	if vitals and crafting:
		crafting.set_craft_time_multiplier(vitals.get_crafting_duration_multiplier())

	var facing := _get_player_facing()
	if _map_initialized:
		hud.update_navigation(_player.global_position, facing, buildings.get_base_markers())
	if death_recovery:
		hud.update_recovery_indicator(death_recovery.get_latest_cache_indicator(_player.global_position))
	if vitals:
		var dbg := vitals.get_debug_summary()
		if day_night:
			dbg += "\n" + day_night.get_clock_string()
		if wildlife:
			dbg += "\n" + wildlife.get_debug_summary()
		hud.update_debug_vitals(dbg)

	if modal_open or dying:
		_current_target.clear()
		hud.set_interaction_prompt("")
		hud.update_build_hud(false, database.building_piece_order, buildings.selected_index, buildings.selected_material_id, database, inventory, {})
		return

	if buildings.build_mode:
		hud.update_build_hud(true, database.building_piece_order, buildings.selected_index, buildings.selected_material_id, database, inventory, buildings.get_preview_status())
	else:
		hud.update_build_hud(false, database.building_piece_order, buildings.selected_index, buildings.selected_material_id, database, inventory, {})

	_update_interaction_target(facing)


func _unhandled_input(event: InputEvent) -> void:
	if death_recovery and death_recovery.is_death_in_progress():
		return
	if event.is_action_pressed("quick_save"):
		perform_save()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("quick_load"):
		perform_load()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("debug_toggle_vitals"):
		hud.toggle_debug_panel()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("debug_toggle_rain"):
		var next_rain := 0.0 if vitals.rain_intensity > 0.1 else 1.0
		vitals.rain_intensity = next_rain
		hud.push_toast("Debug Rain: %s" % ("ON (100%)" if next_rain > 0.5 else "OFF"), Color(0.65, 0.88, 1.0))
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("debug_drain_vitals"):
		vitals.hunger = maxf(0.0, vitals.hunger - 25.0)
		vitals.thirst = maxf(0.0, vitals.thirst - 25.0)
		vitals.step_simulation(0.01)
		hud.push_toast("Debug Drain: Hunger %.0f%% | Thirst %.0f%%" % [vitals.hunger, vitals.thirst], Color(1.0, 0.78, 0.42))
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("debug_advance_time"):
		if day_night:
			day_night.advance_time(60.0)
			hud.push_toast("Debug Time (+1m): %s" % day_night.get_clock_string(), Color(0.86, 0.90, 1.0))
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("debug_toggle_day_night"):
		if day_night:
			day_night.toggle_day_night()
			hud.push_toast("Debug Cycle: %s" % day_night.get_clock_string(), Color(0.82, 0.88, 1.0))
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("debug_trigger_shelter_threat"):
		if wildlife:
			var tr := wildlife.trigger_shelter_threat_test()
			if not bool(tr.get("ok", false)):
				hud.push_toast("Debug Threat: %s" % String(tr.get("reason", "Failed")), Color(0.98, 0.55, 0.45))
		get_viewport().set_input_as_handled()
		return

	var modal_open := hud.is_any_modal_open()
	if modal_open:
		if event.is_action_pressed("ui_cancel"):
			_close_all_modals()
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("toggle_inventory") and hud.inv_panel.visible:
			_close_all_modals()
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("toggle_map") and hud.map_overlay.visible:
			_close_all_modals()
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("toggle_system_menu") and hud.system_menu.visible:
			_close_all_modals()
			get_viewport().set_input_as_handled()
		return

	if event.is_action_pressed("toggle_inventory"):
		buildings.set_build_mode(false)
		hud.inv_panel.open_panel()
		_sync_player_input_flags(true)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("toggle_map"):
		buildings.set_build_mode(false)
		hud.map_overlay.open_map()
		_sync_player_input_flags(true)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("toggle_system_menu"):
		buildings.set_build_mode(false)
		hud.system_menu.open_menu(save_system.has_save())
		_sync_player_input_flags(true)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("toggle_build_mode"):
		buildings.set_build_mode(not buildings.build_mode)
		get_viewport().set_input_as_handled()
		return

	if buildings.build_mode:
		if _handle_build_input(event):
			get_viewport().set_input_as_handled()
			return

	if event.is_action_pressed("interact"):
		perform_interact()
		get_viewport().set_input_as_handled()
		return

	if event.is_action_pressed("ui_cancel"):
		hud.system_menu.open_menu(save_system.has_save())
		_sync_player_input_flags(true)
		get_viewport().set_input_as_handled()


func _handle_build_input(event: InputEvent) -> bool:
	if event.is_action_pressed("build_cancel") or event.is_action_pressed("ui_cancel"):
		buildings.set_build_mode(false)
		return true
	if event.is_action_pressed("build_confirm"):
		var res := buildings.try_place_current()
		if res["ok"]:
			audio.play(&"build")
			var pdef := database.get_building_piece(res["piece_id"])
			var mdef := database.get_building_material(res.get("material_id", &"wood"))
			var mname := mdef.display_name if mdef else ""
			var pname := pdef.display_name if pdef else "Structure"
			hud.push_toast("Placed %s %s" % [mname, pname], Color(0.75, 0.96, 0.72))
		else:
			audio.play(&"error")
			hud.push_toast(String(res.get("reason", "Cannot place here")), Color(0.98, 0.45, 0.45))
		return true
	if event.is_action_pressed("build_remove"):
		var res := buildings.try_remove_targeted()
		if res["ok"]:
			audio.play(&"remove")
			hud.push_toast("Removed structure" + (" (item refunded)" if res.get("refunded", false) else ""), Color(0.95, 0.86, 0.62))
		else:
			audio.play(&"error")
			hud.push_toast(String(res.get("reason", "Nothing to remove")), Color(0.95, 0.55, 0.45))
		return true
	if event.is_action_pressed("build_rotate_cw"):
		buildings.rotate_piece(1)
		return true
	if event.is_action_pressed("build_rotate_ccw"):
		buildings.rotate_piece(-1)
		return true
	if event.is_action_pressed("build_prev_piece"):
		buildings.cycle_piece(-1)
		return true
	if event.is_action_pressed("build_next_piece"):
		buildings.cycle_piece(1)
		return true
	if event.is_action_pressed("build_cycle_material"):
		buildings.cycle_material(1)
		var mdef := database.get_building_material(buildings.selected_material_id)
		hud.push_toast("Build Material: %s" % (mdef.display_name if mdef else String(buildings.selected_material_id)), Color(0.84, 0.92, 0.98))
		return true
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			buildings.cycle_piece(-1)
			return true
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			buildings.cycle_piece(1)
			return true
	if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		var kc: Key = (event as InputEventKey).physical_keycode
		if kc >= KEY_1 and kc <= KEY_7:
			buildings.select_piece_by_index(int(kc - KEY_1))
			return true
	return false


func perform_interact() -> Dictionary:
	if _current_target.is_empty():
		return { "ok": false, "reason": "nothing_nearby" }
	var ttype: String = _current_target["type"]
	match ttype:
		"death_cache":
			var cache_data: Dictionary = _current_target["data"]
			var rec_res := death_recovery.recover_cache(String(cache_data["uid"]))
			if bool(rec_res.get("fully_emptied", false)):
				audio.play(&"sparkle")
				hud.push_toast("Recovered all equipment from Death Cache!", Color(0.72, 0.96, 0.72))
			elif int(rec_res.get("recovered_items", 0)) > 0:
				audio.play(&"gather")
				hud.push_toast("Recovered %d item(s) — %d left in cache (Bag Full)" % [int(rec_res["recovered_items"]), int(rec_res["remaining_items"])], Color(1.0, 0.80, 0.44))
			else:
				audio.play(&"error")
				hud.push_toast("Inventory full! Free space to recover Death Cache.", Color(0.98, 0.50, 0.42))
			return rec_res
		"collectible":
			var res := collectibles.collect(_current_target["data"])
			if res["ok"]:
				audio.play(&"sparkle")
				var item_def := database.get_item(res["item_id"])
				var nm := item_def.display_name if item_def else String(res["item_id"])
				hud.push_toast("+%d %s" % [int(res["amount"]), nm], Color(1.0, 0.94, 0.62))
			elif res.get("reason") == "inventory_full":
				audio.play(&"error")
			return res
		"door":
			var door_data: Dictionary = _current_target["data"]
			if buildings.toggle_door(String(door_data["uid"])):
				audio.play(&"door")
				return { "ok": true, "door_open": door_data["door_open"] }
			return { "ok": false }
		"campfire":
			var fire_data: Dictionary = _current_target["data"]
			if buildings.toggle_campfire(String(fire_data["uid"])):
				var is_lit := bool(fire_data.get("lit", true))
				audio.play(&"craft" if is_lit else &"remove")
				hud.push_toast("Campfire Lit" if is_lit else "Campfire Extinguished", Color(1.0, 0.80, 0.45))
				return { "ok": true, "lit": is_lit }
			return { "ok": false }
		"reinforce":
			var wall_data: Dictionary = _current_target["data"]
			var r_res := buildings.reinforce_piece(String(wall_data["uid"]), true)
			if bool(r_res.get("ok", false)):
				audio.play(&"build")
				hud.push_toast("Reinforced Shelter Wall (%.0f HP)" % float(r_res.get("max_hp", 0.0)), Color(0.76, 0.96, 0.72))
			else:
				audio.play(&"error")
				hud.push_toast(String(r_res.get("reason", "Need 2 Wood + 2 Stone to reinforce")), Color(0.98, 0.55, 0.45))
			return r_res
		"resource":
			var res := resources.harvest(_current_target["data"])
			if res["ok"]:
				audio.play(&"gather")
				if vitals and res.has("kind"):
					vitals.register_harvest_activity(res["kind"])
				for drop: Dictionary in res["drops"]:
					var item_def := database.get_item(drop["item_id"])
					var nm := item_def.display_name if item_def else String(drop["item_id"])
					hud.push_toast("+%d %s" % [int(drop["amount"]), nm], Color(0.80, 0.96, 0.78))
			elif res.get("reason") == "inventory_full":
				audio.play(&"error")
			return res
		"rain_collector":
			var col_data: Dictionary = _current_target["data"]
			var uid := String(col_data["uid"])
			var slot_idx := inventory.find_container_slot(true, false)
			if slot_idx >= 0 and float(col_data.get("stored_water", 0.0)) > 0.1:
				var tr := water_system.transfer_to_container(uid)
				if tr["ok"]:
					audio.play(&"sparkle")
					hud.push_toast("Filled Container (+%.0f mL %s)" % [float(tr["transferred"]), WaterQuality.get_label(int(tr["quality"]))], Color(0.55, 0.90, 1.0))
				else:
					audio.play(&"error")
					hud.push_toast(String(tr.get("reason", "Cannot fill")), Color(0.98, 0.55, 0.45))
				return tr
			var dr := water_system.drink_from_collector(uid)
			if dr.get("ok", false):
				audio.play(&"sparkle" if bool(dr.get("safe", false)) else &"error")
				hud.push_toast(String(dr.get("message", "Drank water")), Color(0.55, 0.92, 1.0) if bool(dr.get("safe", false)) else Color(1.0, 0.42, 0.35))
			else:
				audio.play(&"error")
				hud.push_toast(String(dr.get("reason", "Rain collector is empty")), Color(0.95, 0.72, 0.45))
			return dr
		"water_source":
			var src: Dictionary = _current_target["data"]
			var quality := int(src["quality"])
			var slot_idx := inventory.find_container_slot(true, false)
			if slot_idx >= 0 and WaterQuality.is_safe(quality):
				var added := inventory.fill_container(slot_idx, 100.0, quality)
				if added > 0.0:
					audio.play(&"sparkle")
					hud.push_toast("Filled Coconut Shell (+%.0f mL %s)" % [added, WaterQuality.get_label(quality)], Color(0.55, 0.92, 1.0))
					return { "ok": true, "filled": added, "quality": quality }
			var eff := vitals.drink_water(32.0, quality)
			audio.play(&"sparkle" if bool(eff["safe"]) else &"error")
			hud.push_toast(String(eff["message"]), Color(0.55, 0.92, 1.0) if bool(eff["safe"]) else Color(1.0, 0.40, 0.35))
			eff["ok"] = true
			return eff
	return { "ok": false }


func use_inventory_slot(slot_idx: int) -> Dictionary:
	var slot := inventory.get_slot(slot_idx)
	if slot.is_empty():
		return { "ok": false, "reason": "empty_slot" }
	var item_id := StringName(slot["item_id"])
	var def := database.get_item(item_id)
	if def == null:
		return { "ok": false, "reason": "unknown_item" }

	if def.category == &"food":
		if not inventory.remove_item(item_id, 1):
			return { "ok": false, "reason": "remove_failed" }
		var res := vitals.eat_food(def.hunger_restore, def.thirst_restore)
		audio.play(&"gather")
		hud.push_toast("Ate %s (+%.0f Hunger)" % [def.display_name, float(res["hunger_restored"])], Color(0.75, 0.96, 0.65))
		res["ok"] = true
		return res

	if def.water_capacity > 0.0:
		var drained := inventory.drain_container(slot_idx, 50.0)
		var vol := float(drained["drained"])
		if vol <= 0.01:
			audio.play(&"error")
			hud.push_toast("%s is empty." % def.display_name, Color(0.96, 0.72, 0.42))
			return { "ok": false, "reason": "empty_container" }
		var eff := vitals.drink_water(vol, int(drained["quality"]))
		audio.play(&"sparkle" if bool(eff["safe"]) else &"error")
		hud.push_toast(String(eff["message"]), Color(0.55, 0.92, 1.0) if bool(eff["safe"]) else Color(1.0, 0.42, 0.35))
		eff["ok"] = true
		return eff

	if item_id == &"rain_tarp":
		var place_pos := _player.global_position + _get_player_facing() * 2.6
		var res := water_system.place_rain_collector(place_pos, 0.0, true)
		if res["ok"]:
			audio.play(&"build")
			_close_all_modals()
			var anchor_txt := " (anchored between trees)" if bool(res.get("anchored_to_trees", false)) else " (anchored on poles)"
			hud.push_toast("Placed Rainwater Collection Tarp" + anchor_txt, Color(0.68, 0.95, 0.78))
		else:
			audio.play(&"error")
			hud.push_toast(String(res.get("reason", "Cannot place rain tarp here")), Color(0.98, 0.45, 0.45))
		return res

	if item_id == &"campfire":
		var place_pos := _player.global_position + _get_player_facing() * 2.4
		var res := buildings.place_campfire(place_pos, true)
		if res["ok"]:
			audio.play(&"build")
			_close_all_modals()
			hud.push_toast("Placed & Lit Campfire", Color(1.0, 0.80, 0.44))
		else:
			audio.play(&"error")
			hud.push_toast(String(res.get("reason", "Cannot place campfire here")), Color(0.98, 0.45, 0.45))
		return res

	return { "ok": false, "reason": "not_usable" }


func perform_save() -> Dictionary:
	var res := save_system.save_game(_player, inventory, resources, collectibles, buildings, vitals, water_system, day_night, death_recovery)
	if res["ok"]:
		audio.play(&"craft")
		hud.push_toast("Progress Saved!", Color(0.65, 0.95, 0.78))
		hud.system_menu.set_status("Saved successfully.")
	else:
		audio.play(&"error")
		hud.push_toast("Save failed: %s" % String(res.get("reason", "")), Color(0.98, 0.45, 0.45))
	return res


func perform_load() -> Dictionary:
	var res := save_system.load_game(_player, inventory, resources, collectibles, buildings, vitals, water_system, day_night, death_recovery)
	if res["ok"]:
		audio.play(&"craft")
		hud.push_toast("Saved Game Loaded!", Color(0.70, 0.92, 1.0))
		_close_all_modals()
	else:
		audio.play(&"error")
		var msg := String(res.get("reason", "Failed to load"))
		hud.push_toast(msg, Color(0.98, 0.45, 0.45))
		hud.system_menu.set_status(msg)
	return res


func perform_new_game() -> void:
	save_system.new_game(_player, inventory, resources, collectibles, buildings, false, vitals, water_system, day_night, death_recovery)
	if wildlife:
		wildlife.reset_all()
	hud.hide_death_banner()
	_close_all_modals()
	hud.push_toast("Started New Game", Color(0.96, 0.92, 0.72))


func _on_craft_requested(recipe_id: StringName) -> void:
	if crafting.craft(recipe_id):
		audio.play(&"craft")
		var rec := database.get_recipe(recipe_id)
		if rec:
			hud.push_toast("Crafted %s!" % rec.display_name, Color(0.70, 0.95, 0.82))
	else:
		audio.play(&"error")
		var eval := crafting.evaluate_recipe(recipe_id)
		if eval["inventory_full"]:
			hud.push_toast("Cannot craft: Inventory is full!", Color(0.98, 0.50, 0.42))
		else:
			hud.push_toast("Missing required materials.", Color(0.98, 0.55, 0.45))


func _on_inventory_full(_item_id: StringName) -> void:
	hud.push_toast("Inventory full! Free up space to gather more.", Color(1.0, 0.52, 0.38))


func _on_critical_warning(_category: StringName, message: String) -> void:
	audio.play(&"error")
	hud.push_toast(message, Color(1.0, 0.42, 0.32))


func _on_wildlife_warning(category: StringName, message: String, _world_pos: Vector3) -> void:
	var col := Color(1.0, 0.76, 0.38)
	if category == &"shark_bite" or category == &"shelter_breach" or category == &"shark_warning":
		col = Color(1.0, 0.38, 0.32)
	elif category == &"campfire_deter" or category == &"shelter_held":
		col = Color(0.68, 0.95, 0.74)
	hud.push_toast(message, col)


func _on_phase_changed(new_phase: StringName, day_num: int) -> void:
	if new_phase == &"night":
		hud.push_toast("Night falls on Day %d — wildlife grows bolder." % day_num, Color(0.68, 0.78, 1.0))
	elif new_phase == &"sunrise" and day_num > 1:
		hud.push_toast("Day %d — Sunrise over KoaCoast." % day_num, Color(1.0, 0.88, 0.62))


func _on_death_started(_cause: StringName, cause_label: String, _cache_uid: String) -> void:
	buildings.set_build_mode(false)
	crafting.cancel_timed_craft()
	hud.inv_panel.close_panel()
	hud.map_overlay.close_map()
	hud.system_menu.close_menu()
	audio.play(&"error")
	hud.show_death_banner(cause_label)


func _on_player_respawned(_respawn_info: Dictionary, _latest_cache_uid: String) -> void:
	hud.hide_death_banner()
	hud.show_respawn_banner()
	audio.play(&"craft")


func _on_build_mode_changed(active: bool) -> void:
	if _player and "build_mode_active" in _player:
		_player.set("build_mode_active", active)
	hud.push_toast("Building Mode ON" if active else "Building Mode OFF", Color(0.82, 0.96, 0.80))


func _close_all_modals() -> void:
	hud.inv_panel.close_panel()
	hud.map_overlay.close_map()
	hud.system_menu.close_menu()
	_sync_player_input_flags(false)
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _sync_player_input_flags(modal_open: bool) -> void:
	if _player == null:
		return
	if "gameplay_input_blocked" in _player:
		_player.set("gameplay_input_blocked", modal_open)
	if "build_mode_active" in _player:
		_player.set("build_mode_active", buildings.build_mode)
	if DisplayServer.get_name() != "headless" and modal_open:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _update_interaction_target(facing: Vector3) -> void:
	var p := _player.global_position
	var cache_entry := death_recovery.find_nearest_cache(p) if death_recovery else {}
	var col_spot := collectibles.find_nearest_collectible(p)
	var door_entry := buildings.find_nearest_door(p)
	var campfire_entry := buildings.find_nearest_campfire(p)
	var reinforce_entry := buildings.find_nearest_reinforceable(p)
	var rain_col := water_system.find_nearest_collector(p)
	var res_node := resources.find_nearest_target(p, facing)

	var best_type := ""
	var best_data: Dictionary = {}
	var best_dist := INF

	if not cache_entry.is_empty():
		var d := (cache_entry["pos"] as Vector3).distance_to(p)
		if d < best_dist:
			best_dist = d
			best_type = "death_cache"
			best_data = cache_entry
	if not col_spot.is_empty():
		var d := (col_spot["pos"] as Vector3).distance_to(p)
		if d < best_dist:
			best_dist = d
			best_type = "collectible"
			best_data = col_spot
	if not door_entry.is_empty():
		var d := (door_entry["pos"] as Vector3).distance_to(p)
		if d < best_dist:
			best_dist = d
			best_type = "door"
			best_data = door_entry
	if not campfire_entry.is_empty():
		var d := (campfire_entry["pos"] as Vector3).distance_to(p)
		if d < best_dist:
			best_dist = d
			best_type = "campfire"
			best_data = campfire_entry
	if not rain_col.is_empty():
		var d := (rain_col["pos"] as Vector3).distance_to(p)
		if d < best_dist:
			best_dist = d
			best_type = "rain_collector"
			best_data = rain_col
	if not res_node.is_empty() and not buildings.build_mode:
		var d := (res_node["pos"] as Vector3).distance_to(p)
		if d < best_dist:
			best_dist = d
			best_type = "resource"
			best_data = res_node
	if not reinforce_entry.is_empty() and not buildings.build_mode:
		var d := (reinforce_entry["pos"] as Vector3).distance_to(p)
		if d < best_dist:
			best_dist = d
			best_type = "reinforce"
			best_data = reinforce_entry

	if best_type == "" and not buildings.build_mode:
		var water_src := water_system.detect_water_source(p)
		if not water_src.is_empty():
			best_type = "water_source"
			best_data = water_src

	if best_type == "":
		_current_target.clear()
		hud.set_interaction_prompt("")
		return

	_current_target = { "type": best_type, "data": best_data }
	match best_type:
		"death_cache":
			var item_cnt := 0
			for it in best_data.get("items", []):
				if it is Dictionary:
					item_cnt += int(it.get("amount", 0))
			hud.set_interaction_prompt("Recover Death Cache (%d items)" % item_cnt)
		"collectible":
			hud.set_interaction_prompt(collectibles.get_prompt_for_spot(best_data))
		"door":
			var is_open := bool(best_data.get("door_open", false))
			hud.set_interaction_prompt("Close Door" if is_open else "Open Door")
		"campfire":
			var is_lit := bool(best_data.get("lit", true))
			hud.set_interaction_prompt("Extinguish Campfire" if is_lit else "Light Campfire")
		"reinforce":
			var hp := float(best_data.get("hp", 0.0))
			var mhp := float(best_data.get("max_hp", 1.0))
			hud.set_interaction_prompt("Reinforce Wall (2 Wood, 2 Stone) [%.0f/%.0f HP]" % [hp, mhp])
		"rain_collector":
			var stored := float(best_data.get("stored_water", 0.0))
			if stored <= 0.1:
				hud.set_interaction_prompt("Rain Tarp (Empty — wait for rain)")
			elif inventory.find_container_slot(true, false) >= 0:
				hud.set_interaction_prompt("Fill Shell from Rain Tarp (%.0f mL)" % stored)
			else:
				hud.set_interaction_prompt("Drink Rainwater (%.0f mL)" % stored)
		"water_source":
			var q := int(best_data["quality"])
			if not WaterQuality.is_safe(q):
				hud.set_interaction_prompt("Drink %s (Unsafe!)" % String(best_data["label"]))
			elif inventory.find_container_slot(true, false) >= 0:
				hud.set_interaction_prompt("Fill Coconut Shell (%s)" % String(best_data["label"]))
			else:
				hud.set_interaction_prompt("Drink %s" % String(best_data["label"]))
		"resource":
			hud.set_interaction_prompt(resources.get_prompt_for_target(best_data))


func _get_player_facing() -> Vector3:
	if _player == null:
		return Vector3.FORWARD
	var visual := _player.get_node_or_null("Visual") as Node3D
	if visual:
		return visual.global_basis.z.normalized()
	return Vector3.FORWARD
