class_name MinimapWidget
extends Control
## Circular upper-right minimap rendering live Terrain3D-derived island map,
## North indicator, Kekoa's position & facing direction, and base markers.

const MINIMAP_SHADER := """
shader_type canvas_item;
uniform sampler2D map_tex : filter_linear_mipmap;
uniform vec2 center_uv = vec2(0.5, 0.5);
uniform float zoom_span = 0.22;

void fragment() {
	vec2 d = UV - vec2(0.5);
	float r = length(d);
	if (r > 0.485) {
		discard;
	}
	vec2 sample_uv = center_uv + d * zoom_span;
	vec4 col = vec4(0.03, 0.12, 0.24, 1.0);
	if (sample_uv.x >= 0.0 && sample_uv.x <= 1.0 && sample_uv.y >= 0.0 && sample_uv.y <= 1.0) {
		col = texture(map_tex, sample_uv);
	}
	float rim = smoothstep(0.455, 0.482, r);
	col.rgb = mix(col.rgb, vec3(0.84, 0.78, 0.62), rim * 0.85);
	COLOR = vec4(col.rgb, 0.96);
}
"""

var _map_rect: ColorRect
var _overlay: Control
var _shader_mat: ShaderMaterial
var _world_rect := Rect2(-1024.0, -1024.0, 2048.0, 2048.0)
var _player_uv := Vector2(0.5, 0.5)
var _player_yaw := 0.0
var _zoom_span := 0.22
var _base_uvs: Array[Vector2] = []


func _ready() -> void:
	custom_minimum_size = Vector2(184, 184)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_map_rect = ColorRect.new()
	_map_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_map_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var shader := Shader.new()
	shader.code = MINIMAP_SHADER
	_shader_mat = ShaderMaterial.new()
	_shader_mat.shader = shader
	_shader_mat.set_shader_parameter("zoom_span", _zoom_span)
	_map_rect.material = _shader_mat
	add_child(_map_rect)

	_overlay = MinimapOverlayDraw.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.widget = self
	add_child(_overlay)


func set_map_data(tex: Texture2D, world_rect: Rect2) -> void:
	_world_rect = world_rect
	if _shader_mat:
		_shader_mat.set_shader_parameter("map_tex", tex)


func update_state(player_pos: Vector3, facing_dir: Vector3, base_positions: Array[Vector3]) -> void:
	_player_uv = IslandMapGenerator.world_to_uv(player_pos, _world_rect)
	# Map north is -Z (screen -Y); East is +X (screen +X).
	_player_yaw = atan2(facing_dir.x, -facing_dir.z)
	_base_uvs.clear()
	for bp in base_positions:
		_base_uvs.append(IslandMapGenerator.world_to_uv(bp, _world_rect))
	if _shader_mat:
		_shader_mat.set_shader_parameter("center_uv", _player_uv)
	if _overlay:
		_overlay.queue_redraw()


func _draw_overlay(canvas: Control) -> void:
	var c := canvas.size * 0.5
	var rad := minf(c.x, c.y) * 0.94
	canvas.draw_arc(c, rad, 0.0, TAU, 48, Color(0.92, 0.86, 0.70, 0.92), 2.5, true)

	# North indicator badge at top of circle.
	var font := ThemeDB.fallback_font
	var n_pos := c + Vector2(0.0, -rad + 2.0)
	canvas.draw_circle(n_pos, 10.0, Color(0.11, 0.14, 0.17, 0.92))
	canvas.draw_arc(n_pos, 10.0, 0.0, TAU, 20, Color(0.95, 0.80, 0.40, 0.95), 1.5)
	canvas.draw_string(font, n_pos + Vector2(-4.5, 4.5), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1.0, 0.87, 0.45))

	# Base markers projected relative to player center.
	for buv in _base_uvs:
		var rel := (buv - _player_uv) / _zoom_span * canvas.size
		if rel.length() > rad - 10.0:
			rel = rel.normalized() * (rad - 10.0)
		var mp := c + rel
		var house := PackedVector2Array([
			mp + Vector2(0, -6),
			mp + Vector2(6, -1),
			mp + Vector2(4, 5),
			mp + Vector2(-4, 5),
			mp + Vector2(-6, -1),
		])
		canvas.draw_colored_polygon(house, Color(1.0, 0.76, 0.24, 0.95))
		canvas.draw_polyline(house + PackedVector2Array([house[0]]), Color(0.12, 0.09, 0.05), 1.4)

	# Player facing arrow at center.
	var dir := Vector2(sin(_player_yaw), -cos(_player_yaw))
	var right := Vector2(dir.y, -dir.x)
	var arrow := PackedVector2Array([
		c + dir * 9.0,
		c - dir * 6.0 + right * 5.5,
		c - dir * 3.0,
		c - dir * 6.0 - right * 5.5,
	])
	canvas.draw_colored_polygon(arrow, Color(1.0, 0.97, 0.90, 0.98))
	canvas.draw_polyline(arrow + PackedVector2Array([arrow[0]]), Color(0.10, 0.12, 0.15, 0.95), 1.5)


class MinimapOverlayDraw extends Control:
	var widget: MinimapWidget

	func _draw() -> void:
		if widget:
			widget._draw_overlay(self)
