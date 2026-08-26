## MenuStyle — the spawn menu's palette, and builders for the widgets it makes
## over and over.
##
## The menu builds its whole UI in code, so a sixth of it was widget
## boilerplate: 104 `Label.new()` followed by a font-size override and a colour
## override, 17 hand-rolled rounded stylebox loops, and so on. Those live here
## now, so a view file is the layout and the wiring rather than the ceremony.
##
## Every builder returns exactly what the inline version did — this is a place to
## put the repetition, not an opportunity to restyle. Anything a caller varies
## (action_mode, focus_mode, size flags) is deliberately left to the caller: the
## menu runs in a Viewport2Din3D where those have real consequences, and baking
## one choice in here would apply it to widgets that must not have it.
##
## All static. Never instantiated.
class_name MenuStyle
extends RefCounted

# ── Palette ───────────────────────────────────────────────────────────────────
const COLOR_BG           := Color(0.08, 0.08, 0.16, 0.96)
const COLOR_NAV_ACTIVE   := Color(0.25, 0.25, 0.55)
const COLOR_NAV_INACTIVE := Color(0.12, 0.12, 0.25)
const COLOR_TITLE        := Color(0.9,  0.9,  1.0)
const COLOR_LICENSE      := Color(0.65, 0.65, 0.80)
const COLOR_DESC         := Color(0.55, 0.55, 0.68)
const COLOR_BTN_DL       := Color(0.15, 0.45, 0.15)
## Lighter than COLOR_BTN_DL, which is a button fill and unreadable as text here.
const COLOR_RECOMMENDED  := Color(0.45, 0.85, 0.45)
## Netplay, by strategy, brightest first. Light enough to read as text: the only
## other purple here is COLOR_TILE_ALT, a dark tile fill that is not.
const COLOR_NETPLAY      := Color(0.70, 0.55, 1.00)
const COLOR_NETPLAY_DET  := Color(0.56, 0.46, 0.78)
const COLOR_NETPLAY_LOCK := Color(0.46, 0.40, 0.60)
const COLOR_BTN_UPD      := Color(0.45, 0.30, 0.10)
const COLOR_BTN_REUP     := Color(0.18, 0.18, 0.35)
const COLOR_BTN_BUSY     := Color(0.25, 0.20, 0.10)

# Scrollbar. The track matches the recessed nav chrome; the grabber climbs in
# brightness through hover and drag so the state reads from a metre away.
const COLOR_SCROLL_TRACK   := Color(0.12, 0.12, 0.25)
const COLOR_SCROLL_GRAB    := Color(0.30, 0.30, 0.60)
const COLOR_SCROLL_GRAB_HI := Color(0.42, 0.42, 0.74)
const COLOR_SCROLL_GRAB_ON := Color(0.55, 0.55, 0.90)

# Scene view
const COLOR_SCENE_ACTIVE   := Color(0.3, 0.5, 0.3)
const COLOR_SCENE_INACTIVE := Color(0.15, 0.15, 0.30)
const COLOR_BTN_SAVE       := Color(0.15, 0.45, 0.15)
const COLOR_BTN_CLEAR      := Color(0.50, 0.15, 0.15)
const COLOR_BTN_LOAD       := Color(0.15, 0.30, 0.55)
const COLOR_SLOT_ACTIVE    := Color(0.20, 0.42, 0.20)
const COLOR_SLOT_NORMAL    := Color(0.12, 0.12, 0.27)


# ── Builders ──────────────────────────────────────────────────────────────────

## The tinted plate one save sits on — a memory card's or a cartridge's. Defined
## once because the two lists show the same kind of thing and were drifting: one
## had rounded plates with a title and a detail line, the other flat buttons
## holding a single run-on string.
static func save_plate_box() -> StyleBoxFlat:
	var s := rounded(Color(1, 1, 1, 0.05), 6)
	s.content_margin_left = 8
	s.content_margin_right = 8
	s.content_margin_top = 6
	s.content_margin_bottom = 6
	return s


