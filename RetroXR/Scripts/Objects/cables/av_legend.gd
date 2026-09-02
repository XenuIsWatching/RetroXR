## The printed legend around a device's composite sockets — the outlined box, the
## words under the jacks, the AV IN / AV OUT heading naming which way the signal
## flows, and an optional `title` above them naming the group itself. What a real
## back panel silk-screens there, and the only thing on the cabinet that says those
## three chrome rings are what you plug into.
##
## MEASURED off the sockets rather than authored per device, because devices do not
## agree on the row. Seen from outside the panel the decks read R, L, VIDEO while the
## television reads VIDEO, L, R: both author ascending x, and device +X is on the
## viewer's LEFT from behind, so the same numbers come out in opposite orders. A
## legend that reads the sockets it labels cannot print R-AUDIO-L over a row running
## the other way. Nor is the row always on the back — a shell can mould its jacks on
## a flank — so the panel's own frame is derived too, and nothing here assumes -Z.
class_name AvLegend
extends Node3D


## How far back from a port's origin the panel face is. rca_port.tscn seats the zone
## 10 mm proud and pushes the jack back by that much so its flange lands on the
## panel, so backing off by slightly less puts the legend half a millimetre in FRONT
## of the panel — where pc_tower.tscn's silkscreen sits, and clear of z-fighting.
const PANEL_STANDOFF := 0.0095

## Flange radius of the socket being surrounded (gen_rca_jack.gd FLANGE_R). What the
## words have to clear, and the minimum half-width of the plate.
const JACK_RADIUS := 0.0048

## font_size is the size the glyphs are RASTERISED at, not the size they come out.
## Asking for a 5 mm font builds a five-pixel-tall atlas and magnifies a smear, so
## every label here is rastered large and scaled down through pixel_size. Same recipe
## pc_tower.tscn documents for its own back-panel silkscreen.
const RASTER := 48

## Unshaded, all three. These rooms light with a flat ambient and no radiance map, so
## a shaded near-black plate renders at whatever the ambient gives it and the border
## that has to read against a dark deck stops reading. Darkness by MATERIAL is the
## same call gen_rca_jack.gd makes for the socket bore.
const INK := Color(0.90, 0.90, 0.87)
const PLATE := Color(0.055, 0.055, 0.065)
const BORDER := Color(0.72, 0.72, 0.69)

## The rule between adjacent groups. Brighter than BORDER on purpose: the border
## outlines the whole bank and should sit back, while this is the line that has to
## say which three sockets belong together.
const DIVIDER := Color(0.95, 0.95, 0.92)

## Worn only when the plate is off, where the cabinet behind the words could be any
## colour — a white monitor back or a black one. Light ink inside a dark outline
## reads on both. On the plate it is the plate that supplies the contrast, and an
## outline there only fuses the glyphs into a blob.
const OUTLINE := Color(0.03, 0.03, 0.04)
const OUTLINE_RASTER := 12

## Stacking order out of the panel. 0.2 mm apart is plenty to keep the border, the
## plate and the text off each other's depth values at arm's length.
const Z_BORDER := 0.0
const Z_PLATE := 0.0002
const Z_TEXT := 0.0006


## Panel face to the row centre. Left exported so a bespoke shell whose jacks are not
## seated on the 10 mm convention can say so.
@export var standoff: float = PANEL_STANDOFF

## Cap line of the words under the jacks, and of the AV IN / AV OUT heading. Both
## generous against the real thing, which prints these at about 2 mm — the point is
## to be read across a room-lit cabinet, not to be to scale.
@export var word_height: float = 0.0045
@export var heading_height: float = 0.007

## Name printed ABOVE the jacks, naming this socket group among several — the
## television's "Composite 1" … "Composite 4". Empty prints nothing and leaves the
## layout exactly as it was, which is what every single-group device wants: a deck
## with one A/V row has nothing to disambiguate and says so by saying nothing.
##
## Set in the group's own words rather than derived from an index, so a device that
## numbers its inputs differently — or names them at all — needs no code here.
@export var title: String = ""

## Print the per-socket words (VIDEO, L-AUDIO-R). Off for a group whose sockets are
## not phono, where the channel names nothing a player would recognise: CoaxPort
## reports Channel.VIDEO only because the routing needs somewhere to send the
## picture, and an aerial hole labelled VIDEO is a lie about the connector.
##
## The LAYOUT is deliberately untouched by this — the words' row still takes up its
## space — so a wordless plate comes out exactly as tall as the ones printed beside
## it and a bank of them still lines up.
@export var show_words: bool = true

## Replaces the AV IN / AV OUT heading, for a socket that is an input but not an A/V
## one. The aerial hole reads RF IN.
@export var heading_override: String = ""

