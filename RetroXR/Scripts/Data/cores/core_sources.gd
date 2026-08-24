## CoreSources — cores retroXR ships itself, instead of taking from the buildbot.
##
## Almost every core comes from buildbot.libretro.com and needs nothing here. A
## core lands in this table when we maintain a fork of it, because then the
## buildbot's build is not the one we want the player to have.
##
## Six of them, and five are here for the same reason: this room has cables in
## it, and libretro has nowhere to put the far end of one. Dolphin, mGBA,
## gambatte and pcsx_rearmed each reach a link bus the frontend hosts; azahar is
## the odd one, and is here to surface stereo 3D the libretro glue never exposed.
##
## Dolphin is the one to read first if you want the shape of it. The buildbot
## build cannot do Wiimote IR passthrough — the frontend hands the emulated
## camera its real view of the sensor bar rather than a cursor position, and the
## option that switches it on only exists in our fork. Without it a Wii Remote in
## this room points by a constant fitted per game; with it, it points where you
## point.
##
## Each entry's comment says what its fork adds, and under which licence.
##
## Every binary is published on the fork it was built from, which is also what
## keeps it honest: four of the six are GPL, so the source for a distributed
## binary has to be there beside it, and a release tag on the source repo is the
## simplest arrangement that stays true. mGBA (MPL-2.0) and Play! (BSD) carry no
## such obligation and are published the same way anyway — it is the only way
## anyone can tell what they are running.
##
## Each fork builds its own release from that tag, so what ships is what the tag
## says. See .github/workflows/retroxr-release.yml on any of them.
##
## Deliberately keyed by the SAME core_name the buildbot uses ("dolphin", not
## "dolphin_retroxr"). The frontend derives system/<core> and save/<core> from
## that name, so a new one would strand the Sys folder, every GameCube memory
## card and the whole Wii NAND. Ours replaces the stock build in place and
## inherits all of it.
class_name CoreSources
extends RefCounted


const SOURCES := {
	"dolphin": {
		"repo":  "XenuIsWatching/dolphin",
		# The release this app was built knowing about. NOT part of the download
		# URL — see base_url. It is only the version to show when GitHub cannot be
		# reached, so an offline player still sees something truthful rather than
		# a blank.
		"known_tag": "retroxr-dolphin-libretro-v5",
		"label": "Dolphin (retroXR build)",
		# Per platform, because we only publish what we build. A platform absent
		# here is not an error — the manager falls back to the buildbot for it,
		# which is why Linux players still get a working Dolphin.
		"assets": {
			"Windows": "dolphin_libretro.dll.zip",
			"Android": "dolphin_libretro_android.so.zip",
		},
	},
	# Azahar, for the same shape of reason. The 3DS renders two eyes and always
	# did — Settings::values.render_3d and factor_3d were honoured all the way
	# down to the renderer — but the libretro glue was the one place that never
	# surfaced them, so no frontend could ask for a side-by-side frame. Without
	# that a 3DS in this room is flat, which is the one thing a 3DS is not.
	#
	# Upstream has the change as an open pull request (azahar-emu/azahar#2339).
	# When it merges this entry can go, and the buildbot's build will do.
	#
	# Note the asset has no "_android" infix: azahar's CMake never set an Android
	# OUTPUT_NAME, so its Android core is plain azahar_libretro.so and it is the
	# only one on the buildbot like that. core_lib_suffixes() already accepts
	# both spellings for exactly this core.
	"azahar": {
		"repo":  "XenuIsWatching/azahar",
		"known_tag": "retroxr-azahar-libretro-v1",
		"label": "Azahar (retroXR build)",
		"assets": {
			"Windows": "azahar_libretro.dll.zip",
			"Android": "azahar_libretro.so.zip",
		},
	},
	# mGBA, for the half of the link cable that is not the console.
	#
	# mGBA has carried its own lockstep coordinator for years and it was simply
	# unreachable: nothing in libretro can express a cable, and every core
	# instance is loaded from its own copy of the library, so two Game Boy
	# Advances in one process share no globals and have exactly one thing in
	# common, which is the frontend. Our build talks to a link bus the frontend
	# hosts instead, and that is what makes two handhelds in one room able to
	# play together, single-cartridge play work, and a GameCube lead reach a
	# handheld at all.
	#
	# Unlike Dolphin this is not a GPL obligation -- mGBA is MPL-2.0 -- but the
	# source sits on the tag beside the binary for the same practical reason: it
	# is the only way anyone can tell what they are running.
	#
	# The Android asset DOES carry the "_android" infix, unlike azahar's. Worth
	# saying because the two sit next to each other in this file and the wrong
	# name here fails silently, as a core that simply never downloads.
	"mgba": {
		"repo":  "XenuIsWatching/mgba",
		"known_tag": "retroxr-mgba-libretro-v2",
		"label": "mGBA (retroXR build)",
		"assets": {
			"Windows": "mgba_libretro.dll.zip",
			"Android": "mgba_libretro_android.so.zip",
		},
	},
	# Play!, the PS2 core. Two of the three fixes are the difference between a
	# core that runs on Quest and one that does not: the buildbot's Android build
	# points its data directory at /sdcard, which scoped storage will not let it
	# create, and the exception that follows escapes retro_init and aborts the
	# whole frontend. Past that, every thread the core starts asked to attach to
	# a JavaVM that a dlopen'd library never receives, and the assert guarding it
	# is compiled out of a release build. The third fix is visible on both
	# platforms — sprites are snapped to whole pixels, closing the column of
	# black seams the GS's corner sampling leaves down an OpenGL-rendered frame.
	#
	# Play! is BSD, so unlike Dolphin the binary carries no source obligation;
	# the fork is where it is built from all the same.
	"play": {
		"repo":  "XenuIsWatching/Play-",
		"known_tag": "retroxr-play-libretro-v1",
		"label": "Play! (retroXR build)",
		"assets": {
			"Windows": "play_libretro.dll.zip",
			"Android": "play_libretro_android.so.zip",
		},
	},
	# gambatte, the other end of every Game Boy cable in the room.
	#
	# The Game Boy's serial port is two wires and a clock, and libretro has never
	# had anywhere to put the far end of them. Our build speaks `gb-sio-1` over a
	# bus the frontend hosts, and gambatte_gb_link_mode gains a fourth value,
	# "Link Cable", which is the DEFAULT — with no bus, or a bus with nothing
	# cabled to it, the driver hands back the 0xFF of an open line, which is
	# exactly what the port does on the stock build. So the default costs an
	# uncabled player nothing.
	#
	# Deliberately the same wire format mGBA's Game Boy driver uses, which is
	# what lets a gambatte Game Boy and an mGBA one join the SAME cable. The two
	# drivers have to stay field-for-field in step; a field one latches and the
	# other does not is invisible from either side alone.
	#
	# It also carries two accuracy fixes the cable work uncovered, neither of
	# them about cables: the progressive serial shift took its bits off the top
	# of the incoming byte rather than from where the transfer had reached, and
	# a savestate was missing the blit event and blank-LCD flag, which slipped a
	# frame on reload with the LCD off. That second one is what kept gambatte out
	# of rollback netplay.
	#
	# gambatte is GPLv2, so the source obligation is Dolphin's, not mGBA's — the
	# tag beside the binary is what meets it.
	"gambatte": {
		"repo":  "XenuIsWatching/gambatte-libretro",
		"known_tag": "retroxr-gambatte-libretro-v1",
		"label": "gambatte (retroXR build)",
		"assets": {
			"Windows": "gambatte_libretro.dll.zip",
			"Android": "gambatte_libretro_android.so.zip",
		},
	},
	# pcsx_rearmed, for the PlayStation's serial port.
	#
	# SIO1 — the port at 1F801050h that the official Link Cable plugs into — had
	# never been emulated at all: sio1ReadStat16 returned a bare 0xa0 and there
	# was nothing behind it. Our build implements the port and speaks `psx-sio-1`
	# over the frontend's bus.
	#
	# With no bus the port still answers 0xa0, which is what every existing
	# session sees, and that matters more than it sounds: it is what stops
	# Armored Core and Formula 1 misdetecting a cable that is not there.
	# pcsx_rearmed_link_cable is on by default and is not restart-time.
	#
	# pcsx_rearmed is GPLv2, so the source has to sit on the tag beside the
	# binary — same arrangement as Dolphin and gambatte.
	"pcsx_rearmed": {
		"repo":  "XenuIsWatching/pcsx_rearmed",
		"known_tag": "retroxr-pcsx-rearmed-libretro-v1",
		"label": "PCSX-ReARMed (retroXR build)",
		"assets": {
			"Windows": "pcsx_rearmed_libretro.dll.zip",
			"Android": "pcsx_rearmed_libretro_android.so.zip",
		},
	},
}


