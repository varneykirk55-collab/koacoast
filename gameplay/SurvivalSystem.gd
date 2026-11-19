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
	hud.inv_panel.close_requested.connect(_close_all_modals)
	hud.inv_panel.craft_requested.connect(_on_craft_requested)
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
	var modal_open := hud.is_any_modal_open()
	_sync_player_input_flags(modal_open)

	var facing := _get_player_facing()
	if _map_initialized:
		hud.update_navigation(_player.global_position, facing, buildings.get_base_markers())

	if modal_open:
		_current_target.clear()
		hud.set_interaction_prompt("")
		hud.update_build_hud(false, database.building_piece_order, buildings.selected_index, database, inventory, {})
		return

	if buildings.build_mode:
		hud.update_build_hud(true, database.building_piece_order, buildings.selected_index, database, inventory, buildings.get_preview_status())
	else:
		hud.update_build_hud(false, database.building_piece_order, buildings.selected_index, database, inventory, {})

	_update_interaction_target(facing)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("quick_save"):
		perform_save()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("quick_load"):
		perform_load()
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
			hud.push_toast("Placed %s" % (pdef.display_name if pdef else "Structure"), Color(0.75, 0.96, 0.72))
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
		"resource":
			var res := resources.harvest(_current_target["data"])
			if res["ok"]:
				audio.play(&"gather")
				for drop: Dictionary in res["drops"]:
					var item_def := database.get_item(drop["item_id"])
					var nm := item_def.display_name if item_def else String(drop["item_id"])
					hud.push_toast("+%d %s" % [int(drop["amount"]), nm], Color(0.80, 0.96, 0.78))
			elif res.get("reason") == "inventory_full":
				audio.play(&"error")
			return res
	return { "ok": false }


func perform_save() -> Dictionary:
	var res := save_system.save_game(_player, inventory, resources, collectibles, buildings)
	if res["ok"]:
		audio.play(&"craft")
		hud.push_toast("Progress Saved!", Color(0.65, 0.95, 0.78))
		hud.system_menu.set_status("Saved successfully.")
	else:
		audio.play(&"error")
		hud.push_toast("Save failed: %s" % String(res.get("reason", "")), Color(0.98, 0.45, 0.45))
	return res


func perform_load() -> Dictionary:
	var res := save_system.load_game(_player, inventory, resources, collectibles, buildings)
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
	save_system.new_game(_player, inventory, resources, collectibles, buildings, false)
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
	var col_spot := collectibles.find_nearest_collectible(p)
	var door_entry := buildings.find_nearest_door(p)
	var res_node := resources.find_nearest_target(p, facing)

	var best_type := ""
	var best_data: Dictionary = {}
	var best_dist := INF

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
	if not res_node.is_empty() and not buildings.build_mode:
		var d := (res_node["pos"] as Vector3).distance_to(p)
		if d < best_dist:
			best_dist = d
			best_type = "resource"
			best_data = res_node

	if best_type == "":
		_current_target.clear()
		hud.set_interaction_prompt("")
		return

	_current_target = { "type": best_type, "data": best_data }
	match best_type:
		"collectible":
			hud.set_interaction_prompt(collectibles.get_prompt_for_spot(best_data))
		"door":
			var is_open := bool(best_data.get("door_open", false))
			hud.set_interaction_prompt("Close Door" if is_open else "Open Door")
		"resource":
			hud.set_interaction_prompt(resources.get_prompt_for_target(best_data))


func _get_player_facing() -> Vector3:
	if _player == null:
		return Vector3.FORWARD
	var visual := _player.get_node_or_null("Visual") as Node3D
	if visual:
		return visual.global_basis.z.normalized()
	return Vector3.FORWARD
