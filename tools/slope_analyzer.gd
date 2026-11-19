class_name SlopeAnalyzer
extends RefCounted
## Read-only slope and elevation analysis for the Koa Coast Terrain3D island.
##
## Reads region height maps (and cross-checks Terrain3DData.get_height / get_normal).
## Never assigns height maps, never saves regions, never edits the terrain.

const PLAYER_SCENE := "res://player/KekoaPlayer.tscn"
const SEA_LEVEL := 0.0
## Green ends at this fraction of the player CharacterBody3D.floor_max_angle.
const GENTLE_FRACTION := 0.30
## Yellow ends (red begins) at this fraction of floor_max_angle.
const MODERATE_FRACTION := 0.70
const CONTOUR_M := 25.0
const MIN_CLUSTER_CELLS := 48
const TOP_CLUSTERS := 8

enum Mode { SLOPE, ELEVATION, BOTH }

const COL_GENTLE := Color(0.239, 0.863, 0.549)
const COL_GENTLE_DARK := Color(0.09, 0.42, 0.28)
const COL_MOD := Color(0.961, 0.773, 0.259)
const COL_MOD_DARK := Color(0.62, 0.40, 0.08)
const COL_STEEP := Color(1.0, 0.302, 0.302)
const COL_STEEP_DARK := Color(0.42, 0.05, 0.08)
const COL_DEEP := Color(0.027, 0.071, 0.133)
const COL_SHALLOW := Color(0.12, 0.42, 0.52)
const COL_CONTOUR := Color(0.91, 0.97, 1.0)
const COL_COAST := Color(0.96, 0.90, 0.74)
const COL_ELEV := [
	Color(0.62, 0.75, 0.58),
	Color(0.20, 0.55, 0.34),
	Color(0.55, 0.58, 0.24),
	Color(0.55, 0.36, 0.22),
	Color(0.93, 0.91, 0.85),
]

const SHEET_W := 1560
const SHEET_H := 1080
const MAP_ORIGIN := Vector2i(24, 28)

static var _glyph_cache: Dictionary = {}


## Returns (gentle_max_deg, moderate_max_deg, floor_max_deg) from Player.tscn.
## Does not modify the player. Falls back to 50° if the scene cannot be read.
static func thresholds_from_player() -> Vector3:
	var floor_deg := _read_floor_max_deg()
	return Vector3(
		snappedf(floor_deg * GENTLE_FRACTION, 0.5),
		snappedf(floor_deg * MODERATE_FRACTION, 0.5),
		floor_deg
	)


static func _read_floor_max_deg() -> float:
	var packed := load(PLAYER_SCENE) as PackedScene
	if packed == null:
		push_warning("SlopeAnalyzer: Player.tscn missing; assuming floor_max_angle of 50 deg.")
		return 50.0
	var player := packed.instantiate()
	var deg := rad_to_deg(float(player.get("floor_max_angle")))
	player.free()
	if deg < 1.0 or deg > 89.0:
		push_warning("SlopeAnalyzer: unusual floor_max_angle %.2f deg." % deg)
	return deg


## Stitches active Terrain3D regions into one height grid. Read only.
func load_grid(terrain: Node) -> Dictionary:
	var data = terrain.get("data")
	if data == null:
		push_error("SlopeAnalyzer: Terrain3D has no data.")
		return {}
	var regions: Array = data.get_regions_active()
	if regions.is_empty():
		push_error("SlopeAnalyzer: no active regions.")
		return {}
	var region_size := int(terrain.get("region_size"))
	var spacing := float(terrain.get("vertex_spacing"))
	var min_loc := Vector2i(1 << 20, 1 << 20)
	var max_loc := Vector2i(-(1 << 20), -(1 << 20))
	for region in regions:
		var loc: Vector2i = region.location
		min_loc.x = mini(min_loc.x, loc.x)
		min_loc.y = mini(min_loc.y, loc.y)
		max_loc.x = maxi(max_loc.x, loc.x)
		max_loc.y = maxi(max_loc.y, loc.y)
	var w := (max_loc.x - min_loc.x + 1) * region_size
	var d := (max_loc.y - min_loc.y + 1) * region_size
	var heights := PackedFloat32Array()
	heights.resize(w * d)
	heights.fill(NAN)
	var min_h := INF
	var max_h := -INF
	for region in regions:
		var src: Image = region.height_map
		# Duplicate before touching pixels so the region resource stays unmodified.
		var copy := src.duplicate() as Image
		if copy.get_format() != Image.FORMAT_RF:
			copy.convert(Image.FORMAT_RF)
		var hv: PackedFloat32Array = copy.get_data().to_float32_array()
		var loc: Vector2i = region.location
		var ox := (loc.x - min_loc.x) * region_size
		var oz := (loc.y - min_loc.y) * region_size
		var img_w := copy.get_width()
		for py in region_size:
			var row := (oz + py) * w + ox
			var src_row := py * img_w
			for px in region_size:
				var v := hv[src_row + px]
				heights[row + px] = v
				if not is_nan(v):
					min_h = minf(min_h, v)
					max_h = maxf(max_h, v)
	var slopes := _slopes(heights, w, d, spacing)
	var origin := Vector2(float(min_loc.x * region_size) * spacing, float(min_loc.y * region_size) * spacing)
	var grid := {
		"heights": heights,
		"slopes": slopes,
		"w": w,
		"d": d,
		"spacing": spacing,
		"origin": origin,
		"min_h": min_h,
		"max_h": max_h,
		"min_loc": min_loc,
		"max_loc": max_loc,
	}
	grid["crosscheck"] = _crosscheck(grid, data)
	return grid


