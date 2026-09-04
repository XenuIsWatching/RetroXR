## MediaDimensions — per-system physical media data (cartridge sizes, disc
## diameters) plus the scraped label-art loader shared by RetroCartridge and
## RetroDisc. Single source of truth for "which systems use discs" and how big
## each system's media is. Sizes are real-world approximations in metres.
class_name MediaDimensions
extends RefCounted

## The e-Reader card, and there is only one.
##
## An earlier version of this file carried a second, landscape shape and chose
## between them per card -- first from the strip layout, then from the aspect of
## the scraped scan. Both were wrong, and the second was worse: a card scraped
## mid-session changed shape under the player. Every card in the No-Intro set is
## a portrait trading card, so the size is a constant and the strip layout says
## only which EDGES are coded.
const CARD_SIZE_EREADER := Vector3(0.063, 0.088, 0.0008)


## Cartridge dimensions: systemid -> Vector3(width, height, thickness).
## Axes match cartridge.tscn (label faces +Z). Unlisted systems fall back to
## the generic scene size via cart_size().
const CART_SIZES: Dictionary = {
	"nes":              Vector3(0.120, 0.133, 0.017),   # measured off a real cart
	"super_nes":        Vector3(0.137, 0.088, 0.020),
	"nintendo_64":      Vector3(0.116, 0.075, 0.020),
	"game_boy":         Vector3(0.057, 0.065, 0.008),
	"game_boy_advance": Vector3(0.058, 0.036, 0.007),
	"mega_drive":       Vector3(0.110, 0.070, 0.017),
	# A 32X game is a Mega Drive cartridge -- same shell, same slot, and it goes
	# into the 32X's own slot the way a plain cart goes into the console's. Listed
	# so it is not handed CART_SIZE_DEFAULT, which is a different shape entirely
	# and made the 32X's slot the wrong size for what stands in it.
	"sega_32x":         Vector3(0.110, 0.070, 0.017),
	"atari_2600":       Vector3(0.079, 0.104, 0.021),
	"atari_5200":       Vector3(0.108, 0.104, 0.021),   # squarer, wider shell than the 2600 cart
	"virtual_boy":      Vector3(0.065, 0.054, 0.006),   # VB cart, measured off the model
	"nds":              Vector3(0.033, 0.035, 0.004),
	"3ds":              Vector3(0.033, 0.035, 0.004),   # 3DS Game Card = DS footprint
	"atari_lynx":       Vector3(0.073, 0.086, 0.006),   # Lynx card
	"game_gear":        Vector3(0.068, 0.047, 0.012),
	"wonderswan":       Vector3(0.048, 0.052, 0.008),
	"neo_geo_pocket":   Vector3(0.048, 0.052, 0.008),
	"nintendo_64dd":    Vector3(0.098, 0.079, 0.017),   # 64DD magnetic disk
	# The 8M Memory Pack, which is NOT a Super Famicom cartridge -- it is a small
	# pack that goes into a well in the top of the BS-X cart and stands proud of
	# it. Approximate: proportioned from photographs against the SFC shell it
	# slots into, not measured off one. Without an entry it took CART_SIZE_DEFAULT
	# and arrived nearly as big as the cartridge carrying it.
	"satellaview":      Vector3(0.062, 0.042, 0.011),
	# A Sufami Turbo cartridge is a small one -- nearer the 8M pack above than the
	# Super Famicom cart it plugs in behind. Without an entry it took
	# CART_SIZE_DEFAULT, a 100 mm slab, and the adapter has to hold TWO side by
	# side: at that size they do not fit in the unit at all, so the fallback was
	# not merely untuned here, it was load-bearing geometry.
	"sufami_turbo":     Vector3(0.055, 0.045, 0.012),
	"pokemon_mini":     Vector3(0.022, 0.033, 0.007),
	"supervision":      Vector3(0.066, 0.070, 0.009),
	# UMD caddy — square footprint, thin. RetroUMD builds its shell straight off
	# this; without an entry it would fall back to CART_SIZE_DEFAULT (10x8 cm) and
	# hand out a caddy ~40% too big. Note the PSP appears in DISC_DIAMETERS too:
	# that is the bare platter sealed inside, this is the caddy you actually hold.
	"playstation_portable": Vector3(0.064, 0.064, 0.0042),
	# A dotcode card, which is a trading card: every e-Reader card is the same
	# portrait 63 x 88 mm stock, Nintendo's own series and the Pokemon-e TCG
	# cards alike. Nominal, not measured off a card.
	"ereader":          CARD_SIZE_EREADER,
}

