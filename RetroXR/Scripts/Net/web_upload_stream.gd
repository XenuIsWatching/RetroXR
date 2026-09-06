## WebUploadStream — the multipart/form-data reader behind a browser upload.
##
## Lifted out of web_file_server.gd, where it was the one genuinely large piece
## of logic in the file: a 128-line state machine plus its staging helpers, about
## 237 lines against a server whose other 26 functions average under 30. It came
## out cleanly because it barely touched its host — the whole group reached back
## into only three server functions and one member.
##
## The split it makes is between PARSING and ANSWERING. The state machine used to
## call the server's _send_text at eight points, so the thing that reads bytes and
## the thing that speaks HTTP were the same object. Here `feed()` returns DONE and
## leaves `code` and `body` for the caller to send, which is what lets the reader
## be tested without a socket.
##
## Staging is the property worth preserving: a part is written to "<dest>.part"
## and promoted only on the closing boundary. An upload that stops early — a
## closed tab, a dropped link, a full disk — would otherwise leave a truncated
## file standing where a good one was, and RomLibrary.scan_roms would spawn it as
## a real cartridge. Same rule the ROM downloader and the state writer follow.
class_name WebUploadStream
extends RefCounted

## NEED_MORE: hand me the next chunk. DONE: `code`/`body` are the reply to send.
enum Status { NEED_MORE, DONE }

## The reply, once feed() has returned DONE.
var code := 200
var body := ""

## How many parts were promoted, and where the current one is up to. The server
## republishes these on its progress endpoint.
var saved := 0
var filename := ""
var written := 0
var total := 0

var _phase := "part_preamble"
var _dest_dir := ""
var _delim: PackedByteArray
var _data_term: PackedByteArray
var _buf: PackedByteArray
var _f: FileAccess = null
var _part := ""
var _dest := ""


## Start a reader, or return null when the request carries no usable boundary —
## which is the caller's cue to answer 400 rather than to keep reading.
static func open(dest_dir: String, content_type: String, content_length: int,
		body_so_far: PackedByteArray) -> WebUploadStream:
	var b_idx := content_type.find("boundary=")
	if b_idx == -1:
		return null
	var boundary := content_type.substr(b_idx + 9).strip_edges()
	if boundary.begins_with('"'):
		boundary = boundary.trim_prefix('"').trim_suffix('"')

	var us := WebUploadStream.new()
	us._dest_dir = dest_dir
	us._delim = ("--" + boundary).to_utf8_buffer()
	us._data_term = ("\r\n--" + boundary).to_utf8_buffer()
	us._buf = body_so_far.duplicate()
	us.total = content_length
	return us


## What the server publishes while an upload is in flight.
func progress() -> Dictionary:
	return {"filename": filename, "written": written, "total": total}


## Append new bytes and advance as far as they allow, writing file data to disk
## as it arrives and keeping only a small lookahead buffer. Returns DONE once the
## reply is ready in `code`/`body`.
func feed(new_data: PackedByteArray) -> Status:
	if new_data.size() > 0:
		_buf.append_array(new_data)

	while true:
		if _phase == "part_preamble":
			var pos := find_bytes(_buf, _delim)
			if pos == -1:
				break
			var after := pos + _delim.size()
			if after + 1 >= _buf.size():
				break  # need 2 more bytes to classify
			if _buf[after] == 45 and _buf[after + 1] == 45:
				# "--boundary--" with no parts.
				return _finish(200, '{"saved":%d}' % saved)
			# Skip CRLF after delimiter.
			if _buf[after] == 13 and _buf[after + 1] == 10:
				after += 2
			_buf = _buf.slice(after)
			_phase = "part_headers"

		elif _phase == "part_headers":
			var hdr_end := find_bytes(_buf, "\r\n\r\n".to_utf8_buffer())
			if hdr_end == -1:
				break
			var hdr_text := _buf.slice(0, hdr_end).get_string_from_utf8()
			_buf = _buf.slice(hdr_end + 4)
			if not _begin_part(hdr_text):
				continue

		elif _phase == "data":
			var term_pos := find_bytes(_buf, _data_term)
			if term_pos == -1:
				# Terminator not found yet. Flush every byte that cannot be part of it.
				var safe := _buf.size() - (_data_term.size() - 1)
				if safe > 0:
					if not _write(_buf.slice(0, safe)):
						return _finish(507, '{"error":"write failed"}')
					_buf = _buf.slice(safe)
				break
			var after_term := term_pos + _data_term.size()
			if after_term + 1 >= _buf.size():
				# Write up to the possible terminator and wait for 2 more bytes.
				if term_pos > 0 and not _write(_buf.slice(0, term_pos)):
					return _finish(507, '{"error":"write failed"}')
				_buf = _buf.slice(term_pos)
				break
			# Write the data before the terminator, then close the file.
			if term_pos > 0 and not _write(_buf.slice(0, term_pos)):
				return _finish(507, '{"error":"write failed"}')
			if not _promote():
				return _finish(500, '{"error":"could not save"}')
			saved += 1
			print("[WebUploadStream] Saved: %s" % filename)
			if _buf[after_term] == 45 and _buf[after_term + 1] == 45:
				return _finish(200, '{"saved":%d}' % saved)  # final boundary
			# More parts → skip CRLF, read the next part's headers.
			if _buf[after_term] == 13 and _buf[after_term + 1] == 10:
				after_term += 2
			_buf = _buf.slice(after_term)
			_phase = "part_headers"

		else:
			break

	return Status.NEED_MORE


