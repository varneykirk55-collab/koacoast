class_name InventorySystem
extends Node
## Data-driven slot inventory supporting stacking, capacity limits, tool checks,
## and version-safe serialization.

signal inventory_changed
signal item_added(item_id: StringName, amount: int)
signal item_removed(item_id: StringName, amount: int)
signal inventory_full(item_id: StringName)

@export var capacity := 24

var database: GameDatabase
var slots: Array[Dictionary] = []


func setup(db: GameDatabase) -> void:
	database = db
	clear()


func clear() -> void:
	slots.resize(capacity)
	for i in capacity:
		slots[i] = {}
	inventory_changed.emit()


func get_slot(index: int) -> Dictionary:
	if index < 0 or index >= slots.size():
		return {}
	return slots[index]


func get_used_slot_count() -> int:
	var count := 0
	for slot in slots:
		if not slot.is_empty():
			count += 1
	return count


func get_count(item_id: StringName) -> int:
	var total := 0
	for slot in slots:
		if slot.get("item_id", &"") == item_id:
			total += int(slot.get("amount", 0))
	return total


func has_items(requirements: Array[Dictionary]) -> bool:
	for req in requirements:
		var req_id := StringName(req.get("item_id", ""))
		var req_amt := int(req.get("amount", 0))
		if req_amt <= 0 or req_id == &"":
			continue
		if get_count(req_id) < req_amt:
			return false
	return true


func has_tool(tool_kind: StringName) -> bool:
	return get_tool_bonus(tool_kind) > 0


func get_tool_bonus(tool_kind: StringName) -> int:
	if database == null or tool_kind == &"":
		return 0
	var best := 0
	for slot in slots:
		if slot.is_empty():
			continue
		var def := database.get_item(StringName(slot.get("item_id", "")))
		if def and def.tool_kind == tool_kind:
			best = maxi(best, def.tool_bonus)
	return best


func can_fit(item_id: StringName, amount: int) -> bool:
	if database == null or amount <= 0:
		return false
	var def := database.get_item(item_id)
	if def == null:
		return false
	return _can_fit_on_slots(slots, item_id, amount, def.max_stack)


func can_fit_after_consume(requirements: Array[Dictionary], output_id: StringName, output_amount: int) -> bool:
	if database == null or output_amount <= 0:
		return false
	var def := database.get_item(output_id)
	if def == null:
		return false
	var sim: Array[Dictionary] = []
	for slot in slots:
		sim.append(slot.duplicate())
	for req in requirements:
		var req_id := StringName(req.get("item_id", ""))
		var need := int(req.get("amount", 0))
		for i in sim.size():
			if need <= 0:
				break
			if sim[i].get("item_id", &"") == req_id:
				var take := mini(need, int(sim[i].get("amount", 0)))
				var left := int(sim[i].get("amount", 0)) - take
				need -= take
				if left <= 0:
					sim[i] = {}
				else:
					sim[i]["amount"] = left
		if need > 0:
			return false
	return _can_fit_on_slots(sim, output_id, output_amount, def.max_stack)


func add_item(item_id: StringName, amount: int) -> int:
	if database == null or amount <= 0:
		return 0
	var def := database.get_item(item_id)
	if def == null:
		return 0
	var remaining := amount
	var max_stack := maxi(1, def.max_stack)

	# First fill existing partial stacks.
	for i in slots.size():
		if remaining <= 0:
			break
		var slot := slots[i]
		if slot.get("item_id", &"") == item_id:
			var cur := int(slot.get("amount", 0))
			var space := max_stack - cur
			if space > 0:
				var put := mini(space, remaining)
				slot["amount"] = cur + put
				remaining -= put

	# Then occupy empty slots.
	for i in slots.size():
		if remaining <= 0:
			break
		if slots[i].is_empty():
			var put := mini(max_stack, remaining)
			slots[i] = { "item_id": item_id, "amount": put }
			remaining -= put

	var added := amount - remaining
	if added > 0:
		item_added.emit(item_id, added)
		inventory_changed.emit()
	if remaining > 0:
		inventory_full.emit(item_id)
	return added


func remove_item(item_id: StringName, amount: int) -> bool:
	if amount <= 0:
		return true
	if get_count(item_id) < amount:
		return false
	var remaining := amount
	# Consume from last matching slots first so earlier stack positions stay tidy.
	for i in range(slots.size() - 1, -1, -1):
		if remaining <= 0:
			break
		var slot := slots[i]
		if slot.get("item_id", &"") == item_id:
			var cur := int(slot.get("amount", 0))
			var take := mini(cur, remaining)
			cur -= take
			remaining -= take
			if cur <= 0:
				slots[i] = {}
			else:
				slot["amount"] = cur
	item_removed.emit(item_id, amount)
	inventory_changed.emit()
	return true


func swap_slots(a: int, b: int) -> void:
	if a < 0 or a >= slots.size() or b < 0 or b >= slots.size() or a == b:
		return
	var tmp := slots[a]
	slots[a] = slots[b]
	slots[b] = tmp
	inventory_changed.emit()


func serialize() -> Dictionary:
	var out: Array[Dictionary] = []
	for i in slots.size():
		var slot := slots[i]
		if not slot.is_empty():
			out.append({
				"slot": i,
				"item_id": String(slot["item_id"]),
				"amount": int(slot["amount"]),
			})
	return {
		"capacity": capacity,
		"slots": out,
	}


func deserialize(data: Dictionary) -> void:
	clear()
	if not data.has("slots") or not (data["slots"] is Array):
		return
	for entry in data["slots"]:
		if not (entry is Dictionary):
			continue
		var idx := int(entry.get("slot", -1))
		var item_id := StringName(String(entry.get("item_id", "")))
		var amt := int(entry.get("amount", 0))
		var def := database.get_item(item_id) if database else null
		if def == null or amt <= 0:
			continue
		amt = mini(amt, maxi(1, def.max_stack))
		if idx >= 0 and idx < capacity and slots[idx].is_empty():
			slots[idx] = { "item_id": item_id, "amount": amt }
		else:
			add_item(item_id, amt)
	inventory_changed.emit()


func _can_fit_on_slots(slot_list: Array[Dictionary], item_id: StringName, amount: int, max_stack: int) -> bool:
	var needed := amount
	var stack_cap := maxi(1, max_stack)
	for slot in slot_list:
		if slot.is_empty():
			needed -= stack_cap
		elif slot.get("item_id", &"") == item_id:
			needed -= maxi(0, stack_cap - int(slot.get("amount", 0)))
		if needed <= 0:
			return true
	return false
