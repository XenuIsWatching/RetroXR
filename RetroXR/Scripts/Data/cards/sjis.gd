## Sjis — Shift-JIS save titles, as much of them as ASCII can carry.
##
## Both Sony consoles write a save's title in Shift-JIS and almost always in the
## FULL-WIDTH forms, so reading the bytes as ASCII yields mojibake. The
## full-width blocks are contiguous, which covers every Western title. Anything
## outside them (real kana or kanji) has no ASCII equivalent and is dropped
## rather than guessed; a save's filename is always there as a fallback.
##
## Lifted out of PS1Card when the PlayStation 2's icon.sys needed the same
## decode. PS1Card forwards to it, so the two cannot drift.
class_name Sjis


const PUNCT := {
	0x8140: " ", 0x8141: ",", 0x8142: ".", 0x8143: ",", 0x8144: ".",
	0x8146: ":", 0x8147: ";", 0x8148: "?", 0x8149: "!", 0x814F: "^",
	0x8151: "_", 0x815B: "-", 0x815C: "-", 0x815D: "-", 0x815E: "/",
	0x815F: "\\", 0x8160: "~", 0x8162: "|", 0x8165: "'", 0x8166: "'",
	0x8167: "\"", 0x8168: "\"", 0x8169: "(", 0x816A: ")", 0x816D: "[",
	0x816E: "]", 0x816F: "{", 0x8170: "}", 0x817B: "+", 0x817C: "-",
	0x8181: "=", 0x8183: "<", 0x8184: ">", 0x8190: "$", 0x8193: "%",
	0x8194: "#", 0x8195: "&", 0x8196: "*", 0x8197: "@",
}


static func to_ascii(raw: PackedByteArray) -> String:
	var s := ""
	var i := 0
	while i < raw.size():
		var b := raw[i]
		if b == 0:
			break
		# Some games just write plain ASCII.
		if b < 0x80:
			s += char(b)
			i += 1
			continue
		if i + 1 >= raw.size():
			break
		var w := (b << 8) | raw[i + 1]
		i += 2
		if w >= 0x824F and w <= 0x8258:
			s += char(0x30 + (w - 0x824F))        # full-width 0-9
		elif w >= 0x8260 and w <= 0x8279:
			s += char(0x41 + (w - 0x8260))        # full-width A-Z
		elif w >= 0x8281 and w <= 0x829A:
			s += char(0x61 + (w - 0x8281))        # full-width a-z
		elif PUNCT.has(w):
			s += str(PUNCT[w])
	return s.strip_edges()
