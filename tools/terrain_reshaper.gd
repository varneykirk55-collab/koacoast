@tool
extends RefCounted
## One-shot terrain reshaper for Koa Coast.
##
## Creates walkable coastal plains and gentler mid slopes while preserving
## the high volcanic ridgeline, steep sea cliffs, and the rugged SE lava field.
##
##  - Lowlands (bottom ~15% of island height): strong multi-scale smoothing
##    plus gentle flattening removes the constant 15-35 deg random hills and
##    leaves broad, walkable coastal plains and valley floors near the black
##    sand beaches and around the base of the mountains.
##  - Mid slopes (~12-44% of island height): softens the small-scale bumps
##    toward a wide regional slope and adds subtle contour shelves (resting
##    areas and natural paths) while preserving the large valleys and ridges.
##  - High peaks & ridgeline (> ~44% of island height): completely untouched.
##  - Sea cliffs & pali walls: detected from both steep local slope and
##    tall coastal drop-offs and protected from smoothing.
##  - SE lava field (low-foliage basalt tongue on the east/southeast flank):
##    masked out so it stays rugged.
##  - Foliage in IslandVegetation.scn is re-seated on the new surface.

const SCENE_PATH := "res://scenes/KoaCoast.tscn"
const FOLIAGE_PATH := "res://foliage/IslandVegetation.scn"
const MARKER_PATH := "res://tools/.terrain_reshaped"

# Elevation bands, as a fraction of the island's max height (~358 m), evaluated
# on a wide macro-blurred height so bumpy knobs don't escape their band.
const LOW_START := 0.10            ## ~36 m: full lowland flattening below this
const LOW_END := 0.23              ## ~82 m: lowland blend fades out by here
const MID_START := 0.28            ## ~100 m: full mid-slope softening below this
const MID_END := 0.46              ## ~165 m: zero effect above this (ridgeline & peaks)

const LOW_STRENGTH := 0.97         ## how strongly lowlands move to the smooth plain surface
const MID_STRENGTH := 0.90         ## how strongly mid slopes shed their small-scale bumps

# Blur radii in grid samples (each sample = 2 m, 3 box passes ~ Gaussian).
const LOW_BLUR := 28               ## ~110 m smoothing window in coastal plains & lower valleys
const MID_BLUR := 20               ## ~80 m smoothing window on mid slopes
const ELEV_BLUR := 32              ## ~125 m macro elevation reference
const SLOPE_BLUR := 14             ## ~55 m scale used to detect true cliffs / pali walls (ignores small bumps)
const CLIFF_SPREAD := 2

# Cliff protection:
#  1) Any slope over ~39-50 deg on the 55 m macro scale is a real pali wall / ridge cliff.
#  2) Coastal sea cliffs: near the ocean where macro height is already high (>28 m)
#     and macro slope is >26 deg, keep the dramatic drop-off to the water.
const CLIFF_SLOPE_START := 0.80    ## ~38.7 deg
const CLIFF_SLOPE_END := 1.15      ## ~49 deg

# Soft contour shelves in the mid-slope band (clearer resting areas / paths).
const TERRACE_STEP := 18.0
const TERRACE_STRENGTH := 0.58

# Elevation compression curve: lowers and flattens the coastal plain & lower-valley band
# (slope 0.48 near the shore easing smoothly back to 1.0 by PLAIN_TOP_FRAC * hmax).
const PLAIN_FLOOR := 1.6
const PLAIN_TOP_FRAC := 0.28       ## ~100 m
const PLAIN_COMPRESSION := 0.48

const SHORE_MIN := 1.2             ## land never drops below this (or its original height)
const LAVA_KEEP := 0.85            ## 1.0 = lava field completely untouched

var _w := 0
var _d := 0
var _rs := 256
var _spacing := 2.0
var _min_loc := Vector2i.ZERO
var _old_h := PackedFloat32Array()
var _new_h := PackedFloat32Array()
var _p0 := 0.0
var _p2 := 0.0
var dry_run := false


static func already_ran() -> bool:
	return FileAccess.file_exists(MARKER_PATH)


func backup() -> String:
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var dir := "res://terrain_backup_%s" % stamp
	var abs_dir := ProjectSettings.globalize_path(dir)
	DirAccess.make_dir_recursive_absolute(abs_dir + "/regions")
	FileAccess.open(dir + "/.gdignore", FileAccess.WRITE).store_string("")
	for f in DirAccess.get_files_at("res://terrain/regions"):
		if f.ends_with(".res"):
			DirAccess.copy_absolute(ProjectSettings.globalize_path("res://terrain/regions/" + f), abs_dir + "/regions/" + f)
	DirAccess.copy_absolute(ProjectSettings.globalize_path(FOLIAGE_PATH), abs_dir + "/IslandVegetation.scn")
	DirAccess.copy_absolute(ProjectSettings.globalize_path(SCENE_PATH), abs_dir + "/KoaCoast.tscn")
	print("TerrainReshaper: backup written to ", dir)
	return dir


