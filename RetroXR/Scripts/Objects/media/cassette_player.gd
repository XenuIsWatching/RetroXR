## CassettePlayer — a pickable cassette deck that plays an inserted audio tape
## (AudioCassette). A linear tape: play / pause / stop / ff / rew only (no track
## skip). Tracks in a multi-song album still auto-advance as the tape "plays
## through"; the remote shows the same reduced control set.
##
## Front-loads like the VCR (scaled to a cassette): the tape rides flat into the
## deck through the front slot and EJECT slides it back out — all handled by the
## shared MediaSlot.
class_name CassettePlayer
extends RetroAudioPlayer

# Cassette rides ~6 cm into the deck, laid flat (the tape mesh is authored standing,
# so it's rotated -90° about the slot's X axis, same as the VHS tape).
const SLOT_INSET := 0.06

var _slot: MediaSlot = null


func _ready() -> void:
	_media_group = "audio_cassette"
	super._ready()
	add_to_group("cassette_player")
	TransportGlyphs.label_buttons(self, {
		"RewindButton": "rew", "PlayButton": "play", "PauseButton": "pause",
		"StopButton": "stop", "FastForwardButton": "ff", "EjectButton": "eject",
	}, TransportGlyphs.DECK_SIZE)


## Front-loading tape bay via the shared MediaSlot.
func _setup_loader() -> void:
	_slot = MediaSlot.new()
	_slot.host = self
	_slot.slot = _media_slot
	_slot.insert_depth = SLOT_INSET
	_slot.media_local_basis = Basis(Vector3(1, 0, 0), -PI / 2.0)   # lay the tape flat
	add_child(_slot)
	_slot.inserted.connect(_media_loaded)
	_slot.removed.connect(_media_unloaded)
	var eject := get_node_or_null("EjectButton") as VRButton
	if eject:
		eject.button_pressed.connect(func() -> void:
			if _slot:
				_slot.eject())
		eject.set_color(Color(0.8, 0.8, 0.85))


func restore_media(media: Node3D) -> void:
	if _slot:
		_slot.restore(media)


## Ejecting IS how a tape leaves a front loader — it rides back out of the slot.
func remove_media() -> void:
	if _slot:
		_slot.eject()


func deck_save_type() -> String:
	return "cassette_player"
