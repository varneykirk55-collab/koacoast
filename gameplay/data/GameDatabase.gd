class_name GameDatabase
extends RefCounted
## Central registry of items, crafting recipes, building materials/pieces,
## collectibles, and procedurally generated item icons.

const ICON_SIZE := 48

var items: Dictionary = {}
var recipes: Array[RecipeDef] = []
var recipes_by_id: Dictionary = {}
var building_materials: Dictionary = {}
var building_material_order: Array[StringName] = [&"thatch", &"wood", &"stone"]
var building_pieces: Dictionary = {}
var building_piece_order: Array[StringName] = []
var building_item_map: Dictionary = {} # "mat:piece" -> item_id
var collectibles: Dictionary = {}
var _icon_cache: Dictionary = {}


func _init() -> void:
	_register_items()
	_register_recipes()
	_register_building_materials()
	_register_building_pieces()
	_register_collectibles()


func get_item(id: StringName) -> ItemDef:
	return items.get(id, null) as ItemDef


func get_recipe(id: StringName) -> RecipeDef:
	return recipes_by_id.get(id, null) as RecipeDef


func get_building_material(id: StringName) -> BuildingMaterialDef:
	return building_materials.get(id, null) as BuildingMaterialDef


func get_building_piece(id: StringName) -> BuildingPieceDef:
	return building_pieces.get(id, null) as BuildingPieceDef


func get_building_item_id(piece_id: StringName, material_id: StringName) -> StringName:
	var key := "%s:%s" % [String(material_id), String(piece_id)]
	if building_item_map.has(key):
		return building_item_map[key]
	return &""


func get_recipe_category(rec: RecipeDef) -> StringName:
	if rec == null:
		return &"other"
	var def := get_item(rec.output_item_id)
	if def == null:
		return &"other"
	if def.category == &"tool":
		return &"tool"
	if def.category == &"component" or def.category == &"container" or def.category == &"survival":
		return &"component"
	if def.category == &"building":
		var id_str := String(def.id)
		if id_str.begins_with("thatch_"):
			return &"thatch"
		if id_str.begins_with("stone_"):
			return &"stone"
		return &"wood"
	return &"other"


func get_collectible(id: StringName) -> CollectibleDef:
	return collectibles.get(id, null) as CollectibleDef


func get_item_icon(id: StringName) -> Texture2D:
	if _icon_cache.has(id):
		return _icon_cache[id] as Texture2D
	var def := get_item(id)
	var tex := _generate_icon(def)
	_icon_cache[id] = tex
	return tex


