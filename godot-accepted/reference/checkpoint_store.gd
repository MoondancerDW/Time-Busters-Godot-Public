class_name TbLocalCheckpointStore
extends RefCounted
## Own local progress format. Loading enters the level through the native GD constructor.

const FORMAT := "timebusters-local-progress"
const VERSION := 1
const LEGACY_BACKEND := "bbtime-465afda7976c1ff1c50a40e7560b0a0ccec14c03-local-research-r09-global-skip-link-after-template-closure-v1"
const R16_BACKEND := LEGACY_BACKEND + "-r16-state-derived-hang-v1"
const R20_BACKEND := R16_BACKEND + "-r20-preserve-stomp-through-hurt-vm-v1"
const R22_BACKEND := R20_BACKEND + "-r22-live-mutable-surfaces-v1"
const R25_BACKEND := R22_BACKEND + "-r25-recorded-camera-actor-paths-v1"
const R26_BACKEND := R25_BACKEND + "-r26-native-level-view-entry-v1"
const R27_BACKEND := R22_BACKEND + "-r27-zero-scaled-cylinder-v1"
const BACKEND := R26_BACKEND + "-r27-zero-scaled-cylinder-v1"
const PROGRESS_SCHEMA := "tb-gd768-level-entry-v1"
const AssetLayoutScript = preload("res://reference/asset_layout.gd")
const LOCAL_ROOT := AssetLayoutScript.DEVELOPER_SAVE_ROOT
const SAVE_NAMESPACE := "backend-r28-combined-v1"
const COMPATIBLE_NAMESPACES := ["backend-r27-cylinder-v1", "backend-r26-view-entry-v1", "backend-r25-paths-v1", "backend-r22-surfaces-v1", "backend-r20-stomp-v1", "backend-r16-state-v1", "backend-r09-skiplink-v1"]
const POLICY := "level_entry_with_persistent_game_data"
const AUTHORED_SAVE_REQUEST := 6
const NEW_SLOT_MODE := 2
const NUMBERED_SLOT_LIMIT := 9999
var save_directory: String = OS.get_environment("TIMEBUSTERS_SAVE_DIRECTORY")
var _save_root: String = AssetLayoutScript.save_root()
var _identity_paths: Dictionary = AssetLayoutScript.metadata_paths()

func _init() -> void:
	if save_directory.is_empty():
		save_directory = _save_root + "saves/" + SAVE_NAMESPACE

func _fail(message: String) -> Dictionary:
	return {"ok":false, "error":message}

func _digest(data: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(data)
	return context.finish().hex_encode()

func _read_json(path: String, limit: int) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > limit:
		return null
	return JSON.parse_string(file.get_as_text())

func _hex64(value: Variant) -> bool:
	if not value is String:
		return false
	var pattern := RegEx.new()
	pattern.compile("^[0-9a-f]{64}$")
	return pattern.search(value) != null

func _normalized_save_directory() -> String:
	var directory := save_directory.replace("\\", "/")
	if AssetLayoutScript.is_bundled() and directory.begins_with("user://"):
		directory = ProjectSettings.globalize_path(directory)
	return directory.simplify_path()

func _slot_path(slot: String) -> String:
	var pattern := RegEx.new()
	pattern.compile("^[a-zA-Z0-9_-]{1,40}$")
	var directory := _normalized_save_directory()
	if pattern.search(slot) == null or not (directory + "/").to_lower().begins_with(_save_root.to_lower()):
		return ""
	return directory.path_join(slot + ".json")

func _slot_directories(directory: String) -> Array[String]:
	var fork := directory.path_join(SAVE_NAMESPACE)
	var directories: Array[String] = [fork.path_join("safe-entry-v1"), fork, directory]
	if directory == _save_root + "saves/" + SAVE_NAMESPACE:
		for compatible_namespace: String in COMPATIBLE_NAMESPACES:
			directories.append((_save_root + "saves").path_join(compatible_namespace))
	return directories

func _read_path(slot: String) -> String:
	var path := _slot_path(slot)
	if path.is_empty():
		return path
	# Prefer a newer-runtime child without replacing an older source slot.
	for directory: String in _slot_directories(path.get_base_dir()):
		var candidate := directory.path_join(path.get_file())
		if FileAccess.file_exists(candidate):
			return candidate
	return path

func numbered_slot_index(slot: String) -> int:
	var digits := slot.trim_prefix("slot")
	if digits == slot or digits.length() > 4 or not digits.is_valid_int():
		return 0
	var index := int(digits)
	return index if index > 0 and index <= NUMBERED_SLOT_LIMIT and digits == str(index) else 0

func newest_numbered_slot() -> String:
	var path := _slot_path("slot1")
	if path.is_empty():
		return "slot1"
	var newest := "slot1"
	var newest_time := -1
	var newest_number := 0
	for directory: String in _slot_directories(path.get_base_dir()):
		if not DirAccess.dir_exists_absolute(directory):
			continue
		for filename: String in DirAccess.get_files_at(directory):
			if not filename.ends_with(".json"):
				continue
			var slot := filename.trim_suffix(".json")
			var number := numbered_slot_index(slot)
			if number == 0 or _read_path(slot) != directory.path_join(filename):
				continue
			var modified := FileAccess.get_modified_time(directory.path_join(filename))
			if modified > newest_time or (modified == newest_time and number > newest_number):
				newest = slot
				newest_time = modified
				newest_number = number
	return newest

func _slot_occupied(slot: String) -> bool:
	var path := _read_path(slot)
	return FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path)

