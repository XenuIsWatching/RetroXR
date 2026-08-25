## RoomCode — the six characters a player reads out to invite someone.
##
## A room code identifies a hosted session on the rendezvous registry. It is
## assigned by the server, which owns uniqueness; nothing here mints one.
##
## The alphabet drops I, L, O, U, 0 and 1. Those are the pairs that go wrong
## when a code is read aloud over voice chat or copied off a VR panel, and both
## halves of each pair are dropped rather than one being folded into the other:
## with O and 0 both absent there is no correct character to rewrite a typed 0
## into, and guessing would turn a local "that is not a code" into the server's
## indistinguishable "invalid or expired".
##
## `normalize()` and `is_valid()` are separate on purpose, and callers run them
## in that order. `is_valid()` judges a code in the form it would be sent in, so
## a caller that skips normalization fails visibly on lowercase input instead of
## passing a gate and then sending something the registry never issued.
class_name RoomCode
extends RefCounted

const ALPHABET := "ABCDEFGHJKMNPQRSTVWXYZ23456789"
const LENGTH := 6


## Upper-cases, and drops the separators a person adds when writing a code down.
## Nothing else is rewritten: a character outside the alphabet survives so that
## `is_valid()` can reject it.
static func normalize(raw: String) -> String:
	var out := ""
	for c in raw.to_upper():
		# strip_edges rather than a literal tab: an editor run retabs this file,
		# string literals included.
		if c.strip_edges().is_empty() or c == "-" or c == "_":
			continue
		out += c
	return out


## True for a code in the exact form the registry issues it. Pass the result of
## `normalize()`.
static func is_valid(code: String) -> bool:
	if code.length() != LENGTH:
		return false
	for c in code:
		if not ALPHABET.contains(c):
			return false
	return true
