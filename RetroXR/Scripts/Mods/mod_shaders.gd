## ModShaders — the built-in display shaders, by name.
##
## A mod wanting the stock CRT look should not have to hardcode
## res://Shaders/crt_effect.gdshader. Nothing about the shader tree is frozen,
## and a name lets those files move or be renamed without breaking every mod.
##
## These are the SAME resources the game already has loaded, so asking for one
## costs nothing and compiles nothing twice.
##
## Note this is only for a mod that wants a built-in DELIBERATELY. A shell that
## simply returns null from screen_shader() gets the stock CRT material anyway --
## that is the zero-effort path and the common case.
class_name ModShaders
extends RefCounted

const _SHADERS := {
	"crt":              "res://Shaders/crt_effect.gdshader",
	"vcr":              "res://Shaders/vcr_effect.gdshader",
	"static":           "res://Shaders/tv_static.gdshader",
	"window":           "res://Shaders/screen_window.gdshader",
	"gameboy_lcd":      "res://Shaders/gameboy_lcd.gdshader",
	"vb_stereo":        "res://Shaders/vb_stereo.gdshader",
	"phosphor_decay":   "res://Shaders/phosphor_decay.gdshader",
	"screen_pixel_aa":  "res://Shaders/screen_pixel_aa.gdshader",
}


## The named shader, or null. An unknown name warns rather than returning null
## quietly: a null landing in a ShaderMaterial paints nothing, and a mod author
## staring at an invisible screen has no way to guess why.
static func get_shader(shader_name: String) -> Shader:
	if not _SHADERS.has(shader_name):
		push_warning("[mods] unknown built-in shader '%s'; known names: %s"
			% [shader_name, ", ".join(names())])
		return null
	return load(_SHADERS[shader_name]) as Shader


static func has(shader_name: String) -> bool:
	return _SHADERS.has(shader_name)


static func names() -> Array:
	return _SHADERS.keys()