func _schema_compatible(payload: Dictionary) -> bool:
	var backend: Variant = payload.get("backend")
	if backend not in [BACKEND, R27_BACKEND, R26_BACKEND, R25_BACKEND, R22_BACKEND, R20_BACKEND, R16_BACKEND, LEGACY_BACKEND]:
		return false
	var runtime_present: bool = payload.has("runtime_backend")
	var schema_present: bool = payload.has("progress_schema")
	if backend in [BACKEND, R27_BACKEND, R26_BACKEND, R25_BACKEND, R22_BACKEND, R20_BACKEND] or runtime_present or schema_present:
		return runtime_present and schema_present and payload.runtime_backend == backend and payload.progress_schema == PROGRESS_SCHEMA
	# Explicit old R09/R16 shape: both fields absent; all source/GD/seals are still checked.
	return true

const SAVE_SAFETY := "original-native-pause-entry-v2"
const LEGACY_SAVE_SAFETY := "original-native-pause-entry-v1"
const AUTHORED_SAVE_SAFETY := "original-native-authored-request-v1"

func save_eligibility(frame: Dictionary, authored_request: bool = false) -> Dictionary:
	var gd: Variant = frame.get("game_data")
	var state: Variant = frame.get("script_state")
	var session: Variant = frame.get("session")
	var message := "Сохранение доступно в игровой паузе: нажмите P, затем F5."
	if not frame.get("ok", false) or not gd is PackedByteArray or gd.size() != 0x300 or not state is PackedByteArray or state.size() != 0x400 or not session is Dictionary:
		return {"ok":false, "code":"no_native_frame", "error":"Нет полного состояния активной игры."}
	if not session.get("loaded", false) or not session.get("enabled", false) or session.get("phase", "") != "running" or session.get("transition_pending", false) or session.get("quit_requested", false) or frame.get("restart", false) or int(frame.get("next_level", -1)) >= 0:
		return {"ok":false, "code":"transition", "error":"Дождитесь окончания перехода; затем нажмите P и F5."}
	var camera: Variant = frame.get("camera")
	if not camera is Dictionary or typeof(camera.get("native_flags")) != TYPE_INT:
		return {"ok":false, "code":"camera_guard_unavailable", "error":"Для безопасного сохранения требуется обновлённый игровой модуль."}
	var camera_flags: int = int(camera.native_flags)
	if camera_flags < 0 or camera_flags > 0xffffffff:
		return {"ok":false, "code":"invalid_native_camera_flags", "error":"Неверное состояние игрового модуля; сохранение не записано."}
	if authored_request:
		if session.get("save_requested", 0) != AUTHORED_SAVE_REQUEST or state[0x29] != AUTHORED_SAVE_REQUEST:
			return {"ok":false, "code":"no_authored_request", "error":"Игра не запрашивала сохранение."}
		# The original host handles S29=6 before its pause and cinematic checks.
		return {"ok":true, "code":"eligible", "receipt":{
			"policy":AUTHORED_SAVE_SAFETY, "request":AUTHORED_SAVE_REQUEST, "file_choice":int(state[0x27]),
			"native_pause":int(state[9]), "native_control":int(state[0]), "cinematic":int(gd[0x9f]),
			"demo":int(gd[0x8a]), "native_state_bytes":0x400, "camera_flags":camera_flags,
		}}
	if not _original_camera_allowed(camera_flags):
		return {"ok":false, "code":"camera_hold", "error":"Дождитесь завершения сцены; затем нажмите P и F5."}
	if int(gd[0x9f]) != 0 or int(gd[0x8a]) != 0 or int(state[0]) != 0:
		return {"ok":false, "code":"transient", "error":"Дождитесь окончания сцены; затем нажмите P и F5."}
	if int(state[9]) != 1:
		return {"ok":false, "code":"native_pause_required", "error":message}
	return {"ok":true, "code":"eligible", "receipt":{"policy":SAVE_SAFETY, "native_pause":1, "native_control":0, "cinematic":0, "demo":0, "native_state_bytes":0x400, "camera_flags":camera_flags}}

