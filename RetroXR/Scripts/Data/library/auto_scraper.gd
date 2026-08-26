## AutoScraper -- scrape a ROM's metadata once it lands, without being asked.
##
## Scraping was manual and per-row: a button in the spawn list, one game at a
## time, pressed by hand. A ROM that arrives some other way -- pulled off the
## shelf for the first time, downloaded from RomM, resolved by hash to join a
## netplay session -- has a name, a hash and no artwork, and nobody is going to
## go and press that button for it.
##
## Why this is a QUEUE and not a call:
##
## ScreenScraper rate-limits per account and ScreenscraperClient serialises
## requests behind _wait_for_rate_limit(), so firing one scrape per resolved ROM
## would stack requests the server will refuse. One at a time, in arrival order,
## is the only shape that works.
##
## It is also deliberately quiet about failure. A scrape is decoration: the game
## runs, the session starts, the file is already correct. A missing cover must
## never turn into an error a player has to dismiss.
class_name AutoScraper
extends Node

## A scrape finished and wrote metadata for this ROM. The library refreshes on
## it; nothing depends on it having succeeded.
signal scraped(rom_path: String, systemid: String)

const MAX_QUEUE := 64

var _client: ScreenscraperClient = null
var _gamelist: GamelistManager = null
var _config: ScraperConfig = null

var _queue: Array[Dictionary] = []
var _busy := false
var _current: Dictionary = {}


func setup(client: ScreenscraperClient, gamelist: GamelistManager,
		config: ScraperConfig) -> void:
	_client = client
	_gamelist = gamelist
	_config = config
	if _client != null:
		_client.scrape_completed.connect(_on_completed)
		_client.scrape_failed.connect(_on_failed)


## True when auto-scraping can run at all.
##
## Credentials are the gate: ScreenScraper's anonymous quota is small enough
## that a library sweep would exhaust it, and a player who has not signed in has
## not opted into anything. Checked per request rather than cached because the
## account can be entered while the app is running.
func is_enabled() -> bool:
	return _config != null and _client != null \
		and not _config.ssid.is_empty() and not _config.sspassword.is_empty()


## The systemid a ROM path sits under, or "".
##
## Derived from the path rather than passed in, because the two callers know it
## in different forms -- the downloader enqueued with one, the netplay resolver
## only has a file it matched by hash -- and the layout (<roms_root>/<systemid>/)
## is the one thing both agree on.
static func systemid_for_path(rom_path: String) -> String:
	var root := RomLibrary.default_roms_root().simplify_path()
	var full := rom_path.simplify_path()
	if not full.begins_with(root):
		return ""
	var rest := full.substr(root.length()).lstrip("/")
	var parts := rest.split("/", false)
	return parts[0] if parts.size() > 1 else ""


## Queue a ROM for scraping if it needs it. Safe to call on every resolve.
func request(rom_path: String, systemid: String) -> void:
	if not is_enabled() or rom_path.is_empty() or systemid.is_empty():
		return
	if not FileAccess.file_exists(rom_path):
		return
	if already_scraped(rom_path, systemid):
		return
	for q: Dictionary in _queue:
		if str(q["rom"]) == rom_path:
			return
	if str(_current.get("rom", "")) == rom_path:
		return
	# A bound rather than an unbounded backlog: a first run over a large library
	# would otherwise queue thousands and scrape for hours.
	if _queue.size() >= MAX_QUEUE:
		return
	_queue.append({"rom": rom_path, "systemid": systemid})
	_pump()


## True when this ROM already has metadata, so scraping it again would spend a
## request to learn nothing.
func already_scraped(rom_path: String, systemid: String) -> bool:
	if _gamelist == null:
		return false
	var game := _gamelist.get_game_for_rom(systemid, rom_path)
	return not game.is_empty() and not str(game.get("name", "")).is_empty()


func queued_count() -> int:
	return _queue.size() + (1 if _busy else 0)


func cancel_all() -> void:
	_queue.clear()


func _pump() -> void:
	if _busy or _queue.is_empty() or _client == null:
		return
	_current = _queue.pop_front()
	_busy = true
	# checksums_of is the cached pass, so a ROM the netplay layer just hashed
	# costs nothing here.
	var sums := NetFileTransfer.checksums_of(str(_current["rom"]))
	_client.scrape_rom(str(_current["rom"]), str(_current["systemid"]), sums)


func _on_completed(result: Dictionary) -> void:
	if not _busy:
		return
	var rom := str(_current.get("rom", ""))
	var systemid := str(_current.get("systemid", ""))
	if _gamelist != null and not result.is_empty() and not rom.is_empty():
		_gamelist.add_or_merge_rom(systemid, result, {"path": rom})
		if _client != null:
			_client.download_all_media(result, systemid, rom.get_file().get_basename())
	_finish()
	if not rom.is_empty():
		scraped.emit(rom, systemid)


func _on_failed(_error: String) -> void:
	if not _busy:
		return
	_finish()


func _finish() -> void:
	_busy = false
	_current = {}
	_pump()