## Generic cartridge size (the original cartridge.tscn values) for systems
## without an entry above.
const CART_SIZE_DEFAULT := Vector3(0.10, 0.08, 0.015)

## The 3.5-inch disk: 90 mm across, 94 mm deep, 3.3 mm thick — the real thing.
## One constant rather than a row per system, because every machine below loaded
## from the same disk. Axes match a cartridge: the shutter edge is -Y (where a
## cart's connector is) and the paper label faces +Z.
const FLOPPY_SIZE := Vector3(0.090, 0.094, 0.0033)

## Systems whose media is a SHUTTERED DISK rather than a cartridge -- a sliding
## metal cover over a head window, and a shell that goes into a slot rather than
## onto a connector.
##
## This is every platform the PC tower is hardware for (SystemModelRegistry's
## _COMPUTER_PLATFORMS) except scummvm, which shipped on CD and appears in
## DISC_DIAMETERS above. Listed rather than derived for the reason the registry
## lists them too: this is a const table and SystemInfo is a loaded resource, so a
## new computer system has to be added here as well as given its .tres.
##
## Not every one of them really used a 3.5-inch disk — a VIC-20 took cartridges, a
## ZX81 a cassette — but the tower is already an admitted stand-in for eighteen
## machines and it has exactly one 3.5-inch drive on its bezel. One medium per
## shell beats sixteen exceptions to it.
const FLOPPY_SYSTEMS: Dictionary = {
	# Not PC media, and not the tower's: a 64DD disk and a Famicom Disk System
	# disk are both shuttered magnetic disks that slide into a drive, and both
	# are loaded label-up with the shutter leading. Without an entry here they
	# spawn as moulded cartridges with a connector edge, and a drive that pulls
	# the shutter in first would appear to be swallowing them backwards.
	"nintendo_64dd": true,
	"fds": true,
	"apple_ii": true,
	"atari_8bit": true,
	"atari_st": true,
	"commodore_amiga": true,
	"commodore_c128": true,
	"commodore_c64": true,
	"commodore_vic20": true,
	"cpc": true,
	"dos": true,
	"msx": true,
	"pc_88": true,
	"pc_98": true,
	"sharp_x1": true,
	"sharp_x68000": true,
	"svi": true,
	"zx81": true,
	"zx_spectrum": true,
}

## Disc diameters: systemid -> diameter in metres. Doubles as the disc-system
## set — a systemid present here spawns a RetroDisc instead of a cartridge.
## (pc_engine stays a cartridge: its HuCard — the CD add-on is pc_engine_cd.)
const DISC_DIAMETERS: Dictionary = {
	"playstation":           0.12,
	"playstation2":          0.12,
	"sega_saturn":           0.12,
	"sega_cd":               0.12,
	"pc_engine_cd":          0.12,
	"jaguar_cd":             0.12,
	"neo_geo_cd":            0.12,
	"amiga_cd32":            0.12,
	"amiga_cdtv":            0.12,
	"wii":                   0.12,
	"dreamcast":             0.12,
	"3do":                   0.12,
	"cdi":                   0.12,
	"pc_fx":                 0.12,
	"gamecube":              0.08,   # mini-DVD
	"playstation_portable":  0.064,  # UMD (bare disc, no caddy)
	# ScummVM is not console hardware — it stands in for a 90s PC, whose adventure
	# games shipped on CD-ROM. Listing it here is what makes the spawn menu hand
	# out a disc and RetroSystem take the tray path; the PC tower model then slides
	# that tray instead of hinging a lid.
	"scummvm":               0.12,
}

## Default disc diameter (standard CD/DVD) for a disc systemid without an entry.
const DISC_DIAMETER_DEFAULT := 0.12

