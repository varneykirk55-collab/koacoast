class_name InventoryCraftingPanel
extends PanelContainer
## Combined data-driven Inventory and Recipe Crafting modal with full
## keyboard/mouse and gamepad focus navigation.

signal close_requested
signal craft_requested(recipe_id: StringName)
signal use_slot_requested(slot_idx: int)

const FILTER_TABS := [
	[&"all", "All"],
	[&"tool", "Tools"],
	[&"component", "Parts"],
	[&"thatch", "Thatch"],
	[&"wood", "Wood"],
	[&"stone", "Stone"],
]

var _database: GameDatabase
var _inventory: InventorySystem
var _crafting: CraftingSystem

var _capacity_label: Label
var _slot_buttons: Array[Button] = []
var _slot_icons: Array[TextureRect] = []
var _slot_counts: Array[Label] = []
var _detail_icon: TextureRect
var _detail_name: Label
var _detail_meta: Label
var _detail_desc: Label
var _use_btn: Button
var _filter_buttons: Array[Button] = []
var _active_filter_idx := 0
var _recipe_list: VBoxContainer
var _recipe_buttons: Dictionary = {} # StringName -> Button
var _selected_slot := 0


func _ready() -> void:
	visible = false
	set_anchors_preset(Control.PRESET_CENTER)
	custom_minimum_size = Vector2(1020, 580)
	offset_left = -510
	offset_top = -290
	offset_right = 510
	offset_bottom = 290

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.11, 0.14, 0.95)
	style.border_color = Color(0.55, 0.72, 0.65, 0.9)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(16)
	add_theme_stylebox_override("panel", style)

	var root_vbox := VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 12)
	add_child(root_vbox)

	var top_bar := HBoxContainer.new()
	root_vbox.add_child(top_bar)

	var title := Label.new()
	title.text = "KEKOA'S BAG & CRAFTING"
	title.add_theme_font_size_override("font_size", 20)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_bar.add_child(title)

	var hint := Label.new()
	hint.text = "D-Pad/Mouse: Navigate   A/Click: Craft   B/I/Esc: Close   "
	hint.modulate = Color(0.80, 0.86, 0.88)
	top_bar.add_child(hint)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(func(): close_requested.emit())
	top_bar.add_child(close_btn)

	var columns := HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 18)
	root_vbox.add_child(columns)

	# Left: Inventory grid + item inspector.
	var inv_col := VBoxContainer.new()
	inv_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inv_col.add_theme_constant_override("separation", 10)
	columns.add_child(inv_col)

	var inv_hdr := HBoxContainer.new()
	inv_col.add_child(inv_hdr)
	var inv_title := Label.new()
	inv_title.text = "Inventory"
	inv_title.add_theme_font_size_override("font_size", 16)
	inv_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inv_hdr.add_child(inv_title)

	_capacity_label = Label.new()
	_capacity_label.text = "0 / 24 slots"
	inv_hdr.add_child(_capacity_label)

	var grid := GridContainer.new()
	grid.columns = 6
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	inv_col.add_child(grid)

	for i in 24:
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(68, 68)
		btn.focus_mode = Control.FOCUS_ALL
		btn.pressed.connect(_on_slot_selected.bind(i))
		btn.focus_entered.connect(_on_slot_selected.bind(i))
		btn.mouse_entered.connect(_on_slot_selected.bind(i))
		grid.add_child(btn)

		var icon := TextureRect.new()
		icon.set_anchors_preset(Control.PRESET_CENTER)
		icon.offset_left = -24
		icon.offset_top = -24
		icon.offset_right = 24
		icon.offset_bottom = 24
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.add_child(icon)

		var qty := Label.new()
		qty.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
		qty.offset_left = -36
		qty.offset_top = -20
		qty.offset_right = -4
		qty.offset_bottom = -2
		qty.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		qty.add_theme_color_override("font_outline_color", Color.BLACK)
		qty.add_theme_constant_override("outline_size", 3)
		qty.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.add_child(qty)

		_slot_buttons.append(btn)
		_slot_icons.append(icon)
		_slot_counts.append(qty)

	# Item inspector panel.
	var detail_box := PanelContainer.new()
	var d_style := StyleBoxFlat.new()
	d_style.bg_color = Color(0.05, 0.07, 0.09, 0.9)
	d_style.set_corner_radius_all(6)
	d_style.set_content_margin_all(10)
	detail_box.add_theme_stylebox_override("panel", d_style)
	detail_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	inv_col.add_child(detail_box)

	var detail_row := HBoxContainer.new()
	detail_row.add_theme_constant_override("separation", 12)
	detail_box.add_child(detail_row)

	_detail_icon = TextureRect.new()
	_detail_icon.custom_minimum_size = Vector2(48, 48)
	_detail_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	detail_row.add_child(_detail_icon)

	var detail_text := VBoxContainer.new()
	detail_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_row.add_child(detail_text)

	_detail_name = Label.new()
	_detail_name.add_theme_font_size_override("font_size", 16)
	_detail_name.text = "Empty Slot"
	detail_text.add_child(_detail_name)

	_detail_meta = Label.new()
	_detail_meta.modulate = Color(0.75, 0.85, 0.78)
	detail_text.add_child(_detail_meta)

	_detail_desc = Label.new()
	_detail_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_desc.text = "Gather wood, stone, plant fibers, leaves, or beach collectibles."
	detail_text.add_child(_detail_desc)

	_use_btn = Button.new()
	_use_btn.visible = false
	_use_btn.focus_mode = Control.FOCUS_ALL
	_use_btn.custom_minimum_size = Vector2(0, 30)
	_use_btn.pressed.connect(func(): use_slot_requested.emit(_selected_slot))
	detail_text.add_child(_use_btn)

	# Right: Crafting recipe list.
	var craft_col := VBoxContainer.new()
	craft_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	craft_col.size_flags_stretch_ratio = 1.3
	craft_col.add_theme_constant_override("separation", 8)
	columns.add_child(craft_col)

	var craft_title := Label.new()
	craft_title.text = "Crafting Recipes (A/Click: Craft   LB/RB or [/]: Filter)"
	craft_title.add_theme_font_size_override("font_size", 15)
	craft_col.add_child(craft_title)

	var tab_row := HBoxContainer.new()
	tab_row.add_theme_constant_override("separation", 4)
	craft_col.add_child(tab_row)
	for i in FILTER_TABS.size():
		var tab_btn := Button.new()
		tab_btn.text = FILTER_TABS[i][1]
		tab_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tab_btn.focus_mode = Control.FOCUS_ALL
		tab_btn.pressed.connect(_set_filter.bind(i))
		tab_row.add_child(tab_btn)
		_filter_buttons.append(tab_btn)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	craft_col.add_child(scroll)

	_recipe_list = VBoxContainer.new()
	_recipe_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_recipe_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_recipe_list)


