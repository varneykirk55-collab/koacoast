@tool
extends Node3D
## Read-only slope overlay for Koa Coast. Off until show_overlay is checked or F8 is pressed.
##
## Keys are read in this script. Nothing is added to the Input Map.
##   F8        toggle the overlay
##   M         cycle slope / elevation / both
##   T         toggle a top-down camera (overlay on)
##   [ ]       lower / raise the steep threshold by 1°
##   , .       lower / raise the gentle threshold by 1°
##
## Threshold nudges turn auto_thresholds off so the edited numbers stick.
## See tools/README.md.

const Analyzer := preload("res://tools/slope_analyzer.gd")

@export var show_overlay: bool = false:
	set(value):
		show_overlay = value
		if is_inside_tree() and not _applying:
			_apply_visibility()

@export_group("Thresholds")
## When on, gentle = 30% and moderate = 70% of Player.tscn floor_max_angle.
@export var auto_thresholds: bool = true:
	set(value):
		auto_thresholds = value
		if is_inside_tree() and not _applying and auto_thresholds:
			_apply_auto_thresholds()
			_classes_dirty = true
			if show_overlay:
				_refresh()

## Green / gentle slopes are below this angle. Ignored while auto_thresholds is on.
@export_range(1.0, 80.0, 0.5) var gentle_max_deg: float = 15.0:
	set(value):
		gentle_max_deg = value
		_on_threshold_edited()

## Red / steep slopes start at this angle. Yellow is the band between the two.
@export_range(1.0, 89.0, 0.5) var moderate_max_deg: float = 35.0:
	set(value):
		moderate_max_deg = value
		_on_threshold_edited()

@export_enum("Slope", "Elevation", "Both") var view_mode: int = 0:
	set(value):
		view_mode = clampi(value, 0, 2)
		if is_inside_tree() and not _applying and show_overlay:
			_texture_dirty = true
			_refresh()

@export var contour_interval_m: float = 25.0
@export var hover_m: float = 1.0

var _applying := false
var _grid: Dictionary = {}
var _report: Dictionary = {}
var _classes_dirty := true
var _texture_dirty := true
var _floor_max_deg := 50.0
var _mesh_instance: MeshInstance3D
var _canvas: CanvasLayer
var _title: Label
var _mode_label: Label
var _swatch_labels: Array[Label] = []
var _swatch_chips: Array[ColorRect] = []
var _stats: Label
var _clusters: Label
var _hints: Label
var _camera: Camera3D
var _saved_camera: Camera3D
var _top_down_on := false


func _ready() -> void:
	if auto_thresholds:
		_apply_auto_thresholds()
	if show_overlay:
		_refresh()


func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo or key.ctrl_pressed or key.alt_pressed or key.meta_pressed:
		return
	if key.keycode == KEY_F8:
		show_overlay = not show_overlay
		get_viewport().set_input_as_handled()
	elif show_overlay and key.keycode == KEY_M:
		view_mode = (view_mode + 1) % 3
		get_viewport().set_input_as_handled()
	elif show_overlay and key.keycode == KEY_T:
		set_top_down(not _top_down_on)
		get_viewport().set_input_as_handled()
	elif show_overlay and key.keycode == KEY_BRACKETLEFT:
		_nudge_moderate(-1.0)
		get_viewport().set_input_as_handled()
	elif show_overlay and key.keycode == KEY_BRACKETRIGHT:
		_nudge_moderate(1.0)
		get_viewport().set_input_as_handled()
	elif show_overlay and key.keycode == KEY_COMMA:
		_nudge_gentle(-1.0)
		get_viewport().set_input_as_handled()
	elif show_overlay and key.keycode == KEY_PERIOD:
		_nudge_gentle(1.0)
		get_viewport().set_input_as_handled()


func set_top_down(enabled: bool) -> void:
	_top_down_on = enabled and show_overlay
	if not _top_down_on:
		if _camera:
			_camera.current = false
		if is_instance_valid(_saved_camera):
			_saved_camera.current = true
		_saved_camera = null
		return
	if _grid.is_empty():
		return
	if _camera == null:
		_camera = Camera3D.new()
		_camera.name = "SlopeTopDown"
		_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		_camera.near = 0.5
		_camera.far = 20000.0
		add_child(_camera)
	var origin: Vector2 = _grid.origin
	var w: int = _grid.w
	var d: int = _grid.d
	var spacing: float = _grid.spacing
	var cx := origin.x + float(w - 1) * spacing * 0.5
	var cz := origin.y + float(d - 1) * spacing * 0.5
	# Straight down. With this pitch, screen up is world +Z (north) and screen right is +X.
	var span := maxf(float(w - 1), float(d - 1)) * spacing
	_camera.size = span * 0.9
	var vp := get_viewport().get_visible_rect().size
	var aspect := vp.x / maxf(vp.y, 1.0)
	# Slide east so the island sits in the open area left of the legend.
	var shift := _camera.size * aspect * 0.12
	_camera.position = Vector3(cx + shift, float(_grid.max_h) + 800.0, cz)
	_camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	var current := get_viewport().get_camera_3d()
	if current != _camera:
		_saved_camera = current
	_camera.current = true


