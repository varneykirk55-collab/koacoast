extends SceneTree
## Write the edited height grid back through Terrain3D and save the regions.
## Only height maps are replaced. Control and color maps are left alone.
##   godot --headless --path . --script res://tools/walkability_apply.gd

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var meta_text := FileAccess.get_file_as_string("/tmp/koacoast_grid.txt").split(" ")
	var w := int(meta_text[0])
	var d := int(meta_text[1])
	var rs := int(meta_text[7])
	var edited_bytes := FileAccess.get_file_as_bytes("/tmp/koacoast_heights_edited.f32")
	var edited := edited_bytes.to_float32_array()
	if edited.size() != w * d:
		push_error("Edited grid size %d != %d" % [edited.size(), w * d])
		quit(1)
		return
	var scene := (load("res://scenes/KoaCoast.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	for _i in 4:
		await process_frame
	var terrain := scene.get_node("Terrain3D")
	var data = terrain.data
	var regions: Array = data.get_regions_active()
	var min_loc := Vector2i(1 << 20, 1 << 20)
	for region in regions:
		var loc: Vector2i = region.location
		min_loc.x = mini(min_loc.x, loc.x)
		min_loc.y = mini(min_loc.y, loc.y)
	var changed := 0
	for region in regions:
		var loc: Vector2i = region.location
		var ox := (loc.x - min_loc.x) * rs
		var oz := (loc.y - min_loc.y) * rs
		var buf := PackedFloat32Array()
		buf.resize(rs * rs)
		var max_abs := 0.0
		var old := (region.height_map as Image).get_data().to_float32_array()
		for py in rs:
			for px in rs:
				var v: float = edited[(oz + py) * w + ox + px]
				buf[py * rs + px] = v
				max_abs = maxf(max_abs, absf(v - old[py * rs + px]))
		if max_abs < 0.01:
			print("REGION_UNCHANGED ", loc)
			continue
		region.height_map = Image.create_from_data(rs, rs, false, Image.FORMAT_RF, buf.to_byte_array())
		if region.has_method("calc_height_range"):
			region.calc_height_range()
		if region.has_method("set_modified"):
			region.set_modified(true)
		else:
			region.set("modified", true)
		changed += 1
		print("REGION_CHANGED ", loc, " max_abs ", max_abs)
	data.update_maps(Terrain3DRegion.TYPE_HEIGHT, true, false)
	if data.has_method("calc_height_range"):
		data.calc_height_range(true)
	data.save_directory(terrain.data_directory)
	print("SAVE ok")
	print("CHANGED_REGIONS ", changed)
	var spawn := Vector3(48.0, 0.0, 576.0)
	print("SPAWN_H %.4f" % float(data.get_height(spawn)))
	print("RANGE ", data.get_height_range())
	quit(0)
