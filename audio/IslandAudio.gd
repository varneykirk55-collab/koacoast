extends Node3D
## Drives ambience from Kekoa's position and the surveyed watercourses.
## Separate buses keep ambience and movement available to a future mix or menu.

const WATERSHEDS := preload("res://freshwater/watersheds.json")
const SOUND_ROOT := "res://audio/sounds/"
const VOICE_LIMIT := 8
const SILENCE := -65.0
const WATER_TILE := 16.0

@onready var player: CharacterBody3D = $"../Player"
@onready var terrain: Terrain3D = $"../Terrain3D"

var sites: Array[Dictionary] = []
var coast: PackedVector3Array
var bed: Dictionary = {}
var voices: Array[AudioStreamPlayer3D] = []
var assignments: Array[int] = []
var gains: Dictionary = {}
var water_grid: Dictionary = {}
var streams: Dictionary = {}
var rng := RandomNumberGenerator.new()
var bird: AudioStreamPlayer3D
var surf: AudioStreamPlayer3D
var shore_distance := INF
var jungle := 0.0
var wildlife_time := 3.5
var survey_time := 0.0
var mix_channel := {"Ambient": 0.78, "Effects": 0.86}
var panel: PanelContainer
var old_mouse_mode: Input.MouseMode
var closing := false


func _ready() -> void:
	rng.randomize()
	_setup.call_deferred()


func _setup() -> void:
	_load_preferences()
	for kind in ["canopy", "insects", "wind"]:
		var track := AudioStreamPlayer.new()
		track.bus = "Ambient"
		track.stream = sound(kind, true)
		track.volume_db = SILENCE
		add_child(track)
		track.play(rng.randf_range(0.0, 4.0))
		bed[kind] = track
	surf = _positional(38.0, 260.0)
	surf.stream = sound("surf", true)
	bird = _positional(12.0, 115.0)
	for i in VOICE_LIMIT:
		voices.append(_positional(14.0, 220.0))
		assignments.append(-1)
	_survey_coast()
	_survey_water()
	var footsteps := Node.new()
	footsteps.set_script(preload("res://audio/KekoaFootsteps.gd"))
	footsteps.name = "KekoaFootsteps"
	add_child(footsteps)
	_build_settings()


func stop_audio() -> void:
	closing = true
	for track: AudioStreamPlayer in bed.values():
		track.stop()
	for track in voices:
		track.stop()
	if is_instance_valid(bird):
		bird.stop()
	if is_instance_valid(surf):
		surf.stop()
	var feet := get_node_or_null("KekoaFootsteps")
	if feet:
		feet.stop_audio()


func sound(name: String, looping := false) -> AudioStreamOggVorbis:
	if not streams.has(name):
		var clip := load(SOUND_ROOT + name + ".ogg") as AudioStreamOggVorbis
		clip.loop = looping
		streams[name] = clip
	return streams[name]


func _positional(reference: float, reach: float) -> AudioStreamPlayer3D:
	var track := AudioStreamPlayer3D.new()
	track.bus = "Ambient"
	track.unit_size = reference
	track.max_distance = reach
	track.volume_db = SILENCE
	track.max_db = -8.0
	add_child(track)
	return track


func _survey_coast() -> void:
	for z in range(-760, 704, 10):
		for x in range(-940, 964, 10):
			var p := Vector3(x, 0, z)
			var h := terrain.data.get_height(p)
			if h < -4.5 or h > 14.0 or not is_finite(h):
				continue
			for offset: Vector3 in [Vector3(10, 0, 0), Vector3(0, 0, 10)]:
				var nearby := terrain.data.get_height(p + offset)
				if not is_finite(nearby) or (h > 0.0) == (nearby > 0.0):
					continue
				coast.append(p + offset * clampf(h / (h - nearby), 0.0, 1.0))


