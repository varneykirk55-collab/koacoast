class_name GameDatabase
extends RefCounted
## Central registry of items, crafting recipes, building materials/pieces,
## collectibles, and procedurally generated item icons.

const ICON_SIZE := 48

var items: Dictionary = {}
var recipes: Array[RecipeDef] = []
var recipes_by_id: Dictionary = {}
var building_materials: Dictionary = {}
var building_pieces: Dictionary = {}
var building_piece_order: Array[StringName] = []
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
		[&"wood", "Wood", "Sturdy island timber gathered from koa trees and fallen branches.", &"resource", 99, Color(0.58, 0.38, 0.21), &"wood", &"", &"", 0],
		[&"stone", "Stone", "Dense volcanic basalt gathered from coastal boulders and rocky outcrops.", &"resource", 99, Color(0.47, 0.50, 0.54), &"stone", &"", &"", 0],
		[&"plant_fiber", "Plant Fiber", "Tough fibrous strands stripped from coastal sedge and valley grasses.", &"resource", 99, Color(0.54, 0.69, 0.32), &"fiber", &"", &"", 0],
		[&"leaves", "Leaves", "Broad tropical fronds and palm leaves useful for roofing and shelter.", &"resource", 99, Color(0.24, 0.62, 0.28), &"leaf", &"", &"", 0],
		[&"shark_tooth", "Shark Tooth", "A serrated tiger shark tooth found sparkling along black-sand beaches. Future material for a traditional leiomano.", &"collectible", 99, Color(0.92, 0.89, 0.80), &"tooth", &"", &"", 0],
		[&"stone_gathering_tool", "Stone Gathering Tool", "Lashed basalt pick for breaking boulders. Increases Stone gained when harvesting rocks.", &"tool", 1, Color(0.60, 0.64, 0.68), &"pick", &"", &"stone", 2],
		[&"wood_gathering_tool", "Wood Gathering Tool", "Heavy stone hatchet lashed to a koa handle. Increases Wood gained from trees and branches.", &"tool", 1, Color(0.68, 0.45, 0.25), &"axe", &"", &"wood", 2],
		[&"wood_foundation", "Wooden Foundation", "Elevated timber platform with support pilings for level building on slopes, valleys, or beaches.", &"building", 50, Color(0.64, 0.44, 0.24), &"foundation", &"foundation", &"", 0],
		[&"wood_floor", "Wooden Floor", "Timber deck slab for upper stories or bridged walkways.", &"building", 50, Color(0.72, 0.52, 0.30), &"floor", &"floor", &"", 0],
		[&"wood_wall", "Wooden Wall", "Full-height timber wall panel that snaps to foundation and floor edges.", &"building", 50, Color(0.61, 0.41, 0.22), &"wall", &"wall", &"", 0],
		[&"wood_doorway", "Wooden Doorway", "Framed timber wall with a central opening sized for a hinged door.", &"building", 50, Color(0.66, 0.46, 0.26), &"doorway", &"doorway", &"", 0],
		[&"wood_door", "Wooden Door", "Hinged plank door that snaps into doorways and opens with Interact.", &"building", 50, Color(0.52, 0.33, 0.18), &"door", &"door", &"", 0],
		[&"wood_roof", "Wooden Roof", "Sloped timber roof section that caps walls and upper floors.", &"building", 50, Color(0.50, 0.34, 0.19), &"roof", &"roof", &"", 0],
		[&"wood_stairs", "Wooden Stairs", "Timber staircase for climbing between terrain, foundations, and upper floors.", &"building", 50, Color(0.68, 0.48, 0.27), &"stairs", &"stairs", &"", 0],
	]
	for r: Array in rows:
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
		items[item.id] = item


func _register_recipes() -> void:
	var rows := [
		[&"craft_stone_tool", "Stone Gathering Tool", &"stone_gathering_tool", 1, &"hand", [{ "item_id": &"wood", "amount": 2 }, { "item_id": &"stone", "amount": 2 }, { "item_id": &"plant_fiber", "amount": 2 }]],
		[&"craft_wood_tool", "Wood Gathering Tool", &"wood_gathering_tool", 1, &"hand", [{ "item_id": &"wood", "amount": 2 }, { "item_id": &"stone", "amount": 3 }, { "item_id": &"plant_fiber", "amount": 2 }]],
		[&"craft_foundation", "Wooden Foundation", &"wood_foundation", 1, &"hand", [{ "item_id": &"wood", "amount": 4 }, { "item_id": &"plant_fiber", "amount": 2 }]],
		[&"craft_floor", "Wooden Floor", &"wood_floor", 1, &"hand", [{ "item_id": &"wood", "amount": 3 }, { "item_id": &"plant_fiber", "amount": 1 }]],
		[&"craft_wall", "Wooden Wall", &"wood_wall", 1, &"hand", [{ "item_id": &"wood", "amount": 3 }, { "item_id": &"leaves", "amount": 2 }]],
		[&"craft_doorway", "Wooden Doorway", &"wood_doorway", 1, &"hand", [{ "item_id": &"wood", "amount": 3 }, { "item_id": &"plant_fiber", "amount": 1 }]],
		[&"craft_door", "Wooden Door", &"wood_door", 1, &"hand", [{ "item_id": &"wood", "amount": 2 }, { "item_id": &"plant_fiber", "amount": 2 }]],
		[&"craft_roof", "Wooden Roof", &"wood_roof", 1, &"hand", [{ "item_id": &"wood", "amount": 3 }, { "item_id": &"leaves", "amount": 3 }]],
		[&"craft_stairs", "Wooden Stairs", &"wood_stairs", 1, &"hand", [{ "item_id": &"wood", "amount": 4 }, { "item_id": &"plant_fiber", "amount": 2 }]],
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
	var wood := BuildingMaterialDef.new()
	wood.id = &"wood"
	wood.display_name = "Wood"
	wood.albedo_color = Color(0.56, 0.37, 0.21)
	wood.accent_color = Color(0.37, 0.23, 0.12)
	wood.roughness = 0.85
	building_materials[wood.id] = wood


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