func _register_items() -> void:
	var rows := [
		[&"wood", "Wood", "Sturdy island timber gathered from koa trees and fallen branches. Used for tool handles and construction.", &"resource", 99, Color(0.58, 0.38, 0.21), &"wood", &"", &"", 0],
		[&"stone", "Stone", "Dense volcanic basalt gathered from coastal boulders. Used for stone tools and heavy stone structures.", &"resource", 99, Color(0.47, 0.50, 0.54), &"stone", &"", &"", 0],
		[&"plant_fiber", "Plant Fiber", "Tough fibrous strands from island grass. Used for bindings and spun into Fiber Rope.", &"resource", 99, Color(0.54, 0.69, 0.32), &"fiber", &"", &"", 0],
		[&"leaves", "Leaves", "Broad tropical fronds and palm leaves. Used for thatch roofs, thatch walls, and natural shelters.", &"resource", 99, Color(0.24, 0.62, 0.28), &"leaf", &"", &"", 0],
		[&"shark_tooth", "Shark Tooth", "Serrated tiger shark tooth found sparkling along black-sand beaches. Future material for a traditional leiomano.", &"collectible", 99, Color(0.92, 0.89, 0.80), &"tooth", &"", &"", 0],
		[&"wild_berries", "Wild Berries", "Tart island berries gathered from valley bushes. Eat to restore +14 Hunger and +3 Thirst.", &"food", 30, Color(0.84, 0.20, 0.24), &"berries", &"", &"", 0, 14.0, 3.0, 0.0],
		[&"coconut", "Coconut", "Fresh island coconut from coastal palms. Eat (+10 Hunger, +12 Thirst) or craft into a Hollowed Coconut Shell.", &"food", 15, Color(0.46, 0.30, 0.16), &"coconut", &"", &"", 0, 10.0, 12.0, 0.0],
		[&"coconut_shell", "Hollowed Coconut Shell", "Primitive water container (100 mL cap). Fill at freshwater streams or rain collectors and drink to restore Thirst.", &"container", 1, Color(0.54, 0.35, 0.18), &"shell", &"", &"", 0, 0.0, 0.0, 100.0],
		[&"rain_tarp", "Rainwater Collection Tarp", "Woven leaf tarp lashed to poles or trees. Captures rainwater during rainfall for refilling containers.", &"survival", 5, Color(0.32, 0.56, 0.30), &"tarp", &"", &"", 0],
		[&"rope", "Fiber Rope", "Braided plant-fiber cordage. Essential binding for advanced tools, doors, and sturdy foundations.", &"component", 99, Color(0.76, 0.68, 0.42), &"rope", &"", &"", 0],
		[&"stone_gathering_tool", "Stone Gathering Tool", "Starter lashed basalt multi-tool. +1 bonus yield on all gathered resources (Wood, Stone, Fiber, Leaves).", &"tool", 1, Color(0.62, 0.66, 0.68), &"pick", &"", &"all", 1],
		[&"stone_axe", "Stone Axe", "Balanced basalt hatchet on a koa handle. +3 Wood and +1 Leaves from trees and fallen branches.", &"tool", 1, Color(0.74, 0.48, 0.26), &"axe", &"", &"wood", 3],
		[&"stone_pickaxe", "Stone Pickaxe", "Pointed volcanic basalt pick. +3 Stone when mining rocks and coastal boulders.", &"tool", 1, Color(0.54, 0.62, 0.72), &"pick", &"", &"stone", 3],
		[&"harvest_knife", "Basalt Harvest Knife", "Sharp chipped-basalt blade with leaf-wrapped grip. +2 Plant Fiber and +2 Leaves from vegetation.", &"tool", 1, Color(0.42, 0.72, 0.44), &"knife", &"", &"foliage", 2],
	]
	for r: Array in rows:
		_add_item(r)

	# Register building piece items across Thatch, Wood, and Stone tiers.
	var building_defs := [
		# Thatch tier (leaves + plant fiber + light wood framing)
		[&"thatch_floor", "Thatch Floor", "Lightweight woven frond deck for simple shelters. Material: Thatch.", &"thatch", &"floor", Color(0.72, 0.63, 0.34), &"floor"],
		[&"thatch_wall", "Thatch Wall", "Woven palm-frond wall panel framed with wood and fiber. Material: Thatch.", &"thatch", &"wall", Color(0.69, 0.60, 0.32), &"wall"],
		[&"thatch_doorway", "Thatch Doorway", "Woven thatch wall with an open doorway frame. Material: Thatch.", &"thatch", &"doorway", Color(0.70, 0.61, 0.33), &"doorway"],
		[&"thatch_door", "Thatch Door", "Woven frond hinged door bound with Fiber Rope. Material: Thatch.", &"thatch", &"door", Color(0.64, 0.54, 0.28), &"door"],
		[&"thatch_roof", "Thatch Roof", "Traditional pitched tropical leaf roof that sheds rain. Material: Thatch.", &"thatch", &"roof", Color(0.74, 0.65, 0.35), &"roof"],
		# Wood tier
		[&"wood_foundation", "Wooden Foundation", "Elevated timber platform with support pilings for slopes and beaches. Material: Wood.", &"wood", &"foundation", Color(0.64, 0.44, 0.24), &"foundation"],
		[&"wood_floor", "Wooden Floor", "Timber deck slab for upper stories or walkways. Material: Wood.", &"wood", &"floor", Color(0.72, 0.52, 0.30), &"floor"],
		[&"wood_wall", "Wooden Wall", "Full-height timber wall panel. Material: Wood.", &"wood", &"wall", Color(0.61, 0.41, 0.22), &"wall"],
		[&"wood_doorway", "Wooden Doorway", "Timber wall frame with doorway opening. Material: Wood.", &"wood", &"doorway", Color(0.66, 0.46, 0.26), &"doorway"],
		[&"wood_door", "Wooden Door", "Hinged timber plank door bound with Fiber Rope. Opens with Interact. Material: Wood.", &"wood", &"door", Color(0.52, 0.33, 0.18), &"door"],
		[&"wood_roof", "Wooden Roof", "Sloped timber roof section insulated with tropical leaves. Material: Wood.", &"wood", &"roof", Color(0.50, 0.34, 0.19), &"roof"],
		[&"wood_stairs", "Wooden Stairs", "Timber staircase connecting terrain, foundations, and upper floors. Material: Wood.", &"wood", &"stairs", Color(0.68, 0.48, 0.27), &"stairs"],
		# Stone tier
		[&"stone_foundation", "Stone Foundation", "Heavy volcanic basalt foundation with deep corner pilings. Material: Stone.", &"stone", &"foundation", Color(0.45, 0.48, 0.52), &"foundation"],
		[&"stone_floor", "Stone Floor", "Cut basalt slab reinforced with timber beams. Material: Stone.", &"stone", &"floor", Color(0.50, 0.53, 0.57), &"floor"],
		[&"stone_wall", "Stone Wall", "Thick mortared basalt wall for durable shelters. Material: Stone.", &"stone", &"wall", Color(0.43, 0.46, 0.50), &"wall"],
		[&"stone_doorway", "Stone Doorway", "Basalt archway sized for wooden or thatch doors. Material: Stone.", &"stone", &"doorway", Color(0.46, 0.49, 0.53), &"doorway"],
		[&"stone_roof", "Stone Roof", "Reinforced slate-and-timber roof built for coastal winds. Material: Stone.", &"stone", &"roof", Color(0.40, 0.43, 0.47), &"roof"],
		[&"stone_stairs", "Stone Stairs", "Solid carved basalt staircase for multi-tier bases. Material: Stone.", &"stone", &"stairs", Color(0.48, 0.51, 0.55), &"stairs"],
	]
	for b: Array in building_defs:
		_add_item([b[0], b[1], b[2], &"building", 50, b[5], b[6], b[4], &"", 0])
		building_item_map["%s:%s" % [String(b[3]), String(b[4])]] = b[0]