func _survey_water() -> void:
	for watershed: Dictionary in WATERSHEDS.data:
		for channel: Dictionary in [watershed.river] + watershed.streams:
			var points: Array = channel.points
			var major: bool = channel.join == null
			for i in points.size():
				var p := _position(points[i])
				var width := clampf(sqrt(float(points[i][3])) * 0.016, 0.47, 2.45)
				if not major:
					width = minf(1.15, width)
				var key := _cell(p)
				if not water_grid.has(key):
					water_grid[key] = []
				water_grid[key].append(Vector4(p.x, p.y, p.z, width))
				if i % 8 == 0 and i + 1 < points.size():
					var ahead := _position(points[mini(i + 5, points.size() - 1)])
					var steep := p.y - ahead.y > 4.1
					_add_site("rapids" if steep else "stream", p, 78.0 if major else 52.0, -19.0 if major else -23.0)
			for fall: Array in channel.falls:
				var lip := _position(points[int(fall[0])])
				var foot := _position(points[int(fall[1])])
				var strength := smoothstep(3.0, 29.0, lip.y - foot.y)
				_add_site("falls", lip.lerp(foot, 0.62), lerpf(76.0, 190.0, strength), lerpf(-20.0, -11.0, strength))
				_add_site("impact", foot, lerpf(38.0, 92.0, strength), lerpf(-25.0, -17.0, strength))
			for pool: Array in channel.pools:
				var center := _position(points[(int(pool[0]) + int(pool[1])) / 2])
				_add_site("pool", center, 45.0, -23.0)
				water_grid[_cell(center)].append(Vector4(center.x, center.y, center.z, 2.8))


func _add_site(kind: String, p: Vector3, reach: float, volume: float) -> void:
	sites.append({"kind": kind, "position": p, "reach": reach, "volume": volume})


func _process(delta: float) -> void:
	if closing or bed.is_empty():
		return
	var p := player.global_position
	survey_time -= delta
	if survey_time <= 0.0:
		survey_time = 0.20
		_update_zone(p)
		_select_water(p)
	var ease := 1.0 - exp(-delta * 2.8)
	for kind: String in bed:
		_fade(bed[kind], gains.get(kind, 0.0), -20.0 if kind != "insects" else -29.0, ease)
	_fade(surf, gains.get("surf", 0.0), -13.0, ease)
	_update_voices(ease)
	wildlife_time -= delta
	if wildlife_time <= 0.0 and not bird.playing:
		_call_bird(p)


func _update_zone(p: Vector3) -> void:
	var nearest := Vector3(INF, INF, INF)
	var distance := INF
	for point in coast:
		var d := Vector2(point.x - p.x, point.z - p.z).length_squared()
		if d < distance:
			nearest = point
			distance = d
	shore_distance = sqrt(distance)
	var near_water := 1.0 - smoothstep(16.0, 205.0, shore_distance)
	var highland := smoothstep(85.0, 255.0, p.y)
	var grass := material_weight(terrain.data.get_texture_id(p), 2)
	jungle = (1.0 - highland) * smoothstep(7.0, 65.0, shore_distance) * lerpf(0.55, 1.0, grass)
	gains = {
		"canopy": jungle,
		"insects": jungle * 0.85,
		"wind": clampf(0.20 + highland * 0.72 + near_water * 0.52, 0.0, 1.0),
		"surf": near_water * (1.0 - highland),
	}
	if shore_distance < 250.0:
		if not surf.playing:
			surf.global_position = nearest
			surf.play(rng.randf_range(0.0, 5.0))
		else:
			surf.global_position = surf.global_position.lerp(nearest, 0.20)
	elif surf.volume_db <= -60.0:
		surf.stop()


func _select_water(p: Vector3) -> void:
	var best_by_kind := {}
	for i in sites.size():
		var site := sites[i]
		var weight := 1.0 - smoothstep(4.0, site.reach, p.distance_to(site.position))
		if weight < 0.015:
			continue
		var kind: String = site.kind
		var score := weight * db_to_linear(site.volume)
		if assignments.has(i):
			score *= 1.13
		if not best_by_kind.has(kind) or score > best_by_kind[kind].score:
			best_by_kind[kind] = {"index": i, "score": score, "weight": weight}
	for entry: Dictionary in best_by_kind.values():
		gains[entry.index] = entry.weight
		if assignments.has(entry.index):
			continue
		var slot := assignments.find(-1)
		if slot < 0:
			continue
		var site := sites[int(entry.index)]
		var source := voices[slot]
		source.stream = sound(site.kind, true)
		source.global_position = site.position
		source.unit_size = site.reach * 0.32
		source.max_distance = site.reach * 1.15
		source.volume_db = SILENCE
		source.pitch_scale = rng.randf_range(0.94, 1.06)
		source.play(rng.randf_range(0.0, 4.0))
		assignments[slot] = entry.index


