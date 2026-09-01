#!/usr/bin/env bash
# Capture a RenderDoc frame from RetroXR on a connected Quest.
#
# Requires RenderDoc for Meta Quest (renderdoccmd.exe) and the on-device layer
# APKs com.oculus.renderdoccmd.arm32/arm64.
set -euo pipefail
export MSYS_NO_PATHCONV=1

RD="${RD:-/c/Program Files/RenderDocForMetaQuest/renderdoccmd.exe}"
PKG="${PKG:-com.xenu.retroxr}"
DEV="${DEV:-$(adb devices | awk 'NR==2{print $1}')}"
OUT="${OUT:-$PWD/renderdoc_out}"
BOOT_WAIT="${BOOT_WAIT:-28}"

mkdir -p "$OUT"

# The remote server must already be listening or adb-launch reports
# "Failed to connect to remote server". Warm it up first.
adb -s "$DEV" shell am force-stop com.oculus.renderdoccmd.arm64
adb -s "$DEV" shell am start -W -n com.oculus.renderdoccmd.arm64/.Loader \
	-e renderdoccmd remoteserver >/dev/null
adb -s "$DEV" shell sleep 4

# Launch unattended: fake "worn", pause Guardian.
adb -s "$DEV" shell am force-stop "$PKG"
adb -s "$DEV" shell am broadcast -a com.oculus.vrpowermanager.prox_close >/dev/null
adb -s "$DEV" shell setprop debug.oculus.guardian_pause 1

IDENT=$("$RD" adb-launch-drawcall-profiling --device "$DEV" --package "$PKG" 2>&1 |
	grep -oE '"ident":[0-9]+' | head -1 | cut -d: -f2)
[ -n "$IDENT" ] || { echo "launch failed: no ident" >&2; exit 1; }
echo "ident=$IDENT"

adb -s "$DEV" shell sleep "$BOOT_WAIT"

# The "worn" broadcast expires after 30s and a headset that reads as off the
# head stops submitting frames, which surfaces as "No captures received".
adb -s "$DEV" shell am broadcast -a com.oculus.vrpowermanager.prox_close 	--ei duration 120000 >/dev/null
adb -s "$DEV" shell input keyevent KEYCODE_WAKEUP

"$RD" adb-capture --device "$DEV" --ident "$IDENT" --frames "${FRAMES:-1}" \
	--output-dir "$(cygpath -w "$OUT" 2>/dev/null || echo "$OUT")"

adb -s "$DEV" shell setprop debug.oculus.guardian_pause 0
adb -s "$DEV" shell am broadcast -a com.oculus.vrpowermanager.prox_open >/dev/null
ls -la "$OUT"