func _add_item(r: Array) -> void:
	var item := ItemDef.new()
	item.id = r[0]
	item.display_name = r[1]
	item.description = r[2]
	item.category = r[3]
	item.max_stack = r[4]
	item.icon_color = r[5]
	item.icon_shape = r[6]
	item.placeable_piece_id = r[7]
	item.tool_kind = r[8]
	item.tool_bonus = r[9]
	if r.size() >= 13:
		item.hunger_restore = float(r[10])
		item.thirst_restore = float(r[11])
		item.water_capacity = float(r[12])
	items[item.id] = item


func _register_recipes() -> void:
	var rows := [
		# Components & Survival Gear
		[&"craft_rope", "Fiber Rope (x2)", &"rope", 2, &"hand", [{ "item_id": &"plant_fiber", "amount": 3 }]],
		[&"craft_coconut_shell", "Hollowed Coconut Shell", &"coconut_shell", 1, &"hand", [{ "item_id": &"coconut", "amount": 1 }, { "item_id": &"stone", "amount": 1 }]],
		[&"craft_rain_tarp", "Rainwater Collection Tarp", &"rain_tarp", 1, &"hand", [{ "item_id": &"leaves", "amount": 6 }, { "item_id": &"rope", "amount": 2 }, { "item_id": &"wood", "amount": 2 }]],
		# Tool progression
		[&"craft_stone_tool", "Stone Gathering Tool", &"stone_gathering_tool", 1, &"hand", [{ "item_id": &"wood", "amount": 2 }, { "item_id": &"stone", "amount": 2 }, { "item_id": &"plant_fiber", "amount": 2 }]],
		[&"craft_stone_axe", "Stone Axe", &"stone_axe", 1, &"hand", [{ "item_id": &"wood", "amount": 3 }, { "item_id": &"stone", "amount": 3 }, { "item_id": &"rope", "amount": 1 }]],
		[&"craft_stone_pickaxe", "Stone Pickaxe", &"stone_pickaxe", 1, &"hand", [{ "item_id": &"wood", "amount": 3 }, { "item_id": &"stone", "amount": 4 }, { "item_id": &"rope", "amount": 1 }]],
		[&"craft_harvest_knife", "Basalt Harvest Knife", &"harvest_knife", 1, &"hand", [{ "item_id": &"wood", "amount": 1 }, { "item_id": &"stone", "amount": 2 }, { "item_id": &"rope", "amount": 1 }, { "item_id": &"leaves", "amount": 2 }]],
		# Thatch building tier
		[&"craft_thatch_floor", "Thatch Floor", &"thatch_floor", 1, &"hand", [{ "item_id": &"leaves", "amount": 4 }, { "item_id": &"plant_fiber", "amount": 2 }, { "item_id": &"wood", "amount": 1 }]],
		[&"craft_thatch_wall", "Thatch Wall", &"thatch_wall", 1, &"hand", [{ "item_id": &"leaves", "amount": 4 }, { "item_id": &"plant_fiber", "amount": 2 }, { "item_id": &"wood", "amount": 1 }]],
		[&"craft_thatch_doorway", "Thatch Doorway", &"thatch_doorway", 1, &"hand", [{ "item_id": &"leaves", "amount": 3 }, { "item_id": &"plant_fiber", "amount": 2 }, { "item_id": &"wood", "amount": 1 }]],
		[&"craft_thatch_door", "Thatch Door", &"thatch_door", 1, &"hand", [{ "item_id": &"leaves", "amount": 3 }, { "item_id": &"rope", "amount": 1 }]],
		[&"craft_thatch_roof", "Thatch Roof", &"thatch_roof", 1, &"hand", [{ "item_id": &"leaves", "amount": 5 }, { "item_id": &"plant_fiber", "amount": 2 }]],
		# Wood building tier
		[&"craft_foundation", "Wooden Foundation", &"wood_foundation", 1, &"hand", [{ "item_id": &"wood", "amount": 4 }, { "item_id": &"rope", "amount": 1 }]],
		[&"craft_floor", "Wooden Floor", &"wood_floor", 1, &"hand", [{ "item_id": &"wood", "amount": 3 }, { "item_id": &"plant_fiber", "amount": 1 }]],
		[&"craft_wall", "Wooden Wall", &"wood_wall", 1, &"hand", [{ "item_id": &"wood", "amount": 3 }, { "item_id": &"plant_fiber", "amount": 2 }]],
		[&"craft_doorway", "Wooden Doorway", &"wood_doorway", 1, &"hand", [{ "item_id": &"wood", "amount": 3 }, { "item_id": &"plant_fiber", "amount": 1 }]],
		[&"craft_door", "Wooden Door", &"wood_door", 1, &"hand", [{ "item_id": &"wood", "amount": 2 }, { "item_id": &"rope", "amount": 1 }]],
		[&"craft_roof", "Wooden Roof", &"wood_roof", 1, &"hand", [{ "item_id": &"wood", "amount": 3 }, { "item_id": &"leaves", "amount": 2 }, { "item_id": &"plant_fiber", "amount": 1 }]],
		[&"craft_stairs", "Wooden Stairs", &"wood_stairs", 1, &"hand", [{ "item_id": &"wood", "amount": 4 }, { "item_id": &"rope", "amount": 1 }]],
		# Stone building tier
		[&"craft_stone_foundation", "Stone Foundation", &"stone_foundation", 1, &"hand", [{ "item_id": &"stone", "amount": 5 }, { "item_id": &"wood", "amount": 2 }, { "item_id": &"rope", "amount": 1 }]],
		[&"craft_stone_floor", "Stone Floor", &"stone_floor", 1, &"hand", [{ "item_id": &"stone", "amount": 4 }, { "item_id": &"wood", "amount": 2 }]],
		[&"craft_stone_wall", "Stone Wall", &"stone_wall", 1, &"hand", [{ "item_id": &"stone", "amount": 5 }, { "item_id": &"wood", "amount": 1 }, { "item_id": &"rope", "amount": 1 }]],
		[&"craft_stone_doorway", "Stone Doorway", &"stone_doorway", 1, &"hand", [{ "item_id": &"stone", "amount": 4 }, { "item_id": &"wood", "amount": 2 }, { "item_id": &"rope", "amount": 1 }]],
		[&"craft_stone_roof", "Stone Roof", &"stone_roof", 1, &"hand", [{ "item_id": &"stone", "amount": 5 }, { "item_id": &"wood", "amount": 2 }, { "item_id": &"leaves", "amount": 2 }]],
		[&"craft_stone_stairs", "Stone Stairs", &"stone_stairs", 1, &"hand", [{ "item_id": &"stone", "amount": 6 }, { "item_id": &"wood", "amount": 2 }, { "item_id": &"rope", "amount": 1 }]],
	]
	for r: Array in rows:
		var rec := RecipeDef.new()
		rec.id = r[0]
		rec.display_name = r[1]
		rec.output_item_id = r[2]
		rec.output_amount = r[3]
		rec.station = r[4]
		var typed_ings: Array[Dictionary] = []
		for ing: Dictionary in r[5]:
			typed_ings.append(ing)
		rec.ingredients = typed_ings
		recipes.append(rec)
		recipes_by_id[rec.id] = rec


