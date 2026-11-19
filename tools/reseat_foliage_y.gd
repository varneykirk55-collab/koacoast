extends SceneTree
## Snap every foliage instance's Y to Terrain3D.get_height. X/Z stay put.

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var scene := (load("res://scenes/KoaCoast.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	for _i in 4:
		await process_frame
	var data = scene.get_node("Terrain3D").data
	var veg := scene.get_node("IslandVegetation")
	var n := 0
	var moved := 0
	for c in veg.get_children():
		if not (c is MultiMeshInstance3D):
			continue
		var mmi := c as MultiMeshInstance3D
		var mm := mmi.multimesh
		if mm == null or mm.instance_count == 0:
			continue
		var buf := mm.buffer
		var stride := int(buf.size() / mm.instance_count)
		if stride < 12:
			continue
		for k in mm.instance_count:
			var at := k * stride
			var wx := mmi.position.x + buf[at + 3]
			var wz := mmi.position.z + buf[at + 11]
			var h: float = data.get_height(Vector3(wx, 0.0, wz))
			if is_nan(h):
				continue
			if absf(buf[at + 7] - h) > 0.02:
				moved += 1
			buf[at + 7] = h
			n += 1
		mm.buffer = buf
	for c in veg.get_children():
		c.owner = veg
	var packed := PackedScene.new()
	var err := packed.pack(veg)
	if err != OK:
		push_error(error_string(err))
		quit(1)
		return
	err = ResourceSaver.save(packed, "res://foliage/IslandVegetation.scn")
	print("SNAPPED ", n, " moved ", moved, " save ", err)
	quit(0 if err == OK else 1)
