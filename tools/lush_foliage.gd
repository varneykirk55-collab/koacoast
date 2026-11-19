extends SceneTree
## Fill the lowlands with the existing plant meshes and re-seat old instances.
## Does not write terrain. Run:
##   godot --headless --path . --script res://tools/lush_foliage.gd

const FOLIAGE_SCENE := "res://foliage/IslandVegetation.scn"
const MATERIAL := "res://foliage/materials/Foliage.tres"
const ROUTES := "res://docs/walkability_routes.json"
const SPAWN := Vector2(48.0, 576.0)
const SPAWN_CLEAR_M := 14.0
const CORRIDOR_M := 11.0

const MESHES := {
	"Sedge": "res://foliage/meshes/Sedge.obj",
	"Fern": "res://foliage/meshes/Fern.obj",
	"CoastalShrub": "res://foliage/meshes/CoastalShrub.obj",
	"Broadleaf": "res://foliage/meshes/Broadleaf.obj",
	"FanPalm": "res://foliage/meshes/FanPalm.obj",
}

var _w := 0
var _d := 0
var _spacing := 2.0
var _origin := Vector2.ZERO
var _heights := PackedFloat32Array()
var _slopes := PackedFloat32Array()
var _lava := PackedFloat32Array()
var _block := PackedByteArray() # 1 = no trees/shrubs/palms, 2 = spawn, nothing
var _route_pts: Array[Vector2] = []
var _terrain_data = null
var _mesh_res := {}
var _material: Material
var _buckets := {}
var _added := {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var scene := (load("res://scenes/KoaCoast.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	for _i in 4:
		await process_frame
	var terrain := scene.get_node("Terrain3D")
	_terrain_data = terrain.data
	_load_grid(terrain)
	_paint_masks()
	_material = load(MATERIAL)
	for kind in MESHES:
		_mesh_res[kind] = load(MESHES[kind])
		_added[kind] = 0
	var veg := scene.get_node("IslandVegetation")
	var before := _count(veg)
	print("BEFORE ", before)
	var reseated := _reseat(veg)
	print("RESEATED ", reseated)
	_scatter()
	_build_chunks(veg)
	var after := _count(veg)
	print("AFTER ", after)
	print("ADDED ", _added)
	var blocked_large := _count_large_in_corridor(veg)
	var spawn_plants := _count_near_spawn(veg, SPAWN_CLEAR_M - 1.0)
	print("CORRIDOR_LARGE ", blocked_large)
	print("SPAWN_PLANTS ", spawn_plants)
	_density_map(veg)
	for c in veg.get_children():
		c.owner = veg
	var packed := PackedScene.new()
	var err := packed.pack(veg)
	if err != OK:
		push_error("pack failed " + error_string(err))
		quit(1)
		return
	err = ResourceSaver.save(packed, FOLIAGE_SCENE)
	if err != OK:
		push_error("save failed " + error_string(err))
		quit(1)
		return
	print("SAVED ", FOLIAGE_SCENE)
	quit(0)


func _load_grid(terrain: Node) -> void:
	var data = terrain.data
	var regions: Array = data.get_regions_active()
	var rs := int(terrain.region_size)
	_spacing = float(terrain.vertex_spacing)
	var min_loc := Vector2i(1 << 20, 1 << 20)
	var max_loc := Vector2i(-(1 << 20), -(1 << 20))
	for region in regions:
		var loc: Vector2i = region.location
		min_loc.x = mini(min_loc.x, loc.x)
		min_loc.y = mini(min_loc.y, loc.y)
		max_loc.x = maxi(max_loc.x, loc.x)
		max_loc.y = maxi(max_loc.y, loc.y)
	_w = (max_loc.x - min_loc.x + 1) * rs
	_d = (max_loc.y - min_loc.y + 1) * rs
	_origin = Vector2(float(min_loc.x * rs) * _spacing, float(min_loc.y * rs) * _spacing)
	_heights.resize(_w * _d)
	_lava.resize(_w * _d)
	for region in regions:
		var himg := (region.height_map as Image).duplicate() as Image
		if himg.get_format() != Image.FORMAT_RF:
			himg.convert(Image.FORMAT_RF)
		var hv: PackedFloat32Array = himg.get_data().to_float32_array()
		var cimg: Image = region.control_map
		var cb := PackedByteArray()
		if cimg != null:
			var copy := cimg.duplicate() as Image
			if copy.get_format() != Image.FORMAT_RF:
				copy.convert(Image.FORMAT_RF)
			cb = copy.get_data()
		var loc: Vector2i = region.location
		var ox := (loc.x - min_loc.x) * rs
		var oz := (loc.y - min_loc.y) * rs
		for py in rs:
			var dst := (oz + py) * _w + ox
			var src := py * rs
			for px in rs:
				_heights[dst + px] = hv[src + px]
				if not cb.is_empty():
					var u := cb.decode_u32((src + px) * 4)
					var base_id := (u >> 27) & 0x1F
					var ovr_id := (u >> 22) & 0x1F
					var blend := float((u >> 14) & 0xFF) / 255.0
					var bw := (1.0 - blend if base_id == 0 else 0.0) + (blend if ovr_id == 0 else 0.0)
					var wx := _origin.x + float(ox + px) * _spacing
					var wz := _origin.y + float(oz + py) * _spacing
					var east := clampf((wx - 220.0) / 220.0, 0.0, 1.0)
					var south := clampf((20.0 - wz) / 180.0, 0.0, 1.0)
					_lava[dst + px] = east * south * clampf((bw - 0.32) / 0.4, 0.0, 1.0)
	_slopes.resize(_w * _d)
	for z in _d:
		for x in _w:
			var i := z * _w + x
			var h: float = _heights[i]
			var h_l: float
			var h_r: float
			var span_x: float
			if x == 0:
				h_l = h
				h_r = _heights[i + 1]
				span_x = _spacing
			elif x == _w - 1:
				h_l = _heights[i - 1]
				h_r = h
				span_x = _spacing
			else:
				h_l = _heights[i - 1]
				h_r = _heights[i + 1]
				span_x = _spacing * 2.0
			var h_d: float
			var h_u: float
			var span_z: float
			if z == 0:
				h_d = h
				h_u = _heights[i + _w]
				span_z = _spacing
			elif z == _d - 1:
				h_d = _heights[i - _w]
				h_u = h
				span_z = _spacing
			else:
				h_d = _heights[i - _w]
				h_u = _heights[i + _w]
				span_z = _spacing * 2.0
			var dhdx := (h_r - h_l) / span_x
			var dhdz := (h_u - h_d) / span_z
			_slopes[i] = rad_to_deg(atan(sqrt(dhdx * dhdx + dhdz * dhdz)))


func _paint_masks() -> void:
	_block.resize(_w * _d)
	var doc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(ROUTES))
	var rad := int(ceil(CORRIDOR_M / _spacing))
	var rad2 := rad * rad
	for route in doc["routes"]:
		var prev := Vector2.INF
		for pt in route["path"]:
			var z := int(pt[0])
			var x := int(pt[1])
			var world := Vector2(_origin.x + float(x) * _spacing, _origin.y + float(z) * _spacing)
			if prev != Vector2.INF:
				_route_pts.append((prev + world) * 0.5)
			_route_pts.append(world)
			prev = world
			for dz in range(-rad, rad + 1):
				var zz := z + dz
				if zz < 0 or zz >= _d:
					continue
				for dx in range(-rad, rad + 1):
					if dz * dz + dx * dx > rad2:
						continue
					var xx := x + dx
					if xx < 0 or xx >= _w:
						continue
					_block[zz * _w + xx] = 1
	var sz := int(round((SPAWN.y - _origin.y) / _spacing))
	var sx := int(round((SPAWN.x - _origin.x) / _spacing))
	var sr := int(ceil(SPAWN_CLEAR_M / _spacing))
	for dz in range(-sr, sr + 1):
		for dx in range(-sr, sr + 1):
			if dz * dz + dx * dx > sr * sr:
				continue
			var zz := sz + dz
			var xx := sx + dx
			if zz < 0 or xx < 0 or zz >= _d or xx >= _w:
				continue
			_block[zz * _w + xx] = 2
	print("ROUTE_POINTS ", _route_pts.size())


func _cell(x: float, z: float) -> int:
	var cx := int(round((x - _origin.x) / _spacing))
	var cz := int(round((z - _origin.y) / _spacing))
	cx = clampi(cx, 0, _w - 1)
	cz = clampi(cz, 0, _d - 1)
	return cz * _w + cx


func _surface(x: float, z: float) -> float:
	return float(_terrain_data.get_height(Vector3(x, 0.0, z)))


func _dist_to_route(p: Vector2) -> float:
	var best := INF
	for i in _route_pts.size():
		best = minf(best, p.distance_squared_to(_route_pts[i]))
	return sqrt(best)


func _reseat(veg: Node) -> int:
	var n := 0
	var pushed := 0
	for c in veg.get_children():
		if not (c is MultiMeshInstance3D):
			continue
		var mmi := c as MultiMeshInstance3D
		var mm := mmi.multimesh
		if mm == null or mm.instance_count == 0:
			continue
		var kind := _kind_of(mm)
		var large := kind == "Broadleaf" or kind == "FanPalm" or kind == "CoastalShrub"
		var buf := mm.buffer
		var stride := int(buf.size() / mm.instance_count)
		for k in mm.instance_count:
			var at := k * stride
			var local := Vector3(buf[at + 3], buf[at + 7], buf[at + 11])
			var world: Vector3 = mmi.global_transform * local
			var flat := Vector2(world.x, world.z)
			var on_spawn := flat.distance_to(SPAWN) < SPAWN_CLEAR_M
			var on_path := large and _dist_to_route(flat) < CORRIDOR_M + 0.5
			if on_spawn or on_path:
				var anchor := SPAWN if on_spawn else _nearest_route(flat)
				var away := flat - anchor
				if away.length() < 0.25:
					away = Vector2(0.8, 0.45)
				var clear := (SPAWN_CLEAR_M + 2.0) if on_spawn else (CORRIDOR_M + 2.5)
				for _step in 5:
					var placed := anchor + away.normalized() * clear
					if (not on_spawn or placed.distance_to(SPAWN) >= SPAWN_CLEAR_M) and (not large or _dist_to_route(placed) >= CORRIDOR_M + 1.0):
						flat = placed
						break
					clear += 3.0
					anchor = SPAWN if on_spawn else _nearest_route(placed)
					away = placed - anchor
				world.x = flat.x
				world.z = flat.y
				pushed += 1
			var h := _surface(world.x, world.z)
			if is_nan(h):
				h = world.y
			var new_local: Vector3 = mmi.global_transform.affine_inverse() * Vector3(world.x, h, world.z)
			buf[at + 3] = new_local.x
			buf[at + 7] = new_local.y
			buf[at + 11] = new_local.z
			n += 1
		mm.buffer = buf
	print("PUSHED_OFF_PATH_OR_SPAWN ", pushed)
	return n


func _kind_of(mm: MultiMesh) -> String:
	if mm.mesh == null:
		return ""
	var file := mm.mesh.resource_path.get_file()
	return file.get_basename()


func _nearest_route(p: Vector2) -> Vector2:
	var best := _route_pts[0]
	var best_d := INF
	var step := maxi(1, int(_route_pts.size() / 800))
	for i in range(0, _route_pts.size(), step):
		var d := p.distance_squared_to(_route_pts[i])
		if d < best_d:
			best_d = d
			best = _route_pts[i]
	return best


func _scatter() -> void:
	_noise_cache = _noise_grid(96)
	var noise := _noise_cache
	for z in range(2, _d - 2, 2):
		for x in range(2, _w - 2, 2):
			var i := z * _w + x
			var h: float = _heights[i]
			var slope: float = _slopes[i]
			if h < 1.5 or h > 200.0 or slope >= 35.0:
				continue
			if _block[i] == 2:
				continue
			var lava: float = _lava[i]
			if lava > 0.55:
				continue
			var sw := _slope_weight(slope)
			var ew := _elev_weight(h)
			var cl := 0.28 + 0.72 * _sample_noise(noise, x, z, 96)
			var wx := _origin.x + float(x) * _spacing
			var wz := _origin.y + float(z) * _spacing
			var jx := (_hash(x, z, 3) - 0.5) * _spacing * 1.6
			var jz := (_hash(x, z, 4) - 0.5) * _spacing * 1.6
			var px := wx + jx
			var pz := wz + jz
			var ph := _surface(px, pz)
			if ph < 1.2:
				continue
			var corridor := _block[i] == 1
			var lava_cut := 1.0 - clampf(lava * 1.4, 0.0, 1.0)
			var base := sw * ew * cl * lava_cut
			if _hash(x, z, 11) < 0.70 * base * (0.55 if corridor else 1.0):
				_place("Sedge", px, ph, pz, 0.72 + _hash(x, z, 12) * 0.7, _hash(x, z, 13))
			if _hash(x, z, 14) < 0.38 * base * (0.45 if corridor else 1.0):
				_place("Sedge", px + 0.7, ph, pz - 0.4, 0.55 + _hash(x, z, 15) * 0.5, _hash(x, z, 16))
			if _hash(x, z, 21) < 0.34 * base * (0.5 if corridor else 1.0):
				_place("Fern", px - 0.4, ph, pz + 0.5, 0.7 + _hash(x, z, 22) * 0.75, _hash(x, z, 23))
			if not corridor and slope < 30.0 and _hash(x, z, 31) < 0.09 * base:
				_place("CoastalShrub", px, ph, pz, 0.8 + _hash(x, z, 32) * 0.55, _hash(x, z, 33))
			if not corridor and slope < 22.0 and h < 125.0 and lava < 0.35 and _hash(x, z, 41) < 0.008 * sw * ew * cl:
				_place("Broadleaf", px, ph, pz, 0.85 + _hash(x, z, 42) * 0.45, _hash(x, z, 43))
			if not corridor and slope < 16.0 and h < 42.0 and h > 2.0 and _hash(x, z, 51) < 0.004 * sw * cl:
				_place("FanPalm", px, ph, pz, 0.9 + _hash(x, z, 52) * 0.35, _hash(x, z, 53))
	# A finer pass so ferns and sedges overlap inside the clumps.
	for z in range(3, _d - 3, 3):
		for x in range(3, _w - 3, 3):
			var i := z * _w + x
			var h: float = _heights[i]
			var slope: float = _slopes[i]
			if h < 2.0 or h > 140.0 or slope >= 28.0 or _block[i] == 2 or _lava[i] > 0.5:
				continue
			var cl := _sample_noise(_noise_grid_cached(), x, z, 96)
			if cl < 0.62:
				continue
			if _hash(x, z, 61) > 0.55:
				continue
			var px := _origin.x + float(x) * _spacing + (_hash(x, z, 62) - 0.5) * 2.0
			var pz := _origin.y + float(z) * _spacing + (_hash(x, z, 63) - 0.5) * 2.0
			_place("Fern", px, _surface(px, pz), pz, 0.45 + _hash(x, z, 64) * 0.4, _hash(x, z, 65))


var _noise_cache: PackedFloat32Array = PackedFloat32Array()


func _noise_grid_cached() -> PackedFloat32Array:
	if _noise_cache.is_empty():
		_noise_cache = _noise_grid(96)
	return _noise_cache


func _noise_grid(n: int) -> PackedFloat32Array:
	var g := PackedFloat32Array()
	g.resize(n * n)
	for y in n:
		for x in n:
			g[y * n + x] = _hash(x, y, 7)
	# One box smooth so clumps are blobs, not salt.
	var s := g.duplicate()
	for y in n:
		for x in n:
			var acc := 0.0
			var cnt := 0
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var xx := posmod(x + dx, n)
					var yy := posmod(y + dy, n)
					acc += g[yy * n + xx]
					cnt += 1
			s[y * n + x] = acc / float(cnt)
	return s


func _sample_noise(g: PackedFloat32Array, x: int, z: int, n: int) -> float:
	var fx := float(x) / float(_w) * float(n - 1)
	var fz := float(z) / float(_d) * float(n - 1)
	var x0 := clampi(int(fx), 0, n - 1)
	var z0 := clampi(int(fz), 0, n - 1)
	return g[z0 * n + x0]


func _hash(x: int, z: int, salt: int) -> float:
	var n := x * 374761393 + z * 668265263 + salt * 1442695041
	n = (n ^ (n >> 13)) * 1274126177
	n = n & 2147483647
	return float(n) / 2147483647.0


func _slope_weight(slope: float) -> float:
	if slope < 12.0:
		return 1.0
	if slope < 25.0:
		return 0.82
	return lerpf(0.82, 0.2, clampf((slope - 25.0) / 10.0, 0.0, 1.0))


func _elev_weight(h: float) -> float:
	if h < 55.0:
		return 1.0
	if h < 110.0:
		return 0.72
	if h < 160.0:
		return 0.38
	return 0.12


func _place(kind: String, x: float, y: float, z: float, scale: float, yaw_u: float) -> void:
	if y < 1.0:
		return
	var idx := _cell(x, z)
	if _block[idx] == 2:
		return
	if kind != "Sedge" and kind != "Fern" and _block[idx] != 0:
		return
	var normal := _normal_at(idx)
	var yaw := yaw_u * TAU
	var side := normal.cross(Vector3(0.0, 0.0, 1.0))
	if side.length() < 0.15:
		side = normal.cross(Vector3(1.0, 0.0, 0.0))
	side = side.normalized()
	var forward := side.cross(normal).normalized()
	var basis := Basis(side, normal, forward).rotated(normal, yaw)
	var tilt := deg_to_rad((yaw_u - 0.5) * 14.0)
	basis = basis.rotated(basis.x, tilt)
	basis = basis.scaled(Vector3(scale, scale, scale))
	var chunk := Vector2i(int(floor(x / 128.0)), int(floor(z / 128.0)))
	var key := "%s_%d_%d" % [kind, chunk.x, chunk.y]
	if not _buckets.has(key):
		_buckets[key] = {"kind": kind, "chunk": chunk, "xf": [], "col": []}
	var local := Vector3(x - float(chunk.x) * 128.0, y, z - float(chunk.y) * 128.0)
	_buckets[key]["xf"].append(Transform3D(basis, local))
	var tint := 0.82 + yaw_u * 0.28
	_buckets[key]["col"].append(Color(tint, 0.9 + (1.0 - yaw_u) * 0.15, 0.78 + yaw_u * 0.1, 1.0))
	_added[kind] = int(_added[kind]) + 1


func _normal_at(i: int) -> Vector3:
	var x := i % _w
	var z := int(i / _w)
	var h: float = _heights[i]
	var hr: float = _heights[i + 1] if x < _w - 1 else h
	var hu: float = _heights[i + _w] if z < _d - 1 else h
	var dhdx := (hr - h) / _spacing
	var dhdz := (hu - h) / _spacing
	return Vector3(-dhdx, 1.0, -dhdz).normalized()


func _build_chunks(veg: Node) -> void:
	var ranges := {
		"Sedge": Vector2(90.0, 22.0),
		"Fern": Vector2(150.0, 30.0),
		"CoastalShrub": Vector2(300.0, 40.0),
		"Broadleaf": Vector2(2000.0, 180.0),
		"FanPalm": Vector2(2000.0, 180.0),
	}
	for key in _buckets:
		var bucket: Dictionary = _buckets[key]
		var kind: String = bucket["kind"]
		var chunk: Vector2i = bucket["chunk"]
		var xforms: Array = bucket["xf"]
		var colors: Array = bucket["col"]
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Lush%s_%d_%d" % [kind, chunk.x, chunk.y]
		mmi.position = Vector3(float(chunk.x) * 128.0, 0.0, float(chunk.y) * 128.0)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = _mesh_res[kind]
		var count := xforms.size()
		var buf := PackedFloat32Array()
		buf.resize(count * 16)
		for i in count:
			var xf: Transform3D = xforms[i]
			var b := xf.basis
			var o := xf.origin
			var col: Color = colors[i]
			var at := i * 16
			buf[at + 0] = b.x.x
			buf[at + 1] = b.x.y
			buf[at + 2] = b.x.z
			buf[at + 3] = o.x
			buf[at + 4] = b.y.x
			buf[at + 5] = b.y.y
			buf[at + 6] = b.y.z
			buf[at + 7] = o.y
			buf[at + 8] = b.z.x
			buf[at + 9] = b.z.y
			buf[at + 10] = b.z.z
			buf[at + 11] = o.z
			buf[at + 12] = col.r
			buf[at + 13] = col.g
			buf[at + 14] = col.b
			buf[at + 15] = col.a
		mm.instance_count = count
		mm.buffer = buf
		mmi.multimesh = mm
		mmi.material_override = _material
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var span: Vector2 = ranges[kind]
		mmi.visibility_range_end = span.x
		mmi.visibility_range_end_margin = span.y
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		veg.add_child(mmi)


func _count(veg: Node) -> Dictionary:
	var totals := {}
	for c in veg.get_children():
		if not (c is MultiMeshInstance3D):
			continue
		var mm := (c as MultiMeshInstance3D).multimesh
		if mm == null:
			continue
		var kind := _kind_of(mm)
		totals[kind] = int(totals.get(kind, 0)) + mm.instance_count
	return totals


func _count_large_in_corridor(veg: Node) -> int:
	var n := 0
	for c in veg.get_children():
		if not (c is MultiMeshInstance3D):
			continue
		var mmi := c as MultiMeshInstance3D
		var mm := mmi.multimesh
		if mm == null:
			continue
		var kind := _kind_of(mm)
		if kind != "Broadleaf" and kind != "FanPalm" and kind != "CoastalShrub":
			continue
		var buf := mm.buffer
		var stride := int(buf.size() / mm.instance_count)
		for k in mm.instance_count:
			var wx := mmi.position.x + buf[k * stride + 3]
			var wz := mmi.position.z + buf[k * stride + 11]
			if _dist_to_route(Vector2(wx, wz)) < CORRIDOR_M:
				n += 1
	return n


func _count_near_spawn(veg: Node, radius: float) -> int:
	var n := 0
	var r2 := radius * radius
	for c in veg.get_children():
		if not (c is MultiMeshInstance3D):
			continue
		var mmi := c as MultiMeshInstance3D
		var mm := mmi.multimesh
		if mm == null:
			continue
		for k in mm.instance_count:
			var world: Vector3 = mmi.global_transform * mm.get_instance_transform(k).origin
			if Vector2(world.x, world.z).distance_squared_to(SPAWN) <= r2:
				n += 1
	return n


func _density_map(veg: Node) -> void:
	var counts := PackedInt32Array()
	counts.resize(_w * _d)
	for c in veg.get_children():
		if not (c is MultiMeshInstance3D):
			continue
		var mmi := c as MultiMeshInstance3D
		var mm := mmi.multimesh
		if mm == null:
			continue
		for k in mm.instance_count:
			var world: Vector3 = mmi.global_transform * mm.get_instance_transform(k).origin
			var idx := _cell(world.x, world.z)
			counts[idx] = counts[idx] + 1
	var bytes := PackedByteArray()
	bytes.resize(_w * _d * 3)
	for z in _d:
		var img_y := _d - 1 - z
		for x in _w:
			var i := z * _w + x
			var h: float = _heights[i]
			var s: float = _slopes[i]
			var r := 8
			var g := 28
			var b := 48
			if h >= 0.0:
				if s < 15.0:
					r = 40
					g = 150
					b = 90
				elif s < 35.0:
					r = 190
					g = 150
					b = 50
				else:
					r = 190
					g = 60
					b = 55
			var dens := counts[i]
			if dens > 0:
				var t := clampf(float(dens) / 4.0, 0.0, 1.0)
				r = int(lerpf(float(r), 230.0, t))
				g = int(lerpf(float(g), 255.0, t))
				b = int(lerpf(float(b), 210.0, t))
			var o := (img_y * _w + x) * 3
			bytes[o] = r
			bytes[o + 1] = g
			bytes[o + 2] = b
	for p in _route_pts:
		var x := int(round((p.x - _origin.x) / _spacing))
		var z := int(round((p.y - _origin.y) / _spacing))
		var img_y := _d - 1 - z
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var xx := x + dx
				var yy := img_y + dy
				if xx < 0 or yy < 0 or xx >= _w or yy >= _d:
					continue
				var o := (yy * _w + xx) * 3
				bytes[o] = 120
				bytes[o + 1] = 230
				bytes[o + 2] = 255
	var img := Image.create_from_data(_w, _d, false, Image.FORMAT_RGB8, bytes)
	var path := ProjectSettings.globalize_path("res://docs/foliage_density_slope.png")
	img.save_png(path)
	print("DENSITY_MAP ", path)
