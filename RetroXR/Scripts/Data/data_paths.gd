## DataPaths — where the player's own files live, on each platform.
##
## The ROMs, books, videos, posters, music and mods the player supplies, plus
## the libretro tree the app fills in for them. One three-branch platform switch
## rather than the eleven that had grown: RomLibrary alone carried eight copies
## of it, differing only in the folder name on the end, and CoreDownloadManager
## and WebFileServer each had another.
##
## Copies of a platform switch do not drift evenly — they drift by OMISSION, and
## that is exactly what had happened. WebFileServer.server_root() had the Android
## branch and the Windows fallback and no Linux/macOS branch at all, so on those
## two it read an unset USERPROFILE and served "/retroxr": not the player's
## files, and not a directory that exists.
##
## The desktop root stays `~/retroxr` rather than following the app's rename. It
## holds the player's own ROM library, so moving it would strand every file they
## already put there.
class_name DataPaths
extends RefCounted

## The app's external files directory. Plain `adb push` reaches this one; it is
## deliberately NOT `user://`, which on Android is internal storage the shell
## cannot write. See CLAUDE.md on why pushing into the app's own tree is a trap.
const ANDROID_ROOT := "/sdcard/Android/data/com.xenu.retroxr/files"


## The player's data root, or a named folder inside it.
##
## `sub` is appended when given, so `media_root("roms")` and `media_root()` are
## the same call. Windows backslashes are folded to "/" because everything
## downstream — path_join, the file server's URLs, the RomM cache keys —
## assumes one separator.
static func media_root(sub: String = "") -> String:
	var root := ""
	if OS.get_name() == "Android":
		root = ANDROID_ROOT
	elif OS.get_name() in ["Linux", "macOS"]:
		root = OS.get_environment("HOME") + "/retroxr"
	else:
		root = OS.get_environment("USERPROFILE").replace("\\", "/") + "/retroxr"
	return root if sub.is_empty() else root + "/" + sub


## Root of the libretro tree — cores, system/, save/.
##
## Android is the one platform where this is NOT under media_root: cores live in
## INTERNAL storage (`user://`), a different filesystem from the ROMs on /sdcard,
## because the app must be able to write them and the shell must not. That is a
## deliberate split rather than an oversight, which is why it is stated here
## instead of being folded into media_root.
static func libretro_root() -> String:
	if OS.get_name() == "Android":
		return OS.get_user_data_dir() + "/libretro"
	return media_root("libretro")
