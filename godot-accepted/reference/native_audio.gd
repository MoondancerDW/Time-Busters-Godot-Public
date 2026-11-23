class_name TbNativeAudioOutput
extends Node
## Output-only owner. Physical finished callbacks never acknowledge the VM.
const MAX_KEYS := 1280 # Native blob<128, ten buffer copies; NOT model voice count24.
const CHUNK_FRAMES := 2048
const MAX_FEEDS_PER_RENDER := 8 # Same per-voice order/maximum as predecessor.
const MAX_LOOP_FEED_FRAMES_PER_FRAME := 131072
const MAX_LOOP_SERVICE_US_PER_FRAME := 2000
const MAX_LOOP_OUTPUT_RATE := 192000
var loop_buffer_seconds := 1.0
var _loop_budget_frame := -1
var _loop_budget_frames := 0
var _loop_budget_us := 0
var _loop_max_frame_service_us := 0
var _loop_budget_exhaustions := 0
const MAX_LOG := 128
var enabled := true
var music_volume_percent := 100
var _generation := -1
var _sequence := 0
var _voice_token := 0
var _voices: Dictionary = {}
var _host_hold := false
var _music_player: AudioStreamPlayer
var _music_playback: AudioStreamGeneratorPlayback
var _music_instance := -1
var _speech_player: AudioStreamPlayer
var _music_native_paused := false
var _errors: Array[String] = []
var _log: Array[Dictionary] = []
var _commands_consumed := 0
var _packets_consumed := 0
var _finished_stale := 0
var _finished_current := 0
var _sfx_PCM_bytes := 0
var _sfx_PCM_high_water := 0
var _music_pushed_frames := 0
var _loop_pushed_frames := 0
var _music_starts := 0
var _music_skips_completed := 0
var _loop_skips_completed := 0
var sfx_bus_name: String = SFX_BUS
const SFX_BUS := "TimeBusters SFX"
const MUSIC_BUS := "TimeBusters Music"
const SPEECH_BUS := "TimeBusters Speech"

func _ready() -> void:
	for bus_name: String in [SFX_BUS, MUSIC_BUS, SPEECH_BUS]:
		if AudioServer.get_bus_index(bus_name) < 0:
			AudioServer.add_bus()
			var index := AudioServer.bus_count - 1
			AudioServer.set_bus_name(index, bus_name)
			AudioServer.set_bus_send(index, "Master")
	_music_player = AudioStreamPlayer.new()
	_music_player.bus = MUSIC_BUS
	add_child(_music_player)

func bind_speech(player: AudioStreamPlayer) -> void:
	_speech_player = player
	player.bus = SPEECH_BUS
	set_music_volume_percent(music_volume_percent)

func set_music_volume_percent(percent: int) -> void:
	music_volume_percent = clampi(percent, 0, 100)
	var gain: float = float(music_volume_percent) / 100.0
	if is_instance_valid(_music_player):
		_music_player.volume_linear = gain
	if is_instance_valid(_speech_player):
		_speech_player.volume_linear = gain

func _note_error(message: String) -> void:
	if _errors.size() == MAX_LOG:
		_errors.pop_front()
	_errors.append(message)

func consume_packets(packets: Array) -> void:
	for packet: Dictionary in packets:
		var seq := int(packet.get("sequence", -1))
		if seq <= _sequence:
			_note_error("Duplicate/stale native audio packet %s after %s" % [seq, _sequence])
			continue
		if _sequence != 0 and seq != _sequence + 1:
			_note_error("Gap in inline audio delivery %s -> %s" % [_sequence, seq])
		_sequence = seq
		_packets_consumed += 1
		if packet.get("kind") == "reset":
			clear_sfx()
			_generation = int(packet.generation)
			enabled = bool(packet.get("enabled", enabled))
			continue
		if int(packet.get("generation", -1)) != _generation:
			_note_error("Native audio generation missing reset boundary")
			clear_sfx()
			continue
		for error: Variant in packet.get("errors", []):
			_note_error(str(error))
		for command: Dictionary in packet.get("commands", []):
			_commands_consumed += 1
			if _log.size() == MAX_LOG:
				_log.pop_front()
			_log.append({"sequence":seq,"generation":_generation,"tick":packet.get("tick"),
				"op":command.get("op"),"key":command.get("key"),"asset_id":command.get("asset_id", -1)})
			if enabled:
				_command(command)