func setup(db: GameDatabase, inv: InventorySystem, crafting: CraftingSystem) -> void:
	_database = db
	_inventory = inv
	_crafting = crafting
	if _inventory:
		_inventory.inventory_changed.connect(refresh)
	if _crafting:
		_crafting.item_crafted.connect(func(_r, _o, _a): refresh())
	_build_recipe_rows()
	refresh()


func open_panel() -> void:
	visible = true
	refresh()
	if not _slot_buttons.is_empty():
		_slot_buttons[0].grab_focus()


func close_panel() -> void:
	visible = false


func refresh() -> void:
	if _inventory == null or _database == null:
		return
	_capacity_label.text = "%d / %d slots" % [_inventory.get_used_slot_count(), _inventory.capacity]
	for i in _slot_buttons.size():
		var slot := _inventory.get_slot(i)
		if slot.is_empty():
			_slot_icons[i].texture = null
			_slot_counts[i].text = ""
			_slot_buttons[i].tooltip_text = "Empty Slot"
		else:
			var item_id := StringName(slot["item_id"])
			var amt := int(slot["amount"])
			var def := _database.get_item(item_id)
			_slot_icons[i].texture = _database.get_item_icon(item_id)
			if def and def.water_capacity > 0.0:
				var w := _inventory.get_container_water(i)
				_slot_counts[i].text = "%.0f%%" % (float(w["amount"]) / maxf(1.0, float(w["capacity"])) * 100.0)
				_slot_buttons[i].tooltip_text = "%s (%.0f/%.0f mL %s)" % [def.display_name, float(w["amount"]), float(w["capacity"]), WaterQuality.get_label(int(w["quality"]))]
			else:
				_slot_counts[i].text = str(amt) if amt > 1 else ""
				_slot_buttons[i].tooltip_text = "%s (%d)" % [def.display_name if def else String(item_id), amt]
	_update_detail(_selected_slot)
	_refresh_recipes()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("craft_tab_prev"):
		_set_filter(posmod(_active_filter_idx - 1, FILTER_TABS.size()))
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("craft_tab_next"):
		_set_filter(posmod(_active_filter_idx + 1, FILTER_TABS.size()))
		get_viewport().set_input_as_handled()