## Reshapes the terrain held by a live Terrain3D node and saves its regions.
## Returns { "spawn": Vector3, "stats": String }.
func reshape(terrain: Node) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var data = terrain.data
	var regions: Array = data.get_regions_active()
	if regions.is_empty():
		push_error("TerrainReshaper: no active regions found.")
		return {}
	_rs = int(terrain.region_size)
	_spacing = float(terrain.vertex_spacing)

	var min_loc := Vector2i(1 << 20, 1 << 20)
	var max_loc := -min_loc
	for r in regions:
		var loc: Vector2i = r.location
		min_loc = Vector2i(mini(min_loc.x, loc.x), mini(min_loc.y, loc.y))
		max_loc = Vector2i(maxi(max_loc.x, loc.x), maxi(max_loc.y, loc.y))
	_min_loc = min_loc
	_w = (max_loc.x - min_loc.x + 1) * _rs
	_d = (max_loc.y - min_loc.y + 1) * _rs
	var n := _w * _d

	var h := PackedFloat32Array()
	h.resize(n)
	h.fill(-30.0)
	var valid := PackedByteArray()
	valid.resize(n)
	var basalt := PackedFloat32Array()
	basalt.resize(n)
	var sand := PackedFloat32Array()
	sand.resize(n)

	# --- Gather heights + surface material weights into one global grid ---
	for r in regions:
		var himg: Image = r.height_map
		if himg.get_format() != Image.FORMAT_RF:
			himg = himg.duplicate()
			himg.convert(Image.FORMAT_RF)
		var hv := himg.get_data().to_float32_array()
		var cimg: Image = r.control_map
		var cb := PackedByteArray()
		if cimg and cimg.get_format() == Image.FORMAT_RF:
			cb = cimg.get_data()
		var loc: Vector2i = r.location
		var ox := (loc.x - _min_loc.x) * _rs
		var oz := (loc.y - _min_loc.y) * _rs
		for py in _rs:
			var row := (oz + py) * _w + ox
			var src := py * _rs
			for px in _rs:
				var i := row + px
				var v := hv[src + px]
				h[i] = 0.0 if is_nan(v) else v
				valid[i] = 1
				if not cb.is_empty():
					var u := cb.decode_u32((src + px) * 4)
					var base_id := (u >> 27) & 0x1F
					var ovr_id := (u >> 22) & 0x1F
					var blend := float((u >> 14) & 0xFF) / 255.0
					var bw := (1.0 - blend if base_id == 0 else 0.0) + (blend if ovr_id == 0 else 0.0)
					var sw := (1.0 - blend if base_id == 3 else 0.0) + (blend if ovr_id == 3 else 0.0)
					basalt[i] = bw
					sand[i] = sw

	var hmax := 0.0
	var hc := PackedFloat32Array()
	hc.resize(n)
	var water := PackedFloat32Array()
	water.resize(n)
	for i in n:
		var v := maxf(h[i], 0.0)
		hc[i] = v
		water[i] = 1.0 if h[i] < 0.0 else 0.0
		if valid[i] == 1:
			hmax = maxf(hmax, v)
	if hmax < 5.0:
		push_error("TerrainReshaper: terrain looks flat (max %.1f m); aborting." % hmax)
		return {}
	_p0 = PLAIN_FLOOR
	_p2 = maxf(PLAIN_TOP_FRAC * hmax, PLAIN_FLOOR + 10.0)

	# --- Smoothed surfaces and masks ---
	var b_elev := _blur(hc, ELEV_BLUR)
	var t_low := _blur(hc, LOW_BLUR)
	var t_mid := _blur(hc, MID_BLUR)
	var b_slope := _blur(hc, SLOPE_BLUR)
	var basalt_b := _blur(basalt, 8)
	var sand_b := _blur(sand, 14)
	var near_ocean := _blur(water, 18)

	var cliff_raw := PackedFloat32Array()
	cliff_raw.resize(n)
	var inv2s := 1.0 / (2.0 * _spacing)
	for z in range(1, _d - 1):
		for x in range(1, _w - 1):
			var i := z * _w + x
			var sx := (b_slope[i + 1] - b_slope[i - 1]) * inv2s
			var sz := (b_slope[i + _w] - b_slope[i - _w]) * inv2s
			var s := sqrt(sx * sx + sz * sz)
			var pali := smoothstep(CLIFF_SLOPE_START, CLIFF_SLOPE_END, s)
			# Sea cliff: close to ocean, macro terrain is high (not a beach plain), and steep.
			var sea_cliff := smoothstep(0.015, 0.14, near_ocean[i]) \
					* smoothstep(18.0, 38.0, b_elev[i]) \
					* smoothstep(0.38, 0.72, s) \
					* (1.0 - clampf(sand_b[i] * 3.0, 0.0, 1.0))
			cliff_raw[i] = maxf(pali, sea_cliff)
	var cliff := _blur(cliff_raw, CLIFF_SPREAD)

	# --- Compose new heights ---
	var out := h.duplicate()
	for z in _d:
		var wz := (z + _min_loc.y * _rs) * _spacing
		var row := z * _w
		for x in _w:
			var i := row + x
			var hv := h[i]
			if valid[i] == 0 or hv <= 0.25:
				continue
			var wx := (x + _min_loc.x * _rs) * _spacing
			var hn := b_elev[i] / hmax
			var low := 1.0 - smoothstep(LOW_START, LOW_END, hn)
			var mid := 1.0 - smoothstep(MID_START, MID_END, hn)
			if low <= 0.0001 and mid <= 0.0001:
				continue

			# SE lava field mask: bare basalt flow on the east/southeast flank.
			var se_zone := smoothstep(240.0, 440.0, wx) * smoothstep(-160.0, 40.0, wz)
			var lava_mask := se_zone * smoothstep(0.35, 0.72, basalt_b[i]) * (1.0 - clampf(sand_b[i] * 3.0, 0.0, 1.0))

			var cliff_keep := 1.0 - clampf(cliff[i] * 1.85, 0.0, 1.0)
			var lava_keep := 1.0 - LAVA_KEEP * lava_mask
			var shore_fade := smoothstep(0.25, 1.8, hv)
			var protect := cliff_keep * lava_keep * shore_fade

			var w := lerpf(MID_STRENGTH * mid, LOW_STRENGTH, low) * protect
			var target := lerpf(t_mid[i], t_low[i], low)
			var p := hv + w * (target - hv)

			# Soft contour shelves on mid-elevation slopes (natural paths / resting benches).
			var tw := TERRACE_STRENGTH * mid * (1.0 - low * 0.75) * protect
			if tw > 0.001:
				var tt := p / TERRACE_STEP
				var fl := floorf(tt)
				p = lerpf(p, (fl + smoothstep(0.30, 0.70, tt - fl)) * TERRACE_STEP, tw)

			# Gentle elevation compression in coastal plains & lower valleys (scaled by protect
			# so cliffs and the lava field keep their full height).
			var compressed := _remap(p)
			p = lerpf(p, compressed, protect)

			# Extra leveling right behind black sand beaches so beach aprons feel wide and flat.
			var beach := clampf(sand_b[i] * 2.2, 0.0, 1.0) * low * shore_fade
			if beach > 0.01:
				p = lerpf(p, clampf(t_low[i] * 0.72, 1.5, 10.0), beach * 0.55)

			out[i] = maxf(p, minf(hv, SHORE_MIN))

	var stats := _build_stats(h, out, b_elev, hmax)
	print("TerrainReshaper:\n", stats)
	var spawn := _find_spawn(out, sand_b)
	print("TerrainReshaper: chosen coastal spawn = ", spawn)
	if dry_run:
		return {"spawn": spawn, "stats": stats}

	# --- Write back into regions ---
	for r in regions:
		var loc: Vector2i = r.location
		var ox := (loc.x - _min_loc.x) * _rs
		var oz := (loc.y - _min_loc.y) * _rs
		var buf := PackedFloat32Array()
		buf.resize(_rs * _rs)
		for py in _rs:
			var rrow := (oz + py) * _w + ox
			for px in _rs:
				buf[py * _rs + px] = out[rrow + px]
		r.height_map = Image.create_from_data(_rs, _rs, false, Image.FORMAT_RF, buf.to_byte_array())
		if r.has_method("calc_height_range"):
			r.calc_height_range()
		if r.has_method("set_modified"):
			r.set_modified(true)
		else:
			r.set("modified", true)
	data.update_maps(Terrain3DRegion.TYPE_HEIGHT, true, false)
	if data.has_method("calc_height_range"):
		data.calc_height_range(true)
	data.save_directory(terrain.data_directory)

	_old_h = h
	_new_h = out
	FileAccess.open(MARKER_PATH, FileAccess.WRITE).store_string(
			"Terrain reshaped %s. Delete this file to allow running again.\n" % Time.get_datetime_string_from_system())
	print("TerrainReshaper: terrain saved in %.1f s" % [(Time.get_ticks_msec() - t0) / 1000.0])
	return {"spawn": spawn, "stats": stats}