## Track pitch in MICROMETRES — the spacing of the data spiral, which is what
## Shaders/disc.gdshader diffracts light off. A CD's coarse 1.6 um puts four
## diffraction orders in the visible band and shows repeating spectral bands; a
## DVD's 0.74 um puts one there and shows a single broad sweep. Getting this right
## is the whole difference between a PS1 disc and a Wii disc.
const PITCH_CD := 1.6
const PITCH_DVD := 0.74
const PITCH_GD := 1.1   # GD-ROM packed ~1 GB onto a CD by tightening the pitch

## Disc finishes:
##   data   the reflective layer seen through the substrate (the underside)
##   poly   bare polycarbonate — bore, rim, edge, and the clear annulus inside
##          the metal, which on a CD reaches all the way out to 22 mm
##   alpha  opacity of that bare substrate. A normal disc's hub is a window; a
##          dyed one is not, which is the whole reason this is per-system.
##   pitch  track pitch, micrometres
const FINISH_CD := {"data": Color(0.78, 0.80, 0.84), "poly": Color(0.09, 0.10, 0.12), "alpha": 0.28, "pitch": PITCH_CD}
const FINISH_DVD := {"data": Color(0.72, 0.71, 0.79), "poly": Color(0.09, 0.10, 0.12), "alpha": 0.28, "pitch": PITCH_DVD}
const FINISH_GD := {"data": Color(0.76, 0.78, 0.80), "poly": Color(0.09, 0.10, 0.12), "alpha": 0.28, "pitch": PITCH_GD}
## The PS1's black disc: the polycarbonate itself is dyed, so the edge goes black
## too, not just the playing surface, and the hub stops being a window. Near-black
## albedo is why this one needs the analytic rainbow most — with no reflection
## probe in any room, the diffraction term is the only thing keeping it from
## rendering as a featureless black hole.
const FINISH_PS1 := {"data": Color(0.07, 0.06, 0.09), "poly": Color(0.035, 0.03, 0.045), "alpha": 0.90, "pitch": PITCH_CD}
## Dual-layer DVD-9. The second layer is semi-reflective gold rather than plain
## aluminium, which is why a DVD-9 reads bronze against a DVD-5's silver-violet —
## and most of the big PS2 and Wii titles are DVD-9.
const FINISH_DVD9 := {"data": Color(0.70, 0.58, 0.34), "poly": Color(0.09, 0.10, 0.12), "alpha": 0.28, "pitch": PITCH_DVD}
## The PS2's blue CD-ROM. Its DVD titles are FINISH_DVD — see disc_finish().
const FINISH_PS2_CD := {"data": Color(0.10, 0.20, 0.48), "poly": Color(0.04, 0.07, 0.16), "alpha": 0.55, "pitch": PITCH_CD}

## systemid -> finish. Unlisted disc systems are silver CDs, which is most of them.
const DISC_FINISHES: Dictionary = {
	"playstation":  FINISH_PS1,
	"dreamcast":    FINISH_GD,
	"gamecube":     FINISH_DVD,   # mini-DVD
	"wii":          FINISH_DVD,
	"playstation_portable": FINISH_DVD,   # UMD is DVD-derived, not a CD
	# playstation2 is resolved per-title in disc_finish(): CD-ROM or DVD.
}

## CD descriptor formats. A DVD is never described by a .cue, and this check has to
## come before any size test: rom_path frequently points at the descriptor rather
## than the data, and "Final Fantasy VII (USA) (Disc 1).cue" is 98 bytes next to a
## 747 MB .bin.
const _CD_DESCRIPTORS: PackedStringArray = ["cue", "gdi", "toc", "m3u", "ccd"]

## A PS2 CD-ROM cannot hold more than one CD. A raw 2352-byte-per-sector image
## inflates that well past the nominal 700 MB — a full 80-minute disc reaches
## ~783 MB — so the line sits at 1 GiB, still four times under a 4.7 GB DVD5.
const _CD_MAX_BYTES := 1073741824

## A single-layer DVD-5 holds 4.7 GB decimal = 4.377 GiB. Anything past that had
## to be pressed as dual-layer, so the image size tells you the disc was gold.
const _DVD5_MAX_BYTES := 4831838208   # 4.5 GiB, just clear of a full DVD-5