func _original_camera_allowed(flags: int) -> bool:
	# Stock PC 0x40154d..0x40155b: hold bits block unless bit0 overrides them.
	return (flags & 0x300) == 0 or (flags & 1) != 0

func _receipt_base(payload: Dictionary, gd: PackedByteArray, policy: String) -> bool:
	var receipt: Variant = payload.get("save_safety")
	return receipt is Dictionary and receipt.get("policy") == policy and receipt.get("native_pause") == 1 and receipt.get("native_control") == 0 and receipt.get("cinematic") == 0 and receipt.get("demo") == 0 and gd.size() == 0x300 and gd[0x9f] == 0 and gd[0x8a] == 0

func _legacy_safety_receipt(payload: Dictionary, gd: PackedByteArray) -> bool:
	# Local R24 prototypes predated the missing-camera-gate finding. They are
	# readable but cannot count as certified complete original eligibility.
	return _receipt_base(payload, gd, LEGACY_SAVE_SAFETY)

func _native_integer(value: Variant, upper: int) -> bool:
	return typeof(value) in [TYPE_INT, TYPE_FLOAT] and float(value) == floor(float(value)) and value >= 0 and value <= upper

func _certified_safety(payload: Dictionary, gd: PackedByteArray) -> bool:
	var receipt: Variant = payload.get("save_safety")
	if not receipt is Dictionary or receipt.get("native_state_bytes") != 0x400 or not _hex64(receipt.get("native_module_sha256")):
		return false
	var flags: Variant = receipt.get("camera_flags")
	if not _native_integer(flags, 0xffffffff):
		return false
	if receipt.get("policy") == AUTHORED_SAVE_SAFETY:
		return (gd.size() == 0x300 and receipt.get("request") == AUTHORED_SAVE_REQUEST
			and _native_integer(receipt.get("file_choice"), 255) and _native_integer(receipt.get("native_pause"), 255)
			and _native_integer(receipt.get("native_control"), 255)
			and receipt.get("cinematic") == gd[0x9f] and receipt.get("demo") == gd[0x8a])
	return _receipt_base(payload, gd, SAVE_SAFETY) and _original_camera_allowed(int(flags))

