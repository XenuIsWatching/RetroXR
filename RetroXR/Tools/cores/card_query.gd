## Prints which spawn card each expansion unit is filed on.
##
##     "$godot" --headless --path RetroXR --script res://Tools/cores/card_query.gd
extends SceneTree


func _init() -> void:
	for id: String in ExpansionCatalog.ROWS:
		print("[card] %-20s host=%-14s media=%-14s card=%s" % [
			id,
			ExpansionCatalog.host_of(id),
			ExpansionCatalog.media_of(id),
			ExpansionCatalog.card_systemid(id)])
	for sysid in ["super_nes", "game_boy"]:
		print("[on] %s -> %s" % [sysid, str(ExpansionCatalog.ids_carded_on(sysid))])
	quit(0)