func _slopes(heights: PackedFloat32Array, w: int, d: int, spacing: float) -> PackedFloat32Array:
	var slopes := PackedFloat32Array()
	slopes.resize(w * d)
	for pz in d:
		var row := pz * w
		for px in w:
			var i := row + px
			var h: float = heights[i]
			var h_l: float
			var h_r: float
			var span_x: float
			if px == 0:
				h_l = h
				h_r = heights[i + 1]
				span_x = spacing
			elif px == w - 1:
				h_l = heights[i - 1]
				h_r = h
				span_x = spacing
			else:
				h_l = heights[i - 1]
				h_r = heights[i + 1]
				span_x = spacing * 2.0
			var h_d: float
			var h_u: float
			var span_z: float
			if pz == 0:
				h_d = h
				h_u = heights[i + w]
				span_z = spacing
			elif pz == d - 1:
				h_d = heights[i - w]
				h_u = h
				span_z = spacing
			else:
				h_d = heights[i - w]
				h_u = heights[i + w]
				span_z = spacing * 2.0
			var dhdx := (h_r - h_l) / span_x
			var dhdz := (h_u - h_d) / span_z
			slopes[i] = rad_to_deg(atan(sqrt(dhdx * dhdx + dhdz * dhdz)))
	return slopes


## Compare a scatter of vertices against Terrain3DData.get_height / get_normal.
func _crosscheck(grid: Dictionary, data) -> Dictionary:
	var heights: PackedFloat32Array = grid.heights
	var slopes: PackedFloat32Array = grid.slopes
	var w: int = grid.w
	var d: int = grid.d
	var spacing: float = grid.spacing
	var origin: Vector2 = grid.origin
	var n := 0
	var sum_h := 0.0
	var max_h_err := 0.0
	var sum_s := 0.0
	var max_s_err := 0.0
	var pz := 16
	while pz < d - 16 and n < 24:
		var px := 16
		while px < w - 16 and n < 24:
			var i := pz * w + px
			var h: float = heights[i]
			if h >= 2.0:
				var world := Vector3(origin.x + float(px) * spacing, 0.0, origin.y + float(pz) * spacing)
				var api_h: float = data.get_height(world)
				var api_n: Vector3 = data.get_normal(world)
				var api_deg := rad_to_deg(api_n.angle_to(Vector3.UP))
				var herr := absf(api_h - h)
				var serr := absf(api_deg - slopes[i])
				sum_h += herr
				sum_s += serr
				max_h_err = maxf(max_h_err, herr)
				max_s_err = maxf(max_s_err, serr)
				n += 1
			px += 80
		pz += 70
	return {
		"samples": n,
		"mean_height_m": (sum_h / float(n)) if n else 0.0,
		"max_height_m": max_h_err,
		"mean_slope_deg": (sum_s / float(n)) if n else 0.0,
		"max_slope_deg": max_s_err,
	}