func _is_current_file(path: String, root: String) -> bool:
	var envelope: Variant = _read_json(path, 65536)
	if not envelope is Dictionary or envelope.get("format") != FORMAT:
		return false
	var version: Variant = envelope.get("version")
	if typeof(version) not in [TYPE_FLOAT, TYPE_INT] or version != VERSION:
		return false
	var serialized: Variant = envelope.get("payload_json")
	if not serialized is String or not _hex64(envelope.get("payload_sha256")) or serialized.sha256_text() != envelope.payload_sha256:
		return false
	var payload: Variant = JSON.parse_string(serialized)
	if not payload is Dictionary or payload.get("backend") != BACKEND or not _schema_compatible(payload) or payload.get("policy") != POLICY:
		return false
	var encoded: Variant = payload.get("game_data_base64")
	if not encoded is String or encoded.length() != 1024:
		return false
	var gd: PackedByteArray = Marshalls.base64_to_raw(encoded)
	if gd.size() != 0x300 or not _hex64(payload.get("game_data_sha256")) or _digest(gd) != payload.game_data_sha256:
		return false
	if not _certified_safety(payload, gd):
		return false
	var language: Variant = payload.get("profile")
	var level: Variant = payload.get("level")
	if not language is String or language not in ["RU", "EN"] or not level is String:
		return false
	var identity := source_identity(root, language)
	if not identity.ok:
		return false
	for key: String in ["source_manifest_sha256", "profile_definition_sha256", "source_set_sha256"]:
		if payload.get(key, "") != identity.get(key, ""):
			return false
	return _hex64(payload.get("level_source_sha256")) and identity.container_hashes.get(level, "") == payload.level_source_sha256

func _write_path(slot: String, root: String) -> String:
	var path := _slot_path(slot)
	if path.is_empty():
		return path
	var fork := path.get_base_dir().path_join(SAVE_NAMESPACE).path_join(slot + ".json")
	var safe_fork := path.get_base_dir().path_join(SAVE_NAMESPACE).path_join("safe-entry-v1").path_join(slot + ".json")
	if FileAccess.file_exists(safe_fork):
		return safe_fork if _is_current_file(safe_fork, root) else ""
	if FileAccess.file_exists(fork):
		if _is_current_file(fork, root):
			return fork
		# A valid old current-backend child predates the safety receipt. Migrate
		# separately; damaged/foreign children never fall back or get replaced.
		var legacy := load_progress(root, slot)
		if legacy.get("ok", false) and legacy.get("path", "") == fork and legacy.payload.get("backend") == BACKEND and (not legacy.payload.has("save_safety") or _legacy_safety_receipt(legacy.payload, legacy.game_data)):
			return safe_fork
		return ""
	if not FileAccess.file_exists(path) or _is_current_file(path, root):
		return path
	return fork

func source_identity(root: String, language: String) -> Dictionary:
	if language not in ["RU", "EN"]:
		return _fail("Неизвестный профиль сохранения.")
	var catalog: Variant = _read_json(_identity_paths.catalog, 4 * 1024 * 1024)
	var baseline: Variant = _read_json(_identity_paths.baseline, 4 * 1024 * 1024)
	var profiles: Variant = _read_json(_identity_paths.profiles, 65536)
	if not catalog is Dictionary or not baseline is Array or not profiles is Dictionary:
		return _fail("Недоступны проверенные описания исходных ресурсов.")
	var manifest_hash := FileAccess.get_sha256(_identity_paths.baseline)
	var bundled_root := AssetLayoutScript.is_bundled_data_root(root)
	if catalog.get("source_manifest_sha256", "") != manifest_hash or (bundled_root and manifest_hash != AssetLayoutScript.BUNDLED_BASELINE_SHA256):
		return _fail("Контрольный список исходных ресурсов изменён.")
	if profiles.get("schema_version", 0) != 1 or not profiles.get("profiles", {}).has(language):
		return _fail("Описание профиля несовместимо с сохранением.")
	var extension: String = profiles.profiles[language].get("extension", "")
	if extension != (".bzr" if language == "RU" else ".bze"):
		return _fail("Профиль ссылается на другую версию ресурсов.")
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	var count: int = 0
	var total_bytes: int = 0
	var verified_files: int = 0
	var verified_bytes: int = 0
	var container_hashes: Dictionary = {}
	for item: Variant in baseline:
		if not item is Dictionary:
			return _fail("Повреждён контрольный список файлов.")
		var original: String = str(item.get("path", ""))
		if not original.begins_with("outputs/TimeBusters/"):
			continue
		var relative := original.trim_prefix("outputs/TimeBusters/")
		if relative.is_absolute_path() or ".." in relative.split("/") or "\\" in relative or ":" in relative:
			return _fail("Недопустимый путь в контрольном списке.")
		if relative.to_upper().begins_with("BZE/") and relative.get_extension().to_lower() != extension.trim_prefix("."):
			continue
		var length: int = int(item.get("bytes", -1))
		var expected: Variant = item.get("sha256")
		if length < 0 or not _hex64(expected):
			return _fail("Повреждена запись контрольного списка: " + relative)
		# The pinned bundle manifest keeps provenance rows in the historical save digest.
		if not bundled_root or relative.get_slice("/", 0) in AssetLayoutScript.RUNTIME_ASSET_DIRECTORIES:
			var path := root.path_join(relative)
			var file := FileAccess.open(path, FileAccess.READ)
			if file == null or file.get_length() != length:
				return _fail("Исходный файл отсутствует или изменён: " + relative)
			file.close()
			if FileAccess.get_sha256(path) != expected:
				return _fail("Не совпадает контрольная сумма: " + relative)
			verified_files += 1
			verified_bytes += length
		context.update((relative + "\t" + str(length) + "\t" + str(expected) + "\n").to_utf8_buffer())
		count += 1
		total_bytes += length
		if relative.to_upper().begins_with("BZE/"):
			container_hashes[relative.get_file().get_basename().to_upper()] = expected
	if container_hashes.size() != 58:
		return _fail("Не подтверждён полный набор из 58 ресурсов профиля.")
	return {"ok":true, "profile":language, "source_manifest_sha256":manifest_hash,
		"profile_definition_sha256":FileAccess.get_sha256(_identity_paths.profiles),
		"source_set_sha256":context.finish().hex_encode(), "files":count, "bytes":total_bytes,
		"verified_files":verified_files, "verified_bytes":verified_bytes, "container_hashes":container_hashes}