func _register_building_materials() -> void:
	var mat_rows := [
		[&"thatch", "Thatch", Color(0.68, 0.59, 0.31), Color(0.47, 0.40, 0.19), 0.92],
		[&"wood", "Wood", Color(0.56, 0.37, 0.21), Color(0.37, 0.23, 0.12), 0.85],
		[&"stone", "Stone", Color(0.41, 0.43, 0.46), Color(0.26, 0.28, 0.31), 0.90],
	]
	for r: Array in mat_rows:
		var mat := BuildingMaterialDef.new()
		mat.id = r[0]
		mat.display_name = r[1]
		mat.albedo_color = r[2]
		mat.accent_color = r[3]
		mat.roughness = r[4]
		building_materials[mat.id] = mat


func _register_building_pieces() -> void:
	var rows := [
		[&"foundation", "Foundation", &"wood_foundation", Vector3(4.0, 0.4, 4.0), &"foundation", false, true, 90.0],
		[&"floor", "Floor", &"wood_floor", Vector3(4.0, 0.22, 4.0), &"floor", true, false, 90.0],
		[&"wall", "Wall", &"wood_wall", Vector3(4.0, 3.0, 0.24), &"wall", true, false, 90.0],
		[&"doorway", "Doorway", &"wood_doorway", Vector3(4.0, 3.0, 0.24), &"wall", true, false, 90.0],
		[&"door", "Door", &"wood_door", Vector3(1.36, 2.16, 0.14), &"door", true, false, 90.0],
		[&"roof", "Roof", &"wood_roof", Vector3(4.0, 1.4, 4.0), &"roof", true, false, 90.0],
		[&"stairs", "Stairs", &"wood_stairs", Vector3(4.0, 3.0, 4.0), &"stairs", false, true, 90.0],
	]
	for r: Array in rows:
		var piece := BuildingPieceDef.new()
		piece.id = r[0]
		piece.display_name = r[1]
		piece.item_id = r[2]
		piece.size = r[3]
		piece.snap_category = r[4]
		piece.requires_support = r[5]
		piece.can_place_on_terrain = r[6]
		piece.rot_step_deg = r[7]
		building_pieces[piece.id] = piece
		building_piece_order.append(piece.id)