func _set_filter(idx: int) -> void:
	_active_filter_idx = posmod(idx, FILTER_TABS.size())
	_refresh_recipes()


func _build_recipe_rows() -> void:
	for child in _recipe_list.get_children():
		child.queue_free()
	_recipe_buttons.clear()
	if _crafting == null:
		return
	for rec in _crafting.get_recipes(&"hand"):
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(0, 62)
		btn.focus_mode = Control.FOCUS_ALL
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.pressed.connect(func(): craft_requested.emit(rec.id))
		btn.focus_entered.connect(_on_recipe_inspected.bind(rec))
		btn.mouse_entered.connect(_on_recipe_inspected.bind(rec))
		_recipe_list.add_child(btn)

		var row := HBoxContainer.new()
		row.set_anchors_preset(Control.PRESET_FULL_RECT)
		row.offset_left = 8
		row.offset_right = -8
		row.add_theme_constant_override("separation", 10)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.add_child(row)

		var icon := TextureRect.new()
		icon.custom_minimum_size = Vector2(40, 40)
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.texture = _database.get_item_icon(rec.output_item_id)
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(icon)

		var info := VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(info)

		var name_lbl := Label.new()
		name_lbl.name = "Name"
		name_lbl.text = rec.display_name
		name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		info.add_child(name_lbl)

		var req_lbl := Label.new()
		req_lbl.name = "Reqs"
		req_lbl.add_theme_font_size_override("font_size", 11)
		req_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		req_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		info.add_child(req_lbl)

		var status_lbl := Label.new()
		status_lbl.name = "Status"
		status_lbl.custom_minimum_size = Vector2(68, 0)
		status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		status_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		status_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(status_lbl)

		_recipe_buttons[rec.id] = btn


