## MenuToasts — the stack of status bars along the bottom of the spawn menu.
##
## Two kinds of bar live here and they are the same widget:
##
##  * toasts — one per in-flight operation, keyed, updated in place. A download,
##    a sync, a cache eviction. Several can be up at once, so they stack; past
##    MAX_VISIBLE they collapse into a "+N more" row rather than running off the
##    top of the panel.
##  * the status bar — a single bar at the bottom of the stack for whatever the
##    menu is doing right now ("Hashing ROM…"), or a transient notice ("Drop
##    Item From Hand First"). Never counted toward the cap and never hidden by
##    it, and pinned last because that is where it sat when it was anchored
##    straight onto the page.
##
## The whole stack is lifted onto its own quad in front of the menu by
## ToastPanel, the same way a dropdown's option list is — so it reads as
## floating in front of the panel rather than painted on it. Falls back to the
## anchors below when there is no 3D host (a plain 2D scene, or a probe).
class_name MenuToasts
extends VBoxContainer

## Bars visible before the rest collapse into "+N more".
const MAX_VISIBLE := 4

## How long an auto-dismissing bar stays up. A failure gets far longer than a
## success: 2.5 s is not enough to read a failure reason through a headset.
const DWELL_OK   := 2.5
const DWELL_INFO := 3.0
const DWELL_FAIL := 6.0

const BAR_BG := Color(0.05, 0.10, 0.28, 0.96)
const OVERFLOW_BG := Color(0.05, 0.10, 0.28, 0.80)
const PROGRESS_FILL := Color(0.45, 0.70, 1.0)
const PROGRESS_TRACK := Color(0.25, 0.25, 0.38)

## key -> { bar, label, icon, progress }
var _toasts: Dictionary = {}
var _panel: ToastPanel = null
var _overflow_bar: PanelContainer = null
var _overflow_label: Label = null

var _status_bar: PanelContainer = null
var _status_label: Label = null
## Bumped per notice so a stale auto-hide can't clear a newer message.
var _notice_token := 0
## Widest a bar's text may run before it wraps, in pixels; 0 leaves it on one
## line. Set by ToastPanel from the width its quad may occupy — on the spawn menu
## that is over a thousand pixels and nothing ever wraps, but a memory card's
## panel is 420 px wide and a sentence has to fold to be read at all.
var _wrap_width := 0.0

## Chrome either side of a bar's text: the margins, the icon and its gap.
const BAR_CHROME := 60.0


static func create() -> MenuToasts:
	var t := MenuToasts.new()
	t.add_theme_constant_override("separation", 6)
	t.alignment = BoxContainer.ALIGNMENT_END
	# Anchored to the bottom, above where the status bar used to sit alone.
	t.anchor_left   = 0.1
	t.anchor_right  = 0.9
	t.anchor_top    = 1.0
	t.anchor_bottom = 1.0
	t.offset_top    = -300.0
	t.offset_bottom = -62.0
	t.grow_vertical = Control.GROW_DIRECTION_BEGIN
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return t


## Adopt onto the 3D quad. Deferred to the first bar rather than done on entry:
## the host Viewport2Din3D is one hop out through the viewport, and that is only
## resolvable once this is in the tree.
func _ensure_panel() -> void:
	if is_instance_valid(_panel):
		return
	var vp := get_viewport()
	if vp == null:
		return
	_panel = ToastPanel.adopt(vp.get_parent() as XRToolsViewport2DIn3D, self)


## Re-measure the quad. Deferred so it lands after _enforce_cap's visibility
## pass and after any other bars raised in the same frame; refresh() is
## idempotent, so extra calls cost nothing.
func refresh() -> void:
	if is_instance_valid(_panel):
		_panel.refresh.call_deferred()


## Fold each bar's text to fit `px` of quad. Called by ToastPanel before it
## measures, so the width it then reads back already accounts for the wrapping.
##
## The wrap width is also the label's MINIMUM width. Autowrap alone would let a
## label shrink to its longest word, which the quad would then size itself to —
## every message a narrow column.
func set_wrap_width(px: float) -> void:
	var text_w := maxf(px - BAR_CHROME, 80.0)
	if is_equal_approx(_wrap_width, text_w):
		return
	_wrap_width = text_w
	# The message labels only. A bar's icon is a Label too, and giving that one a
	# minimum width would push every bar out by the width it was told to fit in.
	for t: Dictionary in _toasts.values():
		_apply_wrap(t.get("label"))
	_apply_wrap(_status_label)


