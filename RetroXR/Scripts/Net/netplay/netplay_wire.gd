## NetplayWire — the byte layout of a lockstep input packet, in one place.
##
## Pure: every method here is a function of its arguments and a StreamPeerBuffer.
## Nothing reads session state, which is what lets the layout be tested without
## standing up two peers.
##
## ── Why this is a class and not a comment ────────────────────────────────────
## The sizes below are budgeted by READERS before they unpack, and produced by
## WRITERS a few hundred lines away. When those two disagree the packet is not
## corrupt and nothing errors — the reader simply decides it is short and
## returns, dropping input for that frame.
##
## It has happened. Three call sites carried the aux size by hand and said 15
## where the writer produced 13, so every reader demanded two bytes more than
## existed and bailed on the LAST frame of every packet. The redundancy window
## hid that for streamed frames and could not hide it for a re-request, which
## sends one frame and had it dropped every time.
##
## Naming AUX_BYTES_PER_PORT fixed that instance. It did not fix the class of
## bug: the surrounding arithmetic — a header, a per-port block, then one aux
## and key block per machine — was still written out at four call sites, with
## the per-port width as a bare 10 or 11. local_frame_bytes and
## broadcast_frame_bytes are those four expressions, written once, so a writer
## and its reader cannot drift apart again.
class_name NetplayWire
extends RefCounted


## Ports a single machine contributes to an assembled frame. A wire fact, not a
## hardware one: a machine with two pads still occupies four slots, and a linked
## pair addresses its ports as machine * PORTS_PER_MACHINE + port.
const PORTS_PER_MACHINE := 4

# Aux input is per controller port: two accelerometers, two gyroscopes and four
# pointer/IR contacts. Layout is flags, accel[2]*xyz, gyro[2]*xyz, pointer[4]*
# {x,y,pressed}. Flags bits 0..1 = accel, 2..3 = gyro, 4..7 = pointer valid.
# Values are milli-g / centi-radians-per-second / signed libretro coordinates.
const AUX_SENSOR_COUNT := 2
const AUX_POINTER_COUNT := 4
const AUX_INTS_PER_PORT := 25
const AUX_INTS := PORTS_PER_MACHINE * AUX_INTS_PER_PORT

## Keyboard events ride with the port-0 owner, up to this many per frame.
const KEY_SLOTS := 4

## One port on the wire: u16 buttons + four signed 16-bit axes. The INDEXED form
## carries a u8 port number in front, which a client's own window needs (it
## sends only the ports it owns) and a host broadcast does not (it sends every
## port, in order).
const PORT_BYTES := 10
const PORT_BYTES_INDEXED := PORT_BYTES + 1

## u8 flags + 12 signed 16-bit sensor values + four pointers of {i16, i16, u8}.
const AUX_BYTES_PER_PORT := 45
const AUX_BYTES := PORTS_PER_MACHINE * AUX_BYTES_PER_PORT
const KEY_BYTES := KEY_SLOTS * 4


## Bytes one frame occupies in a client's own-input packet: u32 frame, u8 port
## count, then an indexed block per owned port, then every machine's tail.
##
## The tail is per MACHINE and not per sender: a client that owns one port on a
## linked pair still writes both machines' aux and key blocks, because the
## reader walks them positionally.
static func local_frame_bytes(owned_ports: int, machines: int) -> int:
	return 4 + 1 + owned_ports * PORT_BYTES_INDEXED + machines * (AUX_BYTES + KEY_BYTES)


## Bytes one frame occupies in the host's assembled broadcast: u32 frame, then
## every port in order with no index, then every machine's tail.
static func broadcast_frame_bytes(all_ports: int, machines: int) -> int:
	return 4 + all_ports * PORT_BYTES + machines * (AUX_BYTES + KEY_BYTES)


## An aux block with nothing set. Also the shape every reader fills.
static func aux_default() -> Array:
	var out: Array = []
	out.resize(AUX_INTS_PER_PORT)
	out.fill(0)
	return out


static func put_port(buf: StreamPeerBuffer, port: int, v: Array) -> void:
	buf.put_u8(port)
	buf.put_u16(int(v[0]) & 0xFFFF)
	buf.put_16(int(v[1])); buf.put_16(int(v[2]))
	buf.put_16(int(v[3])); buf.put_16(int(v[4]))


static func get_port(buf: StreamPeerBuffer) -> Array:
	return [buf.get_u16(), buf.get_16(), buf.get_16(), buf.get_16(), buf.get_16()]


## One port's aux wire block: flags, accel+gyro for two sensor indices, then
## four pointer contacts. All analogue values are signed 16-bit quantities.
static func put_aux(buf: StreamPeerBuffer, aux: Array) -> void:
	buf.put_u8(int(aux[0]) & 0xFF)
	for i in range(1, 13):
		buf.put_16(int(aux[i]))
	for pointer_index in range(AUX_POINTER_COUNT):
		var base := 13 + pointer_index * 3
		buf.put_16(int(aux[base]))
		buf.put_16(int(aux[base + 1]))
		buf.put_u8(1 if int(aux[base + 2]) != 0 else 0)


static func get_aux(buf: StreamPeerBuffer) -> Array:
	var out := aux_default()
	out[0] = buf.get_u8()
	for i in range(1, 13):
		out[i] = buf.get_16()
	for pointer_index in range(AUX_POINTER_COUNT):
		var base := 13 + pointer_index * 3
		out[base] = buf.get_16()
		out[base + 1] = buf.get_16()
		out[base + 2] = buf.get_u8()
	return out


## Key-event wire block (KEY_SLOTS x 4 bytes): u16 (keycode | down<<15) plus a
## u16 character per slot; keycode 0 is an empty slot.
static func put_keys(buf: StreamPeerBuffer, kv: Array) -> void:
	for slot in range(KEY_SLOTS):
		var packed := 0
		var ch := 0
		if slot * 2 + 1 < kv.size() or slot * 2 < kv.size():
			var p := int(kv[slot * 2]) if slot * 2 < kv.size() else 0
			ch = int(kv[slot * 2 + 1]) if slot * 2 + 1 < kv.size() else 0
			packed = (p & 0x7FFF) | (0x8000 if (p & 65536) != 0 else 0)
		buf.put_u16(packed)
		buf.put_u16(ch & 0xFFFF)


static func get_keys(buf: StreamPeerBuffer) -> Array:
	var out: Array = []
	for _slot in range(KEY_SLOTS):
		var packed := buf.get_u16()
		var ch := buf.get_u16()
		var keycode := packed & 0x7FFF
		var down := (packed & 0x8000) != 0
		out.append(keycode | (65536 if down else 0))
		out.append(ch)
	return out
