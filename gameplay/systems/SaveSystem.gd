class_name SaveSystem
extends Node
## Versioned JSON save & load system covering player state, inventory,
## resource depletion timers, beach collectibles, and placed buildings.

const SAVE_VERSION := 1
const DEFAULT_SAVE_PATH := "user://koacoast_save_v1.json"

var save_path := DEFAULT_SAVE_PATH
var _spawn_position := Vector3(48.0, 3.0, 576.0)


func set_spawn_position(pos: Vector3) -> void:
	_spawn_position = pos


func has_save() -> bool:
	return FileAccess.file_exists(save_path)


func save_game(player: Node3D, inventory: InventorySystem, resources: ResourceGatherSystem, collectibles: BeachCollectibleSystem, buildings: BuildingSystem, vitals: SurvivalVitalsSystem = null, water_system: WaterSystem = null, day_night: DayNightSystem = null) -> Dictionary:
	if player == null or inventory == null or resources == null or collectibles == null or buildings == null:
		return { "ok": false, "reason": "Missing system reference" }

	var visual := player.get_node_or_null("Visual") as Node3D
	var pivot := player.get_node_or_null("CameraPivot") as Node3D
	var spring := player.get_node_or_null("CameraPivot/SpringArm3D") as Node3D
	var p := player.global_position
	var payload := {
		"version": SAVE_VERSION,
		"saved_at": Time.get_datetime_string_from_system(true),
		"player": {
			"position": [p.x, p.y, p.z],
			"visual_yaw": visual.rotation.y if visual else 0.0,
			"camera_yaw": pivot.rotation.y if pivot else 0.0,
			"camera_pitch": spring.rotation.x if spring else 0.0,
		},
		"inventory": inventory.serialize(),
		"resources": resources.serialize(),
		"collectibles": collectibles.serialize(),
		"buildings": buildings.serialize(),
	}
	if vitals:
		payload["vitals"] = vitals.serialize()
	if water_system:
		payload["rain_collectors"] = water_system.serialize()
	if day_night:
		payload["day_night"] = day_night.serialize()

	var json_str := JSON.stringify(payload, "\t")
	var tmp_path := save_path + ".tmp"
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		return { "ok": false, "reason": "Failed to open save file for writing" }
	file.store_string(json_str)
	file.close()

	var abs_tmp := ProjectSettings.globalize_path(tmp_path)
	var abs_dst := ProjectSettings.globalize_path(save_path)
	var err := DirAccess.rename_absolute(abs_tmp, abs_dst)
	if err != OK:
		var direct := FileAccess.open(save_path, FileAccess.WRITE)
		if direct == null:
			return { "ok": false, "reason": "Failed to write save file" }
		direct.store_string(json_str)
		direct.close()
	return { "ok": true, "path": save_path }


func load_game(player: Node3D, inventory: InventorySystem, resources: ResourceGatherSystem, collectibles: BeachCollectibleSystem, buildings: BuildingSystem, vitals: SurvivalVitalsSystem = null, water_system: WaterSystem = null, day_night: DayNightSystem = null) -> Dictionary:
	if not FileAccess.file_exists(save_path):
		return { "ok": false, "reason": "No save file found" }
	var file := FileAccess.open(save_path, FileAccess.READ)
	if file == null:
		return { "ok": false, "reason": "Could not open save file" }
	var raw_text := file.get_as_text()
	file.close()

	var json := JSON.new()
	if json.parse(raw_text) != OK or not (json.data is Dictionary):
		push_warning("SaveSystem: corrupted save file at %s" % save_path)
		return { "ok": false, "reason": "Corrupted save data (invalid JSON)" }
	var data: Dictionary = json.data
	var version := int(data.get("version", -1))
	if version <= 0 or version > SAVE_VERSION:
		push_warning("SaveSystem: unsupported save version %s" % str(data.get("version")))
		return { "ok": false, "reason": "Unsupported save version" }

	if data.has("inventory") and data["inventory"] is Dictionary:
		inventory.deserialize(data["inventory"])
	if data.has("resources") and data["resources"] is Dictionary:
		resources.deserialize(data["resources"])
	if data.has("collectibles") and data["collectibles"] is Dictionary:
		collectibles.deserialize(data["collectibles"])
	if data.has("buildings") and data["buildings"] is Dictionary:
		buildings.deserialize(data["buildings"])
	if vitals and data.has("vitals") and data["vitals"] is Dictionary:
		vitals.deserialize(data["vitals"])
	if water_system and data.has("rain_collectors") and data["rain_collectors"] is Dictionary:
		water_system.deserialize(data["rain_collectors"])
	if day_night and data.has("day_night") and data["day_night"] is Dictionary:
		day_night.deserialize(data["day_night"])
	if data.has("player") and data["player"] is Dictionary:
		_apply_player_state(player, data["player"])

	return { "ok": true, "version": version }


func new_game(player: Node3D, inventory: InventorySystem, resources: ResourceGatherSystem, collectibles: BeachCollectibleSystem, buildings: BuildingSystem, delete_save := false, vitals: SurvivalVitalsSystem = null, water_system: WaterSystem = null, day_night: DayNightSystem = null) -> void:
	if inventory:
		inventory.clear()
	if resources:
		resources.reset_all()
	if collectibles:
		collectibles.reset_all()
	if buildings:
		buildings.clear_all()
	if vitals:
		vitals.reset_all()
	if water_system:
		water_system.clear_all()
	if day_night:
		day_night.reset_all()
	if player:
		player.global_position = _spawn_position
		if player is CharacterBody3D:
			(player as CharacterBody3D).velocity = Vector3.ZERO
		if player.has_method("_snap_to_ground"):
			player.call("_snap_to_ground")
	if delete_save and FileAccess.file_exists(save_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))


func _apply_player_state(player: Node3D, pdata: Dictionary) -> void:
	if player == null:
		return
	var pos_arr = pdata.get("position", [])
	if pos_arr is Array and pos_arr.size() >= 3:
		var px := float(pos_arr[0])
		var py := float(pos_arr[1])
		var pz := float(pos_arr[2])
		if is_finite(px) and is_finite(py) and is_finite(pz):
			player.global_position = Vector3(px, py, pz)
			if player is CharacterBody3D:
				(player as CharacterBody3D).velocity = Vector3.ZERO
	var visual := player.get_node_or_null("Visual") as Node3D
	if visual and pdata.has("visual_yaw"):
		var vy := float(pdata["visual_yaw"])
		if is_finite(vy):
			visual.rotation.y = vy
	var pivot := player.get_node_or_null("CameraPivot") as Node3D
	if pivot and pdata.has("camera_yaw"):
		var cy := float(pdata["camera_yaw"])
		if is_finite(cy):
			pivot.rotation.y = cy
		pivot.global_position = player.global_position + Vector3.UP * 1.55
	var spring := player.get_node_or_null("CameraPivot/SpringArm3D") as Node3D
	if spring and pdata.has("camera_pitch"):
		var cp := float(pdata["camera_pitch"])
		if is_finite(cp):
			spring.rotation.x = clampf(cp, -1.2, 0.5)