func _drop_voice(key: int, from_finished: bool = false) -> void:
	if not _voices.has(key):
		return
	var voice: Dictionary = _voices[key]
	_voices.erase(key)
	if bool(voice.loop) and voice.playback != null:
		_loop_skips_completed += voice.playback.get_skips()
	_sfx_PCM_bytes -= int(voice.bytes)
	var player: AudioStreamPlayer = voice.player
	if is_instance_valid(player):
		player.stop()
		if from_finished:
			player.queue_free()
		else:
			remove_child(player)
			player.free()

func clear_sfx() -> void:
	for key: Variant in _voices.keys():
		_drop_voice(int(key))

func _command(c: Dictionary) -> void:
	var key := int(c.get("key", -1))
	if key < 0 or key >= MAX_KEYS:
		_note_error("Native sound key outside1280 domain")
		return
	var op := int(c.get("op", -1))
	if op in [1, 3, 4]: # Volume, Pause, Resume never restart/re-pan/re-rate an existing key.
		if not _voices.has(key):
			return
		var existing: Dictionary = _voices[key]
		if op == 1:
			existing.player.volume_linear = float(c.get("gain_linear", 0.0))
		else:
			existing.native_paused = op == 3
			existing.player.stream_paused = _host_hold or bool(existing.native_paused)
		return
	_drop_voice(key) # Native Play/Stop drop the old key even if the new buffer is empty/invalid.
	if op == 2 or c.get("empty_sound", false):
		return
	if op != 0:
		_note_error("Unknown native sound operation")
		return
	var pcm: PackedByteArray = c.get("pcm_s16le", PackedByteArray())
	var frames := int(c.get("frames", 0))
	var rate := int(c.get("rate", 0))
	if frames <= 0 or rate <= 0 or pcm.size() != frames * 4:
		_note_error("Invalid owned stereo PCM")
		return
	_voice_token += 1
	var player := AudioStreamPlayer.new()
	player.bus = sfx_bus_name
	player.volume_linear = float(c.get("gain_linear", 0.0)) # Already includes native config+positional attenuation.
	player.stream_paused = _host_hold
	player.pitch_scale = 1.0 # c.rate alone defines frequency; never apply it twice.
	add_child(player)
	var voice := {"player":player,"token":_voice_token,"generation":_generation,"native_paused":false,
		"bytes":pcm.size(),"loop":bool(c.get("loop", false)),"asset_id":c.get("asset_id", -1)}
	if voice.loop:
		var points: PackedVector2Array = c.get("loop_pcm_frames", PackedVector2Array())
		var begin := int(c.get("loop_begin", -1))
		var end := int(c.get("loop_end", -1))
		if rate > MAX_LOOP_OUTPUT_RATE:
			player.free()
			_note_error("Loop source rate exceeds explicit192000Hz presentation memory bound; not clamped")
			return
		if begin < 0 or end <= begin or end != frames or points.size() != frames:
			player.free()
			_note_error("Invalid half-open native loop region")
			return
		voice.bytes += points.size() * 8
		voice.points = points
		voice.cursor = 0
		voice.begin = begin
		voice.end = end
		player.stream = _generator(rate, loop_buffer_seconds)
		player.play()
		voice.playback = _retain_generator_playback(player)
	else:
		var wave := AudioStreamWAV.new()
		wave.format = AudioStreamWAV.FORMAT_16_BITS
		wave.mix_rate = rate
		wave.stereo = true
		wave.data = pcm
		wave.loop_mode = AudioStreamWAV.LOOP_DISABLED
		player.stream = wave
		player.finished.connect(_voice_finished.bind(_generation, key, _voice_token))
		player.play()
	_voices[key] = voice
	_sfx_PCM_bytes += int(voice.bytes)
	_sfx_PCM_high_water = maxi(_sfx_PCM_high_water, _sfx_PCM_bytes)
	if voice.loop:
		_feed_loop(voice) # Prefill immediately, not waiting for the next rendered frame.
	player.stream_paused = _host_hold

