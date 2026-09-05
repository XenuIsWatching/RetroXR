## ModOverlayTable — a shipped const table with a mod layer on top of it.
##
## Several tables let a mod ADD rows and REPLACE shipped ones, remember which mod
## contributed each, and serve a merged view. Each had grown its own copy of that
## bookkeeping, and they had drifted: two owner-key conventions (row -> owner in
## some, owner -> rows in others), some with a merged cache and some rebuilding
## on every read, and ConsolePadArt tracking no owner at all — so its rows could
## be registered but never withdrawn.
##
## Mechanism lives here; POLICY stays with each table. What counts as a valid row
## and what to say when one is refused are domain questions with domain wording,
## so callers still make those checks and own their messages. This owns only the
## four dictionaries and the merge, which is the part that was worth agreeing on.
##
## The shipped table is the base layer and is never mutated: `table()` returns a
## merged copy, with overrides applied over the shipped rows and mod additions
## last. Rebuilt only when a registration changed it, because the callers read it
## inside loops.
class_name ModOverlayTable
extends RefCounted

var _base: Dictionary
## key -> row, for rows a mod ADDED.
var _additions: Dictionary = {}
## key -> row, for shipped rows a mod REPLACED.
var _overrides: Dictionary = {}
## key -> the mod that contributed it, for the Mods page and for blame.
var _owners: Dictionary = {}

var _merged: Dictionary = {}
var _dirty: bool = true


func _init(base: Dictionary) -> void:
	_base = base


## The merged view: shipped rows, then overrides, then mod additions.
func table() -> Dictionary:
	if _dirty:
		_merged = _base.duplicate(true)
		for key: String in _overrides:
			_merged[key] = _overrides[key]
		for key: String in _additions:
			_merged[key] = _additions[key]
		_dirty = false
	return _merged


## True when the shipped table already carries this key.
func is_shipped(key: String) -> bool:
	return _base.has(key)


## True for a row a mod ADDED. A shipped row a mod merely overrode is still
## shipped — its id survives the mod being removed, and so do saves naming it.
func is_mod(key: String) -> bool:
	return _additions.has(key)


func has_override(key: String) -> bool:
	return _overrides.has(key)


## Which mod contributed or overrode a key, or "" for an untouched shipped row.
func owner_of(key: String) -> String:
	return str(_owners.get(key, ""))


## Every key a mod added, in registration order.
func mod_keys() -> Array:
	return _additions.keys()


## Record a row a mod added. Callers validate first; this only stores.
func add(key: String, row: Dictionary, owner_id: String) -> void:
	_additions[key] = row
	_owners[key] = owner_id
	_dirty = true


## Record a mod's replacement for a shipped row, keeping the shipped key so
## existing saves still resolve to it.
func override(key: String, row: Dictionary, owner_id: String) -> void:
	_overrides[key] = row
	_owners[key] = owner_id
	_dirty = true


## Withdraw everything one mod contributed, additions and overrides alike.
func drop_owner(owner_id: String) -> void:
	for key: String in _owners.keys():
		if _owners[key] != owner_id:
			continue
		_additions.erase(key)
		_overrides.erase(key)
		_owners.erase(key)
	_dirty = true


## Drop every mod's contribution. For tests, which share process state.
func clear() -> void:
	_additions.clear()
	_overrides.clear()
	_owners.clear()
	_dirty = true
