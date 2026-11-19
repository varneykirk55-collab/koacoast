class_name BuildingPieceDef
extends Resource
## Defines a modular building piece type independent of its material.

@export var id: StringName = &""
@export var display_name: String = ""
@export var item_id: StringName = &""
@export var size: Vector3 = Vector3(4.0, 0.5, 4.0)
@export var snap_category: StringName = &"foundation"
@export var requires_support: bool = false
@export var can_place_on_terrain: bool = false
@export var rot_step_deg: float = 90.0