func classify(grid: Dictionary, gentle: float, moderate: float, floor_max: float) -> Dictionary:
	gentle = clampf(gentle, 0.5, 88.0)
	moderate = clampf(maxf(moderate, gentle + 0.5), 1.0, 89.0)
	var heights: PackedFloat32Array = grid.heights
	var slopes: PackedFloat32Array = grid.slopes
	var w: int = grid.w
	var d: int = grid.d
	var spacing: float = grid.spacing
	var origin: Vector2 = grid.origin
	var land := 0
	var gentle_n := 0
	var moderate_n := 0
	var steep_n := 0
	var unwalkable_n := 0
	var steepest_deg := -1.0
	var steepest_i := 0
	for i in heights.size():
		var h: float = heights[i]
		if is_nan(h) or h < SEA_LEVEL:
			continue
		land += 1
		var deg: float = slopes[i]
		if deg < gentle:
			gentle_n += 1
		elif deg < moderate:
			moderate_n += 1
		else:
			steep_n += 1
		if deg >= floor_max:
			unwalkable_n += 1
		if deg > steepest_deg:
			steepest_deg = deg
			steepest_i = i
	var spx := steepest_i % w
	var spz := int(steepest_i / float(w))
	return {
		"gentle_max": gentle,
		"moderate_max": moderate,
		"floor_max": floor_max,
		"contour_m": CONTOUR_M,
		"land_cells": land,
		"gentle_cells": gentle_n,
		"moderate_cells": moderate_n,
		"steep_cells": steep_n,
		"unwalkable_cells": unwalkable_n,
		"land_area_m2": float(land) * spacing * spacing,
		"clusters": _pick_clusters(grid, moderate, floor_max),
		"steepest": {
			"x": origin.x + float(spx) * spacing,
			"z": origin.y + float(spz) * spacing,
			"deg": steepest_deg,
			"h": heights[steepest_i],
		},
		"crosscheck": grid.crosscheck,
		"min_h": grid.min_h,
		"max_h": grid.max_h,
		"spacing": spacing,
		"origin": origin,
		"w": w,
		"d": d,
	}


## Prefer distinct cliff groups over one island-sized component.
## Starts at the walk limit and tightens if the largest blob still covers a ridge.
func _pick_clusters(grid: Dictionary, moderate: float, floor_max: float) -> Array:
	var best: Array = []
	var best_cut := maxf(moderate, floor_max)
	for cut in [maxf(moderate, floor_max), 60.0, 65.0, 70.0, 75.0]:
		var found := _clusters(grid, cut)
		if found.is_empty():
			continue
		best = found
		best_cut = cut
		var largest := 0.0
		for cluster in found:
			largest = maxf(largest, float(cluster.area_m2))
		# A single volcanic face can be large; a component over ~8 ha is the whole ridge.
		if largest <= 80000.0 and found.size() >= 3:
			break
	for cluster in best:
		cluster["cut_deg"] = best_cut
	return best


func _clusters(grid: Dictionary, moderate: float) -> Array:
	var heights: PackedFloat32Array = grid.heights
	var slopes: PackedFloat32Array = grid.slopes
	var w: int = grid.w
	var d: int = grid.d
	var n := w * d
	var spacing: float = grid.spacing
	var origin: Vector2 = grid.origin
	var seen := PackedByteArray()
	seen.resize(n)
	var queue := PackedInt32Array()
	queue.resize(n)
	var out: Array = []
	for start in n:
		if seen[start] != 0:
			continue
		if is_nan(heights[start]) or heights[start] < SEA_LEVEL or slopes[start] < moderate:
			seen[start] = 1
			continue
		var qh := 0
		var qt := 0
		queue[qt] = start
		qt += 1
		seen[start] = 1
		var count := 0
		var sum_s := 0.0
		var sum_x := 0.0
		var sum_z := 0.0
		var max_s := -1.0
		var max_i := start
		var min_px := w
		var max_px := 0
		var min_pz := d
		var max_pz := 0
		while qh < qt:
			var cur: int = queue[qh]
			qh += 1
			var px := cur % w
			var pz := int(cur / float(w))
			var deg: float = slopes[cur]
			count += 1
			sum_s += deg
			sum_x += float(px)
			sum_z += float(pz)
			if deg > max_s:
				max_s = deg
				max_i = cur
			min_px = mini(min_px, px)
			max_px = maxi(max_px, px)
			min_pz = mini(min_pz, pz)
			max_pz = maxi(max_pz, pz)
			if px > 0:
				var left := cur - 1
				if seen[left] == 0 and heights[left] >= SEA_LEVEL and slopes[left] >= moderate:
					seen[left] = 1
					queue[qt] = left
					qt += 1
			if px + 1 < w:
				var right := cur + 1
				if seen[right] == 0 and heights[right] >= SEA_LEVEL and slopes[right] >= moderate:
					seen[right] = 1
					queue[qt] = right
					qt += 1
			if pz > 0:
				var down := cur - w
				if seen[down] == 0 and heights[down] >= SEA_LEVEL and slopes[down] >= moderate:
					seen[down] = 1
					queue[qt] = down
					qt += 1
			if pz + 1 < d:
				var up := cur + w
				if seen[up] == 0 and heights[up] >= SEA_LEVEL and slopes[up] >= moderate:
					seen[up] = 1
					queue[qt] = up
					qt += 1
		if count < MIN_CLUSTER_CELLS:
			continue
		var mpx := max_i % w
		var mpz := int(max_i / float(w))
		out.append({
			"cells": count,
			"area_m2": float(count) * spacing * spacing,
			"mean_deg": sum_s / float(count),
			"max_deg": max_s,
			"cx": origin.x + (sum_x / float(count)) * spacing,
			"cz": origin.y + (sum_z / float(count)) * spacing,
			"max_x": origin.x + float(mpx) * spacing,
			"max_z": origin.y + float(mpz) * spacing,
			"max_h": heights[max_i],
			"min_x": origin.x + float(min_px) * spacing,
			"max_x_bound": origin.x + float(max_px) * spacing,
			"min_z": origin.y + float(min_pz) * spacing,
			"max_z_bound": origin.y + float(max_pz) * spacing,
			"severity": sum_s - moderate * float(count),
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["severity"]) > float(b["severity"])
	)
	if out.size() > TOP_CLUSTERS:
		out.resize(TOP_CLUSTERS)
	return out


