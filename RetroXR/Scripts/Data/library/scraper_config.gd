## ScraperConfig — stores screenscraper.fr credentials and preferences.
## Developer credentials are hardcoded; user credentials and priorities are persisted.
class_name ScraperConfig
extends RefCounted


## Developer credentials (hardcoded).
const DEV_ID := "XenuIsWatching"
const DEV_PASSWORD := "cRF2f81Fdgi"
const SOFT_NAME := "retroxr"

## User credentials (persisted).
var ssid: String = ""
var sspassword: String = ""

## Region priority for selecting localized content (first match wins).
## "wor" = worldwide (screenscraper's code for universal assets, e.g. English wheel logos).
var region_priorities: Array[String] = ["us", "eu", "wor", "jp", "ss"]

## Language priority for selecting localized text (first match wins).
var language_priorities: Array[String] = ["en", "fr"]

## Whether the web file server should auto-start on launch.
var web_server_enabled: bool = false

## 4-digit PIN required to log in to the web file server (persisted).
var web_server_pin: String = ""


## Returns the web-server PIN, generating & persisting a random 4-digit one if unset.
func ensure_web_server_pin() -> String:
	if web_server_pin.length() != 4 or not web_server_pin.is_valid_int():
		web_server_pin = "%04d" % (randi() % 10000)
		save_config()
	return web_server_pin


func load_config() -> void:
	var path := _config_path()
	if not FileAccess.file_exists(path):
		return

	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return

	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_warning("[ScraperConfig] JSON parse error: %s" % json.get_error_message())
		return

	var data: Dictionary = json.data if json.data is Dictionary else {}
	ssid = data.get("ssid", "")
	sspassword = data.get("sspassword", "")

	if data.has("region_priorities") and data["region_priorities"] is Array:
		region_priorities.clear()
		for r in data["region_priorities"]:
			region_priorities.append(str(r))

	if data.has("language_priorities") and data["language_priorities"] is Array:
		language_priorities.clear()
		for l in data["language_priorities"]:
			language_priorities.append(str(l))

	web_server_enabled = bool(data.get("web_server_enabled", false))
	web_server_pin = str(data.get("web_server_pin", ""))

	print("[ScraperConfig] Loaded config")


func save_config() -> bool:
	var path := _config_path()
	var dir_path := path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(dir_path)

	var data := {
		"ssid": ssid,
		"sspassword": sspassword,
		"region_priorities": region_priorities,
		"language_priorities": language_priorities,
		"web_server_enabled": web_server_enabled,
		"web_server_pin": web_server_pin,
	}
	return JsonStore.write_dict(path, data, "ScraperConfig")
	print("[ScraperConfig] Saved config")


static func _config_path() -> String:
	return RomLibrary.default_roms_root().path_join("scraper_config.json")