func _nudge_gentle(delta: float) -> void:
	_applying = true
	auto_thresholds = false
	gentle_max_deg = clampf(snappedf(gentle_max_deg + delta, 0.5), 1.0, moderate_max_deg - 0.5)
	_applying = false
	_classes_dirty = true
	_texture_dirty = true
	_refresh()


func _nudge_moderate(delta: float) -> void:
	_applying = true
	auto_thresholds = false
	moderate_max_deg = clampf(snappedf(moderate_max_deg + delta, 0.5), gentle_max_deg + 0.5, 89.0)
	_applying = false
	_classes_dirty = true
	_texture_dirty = true
	_refresh()


func _on_threshold_edited() -> void:
	if _applying or not is_inside_tree():
		return
	_classes_dirty = true
	_texture_dirty = true
	if show_overlay:
		_refresh()


func _apply_auto_thresholds() -> void:
	var limits := Analyzer.thresholds_from_player()
	_applying = true
	gentle_max_deg = limits.x
	moderate_max_deg = limits.y
	_floor_max_deg = limits.z
	_applying = false


func _apply_visibility() -> void:
	if not show_overlay:
		if _mesh_instance:
			_mesh_instance.visible = false
		if _canvas:
			_canvas.visible = false
		set_top_down(false)
		return
	_refresh()


func _refresh() -> void:
	if not show_overlay:
		return
	var terrain := get_parent().get_node_or_null("Terrain3D") if get_parent() else null
	if terrain == null:
		push_warning("SlopeAnalysis: Terrain3D sibling not found.")
		return
	if _grid.is_empty():
		var analyzer = Analyzer.new()
		_grid = analyzer.load_grid(terrain)
		if auto_thresholds:
			_floor_max_deg = Analyzer.thresholds_from_player().z
		_classes_dirty = true
		_texture_dirty = true
	if _grid.is_empty():
		return
	if _classes_dirty or _report.is_empty():
		var analyzer = Analyzer.new()
		_report = analyzer.classify(_grid, gentle_max_deg, moderate_max_deg, _floor_max_deg)
		_report["contour_m"] = contour_interval_m
		_classes_dirty = false
		_texture_dirty = true
	if _mesh_instance == null:
		_build_mesh()
	if _texture_dirty:
		_apply_texture()
		_texture_dirty = false
	_mesh_instance.visible = true
	_ensure_ui()
	_fill_ui()
	_canvas.visible = true


func _build_mesh() -> void:
	var heights: PackedFloat32Array = _grid.heights
	var w: int = _grid.w
	var d: int = _grid.d
	var spacing: float = _grid.spacing
	var origin: Vector2 = _grid.origin
	var step := 2
	var nx := int((w - 1) / step) + 1
	var nz := int((d - 1) / step) + 1
	var verts := PackedVector3Array()
	verts.resize(nx * nz)
	var uvs := PackedVector2Array()
	uvs.resize(nx * nz)
	for j in nz:
		var pz := mini(j * step, d - 1)
		var z := origin.y + float(pz) * spacing
		for i in nx:
			var px := mini(i * step, w - 1)
			var h: float = heights[pz * w + px]
			var y := 0.2
			if h >= 0.0:
				y = h + hover_m
			var vi := j * nx + i
			verts[vi] = Vector3(origin.x + float(px) * spacing, y, z)
			uvs[vi] = Vector2(float(px) / float(w - 1), 1.0 - float(pz) / float(d - 1))
	var indices := PackedInt32Array()
	indices.resize((nx - 1) * (nz - 1) * 6)
	var count := 0
	for j in nz - 1:
		for i in nx - 1:
			var pz0 := mini(j * step, d - 1)
			var pz1 := mini((j + 1) * step, d - 1)
			var px0 := mini(i * step, w - 1)
			var px1 := mini((i + 1) * step, w - 1)
			if heights[pz0 * w + px0] < 0.0 and heights[pz0 * w + px1] < 0.0 and heights[pz1 * w + px0] < 0.0 and heights[pz1 * w + px1] < 0.0:
				continue
			var a := j * nx + i
			var b := a + 1
			var c := a + nx
			var e := c + 1
			indices[count] = a
			indices[count + 1] = c
			indices[count + 2] = b
			indices[count + 3] = b
			indices[count + 4] = c
			indices[count + 5] = e
			count += 6
	indices.resize(count)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "SlopeMesh"
	_mesh_instance.mesh = mesh
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mesh_instance.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(_mesh_instance)


