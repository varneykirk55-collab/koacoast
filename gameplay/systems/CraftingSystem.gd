class_name CraftingSystem
extends Node
## Recipe-based crafting connected to InventorySystem and GameDatabase.

signal item_crafted(recipe_id: StringName, output_item_id: StringName, amount: int)
signal craft_progress_changed(active: bool, recipe_id: StringName, progress: float)

@export var base_craft_duration := 0.8

var database: GameDatabase
var inventory: InventorySystem
var craft_time_multiplier := 1.0

var _active_recipe_id: StringName = &""
var _active_elapsed := 0.0
var _active_duration := 0.0


func setup(db: GameDatabase, inv: InventorySystem) -> void:
	database = db
	inventory = inv


func set_craft_time_multiplier(mult: float) -> void:
	craft_time_multiplier = clampf(mult, 0.25, 4.0)


func get_effective_craft_time(_recipe_id: StringName = &"") -> float:
	return base_craft_duration * craft_time_multiplier


func is_crafting() -> bool:
	return _active_recipe_id != &""


func cancel_timed_craft() -> void:
	if _active_recipe_id != &"":
		_active_recipe_id = &""
		_active_elapsed = 0.0
		_active_duration = 0.0
		craft_progress_changed.emit(false, &"", 0.0)


func begin_timed_craft(recipe_id: StringName) -> bool:
	if _active_recipe_id != &"":
		return false
	var status := evaluate_recipe(recipe_id)
	if not status["craftable"]:
		if status["inventory_full"]:
			var rec_full := database.get_recipe(recipe_id)
			if rec_full:
				inventory.inventory_full.emit(rec_full.output_item_id)
		return false
	_active_recipe_id = recipe_id
	_active_elapsed = 0.0
	_active_duration = maxf(0.05, get_effective_craft_time(recipe_id))
	craft_progress_changed.emit(true, _active_recipe_id, 0.0)
	return true


func _process(delta: float) -> void:
	if _active_recipe_id == &"":
		return
	_active_elapsed += delta
	var frac := clampf(_active_elapsed / maxf(0.05, _active_duration), 0.0, 1.0)
	craft_progress_changed.emit(true, _active_recipe_id, frac)
	if _active_elapsed >= _active_duration:
		var rec_id := _active_recipe_id
		_active_recipe_id = &""
		_active_elapsed = 0.0
		_active_duration = 0.0
		craft_progress_changed.emit(false, &"", 0.0)
		craft(rec_id)


func get_recipes(station: StringName = &"hand") -> Array[RecipeDef]:
	var result: Array[RecipeDef] = []
	if database == null:
		return result
	for rec in database.recipes:
		if station == &"" or rec.station == station:
			result.append(rec)
	return result


func evaluate_recipe(recipe_id: StringName) -> Dictionary:
	var rec := database.get_recipe(recipe_id) if database else null
	if rec == null or inventory == null:
		return { "craftable": false, "missing": [], "inventory_full": false }
	var missing: Array[Dictionary] = []
	for req in rec.ingredients:
		var req_id := StringName(req.get("item_id", ""))
		var req_amt := int(req.get("amount", 0))
		var have := inventory.get_count(req_id)
		if have < req_amt:
			missing.append({
				"item_id": req_id,
				"required": req_amt,
				"have": have,
				"missing": req_amt - have,
			})
	var has_mats := missing.is_empty()
	var can_fit := has_mats and inventory.can_fit_after_consume(rec.ingredients, rec.output_item_id, rec.output_amount)
	return {
		"craftable": has_mats and can_fit,
		"missing": missing,
		"inventory_full": has_mats and not can_fit,
	}


func craft(recipe_id: StringName) -> bool:
	var status := evaluate_recipe(recipe_id)
	if not status["craftable"]:
		if status["inventory_full"]:
			var rec_full := database.get_recipe(recipe_id)
			if rec_full:
				inventory.inventory_full.emit(rec_full.output_item_id)
		return false
	var rec := database.get_recipe(recipe_id)
	for req in rec.ingredients:
		var req_id := StringName(req.get("item_id", ""))
		var req_amt := int(req.get("amount", 0))
		if not inventory.remove_item(req_id, req_amt):
			return false
	var added := inventory.add_item(rec.output_item_id, rec.output_amount)
	if added <= 0:
		return false
	item_crafted.emit(recipe_id, rec.output_item_id, added)
	return true
