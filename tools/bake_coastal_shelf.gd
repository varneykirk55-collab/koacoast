extends SceneTree
## Rebuild materials/CoastalShelf.png from the live terrain heights.
## Encoding is unchanged: texel (i + 0.5, j + 0.5) maps through (p + 1025) / 2048,
## and the 8-bit value stores height as (clamp(h, -48, 16) + 48) / 64.
## Does not write terrain regions.

var _frames := 0


func _initialize() -> void:
	var scene := (load("res://scenes/KoaCoast.tscn") as PackedScene).instantiate()
	root.add_child(scene)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 4:
		return false
	var data = root.get_node("KoaCoast/Terrain3D").data
	var img := Image.create(1024, 1024, false, Image.FORMAT_L8)
	var missed := 0
	for j in 1024:
		for i in 1024:
			var u := (float(i) + 0.5) / 1024.0
			var v := (float(j) + 0.5) / 1024.0
			var x := u * 2048.0 - 1025.0
			var z := v * 2048.0 - 1025.0
			var h: float = data.get_height(Vector3(x, 0.0, z))
			if is_nan(h):
				h = -40.0
				missed += 1
			h = clampf(h, -48.0, 16.0)
			var r := (h + 48.0) / 64.0
			img.set_pixel(i, j, Color(r, r, r, 1.0))
	var path := "/workspace/materials/CoastalShelf.png"
	var err := img.save_png(path)
	print("SHELF_SAVED ", err, " missed ", missed)
	# Spot-check the beach the screenshots use.
	for p in [Vector2(-80, 608), Vector2(-84, 617), Vector2(48, 576)]:
		var th: float = data.get_height(Vector3(p.x, 0.0, p.y))
		var uv := Vector2((p.x + 1025.0) / 2048.0, (p.y + 1025.0) / 2048.0)
		var px := clampi(int(uv.x * 1024.0), 0, 1023)
		var py := clampi(int(uv.y * 1024.0), 0, 1023)
		var sh: float = img.get_pixel(px, py).r * 64.0 - 48.0
		print("CHECK ", p, " terrain ", th, " shelf ", sh)
	quit(0)
	return true
