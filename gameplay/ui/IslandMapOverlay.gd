class_name IslandMapOverlay
extends PanelContainer
## Full-screen island map showing Terrain3D-derived island geography, rivers,
## Kekoa's live position/facing, and player-built base markers with zoom & pan.

signal close_requested

var _canvas: MapCanvasControl
var _coord_label: Label
var _zoom := 1.0
var _pan := Vector2.ZERO
var _dragging := false
var _map_tex: Texture2D
var _world_rect := Rect2(-1024.0, -1024.0, 2048.0, 2048.0)
var _player_pos := Vector3.ZERO
var _player_uv := Vector2(0.5, 0.5)
var _player_yaw := 0.0
var _base_uvs: Array[Vector2] = []


func _ready() -> void:
	visible = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	offset_left = 36
	offset_top = 36
	offset_right = -36
	offset_bottom = -36
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.09, 0.12, 0.98)
	style.border_color = Color(0.45, 0.62, 0.66, 0.90)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(14)
	add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	add_child(vbox)

	var header := HBoxContainer.new()
	vbox.add_child(header)

	var title := Label.new()
	title.text = "KOACOAST ISLAND MAP"
	title.add_theme_font_size_override("font_size", 20)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	_coord_label = Label.new()
	_coord_label.text = "Pos: 0, 0"
	header.add_child(_coord_label)

	var close_btn := Button.new()
	close_btn.text = "Close [M / B / Esc]"
	close_btn.pressed.connect(func(): close_requested.emit())
	header.add_child(close_btn)

	_canvas = MapCanvasControl.new()
	_canvas.owner_overlay = self
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas.clip_contents = true
	_canvas.focus_mode = Control.FOCUS_ALL
	vbox.add_child(_canvas)

	var footer := Label.new()
	footer.text = "Zoom: Wheel / + - / LB RB   |   Pan: Drag or Left Stick   |   White Arrow: Kekoa   |   Gold House: Base"
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	footer.modulate = Color(0.84, 0.89, 0.92)
	vbox.add_child(footer)


func set_map_data(tex: Texture2D, world_rect: Rect2) -> void:
	_map_tex = tex
	_world_rect = world_rect
	if _canvas:
		_canvas.queue_redraw()


func open_map() -> void:
	visible = true
	_zoom = 1.0
	_pan = Vector2.ZERO
	if _canvas:
		_canvas.grab_focus()
		_canvas.queue_redraw()


func close_map() -> void:
	visible = false


func update_state(player_pos: Vector3, facing_dir: Vector3, base_positions: Array[Vector3]) -> void:
	_player_pos = player_pos
	_player_uv = IslandMapGenerator.world_to_uv(player_pos, _world_rect)
	_player_yaw = atan2(facing_dir.x, -facing_dir.z)
	_base_uvs.clear()
	for bp in base_positions:
		_base_uvs.append(IslandMapGenerator.world_to_uv(bp, _world_rect))
	if _coord_label:
		_coord_label.text = "X: %.0f m  Z: %.0f m  Elev: %.1f m  Bases: %d   " % [player_pos.x, player_pos.z, player_pos.y, _base_uvs.size()]
	if visible and _canvas:
		_canvas.queue_redraw()


func _process(delta: float) -> void:
	if not visible:
		return
	var stick := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	if stick.length() > 0.15:
		_pan -= stick * 320.0 * delta
		_clamp_pan()
		_canvas.queue_redraw()
	if Input.is_action_pressed("build_rotate_cw"):
		_adjust_zoom(1.0 + 1.2 * delta)
	elif Input.is_action_pressed("build_rotate_ccw"):
		_adjust_zoom(1.0 - 1.2 * delta)


func _gui_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_adjust_zoom(1.15)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_adjust_zoom(1.0 / 1.15)
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
	elif event is InputEventMouseMotion and _dragging:
		_pan += (event as InputEventMouseMotion).relative
		_clamp_pan()
		_canvas.queue_redraw()


func _adjust_zoom(factor: float) -> void:
	_zoom = clampf(_zoom * factor, 1.0, 4.5)
	_clamp_pan()
	if _canvas:
		_canvas.queue_redraw()


func _clamp_pan() -> void:
	if _canvas == null:
		return
	var max_pan := _canvas.size * 0.45 * (_zoom - 1.0)
	_pan.x = clampf(_pan.x, -max_pan.x, max_pan.x)
	_pan.y = clampf(_pan.y, -max_pan.y, max_pan.y)


func _draw_canvas(canvas: Control) -> void:
	var c := canvas.size * 0.5
	var base_side := minf(canvas.size.x, canvas.size.y) * 0.94 * _zoom
	var top_left := c + _pan - Vector2(base_side, base_side) * 0.5
	var rect := Rect2(top_left, Vector2(base_side, base_side))
	if _map_tex:
		canvas.draw_texture_rect(_map_tex, rect, false)
	canvas.draw_rect(rect, Color(0.85, 0.80, 0.64, 0.75), false, 2.0)

	var font := ThemeDB.fallback_font
	canvas.draw_string(font, Vector2(c.x - 6.0, 22.0), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1.0, 0.88, 0.45))

	for buv in _base_uvs:
		var mp := rect.position + buv * rect.size
		var house := PackedVector2Array([
			mp + Vector2(0, -8),
			mp + Vector2(8, -1),
			mp + Vector2(6, 7),
			mp + Vector2(-6, 7),
			mp + Vector2(-8, -1),
		])
		canvas.draw_colored_polygon(house, Color(1.0, 0.78, 0.25, 0.98))
		canvas.draw_polyline(house + PackedVector2Array([house[0]]), Color(0.1, 0.08, 0.04), 1.8)

	var pp := rect.position + _player_uv * rect.size
	var dir := Vector2(sin(_player_yaw), -cos(_player_yaw))
	var right := Vector2(dir.y, -dir.x)
	var arrow := PackedVector2Array([
		pp + dir * 12.0,
		pp - dir * 8.0 + right * 7.0,
		pp - dir * 4.0,
		pp - dir * 8.0 - right * 7.0,
	])
	canvas.draw_colored_polygon(arrow, Color(1.0, 0.98, 0.92, 1.0))
	canvas.draw_polyline(arrow + PackedVector2Array([arrow[0]]), Color(0.08, 0.1, 0.14), 1.8)


class MapCanvasControl extends Control:
	var owner_overlay: IslandMapOverlay

	func _draw() -> void:
		if owner_overlay:
			owner_overlay._draw_canvas(self)
