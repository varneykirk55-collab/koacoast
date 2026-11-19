class_name BuildingMaterialDef
extends Resource
## Separates building material visuals/properties from piece geometry.

@export var id: StringName = &"wood"
@export var display_name: String = "Wood"
@export var albedo_color: Color = Color(0.55, 0.37, 0.21)
@export var accent_color: Color = Color(0.39, 0.25, 0.14)
@export var roughness: float = 0.85
