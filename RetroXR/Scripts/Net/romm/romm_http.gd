## RommHttp — blocking HTTP for worker threads.
##
## HTTPRequest hands the response body back on the main thread, so a 3 MB catalog
## page or a 4 GB ROM would be parsed/copied there and blow the frame budget.
## This wraps HTTPClient's poll loop instead, so callers can run it on their own
## Thread and stream bodies straight to disk.
##
## NEVER call these from the main thread — every method blocks.
class_name RommHttp
extends RefCounted


## Outcome codes distinct enough to drive the download error matrix.
enum Result {
	OK,
	CONNECT_FAILED,   ## DNS / refused / TLS — transient, retry
	REQUEST_FAILED,   ## socket died mid-exchange — transient, retry
	HTTP_ERROR,       ## got a response, but a bad status — see `code`
	ABORTED,          ## caller set the abort flag
	WRITE_FAILED,     ## local disk write failed — terminal
	## Request went out, server never answered in time. NOT a dead socket:
	## /api/roms pages are database queries and a big one legitimately thinks for
	## minutes. Worth retrying — the same query can answer in a fraction of the
	## time once the server is no longer under sustained load — but each attempt
	## costs a full timeout to discover, so budget them separately.
	TIMED_OUT,
}

## The one failure a caller can act on rather than only report: the server has
## answered that this thing is gone. Named because three call sites compare
## against it -- a state upload deciding to re-create its copy, and the ROM
## browser dropping a catalogue row that can never be downloaded again.
const ERR_GONE := "No longer on the server"

const POLL_SLEEP_MS := 1
## Guard against a server that accepts the connection and then says nothing.
const CONNECT_TIMEOUT_SEC := 15.0
const RESPONSE_TIMEOUT_SEC := 30.0

var _client: HTTPClient = null
var _host: String = ""
var _port: int = -1
var _use_tls: bool = false


## Split "http://host:8080" into its parts. Returns {} when unusable.
static func parse_url(base_url: String) -> Dictionary:
	var url := base_url.strip_edges()
	if url.is_empty():
		return {}

	var use_tls := url.begins_with("https://")
	if use_tls:
		url = url.substr(8)
	elif url.begins_with("http://"):
		url = url.substr(7)

	# Strip any path — callers always pass absolute paths themselves.
	var slash := url.find("/")
	if slash >= 0:
		url = url.substr(0, slash)

	var host := url
	var port := 443 if use_tls else 80
	var colon := url.rfind(":")
	if colon > 0:
		host = url.substr(0, colon)
		var port_str := url.substr(colon + 1)
		if port_str.is_valid_int():
			port = int(port_str)

	if host.is_empty():
		return {}
	return {"host": host, "port": port, "use_tls": use_tls}


## Connect (or reconnect) to the server. Returns a Result.
##
## `abort` is polled while connecting for the same reason the request loops poll
## it: a server under load can take most of CONNECT_TIMEOUT_SEC just to accept,
## and a caller waiting to join this thread should not have to sit through that.
func open(base_url: String, abort: Callable = Callable()) -> int:
	close()

	var parts := parse_url(base_url)
	if parts.is_empty():
		return Result.CONNECT_FAILED

	_host = parts["host"]
	_port = parts["port"]
	_use_tls = parts["use_tls"]

	_client = HTTPClient.new()
	var tls: TLSOptions = TLSOptions.client() if _use_tls else null
	if _client.connect_to_host(_host, _port, tls) != OK:
		close()
		return Result.CONNECT_FAILED

	var deadline := Time.get_ticks_msec() + int(CONNECT_TIMEOUT_SEC * 1000.0)
	while true:
		var status := _client.get_status()
		if status == HTTPClient.STATUS_CONNECTED:
			return Result.OK
		if status != HTTPClient.STATUS_CONNECTING and status != HTTPClient.STATUS_RESOLVING:
			close()
			return Result.CONNECT_FAILED
		if abort.is_valid() and abort.call():
			close()
			return Result.ABORTED
		if Time.get_ticks_msec() > deadline:
			close()
			return Result.CONNECT_FAILED
		_client.poll()
		OS.delay_msec(POLL_SLEEP_MS)

	return Result.CONNECT_FAILED


func close() -> void:
	if _client != null:
		_client.close()
		_client = null


func is_open() -> bool:
	return _client != null and _client.get_status() == HTTPClient.STATUS_CONNECTED