func _register_collectibles() -> void:
	var tooth := CollectibleDef.new()
	tooth.id = &"shark_tooth"
	tooth.item_id = &"shark_tooth"
	tooth.display_name = "Shark Tooth"
	tooth.min_amount = 1
	tooth.max_amount = 1
	tooth.rarity_weight = 1.0
	tooth.respawn_seconds = 180.0
	tooth.sparkle_color = Color(1.0, 0.96, 0.78)
	tooth.region_tag = &"black_sand_beach"
	collectibles[tooth.id] = tooth


func _generate_icon(def: ItemDef) -> Texture2D:
	var img := Image.create(ICON_SIZE, ICON_SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.09, 0.12, 0.15, 0.85))
	var col := def.icon_color if def else Color.WHITE
	var dark := col.darkened(0.38)
	var light := col.lightened(0.28)
	var shape: StringName = def.icon_shape if def else &"wood"
	_draw_border(img, Color(0.28, 0.35, 0.40, 0.95))
	match shape:
		&"wood":
			_fill_rect(img, 10, 16, 38, 25, col)
			_fill_rect(img, 10, 27, 38, 35, dark)
			_fill_rect(img, 10, 16, 15, 25, light)
			_fill_rect(img, 10, 27, 15, 35, col)
		&"stone":
			_fill_polygon_circle(img, Vector2(24, 26), 13.0, col)
			_fill_polygon_circle(img, Vector2(20, 21), 6.0, light)
			_fill_polygon_circle(img, Vector2(29, 30), 6.0, dark)
		&"fiber":
			for i in 5:
				var x := 12 + i * 6
				_draw_line(img, Vector2(x, 38), Vector2(24 + (i - 2) * 3, 10), col, 2)
			_fill_rect(img, 17, 25, 31, 29, dark)
		&"leaf":
			_fill_polygon_circle(img, Vector2(24, 24), 12.0, col)
			_draw_line(img, Vector2(12, 36), Vector2(36, 12), light, 2)
		&"tooth":
			for y in range(10, 39):
				var t := float(y - 10) / 28.0
				var half_w := int(lerpf(10.0, 1.0, t))
				var cx := int(24.0 + sin(t * 1.4) * 3.0)
				_fill_rect(img, cx - half_w, y, cx + half_w, y + 1, light if y < 17 else col)
		&"pick":
			_draw_line(img, Vector2(12, 37), Vector2(33, 16), Color(0.55, 0.36, 0.20), 3)
			_draw_line(img, Vector2(21, 10), Vector2(38, 27), light, 3)
		&"axe":
			_draw_line(img, Vector2(12, 37), Vector2(33, 16), Color(0.55, 0.36, 0.20), 3)
			_fill_rect(img, 24, 11, 37, 23, Color(0.75, 0.78, 0.82))
		&"rope":
			_fill_polygon_circle(img, Vector2(24, 24), 13.0, col)
			_fill_polygon_circle(img, Vector2(24, 24), 6.0, Color(0.09, 0.12, 0.15, 1.0))
			_draw_line(img, Vector2(29, 31), Vector2(38, 38), light, 3)
		&"knife":
			_draw_line(img, Vector2(12, 36), Vector2(22, 26), Color(0.48, 0.33, 0.18), 3)
			_draw_line(img, Vector2(21, 27), Vector2(37, 11), Color(0.76, 0.80, 0.84), 4)
			_fill_rect(img, 18, 24, 24, 30, col)
		&"berries":
			_fill_polygon_circle(img, Vector2(19, 28), 6.0, col)
			_fill_polygon_circle(img, Vector2(29, 27), 6.0, dark)
			_fill_polygon_circle(img, Vector2(24, 19), 6.0, light)
			_fill_rect(img, 20, 10, 28, 15, Color(0.24, 0.58, 0.26))
		&"coconut":
			_fill_polygon_circle(img, Vector2(24, 25), 13.0, col)
			_fill_polygon_circle(img, Vector2(20, 20), 4.0, dark)
			_fill_polygon_circle(img, Vector2(28, 20), 3.0, dark)
		&"shell":
			_fill_polygon_circle(img, Vector2(24, 27), 13.0, col)
			_fill_rect(img, 10, 12, 38, 24, Color(0.09, 0.12, 0.15, 1.0))
			_fill_rect(img, 13, 22, 35, 26, Color(0.32, 0.72, 0.88))
		&"tarp":
			_draw_line(img, Vector2(10, 38), Vector2(10, 14), Color(0.55, 0.36, 0.20), 2)
			_draw_line(img, Vector2(38, 38), Vector2(38, 14), Color(0.55, 0.36, 0.20), 2)
			_fill_rect(img, 11, 16, 37, 26, col)
			_fill_rect(img, 16, 20, 32, 24, Color(0.28, 0.68, 0.86))
		&"foundation":
			_fill_rect(img, 9, 18, 39, 27, col)
			_fill_rect(img, 11, 27, 15, 38, dark)
			_fill_rect(img, 33, 27, 37, 38, dark)
		&"floor":
			_fill_rect(img, 8, 21, 40, 28, col)
			_fill_rect(img, 8, 21, 40, 23, light)
		&"wall":
			_fill_rect(img, 10, 10, 38, 38, col)
			_draw_line(img, Vector2(10, 20), Vector2(38, 20), dark, 1)
			_draw_line(img, Vector2(10, 29), Vector2(38, 29), dark, 1)
		&"doorway":
			_fill_rect(img, 10, 10, 38, 38, col)
			_fill_rect(img, 18, 18, 30, 38, Color(0.08, 0.11, 0.14, 1.0))
		&"door":
			_fill_rect(img, 15, 10, 33, 38, col)
			_fill_rect(img, 28, 23, 31, 26, light)
		&"roof":
			for y in range(12, 32):
				var half_w := int(float(y - 12) * 0.9) + 2
				_fill_rect(img, 24 - half_w, y, 24 + half_w, y + 1, col if y < 22 else dark)
		&"stairs":
			for step in 5:
				var x0 := 10 + step * 5
				var y0 := 34 - step * 5
				_fill_rect(img, x0, y0, 38, y0 + 5, col if step % 2 == 0 else light)
	return ImageTexture.create_from_image(img)