func summary_text(report: Dictionary) -> String:
	var land := int(report.land_cells)
	var lines: PackedStringArray = PackedStringArray()
	lines.append("Koa Coast slope analysis (read only)")
	lines.append("Land is height >= 0 m (mean sea level). Each sample is %.0f m." % float(report.spacing))
	lines.append("Gentle  < %.1f deg  (%.0f%% of player floor_max_angle)" % [float(report.gentle_max), GENTLE_FRACTION * 100.0])
	lines.append("Moderate  %.1f–%.1f deg" % [float(report.gentle_max), float(report.moderate_max)])
	lines.append("Steep  >= %.1f deg  (%.0f%% of player floor_max_angle)" % [float(report.moderate_max), MODERATE_FRACTION * 100.0])
	lines.append("Player floor_max_angle  %.2f deg  (slopes at or above this are unwalkable)" % float(report.floor_max))
	lines.append("")
	lines.append("Land area  %.3f km²  (%d samples)" % [float(report.land_area_m2) / 1.0e6, land])
	lines.append("Gentle     %6.2f%%" % _pct(int(report.gentle_cells), land))
	lines.append("Moderate   %6.2f%%" % _pct(int(report.moderate_cells), land))
	lines.append("Steep      %6.2f%%" % _pct(int(report.steep_cells), land))
	lines.append("Unwalkable %6.2f%%  (>= %.1f deg, included in steep)" % [_pct(int(report.unwalkable_cells), land), float(report.floor_max)])
	lines.append("Height range  %.1f m to %.1f m" % [float(report.min_h), float(report.max_h)])
	var steepest: Dictionary = report.steepest
	lines.append("Steepest land point  %.1f deg at (%.0f, %.0f) m, height %.1f m" % [float(steepest.deg), float(steepest.x), float(steepest.z), float(steepest.h)])
	lines.append("")
	var cut := float(report.moderate_max)
	if not report.clusters.is_empty():
		cut = float(report.clusters[0].cut_deg)
	lines.append("Worst steep clusters (cells >= %.0f deg, excess slope x area, >= %d cells)" % [cut, MIN_CLUSTER_CELLS])
	var rank := 1
	for cluster in report.clusters:
		lines.append(
			"%d. centroid (%.0f, %.0f)  max %.1f deg at (%.0f, %.0f) h %.0f m  area %.0f m²  mean %.1f deg  bounds x %.0f..%.0f  z %.0f..%.0f"
			% [
				rank,
				float(cluster.cx), float(cluster.cz),
				float(cluster.max_deg), float(cluster.max_x), float(cluster.max_z), float(cluster.max_h),
				float(cluster.area_m2), float(cluster.mean_deg),
				float(cluster.min_x), float(cluster.max_x_bound),
				float(cluster.min_z), float(cluster.max_z_bound),
			]
		)
		rank += 1
	var check: Dictionary = report.crosscheck
	lines.append("")
	lines.append(
		"API cross-check  %d vertices  mean |height| %.4f m (max %.4f)  mean |slope-get_normal| %.2f deg (max %.2f)"
		% [
			int(check.samples), float(check.mean_height_m), float(check.max_height_m),
			float(check.mean_slope_deg), float(check.max_slope_deg),
		]
	)
	lines.append("Slope method: central differences on region height maps. Contours every %.0f m." % CONTOUR_M)
	return "\n".join(lines) + "\n"


