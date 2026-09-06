## ByteSize — measuring a byte count, and showing it the one way.
##
## Download sizes, cache budgets, "3.4 MB of 12 MB" on a progress row. MenuStyle
## already said in as many words that the callers "must agree on the rounding",
## and then a byte-identical second copy grew in RommDownloader — where a
## download's progress line is written — so the two could disagree about the
## same file and nothing would have said so.
##
## Neutral rather than on MenuStyle because RommDownloader is a Data class: a
## downloader reaching into the spawn menu for a number format is a dependency
## pointing the wrong way, and the shared rule is about text the player reads,
## not about the menu.
##
## Binary units deliberately, with the decimal LABELS the platforms use — the
## same convention the OS file managers this sits beside display. The served
## web page has its own copy in JavaScript with its own rounding; that one is a
## different language in a different process and is not this.
class_name ByteSize
extends RefCounted

const KB := 1024
const MB := 1048576
const GB := 1073741824


## "1.4 GB", "512 MB", "8 KB", "17 B".
##
## One decimal place only at GB, where the step between whole units is large
## enough that rounding to one would lose real information about a download the
## player is deciding whether to start.
static func human(bytes: int) -> String:
	if bytes >= GB:
		return "%.1f GB" % (float(bytes) / float(GB))
	if bytes >= MB:
		return "%.0f MB" % (float(bytes) / float(MB))
	if bytes >= KB:
		return "%.0f KB" % (float(bytes) / float(KB))
	return "%d B" % bytes


## How big the file at `path` is, or 0 when it cannot be opened.
##
## Opens and asks rather than reading: get_file_as_bytes() would pull a
## whole core download into memory to answer a question about its length.
## FirmwareInstaller and StorageCleanup had this byte for byte apiece.
static func on_disk(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var n := int(f.get_length())
	f.close()
	return n
