extends RefCounted

const BUNDLE_ROOT := "res://bundled"
const BUNDLED_BASELINE_SHA256 := "6087c446e8c458fee544341bcc9f3b583d0608f1dfc7fd67f43a331a7f3d701a"
const RUNTIME_ASSET_DIRECTORIES := ["BZE", "data", "SPEECH", "TRACK"]
const DEVELOPER_DATA_ROOT := "D:/TimeBusters/TimeBusters-Codex-Transfer/outputs/TimeBusters"
const DEVELOPER_SAVE_ROOT := "D:/TimeBusters/port/.local/"

static func is_bundled() -> bool:
	return ProjectSettings.get_setting("time_busters/bundled_assets", false) == true

static func default_data_root() -> String:
	if is_bundled():
		# The native backend opens level and audio files through the OS filesystem.
		return ProjectSettings.globalize_path(BUNDLE_ROOT.path_join("TimeBusters"))
	return DEVELOPER_DATA_ROOT

static func is_bundled_data_root(root: String) -> bool:
	return is_bundled() and root.replace("\\", "/").simplify_path().trim_suffix("/") == default_data_root().replace("\\", "/").simplify_path().trim_suffix("/")

static func metadata_paths() -> Dictionary:
	if is_bundled():
		var metadata := BUNDLE_ROOT.path_join("metadata")
		return {
			"baseline":metadata.path_join("MANIFEST_SHA256.json"),
			"catalog":metadata.path_join("resource_manifest.json"),
			"profiles":metadata.path_join("profiles.json"),
		}
	return {
		"baseline":"D:/TimeBusters/TimeBusters-Codex-Transfer/MANIFEST_SHA256.json",
		"catalog":"D:/TimeBusters/port/reports/P00/resource_manifest.json",
		"profiles":"D:/TimeBusters/port/config/data-profiles/profiles.json",
	}

static func save_root() -> String:
	if is_bundled():
		var absolute := ProjectSettings.globalize_path("user://").replace("\\", "/").simplify_path()
		return absolute.trim_suffix("/") + "/"
	return DEVELOPER_SAVE_ROOT
