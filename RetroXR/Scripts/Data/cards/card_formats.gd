## CardFormats — the registry of memory card families.
##
## One instance per family, made once and kept: a CardFormat holds no state, and
## the save list rebuilds on every panel open, so minting a fresh one per call
## would allocate on a menu-tap path for nothing.
##
## Lookups come in three shapes because the three callers genuinely know
## different things. A console knows its systemid. A card in the room knows its
## family. Code holding a path on disk knows only the extension — and that last
## one is why the extensions must stay distinct across families.
class_name CardFormats

static var _by_family: Dictionary = {}


static func _build() -> void:
	if not _by_family.is_empty():
		return
	for fmt: CardFormat in [PS1CardFormat.new(), GCCardFormat.new()]:
		_by_family[fmt.id()] = fmt


## The family with this id, or null.
static func for_family(family: String) -> CardFormat:
	if family.is_empty():
		return null
	_build()
	return _by_family.get(family)


## The family this console's cards belong to, or null when it has no card slots.
## Read from the console's own descriptor rather than a table here, so a new
## console is one .tres line and not an edit in two places.
static func for_system(systemid: String) -> CardFormat:
	var info := SystemInfo.for_system(systemid)
	if info == null:
		return null
	return for_family(info.card_family)


## The family a card image on disk belongs to, by extension, or null.
static func for_path(path: String) -> CardFormat:
	if path.is_empty():
		return null
	_build()
	var ext := path.get_extension().to_lower()
	for fmt: CardFormat in _by_family.values():
		if fmt.extension() == ext:
			return fmt
	return null


## Every registered family. Used by the callers that must sweep them all — the
## legacy card lookup that has only a card_id to go on.
static func all() -> Array[CardFormat]:
	_build()
	var out: Array[CardFormat] = []
	for fmt: CardFormat in _by_family.values():
		out.append(fmt)
	return out
