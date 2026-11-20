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
		if def and (def.tool_kind == tool_kind or def.tool_kind == &"all"):
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
			var entry := { "item_id": item_id, "amount": put }
			if def.water_capacity > 0.0:
				entry["water_amount"] = 0.0
				entry["water_quality"] = WaterQuality.Quality.CLEAN_FRESHWATER
			slots[i] = entry
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


func find_container_slot(need_space := false, need_water := false) -> int:
	if database == null:
		return -1
	for i in slots.size():
		var slot := slots[i]
		if slot.is_empty():
			continue
		var def := database.get_item(StringName(slot["item_id"]))
		if def == null or def.water_capacity <= 0.0:
			continue
		var cur := float(slot.get("water_amount", 0.0))
		if need_space and cur >= def.water_capacity - 0.01:
			continue
		if need_water and cur <= 0.01:
			continue
		return i
	return -1


func get_container_water(slot_idx: int) -> Dictionary:
	var slot := get_slot(slot_idx)
	if slot.is_empty() or database == null:
		return { "amount": 0.0, "capacity": 0.0, "quality": WaterQuality.Quality.CLEAN_FRESHWATER }
	var def := database.get_item(StringName(slot["item_id"]))
	if def == null or def.water_capacity <= 0.0:
		return { "amount": 0.0, "capacity": 0.0, "quality": WaterQuality.Quality.CLEAN_FRESHWATER }
	return {
		"amount": float(slot.get("water_amount", 0.0)),
		"capacity": def.water_capacity,
		"quality": int(slot.get("water_quality", WaterQuality.Quality.CLEAN_FRESHWATER)),
	}


func fill_container(slot_idx: int, amount: float, quality: int) -> float:
	if slot_idx < 0 or slot_idx >= slots.size() or amount <= 0.0 or database == null:
		return 0.0
	var slot := slots[slot_idx]
	if slot.is_empty():
		return 0.0
	var def := database.get_item(StringName(slot["item_id"]))
	if def == null or def.water_capacity <= 0.0:
		return 0.0
	var cur := float(slot.get("water_amount", 0.0))
	var space := maxf(0.0, def.water_capacity - cur)
	var added := minf(space, amount)
	if added <= 0.0:
		return 0.0
	var cur_q := int(slot.get("water_quality", WaterQuality.Quality.CLEAN_FRESHWATER))
	if cur <= 0.01:
		slot["water_quality"] = quality
	elif not WaterQuality.is_safe(quality):
		slot["water_quality"] = quality
	elif not WaterQuality.is_safe(cur_q):
		slot["water_quality"] = cur_q
	slot["water_amount"] = minf(def.water_capacity, cur + added)
	inventory_changed.emit()
	return added


func drain_container(slot_idx: int, amount: float) -> Dictionary:
	if slot_idx < 0 or slot_idx >= slots.size() or amount <= 0.0:
		return { "drained": 0.0, "quality": WaterQuality.Quality.CLEAN_FRESHWATER }
	var slot := slots[slot_idx]
	if slot.is_empty():
		return { "drained": 0.0, "quality": WaterQuality.Quality.CLEAN_FRESHWATER }
	var cur := float(slot.get("water_amount", 0.0))
	if cur <= 0.01:
		return { "drained": 0.0, "quality": WaterQuality.Quality.CLEAN_FRESHWATER }
	var q := int(slot.get("water_quality", WaterQuality.Quality.CLEAN_FRESHWATER))
	var taken := minf(cur, amount)
	slot["water_amount"] = maxf(0.0, cur - taken)
	if float(slot["water_amount"]) <= 0.01:
		slot["water_amount"] = 0.0
		slot["water_quality"] = WaterQuality.Quality.CLEAN_FRESHWATER
	inventory_changed.emit()
	return { "drained": taken, "quality": q }


func serialize() -> Dictionary:
	var out: Array[Dictionary] = []
	for i in slots.size():
		var slot := slots[i]
		if not slot.is_empty():
			var row := {
				"slot": i,
				"item_id": String(slot["item_id"]),
				"amount": int(slot["amount"]),
			}
			if slot.has("water_amount"):
				row["water_amount"] = snappedf(float(slot["water_amount"]), 0.1)
				row["water_quality"] = int(slot.get("water_quality", WaterQuality.Quality.CLEAN_FRESHWATER))
			out.append(row)
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
		if item_id == &"wood_gathering_tool":
			item_id = &"stone_axe"
		var amt := int(entry.get("amount", 0))
		var def := database.get_item(item_id) if database else null
		if def == null or amt <= 0:
			continue
		amt = mini(amt, maxi(1, def.max_stack))
		var slot_data := { "item_id": item_id, "amount": amt }
		if def.water_capacity > 0.0:
			var wa := clampf(float(entry.get("water_amount", 0.0)), 0.0, def.water_capacity)
			slot_data["water_amount"] = wa
			slot_data["water_quality"] = int(entry.get("water_quality", WaterQuality.Quality.CLEAN_FRESHWATER))
		if idx >= 0 and idx < capacity and slots[idx].is_empty():
			slots[idx] = slot_data
		else:
			var free_idx := slots.find({})
			if free_idx != -1 and def.water_capacity > 0.0:
				slots[free_idx] = slot_data
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
