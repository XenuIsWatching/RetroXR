## RaConfig — RetroAchievements sign-in and preferences.
##
## Lives beside romm_config.json and scraper_config.json in the roms root so it
## survives an app reinstall on Android and is visible through the web file
## manager. That directory is world-readable, which is exactly why there is no
## password field: a password sign-in trades the password for a connect token
## and the token is all that is ever written. A leaked token can be revoked from
## the RetroAchievements control panel; a leaked password cannot.
class_name RaConfig
extends RefCounted


## Sign-in methods. PASSWORD is the primary path — it calls
## rc_client_begin_login_with_password and stores the token that comes back.
## TOKEN is for a player who already has one (RetroArch caches it as
## `cheevos_token`). Note this is NOT the Web API key from the website's control
## panel: that is a different, longer value used for read-only queries against
## retroachievements.org/API/, and it will not authenticate an unlock.
const AUTH_PASSWORD := "password"
const AUTH_TOKEN := "token"

var enabled: bool = false
var auth_mode: String = AUTH_PASSWORD
var username: String = ""

## The connect token, obtained by signing in. Written; the password is not.
var token: String = ""

## Show a toast on the cabinet when an achievement unlocks.
var show_notifications: bool = true

## Send the game's rich presence string with the session ping, so the player's
## RetroAchievements profile shows what they are doing.
var rich_presence: bool = true


## True when there is enough to attempt a sign-in. Both modes need a username;
## only the token mode can act without one more round trip.
func is_configured() -> bool:
	if not enabled or username.is_empty():
		return false
	return not token.is_empty()


func load_config() -> void:
	# parse_dict, not read_dict: the two failures mean opposite things to a
	# config. A file that cannot be read at all -- missing, or damaged --
	# comes back null and leaves every field standing, while a file that
	# parses but is not an object comes back {} and falls through to the
	# defaults below. read_dict flattens both to {}, which would quietly
	# reset stored credentials on a corrupt file; ra_tests pins both.
	var raw: Variant = JsonStore.parse_dict(config_path(), "RaConfig")
	if raw == null:
		return
	var data: Dictionary = raw
	enabled = bool(data.get("enabled", false))
	auth_mode = str(data.get("auth_mode", AUTH_PASSWORD))
	if auth_mode != AUTH_PASSWORD and auth_mode != AUTH_TOKEN:
		auth_mode = AUTH_PASSWORD
	username = str(data.get("username", ""))
	token = str(data.get("token", ""))
	show_notifications = bool(data.get("show_notifications", true))
	rich_presence = bool(data.get("rich_presence", true))

	print("[RaConfig] Loaded (user=%s enabled=%s)" % [username, enabled])


func save_config() -> bool:
	var path := config_path()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())

	# No password key, deliberately. See the class comment.
	var data := {
		"enabled": enabled,
		"auth_mode": auth_mode,
		"username": username,
		"token": token,
		"show_notifications": show_notifications,
		"rich_presence": rich_presence,
	}
	return JsonStore.write_dict(path, data, "RaConfig")


static func config_path() -> String:
	return RomLibrary.default_roms_root().path_join("ra_config.json")
