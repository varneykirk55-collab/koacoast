extends SceneTree
## Headless export of the island slope sheet.
##   godot --headless --path <project> --script res://tools/export_slope_map.gd
## Writes docs/slope_map.png and docs/slope_stats.txt. Does not save the scene.

const Analyzer = preload("res://tools/slope_analyzer.gd")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var scene := (load("res://scenes/KoaCoast.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	for _i in 4:
		await process_frame
	var terrain := scene.get_node_or_null("Terrain3D")
	if terrain == null:
		push_error("Slope export: Terrain3D missing.")
		quit(1)
		return
	var analyzer = Analyzer.new()
	var limits: Vector3 = Analyzer.thresholds_from_player()
	var grid: Dictionary = analyzer.load_grid(terrain)
	if grid.is_empty():
		push_error("Slope export: empty grid.")
		quit(1)
		return
	var report: Dictionary = analyzer.classify(grid, limits.x, limits.y, limits.z)
	var sheet: Image = analyzer.render_sheet(grid, report, Analyzer.Mode.BOTH)
	var png := ProjectSettings.globalize_path("res://docs/slope_map.png")
	var txt := ProjectSettings.globalize_path("res://docs/slope_stats.txt")
	DirAccess.make_dir_recursive_absolute(png.get_base_dir())
	var err := sheet.save_png(png)
	if err != OK:
		push_error("Slope export: PNG save failed: %s" % error_string(err))
		quit(1)
		return
	var text: String = analyzer.summary_text(report)
	var file := FileAccess.open(txt, FileAccess.WRITE)
	if file == null:
		push_error("Slope export: could not write %s" % txt)
		quit(1)
		return
	file.store_string(text)
	file.close()
	print(text)
	print("PNG %s" % png)
	quit(0)
