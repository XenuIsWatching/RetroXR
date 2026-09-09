## PS2Icon — a PlayStation 2 save's icon, which is a 3-D model rather than a
## sprite.
##
## Every other console here draws a save with a small bitmap. The PS2 draws a
## lit, animated, textured mesh: `icon.sys` names the save and names three model
## files (one for sitting in the browser, one for being copied, one for being
## deleted), and each `.icn` holds the geometry, a 128x128 texture, and a set of
## morph targets the animation blends between.
##
## Parsing stays here, as data. Nothing in this file touches a scene or a
## viewport, so a malformed icon is a test case rather than something only a
## headset can find. Transliterated from Play!'s Save.cpp and Icon.cpp.
##
## GDScript has no exceptions, and an out-of-range index aborts the function it
## happens in without a word — which in a test suite looks exactly like a case
## that was never written. Every read here is bounds-checked so a truncated file
## returns {} instead.
class_name PS2Icon
extends RefCounted

# --- icon.sys -----------------------------------------------------------------

const SYS_MAGIC       := 0x44325350   ## "PS2D", little-endian
const SYS_LINE_BREAK  := 0x06
const SYS_TITLE       := 0xC0
const SYS_TITLE_LEN   := 68
const SYS_ICON_NAMES  := SYS_TITLE + SYS_TITLE_LEN    # 0x104
const SYS_NAME_LEN    := 64

# --- .icn ---------------------------------------------------------------------

const ICN_MAGIC     := 0x010000
const ICN_ANIM_TAG  := 0x01
const TEX_SIZE      := 128
const FIXED_ONE     := 4096.0

## Texture encodings the file may declare. 6 and 7 store the 128x128 field
## outright; 12, 14 and 15 store it run-length encoded.
const TEX_RAW := [6, 7]
const TEX_RLE := [12, 14, 15]

const VERTEX_SIZE := 8    ## 4 x int16
const ATTRIB_SIZE := 16   ## normal (4 x int16), uv (2 x int16), color (u32)