## Open the staging file for one part. False means this part was refused — an
## unusable name, an escaping path, or a file that would not open — and the
## reader goes back to looking for the next boundary rather than failing the
## whole upload.
func _begin_part(hdr_text: String) -> bool:
	var name := extract_filename(hdr_text)
	# Folder uploads transmit a relative path (e.g. "MyGame/save/data.001");
	# preserve it instead of flattening so the directory tree is recreated.
	var sub := safe_subpath(name)
	if sub.is_empty():
		_phase = "part_preamble"
		return false
	var dest: String = _dest_dir.path_join(sub)
	# Defence in depth — safe_subpath already strips "..", but never write
	# outside the destination root even if that ever changes.
	if not dest.simplify_path().begins_with(_dest_dir + "/"):
		push_error("[WebUploadStream] Rejected escaping upload path: %s" % name)
		_phase = "part_preamble"
		return false
	var parent := dest.get_base_dir()
	if parent != _dest_dir:
		DirAccess.make_dir_recursive_absolute(parent)
	var part := dest + ".part"
	var f := FileAccess.open(part, FileAccess.WRITE)
	if not f:
		push_error("[WebUploadStream] Cannot open %s for writing (%d)"
			% [part, FileAccess.get_open_error()])
		_phase = "part_preamble"
		return false
	_f = f
	_part = part
	_dest = dest
	filename = sub
	written = 0
	_phase = "data"
	print("[WebUploadStream] Streaming write: %s" % dest)
	return true


## Append to the staged part, reporting a write that did not land.
##
## store_buffer returns nothing, so a full disk is only visible through
## get_error() -- without this the server answered 200 OK over a file that was
## silently short. A failure abandons the stage rather than promoting it.
func _write(chunk: PackedByteArray) -> bool:
	_f.store_buffer(chunk)
	if _f.get_error() != OK:
		push_error("[WebUploadStream] Write failed for %s (%d) -- discarding"
			% [filename, _f.get_error()])
		discard()
		return false
	written += chunk.size()
	return true


## Close and delete the staging file, leaving whatever was already at dest alone.
## Public because the server calls it when a connection dies mid-upload.
func discard() -> void:
	if _f != null:
		_f.close()
		_f = null
	if not _part.is_empty() and FileAccess.file_exists(_part):
		DirAccess.remove_absolute(_part)
	_part = ""


## Move the finished stage over the real destination.
func _promote() -> bool:
	_f.close()
	_f = null
	if FileAccess.file_exists(_dest) and DirAccess.remove_absolute(_dest) != OK:
		push_error("[WebUploadStream] Cannot replace %s" % _dest)
		DirAccess.remove_absolute(_part)
		return false
	if DirAccess.rename_absolute(_part, _dest) != OK:
		push_error("[WebUploadStream] Cannot promote %s" % _part)
		DirAccess.remove_absolute(_part)
		return false
	return true


func _finish(reply_code: int, reply_body: String) -> Status:
	code = reply_code
	body = reply_body
	return Status.DONE


## The name out of one part's Content-Disposition header, or "" when it has none.
static func extract_filename(part_headers: String) -> String:
	var idx := part_headers.find("filename=")
	if idx == -1:
		return ""
	var rest := part_headers.substr(idx + 9)
	if rest.begins_with('"'):
		var quote_end := rest.find('"', 1)
		return rest.substr(1, quote_end - 1) if quote_end != -1 else ""
	var end := rest.find("\r")
	if end == -1:
		end = rest.find("\n")
	return rest.substr(0, end if end != -1 else rest.length())


## A relative destination under the upload root, or "" when the name is unusable.
## Every "." and ".." segment is dropped, so a part can name a subfolder without
## being able to climb out of the tree.
static func safe_subpath(rel_name: String) -> String:
	var out: Array[String] = []
	for seg in rel_name.replace("\\", "/").split("/"):
		var s := seg.strip_edges()
		if s.is_empty() or s == "." or s == "..":
			continue
		out.append(s)
	return "/".join(out)


## Index of `needle` in `haystack` at or after `from`, or -1.
##
## The reader calls this on every incoming chunk, so it stays a plain scan rather
## than anything cleverer: the needles are a boundary line, a few dozen bytes at
## most, and a needle longer than the haystack must answer -1 rather than read
## past the end.
static func find_bytes(haystack: PackedByteArray, needle: PackedByteArray,
		from: int = 0) -> int:
	var hs := haystack.size()
	var ns := needle.size()
	if ns == 0 or hs < ns:
		return -1
	for i in range(from, hs - ns + 1):
		var ok := true
		for j in range(ns):
			if haystack[i + j] != needle[j]:
				ok = false
				break
		if ok:
			return i
	return -1
