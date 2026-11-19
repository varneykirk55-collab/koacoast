extends SceneTree
## Rebuild the PacificOcean grid: fine over the island, coarse at the horizon.
## Same resource path and Y = 0. Does not touch terrain regions.

func _initialize() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_grid(st, -2400.0, 2400.0, -2400.0, 2400.0, 12.0)
	_grid(st, -10000.0, 10000.0, 2400.0, 10000.0, 80.0)
	_grid(st, -10000.0, 10000.0, -10000.0, -2400.0, 80.0)
	_grid(st, 2400.0, 10000.0, -2400.0, 2400.0, 80.0)
	_grid(st, -10000.0, -2400.0, -2400.0, 2400.0, 80.0)
	_grid(st, -52000.0, 52000.0, 10000.0, 52000.0, 500.0)
	_grid(st, -52000.0, 52000.0, -52000.0, -10000.0, 500.0)
	_grid(st, 10000.0, 52000.0, -10000.0, 10000.0, 500.0)
	_grid(st, -52000.0, -10000.0, -10000.0, 10000.0, 500.0)
	st.generate_normals()
	var mesh := st.commit()
	var err := ResourceSaver.save(mesh, "res://materials/OceanSurface.res")
	print("OCEAN_MESH ", err, " verts ", _vert_count)
	quit(0 if err == OK else 1)


func _grid(st: SurfaceTool, x0: float, x1: float, z0: float, z1: float, step: float) -> void:
	var nx := int(round((x1 - x0) / step))
	var nz := int(round((z1 - z0) / step))
	nx = maxi(nx, 1)
	nz = maxi(nz, 1)
	var base := _vert_count
	for j in nz + 1:
		for i in nx + 1:
			var x := x0 + float(i) * step
			var z := z0 + float(j) * step
			st.set_uv(Vector2(x, z) / 2048.0)
			st.add_vertex(Vector3(x, 0.0, z))
			_vert_count += 1
	for j in nz:
		for i in nx:
			var a := base + j * (nx + 1) + i
			var b := a + 1
			var c := a + (nx + 1)
			var d := c + 1
			st.add_index(a)
			st.add_index(c)
			st.add_index(b)
			st.add_index(b)
			st.add_index(c)
			st.add_index(d)


var _vert_count := 0