## Rule up the LEFT edge of the plate, dividing this group from the one printed
## beside it. Set on every group but the first, so a bank of four gets three rules
## and no line hangs off either end.
##
## Drawn by the group to its right rather than centred in the gap, because a legend
## knows its own extent and nothing about its neighbour's — and the plates all but
## touch (2.4 mm apart at the 60 mm group pitch, closer than their own borders), so
## an edge rule lands where the seam reads anyway.
@export var divider_left: bool = false

## Clear space between the outermost thing printed and the edge of the plate.
@export var plate_margin: float = 0.006

## Thickness of the light border drawn round the plate.
@export var border_width: float = 0.0008

## Off for a panel the plate would clip. A moulded CRT back is the case that needs
## it: both cabinet shells in the project taper 16 mm and 46 mm across the plate's
## own footprint, so a flat rectangle either floats off the curve or cuts into it.
## The words survive on their own — they pick up an outline in exchange.
@export var show_plate: bool = true

## Turn the whole legend within its panel, in radians, anticlockwise as seen from
## outside. The row, the words and the heading all turn together, so the layout is
## unchanged — only which way it is printed.
##
## PI/2 is the case that exists: a console stood on end carries a socket group whose
## printing was laid out for the machine lying down, so on the vertical Wii the
## phono trio stacks and its legend reads bottom-to-top. It also buys room — a
## narrow back panel that could not take the row across it has 215 mm up it.
@export var roll: float = 0.0


var _ports: Array[RcaPort] = []


## Build a legend for `ports` and hang it on `device`, which must be the node those
## ports are children of — every offset here is measured in that frame.
##
## Returns null for an empty or dead list rather than an empty node, so a caller can
## hand the result straight to a model hook.
static func attach(device: Node3D, ports: Array) -> AvLegend:
	var live: Array[RcaPort] = []
	for p in ports:
		var port := p as RcaPort
		if port != null and is_instance_valid(port):
			live.append(port)
	if live.is_empty():
		return null
	var legend := AvLegend.new()
	legend.name = "AvLegend"
	legend._ports = live
	device.add_child(legend)
	legend.rebuild()
	return legend


## Lay the legend out from scratch. Call it after changing any of the exports above;
## attach() has already called it once.
func rebuild() -> void:
	for c in get_children():
		remove_child(c)
		c.free()
	if _ports.is_empty():
		return
	transform = _panel_frame()

	# Port offsets in the legend's own frame: x runs left-to-right as seen from
	# outside the panel, y up, z out. Sorting on x is what makes the printed order
	# the order a player actually sees.
	var inv := transform.affine_inverse()
	var row: Array[RcaPort] = _ports.duplicate()
	row.sort_custom(func(a: RcaPort, b: RcaPort) -> bool:
		return (inv * a.position).x < (inv * b.position).x)
	var xs := PackedFloat32Array()
	for p in row:
		xs.append((inv * p.position).x)

	var word_text := PackedStringArray()
	var word_x := PackedFloat32Array()
	if show_words:
		_lay_out_words(row, xs, word_text, word_x)
	var heading := heading_override
	if heading.is_empty():
		heading = "AV IN" if _ports[0].direction == RcaPort.Direction.IN else "AV OUT"

	var word_y := -(JACK_RADIUS + word_height * 0.9)
	var head_y := word_y - word_height * 0.6 - heading_height * 0.8
	# Mirror of word_y about the row, so a titled group is printed symmetrically.
	var title_y := JACK_RADIUS + heading_height * 0.9

	# The plate is symmetric about the row centre, which is where the heading is
	# centred; every printed thing has to fit inside it.
	var half := _text_width(heading, heading_height) * 0.5
	if not title.is_empty():
		half = maxf(half, _text_width(title, heading_height) * 0.5)
	for i in word_text.size():
		half = maxf(half, absf(word_x[i]) + _text_width(word_text[i], word_height) * 0.5)
	for x in xs:
		half = maxf(half, absf(x) + JACK_RADIUS)
	half += plate_margin
	var top := JACK_RADIUS + plate_margin
	if not title.is_empty():
		top = title_y + heading_height * 0.8 + plate_margin
	var bottom := head_y - heading_height * 0.8 - plate_margin

	# Everything printed, as (text, x, y, height) rows; the plate rect is the
	# same whether the legend is baked or built from nodes.
	var labels: Array = []
	if not title.is_empty():
		labels.append([title, 0.0, title_y, heading_height])
	for i in word_text.size():
		labels.append([word_text[i], word_x[i], word_y, word_height])
	labels.append([heading, 0.0, head_y, heading_height])
	var size := Vector2(half * 2.0, top - bottom)
	var mid := (top + bottom) * 0.5

	# On a real renderer the whole legend is ONE textured quad: rendered once
	# into a small texture (shared by every legend that prints the same thing)
	# instead of three quads and two or three Label3Ds, each a draw of its own
	# every frame - with a television's five groups and a console's one that
	# was about twenty-five draws a set on a Quest 3. Headless has no picture
	# to bake, so it keeps the node build; nothing there reads the pixels.
	if RenderingServer.get_rendering_device() != null:
		_bake(labels, size, mid)
		return

	if show_plate:
		_add_quad(size + Vector2(border_width, border_width) * 2.0, mid, Z_BORDER, BORDER)
		_add_quad(size, mid, Z_PLATE, PLATE)
		if divider_left:
			# Above the plate in the stack, or the plate it divides covers it.
			_add_quad(Vector2(border_width, size.y), mid, Z_TEXT, DIVIDER, -half)
	for row_l: Array in labels:
		_add_label(row_l[0], row_l[1], row_l[2], row_l[3])


