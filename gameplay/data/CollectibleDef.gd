class_name CollectibleDef
extends Resource
## Reusable overworld collectible definition for sparkling ground discoveries.

@export var id: StringName = &""
@export var item_id: StringName = &""
@export var display_name: String = ""
@export var min_amount: int = 1
@export var max_amount: int = 1
@export var rarity_weight: float = 1.0
@export var respawn_seconds: float = 180.0
@export var sparkle_color: Color = Color(1.0, 0.96, 0.78)
@export var region_tag: StringName = &"black_sand_beach"