## The save's name and the three model files it points at, or {}.
##
## The three names are stored normal, copying, deleting — note that Play!'s own
## accessor enum lists them in a different order, so the file is the authority.
static func parse_icon_sys(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < SYS_ICON_NAMES + SYS_NAME_LEN * 3:
		return {}
	if bytes.decode_u32(0) != SYS_MAGIC:
		return {}
	var names: Array[String] = []
	for i in 3:
		names.append(_ascii(bytes, SYS_ICON_NAMES + i * SYS_NAME_LEN, SYS_NAME_LEN))
	# A title is written as TWO lines with no separator between them, and the
	# console breaks it at a byte offset the file carries. Decoding the field as
	# one run gives "Prince Of PersiaSOT 00"; splitting at the offset first is
	# what makes it read as a title and a subtitle.
	var raw := bytes.slice(SYS_TITLE, SYS_TITLE + SYS_TITLE_LEN)
	var brk := bytes.decode_u16(SYS_LINE_BREAK)
	var title := Sjis.to_ascii(raw)
	if brk > 0 and brk < raw.size():
		var head := Sjis.to_ascii(raw.slice(0, brk))
		var tail := Sjis.to_ascii(raw.slice(brk))
		if not head.is_empty() and not tail.is_empty():
			title = "%s %s" % [head, tail]
	return {
		"title": title,
		"line_break": brk,
		"icon_normal": names[0],
		"icon_copying": names[1],
		"icon_deleting": names[2],
	}


static func _ascii(bytes: PackedByteArray, from: int, length: int) -> String:
	var end := from
	while end < from + length and end < bytes.size() and bytes[end] != 0:
		end += 1
	return bytes.slice(from, end).get_string_from_ascii()


## One .icn: the morph targets, the shared UVs and colors, the animation's
## per-frame blend keys, and the texture. {} when the file is not one.
##
## Vertices are stored interleaved — for each vertex, one position per shape,
## then that vertex's single attribute record. So the shapes are morph targets
## over one topology, and the triangles are the vertex list taken in threes.
static func parse_icn(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 20:
		return {}
	if bytes.decode_u32(0) != ICN_MAGIC:
		return {}
	var shape_count := bytes.decode_u32(4)
	var texture_type := bytes.decode_u32(8)
	var vertex_count := bytes.decode_u32(16)
	if shape_count <= 0 or vertex_count <= 0:
		return {}
	if shape_count > 64 or vertex_count > 200000:
		return {}

	var stride := shape_count * VERTEX_SIZE + ATTRIB_SIZE
	var need := 20 + vertex_count * stride
	if bytes.size() < need:
		return {}

	var shapes: Array[PackedVector3Array] = []
	for s in shape_count:
		var pts := PackedVector3Array()
		pts.resize(vertex_count)
		shapes.append(pts)
	var uvs := PackedVector2Array()
	uvs.resize(vertex_count)
	var colors := PackedColorArray()
	colors.resize(vertex_count)
	var raw_colors := PackedInt32Array()
	raw_colors.resize(vertex_count * 3)
	# The attribute record carries a normal per vertex. Kept so the mesh is
	# well-formed, though the view draws these unshaded — the shading an artist
	# meant is already in the vertex colors.
	var normals := PackedVector3Array()
	normals.resize(vertex_count)

	var pos := 20
	for v in vertex_count:
		for s in shape_count:
			# Y is NEGATED: the PS2 authors these with +Y pointing DOWN, so a
			# straight read stands every icon on its head. Checked against a
			# model that can show it — Indiana Jones' hat, which is unmistakable
			# upside down and unreadable on anything symmetrical.
			shapes[s][v] = Vector3(
				bytes.decode_s16(pos) / FIXED_ONE,
				-bytes.decode_s16(pos + 2) / FIXED_ONE,
				bytes.decode_s16(pos + 4) / FIXED_ONE)
			pos += VERTEX_SIZE
		var n := Vector3(
			bytes.decode_s16(pos) / FIXED_ONE,
			-bytes.decode_s16(pos + 2) / FIXED_ONE,
			bytes.decode_s16(pos + 4) / FIXED_ONE)
		normals[v] = n.normalized() if n.length_squared() > 0.0 else Vector3.UP
		uvs[v] = Vector2(
			bytes.decode_s16(pos + 8) / FIXED_ONE,
			bytes.decode_s16(pos + 10) / FIXED_ONE)
		# Kept RAW here. What a channel means depends on whether this icon has a
		# texture, and that is not known until the texture has been read.
		raw_colors[v * 3 + 0] = bytes.decode_u32(pos + 12) & 0xFF
		raw_colors[v * 3 + 1] = (bytes.decode_u32(pos + 12) >> 8) & 0xFF
		raw_colors[v * 3 + 2] = (bytes.decode_u32(pos + 12) >> 16) & 0xFF
		pos += ATTRIB_SIZE

	# The geometry is the icon. An animation header this does not recognize, or a
	# texture encoding it cannot decode, costs the animation or the texture — not
	# the whole model. Several real saves carry one or the other and would
	# otherwise show nothing at all where a plain shape would have done.
	var anim := _parse_animation(bytes, pos)
	var texture: Image = null
	if not anim.is_empty():
		texture = _parse_texture(bytes, int(anim["end"]), texture_type)

	# What a vertex color means depends on whether a texture modulates it, and
	# the two scales differ by a factor of two:
	#
	#   textured   the GS multiplies and shifts down by 7, so 0x80 is NEUTRAL and
	#              the texture shows through unchanged. Every textured icon on the
	#              test card reads 127 or 128 flat, which is what that looks like.
	#   untextured the color IS the surface, an ordinary 0-255. Indiana Jones'
	#              hat is (35, 14, 5) here and (35, 14, 5) in an independent rip
	#              of the same model — a very dark brown, and nothing like the
	#              light tan that dividing by 128 produces.
	#
	# Alpha is forced opaque throughout: an icon whose alpha is never filled
	# reads as a fully transparent model, which looks like nothing rendered.
	# And converted OUT of sRGB. A console's byte is display-referred, while a
	# renderer multiplies light in linear space, so handing the byte over as-is
	# both brightens a color and flattens it toward gray: (35, 14, 5) has a 7:3:1
	# ratio and comes out 1.6:1.2:1, which is what "washed out" looks like
	# measured rather than eyeballed.
	var scale := 128.0 if texture != null else 255.0
	for v in vertex_count:
		colors[v] = Color(
			minf(raw_colors[v * 3 + 0] / scale, 1.0),
			minf(raw_colors[v * 3 + 1] / scale, 1.0),
			minf(raw_colors[v * 3 + 2] / scale, 1.0),
			1.0).srgb_to_linear()

	return {
		"shape_count": shape_count,
		"vertex_count": vertex_count,
		"shapes": shapes,
		"uvs": uvs,
		"colors": colors,
		"normals": normals,
		"frames": anim.get("frames", []),
		"frame_length": anim.get("frame_length", 0),
		"anim_speed": anim.get("anim_speed", 1.0),
		"texture": texture,
	}


static func _parse_animation(bytes: PackedByteArray, from: int) -> Dictionary:
	if from + 20 > bytes.size():
		return {}
	if bytes.decode_u32(from) != ICN_ANIM_TAG:
		return {}
	var frame_length := bytes.decode_u32(from + 4)
	var anim_speed := bytes.decode_float(from + 8)
	var frame_count := bytes.decode_u32(from + 16)
	if frame_count < 0 or frame_count > 4096:
		return {}
	var pos := from + 20
	var frames: Array[Dictionary] = []
	for i in frame_count:
		if pos + 8 > bytes.size():
			return {}
		var shape_id := bytes.decode_u32(pos)
		var key_count := bytes.decode_u32(pos + 4)
		pos += 8
		if key_count < 0 or key_count > 4096 or pos + key_count * 8 > bytes.size():
			return {}
		var keys := PackedVector2Array()
		keys.resize(key_count)
		for k in key_count:
			# Each key is a time and the blend weight of this frame's shape at
			# that time; the model is the shapes mixed by those weights.
			keys[k] = Vector2(bytes.decode_float(pos), bytes.decode_float(pos + 4))
			pos += 8
		frames.append({"shape_id": shape_id, "keys": keys})
	return {
		"frames": frames,
		"frame_length": frame_length,
		"anim_speed": anim_speed,
		"end": pos,
	}


static func _parse_texture(bytes: PackedByteArray, from: int, texture_type: int) -> Image:
	if not (texture_type in TEX_RAW or texture_type in TEX_RLE):
		return null
	var pixels := PackedInt32Array()
	pixels.resize(TEX_SIZE * TEX_SIZE)
	pixels.fill(0)

	if texture_type in TEX_RAW:
		if from + TEX_SIZE * TEX_SIZE * 2 > bytes.size():
			return null
		for i in TEX_SIZE * TEX_SIZE:
			pixels[i] = bytes.decode_u16(from + i * 2)
	else:
		if from + 4 > bytes.size():
			return null
		var length := bytes.decode_u32(from)
		var pos := from + 4
		var end := mini(pos + length, bytes.size())
		var out := 0
		while pos + 2 <= end and out < pixels.size():
			var code := bytes.decode_u16(pos)
			pos += 2
			if code & 0xFF00 == 0xFF00:
				# A literal run: this many 16-bit pixels follow, verbatim.
				var run := (0x10000 - code) & 0xFFFF
				for i in run:
					if pos + 2 > end or out >= pixels.size():
						break
					pixels[out] = bytes.decode_u16(pos)
					out += 1
					pos += 2
			else:
				if pos + 2 > end:
					break
				var value := bytes.decode_u16(pos)
				pos += 2
				for i in code:
					if out >= pixels.size():
						break
					pixels[out] = value
					out += 1

	var raw := PackedByteArray()
	raw.resize(TEX_SIZE * TEX_SIZE * 4)
	for i in pixels.size():
		var v := pixels[i]
		# 16-bit BGR555. The top bit is the PS2's semi-transparency flag, not an
		# alpha channel — honouring it would paint most icons invisible.
		raw[i * 4 + 0] = ((v & 0x1F) * 255) / 31
		raw[i * 4 + 1] = (((v >> 5) & 0x1F) * 255) / 31
		raw[i * 4 + 2] = (((v >> 10) & 0x1F) * 255) / 31
		raw[i * 4 + 3] = 255
	return Image.create_from_data(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8, raw)
