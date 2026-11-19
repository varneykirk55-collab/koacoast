class_name IslandMapGenerator
extends RefCounted
## Generates a 2D cartographic map texture directly from Terrain3D height/texture
## data and KoaCoast's freshwater watersheds.json. Read-only; never edits terrain.

const MAP_RES := 512
const WATERWAYS := preload("res://freshwater/watersheds.json")


static func generate_map(terrain: Terrain3D) -> Dictionary:
	var fallback := {
		"texture": ImageTexture.create_from_image(Image.create(64, 64, false, Image.FORMAT_RGBA8)),
		"world_rect": Rect2(-1024.0, -1024.0, 2048.0, 2048.0),
	}
	if terrain == null or terrain.data == null:
		return fallback

	var data := terrain.data
	var regions: Array = data.get_regions_active()
	if regions.is_empty():
		return fallback

	var region_size := int(terrain.region_size)
	var spacing := float(terrain.vertex_spacing)
	var min_loc := Vector2i(1 << 20, 1 << 20)
	var max_loc := Vector2i(-(1 << 20), -(1 << 20))
	for region in regions:
		var loc: Vector2i = region.location
		min_loc.x = mini(min_loc.x, loc.x)
		min_loc.y = mini(min_loc.y, loc.y)
		max_loc.x = maxi(max_loc.x, loc.x)
		max_loc.y = maxi(max_loc.y, loc.y)

	var gw := (max_loc.x - min_loc.x + 1) * region_size
	var gd := (max_loc.y - min_loc.y + 1) * region_size
	var heights := PackedFloat32Array()
	heights.resize(gw * gd)
	heights.fill(NAN)

	for region in regions:
		var src := region.height_map as Image
		if src == null:
			continue
		var copy := src.duplicate() as Image
		if copy.get_format() != Image.FORMAT_RF:
			copy.convert(Image.FORMAT_RF)
		var hv: PackedFloat32Array = copy.get_data().to_float32_array()
		var loc: Vector2i = region.location
		var ox := (loc.x - min_loc.x) * region_size
		var oz := (loc.y - min_loc.y) * region_size
		var img_w := copy.get_width()
		for py in region_size:
			var row := (oz + py) * gw + ox
			var src_row := py * img_w
			for px in region_size:
				heights[row + px] = hv[src_row + px]

	var origin := Vector2(float(min_loc.x * region_size) * spacing, float(min_loc.y * region_size) * spacing)
	var world_size := Vector2(float(gw) * spacing, float(gd) * spacing)
	var span := maxf(world_size.x, world_size.y)
	var center := origin + world_size * 0.5
	var rect := Rect2(center - Vector2(span, span) * 0.5, Vector2(span, span))

	var img := Image.create(MAP_RES, MAP_RES, false, Image.FORMAT_RGBA8)
	for py in MAP_RES:
		var wz := rect.position.y + (float(py) + 0.5) / float(MAP_RES) * rect.size.y
		for px in MAP_RES:
			var wx := rect.position.x + (float(px) + 0.5) / float(MAP_RES) * rect.size.x
			var h := _sample_grid(heights, gw, gd, origin, spacing, wx, wz)
			var col := _shade_pixel(heights, gw, gd, origin, spacing, wx, wz, h, data)
			img.set_pixel(px, py, col)

	_draw_waterways(img, rect)
	return {
		"texture": ImageTexture.create_from_image(img),
		"world_rect": rect,
	}


static func world_to_uv(world_pos: Vector3, world_rect: Rect2) -> Vector2:
	if world_rect.size.x <= 0.0 or world_rect.size.y <= 0.0:
		return Vector2(0.5, 0.5)
	return Vector2(
		(world_pos.x - world_rect.position.x) / world_rect.size.x,
		(world_pos.z - world_rect.position.y) / world_rect.size.y
	)


static func _sample_grid(heights: PackedFloat32Array, gw: int, gd: int, origin: Vector2, spacing: float, wx: float, wz: float) -> float:
	var gx := int(floorf((wx - origin.x) / spacing))
	var gz := int(floorf((wz - origin.y) / spacing))
	if gx < 0 or gx >= gw or gz < 0 or gz >= gd:
		return -35.0
	var h := heights[gz * gw + gx]
	return h if is_finite(h) else -35.0