## Disc loading mechanisms.
const LOADER_NONE := 0   # cartridge system — no disc loader
const LOADER_TRAY := 1   # lid/tray: OPEN button gates insert/remove (PS1, GameCube…)
const LOADER_SLOT := 2   # slot-load: disc injects on insert, EJECT slides it out (PS2)
const LOADER_SWIPE := 3  # through-slot: the medium is slid past a reader and back out

## Systems that slot-load instead of using a lid/tray.
## NOTE: playstation2 was here (the fat PS2's front slot) but the console we model
## is the PS2 SLIM, which is top-loading (hinged disc cover) — so LOADER_TRAY.
## Slot-load = the disc injects on insert and the EJECT button slides it out
## (PS2). Everything else with a disc is a lid/tray (OPEN reveals a well). The
## PSP is a tray: its UMD sits behind a hinged door you flick open, not a slot.
const SLOT_LOAD_SYSTEMS: Dictionary = {
	# The one true slot-loader we model: the disc is drawn in and the
	# EJECT button spits it back out. No lid, no tray.
	"wii": true,
}

## Lid/tray systems whose tray SLIDES OUT THE FRONT instead of hinging open — the
## fat PS2, and any PC-style optical drive.
##
## Still LOADER_TRAY: MediaTray owns the gating, seating, spin and collision either
## way, and only the geometry and the button's word change. This is the same split
## RetroSystemModelPCTower already runs on with authored geometry — it keeps
## LOADER_TRAY and makes play_open/play_close a slide — so a system opting in here
## gets that motion built procedurally on the placeholder box instead.
const FRONT_TRAY_SYSTEMS: Dictionary = {
	"playstation2": true,
	# Model 1, the machine our icon draws — a motorised tray out of the front.
	# Model 2 is a hinged top lid, which is the other branch.
	"sega_cd": true,
}


## True when this system's tray slides out of the front face rather than hinging.
static func has_front_tray(systemid: String) -> bool:
	if _mod_media.has(systemid):
		return bool(_mod_media[systemid].get("front_tray", false))
	return FRONT_TRAY_SYSTEMS.has(systemid)


## True when the systemid's games ship on discs (spawn a RetroDisc).
static func is_disc_system(systemid: String) -> bool:
	if _mod_media.has(systemid):
		return _mod_media[systemid].has("disc_diameter")
	return DISC_DIAMETERS.has(systemid)


## True when this system's media is a floppy disk (a dark shell with a sprung
## metal shutter) rather than a moulded cartridge.
static func uses_floppy(systemid: String) -> bool:
	if _mod_media.has(systemid):
		return bool(_mod_media[systemid].get("floppy", false))
	return FLOPPY_SYSTEMS.has(systemid)


## True when a real-world size is known for this system's media, so the generic
## cartridge body is worth resizing to it. Ask this rather than CART_SIZES.has():
## a floppy system carries its size in FLOPPY_SIZE and is in neither table.
static func has_cart_size(systemid: String) -> bool:
	if _mod_media.has(systemid):
		var m: Dictionary = _mod_media[systemid]
		return m.has("cart_size") or bool(m.get("floppy", false))
	return CART_SIZES.has(systemid) or FLOPPY_SYSTEMS.has(systemid)


## Cartridge body size for a system, or the generic default.
## `rom_path` is consulted for the one system whose media is two different
## objects. Everything under "satellaview" is an 8M pack EXCEPT the BS-X shell
## itself, which is an ordinary Super Famicom cartridge and is the file the town
## boots from -- sizing it off the systemid alone shrank it to pack size.
static func cart_size(systemid: String, rom_path := "") -> Vector3:
	if _mod_media.has(systemid):
		var m: Dictionary = _mod_media[systemid]
		if bool(m.get("floppy", false)):
			return FLOPPY_SIZE
		if m.has("cart_size"):
			return m["cart_size"] as Vector3
	if FLOPPY_SYSTEMS.has(systemid):
		return FLOPPY_SIZE
	if systemid == "satellaview" and not rom_path.is_empty():
		var ext := rom_path.get_extension().to_lower()
		if ext == "sfc" or ext == "smc":
			return CART_SIZES["super_nes"]
	return CART_SIZES.get(systemid, CART_SIZE_DEFAULT)