# ── The baked legend ─────────────────────────────────────────────────────────

## Texels per metre for the bake. A 4.5 mm word comes out 32 px tall, which is
## sharper than the 48-texel raster the Label3D path scales down from at the
## distances a back panel is read from, and a 60 mm plate is 420 px across.
const BAKE_PX_PER_M := 7000.0
## Longest side of one legend texture, in texels.
const BAKE_MAX_PX := 1024

## Baked textures by what they print - a room's eight consoles all say
## "AV OUT / VIDEO L-AUDIO-R" and share one.
static var _bakes: Dictionary = {}


func _bake(labels: Array, size: Vector2, mid: float) -> void:
	var key := "%s|%s|%s|%s|%s|%s" % [show_plate, divider_left, border_width,
		plate_margin, var_to_str(size), var_to_str(labels)]
	# The border sits outside the plate, so the quad is the border's rect;
	# without a plate the texture covers the same footprint, transparent.
	var quad_size := size + Vector2(border_width, border_width) * 2.0
	if _bakes.has(key):
		_show_baked(_bakes[key], quad_size, mid)
		return
	var px := Vector2i((quad_size * BAKE_PX_PER_M).ceil())
	var scale := 1.0
	if maxi(px.x, px.y) > BAKE_MAX_PX:
		scale = float(BAKE_MAX_PX) / float(maxi(px.x, px.y))
		px = Vector2i((Vector2(px) * scale).ceil())
	var ppm := BAKE_PX_PER_M * scale

	var sv := SubViewport.new()
	sv.size = px
	sv.disable_3d = true
	sv.transparent_bg = true
	sv.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(sv)
	# Legend frame -> texels: x right, y DOWN from the top of the quad. The
	# quad's top-left corner is at (-quad_size.x / 2, mid + quad_size.y / 2)
	# in the legend's frame.
	var left := -quad_size.x * 0.5
	var top_y := mid + quad_size.y * 0.5
	if show_plate:
		_bake_rect(sv, Rect2(Vector2.ZERO, Vector2(px)), BORDER)
		var inset := border_width * ppm
		_bake_rect(sv, Rect2(Vector2(inset, inset), Vector2(px) - Vector2(inset, inset) * 2.0), PLATE)
		if divider_left:
			_bake_rect(sv, Rect2(Vector2(inset, inset), Vector2(inset, float(px.y) - inset * 2.0)), DIVIDER)
	for row_l: Array in labels:
		var text: String = row_l[0]
		var height: float = row_l[3]
		var font_px := int(round(height * ppm))
		var lbl := Label.new()
		lbl.text = text
		var settings := LabelSettings.new()
		settings.font = ThemeDB.fallback_font
		settings.font_size = font_px
		settings.font_color = INK
		if not show_plate:
			settings.outline_size = int(round(float(OUTLINE_RASTER) * height / float(RASTER) * ppm))
			settings.outline_color = OUTLINE
		lbl.label_settings = settings
		var w := _text_width(text, height) * ppm
		# A Label3D centres its glyph box on the point; a Label's box is its
		# full line height, so centre that on the same y.
		var line_h := float(ThemeDB.fallback_font.get_height(font_px))
		lbl.position = Vector2((float(row_l[1]) - left) * ppm - w * 0.5,
			(top_y - float(row_l[2])) * ppm - line_h * 0.5)
		lbl.size = Vector2(w + 4.0, line_h)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		sv.add_child(lbl)

	await RenderingServer.frame_post_draw
	# A rebuild in the meantime - the television sets a group's title right
	# after attaching it - has freed this viewport and started its own bake.
	if not is_inside_tree() or not is_instance_valid(sv):
		return
	var img := sv.get_texture().get_image()
	sv.queue_free()
	if img == null or img.is_empty():
		return
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_bakes[key] = tex
	_show_baked(tex, quad_size, mid)


