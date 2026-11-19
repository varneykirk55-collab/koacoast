extends SceneTree
## godot --headless --path . --script res://tools/verify_island_audio.gd
## Add -- --mix for a real-time Master bus capture with the selected audio driver.

const PLACES := {
	"summit": Vector2(48, -126),
	"valley": Vector2(70, 200),
	"beach": Vector2(-64, 631),
	"river": Vector2(19, 516),
	"waterfall": Vector2(527, 147),
	"pool": Vector2(509, 156),
}

var failures: Array[String] = []
var contacts: Array[Dictionary] = []
var audio: Node3D
var feet: Node
var player: CharacterBody3D
var island: Node3D
var peak := 0.0
var frames_mixed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var capture := AudioEffectCapture.new()
	var capture_mix := "--mix" in OS.get_cmdline_user_args()
	if capture_mix:
		capture.buffer_length = 2.5
		AudioServer.add_bus_effect(0, capture)
	island = load("res://scenes/KoaCoast.tscn").instantiate()
	root.add_child(island)
	await process_frame
	await process_frame
	audio = island.get_node("IslandAudio")
	feet = audio.get_node("KekoaFootsteps")
	player = island.get_node("Player")
	feet.foot_contact.connect(_contact)
	var kinds := {}
	for site: Dictionary in audio.sites:
		kinds[site.kind] = kinds.get(site.kind, 0) + 1
	_check(kinds.get("falls", 0) == 12 and kinds.get("impact", 0) == 12, "All waterfall pairs registered")
	_check(kinds.get("pool", 0) == 3, "Three pools registered")
	_check(kinds.get("stream", 0) > 0 and kinds.get("rapids", 0) > 0, "Rivers and rapids registered")
	print("WATER_SOURCES ", kinds)
	var max_update_us := 0
	var maximum_voices := 0
	for place: String in PLACES:
		_place(PLACES[place])
		var begin := Time.get_ticks_usec()
		audio._update_zone(player.global_position)
		audio._select_water(player.global_position)
		max_update_us = maxi(max_update_us, Time.get_ticks_usec() - begin)
		if capture_mix:
			await create_timer(1.45).timeout
			_read_mix(capture)
		else:
			for frame in 72:
				await process_frame
		var active: Array[String] = []
		for index: int in audio.assignments:
			if index >= 0:
				active.append(audio.sites[index].kind)
		maximum_voices = maxi(maximum_voices, active.size())
		var expected: Dictionary = {"summit": "wind", "valley": "canopy", "beach": "surf"}
		if expected.has(place):
			_check(float(audio.gains[expected[place]]) > 0.35, "%s zone ambience" % place)
		if place == "waterfall":
			_check("falls" in active and "impact" in active, "Fall and impact audible near base")
		if place == "pool":
			_check("pool" in active, "Pool loop audible")
		print("ZONE ", place, " canopy=", snappedf(audio.gains.canopy, 0.01), " wind=", snappedf(audio.gains.wind, 0.01),
			" surf=", snappedf(audio.gains.surf, 0.01), " water=", active)
	_check(maximum_voices <= audio.VOICE_LIMIT, "Water voice budget")
	print("AUDIO_MAX_ZONE_UPDATE_US ", max_update_us, " MAX_WATER_VOICES ", maximum_voices)
	if capture_mix:
		_place(PLACES.beach)
		player.get_node("CameraPivot").rotation.y = 0.0
		await create_timer(0.24).timeout
		contacts.clear()
		Input.action_press("move_forward")
		Input.action_press("sprint")
		await create_timer(1.25).timeout
		Input.action_release("sprint")
		Input.action_release("move_forward")
		_read_mix(capture)
		_check(not contacts.is_empty(), "Master capture includes live footfalls")
		_check(frames_mixed > 0 and peak > 0.001 and peak < 0.99, "Audible Master bus with clipping headroom")
		print("MASTER_PEAK ", linear_to_db(peak), " dBFS FRAMES ", frames_mixed)
	else:
		await _walk_surfaces()
	audio.stop_audio()
	# The Dummy driver still mixes on wall-clock time under fixed-fps tests.
	OS.delay_msec(80)
	for frame in 4:
		await process_frame
	island.free()
	await process_frame
	if capture_mix:
		AudioServer.remove_bus_effect(0, AudioServer.get_bus_effect_count(0) - 1)
	for failure: String in failures:
		push_error(failure)
	print("ISLAND_AUDIO ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)


func _walk_surfaces() -> void:
	# Select a walkable stretch of the real terrain for each material profile.
	var examples := {}
	for z in range(-668, 668, 5):
		for x in range(-880, 890, 5):
			var at := Vector2(x, z)
			var p := _ground(at)
			if not is_finite(p.y) or p.y < -0.4 or p.y > 170 or audio.terrain.data.get_normal(p).y < 0.89:
				continue
			var category := _surface(p)
			if examples.has(category):
				continue
			for yaw in [0.0, PI * 0.5, PI, -PI * 0.5]:
				var direction := Vector2(-sin(yaw), -cos(yaw))
				if _surface(_ground(at + direction)) == category and _surface(_ground(at + direction * 2.8)) == category:
					examples[category] = [at, yaw]
					break
		if examples.size() == 8:
			break

	for surface in ["grass", "leaves", "undergrowth", "soil", "rock", "sand", "mud", "water"]:
		_check(examples.has(surface), "Walkable %s sample" % surface)
		if not examples.has(surface):
			continue
		var example: Array = examples[surface]
		for sprinting in [false, true]:
			_place(example[0])
			player.get_node("CameraPivot").rotation.y = example[1]
			for frame in 12:
				await physics_frame
			contacts.clear()
			Input.action_press("move_forward")
			if sprinting:
				Input.action_press("sprint")
			for frame in (44 if sprinting else 112):
				await physics_frame
			Input.action_release("sprint")
			Input.action_release("move_forward")
			var found := false
			for contact: Dictionary in contacts:
				found = found or (contact.surface == surface and not contact.landing)
			_check(found, "%s step while %s" % [surface, "running" if sprinting else "walking"])
			print("STEP_TEST ", surface, " ", "run" if sprinting else "walk", " ", contacts.map(func(c): return c.surface))
	_place(PLACES.beach)
	for frame in 40:
		await physics_frame
	contacts.clear()
	for frame in 40:
		await physics_frame
	_check(contacts.is_empty(), "No idle contacts")
	Input.action_press("jump")
	await physics_frame
	await physics_frame
	Input.action_release("jump")
	for frame in 110:
		await physics_frame
	_check(contacts.size() == 1 and contacts[0].landing, "Jump produces one landing and no airborne steps")


func _read_mix(capture: AudioEffectCapture) -> void:
	var count := capture.get_frames_available()
	for frame in capture.get_buffer(count):
		peak = maxf(peak, maxf(absf(frame.x), absf(frame.y)))
	frames_mixed += count


func _surface(p: Vector3) -> String:
	if not is_finite(p.y):
		return ""
	var weights: Dictionary = feet.surface_mix(p)
	var keys := weights.keys()
	keys.sort_custom(func(a, b): return weights[a] > weights[b])
	return keys[0]


func _ground(at: Vector2) -> Vector3:
	var p := Vector3(at.x, 0.0, at.y)
	p.y = audio.terrain.data.get_height(p)
	return p


func _place(at: Vector2) -> void:
	player.global_position = _ground(at) + Vector3.UP * 0.14
	player.velocity = Vector3.ZERO
	player.get_node("CameraPivot").global_position = player.global_position + Vector3.UP * 1.55


func _contact(surface: String, landing: bool, _position: Vector3) -> void:
	_check(player.is_on_floor(), "Contact emitted while grounded")
	contacts.append({"surface": surface, "landing": landing})


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures.append(description)