func render_map(grid: Dictionary, report: Dictionary, mode: int, for_overlay: bool) -> Image:
	var w: int = grid.w
	var d: int = grid.d
	var heights: PackedFloat32Array = grid.heights
	var slopes: PackedFloat32Array = grid.slopes
	var gentle: float = report.gentle_max
	var moderate: float = report.moderate_max
	var interval: float = float(report.contour_m)
	var min_h: float = grid.min_h
	var max_h: float = grid.max_h
	var bytes := PackedByteArray()
	bytes.resize(w * d * 4)
	for pz in d:
		var row := pz * w
		var img_y := d - 1 - pz
		for px in w:
			var i := row + px
			var h: float = heights[i]
			var deg: float = slopes[i]
			var coast := false
			var contour := false
			if px > 0:
				var left_h: float = heights[i - 1]
				if h >= SEA_LEVEL and left_h < SEA_LEVEL:
					coast = true
				elif mode != Mode.SLOPE and h > left_h and floori(h / interval) != floori(left_h / interval):
					contour = true
			if pz > 0:
				var down_h: float = heights[i - w]
				if h >= SEA_LEVEL and down_h < SEA_LEVEL:
					coast = true
				elif mode != Mode.SLOPE and h > down_h and floori(h / interval) != floori(down_h / interval):
					contour = true
			var col := COL_DEEP
			var alpha := 255
			if is_nan(h):
				alpha = 0
			elif h < SEA_LEVEL:
				if for_overlay:
					alpha = 0
				else:
					col = _water_color(h, min_h)
			else:
				col = _elev_color(h, max_h) if mode == Mode.ELEVATION else _slope_color(deg, gentle, moderate)
				if for_overlay:
					alpha = 232
			if coast:
				col = COL_COAST
				alpha = 255
			elif contour and (h >= SEA_LEVEL or mode == Mode.ELEVATION):
				col = COL_CONTOUR
				alpha = 255
			var o := (img_y * w + px) * 4
			bytes[o] = _byte(col.r)
			bytes[o + 1] = _byte(col.g)
			bytes[o + 2] = _byte(col.b)
			bytes[o + 3] = alpha
	return Image.create_from_data(w, d, false, Image.FORMAT_RGBA8, bytes)


func render_sheet(grid: Dictionary, report: Dictionary, mode: int) -> Image:
	var map := render_map(grid, report, mode, false)
	var sheet := Image.create(SHEET_W, SHEET_H, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.016, 0.031, 0.051))
	sheet.blit_rect(map, Rect2i(0, 0, map.get_width(), map.get_height()), MAP_ORIGIN)
	var frame := Color(0.42, 0.86, 0.96)
	var mw := map.get_width()
	var mh := map.get_height()
	sheet.fill_rect(Rect2i(MAP_ORIGIN.x - 2, MAP_ORIGIN.y - 2, mw + 4, 2), frame)
	sheet.fill_rect(Rect2i(MAP_ORIGIN.x - 2, MAP_ORIGIN.y + mh, mw + 4, 2), frame)
	sheet.fill_rect(Rect2i(MAP_ORIGIN.x - 2, MAP_ORIGIN.y, 2, mh), frame)
	sheet.fill_rect(Rect2i(MAP_ORIGIN.x + mw, MAP_ORIGIN.y, 2, mh), frame)
	_draw_markers(sheet, grid, report)
	_draw_scale_and_north(sheet, grid)
	_draw_legend(sheet, report, mode)
	return sheet