func save_progress(root: String, scene: Dictionary, frame: Dictionary, slot: String = "slot1", authored_request: bool = false, active_write: bool = false) -> Dictionary:
	var eligibility := save_eligibility(frame, authored_request)
	if not eligibility.ok:
		return eligibility
	if _slot_path(slot).is_empty() or (authored_request and numbered_slot_index(slot) == 0):
		return _fail("Целевой слот защищён или недопустим. Выберите отдельный локальный слот/папку; прежние файлы сохранены.")
	var gd: Variant = frame.get("game_data")
	if not scene.get("ok", false) or not frame.get("ok", false) or not gd is PackedByteArray or gd.size() != 0x300:
		return _fail("Нет полного состояния игры для сохранения.")
	var language: String = str(scene.get("language", ""))
	var level: String = str(scene.get("level", "")).to_upper()
	if frame.get("level", "") != scene.get("level", "") or frame.get("language", "") != language or frame.get("backend", "") != BACKEND:
		return _fail("Состояние и исходные ресурсы относятся к разным сессиям.")
	var identity := source_identity(root, language)
	if not identity.ok:
		return identity
	var source_hash: String = str(scene.get("source_sha256", ""))
	if not _hex64(source_hash) or identity.container_hashes.get(level, "") != source_hash:
		return _fail("Уровень не совпадает с проверенными исходными данными.")
	var receipt: Dictionary = eligibility.receipt.duplicate(true)
	var module_sha256 := FileAccess.get_sha256("res://bin/tb_reference.dll")
	if not _hex64(module_sha256):
		return _fail("Не удалось подтвердить игровой модуль; прежний слот сохранён.")
	receipt.native_module_sha256 = module_sha256
	var payload := {"profile":language, "level":level, "backend":BACKEND, "runtime_backend":BACKEND,
		"progress_schema":PROGRESS_SCHEMA, "policy":POLICY, "save_safety":receipt,
		"source_manifest_sha256":identity.source_manifest_sha256,
		"profile_definition_sha256":identity.profile_definition_sha256,
		"source_set_sha256":identity.source_set_sha256, "level_source_sha256":source_hash,
		"source_files_checked":identity.verified_files, "source_bytes_checked":identity.verified_bytes,
		"game_data_base64":Marshalls.raw_to_base64(gd), "game_data_sha256":_digest(gd),
		"saved_native_tick":int(frame.get("tick", 0)), "saved_at_utc":Time.get_datetime_string_from_system(true) + "Z"}
	return _write_progress(root, slot, payload, authored_request or active_write)