## Send a request and wait for response headers (not the body).
##
## `timeout_sec` overrides RESPONSE_TIMEOUT_SEC for endpoints that legitimately
## think for longer than a stalled socket would. `abort` is polled while waiting:
## without it a long timeout would pin the calling thread for its full duration,
## and RommCatalog joins that thread on quit.
##
## Returns {result: Result, code: int, headers: Dictionary}.
func _send(method: int, path: String, headers: PackedStringArray, body: String = "",
		   abort: Callable = Callable(), timeout_sec: float = RESPONSE_TIMEOUT_SEC) -> Dictionary:
	if _client == null:
		return {"result": Result.CONNECT_FAILED, "code": 0, "headers": {}}

	if _client.request(method, path, headers, body) != OK:
		return {"result": Result.REQUEST_FAILED, "code": 0, "headers": {}}

	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while _client.get_status() == HTTPClient.STATUS_REQUESTING:
		if abort.is_valid() and abort.call():
			return {"result": Result.ABORTED, "code": 0, "headers": {}}
		_client.poll()
		if Time.get_ticks_msec() > deadline:
			return {"result": Result.TIMED_OUT, "code": 0, "headers": {}}
		OS.delay_msec(POLL_SLEEP_MS)

	if not _client.has_response():
		return {"result": Result.REQUEST_FAILED, "code": 0, "headers": {}}

	return {
		"result": Result.OK,
		"code": _client.get_response_code(),
		"headers": _client.get_response_headers_as_dictionary(),
	}


## GET a small body fully into memory and JSON-parse it.
## Only for responses that comfortably fit — catalog pages at limit=1000 are
## ~3 MB, which is fine on a worker thread.
## Returns {result: Result, code: int, data: Variant}.
func get_json(path: String, headers: PackedStringArray, abort: Callable = Callable(),
			  timeout_sec: float = RESPONSE_TIMEOUT_SEC) -> Dictionary:
	var sent := _send(HTTPClient.METHOD_GET, path, headers, "", abort, timeout_sec)
	if int(sent["result"]) != Result.OK:
		return {"result": sent["result"], "code": sent["code"], "data": null}

	var code := int(sent["code"])
	# A caller patient enough to wait `timeout_sec` for headers is just as patient
	# mid-body — the same slow query is what produces both.
	var raw := _read_body(abort, timeout_sec)
	if int(raw["result"]) != Result.OK:
		return {"result": raw["result"], "code": code, "data": null}

	if code < 200 or code >= 300:
		return {"result": Result.HTTP_ERROR, "code": code, "data": null}

	var json := JSON.new()
	var text: String = (raw["body"] as PackedByteArray).get_string_from_utf8()
	if json.parse(text) != OK:
		return {"result": Result.HTTP_ERROR, "code": code, "data": null}

	return {"result": Result.OK, "code": code, "data": json.data}


## POST a JSON body and read the JSON reply.
##
## Not every RomM write is a file upload: deleting states is
## POST /api/states/delete with {"states": [id, …]} — there is no
## DELETE /api/states/{id} route to use instead.
##
## A 2xx with an empty or unparseable body is still a success; `data` is null.
## Returns {result: Result, code: int, data: Variant}.
func post_json(path: String, headers: PackedStringArray, body: String,
			   abort: Callable = Callable(),
			   timeout_sec: float = RESPONSE_TIMEOUT_SEC) -> Dictionary:
	var all := PackedStringArray(headers)
	all.append("Content-Type: application/json")
	var sent := _send(HTTPClient.METHOD_POST, path, all, body, abort, timeout_sec)
	if int(sent["result"]) != Result.OK:
		return {"result": sent["result"], "code": sent["code"], "data": null}

	var code := int(sent["code"])
	var raw := _read_body(abort, timeout_sec)
	if int(raw["result"]) != Result.OK:
		return {"result": raw["result"], "code": code, "data": null}
	if code < 200 or code >= 300:
		return {"result": Result.HTTP_ERROR, "code": code, "data": null}

	return {"result": Result.OK, "code": code,
		"data": JSON.parse_string((raw["body"] as PackedByteArray).get_string_from_utf8())}


## POST/PUT one file as multipart/form-data. The one-part case, kept because it
## is most of the callers — see upload_parts for the general form.
func upload_multipart(method: int, path: String, headers: PackedStringArray,
					  field: String, filename: String, bytes: PackedByteArray,
					  mime: String = "application/octet-stream",
					  abort: Callable = Callable(),
					  timeout_sec: float = RESPONSE_TIMEOUT_SEC) -> Dictionary:
	return upload_parts(method, path, headers,
		[{"field": field, "filename": filename, "bytes": bytes, "mime": mime}],
		abort, timeout_sec)


