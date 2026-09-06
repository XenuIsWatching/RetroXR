## autoload_order_tests — the boot order that several files depend on and
## nothing checked.
##
## Godot instantiates autoloads in the order project.godot lists them, and a
## later one may reach an earlier one during its own _ready. Several files here
## say so in a comment — scene_manager.gd:79 requires LoadingOverlay to be
## declared BEFORE SceneManager, and CLAUDE.md records that Mods must come
## before AppPrefs — but nothing enforced any of it.
##
## That is not hypothetical. Getting one of these backwards has already shipped
## once, and it hid: the fifteen `has_node("/root/X")` guards that would notice
## a missing singleton degrade silently by design, because they also cover the
## legitimate case of a probe scene run without the full autoload set. So the
## symptom was a feature quietly not working rather than a crash.
##
## This reads project.godot itself rather than the live tree, so it checks what
## SHIPS. A suite runs with every autoload present, which is exactly the
## condition under which an ordering bug is invisible.
##
##   "$godot" --headless --path RetroXR res://Tests/autoload_order_tests.tscn
extends Node

const PROJECT := "res://project.godot"

## Each pair is (earlier, later): `earlier` must be declared first, because
## `later` reaches it while starting up. The reason is recorded with each one so
## a future edit can tell a real constraint from a coincidence of the list.
const MUST_PRECEDE := [
	["LoadingOverlay", "SceneManager",
		"scene_manager.gd:79 — SceneManager shows the overlay during a "
		+ "transition and resolves it at _ready"],
	["Mods", "AppPrefs",
		"a mod may register tables and defaults that AppPrefs then reads"],
	["Mods", "SceneManager",
		"a mod can add rooms, and SceneManager builds its room list at startup"],
	["AppPrefs", "QualityManager",
		"QualityManager applies the stored quality tier on boot"],
	["NetworkManager", "SaveSync",
		"the RomM save sync asks the network layer whether a session is live"],
	["NetworkManager", "StateSync",
		"same reason as SaveSync"],
]

var _passed := 0
var _failed := 0


func _ready() -> void:
	get_tree().create_timer(30.0).timeout.connect(func() -> void:
		push_error("[autoload] TIMEOUT")
		get_tree().quit(1))

	var order := _declared_order()
	_ok(not order.is_empty(), "order/project.godot declares autoloads",
		"read %d" % order.size())

	for rule: Array in MUST_PRECEDE:
		var earlier: String = rule[0]
		var later: String = rule[1]
		var why: String = rule[2]
		var name := "order/%s is declared before %s" % [earlier, later]
		var i := order.find(earlier)
		var j := order.find(later)
		if i < 0 or j < 0:
			# A renamed or removed autoload must fail loudly here rather than
			# letting the rule quietly stop applying.
			_ok(false, name, "one of them is not declared at all")
			continue
		_ok(i < j, name, why)

	# No duplicates: Godot keeps the last, so a repeated name means the earlier
	# declaration — and any ordering rule resting on it — is silently inert.
	var seen: Dictionary = {}
	var dupes: Array[String] = []
	for n: String in order:
		if seen.has(n):
			dupes.append(n)
		seen[n] = true
	_eq(dupes, [] as Array[String], "order/no autoload is declared twice")

	print("[autoload] %d checks, %d failed" % [_passed + _failed, _failed])
	print("[autoload] RESULT=%s" % ("PASS" if _failed == 0 else "FAIL"))
	get_tree().quit(1 if _failed > 0 else 0)


func _ok(cond: bool, what: String, detail := "") -> void:
	if cond:
		_passed += 1
		print("[autoload] ok   %s" % what)
	else:
		_failed += 1
		print("[autoload] FAIL %s%s" % [what, "" if detail.is_empty() else "  -- " + detail])


func _eq(got: Variant, want: Variant, what: String) -> void:
	_ok(got == want, what, "got %s, want %s" % [got, want])


## The autoload names in declaration order, read from project.godot.
##
## Parsed as text rather than through ProjectSettings, because the setting
## dictionary does not promise to preserve declaration order and order is the
## whole subject here.
func _declared_order() -> Array[String]:
	var out: Array[String] = []
	var f := FileAccess.open(PROJECT, FileAccess.READ)
	if f == null:
		return out
	var in_section := false
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.begins_with("["):
			in_section = line == "[autoload]"
			continue
		if not in_section or line.is_empty() or line.begins_with(";"):
			continue
		var eq := line.find("=")
		if eq > 0:
			out.append(line.substr(0, eq).strip_edges())
	return out