func _draw_border(img: Image, color: Color) -> void:
	for x in ICON_SIZE:
		img.set_pixel(x, 0, color)
		img.set_pixel(x, ICON_SIZE - 1, color)
	for y in ICON_SIZE:
		img.set_pixel(0, y, color)
		img.set_pixel(ICON_SIZE - 1, y, color)


func _fill_rect(img: Image, x0: int, y0: int, x1: int, y1: int, color: Color) -> void:
	for y in range(maxi(1, y0), mini(ICON_SIZE - 1, y1)):
		for x in range(maxi(1, x0), mini(ICON_SIZE - 1, x1)):
			img.set_pixel(x, y, color)


func _fill_polygon_circle(img: Image, center: Vector2, radius: float, color: Color) -> void:
	var r2 := radius * radius
	for y in range(maxi(1, int(center.y - radius)), mini(ICON_SIZE - 1, int(center.y + radius + 1))):
		for x in range(maxi(1, int(center.x - radius)), mini(ICON_SIZE - 1, int(center.x + radius + 1))):
			if Vector2(x, y).distance_squared_to(center) <= r2:
				img.set_pixel(x, y, color)


func _draw_line(img: Image, a: Vector2, b: Vector2, color: Color, thickness: int) -> void:
	var steps := int(a.distance_to(b) * 2.0) + 1
	for i in steps + 1:
		var p := a.lerp(b, float(i) / float(steps))
		_fill_rect(img, int(p.x - thickness * 0.5), int(p.y - thickness * 0.5), int(p.x + thickness * 0.5 + 1), int(p.y + thickness * 0.5 + 1), color)