func _write_progress(root: String, slot: String, payload: Dictionary, allow_unused_slot: bool) -> Dictionary:
	var directory := _slot_path(slot).get_base_dir()
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		return _fail("Не удалось создать папку сохранений.")
	var new_slot: bool = payload.save_safety.policy == AUTHORED_SAVE_SAFETY and payload.save_safety.file_choice == NEW_SLOT_MODE
	if not new_slot:
		if _slot_occupied(slot):
			return _commit_progress(root, slot, payload)
		var result := _reserve_and_commit(root, slot, payload, false)
		if result.get("code") != "slot_reserved" or not allow_unused_slot or numbered_slot_index(slot) == 0:
			return result
		if _slot_occupied(slot):
			return _commit_progress(root, slot, payload)
		# An absent numbered slot may still be reserved by an interrupted first write.
		# Keep that reservation and allocate a different slot when no current file exists.
	for number: int in range(1, NUMBERED_SLOT_LIMIT + 1):
		var candidate := "slot%d" % number
		if _slot_occupied(candidate):
			continue
		var result := _reserve_and_commit(root, candidate, payload, true)
		if result.get("code") not in ["slot_reserved", "slot_occupied"]:
			return result
	return _fail("Свободные номера сохранений закончились.")

func _reserve_and_commit(root: String, slot: String, payload: Dictionary, new_slot: bool) -> Dictionary:
	# Coordinate new-slot allocation with the first ordinary write to the same slot.
	var reservation := _slot_path(slot) + ".write-reservation"
	if DirAccess.make_dir_absolute(reservation) != OK:
		if DirAccess.dir_exists_absolute(reservation):
			return {"ok":false, "code":"slot_reserved", "error":"Выбранный слот занят записью."}
		return _fail("Не удалось зарезервировать слот сохранения.")
	var result := _commit_progress(root, slot, payload, new_slot)
	DirAccess.remove_absolute(reservation)
	return result

func _commit_progress(root: String, slot: String, payload: Dictionary, new_slot: bool = false) -> Dictionary:
	if new_slot and _slot_occupied(slot):
		return {"ok":false, "code":"slot_occupied", "error":"Выбранный слот уже существует."}
	var path := _slot_path(slot) if new_slot else _write_path(slot, root)
	if path.is_empty():
		return _fail("Целевой слот защищён или недопустим. Выберите отдельный локальный слот/папку; прежние файлы сохранены.")
	# Hash exact serialized payload bytes: JSON numeric parsing cannot change this seal.
	var payload_json := JSON.stringify(payload, "", true)
	var envelope := {"format":FORMAT, "version":VERSION, "payload_json":payload_json,
		"payload_sha256":payload_json.sha256_text()}
	if DirAccess.make_dir_recursive_absolute(path.get_base_dir()) != OK:
		return _fail("Не удалось создать папку сохранений.")
	var temporary := "%s.%d-%d.tmp" % [path, OS.get_process_id(), Time.get_ticks_usec()]
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return _fail("Не удалось записать сохранение.")
	file.store_string(JSON.stringify(envelope, "\t", true) + "\n")
	file.flush()
	var error := file.get_error()
	file.close()
	if error == OK and new_slot and _slot_occupied(slot):
		DirAccess.remove_absolute(temporary)
		return {"ok":false, "code":"slot_occupied", "error":"Выбранный слот уже существует."}
	if error != OK or DirAccess.rename_absolute(temporary, path) != OK:
		DirAccess.remove_absolute(temporary)
		return _fail("Не удалось завершить запись сохранения; прежний слот сохранён.")
	return {"ok":true, "path":path, "slot":slot, "policy":POLICY, "payload":payload}

