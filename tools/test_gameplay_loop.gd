extends SceneTree
## End-to-end automated playtest of KoaCoast's survival-building gameplay loop
## in the actual KoaCoast.tscn scene.
## Run:
##   godot --headless --path . --script res://tools/test_gameplay_loop.gd

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
	_survival.save_system.save_path = "user://koacoast_playtest_save.json"

	# Allow deferred systems (scenery, resources, beach collectibles, map) to initialize.
	for _i in 20:
		await process_frame

	_step("1. Spawn & Systems Ready")
	_check(_player.is_on_floor(), "Kekoa is standing on Terrain3D at spawn")
	_check(_survival.inventory != null and _survival.crafting != null, "Inventory & Crafting initialized")
	_check(_survival.resources != null and _survival.collectibles != null, "Resource & Collectible systems initialized")
	_check(_survival.buildings != null and _survival.hud != null, "Building & HUD initialized")
	_check(InputMap.has_action("interact") and InputMap.has_action("toggle_build_mode"), "Gameplay InputMap actions registered")

	_step("2. Gather Wood from Tree / Branch")
	var tree_pos := _find_nearest_resource_pos(&"tree", _player.global_position)
	_check(tree_pos != Vector3.INF, "Found tree resource on island (at %s)" % tree_pos)
	_move_player_to(tree_pos + Vector3(1.5, 0.0, 0.0))
	await _pump(4)
	var tree_target := _survival.resources.find_nearest_target(_player.global_position, Vector3.FORWARD)
	_check(not tree_target.is_empty() and tree_target.get("kind") == &"tree", "Detected nearby harvestable tree (%s)" % String(tree_target.get("kind", "")))
	var wood_res := _survival.resources.harvest(tree_target)
	_check(bool(wood_res.get("ok", false)), "Harvested wood from tree")
	_check(_survival.inventory.get_count(&"wood") >= 2, "Wood added to inventory (%d)" % _survival.inventory.get_count(&"wood"))
	# Verify repeat collection exploit prevention.
	var repeat_res := _survival.resources.harvest(tree_target)
	_check(not bool(repeat_res.get("ok", false)) and repeat_res.get("reason") == "depleted", "Prevented repeat collection exploit on depleted node")

	_step("3. Gather Stone, Plant Fiber, and Leaves")
	var rock_pos := _find_nearest_resource_pos(&"rock", _player.global_position)
	_check(rock_pos != Vector3.INF, "Found stone deposit")
	_move_player_to(rock_pos + Vector3(1.2, 0.0, 0.0))
	await _pump(4)
	var rock_target := _survival.resources.find_nearest_target(_player.global_position, Vector3.FORWARD)
	_check(not rock_target.is_empty() and rock_target.get("kind") == &"rock", "Detected stone deposit (%s)" % String(rock_target.get("kind", "")))
	var stone_res := _survival.resources.harvest(rock_target)
	_check(bool(stone_res.get("ok", false)) and _survival.inventory.get_count(&"stone") >= 2, "Harvested stone (%d)" % _survival.inventory.get_count(&"stone"))

	var grass_pos := _find_nearest_resource_pos(&"grass", _player.global_position)
	_check(grass_pos != Vector3.INF, "Found grass / sedge for plant fiber")
	_move_player_to(grass_pos + Vector3(0.4, 0.0, 0.0))
	await _pump(4)
	var grass_target := _survival.resources.find_nearest_target(_player.global_position, Vector3.FORWARD)
	var fiber_res := _survival.resources.harvest(grass_target)
	_check(bool(fiber_res.get("ok", false)) and _survival.inventory.get_count(&"plant_fiber") >= 2, "Harvested plant fiber (%d)" % _survival.inventory.get_count(&"plant_fiber"))

	var plant_pos := _find_nearest_resource_pos(&"tropical_plant", _player.global_position)
	_check(plant_pos != Vector3.INF, "Found tropical plant for leaves")
	_move_player_to(plant_pos + Vector3(0.4, 0.0, 0.0))
	await _pump(4)
	var plant_target := _survival.resources.find_nearest_target(_player.global_position, Vector3.FORWARD)
	var leaf_res := _survival.resources.harvest(plant_target)
	_check(bool(leaf_res.get("ok", false)) and _survival.inventory.get_count(&"leaves") >= 2, "Harvested leaves (%d)" % _survival.inventory.get_count(&"leaves"))

	_step("4. Open Inventory & Inspect + Capacity Check")
	_survival.hud.inv_panel.open_panel()
	await _pump(2)
	_check(_survival.hud.inv_panel.visible, "Inventory & Crafting panel opened")
	_check(_survival.inventory.get_used_slot_count() >= 4, "Inventory displays gathered resource stacks")

	_step("5. Craft Basic Tools")
	# Ensure missing materials blocks crafting (foundation needs 4 wood; we only have 2).
	_check(not _survival.crafting.craft(&"craft_foundation"), "Crafting rejects recipe with missing materials")
	# Gather extra stone & wood for crafting tools + shelter pieces.
	_survival.inventory.add_item(&"wood", 32)
	_survival.inventory.add_item(&"stone", 6)
	_survival.inventory.add_item(&"plant_fiber", 12)
	_survival.inventory.add_item(&"leaves", 10)
	_check(_survival.crafting.craft(&"craft_stone_tool"), "Crafted Stone Gathering Tool")
	_check(_survival.crafting.craft(&"craft_wood_tool"), "Crafted Wood Gathering Tool")
	_check(_survival.inventory.has_tool(&"stone") and _survival.inventory.has_tool(&"wood"), "Both gathering tools stored in inventory")

	# Verify tool gather bonus on another rock deposit.
	var rock2_pos := _find_nearest_resource_pos(&"rock", rock_pos + Vector3(20.0, 0.0, 0.0))
	if rock2_pos != Vector3.INF:
		_move_player_to(rock2_pos + Vector3(1.0, 0.0, 0.0))
		await _pump(3)
		var rock2_target := _survival.resources.find_nearest_target(_player.global_position, Vector3.FORWARD)
		var before_stone := _survival.inventory.get_count(&"stone")
		var bonus_res := _survival.resources.harvest(rock2_target)
		var gained_stone := _survival.inventory.get_count(&"stone") - before_stone
		_check(bool(bonus_res.get("ok", false)) and gained_stone >= 4, "Stone Gathering Tool granted bonus stone (+%d)" % gained_stone)

	_survival.hud.inv_panel.close_panel()

	_step("6. Search Beach & Collect Sparkling Shark Tooth")
	var tooth_spots := _survival.collectibles.get_active_spot_positions()
	_check(tooth_spots.size() >= 3, "Spawned %d beach collectibles along black-sand coastline" % tooth_spots.size())
	var nearest_tooth := _find_nearest_vec3(tooth_spots, _player.global_position)
	_check(_terrain.data.get_height(nearest_tooth) >= 0.45, "Shark tooth spawned above sea level (h=%.2f)" % _terrain.data.get_height(nearest_tooth))
	_move_player_to(nearest_tooth + Vector3(0.8, 0.0, 0.0))
	await _pump(4)
	var col_spot := _survival.collectibles.find_nearest_collectible(_player.global_position)
	_check(not col_spot.is_empty(), "Detected nearby sparkling Shark Tooth")
	var col_res := _survival.collectibles.collect(col_spot)
	_check(bool(col_res.get("ok", false)), "Collected Shark Tooth")
	_check(_survival.inventory.get_count(&"shark_tooth") == 1, "Shark Tooth entered inventory")
	_check(not bool(col_spot["active"]), "Sparkle disappeared after collection")
	_check(not bool(_survival.collectibles.collect(col_spot).get("ok", false)), "Prevented repeat collection of same sparkle")

	_step("7. Craft All Building Components")
	for rec_id in [&"craft_foundation", &"craft_floor", &"craft_wall", &"craft_wall", &"craft_wall", &"craft_doorway", &"craft_door", &"craft_roof", &"craft_stairs"]:
		_check(_survival.crafting.craft(rec_id), "Crafted %s" % String(rec_id))

	_step("8. Building Mode Validation & Shelter Construction")
	var build_origin := Vector3(52.0, _terrain.data.get_height(Vector3(52.0, 0.0, 578.0)) + 0.5, 578.0)
	_move_player_to(Vector3(44.0, 0.0, 576.0))
	_survival.buildings.set_build_mode(true)
	await _pump(2)
	_check(_survival.buildings.build_mode, "Entered Building Mode")

	# Negative validation checks: underwater & unsupported floating wall.
	var underwater_res := _survival.buildings.place_piece_explicit(&"foundation", Vector3(48.0, -2.0, 720.0), 0.0, true)
	_check(not bool(underwater_res.get("ok", false)), "Rejected underwater placement")
	var floating_res := _survival.buildings.place_piece_explicit(&"wall", build_origin + Vector3(20.0, 12.0, 0.0), 0.0, true)
	_check(not bool(floating_res.get("ok", false)), "Rejected floating unsupported wall")

	# Place shelter pieces: foundation, 3 walls, doorway, door, roof, stairs.
	var r_f := _survival.buildings.place_piece_explicit(&"foundation", build_origin, 0.0, true)
	_check(bool(r_f.get("ok", false)), "Placed Foundation")
	var r_w1 := _survival.buildings.place_piece_explicit(&"wall", build_origin + Vector3(-2.0, 0.0, 0.0), PI * 0.5, true)
	var r_w2 := _survival.buildings.place_piece_explicit(&"wall", build_origin + Vector3(2.0, 0.0, 0.0), -PI * 0.5, true)
	var r_w3 := _survival.buildings.place_piece_explicit(&"wall", build_origin + Vector3(0.0, 0.0, -2.0), 0.0, true)
	_check(bool(r_w1.get("ok", false)) and bool(r_w2.get("ok", false)) and bool(r_w3.get("ok", false)), "Placed 3 Walls snapped to Foundation")

	var doorway_pos := build_origin + Vector3(0.0, 0.0, 2.0)
	var r_dw := _survival.buildings.place_piece_explicit(&"doorway", doorway_pos, PI, true)
	_check(bool(r_dw.get("ok", false)), "Placed Doorway snapped to Foundation")
	var r_door := _survival.buildings.place_piece_explicit(&"door", doorway_pos, PI, true)
	_check(bool(r_door.get("ok", false)), "Placed Door snapped into Doorway")
	var r_roof := _survival.buildings.place_piece_explicit(&"roof", build_origin + Vector3(0.0, 3.0, 0.0), 0.0, true)
	_check(bool(r_roof.get("ok", false)), "Placed Roof snapped atop Walls")
	var r_stairs := _survival.buildings.place_piece_explicit(&"stairs", build_origin + Vector3(4.0, 0.0, 0.0), -PI * 0.5, true)
	_check(bool(r_stairs.get("ok", false)), "Placed Stairs snapped to Foundation")

	# Duplicate overlap check.
	_survival.inventory.add_item(&"wood_wall", 1)
	var dup_wall := _survival.buildings.place_piece_explicit(&"wall", build_origin + Vector3(-2.0, 0.0, 0.0), PI * 0.5, true)
	_check(not bool(dup_wall.get("ok", false)), "Rejected overlapping duplicate wall")
	_survival.inventory.remove_item(&"wood_wall", 1)

	# Building removal & refund check (place floor on top of shelter, then remove it).
	var r_fl := _survival.buildings.place_piece_explicit(&"floor", build_origin + Vector3(0.0, 3.0, 0.0), 0.0, true)
	_check(bool(r_fl.get("ok", false)), "Placed Floor on upper wall level")
	if bool(r_fl.get("ok", false)):
		var rem_res := _survival.buildings.remove_piece(String(r_fl["uid"]), true)
		_check(bool(rem_res.get("ok", false)) and _survival.inventory.get_count(&"wood_floor") == 1, "Removed placed Floor and refunded item")
		_survival.inventory.remove_item(&"wood_floor", 1)

	_survival.buildings.set_build_mode(false)
	_check(not _survival.buildings.build_mode, "Exited Building Mode")

	_step("9. Walk Inside Shelter & Toggle Door")
	_move_player_to(doorway_pos + Vector3(0.0, 0.0, 1.5))
	await _pump(4)
	var near_door := _survival.buildings.find_nearest_door(_player.global_position)
	_check(not near_door.is_empty(), "Detected placed Door for interaction")
	_check(_survival.buildings.toggle_door(String(near_door["uid"])), "Opened Door")
	await _pump(20)
	# Stand on top of foundation inside the shelter.
	_player.global_position = build_origin + Vector3(0.0, 0.2, 0.0)
	_player.velocity = Vector3.ZERO
	await _pump(15)
	_check(_player.is_on_floor() and _player.global_position.y >= build_origin.y - 0.15, "Kekoa stands solidly on Foundation inside shelter")

	_step("10. Save & Reload Persistence + Corrupted Save Handling")
	var pre_save_pos := _player.global_position
	var pre_save_tooth := _survival.inventory.get_count(&"shark_tooth")
	var pre_save_buildings := _survival.buildings.get_placed_count()
	var save_res := _survival.perform_save()
	_check(bool(save_res.get("ok", false)), "Saved game to versioned JSON")

	# Wipe live state, then reload.
	_survival.perform_new_game()
	await _pump(4)
	_check(_survival.buildings.get_placed_count() == 0, "New Game cleared buildings")
	_check(_survival.inventory.get_count(&"shark_tooth") == 0, "New Game cleared inventory")

	var load_res := _survival.perform_load()
	_check(bool(load_res.get("ok", false)), "Reloaded saved game")
	await _pump(6)
	_check(_player.global_position.distance_to(pre_save_pos) < 0.25, "Player position persisted")
	_check(_survival.inventory.get_count(&"shark_tooth") == pre_save_tooth, "Inventory persisted without duplication")
	_check(_survival.buildings.get_placed_count() == pre_save_buildings, "All %d placed buildings persisted" % pre_save_buildings)
	_check(not bool(col_spot["active"]), "Collected beach sparkle state persisted as collected")
	_check(_survival.resources.is_depleted(String(tree_target["id"])), "Depleted resource state persisted")

	# Corrupted save resilience check.
	var orig_path := _survival.save_system.save_path
	_survival.save_system.save_path = "user://koacoast_corrupted_test.json"
	var bad_file := FileAccess.open(_survival.save_system.save_path, FileAccess.WRITE)
	bad_file.store_string("{ not valid json !!!")
	bad_file.close()
	var bad_res := _survival.save_system.load_game(_player, _survival.inventory, _survival.resources, _survival.collectibles, _survival.buildings)
	_check(not bool(bad_res.get("ok", false)), "Safely rejected corrupted save file without crashing")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_survival.save_system.save_path))
	_survival.save_system.save_path = orig_path
	DirAccess.remove_absolute(ProjectSettings.globalize_path(orig_path))

	_step("11. Minimap & Full-Screen Map Navigation")
	_survival.hud.map_overlay.open_map()
	await _pump(3)
	_check(_survival.hud.map_overlay.visible, "Full-screen Island Map opened")
	_check(_survival.buildings.get_base_markers().size() >= 1, "Base marker registered on map (%d)" % _survival.buildings.get_base_markers().size())
	_survival.hud.map_overlay.close_map()

	print("[playtest] SUMMARY failures=%d" % _failures.size())
	if not _failures.is_empty():
		for f in _failures:
			push_error("[playtest] FAIL: " + f)
		quit(1)
		return
	print("[playtest] ALL CHECKS PASSED")
	quit(0)