func _build_stats(old_h: PackedFloat32Array, new_h: PackedFloat32Array, b_elev: PackedFloat32Array, hmax: float) -> String:
	var bands := [
		["Coastal & low valleys (0-35m)", 0.0, 0.10],
		["Lower-mid slopes (35-90m)    ", 0.10, 0.25],
		["Upper-mid slopes (90-160m)   ", 0.25, 0.45],
		["High peaks & ridges (>160m)  ", 0.45, 1.05],
	]
	var lines := PackedStringArray()
	var inv2s := 1.0 / (2.0 * _spacing)
	var s5 := tan(deg_to_rad(5.0))
	var s15 := tan(deg_to_rad(15.0))
	var s40 := tan(deg_to_rad(40.0))
	var old_max := 0.0
	var new_max := 0.0
	for i in old_h.size():
		old_max = maxf(old_max, old_h[i])
		new_max = maxf(new_max, new_h[i])
	lines.append("  Peak height: %.1f m -> %.1f m" % [old_max, new_max])
	for b in bands:
		var tot := 0
		var o5 := 0; var n5 := 0
		var o15 := 0; var n15 := 0
		var o40 := 0; var n40 := 0
		for z in range(2, _d - 2, 2):
			for x in range(2, _w - 2, 2):
				var i := z * _w + x
				if old_h[i] < 1.0:
					continue
				var f := b_elev[i] / hmax
				if f < b[1] or f >= b[2]:
					continue
				tot += 1
				var osx := (old_h[i + 1] - old_h[i - 1]) * inv2s
				var osz := (old_h[i + _w] - old_h[i - _w]) * inv2s
				var os := sqrt(osx * osx + osz * osz)
				var nsx := (new_h[i + 1] - new_h[i - 1]) * inv2s
				var nsz := (new_h[i + _w] - new_h[i - _w]) * inv2s
				var ns := sqrt(nsx * nsx + nsz * nsz)
				if os < s5: o5 += 1
				if ns < s5: n5 += 1
				if os < s15: o15 += 1
				if ns < s15: n15 += 1
				if os > s40: o40 += 1
				if ns > s40: n40 += 1
		var d := float(maxi(tot, 1))
		lines.append("  %s: <5 deg %2.0f%%->%2.0f%% | <15 deg (walkable) %2.0f%%->%2.0f%% | >40 deg (cliffs) %2.0f%%->%2.0f%%" % [
			b[0], 100.0 * o5 / d, 100.0 * n5 / d, 100.0 * o15 / d, 100.0 * n15 / d, 100.0 * o40 / d, 100.0 * n40 / d
		])
	return "\n".join(lines)