func _voice_finished(generation: int, key: int, token: int) -> void:
	if generation != _generation or not _voices.has(key) or int(_voices[key].token) != token:
		_finished_stale += 1
		return
	_finished_current += 1
	_drop_voice(key, true) # Presentation reclamation only; no bridge/VM acknowledgement.

func _generator(rate: int, buffer_seconds: float = 0.25) -> AudioStreamGenerator:
	var generator := AudioStreamGenerator.new()
	generator.mix_rate_mode = AudioStreamGenerator.MIX_RATE_CUSTOM
	generator.mix_rate = float(rate)
	generator.buffer_length = buffer_seconds
	return generator

func _retain_generator_playback(player: AudioStreamPlayer) -> AudioStreamGeneratorPlayback:
	var playback := player.get_stream_playback() as AudioStreamGeneratorPlayback
	if playback != null:
		# AudioServer can finish a queued fade after the player drops its stream.
		playback.set_meta(&"_tb_generator_stream", player.stream)
	return playback


func _renew_loop_budget() -> void:
	var frame := Engine.get_process_frames()
	if frame != _loop_budget_frame:
		_loop_max_frame_service_us = maxi(_loop_max_frame_service_us, _loop_budget_us)
		_loop_budget_frame = frame
		_loop_budget_frames = 0
		_loop_budget_us = 0

func _feed_loop(voice: Dictionary) -> void:
	var playback: AudioStreamGeneratorPlayback = voice.playback
	if playback == null or bool(voice.native_paused) or _host_hold:
		return
	_renew_loop_budget()
	var started := Time.get_ticks_usec()
	for _batch: int in range(MAX_FEEDS_PER_RENDER):
		if _loop_budget_frames >= MAX_LOOP_FEED_FRAMES_PER_FRAME or _loop_budget_us + Time.get_ticks_usec() - started >= MAX_LOOP_SERVICE_US_PER_FRAME:
			_loop_budget_exhaustions += 1
			break
		var count := mini(mini(playback.get_frames_available(), CHUNK_FRAMES), MAX_LOOP_FEED_FRAMES_PER_FRAME - _loop_budget_frames)
		if count <= 0:
			break
		var chunk := PackedVector2Array()
		while chunk.size() < count:
			# Push an exact partial chunk if the shared time budget expires; never skip cursor/sample positions.
			if not chunk.is_empty() and _loop_budget_us + Time.get_ticks_usec() - started >= MAX_LOOP_SERVICE_US_PER_FRAME:
				break
			if int(voice.cursor) >= int(voice.end):
				voice.cursor = int(voice.begin)
			var amount := mini(count - chunk.size(), int(voice.end) - int(voice.cursor))
			chunk.append_array(voice.points.slice(int(voice.cursor), int(voice.cursor) + amount))
			voice.cursor += amount
		if not playback.push_buffer(chunk):
			_note_error("SFX loop generator rejected bounded PCM")
			break
		_loop_pushed_frames += chunk.size()
		_loop_budget_frames += chunk.size()
	_loop_budget_us += Time.get_ticks_usec() - started
	_loop_max_frame_service_us = maxi(_loop_max_frame_service_us, _loop_budget_us)

func set_host_hold(hold: bool) -> void:
	_host_hold = hold
	for voice: Dictionary in _voices.values():
		voice.player.stream_paused = hold or bool(voice.native_paused)
	if is_instance_valid(_music_player):
		_music_player.stream_paused = hold or _music_native_paused

