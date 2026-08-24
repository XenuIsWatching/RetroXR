extends Node

## Photographs the CONTROLS tab — the global page and any platform's override
## page — as the player sees it.
##
##   godot --path RetroXR --resolution 1280x900 --position 20,20 \
##     res://Tools/controls_menu_probe.tscn -- --page=wii
##
##   --page=global   the page every machine falls back to
##   --page=<sysid>  that platform's override page (wii, nes, …)
##   --scroll=<px>   scroll down before the shot, for a page taller than the frame
##   --out=<name>    PNG stem; defaults to controls_<page>
##
## PNGs land in res://probe_out/ (gitignored). Windowed, NOT headless: the dummy
## renderer hands back a blank image.
##
## It stands up the REAL MainScene and photographs the menu the room built,
## rather than instantiating SpawnMenuControlsView on its own. That is the whole
## point of it. A detached view has no theme, no CoreDefaults and no
## CoreInfoDatabase, so its platform tiles come up empty and its rows come up
## unstyled — a picture of something no player will ever see, which is worse than
## no picture because it looks like evidence.
##
## Headless reports no OpenXR even when windowed on a desk, so the view builds
## its DESKTOP branch: key-binding rows rather than XR ones. The console diagram
## and the physical-pad section are built either way, and those are what this is
## usually pointed at. To photograph the XR rows you need a headset.

const MAIN := preload("res://Scenes/MainScene.tscn")
const OUT_DIR := "res://probe_out"

var _page := "global"
var _scroll := 0
var _out := ""


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--page="):
			_page = arg.split("=")[1]
		elif arg.begins_with("--scroll="):
			_scroll = int(arg.split("=")[1])
		elif arg.begins_with("--out="):
			_out = arg.split("=")[1]
	if _out.is_empty():
		_out = "controls_" + _page
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("[controls] TIMEOUT")
		get_tree().quit(1))
	await _run()


func _run() -> void:
	add_child(MAIN.instantiate())
	for i in 40:
		await get_tree().process_frame

	var views: Array[Node] = get_tree().root.find_children(
		"*", "SpawnMenuControlsView", true, false)
	if views.is_empty():
		print("[controls] no SpawnMenuControlsView in the tree")
		get_tree().quit(1)
		return
	var view: Node = views[0]

	# The menu lives in a SubViewport somewhere above it — that texture IS what
	# the 3D panel shows, so photographing it is photographing the player's view.
	var sv := _owning_viewport(view)
	if sv == null:
		print("[controls] the menu is not inside a SubViewport")
		get_tree().quit(1)
		return

	# The panel's viewport does not necessarily redraw just because its contents
	# changed — Viewport2DIn3D drives it on its own schedule, so a tab switch can
	# leave the texture holding the frame that was current at startup. That
	# photographs SPAWN however long you wait on CONTROLS, and looks exactly like
	# a tab switch that did not take.
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS

	# The menu opens on SPAWN and the controls view is built but hidden, so
	# _open_platform alone photographs the wrong tab.
	var menus: Array[Node] = get_tree().root.find_children(
		"*", "SpawnMenu2D", true, false)
	if menus.is_empty():
		print("[controls] no SpawnMenu2D in the tree")
		get_tree().quit(1)
		return
	menus[0].call("_show_controls_view")
	for i in 12:
		await get_tree().process_frame

	if _page != "global":
		view.call("_open_platform", _page)
	for i in 20:
		await get_tree().process_frame

	if view is ScrollContainer:
		var sc := view as ScrollContainer
		var bar := sc.get_v_scroll_bar()
		# Printed because a scroll past the end CLAMPS rather than erroring, so
		# two different --scroll values quietly produce the same picture and it
		# reads as a change that did not take.
		print("[controls] scrollable 0..%d (page %d)"
			% [int(bar.max_value - bar.page), int(bar.page)])
		if _scroll > 0:
			sc.scroll_vertical = _scroll
			for i in 8:
				await get_tree().process_frame
			print("[controls] scrolled to %d" % sc.scroll_vertical)

	await RenderingServer.frame_post_draw
	await get_tree().process_frame

	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var path := "%s/%s.png" % [OUT_DIR, _out]
	sv.get_texture().get_image().save_png(path)
	print("[controls] page=%s scroll=%d viewport=%s -> %s"
		% [_page, _scroll, str(sv.size), path])
	get_tree().quit(0)


func _owning_viewport(n: Node) -> SubViewport:
	var p := n.get_parent()
	while p != null:
		if p is SubViewport:
			return p as SubViewport
		p = p.get_parent()
	return null
