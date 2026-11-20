class_name SurvivalHUD
extends CanvasLayer
## Coordinates the HUD overlay (minimap, prompts, build bar, pickup toasts)
## and modal menus (Inventory & Crafting, Full-Screen Map, System Menu).

var minimap: MinimapWidget
var map_overlay: IslandMapOverlay
var inv_panel: InventoryCraftingPanel
var system_menu: SystemMenuPanel

var _prompt_panel: PanelContainer
var _prompt_label: Label
var _build_bar: PanelContainer
var _build_pieces_label: Label
var _build_status_label: Label
var _toast_box: VBoxContainer
var _quick_bar: Label
var _debug_panel: PanelContainer
var _debug_label: Label
var _death_panel: PanelContainer
var _death_title: Label
var _death_cause: Label
var _respawn_banner: Label
var _respawn_banner_ttl := 0.0
var _recovery_panel: PanelContainer
var _recovery_label: Label
var _toasts: Array[Dictionary] = []


func _ready() -> void:
	layer = 10
	_build_hud_elements()

	map_overlay = IslandMapOverlay.new()
	add_child(map_overlay)

	inv_panel = InventoryCraftingPanel.new()
	add_child(inv_panel)

	system_menu = SystemMenuPanel.new()
	add_child(system_menu)


func _process(delta: float) -> void:
	for i in range(_toasts.size() - 1, -1, -1):
		_toasts[i]["ttl"] -= delta
		if float(_toasts[i]["ttl"]) <= 0.0:
			var lbl := _toasts[i]["label"] as Label
			if lbl:
				lbl.queue_free()
			_toasts.remove_at(i)
		elif float(_toasts[i]["ttl"]) < 0.6:
			var lbl := _toasts[i]["label"] as Label
			if lbl:
				lbl.modulate.a = maxf(0.0, float(_toasts[i]["ttl"]) / 0.6)
	if _respawn_banner and _respawn_banner.visible:
		_respawn_banner_ttl -= delta
		if _respawn_banner_ttl <= 0.0:
			_respawn_banner.visible = false
		elif _respawn_banner_ttl < 1.0:
			_respawn_banner.modulate.a = clampf(_respawn_banner_ttl, 0.0, 1.0)


func set_map_data(tex: Texture2D, world_rect: Rect2) -> void:
	if minimap:
		minimap.set_map_data(tex, world_rect)
	if map_overlay:
		map_overlay.set_map_data(tex, world_rect)


func update_navigation(player_pos: Vector3, facing_dir: Vector3, base_positions: Array[Vector3]) -> void:
	if minimap:
		minimap.update_state(player_pos, facing_dir, base_positions)
	if map_overlay:
		map_overlay.update_state(player_pos, facing_dir, base_positions)


func set_interaction_prompt(text: String) -> void:
	if _prompt_panel == null or _prompt_label == null:
		return
	if text == "":
		_prompt_panel.visible = false
	else:
		var prompt := "[E / X] %s" % text
		if _prompt_label.text != prompt:
			_prompt_label.text = prompt
		_prompt_panel.visible = true


func update_build_hud(active: bool, piece_order: Array[StringName], selected_idx: int, selected_material_id: StringName, database: GameDatabase, inventory: InventorySystem, eval: Dictionary) -> void:
	if _build_bar == null:
		return
	_build_bar.visible = active
	if not active:
		return
	var mat_parts: Array[String] = []
	for mid in database.building_material_order:
		var mdef := database.get_building_material(mid)
		var mname := mdef.display_name if mdef else String(mid).capitalize()
		mat_parts.append("[%s]" % mname.to_upper() if mid == selected_material_id else mname)

	var parts: Array[String] = []
	for i in piece_order.size():
		var pid := piece_order[i]
		var pdef := database.get_building_piece(pid)
		var item_id := database.get_building_item_id(pid, selected_material_id)
		var count_str := "--"
		if item_id != &"" and inventory:
			count_str = str(inventory.get_count(item_id))
		var name_str := pdef.display_name if pdef else String(pid)
		if i == selected_idx:
			parts.append("[%d:%s x%s]" % [i + 1, name_str, count_str])
		else:
			parts.append("%d:%s(%s)" % [i + 1, name_str, count_str])
	_build_pieces_label.text = "Tier [G/D-Down]: %s   |   %s" % [" ".join(mat_parts), " ".join(parts)]

	var valid := bool(eval.get("valid", false))
	var reason := String(eval.get("reason", ""))
	if valid:
		_build_status_label.text = "READY: %s  |  Place: LMB/F/RT  |  Rotate: R/LB/RB  |  Tier: G/D-Down  |  Remove: MMB/X/LT  |  Exit: RMB/B" % reason
		_build_status_label.modulate = Color(0.45, 0.96, 0.55)
	else:
		_build_status_label.text = "INVALID: %s  |  Tier: G/D-Down  |  Remove: MMB/X/LT  |  Exit: RMB/B" % reason
		_build_status_label.modulate = Color(0.98, 0.42, 0.42)


