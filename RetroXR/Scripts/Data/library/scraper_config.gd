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
##
## From the crypto RNG, for the reason WebFileServer._gen_token already states
## about its own tokens: randi() is a SEEDED PRNG, so its stream is reproducible
## and a value drawn from it can be predicted rather than guessed. This PIN is
## the only thing standing between anyone on the same network and the player's
## ROM and save directories, and there are only 10000 of them — it should at
## least cost an attacker all 10000.
##
## Rejection sampling rather than a plain modulo: 2^32 is not a multiple of
## 10000, so the low 7296 values would come up fractionally more often than the
## rest. The loop discards the short tail instead, and retries with probability
## under one in half a million.
func ensure_web_server_pin() -> String:
	if web_server_pin.length() != 4 or not web_server_pin.is_valid_int():
		web_server_pin = "%04d" % _random_pin()
		save_config()
	return web_server_pin


func _random_pin() -> int:
	var crypto := Crypto.new()
	var limit := 4294967296 - (4294967296 % 10000)
	while true:
		var bytes := crypto.generate_random_bytes(4)
		var value := bytes.decode_u32(0)
		if value < limit:
			return value % 10000
	return 0


func load_config() -> void:
	# parse_dict, not read_dict: the two failures mean opposite things to a
	# config. A file that cannot be read at all -- missing, or damaged --
	# comes back null and leaves every field standing, while a file that
	# parses but is not an object comes back {} and falls through to the
	# defaults below. read_dict flattens both to {}, which would quietly
	# reset stored credentials on a corrupt file; ra_tests pins both.
	var raw: Variant = JsonStore.parse_dict(_config_path(), "ScraperConfig")
	if raw == null:
		return
	var data: Dictionary = raw
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


static func _config_path() -> String:
	return RomLibrary.default_roms_root().path_join("scraper_config.json")