## The minimum width is the text's OWN width, capped at the wrap width — not the
## wrap width itself. A bar hugs its message (the quad is sized to the widest
## one, so a filling bar would stretch them all), and on the spawn menu, where
## the cap is over a thousand pixels, nothing is ever wide enough to fold.
func _apply_wrap(lbl: Variant) -> void:
	if _wrap_width <= 0.0 or lbl == null or not is_instance_valid(lbl):
		return
	var l := lbl as Label
	var font := l.get_theme_font("font")
	if font == null:
		return
	var natural := font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
		l.get_theme_font_size("font_size")).x
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# +2: this measurement and the Label's own can disagree by a pixel, and one
	# pixel short with autowrap on drops the last word onto a line of its own.
	l.custom_minimum_size.x = minf(natural + 2.0, _wrap_width)


# ── Toasts ────────────────────────────────────────────────────────────────────

## Keyed so each concurrent operation owns one bar and updates it in place —
## never one bar per progress tick or per retry.
##
## key      : stable per operation, e.g. "romm:dl:1289". Use a namespace prefix
##            so it can't collide with the scraper's "box"/"wheel"/… keys.
## progress : 0.0-1.0 to show a bar, or <0 for none.
## seconds  : >0 auto-dismisses after that long; <=0 keeps it until replaced.
func notify(key: String, icon_text: String, msg: String,
			progress: float = -1.0, seconds: float = 0.0) -> void:
	if _toasts.has(key):
		_update(key, icon_text, msg, progress)
	else:
		_add(key, icon_text, msg, progress)
	if seconds > 0.0:
		get_tree().create_timer(seconds).timeout.connect(clear.bind(key))


## Drop a toast immediately (e.g. an operation was cancelled).
func clear(key: String) -> void:
	if not _toasts.has(key):
		return
	var toast: Dictionary = _toasts[key]
	var bar: PanelContainer = toast.get("bar")
	if is_instance_valid(bar):
		remove_child(bar)
		bar.queue_free()
	_toasts.erase(key)
	_enforce_cap()
	refresh()


## Replace a toast's text with an outcome and let it expire. `seconds` defaults
## to 2.5; failures pass a longer dwell, because 2.5 s is not enough to read a
## failure reason through a headset.
func finish(key: String, icon_text: String, msg: String, seconds: float = 2.5) -> void:
	if not _toasts.has(key):
		# No "started" toast (e.g. failed before the request began) — make one so
		# the outcome is still surfaced.
		_add(key, icon_text, msg, -1.0)
	else:
		_update(key, icon_text, msg, -1.0)
	get_tree().create_timer(seconds).timeout.connect(clear.bind(key))


func _update(key: String, icon_text: String, msg: String, progress: float = -1.0) -> void:
	if not _toasts.has(key):
		return
	var toast: Dictionary = _toasts[key]
	var lbl: Label = toast.get("label")
	var icn: Label = toast.get("icon")
	var bar: ProgressBar = toast.get("progress")
	if is_instance_valid(lbl):
		lbl.text = msg
		_apply_wrap(lbl)
	if is_instance_valid(icn):
		icn.text = icon_text
	if is_instance_valid(bar):
		bar.visible = progress >= 0.0
		bar.value = clampf(progress, 0.0, 1.0) * 100.0
	# The quad is sized to the widest bar, and the text just changed.
	refresh()


func _add(key: String, icon_text: String, msg: String, progress: float) -> void:
	_ensure_panel()
	var built := _make_bar(icon_text, msg, progress, true)
	add_child(built["bar"])
	# After it is in the tree: the wrap is measured with the theme's font, and a
	# Control outside the tree has none to ask.
	_apply_wrap(built["label"])
	_toasts[key] = built
	_enforce_cap()
	refresh()


# ── Status bar / notices ──────────────────────────────────────────────────────

## Show or replace the single bar at the bottom of the stack.
func status(msg: String) -> void:
	if is_instance_valid(_status_bar):
		if _status_label != null:
			_status_label.text = msg
			_apply_wrap(_status_label)
			refresh()
		return
	_ensure_panel()
	var built := _make_bar("⏳", msg, -1.0, false)
	_status_bar = built["bar"]
	_status_label = built["label"]
	# Last child: it always sat below the toasts, and the stack grows upward.
	add_child(_status_bar)
	move_child(_status_bar, -1)
	_apply_wrap(_status_label)
	refresh()


## Update the text only, if the bar is up. Connected to the scraper's progress.
func status_update(msg: String) -> void:
	if is_instance_valid(_status_label):
		_status_label.text = msg
		_apply_wrap(_status_label)
		refresh()


func status_clear() -> void:
	if is_instance_valid(_status_bar):
		if _status_bar.get_parent() != null:
			_status_bar.get_parent().remove_child(_status_bar)
		_status_bar.queue_free()
	_status_bar = null
	_status_label = null
	refresh()