## A filled box with every corner rounded. StyleBoxFlat has no set-all for corner
## radius the way it does for content margins, so this was written out as a
## four-key loop in seventeen places.
static func rounded(color: Color, radius: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.corner_radius_top_left = radius
	s.corner_radius_top_right = radius
	s.corner_radius_bottom_left = radius
	s.corner_radius_bottom_right = radius
	return s


static func label(text: String, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	return l


## A section heading inside a view — "DISPLAY", "QUALITY", "MULTIPLAYER (LAN)".
static func header(text: String, font_size := 22) -> Label:
	return label(text, font_size, COLOR_TITLE)


## Explanatory small print under a control. Wraps, because these are sentences.
static func hint(text: String) -> Label:
	var l := label(text, 16, COLOR_DESC)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


## A menu row's button: a fixed height, a font size, and nothing else assumed.
##
## `width` 0 means "take the row" (the usual list row); a positive width is a
## fixed-size button sitting beside one. `align_left` is what separates a row you
## read from a control you press.
##
## Deliberately does not touch action_mode, focus_mode or `disabled` — same
## reasoning as the rest of this file: the menu runs in a Viewport2Din3D where
## those have consequences the caller owns.
static func row_button(text: String, font_size := 26, width := 0,
					   height := 80, align_left := true) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(width, height)
	b.add_theme_font_size_override("font_size", font_size)
	if width <= 0:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if align_left:
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	return b


static func spacer(height: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, height)
	return c


## A checkbox sized and wired for a panel that lives on a Viewport2DIn3D.
##
## ACTION_MODE_BUTTON_RELEASE, never PRESS: every click inside a Viewport2DIn3D
## arrives as TWO presses, so a press-mode toggle flips twice and lands back where
## it started. Every panel that hand-rolled a CheckBox had to rediscover that.
static func check(text: String, font_size := 18, height := 38) -> CheckBox:
	var cb := CheckBox.new()
	cb.text = text
	cb.add_theme_font_size_override("font_size", font_size)
	cb.custom_minimum_size = Vector2(0, height)
	cb.action_mode = BaseButton.ACTION_MODE_BUTTON_RELEASE
	return cb


## A caption on the left, a VRToggle switch on the right — the shape every
## boolean row in OPTIONS has. Adds the row to `parent` and returns the switch,
## since the row itself is never touched again.
static func switch_row(parent: Container, text: String, initial_on := false,
		font_size := 18, height := 56) -> VRToggle:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, height)
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	var lbl := Label.new()
	lbl.text = text
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", COLOR_LICENSE)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lbl)

	var sw := VRToggle.create(initial_on)
	row.add_child(sw)
	return sw


## The "float in place" row every pickable device with an options panel carries.
## One builder so the wording, and what the wording promises, is the same on all
## of them — see FloatLock.
static func float_toggle(parent: Container) -> VRToggle:
	var sw := switch_row(parent, "Float in place (ignore gravity)")
	sw.tooltip_text = "Keep this where you put it instead of letting it fall"
	return sw


## The vertical scroll every view's root uses. Horizontal is off throughout: the
## panel is a fixed width and a sideways scroll in VR is a way to lose the UI.
static func vscroll() -> ScrollContainer:
	var s := ScrollContainer.new()
	s.size_flags_vertical = Control.SIZE_EXPAND_FILL
	s.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	fat_vscroll_bar(s)
	return s


## Size the vertical scrollbar as something a laser can actually hit.
##
## Every panel used to ask for this with a `scrollbar_v_width` theme constant,
## which is a Godot 3 name — Godot 4 takes the bar's width from the bar's own
## styleboxes and minimum size, so the override was discarded and the panels drew
## an 8 px bar with an 8 px grabber floor. The spawn panel is 2200 px across
## 1.1 m at ui_scale 2, so one logical pixel is one millimetre: that default is
## an 8 mm x 10 mm target held at arm's length, under the laser's own jitter.
##
## `min_grabber` is PADDING on the grabber box, not a size. ScrollBar adds its
## grabber stylebox's minimum size to the proportional length, so it raises the
## floor without touching the range — which is what the cartridge list needs,
## where 2744 rows come to 274,400 px of content and size the grabber at a
## quarter of a percent of the track, collapsing it onto that floor.
static func fat_vscroll_bar(scroll: ScrollContainer, width := 40, min_grabber := 60) -> void:
	var bar := scroll.get_v_scroll_bar()
	if bar == null:
		return
	bar.custom_minimum_size.x = width

	@warning_ignore("integer_division")
	var radius := width / 2
	bar.add_theme_stylebox_override("scroll", _track(COLOR_SCROLL_TRACK, radius, width))
	bar.add_theme_stylebox_override("scroll_focus", _track(COLOR_SCROLL_TRACK, radius, width))
	bar.add_theme_stylebox_override("grabber", _grabber(COLOR_SCROLL_GRAB, radius, min_grabber))
	bar.add_theme_stylebox_override("grabber_highlight", _grabber(COLOR_SCROLL_GRAB_HI, radius, min_grabber))
	bar.add_theme_stylebox_override("grabber_pressed", _grabber(COLOR_SCROLL_GRAB_ON, radius, min_grabber))


## The track. Its side margins are load bearing: ScrollContainer insets its
## content by the bar's THEME minimum width, not by `custom_minimum_size`, so a
## track with no margins gets a 40 px bar drawn straight over the right-hand
## column of tiles. Vertical margins are left alone — those would come off the
## track length instead.
static func _track(color: Color, radius: int, width: int) -> StyleBoxFlat:
	var s := rounded(color, radius)
	s.content_margin_left = width / 2.0
	s.content_margin_right = width / 2.0
	return s


static func _grabber(color: Color, radius: int, min_length: int) -> StyleBoxFlat:
	var s := rounded(color, radius)
	s.content_margin_top = min_length / 2.0
	s.content_margin_bottom = min_length / 2.0
	return s


static func vbox(separation: int, fill := true) -> VBoxContainer:
	var b := VBoxContainer.new()
	if fill:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_constant_override("separation", separation)
	return b


static func hbox(separation: int) -> HBoxContainer:
	var b := HBoxContainer.new()
	b.add_theme_constant_override("separation", separation)
	return b


## True when the headset is actually running.
##
## get_viewport().use_xr is false inside the menu's SubViewport even with the
## headset active — only the root window viewport is flagged, by xr_init.gd — so
## this asks OpenXR directly and is correct from any viewport.
static func is_vr_mode() -> bool:
	var xr := XRServer.find_interface("OpenXR")
	return xr != null and xr.is_initialized()


## Byte counts as the menu shows them — download sizes, cache budgets. Here
## rather than in a view because both OPTIONS and the RomM toasts print them,
## and the two must agree on the rounding.
static func human_bytes(bytes: int) -> String:
	if bytes >= 1073741824:
		return "%.1f GB" % (float(bytes) / 1073741824.0)
	if bytes >= 1048576:
		return "%.0f MB" % (float(bytes) / 1048576.0)
	if bytes >= 1024:
		return "%.0f KB" % (float(bytes) / 1024.0)
	return "%d B" % bytes


## The root every *_2d options panel puts inside its viewport: a full-rect
## PanelContainer carrying a rounded background, wrapping a MarginContainer.
## Returns the margin, which is what the caller fills.
##
## Ten of the eleven panels built this by hand, identically bar the radius and
## the padding. The eleventh (the dropdown) adds a border and anchors without
## offsets, so it keeps its own and is not forced through a flag.
static func panel_root(parent: Node, color: Color, radius: int,
		pad: int) -> MarginContainer:
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_theme_stylebox_override("panel", rounded(color, radius))
	parent.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["margin_top", "margin_bottom", "margin_left", "margin_right"]:
		margin.add_theme_constant_override(side, pad)
	panel.add_child(margin)
	return margin
