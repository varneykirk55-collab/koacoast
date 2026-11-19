class_name BuildingPieceBuilder
extends RefCounted
## Builds modular 3D geometry and collision shapes for building pieces from
## BuildingPieceDef + BuildingMaterialDef so materials remain decoupled from shape.

const CELL := 4.0
const HALF := 2.0
const WALL_H := 3.0


static func build_piece_node(piece_def: BuildingPieceDef, mat_def: BuildingMaterialDef, is_preview := false) -> Dictionary:
	var root := Node3D.new()
	var main_mat := _create_material(mat_def, false, is_preview)
	var accent_mat := _create_material(mat_def, true, is_preview)
	var mesh_instances: Array[MeshInstance3D] = []
	var door_hinge: Node3D = null

	match piece_def.id:
		&"foundation":
			_add_box(root, Vector3(CELL, 0.4, CELL), Vector3(0.0, -0.2, 0.0), main_mat, mesh_instances, not is_preview)
			for sx in [-1.75, 1.75]:
				for sz in [-1.75, 1.75]:
					_add_box(root, Vector3(0.34, 2.5, 0.34), Vector3(sx, -1.65, sz), accent_mat, mesh_instances, not is_preview)
		&"floor":
			_add_box(root, Vector3(CELL, 0.22, CELL), Vector3(0.0, -0.11, 0.0), main_mat, mesh_instances, not is_preview)
			_add_box(root, Vector3(CELL, 0.06, 0.16), Vector3(0.0, -0.22, -HALF + 0.12), accent_mat, mesh_instances, false)
			_add_box(root, Vector3(CELL, 0.06, 0.16), Vector3(0.0, -0.22, HALF - 0.12), accent_mat, mesh_instances, false)
		&"wall":
			_add_box(root, Vector3(CELL, WALL_H, 0.24), Vector3(0.0, WALL_H * 0.5, 0.0), main_mat, mesh_instances, not is_preview)
			_add_box(root, Vector3(0.26, WALL_H, 0.28), Vector3(-HALF + 0.13, WALL_H * 0.5, 0.0), accent_mat, mesh_instances, false)
			_add_box(root, Vector3(0.26, WALL_H, 0.28), Vector3(HALF - 0.13, WALL_H * 0.5, 0.0), accent_mat, mesh_instances, false)
		&"doorway":
			_add_box(root, Vector3(1.28, WALL_H, 0.24), Vector3(-1.36, WALL_H * 0.5, 0.0), main_mat, mesh_instances, not is_preview)
			_add_box(root, Vector3(1.28, WALL_H, 0.24), Vector3(1.36, WALL_H * 0.5, 0.0), main_mat, mesh_instances, not is_preview)
			_add_box(root, Vector3(1.44, 0.76, 0.24), Vector3(0.0, 2.62, 0.0), main_mat, mesh_instances, not is_preview)
			_add_box(root, Vector3(0.14, 2.24, 0.28), Vector3(-0.72, 1.12, 0.0), accent_mat, mesh_instances, false)
			_add_box(root, Vector3(0.14, 2.24, 0.28), Vector3(0.72, 1.12, 0.0), accent_mat, mesh_instances, false)
		&"door":
			door_hinge = Node3D.new()
			door_hinge.name = "DoorHinge"
			door_hinge.position = Vector3(-0.70, 0.0, 0.0)
			root.add_child(door_hinge)
			_add_box(door_hinge, Vector3(1.36, 2.18, 0.12), Vector3(0.70, 1.09, 0.0), main_mat, mesh_instances, not is_preview)
			_add_box(door_hinge, Vector3(0.14, 0.14, 0.18), Vector3(1.22, 1.05, 0.0), accent_mat, mesh_instances, false)
		&"roof":
			var slope_len := 2.42
			var pitch := 0.56
			_add_rotated_box(root, Vector3(CELL + 0.2, 0.18, slope_len), Vector3(0.0, 0.68, -1.02), Vector3(pitch, 0.0, 0.0), main_mat, mesh_instances, not is_preview)
			_add_rotated_box(root, Vector3(CELL + 0.2, 0.18, slope_len), Vector3(0.0, 0.68, 1.02), Vector3(-pitch, 0.0, 0.0), main_mat, mesh_instances, not is_preview)
			_add_box(root, Vector3(CELL + 0.2, 0.22, 0.22), Vector3(0.0, 1.30, 0.0), accent_mat, mesh_instances, false)
			for gx in [-HALF + 0.12, HALF - 0.12]:
				_add_box(root, Vector3(0.18, 0.55, 2.2), Vector3(gx, 0.28, 0.0), accent_mat, mesh_instances, false)
				_add_box(root, Vector3(0.18, 0.50, 1.1), Vector3(gx, 0.80, 0.0), accent_mat, mesh_instances, false)
		&"stairs":
			var steps := 8
			for i in steps:
				var t := (float(i) + 0.5) / float(steps)
				var sy := t * WALL_H - 0.12
				var sz := HALF - t * CELL
				_add_box(root, Vector3(3.75, 0.24, CELL / float(steps) + 0.08), Vector3(0.0, sy, sz), main_mat, mesh_instances, false)
			var ramp_angle := atan2(WALL_H, CELL)
			_add_rotated_box(root, Vector3(0.22, 0.24, 5.05), Vector3(-1.88, WALL_H * 0.5 - 0.08, 0.0), Vector3(ramp_angle, 0.0, 0.0), accent_mat, mesh_instances, false)
			_add_rotated_box(root, Vector3(0.22, 0.24, 5.05), Vector3(1.88, WALL_H * 0.5 - 0.08, 0.0), Vector3(ramp_angle, 0.0, 0.0), accent_mat, mesh_instances, false)
			if not is_preview:
				var body := StaticBody3D.new()
				body.collision_layer = 9
				var col := CollisionShape3D.new()
				var shape := BoxShape3D.new()
				shape.size = Vector3(3.85, 0.22, 5.0)
				col.shape = shape
				col.position = Vector3(0.0, WALL_H * 0.5 - 0.12, 0.0)
				col.rotation = Vector3(ramp_angle, 0.0, 0.0)
				body.add_child(col)
				root.add_child(body)

	return {
		"root": root,
		"meshes": mesh_instances,
		"door_hinge": door_hinge,
	}


static func _create_material(mat_def: BuildingMaterialDef, accent: bool, is_preview: bool) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	if is_preview:
		mat.albedo_color = Color(0.2, 0.92, 0.4, 0.45)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		return mat
	mat.albedo_color = mat_def.accent_color if accent else mat_def.albedo_color
	mat.roughness = mat_def.roughness
	return mat


static func _add_box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material, meshes: Array[MeshInstance3D], with_collision: bool) -> void:
	_add_rotated_box(parent, size, pos, Vector3.ZERO, mat, meshes, with_collision)


static func _add_rotated_box(parent: Node3D, size: Vector3, pos: Vector3, rot: Vector3, mat: Material, meshes: Array[MeshInstance3D], with_collision: bool) -> void:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)
	meshes.append(mi)

	if with_collision:
		var body := StaticBody3D.new()
		body.collision_layer = 9 # Layer 1 (world solid) + Layer 4 (buildings)
		var col := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		col.shape = shape
		col.position = pos
		col.rotation = rot
		body.add_child(col)
		parent.add_child(body)