static func _shade_pixel(heights: PackedFloat32Array, gw: int, gd: int, origin: Vector2, spacing: float, wx: float, wz: float, h: float, data) -> Color:
	if h < 0.0:
		var depth := clampf(-h / 32.0, 0.0, 1.0)
		var shallow := Color(0.11, 0.49, 0.57)
		var deep := Color(0.03, 0.12, 0.24)
		return shallow.lerp(deep, pow(depth, 0.65))

	var hl := _sample_grid(heights, gw, gd, origin, spacing, wx - spacing * 2.0, wz)
	var hr := _sample_grid(heights, gw, gd, origin, spacing, wx + spacing * 2.0, wz)
	var hu := _sample_grid(heights, gw, gd, origin, spacing, wx, wz - spacing * 2.0)
	var hd := _sample_grid(heights, gw, gd, origin, spacing, wx, wz + spacing * 2.0)
	var grad := Vector2((hr - hl) / (spacing * 4.0), (hd - hu) / (spacing * 4.0))
	var normal := Vector3(-grad.x, 1.0, -grad.y).normalized()
	var sun := Vector3(-0.55, 0.70, -0.45).normalized()
	var hillshade := clampf(normal.dot(sun) * 0.65 + 0.52, 0.42, 1.15)

	var base: Color
	if h < 2.8:
		# Highlight shoreline & black-sand beaches.
		var tex: Vector3 = data.get_texture_id(Vector3(wx, h, wz))
		var sand_w := (1.0 - tex.z if int(tex.x) == 3 else 0.0) + (tex.z if int(tex.y) == 3 else 0.0)
		base = Color(0.24, 0.23, 0.22) if sand_w > 0.35 else Color(0.76, 0.70, 0.54)
		if h < 0.45:
			base = base.lightened(0.16)
	elif h < 45.0:
		base = Color(0.24, 0.51, 0.26).lerp(Color(0.32, 0.58, 0.28), clampf(h / 45.0, 0.0, 1.0))
	elif h < 140.0:
		base = Color(0.32, 0.58, 0.28).lerp(Color(0.45, 0.50, 0.27), clampf((h - 45.0) / 95.0, 0.0, 1.0))
	elif h < 240.0:
		base = Color(0.45, 0.50, 0.27).lerp(Color(0.44, 0.39, 0.35), clampf((h - 140.0) / 100.0, 0.0, 1.0))
	else:
		base = Color(0.44, 0.39, 0.35).lerp(Color(0.64, 0.61, 0.58), clampf((h - 240.0) / 120.0, 0.0, 1.0))

	if grad.length() > 1.0:
		base = base.lerp(Color(0.29, 0.28, 0.30), 0.45)

	# Subtle 25m elevation contour lines.
	if h > 2.0 and fmod(h, 25.0) < 1.25:
		base = base.darkened(0.16)

	return (base * hillshade).clamp()


static func _draw_waterways(img: Image, rect: Rect2) -> void:
	var river_col := Color(0.20, 0.78, 0.94)
	var stream_col := Color(0.34, 0.82, 0.94)
	var fall_col := Color(0.86, 0.97, 1.0)
	for watershed: Dictionary in WATERWAYS.data:
		_draw_channel(img, rect, watershed.river, river_col, 2)
		for stream: Dictionary in watershed.streams:
			_draw_channel(img, rect, stream, stream_col, 1)
		for fall: Array in watershed.river.falls:
			var pt: Array = watershed.river.points[int(fall[1])]
			_paint_dot(img, rect, Vector2(float(pt[0]), float(pt[1])), 3, fall_col)


static func _draw_channel(img: Image, rect: Rect2, channel: Dictionary, color: Color, radius: int) -> void:
	var pts: Array = channel.points
	for i in range(1, pts.size()):
		var a := Vector2(float(pts[i - 1][0]), float(pts[i - 1][1]))
		var b := Vector2(float(pts[i][0]), float(pts[i][1]))
		for s in 3:
			var p := a.lerp(b, float(s) / 2.0)
			_paint_dot(img, rect, p, radius, color)


static func _paint_dot(img: Image, rect: Rect2, world_xz: Vector2, radius: int, color: Color) -> void:
	var uv := Vector2(
		(world_xz.x - rect.position.x) / rect.size.x,
		(world_xz.y - rect.position.y) / rect.size.y
	)
	var cx := int(uv.x * float(MAP_RES))
	var cy := int(uv.y * float(MAP_RES))
	var r2 := radius * radius
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			if dx * dx + dy * dy > r2:
				continue
			var x := cx + dx
			var y := cy + dy
			if x >= 0 and x < MAP_RES and y >= 0 and y < MAP_RES:
				img.set_pixel(x, y, color)