## Disc diameter for a system, or the standard 12 cm.
static func disc_diameter(systemid: String) -> float:
	if _mod_media.has(systemid) and _mod_media[systemid].has("disc_diameter"):
		return float(_mod_media[systemid]["disc_diameter"])
	return float(DISC_DIAMETERS.get(systemid, DISC_DIAMETER_DEFAULT))


## True when this disc image is a CD rather than a DVD. Extension first, size
## second — see _CD_DESCRIPTORS and _CD_MAX_BYTES. Unknowable means CD, because a
## PS2 game whose file can't be read is more usefully blue than wrongly silver.
static func _is_cd_image(rom_path: String) -> bool:
	if rom_path.is_empty():
		return true
	if _CD_DESCRIPTORS.has(rom_path.get_extension().to_lower()):
		return true
	var f := FileAccess.open(rom_path, FileAccess.READ)
	if f == null:
		return true
	var n := f.get_length()   # metadata only, nothing is read
	f.close()
	return n < _CD_MAX_BYTES


## True when this image is too big to have been a single-layer DVD-5.
static func _is_dual_layer(rom_path: String) -> bool:
	if rom_path.is_empty():
		return false
	var f := FileAccess.open(rom_path, FileAccess.READ)
	if f == null:
		return false
	var n := f.get_length()
	f.close()
	return n > _DVD5_MAX_BYTES


## Disc finish for a system: {"data", "poly", "alpha", "pitch"}.
##
## Two of these need the ROM, not just the systemid. The PS2 shipped both CD-ROM
## (the blue discs) and DVD, roughly half the library each. And any DVD-family
## system can be dual-layer, which is gold rather than silver — the image size is
## the tell for both.
static func disc_finish(systemid: String, rom_path: String = "") -> Dictionary:
	if systemid == "playstation2":
		if _is_cd_image(rom_path):
			return FINISH_PS2_CD
		return FINISH_DVD9 if _is_dual_layer(rom_path) else FINISH_DVD
	var finish: Dictionary = FINISH_CD
	if _mod_media.has(systemid) and _mod_media[systemid].has("disc_finish"):
		finish = _mod_media[systemid]["disc_finish"] as Dictionary
	else:
		finish = DISC_FINISHES.get(systemid, FINISH_CD)
	if float(finish["pitch"]) < 1.0 and _is_dual_layer(rom_path):
		return FINISH_DVD9
	return finish


## Radii in metres of the disc's optical zones, as (metal_start, data_start,
## data_end): where the clear polycarbonate gives way to aluminium, where the
## unrecorded mirror band gives way to pits, and where the pits stop and the
## clear outer rim begins.
##
## Numbers below are off the standards, not guessed. Diameters halved to radii:
##
## CD — ECMA-130 (2nd ed.) clause 8, the free equivalent of ISO/IEC 10149:
##   d1 = 15,0        centre hole
##   d3 = 33 min      clamping area outer edge
##   d4 = 44 max      Information Area starts, and 8.6 puts the REFLECTIVE LAYER
##                    between d4 and d5 — so metal begins at r 16,5..22
##   d6 <= 46 max     physical tracks (pits) start (clause 20)
##   d7 = 50,0        User Data zone;  d8 = 116 max;  d5 = 118 max;  d10 = 120
## d4 is a MAXIMUM, so a real disc may metallise well inside r 22 and show a mirror
## band several mm wide rather than the 1 mm the extreme case implies. Measured on
## a pressed audio CD: clear ring ~12 mm wide (metal from r 19,5), mirror band
## ~4 mm. That is in spec, and is what the CD row uses.
##
## DVD — ECMA-267 (3rd ed.) clause 10:
##   d2 = 15          centre hole;  d4 = 22,0 max -> Clamping Zone;  d5 = 33 min
##   d6 = 44,0 max, d7 = 45,2 max   Lead-in starts (so pits from r ~22,6)
##   d8 = 48,0        Data Zone;  d9 = 116 max
## Note ECMA-267 does NOT pin the reflective layer's inner edge the way ECMA-130
## does — clause 12.6 only constrains reflectivity of the recorded layer. So how
## far in a DVD is silvered is a manufacturing choice, and in practice a bonded
## two-half disc reads metallic from about the clamping zone out. Hence r 11
## (= d4/2) rather than the CD's r 19,5: on a Wii disc only the bore is clear.
##
## The UMD is NOT covered by either standard; its row is scaled from the DVD and
## is the one set of numbers here that is still an estimate.
static func disc_zones(systemid: String, pitch: float = PITCH_CD) -> Vector3:
	var d := disc_diameter(systemid)
	var dvd := pitch < 1.0
	if d < 0.07:
		return Vector3(0.0105, 0.0160, 0.0300)   # UMD platter — estimated
	if d < 0.10:
		return Vector3(0.0110, 0.0226, 0.0380) if dvd else Vector3(0.0195, 0.0230, 0.0380)
	return Vector3(0.0110, 0.0226, 0.0580) if dvd else Vector3(0.0195, 0.0230, 0.0580)