func _step(label: String) -> void:
	print("[playtest] --- %s ---" % label)


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[playtest] PASS: ", msg)
	else:
		print("[playtest] FAIL: ", msg)
		_failures.append(msg)


func _pump(frames: int) -> void:
	for _i in frames:
		await process_frame


func _move_player_to(xz_target: Vector3) -> void:
	var h: float = _terrain.data.get_height(xz_target)
	var y: float = h + 0.15 if is_finite(h) else xz_target.y
	_player.global_position = Vector3(xz_target.x, y, xz_target.z)
	_player.velocity = Vector3.ZERO


func _find_nearest_resource_pos(kind: StringName, origin: Vector3) -> Vector3:
	var best := Vector3.INF
	var best_d2 := INF
	for node: Dictionary in _survival.resources._nodes_by_id.values():
		if node["kind"] != kind:
			continue
		var p: Vector3 = node["pos"]
		var d2 := Vector2(p.x - origin.x, p.z - origin.z).length_squared()
		if d2 < best_d2:
			best_d2 = d2
			best = p
	return best


func _find_nearest_vec3(points: Array[Vector3], origin: Vector3) -> Vector3:
	var best := Vector3.INF
	var best_d2 := INF
	for p in points:
		var d2 := Vector2(p.x - origin.x, p.z - origin.z).length_squared()
		if d2 < best_d2:
			best_d2 = d2
			best = p
	return best