func _draw_markers(sheet: Image, grid: Dictionary, report: Dictionary) -> void:
	var origin: Vector2 = grid.origin
	var spacing: float = grid.spacing
	var d: int = grid.d
	var shown := 0
	for cluster in report.clusters:
		shown += 1
		if shown > 6:
			break
		var px := int(round((float(cluster.max_x) - origin.x) / spacing))
		var pz := int(round((float(cluster.max_z) - origin.y) / spacing))
		var x := MAP_ORIGIN.x + px
		var y := MAP_ORIGIN.y + (d - 1 - pz)
		for t in range(-7, 8):
			_pixel(sheet, x + t, y, Color(0.02, 0.05, 0.08))
			_pixel(sheet, x, y + t, Color(0.02, 0.05, 0.08))
		for t in range(-5, 6):
			_pixel(sheet, x + t, y, Color(0.55, 0.96, 1.0))
			_pixel(sheet, x, y + t, Color(0.55, 0.96, 1.0))
		draw_text(sheet, Vector2i(x + 8, y - 8), str(shown), Color(0.85, 0.98, 1.0), 2)


func _draw_scale_and_north(sheet: Image, grid: Dictionary) -> void:
	var spacing: float = grid.spacing
	var bar := int(round(500.0 / spacing))
	var x := MAP_ORIGIN.x + 18
	var y := MAP_ORIGIN.y + int(grid.d) - 36
	sheet.fill_rect(Rect2i(x - 8, y - 18, bar + 16, 34), Color(0.02, 0.05, 0.08, 0.92))
	sheet.fill_rect(Rect2i(x, y, bar, 4), Color(0.85, 0.96, 1.0))
	sheet.fill_rect(Rect2i(x, y - 3, 2, 10), Color(0.85, 0.96, 1.0))
	sheet.fill_rect(Rect2i(x + bar - 2, y - 3, 2, 10), Color(0.85, 0.96, 1.0))
	draw_text(sheet, Vector2i(x, y + 8), "500 M", Color(0.85, 0.96, 1.0), 2)
	var nx := MAP_ORIGIN.x + int(grid.w) / 2
	var ny := MAP_ORIGIN.y + 22
	sheet.fill_rect(Rect2i(nx - 16, ny - 16, 34, 40), Color(0.02, 0.05, 0.08, 0.9))
	for t in 10:
		_pixel(sheet, nx, ny - t, Color(0.85, 0.96, 1.0))
		_pixel(sheet, nx, ny - t, Color(0.85, 0.96, 1.0))
	_pixel(sheet, nx - 1, ny - 8, Color(0.85, 0.96, 1.0))
	_pixel(sheet, nx + 1, ny - 8, Color(0.85, 0.96, 1.0))
	_pixel(sheet, nx - 2, ny - 7, Color(0.85, 0.96, 1.0))
	_pixel(sheet, nx + 2, ny - 7, Color(0.85, 0.96, 1.0))
	draw_text(sheet, Vector2i(nx - 4, ny + 4), "N", Color(0.85, 0.96, 1.0), 2)


