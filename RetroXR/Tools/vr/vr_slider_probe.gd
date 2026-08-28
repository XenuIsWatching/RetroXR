## Headless probe for VRSlider logic: clamping, continuous emission, detent
## snapping (steps=2 switch), and the populate no-signal guard.
##
## Run: godot --headless --path RetroXR res://Tools/vr/vr_slider_probe.tscn
extends Node

var _fail := false


func _fail_if(cond: bool, msg: String) -> void:
	if cond:
		_fail = true
		print("[probe] FAIL: %s" % msg)


func _make(steps: int) -> VRSlider:
	var s := VRSlider.new()
	s.steps = steps
	s.travel = 0.03
	var knob := MeshInstance3D.new()
	knob.name = "KnobMesh"
	add_child(s)
	s.add_child(knob)
	return s


func _ready() -> void:
	# Continuous slider.
	var emitted: Array = []
	var slider := _make(0)
	slider.value_changed.connect(func(v: float) -> void: emitted.append(v))

	slider._set_from_raw(0.5)
	_fail_if(absf(slider.value - 0.5) > 0.001, "continuous mid value")
	slider._set_from_raw(2.0)
	_fail_if(slider.value != 1.0, "clamp high")
	slider._set_from_raw(-1.0)
	_fail_if(slider.value != 0.0, "clamp low")
	_fail_if(emitted.size() != 3, "continuous emission count (%d)" % emitted.size())

	# World-point projection: a point at +travel/2 along the axis = value 1.
	slider.axis_local = Vector3(1, 0, 0)
	slider._track_world_point(slider.to_global(Vector3(0.015, 0, 0)))
	_fail_if(absf(slider.value - 1.0) > 0.01, "projection at +travel/2 (%f)" % slider.value)
	slider._track_world_point(slider.to_global(Vector3(-0.015, 0, 0)))
	_fail_if(absf(slider.value) > 0.01, "projection at -travel/2 (%f)" % slider.value)

	# 2-detent switch: snaps, emits only on detent change.
	var toggled: Array = []
	var sw := _make(2)
	sw.value_changed.connect(func(v: float) -> void: toggled.append(v))
	sw._set_from_raw(0.2)
	_fail_if(sw.value != 0.0, "detent snap low")
	sw._set_from_raw(0.4)   # still snaps to 0 — must NOT emit
	sw._set_from_raw(0.8)
	_fail_if(sw.value != 1.0, "detent snap high")
	_fail_if(toggled != [1.0], "switch emissions %s (want [1.0])" % str(toggled))

	# Populate guard.
	var before: int = toggled.size()
	sw.set_value_no_signal(0.0)
	_fail_if(sw.value != 0.0, "set_value_no_signal value")
	_fail_if(toggled.size() != before, "set_value_no_signal emitted")

	print("[probe] RESULT=%s" % ("FAIL" if _fail else "PASS"))
	get_tree().quit(1 if _fail else 0)