## Re-seats every plant in the foliage scene by the local height change. Call after reshape().
func update_foliage() -> int:
	if _new_h.is_empty():
		return 0
	var ps := ResourceLoader.load(FOLIAGE_PATH, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if ps == null:
		push_warning("TerrainReshaper: could not load " + FOLIAGE_PATH)
		return 0
	var root := ps.instantiate()
	var moved := _shift_node(root, root, Transform3D.IDENTITY)
	var packed := PackedScene.new()
	var err := packed.pack(root)
	if err == OK:
		err = ResourceSaver.save(packed, FOLIAGE_PATH, ResourceSaver.FLAG_COMPRESS)
	root.free()
	if err != OK:
		push_error("TerrainReshaper: failed to save foliage (%s)" % error_string(err))
		return 0
	print("TerrainReshaper: re-seated %d foliage instances" % moved)
	return moved


func _shift_node(node: Node, root: Node, parent_xf: Transform3D) -> int:
	var xf := parent_xf
	if node is Node3D:
		xf = parent_xf * (node as Node3D).transform
	if node is MultiMeshInstance3D:
		var mm: MultiMesh = (node as MultiMeshInstance3D).multimesh
		if mm == null or mm.transform_format != MultiMesh.TRANSFORM_3D or mm.instance_count == 0:
			return 0
		var buf := mm.buffer
		var stride := buf.size() / mm.instance_count
		if stride < 12:
			return 0
		for k in mm.instance_count:
			var base := k * stride
			var lo := Vector3(buf[base + 3], buf[base + 7], buf[base + 11])
			var wo := xf * lo
			var dh := _delta(wo.x, wo.z)
			if absf(dh) > 0.001:
				var nlo := xf.affine_inverse() * (wo + Vector3(0.0, dh, 0.0))
				buf[base + 3] = nlo.x
				buf[base + 7] = nlo.y
				buf[base + 11] = nlo.z
		mm.buffer = buf
		return mm.instance_count
	if node != root and node is Node3D and (node is VisualInstance3D or not node.scene_file_path.is_empty()):
		var dh := _delta(xf.origin.x, xf.origin.z)
		(node as Node3D).position += parent_xf.basis.inverse() * Vector3(0.0, dh, 0.0)
		return 1
	var count := 0
	for c in node.get_children():
		count += _shift_node(c, root, xf)
	return count


func _delta(x: float, z: float) -> float:
	var gx := x / _spacing - _min_loc.x * _rs
	var gz := z / _spacing - _min_loc.y * _rs
	if gx < 0.0 or gz < 0.0 or gx > _w - 1 or gz > _d - 1:
		return 0.0
	var x0 := int(gx)
	var z0 := int(gz)
	var x1 := mini(x0 + 1, _w - 1)
	var z1 := mini(z0 + 1, _d - 1)
	var fx := gx - x0
	var fz := gz - z0
	var d00 := _new_h[z0 * _w + x0] - _old_h[z0 * _w + x0]
	var d10 := _new_h[z0 * _w + x1] - _old_h[z0 * _w + x1]
	var d01 := _new_h[z1 * _w + x0] - _old_h[z1 * _w + x0]
	var d11 := _new_h[z1 * _w + x1] - _old_h[z1 * _w + x1]
	return lerpf(lerpf(d00, d10, fx), lerpf(d01, d11, fx), fz)


func _remap(p: float) -> float:
	if p <= _p0 or p >= _p2:
		return p
	var u := (p - _p0) / (_p2 - _p0)
	var k := 1.0 - PLAIN_COMPRESSION
	return _p0 + (_p2 - _p0) * (-k * u * u * u + 2.0 * k * u * u + PLAIN_COMPRESSION * u)


## Finds a broad, flat, low coastal plain near a black sand beach. Returns world position.
func _find_spawn(hh: PackedFloat32Array, sand_b: PackedFloat32Array) -> Vector3:
	var best := Vector3.ZERO
	var best_score := INF
	var cx := _w / 2
	var cz := _d / 2
	for z in range(20, _d - 20, 4):
		for x in range(20, _w - 20, 4):
			var hv := hh[z * _w + x]
			if hv < 2.5 or hv > 14.0:
				continue
			var rough := 0.0
			var bad := false
			for r in [3, 6, 12]:
				for d in [Vector2i(r, 0), Vector2i(-r, 0), Vector2i(0, r), Vector2i(0, -r)]:
					var hn := hh[(z + d.y) * _w + (x + d.x)]
					if hn < 1.2:
						bad = true
						break
					rough += absf(hn - hv)
				if bad:
					break
			if bad or rough > 4.5:
				continue
			var coastal := false
			for dir in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
					Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1)]:
				var px: int = clampi(x + dir.x * 55, 0, _w - 1)
				var pz: int = clampi(z + dir.y * 55, 0, _d - 1)
				if hh[pz * _w + px] < 0.0:
					coastal = true
					break
			if not coastal:
				continue
			var sand_bonus := sand_b[z * _w + x] * 1.5
			var score := rough - sand_bonus + 0.0004 * Vector2(x - cx, z - cz).length()
			if score < best_score:
				best_score = score
				best = Vector3((x + _min_loc.x * _rs) * _spacing, hv + 0.3, (z + _min_loc.y * _rs) * _spacing)
	return best


## Separable box blur, 3 passes (~Gaussian). Edges clamp.
func _blur(src: PackedFloat32Array, r: int) -> PackedFloat32Array:
	var a := src.duplicate()
	var tmp := PackedFloat32Array()
	tmp.resize(a.size())
	var inv := 1.0 / float(2 * r + 1)
	var wm := _w - 1
	var dm := _d - 1
	for _p in 3:
		for z in _d:
			var row := z * _w
			var acc := 0.0
			for k in range(-r, r + 1):
				acc += a[row + clampi(k, 0, wm)]
			for x in _w:
				tmp[row + x] = acc * inv
				acc += a[row + mini(x + r + 1, wm)] - a[row + maxi(x - r, 0)]
		for x in _w:
			var acc := 0.0
			for k in range(-r, r + 1):
				acc += tmp[clampi(k, 0, dm) * _w + x]
			for z in _d:
				a[z * _w + x] = acc * inv
				acc += tmp[mini(z + r + 1, dm) * _w + x] - tmp[maxi(z - r, 0) * _w + x]
	return a
