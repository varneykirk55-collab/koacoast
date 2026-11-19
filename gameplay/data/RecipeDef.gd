class_name RecipeDef
extends Resource
## Reusable recipe definition linking required ingredient items to a crafted output item.

@export var id: StringName = &""
@export var display_name: String = ""
@export var output_item_id: StringName = &""
@export var output_amount: int = 1
@export var station: StringName = &"hand"
## Array of {"item_id": StringName, "amount": int}
@export var ingredients: Array[Dictionary] = []