func push_toast(message: String, color := Color(0.95, 0.98, 0.90)) -> void:
	if _toast_box == null:
		return
	var lbl := Label.new()
	lbl.text = message
	lbl.modulate = color
	lbl.add_theme_font_size_override("font_size", 15)
	lbl.add_theme_color_override("font_outline_color", Color.BLACK)
	lbl.add_theme_constant_override("outline_size", 4)
	_toast_box.add_child(lbl)
	_toasts.append({ "label": lbl, "ttl": 3.0 })
	if _toasts.size() > 6:
		var oldest := _toasts[0]["label"] as Label
		if oldest:
			oldest.queue_free()
		_toasts.remove_at(0)


func is_any_modal_open() -> bool:
	var open := (inv_panel and inv_panel.visible) or (map_overlay and map_overlay.visible) or (system_menu and system_menu.visible)
	if _quick_bar:
		_quick_bar.visible = not open
	return open


func toggle_debug_panel() -> void:
	if _debug_panel:
		_debug_panel.visible = not _debug_panel.visible


func is_debug_visible() -> bool:
	return is_instance_valid(_debug_panel) and _debug_panel.visible


func update_debug_vitals(text: String) -> void:
	if _debug_label and _debug_panel and _debug_panel.visible:
		_debug_label.text = text


func show_death_banner(cause_label: String) -> void:
	if _death_panel == null:
		return
	_death_title.text = "YOU DIED"
	_death_cause.text = cause_label if not cause_label.is_empty() else ""
	_death_cause.visible = not cause_label.is_empty()
	_death_panel.visible = true


func hide_death_banner() -> void:
	if _death_panel:
		_death_panel.visible = false


func show_respawn_banner() -> void:
	if _respawn_banner == null:
		return
	_respawn_banner.text = "SURVIVAL TRAUMA — RECOVER YOUR EQUIPMENT"
	_respawn_banner.modulate = Color(1.0, 0.82, 0.45, 1.0)
	_respawn_banner.visible = true
	_respawn_banner_ttl = 5.0


func update_recovery_indicator(info: Dictionary) -> void:
	if _recovery_panel == null or _recovery_label == null:
		return
	if not bool(info.get("active", false)):
		_recovery_panel.visible = false
		return
	var dir := String(info.get("direction", "N"))
	var dist := float(info.get("distance", 0.0))
	_recovery_label.text = "Death Cache: %s — %.0fm" % [dir, dist]
	_recovery_panel.visible = true


