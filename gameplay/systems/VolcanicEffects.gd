class_name VolcanicEffects
extends Node3D

var smoke: GPUParticles3D
var cinders: GPUParticles3D
var ash: GPUParticles3D
var rumbling: AudioStreamPlayer3D
var rockfall: AudioStreamPlayer3D
var mud_sound: AudioStreamPlayer3D
var flow_mesh := MeshInstance3D.new()
var flow_material := ShaderMaterial.new()
var camera: Camera3D
var shake := 0.0
var time := 0.0

func setup(vent: Vector3, island_audio: Node, body: Node3D) -> void:
	camera = body.get_node_or_null("CameraPivot/SpringArm3D/Camera3D") as Camera3D
	smoke = _particles(112, 15, Vector2(19, 19), Color(.24,.22,.23,.55))
	smoke.position = vent + Vector3.UP * 3
	var plume := smoke.process_material as ParticleProcessMaterial
	plume.direction = Vector3.UP
	plume.spread = 13
	plume.initial_velocity_min = 7
	plume.initial_velocity_max = 13
	plume.gravity = Vector3(.6, .08, .08)
	plume.scale_min = .32
	plume.scale_max = 1.5
	var expansion := Curve.new()
	expansion.add_point(Vector2(0,.35))
	expansion.add_point(Vector2(.4,1.1))
	expansion.add_point(Vector2(1,1.8))
	var ramp := CurveTexture.new()
	ramp.curve = expansion
	plume.scale_curve = ramp
	cinders = _particles(46, 2.5, Vector2(.42,.60), Color(1,.36,.055,.95))
	cinders.position = vent + Vector3.UP * 4
	var ejecta := cinders.process_material as ParticleProcessMaterial
	ejecta.direction = Vector3.UP
	ejecta.spread = 34
	ejecta.initial_velocity_min = 8
	ejecta.initial_velocity_max = 19
	ejecta.gravity = Vector3.DOWN * 13
	ash = _particles(115, 4, Vector2(.08,.09), Color(.46,.43,.41,.65))
	var fallout := ash.process_material as ParticleProcessMaterial
	fallout.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	fallout.emission_box_extents = Vector3(12,3,12)
	fallout.initial_velocity_min = 1
	fallout.initial_velocity_max = 2
	fallout.gravity = Vector3.DOWN * .55
	rumbling = _voice(island_audio, "thunder", 190, 1800)
	rockfall = _voice(island_audio, "rock_2", 48, 540)
	mud_sound = _voice(island_audio, "rapids", 22, 165, true)

func _voice(audio: Node, clip: String, unit: float, reach: float, loop := false) -> AudioStreamPlayer3D:
	var voice := AudioStreamPlayer3D.new()
	voice.bus = "Ambient"
	voice.unit_size = unit
	voice.max_distance = reach
	voice.max_db = -13
	voice.stream = audio.sound(clip, loop)
	add_child(voice)
	return voice

func rumble(source: Vector3, strength: float) -> void:
	rumbling.position = source
	rumbling.volume_db = lerpf(-32,-12,strength)
	rumbling.pitch_scale = lerpf(.90,.70,strength)
	rumbling.play()
	if strength > .38:
		rockfall.position = source + Vector3(9,-3,14)
		rockfall.volume_db = -18
		rockfall.pitch_scale = .72
		rockfall.play()