## True when we publish this core ourselves AND have a build for this platform.
## Both halves matter: the Linux answer is "we know this core, but not here".
static func has(core_name: String) -> bool:
	return not asset_for(core_name).is_empty()


## The release asset filename for this platform, or "" when we do not build one.
static func asset_for(core_name: String) -> String:
	var src: Dictionary = SOURCES.get(core_name, {})
	if src.is_empty():
		return ""
	return str((src.get("assets", {}) as Dictionary).get(OS.get_name(), ""))


## Directory URL the asset hangs off, shaped like the buildbot's so the download
## manager can concatenate a filename onto either without caring which it has.
##
## Deliberately the /releases/latest/ form and NOT a tagged one. A tag in here
## would mean every new core build needed a new app build to point at it, and an
## installed copy of retroXR could never be given a fixed core — which is the
## whole point of having a download manager. GitHub resolves `latest` to the
## newest non-prerelease release, so publishing a build is enough to ship it.
##
## The consequence to know: `latest` is per REPOSITORY, not per product. A
## release cut on that fork for anything other than a core build would capture
## this URL. Mark such releases as pre-releases — GitHub's `latest` skips those.
static func base_url(core_name: String) -> String:
	var src: Dictionary = SOURCES.get(core_name, {})
	if src.is_empty():
		return ""
	return "https://github.com/%s/releases/latest/download/" % src.get("repo", "")


## Where to ASK what the newest build is called. A stable download URL is only
## half of shipping updates: the manager decides whether to offer one by
## comparing versions, so without this the app would keep fetching whatever is
## latest while insisting the player is already up to date.
static func api_url(core_name: String) -> String:
	var src: Dictionary = SOURCES.get(core_name, {})
	if src.is_empty():
		return ""
	return "https://api.github.com/repos/%s/releases/latest" % src.get("repo", "")


## Stands in for the buildbot's timestamp. The download manager only ever tests
## it for INEQUALITY against what the manifest stored, to decide whether to offer
## an update — so a release tag serves as well as a date, and unlike a date it
## only changes when the build does.
##
## This is the fallback; the live value comes from api_url.
static func version_of(core_name: String) -> String:
	var src: Dictionary = SOURCES.get(core_name, {})
	return str(src.get("known_tag", ""))


## Core names we publish AND build for this platform, for callers that need to
## walk them (the version probe).
static func active_core_names() -> Array[String]:
	var out: Array[String] = []
	for core_name: Variant in SOURCES:
		if has(str(core_name)):
			out.append(str(core_name))
	return out