func _update_voices(ease: float) -> void:
	for slot in assignments.size():
		var site := assignments[slot]
		if site < 0:
			continue
		var source := voices[slot]
		var weight: float = gains.get(site, 0.0)
		_fade(source, weight, sites[site].volume, ease)
		if weight == 0.0 and source.volume_db <= -60.0:
			source.stop()
			assignments[slot] = -1


func _fade(track: Node, weight: float, nominal: float, ease: float) -> void:
	var target := db_to_linear(nominal) * weight
	track.volume_db = maxf(SILENCE, linear_to_db(lerpf(db_to_linear(track.volume_db), target, ease)))


func _call_bird(p: Vector3) -> void:
	var coastal := shore_distance < 76.0 and p.y < 24.0
	var kind := "seabird" if coastal else ("forest_bird" if jungle > 0.38 and rng.randf() > 0.24 else "distant_bird")
	var angle := rng.randf_range(0.0, TAU)
	var radius := rng.randf_range(16.0, 33.0) if kind != "distant_bird" else rng.randf_range(34.0, 61.0)
	bird.global_position = p + Vector3(sin(angle) * radius, rng.randf_range(3.0, 12.0), cos(angle) * radius)
	bird.stream = sound(kind)
	bird.pitch_scale = rng.randf_range(0.85, 1.14)
	bird.volume_db = -16.0 if kind != "distant_bird" else -21.0
	bird.play()
	wildlife_time = rng.randf_range(5.0, 18.0) if jungle > 0.38 or coastal else rng.randf_range(21.0, 42.0)


func water_depth(p: Vector3) -> float:
	var depth := maxf(0.0, -p.y) if p.y < 0.0 else 0.0
	var key := _cell(p)
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			for point: Vector4 in water_grid.get(key + Vector2i(dx, dz), []):
				var difference := point.y - p.y
				if difference > depth and difference < 1.8 and Vector2(point.x - p.x, point.z - p.z).length_squared() <= point.w * point.w + 1.21:
					depth = difference
	return depth


func material_weight(texture: Vector3, material: int) -> float:
	return (1.0 - texture.z if int(texture.x) == material else 0.0) + (texture.z if int(texture.y) == material else 0.0)


func _cell(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / WATER_TILE), floori(p.z / WATER_TILE))


func _position(row: Array) -> Vector3:
	return Vector3(row[0], row[2], row[1])


func _load_preferences() -> void:
	var settings := ConfigFile.new()
	settings.load("user://island_audio.cfg")
	for key: String in mix_channel:
		_change_level(clampf(float(settings.get_value("audio", key, mix_channel[key])), 0.0, 1.0), key, false)


func _change_level(value: float, bus: String, persist := true) -> void:
	mix_channel[bus] = value
	var index := AudioServer.get_bus_index(bus)
	AudioServer.set_bus_mute(index, value <= 0.001)
	AudioServer.set_bus_volume_db(index, linear_to_db(maxf(value, 0.001)))
	if persist:
		var settings := ConfigFile.new()
		for key: String in mix_channel:
			settings.set_value("audio", key, mix_channel[key])
		settings.save("user://island_audio.cfg")


func _build_settings() -> void:
	var overlay := CanvasLayer.new()
	add_child(overlay)
	panel = PanelContainer.new()
	panel.position = Vector2(18, 64)
	panel.custom_minimum_size.x = 260
	panel.hide()
	overlay.add_child(panel)
	var rows := VBoxContainer.new()
	panel.add_child(rows)
	for bus: String in mix_channel:
		var label := Label.new()
		label.text = bus + " volume"
		rows.add_child(label)
		var slider := HSlider.new()
		slider.max_value = 1.0
		slider.step = 0.01
		slider.value = mix_channel[bus]
		slider.value_changed.connect(_change_level.bind(bus))
		rows.add_child(slider)
	var hint := Label.new()
	hint.text = "F7 or Esc to close"
	rows.add_child(hint)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		stop_audio()


func _input(event: InputEvent) -> void:
	if not panel or not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.keycode == KEY_F7 or (event.keycode == KEY_ESCAPE and panel.visible):
		if panel.visible:
			panel.hide()
			Input.mouse_mode = old_mouse_mode
		else:
			old_mouse_mode = Input.mouse_mode
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			panel.show()
		get_viewport().set_input_as_handled()
