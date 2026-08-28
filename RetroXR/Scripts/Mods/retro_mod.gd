## RetroMod — what a mod's entry script extends.
##
##     extends RetroMod
##
##     func register(api: ModApi) -> void:
##         api.register_model({...})
##
## One call, made once, while the room is still being built. A mod that needs to
## act later asks for a hook (api.on_node_added, api.on_scene_content_ready)
## rather than staying resident, so nothing has to keep it alive.
##
## RefCounted rather than Node on purpose: a mod is not in the tree, and a mod
## that wants to be adds its own nodes through a hook.
class_name RetroMod
extends RefCounted


## Register everything this mod contributes. Called once, after its pack is
## mounted. Anything that throws or pushes an error here is reported against the
## mod by name on the Mods page.
func register(_api: ModApi) -> void:
	pass
