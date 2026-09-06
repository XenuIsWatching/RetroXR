## SystemInfo — per-system hardware descriptor (one .tres per systemid under
## res://SystemInfo/). Records how many controller ports the real console has,
## how its games load (cartridge / disc tray / disc insert), whether a multitap
## accessory applies, and — eventually — a custom hardware model scene.
##
## The MediaType enum values intentionally match MediaDimensions.LOADER_* so the
## loader mechanic (tray lid vs front slot vs no loader) and this descriptor
## never disagree. Look one up with SystemInfo.for_system("nes").
class_name SystemInfo
extends Resource

## Games load from a cartridge, a lidded or sliding disc tray, or a true front
## slot that draws the disc in. Values match MediaDimensions.LOADER_NONE/TRAY/SLOT,
## and MediaDimensions is the side that decides — it is what the cabinet actually
## reads, while nothing reads this field yet.
##
## DISC_INSERT is narrower than it sounds and the Wii is the only hardware here
## that earns it. A front-SLIDING tray is still DISC_TRAY: MediaTray owns the
## gating, seating, spin and collision either way, and only the geometry and the
## button's word change (see MediaDimensions.FRONT_TRAY_SYSTEMS). The PS2 and the
## PSP were both marked DISC_INSERT against that rule — the PS2 slides a tray out
## and the PSP has a hinged UMD door — so both disagreed with the loader they
## were actually given. mod_tests' consistency/ group now checks this pair.
enum MediaType { CARTRIDGE = 0, DISC_TRAY = 1, DISC_INSERT = 2 }

## Project systemid (e.g. "nes"); the filename stem of this resource.
@export var systemid: String = ""

## Human-readable console name for UI.
@export var display_name: String = ""

## Controller ports built into the console itself (before any multitap). Drives
## how many port snap-zones the cabinet exposes.
@export var native_ports: int = 2

## How this system's games are loaded.
@export var media_type: MediaType = MediaType.CARTRIDGE

## How many removable card slots this hardware has (0 = none). Shows that many
## card slots on the console, and makes the seated cards — not the disc — decide
## which save images are mounted. With no card in, nothing persists, which is why
## the card slot and the save path are the same switch.
##
## The PlayStation has one; the GameCube and the Wii have two.
@export var card_slots: int = 0

## Which family of card fits them: the folder under save/memcards/ and the image
## format, resolved through CardFormats.for_family(). A Wii takes GAMECUBE cards,
## which is why this is a family and not the systemid.
@export var card_family: String = ""

## True when this hardware has a serial port on the back for a link cable
## between two consoles -- the PlayStation's SIO1, not the controller bus.
##
## Shows the socket on the console body, the way memory_cards shows the card
## slot. It says nothing about whether the running core can carry a link: a core
## that cannot simply never joins the bus, and the lead sits there doing nothing,
## which is also what a cable does when the machine on the other end is off.
@export var serial_port: bool = false

## True when a multitap accessory extended the console past its native ports.
@export var supports_multitap: bool = false

## Player ports a multitap exposes for this system (NES Four Score = 4,
## PC Engine = 5, PlayStation = 8…). Only meaningful when supports_multitap.
@export var multitap_ports: int = 4

## Home computer whose libretro core reads the mouse on port 0 and takes keyboard
## input globally (ScummVM, DOS, Amiga, C64, MSX…). When true a plugged mouse
## always drives libretro port 0 regardless of which cabinet slot it's in, and a
## plugged keyboard doesn't occupy a numbered port device (its keys are global to
## port 0 anyway) — so a mouse and a keyboard can be used at once. Consoles leave
## this false: their mouse peripherals stay on the port they're plugged into.
@export var computer: bool = false

## One game is a FOLDER, not a file (ScummVM). The content the core is handed is a
## small marker file sitting inside the game's data folder, so a flat scan of the
## system's rom dir sees only directories and reports an empty library. When true
## RomLibrary.scan_roms() descends one level and the folder name becomes the label.
## When true the marker is identified by the system's own core-declared
## supported_extensions, so no extension is recorded here.
@export var folder_content: bool = false


static var _cache: Dictionary = {}

## Descriptors contributed by mods, consulted BEFORE res://SystemInfo/.
##
## Checked ahead of the shipped path so a mod can describe hardware this build
## has never heard of, and can correct a shipped descriptor without shipping a
## replacement .tres over the top of ours.
static var _mod_infos: Dictionary = {}
## systemid -> the mod that contributed it, so it can be taken back again.
static var _mod_owners: Dictionary = {}


## Add or replace a descriptor. The systemid comes off the resource itself, so a
## mod cannot file one under a name it does not answer to.
static func register_mod_info(info: SystemInfo, owner_id: String = "") -> void:
	if info == null or info.systemid.is_empty():
		return
	_mod_infos[info.systemid] = info
	_mod_owners[info.systemid] = owner_id
	# The negative cache is why this matters: for_system() caches a MISS as null,
	# so a systemid asked about before the mod registered would stay null for the
	# session. Dropping the entry is cheaper than reasoning about who asked first.
	_cache.erase(info.systemid)


## Take back one mod's descriptors.
##
## Not on ModOverlayTable like the five tables that are: there is no shipped
## const table to overlay — the base layer is res://SystemInfo/*.tres, resolved
## by path. The negative cache is dropped for the same reason registration drops
## it, in the other direction: a systemid answered from the mod for a whole
## session must not keep answering from it once the mod is gone.
static func drop_mod(owner_id: String) -> void:
	for a_systemid: String in _mod_owners.keys():
		if _mod_owners[a_systemid] != owner_id:
			continue
		_mod_infos.erase(a_systemid)
		_mod_owners.erase(a_systemid)
		_cache.erase(a_systemid)


## Load the descriptor for a systemid, or null when none exists. Cached.
static func for_system(a_systemid: String) -> SystemInfo:
	if a_systemid.is_empty():
		return null
	if _mod_infos.has(a_systemid):
		return _mod_infos[a_systemid]
	if _cache.has(a_systemid):
		return _cache[a_systemid]
	var path := "res://SystemInfo/%s.tres" % a_systemid
	var info: SystemInfo = null
	if ResourceLoader.exists(path):
		info = ResourceLoader.load(path) as SystemInfo
	_cache[a_systemid] = info
	return info


## "cartridge" / "disc_tray" / "disc_insert" for logging and UI.
func media_type_name() -> String:
	match media_type:
		MediaType.DISC_TRAY:   return "disc_tray"
		MediaType.DISC_INSERT: return "disc_insert"
		_:                     return "cartridge"
