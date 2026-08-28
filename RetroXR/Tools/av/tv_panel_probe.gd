extends Node

## Photographs the TV options panel's Channels tab (tuner box + channel list),
## rendered at the real viewport size the 3D panel uses.
##
##   godot --path RetroXR --resolution 640x520 --position 20,20 \
##     res://Tools/av/tv_panel_probe.tscn -- --tab=2
##
## PNG lands in res://probe_out/tv_panel.png (gitignored).

const UI_SCENE := preload("res://Scenes/UI/tv_options_2d.tscn")

var _sv: SubViewport = null
var _ui: TVOptions2D = null
var _tuner: TVTuner = null
var _tab := 2


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--tab="):
			_tab = int(arg.split("=")[1])
	get_tree().create_timer(90.0).timeout.connect(func() -> void:
		print("[panel] TIMEOUT")
		get_tree().quit(1))
	await _run()


func _run() -> void:
	_sv = SubViewport.new()
	# The size tv_options_panel.tscn gives its viewport.
	_sv.size = Vector2i(550, 500)
	_sv.transparent_bg = false
	_sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_sv)

	_ui = UI_SCENE.instantiate() as TVOptions2D
	_sv.add_child(_ui)
	await get_tree().process_frame
	await get_tree().process_frame

	# A real tuner, so the list is the real 80-odd broadcast rows.
	_tuner = TVTuner.new()
	add_child(_tuner)
	_tuner.reload_channels()
	# Wait for DISCOVERY, not just for channels: the cache fills the list within a
	# frame, and populating then would photograph "Looking for a tuner…" and prove
	# nothing about the status line.
	print("[panel] waiting for discovery…")
	var deadline := Time.get_ticks_msec() + 25000
	while _tuner.discovered_host().is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame

	_tuner.current_index = 3
	_ui.populate(1.0)
	_ui.populate_channels(_tuner.channels, _tuner.current_index)
	_ui.populate_tuner(_tuner.tuner_auto(), _tuner.tuner_host(),
		_tuner.discovered_host(), _tuner.tuner_status_line())
	print("[panel] %d channels; status: %s"
		% [_tuner.channels.size(), _tuner.tuner_status_line()])

	var tabs := _find_tabs(_ui)
	if tabs:
		tabs.current_tab = _tab
		print("[panel] tabs: %s (showing %d)"
			% [str(range(tabs.get_tab_count()).map(func(i: int) -> String:
				return tabs.get_tab_title(i))), _tab])
	for f in range(20):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	await get_tree().process_frame

	DirAccess.make_dir_recursive_absolute("res://probe_out")
	_sv.get_texture().get_image().save_png("res://probe_out/tv_panel.png")
	print("[panel] saved probe_out/tv_panel.png")
	get_tree().quit(0)


func _find_tabs(n: Node) -> TabContainer:
	if n is TabContainer:
		return n as TabContainer
	for c in n.get_children():
		var found := _find_tabs(c)
		if found:
			return found
	return null