func _particles(count: int, lifetime: float, size: Vector2, color: Color) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.amount = count
	particles.lifetime = lifetime
	particles.fixed_fps = 20
	particles.local_coords = false
	particles.emitting = false
	particles.visibility_aabb = AABB(Vector3(-70,-30,-70), Vector3(200,280,180))
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var gradient := Gradient.new()
	var edge := color
	edge.a = 0
	gradient.offsets = PackedFloat32Array([0, .45, 1])
	gradient.colors = PackedColorArray([color, color, edge])
	var brush := GradientTexture2D.new()
	brush.gradient = gradient
	brush.fill = GradientTexture2D.FILL_RADIAL
	brush.fill_from = Vector2(.5,.5)
	brush.fill_to = Vector2(1,.5)
	brush.width = 32
	brush.height = 32
	var material := StandardMaterial3D.new()
	material.albedo_texture = brush
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.billboard_keep_scale = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var quad := QuadMesh.new()
	quad.size = size
	quad.material = material
	particles.draw_pass_1 = quad
	var motion := ParticleProcessMaterial.new()
	motion.gravity = Vector3.ZERO
	var fade := GradientTexture1D.new()
	fade.gradient = Gradient.new()
	fade.gradient.offsets = PackedFloat32Array([0,.15,.68,1])
	fade.gradient.colors = PackedColorArray([Color(1,1,1,0),Color.WHITE,Color.WHITE,Color(1,1,1,0)])
	motion.color_ramp = fade
	particles.process_material = motion
	material.vertex_color_use_as_albedo = true
	add_child(particles)
	return particles

func build_flow(path: Curve3D, terrain: Terrain3D) -> void:
	var mesh := SurfaceTool.new()
	mesh.begin(Mesh.PRIMITIVE_TRIANGLES)
	var length := path.get_baked_length()
	var segments := ceili(length / 2)
	var vertices := PackedVector3Array()
	for row in segments + 1:
		var pos := path.sample_baked(length * row / segments)
		var before := path.sample_baked(length * maxi(0,row-1) / segments)
		var after := path.sample_baked(length * mini(segments,row+1) / segments)
		var tangent := after - before
		var side := Vector3(-tangent.z,0,tangent.x).normalized()
		for column in 5:
			var point := pos + side * (column - 2) * 3.5
			point.y = terrain.data.get_height(point) + lerpf(.36,.10,absf(column-2)*.5)
			vertices.append(point)
	for row in segments:
		for col in 4:
			var i := row*5+col
			for index in [i,i+5,i+1,i+1,i+5,i+6]:
				mesh.set_uv(Vector2(float(index % 5)/4, floori(float(index)/5)*length/segments))
				mesh.add_vertex(vertices[index])
	mesh.generate_normals()
	flow_material.shader = preload("res://materials/VolcanicMud.gdshader")
	flow_mesh.mesh = mesh.commit()
	flow_mesh.material_override = flow_material
	flow_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	flow_mesh.hide()
	add_child(flow_mesh)

func present(activity: float, intensity: float, fallout: float, tremor: float, wind: Vector2, viewer: Vector3, flowing: bool, front: Vector3) -> void:
	var distance := viewer.distance_to(smoke.position)
	smoke.emitting = activity > .035 and distance < 3100
	smoke.amount_ratio = activity
	var plume := smoke.process_material as ParticleProcessMaterial
	plume.gravity = Vector3(wind.x * 2.1, .07, wind.y * 2.1)
	cinders.emitting = intensity > .22 and distance < 560
	cinders.amount_ratio = intensity
	ash.position = viewer + Vector3.UP * 3
	ash.emitting = fallout > .08
	ash.amount_ratio = fallout
	var fallout_motion := ash.process_material as ParticleProcessMaterial
	fallout_motion.direction = Vector3(wind.x * .75,-1,wind.y * .75).normalized()
	shake = tremor * (1.0 - smoothstep(30,720,distance))
	if flowing:
		mud_sound.position = front
		mud_sound.volume_db = -14
		if not mud_sound.playing:
			mud_sound.play()
	elif mud_sound.playing:
		mud_sound.stop()

func show_flow(visible_flow: bool, head: float, length: float) -> void:
	flow_mesh.visible = visible_flow
	if visible_flow:
		flow_material.set_shader_parameter("head", head)
		flow_material.set_shader_parameter("length", length)

func _process(delta: float) -> void:
	time += delta
	if is_instance_valid(camera):
		camera.h_offset = sin(time*18) * shake * .075
		camera.v_offset = cos(time*21) * shake * .047