func load_progress(root: String, slot: String = "slot1") -> Dictionary:
	var path := _read_path(slot)
	if path.is_empty():
		return _fail("Недопустимая папка или имя сохранения.")
	var envelope: Variant = _read_json(path, 65536)
	if not envelope is Dictionary:
		if not FileAccess.file_exists(path) and slot == "slot1" and _normalized_save_directory() == _save_root + "saves/" + SAVE_NAMESPACE and FileAccess.file_exists(_save_root + "saves/slot1.json"):
			return _fail("Сохранение прежнего экспериментального ядра несовместимо. Старый файл сохранён отдельно без изменений; начните новую игру.")
		return _fail("Сохранение отсутствует или повреждено.")
	var version: Variant = envelope.get("version")
	if envelope.get("format", "") != FORMAT or typeof(version) not in [TYPE_FLOAT, TYPE_INT] or version != VERSION:
		return _fail("Неподдерживаемый формат или версия сохранения.")
	var payload_json: Variant = envelope.get("payload_json")
	if not payload_json is String or not _hex64(envelope.get("payload_sha256")) or payload_json.sha256_text() != envelope.payload_sha256:
		return _fail("Контрольная сумма сохранения не совпадает.")
	var payload: Variant = JSON.parse_string(payload_json)
	if not payload is Dictionary or payload.get("backend", "") not in [BACKEND, R27_BACKEND, R26_BACKEND, R25_BACKEND, R22_BACKEND, R20_BACKEND, R16_BACKEND, LEGACY_BACKEND] or payload.get("policy", "") != POLICY:
		return _fail("Сохранение относится к другому игровому ядру.")
	if not _schema_compatible(payload):
		return _fail("Схема сохранённого прогресса несовместима с текущим ядром.")
	var language: Variant = payload.get("profile")
	var level: Variant = payload.get("level")
	if not language is String or language not in ["RU", "EN"] or not level is String:
		return _fail("Неверный профиль или уровень сохранения.")
	var encoded: Variant = payload.get("game_data_base64")
	if not encoded is String or encoded.length() != 1024:
		return _fail("Неполное состояние игры в сохранении.")
	var gd := Marshalls.base64_to_raw(encoded)
	if gd.size() != 0x300 or not _hex64(payload.get("game_data_sha256")) or _digest(gd) != payload.game_data_sha256:
		return _fail("Повреждён блок игрового прогресса.")
	var identity := source_identity(root, language)
	if not identity.ok:
		return identity
	for key: String in ["source_manifest_sha256", "profile_definition_sha256", "source_set_sha256"]:
		if payload.get(key, "") != identity.get(key, ""):
			return _fail("Сохранение создано с другим набором исходных ресурсов: " + key)
	if not _hex64(payload.get("level_source_sha256")) or identity.container_hashes.get(level, "") != payload.level_source_sha256:
		return _fail("Профиль и ресурс уровня в сохранении не совпадают.")
	var legacy_receipt := _legacy_safety_receipt(payload, gd)
	var certified := _certified_safety(payload, gd)
	if payload.has("save_safety") and not certified and not legacy_receipt:
		return _fail("Повреждена отметка безопасного сохранения; исходный файл сохранён.")
	var transient: bool = gd[0x9f] != 0 or gd[0x8a] != 0
	var authored: bool = certified and payload.save_safety.policy == AUTHORED_SAVE_SAFETY
	var warning := "Снимок создан во время сцены; продолжение этой сцены не гарантировано. Другой проверенный слот можно открыть отдельно; исходный файл сохранён." if transient and not authored else ""
	if legacy_receipt and warning.is_empty():
		warning = "Сохранение создано ранней версией проверки паузы. Продолжение не гарантировано; исходный файл сохранён."
	var safety := {"legacy_receipt":legacy_receipt, "certified":certified, "transient_snapshot":transient, "warning":warning, "policy":AUTHORED_SAVE_SAFETY if authored else SAVE_SAFETY, "playable_resume_guaranteed":false}
	return {"ok":true, "path":path, "profile":language, "level":level, "game_data":gd,
		"expected_source_sha256":payload.level_source_sha256, "payload":payload, "resume_safety":safety,
		"compatibility":{"save_backend":payload.backend, "runtime_backend":BACKEND,
			"progress_schema":PROGRESS_SCHEMA, "lossless_game_data":true,
			"source_slot_sha256":FileAccess.get_sha256(path), "source_payload_sha256":envelope.payload_sha256,
			"legacy_shape":not payload.has("runtime_backend") and not payload.has("progress_schema")}}
