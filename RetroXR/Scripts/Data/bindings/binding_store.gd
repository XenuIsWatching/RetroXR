## BindingStore — the storage half every control-binding store shares.
##
## ControllerBindings (VR controllers) and GamepadBindings (a real pad) keep
## different maps and save them under different rules, but they answer the same
## three questions about overrides, and both had their own copy of the answer.
##
## The rules, in one place because they are what the pages depend on:
##
##   * a platform with no profile is indistinguishable from global — get_for_system
##     falls through to the global layer, so there is nothing to store for it;
##   * a profile shadows global COMPLETELY, including global edits made after it,
##     which is why each store writes a profile whole rather than field by field;
##   * clearing one puts that platform back on global and touches nobody else's.
##
## The stored shape is {"global": {...}, "per_system": {systemid: {...}}}, where
## each {...} holds a store's own named layers — buttons, sticks, and whatever
## else that hardware has. What those layers ARE stays with each store: this file
## never names one.
##
## Saving is deliberately NOT here. ControllerBindings carries six layers and has
## to preserve the three Wii ones a caller did not supply — a rule that exists
## because dropping them silently reset a stored Nunchuk map whenever anything
## else on that platform was bound. GamepadBindings has two and replaces both
## outright. Folding those into one policy would put a real bug back.
class_name BindingStore
extends RefCounted


## Read the whole store. `owner` is the class name used in a warning, so a
## complaint in the log says which store could not be read.
static func load_file(path: String, owner: String) -> Dictionary:
	return JsonStore.read_dict(path, owner)


static func save_file(path: String, owner: String, data: Dictionary) -> void:
	JsonStore.write_dict(path, data, owner)


## The two override layers for a platform: [global, per-system]. The per-system
## half is empty for the global page and for a platform carrying no profile,
## which is the same thing as far as the merge is concerned.
static func layers(path: String, owner: String, systemid: String) -> Array[Dictionary]:
	var data := load_file(path, owner)
	var global_data: Dictionary = data.get("global", {}) as Dictionary
	var sys_data: Dictionary = {}
	if not systemid.is_empty():
		var per_sys: Dictionary = data.get("per_system", {}) as Dictionary
		sys_data = per_sys.get(systemid, {}) as Dictionary
	return [global_data, sys_data]


## Apply base, then the global overlay, then the per-system one. Returns a new
## dictionary; last writer wins.
static func merge(base: Dictionary, overlay1: Dictionary, overlay2: Dictionary) -> Dictionary:
	var result := base.duplicate()
	for k: String in overlay1:
		result[k] = overlay1[k]
	for k: String in overlay2:
		result[k] = overlay2[k]
	return result


## True when this platform carries a profile of its own rather than falling back
## to global. The presence of the profile IS the override switch — there is no
## separate flag, so clearing the profile is what turns the override off.
static func has_system_override(path: String, owner: String, systemid: String) -> bool:
	if systemid.is_empty():
		return false
	var per_sys: Dictionary = load_file(path, owner).get("per_system", {}) as Dictionary
	return per_sys.has(systemid)


## Drop a platform's profile so it falls back to global again. Other platforms'
## profiles are left standing.
static func clear_system_override(path: String, owner: String, systemid: String) -> void:
	if systemid.is_empty():
		return
	var data := load_file(path, owner)
	var per_sys: Dictionary = data.get("per_system", {}) as Dictionary
	if not per_sys.has(systemid):
		return
	per_sys.erase(systemid)
	data["per_system"] = per_sys
	save_file(path, owner, data)


## Every systemid carrying a profile, for the per-platform tile badges.
static func overridden_systems(path: String, owner: String) -> Array[String]:
	var out: Array[String] = []
	var per_sys: Dictionary = load_file(path, owner).get("per_system", {}) as Dictionary
	for sid: String in per_sys:
		out.append(sid)
	return out
