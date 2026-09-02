## A Schmitt trigger for the analog VR inputs that drive game buttons.
##
## An XR grip or trigger is an analog axis, and every consumer used to compare it
## against a single threshold. That is a comparator with no hysteresis: the value
## routinely dips back under the threshold for a frame as the hand settles into a
## squeeze, and because a grip's threshold is the lowest of the set (0.3, the part
## of the travel where the finger is still moving) the dip lands right where the
## edge is. The core polls per emulated frame while GDScript samples per render
## frame, so an 11 ms dip at 90 Hz is very likely to be seen — one squeeze arrives
## as press, release, press.
##
## So a source that is already down stays down until it falls well clear of the
## threshold it came up through. One instance per input host, because the state is
## per source and per hand.
##
## Deliberately NOT used for gestures — the drop combo, the page-turn grip. Those
## want the raw threshold: a latched combo would stay armed after the hand opened.
class_name InputLatch
extends RefCounted


## How far below its press threshold a source must fall before it reads as
## released. Absolute rather than proportional so the noisy low thresholds get
## the wide band they need (0.3 releases at 0.18) without making a high one
## impossible to let go of (0.5 releases at 0.38).
const RELEASE_MARGIN := 0.12

## The release threshold can never reach zero, or an axis that rests at a small
## non-zero value would latch on for ever.
const MIN_RELEASE := 0.05

var _down: Dictionary = {}


## Whether `key` reads as pressed at `value`, given the threshold it presses at.
## `key` must be unique per source AND per hand — two hands hold their own state.
func pressed(key: String, value: float, threshold: float) -> bool:
	var was: bool = _down.get(key, false)
	var limit := threshold if not was else maxf(threshold - RELEASE_MARGIN, MIN_RELEASE)
	var now := value > limit
	if now != was:
		_down[key] = now
	return now


## Forget every source. Called when a host loses its hands, so a controller that
## was let go mid-squeeze does not come back already pressed.
func clear() -> void:
	_down.clear()
