## MenuIcons — the Nerd Font glyphs the menu draws, the font that can render
## them, and the two small badges built from both.
##
## The menu's theme font has no Nerd Font glyphs, so a codepoint dropped into a
## plain Label renders as tofu. Anything using ICON_* must set symbols() as its
## font, which is what badge() and recommended_badge() do for you.
##
## Codepoints verified present in RetroXR/fonts/SymbolsNerdFont-Regular.ttf.
## All static. Never instantiated.
class_name MenuIcons
extends RefCounted

const FONT_PATH := "res://fonts/SymbolsNerdFont-Regular.ttf"
const ROMM_MARK_PATH := "res://Textures/RomM/romm_logo.svg"

# Two different delete glyphs is deliberate: the pictogram encodes whether the
# file can be got back. (At row size the two trash cans look near-identical, so
# the confirm text carries the real distinction — the glyph is a support cue.)
const DOWNLOAD  := 0xF0ED    # fa-cloud_download  — on the server, not here
const BUSY      := 0xF019    # fa-download        — coming down to us now
const UPLOAD    := 0xF093    # fa-upload          — going out from us now
const PAUSED    := 0xF04C    # fa-pause           — stalled, waiting on someone
const DELETE    := 0xF01B4   # md-delete          — reversible (still on server)
const DELETE_FOREVER := 0xF05E8  # md-delete_forever — local only, gone for good
const RETRY     := 0xF021    # fa-refresh
const ERROR     := 0xF071    # fa-warning
const GAMEPAD   := 0xF11B    # fa-gamepad
const BOOK      := 0xF05DA   # md-book_open_page_variant
const SCRAPE    := 0xF0866   # md-database_search
const FILTER    := 0xF0B0    # fa-filter
const REGION    := 0xF01E7   # md-earth
const RECOMMENDED := 0xF0124 # md-certificate     — the pick for this system
const CHECK     := 0xF012C   # md-check           — firmware present
const CROSS     := 0xF0159   # md-close_thick     — required firmware absent
const DASH      := 0xF0374   # md-minus           — optional firmware absent
const SETTINGS  := 0xF013    # fa-cog             — edit this core's options
const SCAN_QR   := 0xF0433   # md-qrcode_scan     — pair by looking at RomM's code
const CARD_SAVES := 0xF0279  # md-format_list_bulleted — list what a card holds
const RENAME    := 0xF03EB   # md-pencil          — rename in place
const MOVE      := 0xF04E1   # md-swap_horizontal — move a save to another card
const SYNC_ON   := 0xF063F   # md-cloud_sync      — kept in step with RomM
const SYNC_OFF  := 0xF0164   # md-cloud_off_outline — local only
const UPDATE    := 0xF01B    # fa-circle_up       — installed, but newer on the buildbot
const EXPAND    := 0xF0140   # md-chevron_down    — open a row's picker
const COLLAPSE  := 0xF0143   # md-chevron_up      — close it again
const CLOSE     := 0xF0156   # md-close           — dismiss a panel
const BACK      := 0xF004D   # md-arrow_left      — up a level in the menu
const DOT       := 0xF09DE   # md-circle_medium   — the one in use right now
const ROTATE_CCW := 0xF0E2   # fa-rotate_left     — turn a poster
const ROTATE_CW  := 0xF01E   # fa-rotate_right
const BACKSPACE := 0xF006E   # md-backspace       — on-menu keypad
const LOCK      := 0xF033E   # md-lock            — pinned where it stands
const LOCK_OPEN := 0xF033F   # md-lock_open       — free to be picked up
const NETPLAY   := 0xF06F3   # md-network         — this core can hold a session
const BSX_MEMORY_PACK := 0xEF5F  # fa-satellite   — a Satellaview pack we minted

const TINT_DOWNLOAD := Color(0.45, 0.70, 1.00)
const TINT_BUSY     := Color(1.00, 0.75, 0.25)
const TINT_DELETE   := Color(0.95, 0.40, 0.40)
const TINT_OK       := Color(0.40, 0.85, 0.45)
const TINT_WARN     := Color(1.00, 0.72, 0.20)
const TINT_MUTED    := Color(0.45, 0.45, 0.58)