func _stop_music() -> void:
	if _music_playback != null:
		_music_skips_completed += _music_playback.get_skips()
	_music_player.stop()
	_music_player.stream = null
	_music_playback = null

func service_sfx() -> void:
	for voice: Dictionary in _voices.values():
		if bool(voice.loop):
			_feed_loop(voice)
func render_latest(bridge: RefCounted) -> void:
	service_sfx()
	var desired: Dictionary = bridge.call("reconcile_music_output")
	if not desired.get("ok", false):
		_note_error(str(desired.get("music_error", desired.get("resolution_error", "Music output failed"))))
	_music_native_paused = bool(desired.get("paused", false))
	var instance := int(desired.get("instance", -1))
	if instance != _music_instance:
		_stop_music()
		_music_instance = instance
		if desired.get("playing", false) and enabled:
			_music_player.stream = _generator(int(desired.get("sample_rate", 44100)))
			_music_player.stream_paused = _host_hold or _music_native_paused
			_music_player.play()
			_music_playback = _retain_generator_playback(_music_player)
			_music_starts += 1
	_music_native_paused = bool(desired.get("paused", false))
	_music_player.stream_paused = _host_hold or _music_native_paused
	if _music_playback == null or _host_hold or _music_native_paused:
		return
	for _batch: int in range(MAX_FEEDS_PER_RENDER):
		var count := mini(_music_playback.get_frames_available(), CHUNK_FRAMES)
		if count <= 0:
			break
		var result: Dictionary = bridge.call("pull_music_frames", count)
		if not result.get("ok", false):
			_note_error(str(result.get("error", "XA decode failed")))
			_stop_music()
			break
		var samples: PackedVector2Array = result.get("frames", PackedVector2Array())
		if samples.is_empty():
			break
		if not _music_playback.push_buffer(samples):
			_note_error("Music generator rejected bounded PCM")
			break
		_music_pushed_frames += samples.size()

func stop_all() -> void:
	_music_instance = -1
	clear_sfx()
	if is_instance_valid(_music_player):
		_stop_music()

func metrics() -> Dictionary:
	var loop_skips := 0
	var loops := 0
	for voice: Dictionary in _voices.values():
		if bool(voice.loop):
			loops += 1
			loop_skips += voice.playback.get_skips()
	return {"generation":_generation,"sequence":_sequence,"packets_consumed":_packets_consumed,
		"commands_consumed":_commands_consumed,"active_voice_keys":_voices.size(),"active_loops":loops,
		"retained_PCM_bytes":_sfx_PCM_bytes,"PCM_high_water":_sfx_PCM_high_water,"finished_current":_finished_current,
		"finished_stale_ignored":_finished_stale,"host_hold":_host_hold,"music_volume_percent":music_volume_percent,
		"music_instance":_music_instance,"music_starts":_music_starts,"music_pushed_frames":_music_pushed_frames,
		"music_generator_skips":_music_skips_completed + (_music_playback.get_skips() if _music_playback != null else 0),
		"loop_generator_skips":_loop_skips_completed + loop_skips,"loop_pushed_frames":_loop_pushed_frames,"errors":_errors.duplicate(),
		"recent_commands":_log.duplicate(true),"loop_normalization":"s16/32768; WAV uses32767; not float-bit parity",
		"presentation_version":"r29-loop-headroom-v1","loop_buffer_requested_seconds":loop_buffer_seconds,
		"loop_feed_frame_cap":MAX_LOOP_FEED_FRAMES_PER_FRAME,"loop_feed_time_budget_us":MAX_LOOP_SERVICE_US_PER_FRAME,
		"loop_feed_max_frame_us":_loop_max_frame_service_us,"loop_feed_budget_exhaustions":_loop_budget_exhaustions}

func _exit_tree() -> void:
	stop_all()
