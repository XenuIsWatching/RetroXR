## VinylRecord — a 12" LP that drops onto a RecordPlayer's platter and carries the
## path to a music album (a folder of audio tracks, or a single audio file). Group
## "vinyl_record" is what lets the deck's platter well accept it. The third member
## of the family beside AudioDisc and AudioCassette, and identical to them in every
## respect the rest of the app can see — same album exports, same label hook, same
## verify-by-name netplay treatment.
class_name VinylRecord
extends XRToolsPickable

## Path to the album: a folder of audio files, or a single audio file.
@export var album_path: String = "":
	set(value):
		album_path = value

## Human-readable label printed on the record's paper centre.
@export var album_label: String = "":
	set(value):
		album_label = value
		_update_label()

@onready var _label: Label3D = get_node_or_null("DiscLabel")


func _ready() -> void:
	super._ready()
	add_to_group("vinyl_record")
	_update_label()


func get_album_path() -> String:
	return album_path


## Netplay: show transfer progress on the label (empty string restores the album
## label). Called by NetObjectSync while resolving the album on this peer.
func net_set_download_status(status: String) -> void:
	if _label:
		_label.text = album_label if status.is_empty() else status


func _update_label() -> void:
	if _label:
		_label.text = album_label