func _draw_legend(sheet: Image, report: Dictionary, mode: int) -> void:
	var x := MAP_ORIGIN.x + 1024 + 36
	var y := 36
	var title := Color(0.55, 0.93, 1.0)
	var body := Color(0.82, 0.91, 0.94)
	var dim := Color(0.55, 0.70, 0.76)
	draw_text(sheet, Vector2i(x, y), "KOA COAST", title, 3)
	y += 28
	var mode_name := "SLOPE"
	if mode == Mode.ELEVATION:
		mode_name = "ELEVATION"
	elif mode == Mode.BOTH:
		mode_name = "SLOPE + CONTOURS"
	draw_text(sheet, Vector2i(x, y), mode_name, body, 2)
	y += 28
	y = _swatch(sheet, x, y, COL_GENTLE, "GENTLE", "0-%.0f DEG" % float(report.gentle_max))
	y = _swatch(sheet, x, y, COL_MOD, "MODERATE", "%.0f-%.0f DEG" % [float(report.gentle_max), float(report.moderate_max)])
	y = _swatch(sheet, x, y, COL_STEEP, "STEEP", "%.0f+ DEG" % float(report.moderate_max))
	y += 6
	draw_text(sheet, Vector2i(x, y), "WALK LIMIT %.0f DEG" % float(report.floor_max), Color(1.0, 0.72, 0.62), 2)
	y += 16
	draw_text(sheet, Vector2i(x, y), "PLAYER FLOOR MAX ANGLE", dim, 2)
	y += 22
	var land := int(report.land_cells)
	draw_text(sheet, Vector2i(x, y), "LAND %.2f KM2" % (float(report.land_area_m2) / 1.0e6), body, 2)
	y += 18
	draw_text(sheet, Vector2i(x, y), "GENTLE    %5.1f%%" % _pct(int(report.gentle_cells), land), COL_GENTLE, 2)
	y += 16
	draw_text(sheet, Vector2i(x, y), "MODERATE  %5.1f%%" % _pct(int(report.moderate_cells), land), COL_MOD, 2)
	y += 16
	draw_text(sheet, Vector2i(x, y), "STEEP     %5.1f%%" % _pct(int(report.steep_cells), land), COL_STEEP, 2)
	y += 16
	draw_text(sheet, Vector2i(x, y), "OVER LIMIT %5.1f%%" % _pct(int(report.unwalkable_cells), land), body, 2)
	y += 22
	draw_text(sheet, Vector2i(x, y), "HEIGHT %.0f TO %.0f M" % [float(report.min_h), float(report.max_h)], body, 2)
	y += 16
	if mode != Mode.SLOPE:
		draw_text(sheet, Vector2i(x, y), "CONTOURS EVERY %.0f M" % float(report.contour_m), dim, 2)
		y += 16
	draw_text(sheet, Vector2i(x, y), "COAST LINE IS SAND", dim, 2)
	y += 26
	var cut := float(report.moderate_max)
	if not report.clusters.is_empty():
		cut = float(report.clusters[0].cut_deg)
	draw_text(sheet, Vector2i(x, y), "CLIFFS %.0f+ DEG" % cut, title, 2)
	y += 18
	var rank := 1
	for cluster in report.clusters:
		if rank > 6:
			break
		draw_text(sheet, Vector2i(x, y), "%d  X %.0f  Z %.0f" % [rank, float(cluster.max_x), float(cluster.max_z)], body, 2)
		y += 14
		draw_text(sheet, Vector2i(x, y), "   %.0f DEG  %.0f M2" % [float(cluster.max_deg), float(cluster.area_m2)], dim, 2)
		y += 16
		rank += 1
	y += 8
	draw_text(sheet, Vector2i(x, y), "NORTH IS UP", dim, 2)
	y += 14
	draw_text(sheet, Vector2i(x, y), "MARKS ARE STEEPEST POINT", dim, 2)
	y += 14
	draw_text(sheet, Vector2i(x, y), "READ ONLY DEV MAP", dim, 2)


func _swatch(sheet: Image, x: int, y: int, color: Color, name: String, range_text: String) -> int:
	sheet.fill_rect(Rect2i(x, y, 22, 14), color)
	draw_text(sheet, Vector2i(x + 30, y + 1), name, Color(0.9, 0.95, 0.97), 2)
	draw_text(sheet, Vector2i(x + 30, y + 16), range_text, Color(0.62, 0.76, 0.80), 2)
	return y + 40


func _slope_color(deg: float, gentle: float, moderate: float) -> Color:
	if deg < gentle:
		var t := clampf(deg / maxf(gentle, 0.001), 0.0, 1.0)
		return COL_GENTLE.lerp(COL_GENTLE_DARK, t * 0.55)
	if deg < moderate:
		var t := clampf((deg - gentle) / maxf(moderate - gentle, 0.001), 0.0, 1.0)
		return COL_MOD.lerp(COL_MOD_DARK, t * 0.45)
	var t := clampf((deg - moderate) / 40.0, 0.0, 1.0)
	return COL_STEEP.lerp(COL_STEEP_DARK, t * 0.7)


func _water_color(h: float, min_h: float) -> Color:
	var t := clampf((h - min_h) / maxf(-min_h, 1.0), 0.0, 1.0)
	return COL_DEEP.lerp(COL_SHALLOW, t)


func _elev_color(h: float, max_h: float) -> Color:
	var t := clampf(h / maxf(max_h, 1.0), 0.0, 1.0)
	if t < 0.12:
		return COL_ELEV[0].lerp(COL_ELEV[1], t / 0.12)
	if t < 0.35:
		return COL_ELEV[1].lerp(COL_ELEV[2], (t - 0.12) / 0.23)
	if t < 0.65:
		return COL_ELEV[2].lerp(COL_ELEV[3], (t - 0.35) / 0.30)
	return COL_ELEV[3].lerp(COL_ELEV[4], clampf((t - 0.65) / 0.35, 0.0, 1.0))


func _pct(part: int, whole: int) -> float:
	if whole <= 0:
		return 0.0
	return 100.0 * float(part) / float(whole)


func _byte(channel: float) -> int:
	return clampi(int(round(channel * 255.0)), 0, 255)


