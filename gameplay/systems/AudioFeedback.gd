class_name AudioFeedback
extends Node
## Lightweight procedural sound effects for gathering, pickups, crafting,
## building placement/removal, and doors. Does not alter environmental audio.

const SAMPLE_RATE := 22050

var _players: Array[AudioStreamPlayer] = []
var _spatial_players: Array[AudioStreamPlayer3D] = []
var _streams: Dictionary = {}


func _ready() -> void:
	for i in 4:
		var p := AudioStreamPlayer.new()
		p.volume_db = -8.0
		p.bus = "Effects"
		add_child(p)
		_players.append(p)
	for i in 6:
		var sp := AudioStreamPlayer3D.new()
		sp.bus = "Effects"
		sp.unit_size = 10.0
		sp.max_distance = 55.0
		sp.volume_db = -4.0
		add_child(sp)
		_spatial_players.append(sp)
	_build_streams()


func play(cue: StringName) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var stream := _streams.get(cue, null) as AudioStreamWAV
	if stream == null:
		return
	for p in _players:
		if not p.playing:
			p.stream = stream
			p.play()
			return
	_players[0].stream = stream
	_players[0].play()


func play_spatial(cue: StringName, world_pos: Vector3) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var stream := _streams.get(cue, null) as AudioStreamWAV
	if stream == null:
		return
	for sp in _spatial_players:
		if not sp.playing:
			sp.global_position = world_pos
			sp.stream = stream
			sp.play()
			return
	_spatial_players[0].global_position = world_pos
	_spatial_players[0].stream = stream
	_spatial_players[0].play()


func _build_streams() -> void:
	_streams[&"gather"] = _make_tone(190.0, 120.0, 0.11, 0.35, true)
	_streams[&"sparkle"] = _make_chime([880.0, 1174.66, 1567.98], 0.24)
	_streams[&"craft"] = _make_chime([440.0, 659.25], 0.20)
	_streams[&"build"] = _make_tone(150.0, 95.0, 0.13, 0.45, true)
	_streams[&"remove"] = _make_tone(240.0, 110.0, 0.12, 0.35, false)
	_streams[&"door"] = _make_tone(130.0, 180.0, 0.14, 0.30, false)
	_streams[&"error"] = _make_tone(140.0, 110.0, 0.14, 0.28, false)
	_streams[&"pig_grunt"] = _make_tone(105.0, 72.0, 0.22, 0.42, true)
	_streams[&"scratch"] = _make_tone(420.0, 260.0, 0.28, 0.32, true)
	_streams[&"wall_impact"] = _make_tone(95.0, 52.0, 0.18, 0.50, true)
	_streams[&"shark_splash"] = _make_tone(210.0, 85.0, 0.30, 0.45, true)


func _make_tone(f0: float, f1: float, duration: float, amp: float, noise_mix: bool) -> AudioStreamWAV:
	var count := int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(count * 2)
	var phase := 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = int(f0 * 17.0)
	for i in count:
		var t := float(i) / float(count)
		var freq := lerpf(f0, f1, t)
		phase += TAU * freq / float(SAMPLE_RATE)
		var env := (1.0 - t) * (1.0 - t)
		var s := sin(phase) * 0.75
		if noise_mix:
			s += rng.randf_range(-0.35, 0.35) * (1.0 - t)
		var val := clampi(int(s * env * amp * 32767.0), -32768, 32767)
		data.encode_s16(i * 2, val)
	return _wrap_wav(data)


func _make_chime(freqs: Array, duration: float) -> AudioStreamWAV:
	var count := int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(count * 2)
	for i in count:
		var t := float(i) / float(count)
		var env := exp(-t * 5.0) * minf(1.0, t * 25.0)
		var s := 0.0
		for k in freqs.size():
			var note_t := maxf(0.0, t - float(k) * 0.08)
			if note_t > 0.0 or k == 0:
				s += sin(TAU * float(freqs[k]) * (float(i) / float(SAMPLE_RATE))) * exp(-note_t * 6.0)
		s /= float(maxi(1, freqs.size()))
		var val := clampi(int(s * env * 0.55 * 32767.0), -32768, 32767)
		data.encode_s16(i * 2, val)
	return _wrap_wav(data)


func _wrap_wav(pcm16: PackedByteArray) -> AudioStreamWAV:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SAMPLE_RATE
	wav.stereo = false
	wav.data = pcm16
	return wav