## POST/PUT several files in ONE multipart/form-data body and read the JSON reply.
##
## The only upload primitive here — everything else in this class is
## download-shaped. Bodies are composed in memory rather than streamed: battery
## saves are KB-sized (128 KB for a PS1 card, 16 MB for the largest GameCube
## one) and a save state with its thumbnail is tens of MB at worst.
##
## More than one part exists for /api/states, which takes `stateFile` and
## `screenshotFile` together — sending them in ONE request is what makes the
## server store the picture AGAINST the state rather than beside it.
##
## `parts` : [{field, filename, bytes, mime}] — mime defaults to octet-stream.
## `abort` : optional func() -> bool, polled while waiting. Without it a quit
##           during a 50 MB upload waits out the whole response timeout on a
##           join, which is exactly when a quit is likeliest.
##
## Returns {result: Result, code: int, data: Variant}.
func upload_parts(method: int, path: String, headers: PackedStringArray,
				  parts: Array, abort: Callable = Callable(),
				  timeout_sec: float = RESPONSE_TIMEOUT_SEC) -> Dictionary:
	if _client == null:
		return {"result": Result.CONNECT_FAILED, "code": 0, "data": null}
	if parts.is_empty():
		return {"result": Result.REQUEST_FAILED, "code": 0, "data": null}

	# Must not occur in the payload. Random rather than fixed: a save file is
	# arbitrary binary and a constant boundary could appear inside one.
	var boundary := "----RetroXR%016x%016x" % [randi(), randi()]
	var CRLF := PackedByteArray([13, 10])

	var body := PackedByteArray()
	for part: Variant in parts:
		var d := part as Dictionary
		body.append_array(("--%s" % boundary).to_utf8_buffer())
		body.append_array(CRLF)
		body.append_array(('Content-Disposition: form-data; name="%s"; filename="%s"'
			% [str(d.get("field", "file")), str(d.get("filename", "file"))]).to_utf8_buffer())
		body.append_array(CRLF)
		body.append_array(("Content-Type: %s"
			% str(d.get("mime", "application/octet-stream"))).to_utf8_buffer())
		body.append_array(CRLF)
		body.append_array(CRLF)
		body.append_array(d.get("bytes", PackedByteArray()) as PackedByteArray)
		body.append_array(CRLF)
	body.append_array(("--%s--" % boundary).to_utf8_buffer())
	body.append_array(CRLF)

	var all := PackedStringArray(headers)
	all.append("Content-Type: multipart/form-data; boundary=%s" % boundary)
	all.append("Content-Length: %d" % body.size())

	if _client.request_raw(method, path, all, body) != OK:
		return {"result": Result.REQUEST_FAILED, "code": 0, "data": null}

	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while _client.get_status() == HTTPClient.STATUS_REQUESTING:
		_client.poll()
		if abort.is_valid() and abort.call():
			return {"result": Result.ABORTED, "code": 0, "data": null}
		if Time.get_ticks_msec() > deadline:
			return {"result": Result.TIMED_OUT, "code": 0, "data": null}
		OS.delay_msec(POLL_SLEEP_MS)

	if not _client.has_response():
		return {"result": Result.REQUEST_FAILED, "code": 0, "data": null}

	var code := _client.get_response_code()
	var raw := _read_body(abort, timeout_sec)
	if int(raw["result"]) != Result.OK:
		return {"result": raw["result"], "code": code, "data": null}
	if code < 200 or code >= 300:
		return {"result": Result.HTTP_ERROR, "code": code, "data": null}

	# A 2xx with an unparseable body still means the upload landed, so the
	# result stays OK and `data` is simply null.
	return {"result": Result.OK, "code": code,
		"data": JSON.parse_string((raw["body"] as PackedByteArray).get_string_from_utf8())}