static func draw_text(image: Image, at: Vector2i, text: String, color: Color, scale: int) -> void:
	var glyphs := _glyphs()
	var x := at.x
	var y := at.y
	for i in text.length():
		var ch := text.substr(i, 1)
		if ch == " ":
			x += 3 * scale
			continue
		if not glyphs.has(ch):
			push_warning("SlopeAnalyzer font missing '%s'" % ch)
			x += 4 * scale
			continue
		var rows: Array = glyphs[ch]
		for ry in 7:
			var bits: int = int(rows[ry])
			for rx in 5:
				if bits & (1 << (4 - rx)):
					for sy in scale:
						for sx in scale:
							_pixel(image, x + rx * scale + sx, y + ry * scale + sy, color)
		x += 6 * scale


static func _pixel(image: Image, x: int, y: int, color: Color) -> void:
	if x < 0 or y < 0 or x >= image.get_width() or y >= image.get_height():
		return
	image.set_pixel(x, y, color)


static func _glyphs() -> Dictionary:
	if not _glyph_cache.is_empty():
		return _glyph_cache
	var blocks := FONT_SRC.strip_edges().split("\n\n", false)
	for block in blocks:
		var lines: PackedStringArray = block.split("\n", false)
		if lines.size() < 8:
			continue
		var key := lines[0].strip_edges()
		var rows: Array[int] = []
		for i in 7:
			var bits := 0
			var row := lines[i + 1]
			for col in mini(5, row.length()):
				if row.substr(col, 1) == "#":
					bits |= 1 << (4 - col)
			rows.append(bits)
		_glyph_cache[key] = rows
	return _glyph_cache


const FONT_SRC := """
A
.###.
#...#
#...#
#####
#...#
#...#
#...#

B
####.
#...#
#...#
####.
#...#
#...#
####.

C
.###.
#...#
#....
#....
#....
#...#
.###.

D
####.
#...#
#...#
#...#
#...#
#...#
####.

E
#####
#....
#....
####.
#....
#....
#####

F
#####
#....
#....
####.
#....
#....
#....

G
.###.
#...#
#....
#.###
#...#
#...#
.###.

H
#...#
#...#
#...#
#####
#...#
#...#
#...#

I
.###.
..#..
..#..
..#..
..#..
..#..
.###.

J
..###
...#.
...#.
...#.
#..#.
#..#.
.##..

K
#...#
#..#.
#.#..
##...
#.#..
#..#.
#...#

L
#....
#....
#....
#....
#....
#....
#####

M
#...#
##.##
#.#.#
#.#.#
#...#
#...#
#...#

N
#...#
##..#
#.#.#
#..##
#...#
#...#
#...#

O
.###.
#...#
#...#
#...#
#...#
#...#
.###.

P
####.
#...#
#...#
####.
#....
#....
#....

Q
.###.
#...#
#...#
#...#
#.#.#
#..#.
.##.#

R
####.
#...#
#...#
####.
#.#..
#..#.
#...#

S
.####
#....
#....
.###.
....#
....#
####.

T
#####
..#..
..#..
..#..
..#..
..#..
..#..

U
#...#
#...#
#...#
#...#
#...#
#...#
.###.

V
#...#
#...#
#...#
.#.#.
.#.#.
.#.#.
..#..

W
#...#
#...#
#...#
#.#.#
#.#.#
##.##
#...#

X
#...#
.#.#.
.#.#.
..#..
.#.#.
.#.#.
#...#

Y
#...#
#...#
.#.#.
..#..
..#..
..#..
..#..

Z
#####
....#
...#.
..#..
.#...
#....
#####

0
.###.
#...#
#..##
#.#.#
##..#
#...#
.###.

1
..#..
.##..
..#..
..#..
..#..
..#..
.###.

2
.###.
#...#
....#
...#.
..#..
.#...
#####

3
.###.
#...#
....#
..##.
....#
#...#
.###.

4
...#.
..##.
.#.#.
#..#.
#####
...#.
...#.

5
#####
#....
####.
....#
....#
#...#
.###.

6
..##.
.#...
#....
####.
#...#
#...#
.###.

7
#####
....#
...#.
..#..
..#..
..#..
..#..

8
.###.
#...#
#...#
.###.
#...#
#...#
.###.

9
.###.
#...#
#...#
.####
....#
...#.
.##..

%
#...#
#..#.
...#.
..#..
.#...
#..#.
#...#

.
.....
.....
.....
.....
.....
.##..
.##..

-
.....
.....
.....
#####
.....
.....
.....

+
..#..
..#..
..#..
#####
..#..
..#..
..#..
"""
