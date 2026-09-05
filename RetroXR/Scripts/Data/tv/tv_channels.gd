## TVChannels — the set's channel list, read from a user-editable channels.json.
##
## The file lives in RomLibrary.default_tv_root() and names *sources*, not
## channels: a "stream" source is one channel (a URL you typed), while an
## "hdhomerun" source stands for a whole tuner and expands to its full lineup at
## runtime via HDHomeRun.discover(). Resolving the tuner is asynchronous and
## belongs to the caller — this class only parses, holds and saves.
##
## A resolved channel is a Dictionary:
##   { "number": String, "name": String, "url": String,
##     "source": String, "hd": bool }
##
## `number` is free text ("4.1", "42", "") because a broadcast sub-channel is not
## an integer and a hand-written entry may have no number at all.
class_name TVChannels
extends RefCounted

const FILE_NAME := "channels.json"

## Parse outcome, so the TV can tell "you have no channel list" (show a hint)
## from "your channel list is broken" (show the parser's complaint).
enum Status { OK, MISSING, PARSE_ERROR }

var status: int = Status.MISSING
var error_message := ""
## Source entries exactly as written, order preserved. Saving rewrites these.
var sources: Array[Dictionary] = []
## Channels from "stream" sources only; a tuner's lineup is merged in later.
var stream_channels: Array[Dictionary] = []


static func config_path() -> String:
	return RomLibrary.default_tv_root().path_join(FILE_NAME)


## Read channels.json. Never throws: inspect `status` afterwards.
static func load_config() -> TVChannels:
	var cfg := TVChannels.new()
	var path := config_path()
	if not FileAccess.file_exists(path):
		cfg.status = Status.MISSING
		cfg.error_message = "No %s in %s" % [FILE_NAME, RomLibrary.default_tv_root()]
		return cfg

	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		cfg.status = Status.PARSE_ERROR
		cfg.error_message = "Cannot open %s" % path
		push_warning("[TVChannels] %s" % cfg.error_message)
		return cfg

	# JSON.new().parse() rather than JSON.parse_string(): this file is written by
	# hand, so a typo has to name itself instead of vanishing into a null.
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		cfg.status = Status.PARSE_ERROR
		cfg.error_message = "line %d: %s" % [json.get_error_line(), json.get_error_message()]
		push_warning("[TVChannels] JSON parse error, %s" % cfg.error_message)
		return cfg

	cfg._ingest(json.data)
	cfg.status = Status.OK
	print("[TVChannels] Loaded %d source(s), %d direct channel(s)"
		% [cfg.sources.size(), cfg.stream_channels.size()])
	return cfg


## Accepts either the documented object form or a bare array of {name, link}.
## The bare array is the shape people reach for first, and rejecting it would
## make the feature look broken on a file that reads as obviously correct.
func _ingest(data: Variant) -> void:
	var raw: Array = []
	if data is Array:
		raw = data as Array
	elif data is Dictionary:
		var d := data as Dictionary
		if d.get("sources") is Array:
			raw = d["sources"] as Array
		elif d.get("channels") is Array:
			raw = d["channels"] as Array

	for entry_v: Variant in raw:
		if not (entry_v is Dictionary):
			continue
		var entry: Dictionary = entry_v
		# An entry with a link is a stream whether or not it says so, which is
		# what makes the bare {name, link} array work unchanged.
		var kind := str(entry.get("type", "")).to_lower()
		if kind == "":
			kind = "hdhomerun" if entry.has("host") and not entry.has("link") else "stream"
		entry = entry.duplicate()
		entry["type"] = kind
		sources.append(entry)

		if kind == "stream":
			var url := str(entry.get("link", entry.get("url", ""))).strip_edges()
			if url.is_empty():
				push_warning("[TVChannels] Skipping '%s': no link"
					% str(entry.get("name", "(unnamed)")))
				continue
			stream_channels.append({
				"number": str(entry.get("number", "")),
				"name": str(entry.get("name", url)),
				"url": url,
				"source": "stream",
				"hd": bool(entry.get("hd", false)),
			})


## The first hdhomerun source, or {} when the list names no tuner.
func tuner_source() -> Dictionary:
	for s: Dictionary in sources:
		if str(s.get("type", "")) == "hdhomerun":
			return s
	return {}


## Whether the tuner should be discovered rather than addressed directly.
## Defaults to true so a source written as {"type":"hdhomerun"} just works.
func tuner_auto() -> bool:
	var s := tuner_source()
	return bool(s.get("auto", true)) if not s.is_empty() else true


func tuner_host() -> String:
	var s := tuner_source()
	return str(s.get("host", "")).strip_edges() if not s.is_empty() else ""


## Point the tuner at a specific address (or back at discovery) and persist.
## Creates the hdhomerun source if the file did not have one, so the options
## panel can turn a stream-only list into a tuned set.
func set_tuner(auto: bool, host: String) -> void:
	var found := false
	for i in sources.size():
		if str(sources[i].get("type", "")) == "hdhomerun":
			sources[i]["auto"] = auto
			sources[i]["host"] = host.strip_edges()
			found = true
			break
	if not found:
		sources.insert(0, {
			"type": "hdhomerun",
			"name": "Antenna",
			"auto": auto,
			"host": host.strip_edges(),
		})
	save()


## Write the source list back, preserving every key the user put there.
func save() -> bool:
	var path := config_path()
	if not JsonStore.write_dict(path, {"version": 1, "sources": sources},
			"TVChannels"):
		return false
	print("[TVChannels] Saved %d source(s) to %s" % [sources.size(), path])
	return true


## Write a commented starter file so a first run has something to edit rather
## than an empty folder. Only ever called when nothing is there.
static func write_default_config() -> void:
	var path := config_path()
	if FileAccess.file_exists(path):
		return
	RomLibrary.ensure_tv_root()
	var defaults := {
		"version": 1,
		"sources": [
			{"type": "hdhomerun", "name": "Antenna", "auto": true, "host": ""},
			{"type": "stream", "name": "Channel 42", "number": "42",
			 "link": "https://example.com/stream.m3u8"},
		],
	}
	if JsonStore.write_dict(path, defaults, "TVChannels"):
		print("[TVChannels] Wrote starter channel list: %s" % path)
