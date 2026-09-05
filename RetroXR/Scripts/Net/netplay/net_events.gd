## NetEvents — the kinds of room event a peer can announce.
##
## A leaf: it holds the enum and nothing else, and depends on nothing.
##
## These lived on NetObjectSync, which made the dependency run both ways — a
## light switch or a tape deck had to reach into the netplay layer to name the
## event it was reporting, while that same layer called back into those objects
## by method. Objects announcing what happened to them should not have to know
## which subsystem is listening.
##
## The comment beside each kind is the argument dictionary report_event expects.
## NetObjectSync.EV_NODE_KEYS records which of those arguments must be a live
## node, and is checked before the event goes out.
class_name NetEvents
extends RefCounted

enum {
	EV_CART_INSERT,      # {sys, cart}
	EV_CART_REMOVE,      # {sys}
	EV_TAPE_INSERT,      # {vcr, tape}
	EV_TAPE_REMOVE,      # {vcr}
	EV_TV_PLUG,          # {owner, tv, ch, in}  owner = system or VCR; ch = video-out
						 #                      channel; in = the TV's composite input
	EV_TV_UNPLUG,        # {tv, in}
	EV_PORT_PLUG,        # {sys, ctrl, port}
	EV_PORT_UNPLUG,      # {sys, port}
	EV_SYS_POWER,        # {sys}         client intent -> host toggles
	EV_SYS_POWER_STATE,  # {sys, on}     host -> clients (placeholder screens)
	EV_TV_POWER,         # {tv}
	EV_TV_VOL_UP,        # {tv}
	EV_TV_VOL_DOWN,      # {tv}
	EV_TV_MUTE,          # {tv}          mute toggled
	EV_TV_CRT,           # {tv, on}
	EV_TV_SIZE,          # {tv, scale}   size slider committed
	EV_VCR_CMD,          # {vcr, cmd}    client intent -> host transport
	EV_BOOK_PAGE,        # {book, state, leaf}  page turned -> everyone follows
	EV_BOOK_SIZE,        # {book, scale}        size slider committed
	EV_BOOK_HALF,        # {book, on}           half-page mode toggled
	EV_MEMCARD_INSERT,   # {sys, card, slot}
	EV_MEMCARD_REMOVE,   # {sys, slot}
	EV_TRAY,             # {sys, open}   disc tray lid opened/closed
	EV_DISK_OP,          # {sys, op, md5, index}  client disc-swap intent -> host schedules
	EV_DVD_INSERT,       # {dvd, disc}
	EV_DVD_REMOVE,       # {dvd}
	EV_DVD_CMD,          # {dvd, cmd}    client intent -> host transport/menu
	EV_AUDIO_INSERT,     # {player, media}   CD / cassette media inserted
	EV_AUDIO_REMOVE,     # {player}
	EV_AUDIO_CMD,        # {player, cmd, index?}  client intent -> host transport
	EV_TV_STEREO,        # {tv, mode}    stereo presentation (0 stereo / 1 left / 2 right)
	EV_SYS_VIDEO_OUT,    # {sys, on}     video-out cables shown/hidden
	EV_SYS_GRAVITY,      # {sys, on}     ignore-gravity (float where dropped)
	EV_RCA_PLUG,         # {cable, end, cord, dev, port}  composite lead end seated
	EV_RCA_UNPLUG,       # {cable, end, cord}             ...and pulled out again
	EV_TV_AUDIO_MODE,    # {tv, mode}    speaker switch (0 stereo / 1 mono L / 2 mono R)
	EV_SYS_RESET,        # {sys}         client intent -> host / deterministic reset
	EV_TV_ASPECT,        # {tv, on}      false = 4:3, true = 16:9
	EV_TV_SOURCE,        # {tv, source}  selected input
	EV_TV_CHANNEL,       # {tv, source, rf, index} selected RF/tuner channel
	EV_ROOM_LIGHTS,      # {switch, on}  wall-switch ceiling lights
	EV_PULL_LIGHT,       # {cord, on}    bedside/desk pull-chain lamp
	EV_BLINDS,           # {blinds, drop} window blind height
	EV_TIME_OF_DAY,      # {clock, time} bedroom time lever
}
