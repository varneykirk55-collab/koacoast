extends SceneTree
## Read-only dump of the stitched Terrain3D height grid.
##   godot --headless --path . --script res://tools/walkability_dump.gd

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var scene := (load("res://scenes/KoaCoast.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	for _i in 4:
		await process_frame
	var terrain := scene.get_node("Terrain3D")
	var data = terrain.data
	var regions: Array = data.get_regions_active()
	var rs := int(terrain.region_size)
	var spacing := float(terrain.vertex_spacing)
	var min_loc := Vector2i(1 << 20, 1 << 20)
	var max_loc := Vector2i(-(1 << 20), -(1 << 20))
	for region in regions:
		var loc: Vector2i = region.location
		min_loc.x = mini(min_loc.x, loc.x)
		min_loc.y = mini(min_loc.y, loc.y)
		max_loc.x = maxi(max_loc.x, loc.x)
		max_loc.y = maxi(max_loc.y, loc.y)
	var w := (max_loc.x - min_loc.x + 1) * rs
	var d := (max_loc.y - min_loc.y + 1) * rs
	var heights := PackedFloat32Array()
	heights.resize(w * d)
	for region in regions:
		var copy := (region.height_map as Image).duplicate() as Image
		if copy.get_format() != Image.FORMAT_RF:
			copy.convert(Image.FORMAT_RF)
		var hv: PackedFloat32Array = copy.get_data().to_float32_array()
		var loc: Vector2i = region.location
		var ox := (loc.x - min_loc.x) * rs
		var oz := (loc.y - min_loc.y) * rs
		var img_w := copy.get_width()
		for py in rs:
			var dst := (oz + py) * w + ox
			var src := py * img_w
			for px in rs:
				heights[dst + px] = hv[src + px]
	var out_path := "/tmp/koacoast_heights.f32"
	var file := FileAccess.open(out_path, FileAccess.WRITE)
	file.store_buffer(heights.to_byte_array())
	file.close()
	var meta := FileAccess.open("/tmp/koacoast_grid.txt", FileAccess.WRITE)
	meta.store_string("%d %d %.6f %d %d %d %d %d\n" % [w, d, spacing, min_loc.x, min_loc.y, max_loc.x, max_loc.y, rs])
	meta.close()
	var spawn := Vector3(48.0, 0.0, 576.0)
	var sh: float = data.get_height(spawn)
	var sn: Vector3 = data.get_normal(spawn)
	print("SPAWN_H %.4f" % sh)
	print("SPAWN_SLOPE %.3f" % rad_to_deg(sn.angle_to(Vector3.UP)))
	print("RANGE ", data.get_height_range())
	print("DUMP_OK %d %d" % [w, d])
	quit(0)