## A transient message in the status slot — e.g. "Drop Item From Hand First".
## Auto-hides, but only if nothing newer has replaced the text meanwhile.
func notice(msg: String, seconds := 2.5) -> void:
	status(msg)
	_notice_token += 1
	var tok := _notice_token
	get_tree().create_timer(seconds).timeout.connect(func() -> void:
		if tok == _notice_token and _status_label != null \
				and is_instance_valid(_status_label) \
				and _status_label.text == msg:
			status_clear())


# ── The bar itself ────────────────────────────────────────────────────────────

## One rounded bar: icon, message, and — for a toast — a progress track under
## them. Both kinds of bar in this stack are this, which is why it is one
## function: the toast and the status bar were the same forty lines twice.
##
## `with_progress` off leaves out the track AND its VBox wrapper, so a status
## bar is built exactly as it was authored. A toast always gets the track and
## hides it when `progress` is negative, so it can appear later without a
## rebuild.
func _make_bar(icon_text: String, msg: String, progress: float,
			   with_progress: bool) -> Dictionary:
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", MenuStyle.rounded(BAR_BG, 8))
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Hug the text rather than filling the stack — the quad is sized to the
	# widest bar, so a filling bar would stretch every one of them to that width.
	bar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

	var margin := MarginContainer.new()
	for side in ["margin_top", "margin_bottom", "margin_left", "margin_right"]:
		margin.add_theme_constant_override(side, 8)
	bar.add_child(margin)

	var hbox := MenuStyle.hbox(10)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER

	var icon := Label.new()
	icon.text = icon_text
	icon.add_theme_font_size_override("font_size", 18)
	# symbols() keeps the theme font as its base and only chains the Nerd Font
	# behind it, so emoji callers are unaffected while a MenuIcons codepoint
	# resolves to a glyph instead of tofu. See the invariant in menu_icons.gd.
	icon.add_theme_font_override("font", MenuIcons.symbols())
	hbox.add_child(icon)

	var label := MenuStyle.label(msg, 18, MenuStyle.COLOR_TITLE)
	hbox.add_child(label)

	var prog: ProgressBar = null
	if not with_progress:
		margin.add_child(hbox)
		return {"bar": bar, "label": label, "icon": icon, "progress": null}

	# Progress track, stacked under the icon+text line.
	var vbox := MenuStyle.vbox(4, false)
	vbox.add_child(hbox)
	margin.add_child(vbox)

	prog = ProgressBar.new()
	prog.mouse_filter = Control.MOUSE_FILTER_IGNORE
	prog.show_percentage = false
	prog.custom_minimum_size = Vector2(0, 5)
	prog.value = maxf(progress, 0.0) * 100.0
	prog.visible = progress >= 0.0
	prog.add_theme_stylebox_override("fill", MenuStyle.rounded(PROGRESS_FILL, 3))
	prog.add_theme_stylebox_override("background", MenuStyle.rounded(PROGRESS_TRACK, 3))
	vbox.add_child(prog)

	return {"bar": bar, "label": label, "icon": icon, "progress": prog}


# ── Overflow cap ──────────────────────────────────────────────────────────────

## Keep at most MAX_VISIBLE bars on screen; older ones collapse into a single
## "+N more" row at the top. Without this, a queue of downloads pushes bars off
## the top of the menu panel.
func _enforce_cap() -> void:
	# The status bar shares the stack but is not a toast: never hidden by the
	# cap, never counted toward it, and pinned to the bottom.
	if is_instance_valid(_status_bar) \
			and _status_bar.get_parent() == self:
		move_child(_status_bar, -1)

	var bars: Array[Control] = []
	for c: Node in get_children():
		if c == _overflow_bar or c == _status_bar:
			continue
		if c is Control:
			bars.append(c)

	var overflow := maxi(0, bars.size() - MAX_VISIBLE)
	# Newest are appended last, so hide from the front.
	for i in bars.size():
		bars[i].visible = i >= overflow

	if overflow <= 0:
		if is_instance_valid(_overflow_bar):
			_overflow_bar.queue_free()
		_overflow_bar = null
		_overflow_label = null
		return

	if _overflow_bar == null or not is_instance_valid(_overflow_bar):
		_overflow_bar = PanelContainer.new()
		_overflow_bar.add_theme_stylebox_override("panel",
			MenuStyle.rounded(OVERFLOW_BG, 8))
		_overflow_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_overflow_bar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

		var m := MarginContainer.new()
		for side in ["margin_top", "margin_bottom", "margin_left", "margin_right"]:
			m.add_theme_constant_override(side, 6)
		_overflow_bar.add_child(m)

		_overflow_label = MenuStyle.label("", 15, MenuStyle.COLOR_DESC)
		_overflow_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		m.add_child(_overflow_label)

		add_child(_overflow_bar)

	move_child(_overflow_bar, 0)
	_overflow_label.text = "+%d more" % overflow
