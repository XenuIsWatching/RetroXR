## ModManifest — one mod's mod.json, parsed and checked.
##
## Read out of the container by ModPackReader BEFORE anything is mounted, which
## is what lets a mod be a single file and still be inspectable while disabled.
##
## Every failure is a STRING on `error` rather than a push_error, because the
## Mods page has to show the player why a mod did not load. A mod that silently
## vanishes is the worst failure this system has.
class_name ModManifest
extends RefCounted

## Manifests declaring a higher version than this are refused.
##
## Deliberately a BREAK MARKER, not a compatibility promise. Nothing about the
## mod surface is frozen -- RetroSystemModel's virtuals will keep changing --
## so this is bumped whenever something a mod could depend on moves, and the
## refusal message names what moved. Loud and specific beats silent.
const API_VERSION := 1

## Where a mod's own files must live inside its container.
const NAMESPACE_ROOT := "res://mods/"

## Names a mod pack may never carry, whatever it claims. A mod exported from its
## own Godot project picks these up automatically, and either one would replace
## the running game's copy: the class cache decides what every `class_name` in
## the game resolves to.
const FORBIDDEN := [
	"res://project.binary",
	"res://project.godot",
	"res://.godot/global_script_class_cache.cfg",
	"res://.godot/uid_cache.bin",
]

var id: String = ""
var name: String = ""
var version: String = "0.0.0"
var author: String = ""
var description: String = ""
var entry: String = ""
var priority: int = 0
var api_version: int = 0
## Paths outside NAMESPACE_ROOT + id that this pack is allowed to write.
var claims: PackedStringArray = []
## OS names this mod runs on; empty means all of them.
var platforms: PackedStringArray = []

## Empty while the manifest is usable.
var error: String = ""


## Parse `data` (already read from the container) and check everything that can
## be checked without the file list. Never returns null.
static func parse(data: Dictionary) -> ModManifest:
	var m := ModManifest.new()
	m.id = str(data.get("id", "")).strip_edges()
	m.name = str(data.get("name", "")).strip_edges()
	m.version = str(data.get("version", "0.0.0")).strip_edges()
	m.author = str(data.get("author", "")).strip_edges()
	m.description = str(data.get("description", "")).strip_edges()
	m.entry = str(data.get("entry", "")).strip_edges()
	m.priority = int(data.get("priority", 0))
	m.api_version = int(data.get("api_version", 0))
	m.claims = _strings(data.get("claims", []))
	m.platforms = _strings(data.get("platforms", []))
	if m.name.is_empty():
		m.name = m.id
	m.error = m._validate()
	return m


static func _strings(value: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if value is Array:
		for v: Variant in (value as Array):
			out.append(str(v))
	return out


func _validate() -> String:
	if id.is_empty():
		return "no id"
	# The id becomes a res:// path segment and a save-file key, so it is held to
	# what can safely be both.
	if not RegEx.create_from_string("^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$").search(id):
		return "id '%s' is not lower-case alphanumeric with . _ -" % id
	if api_version <= 0:
		return "no api_version"
	if api_version > API_VERSION:
		return ("needs mod API %d, this build provides %d - the mod is newer than RetroXR"
			% [api_version, API_VERSION])
	if entry.is_empty():
		return "no entry script"
	if not entry.begins_with(own_root()):
		return "entry '%s' is outside %s" % [entry, own_root()]
	return ""


## Everything this mod ships must sit under here.
func own_root() -> String:
	return NAMESPACE_ROOT + id + "/"


## True when this mod should run on the current OS.
func runs_here() -> bool:
	return platforms.is_empty() or platforms.has(OS.get_name())


## Check the container's actual file list against the manifest. Returns "" when
## the pack may be mounted.
##
## This is the enforcement half of the security posture: a mod that claims
## nothing provably cannot touch a shipped path, because a pack containing one
## is refused outright rather than mounted with replace_files off. It is also
## what stops an author's SDK copy of vr_hinge.gd from replacing the real one.
func inventory_error(files: PackedStringArray) -> String:
	if files.is_empty():
		return "container is empty"
	var ns := own_root()
	var seen_own := false
	for path: String in files:
		if FORBIDDEN.has(path):
			return "carries %s, which would replace the running game's copy" % path
		if path.begins_with(ns):
			seen_own = true
			continue
		if path.begins_with(NAMESPACE_ROOT):
			# Another mod's namespace: it would silently shadow that mod.
			return "writes into another mod's namespace (%s)" % path
		if not claims.has(path):
			return "writes '%s' outside its namespace without claiming it" % path
	if not seen_own:
		return "nothing under %s - is the id wrong?" % ns
	return ""


## Which claims land on a path the base game already ships. Only these need the
## pack mounted with replace_files, and only these are worth warning about.
func shadowing_claims() -> PackedStringArray:
	var out := PackedStringArray()
	for path: String in claims:
		if ResourceLoader.exists(path):
			out.append(path)
	return out


## Claims that merely add a file the game does not have -- new system icon art,
## for instance. Declared for transparency, but harmless.
func adding_claims() -> PackedStringArray:
	var out := PackedStringArray()
	for path: String in claims:
		if not ResourceLoader.exists(path):
			out.append(path)
	return out
