## WiiDiscLabel — the fallback disc-face art for a Wii disc with no scraped
## support-label scan: a generic "home-burned" print template (RXR-R, styled
## after a real burned DVD-R), plus the placement math that puts the game
## title on the template's own "TITLE" line instead of floating in the disc's
## centre. Without it a Wii disc with no art falls back to the bare silver DVD
## finish with the title centred over it, which reads as a blank disc rather
## than an unlabelled backup.
##
## Split out of disc.gd, which stays the generic disc contract shared by every
## disc-based system; this is the one console-specific decoration on top of it.
class_name WiiDiscLabel
extends RefCounted

## Fed into the disc shader's label_tex uniform exactly like a scraped scan
## would be, so it needs no fitting of its own: full-bleed to the rim with its
## own transparent centre hole.
const TEXTURE := preload("res://Textures/Media/rxr_disc_label.svg")

## Where the template prints "TITLE", measured off its own 1200x1200 canvas
## (rxr_disc_label.svg) rather than guessed — the game title goes on the same
## line, starting just past the printed word.
const _CANVAS := 1200.0
const _TITLE_Y := 827.0
const _TITLE_X_START := 230.0
## The rim the text must stay inside at that height. The template's disc is a
## circle of radius 570 about (600,600); at y=827 that bounds x to
## 600 +/- sqrt(570^2 - (827-600)^2) =~ 600 +/- 523, backed off for a clean
## margin.
const _TITLE_X_END := 1100.0


## Move the fallback title off the disc's centre and onto the print template's
## own "TITLE" line, then shrink it to fit the printable width there — a long
## game title would otherwise run off the template's rim on one side or
## collide with the printed word on the other. Uniformly scaling pixel_size
## (rather than just wrapping) is what keeps it one line at whatever length
## the title is.
##
## `diameter` is the disc's real-world size (MediaDimensions.disc_diameter) —
## the template's own UV mapping is planar over that bounding square, the same
## convention gen_disc.gd bakes into every platter.
static func fit_title(lbl: Label3D, diameter: float) -> void:
	var u0 := _TITLE_X_START / _CANVAS
	var u1 := _TITLE_X_END / _CANVAS
	var v := _TITLE_Y / _CANVAS
	var band_w := (u1 - u0) * diameter
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_OFF
	lbl.pixel_size = 0.0004
	lbl.position = Vector3((u0 - 0.5) * diameter, lbl.position.y, (v - 0.5) * diameter)
	lbl.width = band_w / lbl.pixel_size
	lbl.visible = true
	var font: Font = lbl.font if lbl.font != null else ThemeDB.fallback_font
	var text_w: float = font.get_string_size(
		lbl.text, HORIZONTAL_ALIGNMENT_LEFT, -1, lbl.font_size).x * lbl.pixel_size
	if text_w > band_w and text_w > 0.0:
		lbl.pixel_size *= band_w / text_w