## How this system loads discs: LOADER_NONE / LOADER_TRAY / LOADER_SLOT.
static func disc_loader(systemid: String) -> int:
	if _mod_media.has(systemid):
		var m: Dictionary = _mod_media[systemid]
		if not m.has("disc_diameter"):
			return LOADER_NONE
		return LOADER_SLOT if bool(m.get("slot_load", false)) else LOADER_TRAY
	if not DISC_DIAMETERS.has(systemid):
		return LOADER_NONE
	return LOADER_SLOT if SLOT_LOAD_SYSTEMS.has(systemid) else LOADER_TRAY


## Load the scraped "support" art (physical media label) for a ROM, or null.
## The scraper saves support-texture media to
## <roms_root>/<systemid>/media/label/<rom_basename>.<ext> (screenscraper_client
## download_all_media), named after the ROM file — mirror _load_wheel_texture.
static func load_label_texture(systemid: String, rom_path: String) -> Texture2D:
	if systemid.is_empty() or rom_path.is_empty():
		return null
	var base := rom_path.get_file().get_basename()
	if base.is_empty():
		return null
	var media_dir := RomLibrary.rom_dir_for_system(systemid).path_join("media/label")
	for ext in [".png", ".jpg", ".jpeg", ".webp"]:
		var path := media_dir.path_join(base + ext)
		if FileAccess.file_exists(path):
			var img := Image.load_from_file(path)
			if img:
				# These are ~600x600 photographic scans wrapped onto a disc face or
				# a cartridge label, both of which are read at a glancing angle in
				# VR. Without mips the print shimmers as the head moves. (The
				# project's no-mipmaps rule is about emulator SCREENS, where sharp
				# aliased pixel art is the point — the opposite case.)
				img.generate_mipmaps()
				return ImageTexture.create_from_image(img)
	return null


# ── mod media ─────────────────────────────────────────────────────────────────

## Media descriptors contributed by mods, one per systemid, replacing what the
## six const tables above would say for that platform.
##
## One descriptor rather than six overlays because the tables are not
## independent: disc_loader() is derived from DISC_DIAMETERS and
## SLOT_LOAD_SYSTEMS together, and SystemInfo.media_type is documented as
## matching LOADER_* exactly. A mod filling three of the six would produce a
## platform whose loader and descriptor disagree, which surfaces as a disc bay
## that will not open rather than as anything resembling its cause.
##
## Keys, all optional:
##   cart_size      Vector3  cartridge body, metres
##   floppy         bool     media is a floppy (uses FLOPPY_SIZE)
##   disc_diameter  float    metres; PRESENCE is what makes it a disc system
##   disc_finish    Dictionary  as DISC_FINISHES rows
##   slot_load      bool     front slot rather than a hinged tray
##   front_tray     bool     tray slides from the front face
static var _mod_media: Dictionary = {}


## Returns "" when the descriptor was accepted.
static func register_mod_media(systemid: String, dims: Dictionary) -> String:
	if systemid.is_empty():
		return "no systemid"
	if dims.has("cart_size") and not (dims["cart_size"] is Vector3):
		return "cart_size must be a Vector3"
	if dims.has("disc_diameter") and not (dims["disc_diameter"] is float or dims["disc_diameter"] is int):
		return "disc_diameter must be a number"
	if dims.has("slot_load") and not dims.has("disc_diameter"):
		return "slot_load needs a disc_diameter, or there is no disc to load"
	_mod_media[systemid] = dims.duplicate(true)
	return ""


static func is_mod_media(systemid: String) -> bool:
	return _mod_media.has(systemid)
