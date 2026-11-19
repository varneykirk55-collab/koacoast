extends Node3D
## Builds shallow, bank-fitted freshwater ribbons from surveyed Terrain3D drainage lines.
## Point rows contain world X, Z, water elevation and upstream catchment cell count.

const WATERSHEDS := preload("res://freshwater/watersheds.json")
const CURRENT := preload("res://freshwater/current.gdshader")
const SPRAY := preload("res://freshwater/spray.gdshader")
const BANK_STEP := 0.25
const CROSS_SECTIONS := 6

var _terrain: Terrain3DData
var _current := ShaderMaterial.new()
var _spray := SurfaceTool.new()


func _ready() -> void:
	_build.call_deferred()


func _build() -> void:
	_terrain = (get_node("../Terrain3D") as Terrain3D).data
	_current.shader = CURRENT
	_spray.begin(Mesh.PRIMITIVE_TRIANGLES)
	for watershed: Dictionary in WATERSHEDS.data:
		var group := Node3D.new()
		group.name = watershed.name
		add_child(group)
		_add_channel(group, "River", watershed.river, true)
		for i in watershed.streams.size():
			_add_channel(group, "Tributary%d" % (i + 1), watershed.streams[i], false)

	var spray_material := ShaderMaterial.new()
	spray_material.shader = SPRAY
	var mist := _add_mesh(self, "WaterfallSpray", _spray.commit(), spray_material)
	mist.extra_cull_margin = 6.0


func _add_channel(group: Node3D, label: String, channel: Dictionary, main: bool) -> void:
	var mesh := SurfaceTool.new()
	mesh.begin(Mesh.PRIMITIVE_TRIANGLES)
	var points: Array = channel.points
	var distance := 0.0
	var previous := _position(points[0])
	for i in points.size():
		var point: Array = points[i]
		var center := _position(point)
		distance += center.distance_to(previous)
		previous = center
		var prior := _position(points[maxi(i - 1, 0)])
		var next := _position(points[mini(i + 1, points.size() - 1)])
		var tangent := next - prior
		var across := Vector3(-tangent.z, 0, tangent.x).normalized()
		var slope := maxf(0.0, -tangent.y / maxf(0.1, Vector2(tangent.x, tangent.z).length()))
		var rapid := smoothstep(0.26, 0.92, slope)
		var impact := 0.0
		for fall: Array in channel.falls:
			if i >= int(fall[0]) and i < int(fall[1]):
				rapid = maxf(rapid, 0.88)
			if i == int(fall[1]):
				_add_spray(center, clampf((_position(points[int(fall[0])]).y - center.y) * 0.07, 0.55, 1.9))
			impact = maxf(impact, 1.0 - absf(i - float(fall[1])) / 3.0)

		var width := clampf(sqrt(float(point[3])) * 0.016, 0.47, 2.45)
		if not main:
			width = minf(width, 1.15)
		for pool: Array in channel.pools:
			if i >= int(pool[0]) and i <= int(pool[1]):
				width += sin(PI * (i - float(pool[0])) / (float(pool[1]) - float(pool[0]))) * 2.1
				rapid *= 0.35
		width *= smoothstep(0.0, 5.0, i)
		var coastal := 1.0 - smoothstep(0.04, 1.6, center.y) if main else 0.0
		var left := _bank_distance(center, -across, width)
		var right := _bank_distance(center, across, width)
		for column in CROSS_SECTIONS + 1:
			var u := float(column) / CROSS_SECTIONS
			var offset := -left * (1.0 - u * 2.0) if u < 0.5 else right * (u * 2.0 - 1.0)
			var vertex := center + across * offset
			var bed := _terrain.get_height(vertex)
			var edge := column == 0 or column == CROSS_SECTIONS
			# Sink the outermost vertices slightly into the existing bed.
			if edge and not is_nan(bed):
				vertex.y = minf(vertex.y, bed - 0.025) if coastal < 0.96 else vertex.y
			var depth := clampf((center.y - bed) * 1.45, 0.0, 1.0)
			mesh.set_color(Color(0.0 if edge else depth, rapid, impact, coastal))
			mesh.set_uv(Vector2(u, distance))
			mesh.set_normal(across.cross(tangent).normalized())
			mesh.add_vertex(vertex)
		if i > 0:
			var row := (i - 1) * (CROSS_SECTIONS + 1)
			for column in CROSS_SECTIONS:
				var a := row + column
				var b := a + CROSS_SECTIONS + 1
				for index: int in [a, b, a + 1, a + 1, b, b + 1]:
					mesh.add_index(index)

	_add_mesh(group, label, mesh.commit(), _current)


func _bank_distance(center: Vector3, direction: Vector3, width: float) -> float:
	for step in ceili(width / BANK_STEP):
		var distance := minf(width, (step + 1) * BANK_STEP)
		var ground := _terrain.get_height(center + direction * distance)
		if not is_nan(ground) and ground >= center.y:
			return distance
	return width


func _add_spray(base: Vector3, scale: float) -> void:
	for i in 9:
		var seed := fposmod(i * 0.618 + base.x * 0.036 + base.z * 0.02, 1.0)
		for corner: Vector2 in [Vector2.ZERO, Vector2.RIGHT, Vector2.ONE, Vector2.ZERO, Vector2.ONE, Vector2.DOWN]:
			_spray.set_uv(corner)
			_spray.set_color(Color(seed, scale, 0, 1))
			_spray.add_vertex(base)


func _add_mesh(parent: Node3D, label: String, geometry: ArrayMesh, material: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = label
	node.mesh = geometry
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(node)
	return node


func _position(point: Array) -> Vector3:
	return Vector3(point[0], point[2], point[1])
