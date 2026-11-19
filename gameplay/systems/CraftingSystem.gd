class_name CraftingSystem
extends Node
## Recipe-based crafting connected to InventorySystem and GameDatabase.

signal item_crafted(recipe_id: StringName, output_item_id: StringName, amount: int)

var database: GameDatabase
var inventory: InventorySystem


func setup(db: GameDatabase, inv: InventorySystem) -> void:
	database = db
	inventory = inv


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
