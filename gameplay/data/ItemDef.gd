class_name ItemDef
extends Resource
## Reusable data-driven item definition for resources, collectibles, tools, and building pieces.

@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""
@export var category: StringName = &"resource"
@export var max_stack: int = 99
@export var icon_color: Color = Color.WHITE
@export var icon_shape: StringName = &"wood"
@export var placeable_piece_id: StringName = &""
@export var tool_kind: StringName = &""
@export var tool_bonus: int = 0