func _refresh_recipes() -> void:
	if _crafting == null or _database == null:
		return
	var active_cat: StringName = FILTER_TABS[_active_filter_idx][0]
	for i in _filter_buttons.size():
		_filter_buttons[i].modulate = Color(0.62, 0.98, 0.72) if i == _active_filter_idx else Color(0.76, 0.80, 0.84)

	for rec in _crafting.get_recipes(&"hand"):
		var btn := _recipe_buttons.get(rec.id, null) as Button
		if btn == null:
			continue
		var rec_cat := _database.get_recipe_category(rec)
		btn.visible = active_cat == &"all" or rec_cat == active_cat
		var eval := _crafting.evaluate_recipe(rec.id)
		var craftable := bool(eval["craftable"])
		var inv_full := bool(eval["inventory_full"])
		var req_parts: Array[String] = []
		for req in rec.ingredients:
			var iid := StringName(req["item_id"])
			var need := int(req["amount"])
			var have := _inventory.get_count(iid)
			var idef := _database.get_item(iid)
			var nm := idef.display_name if idef else String(iid)
			req_parts.append("%s %d/%d" % [nm, have, need])
		var row := btn.get_child(0)
		var info := row.get_child(1)
		var req_lbl := info.get_node("Reqs") as Label
		var status_lbl := row.get_node("Status") as Label
		req_lbl.text = "  |  ".join(req_parts)
		if craftable:
			status_lbl.text = "CRAFT"
			status_lbl.modulate = Color(0.45, 0.95, 0.55)
			req_lbl.modulate = Color(0.76, 0.92, 0.78)
			btn.modulate = Color.WHITE
		elif inv_full:
			status_lbl.text = "BAG FULL"
			status_lbl.modulate = Color(1.0, 0.72, 0.30)
			btn.modulate = Color(0.95, 0.85, 0.75)
		else:
			status_lbl.text = "MISSING"
			status_lbl.modulate = Color(0.95, 0.42, 0.42)
			req_lbl.modulate = Color(0.95, 0.65, 0.65)
			btn.modulate = Color(0.78, 0.78, 0.80)


func _on_recipe_inspected(rec: RecipeDef) -> void:
	if _database == null or rec == null:
		return
	var def := _database.get_item(rec.output_item_id)
	_detail_icon.texture = _database.get_item_icon(rec.output_item_id)
	_detail_name.text = rec.display_name
	var have_out := _inventory.get_count(rec.output_item_id) if _inventory else 0
	_detail_meta.text = "Crafts: +%d  |  Owned: %d  |  Category: %s" % [rec.output_amount, have_out, String(def.category).capitalize() if def else "Item"]
	_detail_desc.text = def.description if def else ""
	if _use_btn:
		_use_btn.visible = false


func _on_slot_selected(idx: int) -> void:
	_selected_slot = idx
	_update_detail(idx)


func _update_detail(idx: int) -> void:
	if _inventory == null or _database == null:
		return
	var slot := _inventory.get_slot(idx)
	if slot.is_empty():
		_detail_icon.texture = null
		_detail_name.text = "Empty Slot #%d" % (idx + 1)
		_detail_meta.text = ""
		_detail_desc.text = "Select an item to inspect its details."
		if _use_btn:
			_use_btn.visible = false
		return
	var item_id := StringName(slot["item_id"])
	var amt := int(slot["amount"])
	var def := _database.get_item(item_id)
	_detail_icon.texture = _database.get_item_icon(item_id)
	_detail_name.text = def.display_name if def else String(item_id)
	if def and def.water_capacity > 0.0:
		var w := _inventory.get_container_water(idx)
		_detail_meta.text = "Water: %.0f / %.0f mL  |  %s" % [float(w["amount"]), float(w["capacity"]), WaterQuality.get_label(int(w["quality"]))]
		if _use_btn:
			_use_btn.visible = float(w["amount"]) > 0.1
			_use_btn.text = "Drink %s" % def.display_name
	elif def and def.category == &"food":
		_detail_meta.text = "Food  |  Quantity: %d / %d  |  +%.0f Hunger" % [amt, def.max_stack, def.hunger_restore]
		if _use_btn:
			_use_btn.visible = true
			_use_btn.text = "Eat %s" % def.display_name
	elif item_id == &"rain_tarp":
		_detail_meta.text = "Survival Gear  |  Quantity: %d / %d" % [amt, def.max_stack]
		if _use_btn:
			_use_btn.visible = true
			_use_btn.text = "Place Rainwater Collection Tarp"
	else:
		_detail_meta.text = "Category: %s   |   Quantity: %d / %d" % [String(def.category).capitalize(), amt, def.max_stack] if def else ""
		if _use_btn:
			_use_btn.visible = false
	_detail_desc.text = def.description if def else ""