## Stream a response body straight into an open FileAccess, never holding it in
## memory. `file` must already be positioned (append for a resume).
##
## progress_cb : optional func(received_bytes: int, total_bytes: int) -> void
##               Called from THIS thread — marshal to the main thread yourself.
## abort       : optional func() -> bool, checked between chunks.
##
## Returns {result: Result, code: int, received: int, total: int}.
func download_to_file(path: String, headers: PackedStringArray, file: FileAccess,
					  progress_cb: Callable = Callable(),
					  abort: Callable = Callable()) -> Dictionary:
	# `abort` covers the header wait too. A cancel raised while the server is
	# still thinking is the likeliest moment for one, and a request that ignores
	# it there stays deaf for the whole response timeout.
	var sent := _send(HTTPClient.METHOD_GET, path, headers, "", abort)
	if int(sent["result"]) != Result.OK:
		return {"result": sent["result"], "code": sent["code"], "received": 0, "total": 0}

	var code := int(sent["code"])
	if code < 200 or code >= 300:
		# Drain so the connection stays reusable, then report the status.
		_read_body(abort)
		return {"result": Result.HTTP_ERROR, "code": code, "received": 0, "total": 0}

	var total := _content_length(sent["headers"])
	var received := 0
	var last_report := 0
	# Silence between chunks, not total transfer time: a 4 GB ROM legitimately
	# takes many minutes, and capping the whole download would abandon a healthy
	# one. Reset below on every chunk that lands.
	var deadline := Time.get_ticks_msec() + int(RESPONSE_TIMEOUT_SEC * 1000.0)

	while _client.get_status() == HTTPClient.STATUS_BODY:
		if abort.is_valid() and abort.call():
			return {"result": Result.ABORTED, "code": code, "received": received, "total": total}

		_client.poll()
		var chunk := _client.read_response_body_chunk()
		if chunk.is_empty():
			if Time.get_ticks_msec() > deadline:
				return {"result": Result.TIMED_OUT, "code": code,
					"received": received, "total": total}
			OS.delay_msec(POLL_SLEEP_MS)
			continue

		file.store_buffer(chunk)
		if file.get_error() != OK:
			return {"result": Result.WRITE_FAILED, "code": code, "received": received, "total": total}

		received += chunk.size()
		deadline = Time.get_ticks_msec() + int(RESPONSE_TIMEOUT_SEC * 1000.0)
		# Throttle: a per-chunk deferred call would flood the main thread.
		if progress_cb.is_valid() and (received - last_report) > 262144:
			last_report = received
			progress_cb.call(received, total)

	if progress_cb.is_valid():
		progress_cb.call(received, total)

	return {"result": Result.OK, "code": code, "received": received, "total": total}


## HEAD — size/existence probe without pulling the body.
## Returns {result: Result, code: int, total: int}.
func head(path: String, headers: PackedStringArray) -> Dictionary:
	var sent := _send(HTTPClient.METHOD_HEAD, path, headers)
	if int(sent["result"]) != Result.OK:
		return {"result": sent["result"], "code": sent["code"], "total": 0}
	return {
		"result": Result.OK,
		"code": int(sent["code"]),
		"total": _content_length(sent["headers"]),
	}


## `stall_sec` bounds SILENCE, not total transfer: the deadline resets on every
## chunk that arrives, so a slow-but-moving body runs as long as it needs while a
## server that stops mid-response is cut loose. A body loop with no deadline is
## the one wait an unaborted caller can never leave — it pins the worker for as
## long as the socket stays open, and with it anyone who joins that thread.
func _read_body(abort: Callable = Callable(),
		stall_sec: float = RESPONSE_TIMEOUT_SEC) -> Dictionary:
	var body := PackedByteArray()
	var deadline := Time.get_ticks_msec() + int(stall_sec * 1000.0)
	while _client.get_status() == HTTPClient.STATUS_BODY:
		if abort.is_valid() and abort.call():
			return {"result": Result.ABORTED, "body": body}
		_client.poll()
		var chunk := _client.read_response_body_chunk()
		if chunk.is_empty():
			if Time.get_ticks_msec() > deadline:
				return {"result": Result.TIMED_OUT, "body": body}
			OS.delay_msec(POLL_SLEEP_MS)
		else:
			body.append_array(chunk)
			deadline = Time.get_ticks_msec() + int(stall_sec * 1000.0)
	return {"result": Result.OK, "body": body}


static func _content_length(headers: Dictionary) -> int:
	for key: String in headers:
		if key.to_lower() == "content-length":
			var v := str(headers[key])
			if v.is_valid_int():
				return int(v)
	return 0


## One sentence a player can act on, for a failed RomM request.
##
## The vocabulary lived in four places -- RommSaves, RommStates, RommDownloader
## and FirmwareInstaller -- and one of the docstrings said so ("same vocabulary
## as saves and ROM downloads") without anything actually sharing it. Four of the
## seven branches were word-for-word identical in all four; the two that vary
## genuinely vary, so they are parameters rather than a fifth copy.
##
## `unauthorized` differs because a 403 does not mean the same thing everywhere:
## a read endpoint means "sign in again", while a QR-paired token that cannot
## write means the device will never be able to upload, and telling that player
## to sign in again sends them round a loop that cannot help.
static func describe_error(result: int, code: int,
		unauthorized: String = "Sign in to RomM again",
		refused: String = "RomM refused the request (%d)") -> String:
	match result:
		Result.CONNECT_FAILED, Result.REQUEST_FAILED:
			return "Connection lost"
		Result.TIMED_OUT:
			return "The server took too long to answer"
		Result.WRITE_FAILED:
			return "Not enough space, or the disk is unwritable"
		Result.ABORTED:
			return "Cancelled"
	if code == 401 or code == 403:
		return unauthorized
	if code == 404:
		return ERR_GONE
	if code >= 500:
		return "Server error (%d)" % code
	return refused % code