func _bake_rect(sv: SubViewport, rect: Rect2, colour: Color) -> void:
	var r := ColorRect.new()
	r.position = rect.position
	r.size = rect.size
	r.color = colour
	sv.add_child(r)


func _show_baked(tex: Texture2D, quad_size: Vector2, mid: float) -> void:
	var mesh := QuadMesh.new()
	mesh.size = quad_size
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# Scissor, not blend: the plate is opaque and the glyph edges crisp, and a
	# blended quad would drop out of the depth write on the panel.
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat.alpha_scissor_threshold = 0.5
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	var mi := MeshInstance3D.new()
	mi.name = "BakedLegend"
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = Vector3(0.0, mid, Z_PLATE)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


## The words under the jacks. An adjacent L/R pair is bracketed by ONE string spanning
## both — "R-AUDIO-L" the way the hardware prints it — which is also what keeps the
## line inside 18 mm centres, since "AUDIO R" alone is wider than the pitch. A console
## with a single audio jack (mono hardware) gets the bare word.
func _lay_out_words(row: Array[RcaPort], xs: PackedFloat32Array,
		out_text: PackedStringArray, out_x: PackedFloat32Array) -> void:
	var audio: PackedInt32Array = []
	for i in row.size():
		if row[i].channel == RcaPort.Channel.VIDEO:
			out_text.append("VIDEO")
			out_x.append(xs[i])
		else:
			audio.append(i)
	if audio.size() == 2 and absi(audio[0] - audio[1]) == 1:
		var a := audio[0]
		var b := audio[1]
		out_text.append("%s-AUDIO-%s" % [row[a].channel_name(), row[b].channel_name()])
		out_x.append((xs[a] + xs[b]) * 0.5)
		return
	for i in audio:
		out_text.append("AUDIO" if audio.size() == 1 else "AUDIO " + row[i].channel_name())
		out_x.append(xs[i])


## The panel the sockets are mounted in, as a transform in the device's frame.
##
##   n  the direction a plug arrives from, which is the panel's outward normal
##   u  the device's own up, flattened into the panel — not the world's, so a legend
##      stays printed the same way up however the cabinet is carried or tipped
##   r  u x n, the panel's right; on a rear panel this works out to Ry(180), which is
##      exactly what pc_tower.tscn hand-authors so its words read from behind
##
## `roll` then turns that frame about n, which is why a rolled legend needs no other
## special case: every offset below is measured in this frame, so they all turn with
## it and the sorting still runs along whatever "across the group" now means.
func _panel_frame() -> Transform3D:
	var n := _ports[0].transform.basis.z.normalized()
	var u := Vector3.UP - n * Vector3.UP.dot(n)
	if u.length_squared() < 1e-6:
		# A socket in a face that IS the top or the bottom: nothing to flatten, so
		# take the port's own up instead.
		var own := _ports[0].transform.basis.y
		u = own - n * own.dot(n)
	u = u.normalized()
	var centre := Vector3.ZERO
	for p in _ports:
		centre += p.position
	centre /= float(_ports.size())
	var b := Basis(u.cross(n), u, n)
	if not is_zero_approx(roll):
		# Post-multiplied, so the turn happens in the panel's own plane about its
		# normal — b.rotated() would turn it about a WORLD axis instead.
		b = b * Basis(Vector3(0.0, 0.0, 1.0), roll)
	return Transform3D(b, centre - n * standoff)


func _add_label(text: String, x: float, y: float, height: float) -> void:
	var lbl := Label3D.new()
	lbl.text = text
	lbl.font_size = RASTER
	lbl.pixel_size = height / float(RASTER)
	lbl.outline_size = 0 if show_plate else OUTLINE_RASTER
	lbl.outline_modulate = OUTLINE
	lbl.modulate = INK
	lbl.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	# Depth test STAYS on: a legend that draws through the cabinet would be readable
	# from the front of the device, where there is no panel.
	lbl.no_depth_test = false
	lbl.position = Vector3(x, y, Z_TEXT)
	add_child(lbl)


func _add_quad(size: Vector2, y: float, z: float, colour: Color, x: float = 0.0) -> void:
	var mesh := QuadMesh.new()
	mesh.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = colour
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = Vector3(x, y, z)
	add_child(mi)


## Width a label will come out, in metres. Measured off the font rather than off the
## built Label3D's AABB, which is not there until the node has drawn — the reason
## RetroSystem has to defer _place_name_label.
static func _text_width(text: String, height: float) -> float:
	var f: Font = ThemeDB.fallback_font
	if f == null:
		return 0.0
	var w: float = f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, RASTER).x
	return w * height / float(RASTER)