func _apply_texture() -> void:
	var analyzer = Analyzer.new()
	var image: Image = analyzer.render_map(_grid, _report, view_mode, true)
	var texture := ImageTexture.create_from_image(image)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	material.albedo_texture = texture
	material.albedo_color = Color(1, 1, 1, 0.92)
	_mesh_instance.material_override = material


func _ensure_ui() -> void:
	if _canvas:
		return
	_canvas = CanvasLayer.new()
	_canvas.name = "SlopeLegend"
	_canvas.layer = 20
	add_child(_canvas)
	var panel := PanelContainer.new()
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_top = 0.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -380.0
	panel.offset_right = -12.0
	panel.offset_top = 12.0
	panel.offset_bottom = -12.0
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.02, 0.055, 0.08, 0.88)
	style.border_color = Color(0.42, 0.86, 0.96, 0.95)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 14.0
	style.content_margin_right = 14.0
	style.content_margin_top = 12.0
	style.content_margin_bottom = 12.0
	panel.add_theme_stylebox_override("panel", style)
	_canvas.add_child(panel)
	var margin := MarginContainer.new()
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	margin.add_child(box)
	_title = _label(box, 20, Color(0.55, 0.93, 1.0))
	_mode_label = _label(box, 15, Color(0.86, 0.94, 0.96))
	for _i in 3:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		box.add_child(row)
		var chip := ColorRect.new()
		chip.custom_minimum_size = Vector2(16, 16)
		row.add_child(chip)
		_swatch_chips.append(chip)
		var text := _label(row, 14, Color(0.9, 0.95, 0.97))
		_swatch_labels.append(text)
	_stats = _label(box, 14, Color(0.82, 0.91, 0.94))
	_clusters = _label(box, 13, Color(0.78, 0.88, 0.9))
	_clusters.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(spacer)
	_hints = _label(box, 13, Color(0.55, 0.75, 0.8))
	_hints.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART


func _label(parent: Node, size: int, color: Color) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	parent.add_child(label)
	return label


func _fill_ui() -> void:
	var names := ["Slope", "Elevation", "Slope + contours"]
	_title.text = "Koa Coast slope"
	_mode_label.text = "Mode  %s" % names[view_mode]
	if _swatch_chips.size() >= 3:
		_swatch_chips[0].color = Analyzer.COL_GENTLE
		_swatch_chips[1].color = Analyzer.COL_MOD
		_swatch_chips[2].color = Analyzer.COL_STEEP
	_swatch_labels[0].text = "Gentle     0–%.0f°" % gentle_max_deg
	_swatch_labels[1].text = "Moderate   %.0f–%.0f°" % [gentle_max_deg, moderate_max_deg]
	_swatch_labels[2].text = "Steep      %.0f°+" % moderate_max_deg
	var land := maxi(int(_report.land_cells), 1)
	var gentle_pct := 100.0 * float(_report.gentle_cells) / float(land)
	var moderate_pct := 100.0 * float(_report.moderate_cells) / float(land)
	var steep_pct := 100.0 * float(_report.steep_cells) / float(land)
	var over_pct := 100.0 * float(_report.unwalkable_cells) / float(land)
	var area := float(_report.land_area_m2) / 1.0e6
	_stats.text = "Land %.2f km²\nGentle %.1f%%    Moderate %.1f%%\nSteep %.1f%%    Over %.0f° walk limit %.1f%%\nHeight %.0f to %.0f m" % [
		area, gentle_pct, moderate_pct, steep_pct, _floor_max_deg, over_pct, float(_report.min_h), float(_report.max_h)
	]
	var cluster_lines := "Worst steep ground"
	if not _report.clusters.is_empty():
		cluster_lines = "Cliffs >= %.0f°" % float(_report.clusters[0].cut_deg)
	var rank := 1
	for cluster in _report.clusters:
		if rank > 6:
			break
		cluster_lines += "\n%d  (%.0f, %.0f)  %.0f°  %.0f m²" % [
			rank, float(cluster.max_x), float(cluster.max_z), float(cluster.max_deg), float(cluster.area_m2)
		]
		rank += 1
	if rank == 1:
		cluster_lines += "\nNone at this threshold."
	_clusters.text = cluster_lines
	var auto := "auto from player" if auto_thresholds else "manual"
	_hints.text = "Walk limit %.0f°  (%s)\nF8 overlay    M mode    T top-down\n[ ] steep    , . gentle" % [_floor_max_deg, auto]
