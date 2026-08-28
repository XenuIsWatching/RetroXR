#!/usr/bin/env bash
# Survey which cores can start with nothing in the machine, and what they call
# the option that plays a boot ROM. Fills in the BiosBoot table, which must not
# be written from the .info files: every core of interest declares
# supports_no_game = "false" there, including ones that boot to a BIOS happily.
#
#   Tools/bios_boot_survey.sh                # every candidate
#   Tools/bios_boot_survey.sh mgba flycast   # just these cores
#   GODOT=/path/to/godot Tools/bios_boot_survey.sh
#
# ONE GODOT PROCESS PER ATTEMPT. Handing a core a game info it never expected
# runs code its author may not have exercised, and the extension is built
# -fno-exceptions with no sandbox: mgba segfaults outright on a null pointer.
# A separate process means a casualty costs one table row, not the survey.
#
# Two conventions get tried, ZEROED FIRST. It is the survivable one -- a core
# that reads the pointer without checking sees zeroes rather than faulting --
# so a core that dies on it is not then asked to try the other. Null is
# libretro's own convention and what RetroArch passes, so it is what a core
# detecting no-content with `if (!info)` wants; it is tried second, and only
# when zeroed came back with a clean refusal.
#
# The survey WRITES the player's real core_options: a core serialises its whole
# option set when it shuts down, and a crashed run can leave a key moved. The
# directory is snapshotted up front and restored at the end, always.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJ="$REPO/RetroXR"

if [[ -z "${GODOT:-}" ]]; then
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      GODOT="/c/Program Files/Godot/Godot_v4.7-stable_win64/Godot_v4.7-stable_win64_console.exe" ;;
    *) GODOT="$HOME/Godot/Godot_v4.7-stable_linux.x86_64" ;;
  esac
fi
[[ -x "$GODOT" ]] || { echo "godot not found: $GODOT (set GODOT=)" >&2; exit 2; }

# core:systemid. A core serving two machines appears twice -- the boot ROM and
# the option key both differ per machine, which is the whole reason the BiosBoot
# table is keyed on the pair.
CANDIDATES=(
  pcsx_rearmed:playstation
  mednafen_saturn:sega_saturn
  flycast:dreamcast
  genesis_plus_gx:sega_cd
  mednafen_pce:pc_engine_cd
  neocd:neo_geo_cd
  pcee2:playstation2
  pcsx2:playstation2
  dolphin:gamecube
  mgba:game_boy_advance
  mgba:game_boy
  gambatte:game_boy
  sameboy:game_boy
  opera:3do
  same_cdi:cdi
  parallel_n64:nintendo_64dd
)

if [[ $# -gt 0 ]]; then
  filtered=()
  for want in "$@"; do
    for pair in "${CANDIDATES[@]}"; do
      [[ "${pair%%:*}" == "$want" ]] && filtered+=("$pair")
    done
  done
  CANDIDATES=("${filtered[@]}")
fi

CORE_ROOT="${CORE_ROOT:-$HOME/retroxr/libretro}"
OUT="${OUT:-$REPO/bios_survey_out}"
mkdir -p "$OUT"

BACKUP="$OUT/core_options.backup"
if [[ -d "$CORE_ROOT/core_options" ]]; then
  rm -rf "$BACKUP"
  cp -r "$CORE_ROOT/core_options" "$BACKUP"
  echo "snapshot: $CORE_ROOT/core_options -> $BACKUP"
fi
restore_options() {
  if [[ -d "$BACKUP" ]]; then
    rm -rf "$CORE_ROOT/core_options"
    cp -r "$BACKUP" "$CORE_ROOT/core_options"
    echo "restored: $CORE_ROOT/core_options"
  fi
}
trap restore_options EXIT

# Runs one attempt in its own process. Echoes the verdict; a process that dies
# without printing RESULT is reported as "crash", which is a real finding and
# not an error in the survey.
attempt() {
  local core="$1" sysid="$2" nullinfo="$3"
  local log="$OUT/${core}.${sysid}.null${nullinfo}.log"
  timeout 90 "$GODOT" --path "$PROJ" --resolution 320x240 --position 20,20 \
    res://Tools/cores/bios_boot_probe.tscn -- \
    "--core=$core" "--systemid=$sysid" "--nullinfo=$nullinfo" >"$log" 2>&1
  local rc=$?
  local line
  line="$(grep -a "\[biosprobe\] RESULT" "$log" | tail -1)"
  if [[ -z "$line" ]]; then
    echo "crash"
  elif [[ "$line" == *"no_content=yes"* ]]; then
    if [[ $rc -ne 0 ]]; then echo "yes-then-crash"; else echo "yes"; fi
  elif [[ "$line" == *"no_content=hang"* ]]; then
    echo "hang"
  elif [[ $rc -ne 0 ]]; then
    echo "no-then-crash"
  else
    echo "no"
  fi
}

REPORT="$OUT/survey.txt"
: >"$REPORT"
printf '%-18s %-18s %-14s %-14s\n' CORE SYSTEMID ZEROED NULL | tee -a "$REPORT"
printf '%-18s %-18s %-14s %-14s\n' ------------------ ------------------ -------------- -------------- | tee -a "$REPORT"

for pair in "${CANDIDATES[@]}"; do
  core="${pair%%:*}"
  sysid="${pair##*:}"
  if ! ls "$CORE_ROOT/cores/${core}_libretro."* >/dev/null 2>&1; then
    printf '%-18s %-18s %-14s %-14s\n' "$core" "$sysid" "not-installed" "-" | tee -a "$REPORT"
    continue
  fi
  zeroed="$(attempt "$core" "$sysid" 0)"
  # A core that could not survive the gentler convention is not offered the
  # sharper one; the answer would cost a crash to learn and change nothing.
  if [[ "$zeroed" == crash || "$zeroed" == *-then-crash || "$zeroed" == hang ]]; then
    nulled="skipped"
  else
    nulled="$(attempt "$core" "$sysid" 1)"
  fi
  printf '%-18s %-18s %-14s %-14s\n' "$core" "$sysid" "$zeroed" "$nulled" | tee -a "$REPORT"
done

echo
echo "logs and table: $OUT"
echo "boot-ROM option keys per core:"
grep -ah "\[biosprobe\] option:" "$OUT"/*.log | sort -u | tee -a "$REPORT"
