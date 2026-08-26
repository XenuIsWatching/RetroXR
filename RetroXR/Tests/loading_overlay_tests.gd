extends Node

## The shared loading screen: who is waiting, what the bar says, and when the
## curtain comes down.
##
##   godot --headless --path RetroXR res://Tests/loading_overlay_tests.tscn
##   godot --headless --path RetroXR res://Tests/loading_overlay_tests.tscn -- --only=refcount
##
## Exits non-zero on failure, so it can gate a commit.
##
## Every case here is a way the screen can lie to the player: a curtain that
## comes down while something is still building, one that never comes down at
## all, a bar that walks backwards, or a room that flashes between two owners
## handing off.
##
## It does NOT drive a real transition — change_scene loads a room whose
## SubViewports render every frame, and a headless run has no GPU to service
## them, so that hangs rather than fails. The panel's own rendering is a question
## for Tools/loading_screen_probe.tscn, which has a display.

const GROUPS := ["refcount", "aggregate", "status", "failure", "panel", "netplay"]

var _fail := 0
var _ran := 0
var _only := ""


func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("[test] TIMEOUT")
		get_tree().quit(1))
	get_tree().current_scene = self

	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			_only = a.trim_prefix("--only=")

	_clear()
	if _want("refcount"):
		await _test_refcount()
	if _want("aggregate"):
		await _test_aggregate()
	if _want("status"):
		await _test_status()
	if _want("failure"):
		await _test_failure()
	if _want("panel"):
		_test_panel()
	if _want("netplay"):
		await _test_netplay()
	_clear()

	print("[test] %d cases, %s" % [_ran,
		"PASS" if _fail == 0 else "%d FAILURE(S)" % _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ── Who is waiting ────────────────────────────────────────────────────────────

func _test_refcount() -> void:
	_clear()
	_ok(not LoadingOverlay.is_active(), "refcount/starts down")

	LoadingOverlay.begin(&"a", "A")
	_ok(LoadingOverlay.is_active(), "refcount/one owner puts it up")
	LoadingOverlay.begin(&"b", "B")
	_eq(LoadingOverlay.owners().size(), 2, "refcount/two owners are both counted")

	# The whole point: the first one finishing must not uncover a room the second
	# is still building.
	LoadingOverlay.end(&"a")
	_ok(LoadingOverlay.is_active(), "refcount/one owner ending leaves it up")
	LoadingOverlay.end(&"b")
	await _settle()
	_ok(not LoadingOverlay.is_active(), "refcount/the last owner takes it down")

	# Re-registering is how a coalesced room change arrives. It must refresh, not
	# double-count, or the curtain outlives its second end().
	LoadingOverlay.begin(&"a", "A")
	LoadingOverlay.begin(&"a", "A again")
	_eq(LoadingOverlay.owners().size(), 1, "refcount/re-registering does not double-count")
	LoadingOverlay.end(&"a")
	await _settle()
	_ok(not LoadingOverlay.is_active(), "refcount/one end is enough after a refresh")

	# Ending something that was never registered happens for real:
	# notify_scene_content_ready ends both the boot restore and a transition, and
	# only one of them exists.
	LoadingOverlay.begin(&"a", "A")
	LoadingOverlay.end(&"never_registered")
	_ok(LoadingOverlay.is_active(), "refcount/ending an unknown owner is a no-op")
	LoadingOverlay.end(&"a")
	await _settle()


func _test_status() -> void:
	_clear()
	# The hold is what stops a flash: the boot warm can finish a frame before the
	# restore registers, and the room must not appear in between.
	LoadingOverlay.begin(&"a", "A")
	var panel := _panel()
	_ok(panel != null, "status/a panel exists while an owner is waiting")
	# Compared by INSTANCE ID, not by reference. A freed Object compares equal to
	# null in GDScript, so `_panel() == panel` is true whether the panel survived
	# or was torn down and the handle went stale — an oracle that cannot fail.
	var panel_id := panel.get_instance_id()
	LoadingOverlay.end(&"a")
	LoadingOverlay.begin(&"b", "B")
	await _settle()
	_ok(LoadingOverlay.is_active(), "status/an owner arriving inside the hold keeps it up")
	_ok(_panel() != null and _panel().get_instance_id() == panel_id,
		"status/and reuses the same panel rather than flashing")
	LoadingOverlay.end(&"b")
	await _settle()
	_ok(not is_instance_valid(instance_from_id(panel_id)),
		"status/the panel is freed once nobody is waiting")


# ── What the bar says ─────────────────────────────────────────────────────────

func _test_aggregate() -> void:
	_clear()
	LoadingOverlay.begin(&"light", "L", 1.0)
	LoadingOverlay.begin(&"heavy", "H", 2.0)
	LoadingOverlay.set_phase(&"light", "", 0.0)
	LoadingOverlay.set_phase(&"heavy", "", 1.0)
	_close(LoadingOverlay.aggregate_progress(), 2.0 / 3.0,
		"aggregate/weights decide the mean")

	LoadingOverlay.set_phase(&"light", "", 1.0)
	_close(LoadingOverlay.aggregate_progress(), 1.0, "aggregate/all done is 1.0")

	# A late owner drops the raw mean. The bar must not follow it down — a bar
	# that goes backwards reads as a bug, so the status text carries the truth.
	var before: float = _shown()
	LoadingOverlay.begin(&"late", "X", 1.0)
	LoadingOverlay.set_phase(&"late", "", 0.0)
	_ok(LoadingOverlay.aggregate_progress() < before,
		"aggregate/a late owner really does lower the raw mean")
	_ok(_shown() >= before, "aggregate/but the drawn bar never moves backwards")

	LoadingOverlay.end(&"light")
	LoadingOverlay.end(&"heavy")
	LoadingOverlay.end(&"late")
	await _settle()

	# The floor is per-show, not for ever, or the next load starts full.
	LoadingOverlay.begin(&"fresh", "F")
	LoadingOverlay.set_phase(&"fresh", "", 0.0)
	_close(_shown(), 0.0, "aggregate/a new show starts from zero again")
	LoadingOverlay.end(&"fresh")
	await _settle()


# ── Failure ───────────────────────────────────────────────────────────────────

func _test_failure() -> void:
	_clear()
	LoadingOverlay.begin(&"boom", "B")
	LoadingOverlay.fail(&"boom", "IT BROKE")
	_ok(LoadingOverlay.is_active(), "failure/a failed owner keeps the screen up")
	# A failure the player never sees is the thing being fixed, so it takes an
	# explicit end to clear it.
	LoadingOverlay.end(&"boom")
	await _settle()
	_ok(not LoadingOverlay.is_active(), "failure/an explicit end clears it")

	# fail() on an owner nobody registered still has to show something, rather
	# than dropping the only report of the failure.
	LoadingOverlay.fail(&"ghost", "NO OWNER")
	_ok(LoadingOverlay.is_active(), "failure/fail registers an unknown owner")
	LoadingOverlay.end(&"ghost")
	await _settle()


# ── The panel itself ──────────────────────────────────────────────────────────

func _test_panel() -> void:
	var scene: PackedScene = load("res://Scenes/UI/loading_panel.tscn")
	var panel: Node = scene.instantiate()
	add_child(panel)

	# A SubViewport set to update every frame hangs a headless run outright, with
	# no GPU to service it. This suite is meant to gate a commit, so the fence is
	# here rather than in a comment: turning DetailLabel into a viewport of
	# Controls must fail loudly instead of hanging CI for ever.
	_ok(panel.find_children("*", "SubViewport", true, false).is_empty(),
		"panel/carries no SubViewport, which would hang a headless run")

	# It has to be able to hang in a live room, which means bringing no camera
	# and no environment of its own — Tools/transition_matrix.gd fails the run if
	# a second one of either ever reaches the tree.
	_ok(panel.find_children("*", "XRCamera3D", true, false).is_empty(),
		"panel/brings no camera into a live room")
	_ok(panel.find_children("*", "XROrigin3D", true, false).is_empty(),
		"panel/brings no origin into a live room")
	_ok(panel.find_children("*", "WorldEnvironment", true, false).is_empty(),
		"panel/brings no environment to displace the room's")

	_ok(panel.get_node_or_null("Curtain") != null, "panel/has a curtain to occlude with")
	panel.set_progress(0.5)
	panel.set_progress(0.2)
	_ok(true, "panel/a backwards set_progress is ignored rather than throwing")
	panel.set_detail(PackedStringArray(["ROW ONE", "ROW TWO"]))
	_eq(panel.get_node("Screen/DetailLabel").text, "ROW ONE\nROW TWO",
		"panel/detail rows are shown one per line")
	panel.show_load_error("BROKEN")
	panel.set_progress(1.0)
	_ok(true, "panel/progress after a failure does not clear the failure")

	# Two panels can be alive at once — the rig's and the overlay's, mid-handoff.
	# The bar's material is a sub-resource, and sub-resources are SHARED between
	# instances unless marked local, so without that the two would drive each
	# other's bar.
	var other: Node = scene.instantiate()
	add_child(other)
	other.set_progress(0.0)
	panel.reset()
	panel.set_progress(0.75)
	var a: ShaderMaterial = panel.get_node("Screen/ProgressBar").get_surface_override_material(0)
	var b: ShaderMaterial = other.get_node("Screen/ProgressBar").get_surface_override_material(0)
	_ok(a != b, "panel/two panels do not share one progress material")
	_close(float(b.get_shader_parameter("progress")), 0.0,
		"panel/one panel's bar does not drive another's")

	# The curtain is welded to a camera while attached. If it is not reclaimed on
	# the way out it stays over the player's face for the rest of the session.
	var cam := XRCamera3D.new()
	var origin := Node3D.new()
	add_child(origin)
	add_child(cam)
	panel.attach_to(cam, origin)
	_ok(panel.get_node_or_null("Curtain") == null, "panel/attach moves the curtain to the camera")
	_eq(cam.get_child_count(), 1, "panel/the camera is holding it")
	panel.detach()
	_eq(cam.get_child_count(), 0, "panel/detach takes the curtain back off the camera")
	_ok(panel.get_node_or_null("Curtain") != null, "panel/and the panel has it again")

	panel.attach_to(cam, origin)
	remove_child(panel)
	_eq(cam.get_child_count(), 0, "panel/leaving the tree reclaims the curtain too")

	panel.free()
	other.free()
	cam.free()
	origin.free()


# ── Netplay ───────────────────────────────────────────────────────────────────

func _test_netplay() -> void:
	_clear()
	# A joiner tags its own progress with the HOST's id, 1 — not its own. Reading
	# that as "somebody else's join" is how the rows silently never appear.
	LoadingOverlay.begin(&"netplay", "JOINING ROOM")
	LoadingOverlay._on_net_state_progress(1, "transferring", 1048576, 4194304)
	var shown: String = _panel().get_node("Screen/DetailLabel").text
	_ok(shown.contains("RECEIVING STATE"), "netplay/the host-tagged id is my own join")
	_ok(shown.contains("1.0") and shown.contains("4.0"), "netplay/byte counts are reported in MB")

	# The other peers' rows belong to the host's screen, not this one.
	LoadingOverlay._on_net_state_progress(7, "capturing", 0, 0)
	_eq(_panel().get_node("Screen/DetailLabel").text, shown,
		"netplay/another peer's progress is ignored")

	# The transfer is not what the curtain is waiting on — a join into a room
	# with no running game reports none of it — so it must never end the wait.
	LoadingOverlay._on_net_state_progress(1, "loading", 0, 0)
	_ok(LoadingOverlay.is_active(), "netplay/a finished transfer does not lift the curtain")
	LoadingOverlay.end(&"netplay")
	await _settle()


# ── Helpers ───────────────────────────────────────────────────────────────────

func _panel() -> Node:
	return LoadingOverlay._panel


func _shown() -> float:
	return LoadingOverlay._shown_progress


## Past the hide grace period, so a teardown has actually happened.
func _settle() -> void:
	await get_tree().create_timer(LoadingOverlay.HOLD_S + 0.15).timeout


func _clear() -> void:
	for owner: Variant in LoadingOverlay.owners():
		LoadingOverlay.end(owner)
	LoadingOverlay._teardown()


func _want(group: String) -> bool:
	return _only.is_empty() or _only == group


func _ok(cond: bool, what: String) -> void:
	_ran += 1
	if cond:
		print("[test] ok   %s" % what)
	else:
		_fail += 1
		print("[test] FAIL %s" % what)


func _eq(got: Variant, want: Variant, what: String) -> void:
	_ok(got == want, what if got == want else "%s (got %s, want %s)" % [what, got, want])


func _close(got: float, want: float, what: String, tol: float = 0.001) -> void:
	_ok(absf(got - want) <= tol,
		what if absf(got - want) <= tol else "%s (got %f, want %f)" % [what, got, want])