func _build_hud_elements() -> void:
	# Quick-key reminder positioned cleanly below Kekoa's existing HUD/Info label.
	_quick_bar = Label.new()
	_quick_bar.offset_left = 12
	_quick_bar.offset_top = 62
	_quick_bar.offset_right = 760
	_quick_bar.offset_bottom = 86
	_quick_bar.add_theme_font_size_override("font_size", 13)
	_quick_bar.add_theme_color_override("font_outline_color", Color.BLACK)
	_quick_bar.add_theme_constant_override("outline_size", 3)
	_quick_bar.text = "[E/X] Interact   [I/Tab/Y] Bag & Craft   [B/D-Up] Build   [M/Back] Map   [F4] Vitals Debug   [F5] Save   [Esc/Start] Menu"
	add_child(_quick_bar)

	# Toggleable Survival Debug Readout (no permanent hunger/thirst bars).
	_debug_panel = PanelContainer.new()
	_debug_panel.visible = false
	_debug_panel.offset_left = 12
	_debug_panel.offset_top = 92
	_debug_panel.offset_right = 560
	_debug_panel.offset_bottom = 226
	_debug_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dbg_style := StyleBoxFlat.new()
	dbg_style.bg_color = Color(0.05, 0.08, 0.11, 0.84)
	dbg_style.border_color = Color(0.50, 0.68, 0.72, 0.85)
	dbg_style.set_border_width_all(1)
	dbg_style.set_corner_radius_all(6)
	dbg_style.set_content_margin_all(8)
	_debug_panel.add_theme_stylebox_override("panel", dbg_style)
	add_child(_debug_panel)

	_debug_label = Label.new()
	_debug_label.add_theme_font_size_override("font_size", 12)
	_debug_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_debug_panel.add_child(_debug_label)

	# Upper-right circular minimap.
	minimap = MinimapWidget.new()
	minimap.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	minimap.offset_left = -204
	minimap.offset_top = 16
	minimap.offset_right = -20
	minimap.offset_bottom = 200
	add_child(minimap)

	# Bottom-center interaction prompt pill.
	_prompt_panel = PanelContainer.new()
	_prompt_panel.visible = false
	_prompt_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_prompt_panel.offset_left = -190
	_prompt_panel.offset_top = -126
	_prompt_panel.offset_right = 190
	_prompt_panel.offset_bottom = -86
	_prompt_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var p_style := StyleBoxFlat.new()
	p_style.bg_color = Color(0.06, 0.09, 0.12, 0.85)
	p_style.border_color = Color(0.88, 0.84, 0.62, 0.90)
	p_style.set_border_width_all(2)
	p_style.set_corner_radius_all(8)
	_prompt_panel.add_theme_stylebox_override("panel", p_style)
	add_child(_prompt_panel)

	_prompt_label = Label.new()
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_prompt_label.add_theme_font_size_override("font_size", 16)
	_prompt_panel.add_child(_prompt_label)

	# Bottom-center Building Mode bar.
	_build_bar = PanelContainer.new()
	_build_bar.visible = false
	_build_bar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_build_bar.offset_left = -450
	_build_bar.offset_top = -78
	_build_bar.offset_right = 450
	_build_bar.offset_bottom = -12
	_build_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var b_style := StyleBoxFlat.new()
	b_style.bg_color = Color(0.06, 0.09, 0.11, 0.88)
	b_style.border_color = Color(0.45, 0.72, 0.56, 0.9)
	b_style.set_border_width_all(2)
	b_style.set_corner_radius_all(8)
	b_style.set_content_margin_all(8)
	_build_bar.add_theme_stylebox_override("panel", b_style)
	add_child(_build_bar)

	var b_vbox := VBoxContainer.new()
	b_vbox.add_theme_constant_override("separation", 4)
	_build_bar.add_child(b_vbox)

	_build_pieces_label = Label.new()
	_build_pieces_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_build_pieces_label.add_theme_font_size_override("font_size", 14)
	b_vbox.add_child(_build_pieces_label)

	_build_status_label = Label.new()
	_build_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_build_status_label.add_theme_font_size_override("font_size", 12)
	b_vbox.add_child(_build_status_label)

	# Bottom-left notification toasts.
	_toast_box = VBoxContainer.new()
	_toast_box.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_toast_box.offset_left = 18
	_toast_box.offset_top = -240
	_toast_box.offset_right = 420
	_toast_box.offset_bottom = -20
	_toast_box.alignment = BoxContainer.ALIGNMENT_END
	_toast_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_toast_box)

	# Minimal center-screen death notification ("YOU DIED" + brief cause).
	_death_panel = PanelContainer.new()
	_death_panel.visible = false
	_death_panel.set_anchors_preset(Control.PRESET_CENTER)
	_death_panel.offset_left = -220
	_death_panel.offset_top = -64
	_death_panel.offset_right = 220
	_death_panel.offset_bottom = 64
	_death_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var d_style := StyleBoxFlat.new()
	d_style.bg_color = Color(0.08, 0.02, 0.02, 0.86)
	d_style.border_color = Color(0.78, 0.22, 0.20, 0.90)
	d_style.set_border_width_all(2)
	d_style.set_corner_radius_all(8)
	d_style.set_content_margin_all(14)
	_death_panel.add_theme_stylebox_override("panel", d_style)
	add_child(_death_panel)

	var d_vbox := VBoxContainer.new()
	d_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	d_vbox.add_theme_constant_override("separation", 6)
	_death_panel.add_child(d_vbox)

	_death_title = Label.new()
	_death_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_death_title.add_theme_font_size_override("font_size", 32)
	_death_title.modulate = Color(0.98, 0.28, 0.24)
	_death_title.text = "YOU DIED"
	d_vbox.add_child(_death_title)

	_death_cause = Label.new()
	_death_cause.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_death_cause.add_theme_font_size_override("font_size", 16)
	_death_cause.modulate = Color(0.95, 0.86, 0.82)
	d_vbox.add_child(_death_cause)

	# Minimal temporary respawn banner ("SURVIVAL TRAUMA — RECOVER YOUR EQUIPMENT").
	_respawn_banner = Label.new()
	_respawn_banner.visible = false
	_respawn_banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_respawn_banner.offset_left = -300
	_respawn_banner.offset_top = 86
	_respawn_banner.offset_right = 300
	_respawn_banner.offset_bottom = 118
	_respawn_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_respawn_banner.add_theme_font_size_override("font_size", 18)
	_respawn_banner.add_theme_color_override("font_outline_color", Color.BLACK)
	_respawn_banner.add_theme_constant_override("outline_size", 4)
	_respawn_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_respawn_banner)

	# Temporary top-center recovery indicator (direction + distance to latest unrecovered death cache).
	_recovery_panel = PanelContainer.new()
	_recovery_panel.visible = false
	_recovery_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_recovery_panel.offset_left = -140
	_recovery_panel.offset_top = 18
	_recovery_panel.offset_right = 140
	_recovery_panel.offset_bottom = 50
	_recovery_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var r_style := StyleBoxFlat.new()
	r_style.bg_color = Color(0.08, 0.09, 0.12, 0.82)
	r_style.border_color = Color(0.92, 0.72, 0.36, 0.88)
	r_style.set_border_width_all(1)
	r_style.set_corner_radius_all(6)
	r_style.set_content_margin_all(6)
	_recovery_panel.add_theme_stylebox_override("panel", r_style)
	add_child(_recovery_panel)

	_recovery_label = Label.new()
	_recovery_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_recovery_label.add_theme_font_size_override("font_size", 14)
	_recovery_label.modulate = Color(1.0, 0.88, 0.56)
	_recovery_panel.add_child(_recovery_label)