## Built once and shared — the ROM list recycles rows, so a FontVariation per
## row (or per bind) would churn resources on every scroll.
static var _font: FontVariation = null
## base font instance id -> the same font with the glyphs behind it.
static var _wrapped: Dictionary = {}
static var _romm_mark: Texture2D = null


## The theme font with the Nerd Font behind it as a fallback, so a Label can
## carry both ordinary text and an ICON_* codepoint.
static func symbols() -> FontVariation:
	if _font != null:
		return _font
	_font = FontVariation.new()
	_font.base_font = ThemeDB.fallback_font
	var glyphs: Font = load(FONT_PATH)
	if glyphs != null:
		_font.fallbacks = [glyphs]
	return _font


## A caller that already has a font of its own still needs the glyph table
## behind it: substituting symbols() would throw that font away, and using it
## as-is drops every ICON_* into a tofu box.
static func with_symbols(base: Font) -> Font:
	if base == null:
		return symbols()
	var key := base.get_instance_id()
	if _wrapped.has(key):
		return _wrapped[key]
	var fv := FontVariation.new()
	fv.base_font = base
	var glyphs: Font = load(FONT_PATH)
	if glyphs != null:
		fv.fallbacks = [glyphs]
	_wrapped[key] = fv
	return fv


## The RomM logo, for marking rows that came from the server. Null if absent.
static func romm_mark() -> Texture2D:
	if _romm_mark == null and ResourceLoader.exists(ROMM_MARK_PATH):
		_romm_mark = load(ROMM_MARK_PATH)
	return _romm_mark


## The "Recommended" badge shown against a system's suggested core.
static func recommended_badge(font_size: int) -> Label:
	var lbl := MenuStyle.label("%s  Recommended" % String.chr(RECOMMENDED),
		font_size, MenuStyle.COLOR_RECOMMENDED)
	lbl.add_theme_font_override("font", symbols())
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return lbl


## The core's own `is_experimental` flag, which 57 of the bundled .info files
## set. Independent of the recommendation — a core can be the best available for
## a system and still be work in progress, so both badges can show at once.
static func experimental_badge(font_size: int) -> Label:
	var lbl := MenuStyle.label("%s  Experimental" % String.chr(ERROR),
		font_size, TINT_WARN)
	lbl.add_theme_font_override("font", symbols())
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.tooltip_text = "The core's authors mark this one as experimental — expect bugs"
	return lbl


## The colour a strategy is drawn in, brightest for the strongest.
static func netplay_tint(strategy: int) -> Color:
	match strategy:
		NetplayCores.Strategy.ROLLBACK:
			return MenuStyle.COLOR_NETPLAY
		NetplayCores.Strategy.DETERMINISM:
			return MenuStyle.COLOR_NETPLAY_DET
		_:
			return MenuStyle.COLOR_NETPLAY_LOCK


## The netplay badge for a core, or null when the core is not vetted for one.
## Takes the core name rather than a strategy so every caller gets the same
## gate; NetplayCores.listed_strategy is the one that ignores the debug switch.
static func netplay_badge(font_size: int, core_name: String) -> Label:
	var strategy := NetplayCores.listed_strategy(core_name)
	if strategy < 0:
		return null
	var word := NetplaySession.strategy_str(strategy).capitalize()
	var lbl := MenuStyle.label("%s  Netplay · %s" % [String.chr(NETPLAY), word],
		font_size, netplay_tint(strategy))
	lbl.add_theme_font_override("font", symbols())
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.tooltip_text = "Verified for online play with other players running this core"
	return lbl


## Reads the flag off a parsed .info entry. Written unquoted in two of the
## bundled files and quoted in the rest; the parser strips quotes, so both
## arrive here as the bare word.
static func is_experimental(info: Dictionary) -> bool:
	return str(info.get("is_experimental", "false")).strip_edges().to_lower() == "true"
