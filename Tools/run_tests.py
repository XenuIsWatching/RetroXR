#!/usr/bin/env python3
"""Run every self-checking suite in RetroXR/Tests, in one command.

    python Tools/run_tests.py
    python Tools/run_tests.py --only rope_tests
    python Tools/run_tests.py --only netplay_tests,scene_tests
    python Tools/run_tests.py --list
    python Tools/run_tests.py --only rope_tests -- --only=contact

Everything under RetroXR/Tests/ is a suite that checks itself, runs unattended
with no ROM, core, headset or device, and exits non-zero on failure. That exit
code is the contract and the only thing every suite agrees on -- the summary
lines differ ("[test]", "[av]", "[bay]"), so the table below scrapes counts for
readability but the verdict is always the process's status.

Suites run SEQUENTIALLY and never in parallel. Each one writes the player's real
`user://` state -- prefs.json, controller_bindings.json, the arcade manifest,
core_options/ -- and each snapshots and restores its own. Two at once would
restore each other's snapshots and leave the player's settings wherever the race
landed.

Anything after a bare `--` is forwarded to every suite, which is how a suite's
own `--only=<group>` filter is reached. That is a different flag from this
script's `--only`, which picks whole suites.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PROJECT = REPO / "RetroXR"
TESTS_DIR = PROJECT / "Tests"

# A failing suite's detail line is where the em dash lives ("FAIL name — why"),
# so a cp1252 console dies exactly when it is finally printing something worth
# reading. Force UTF-8 out rather than lose the one report that matters.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError):
        pass

# Longest measured run is rope_tests at ~2 min. The default leaves generous head
# room on a cold cache or a slower box; a suite that blows through it is hung,
# not slow, and is reported as TIMEOUT rather than silently waited on.
DEFAULT_TIMEOUT = 420

# Pre-existing headless noise, documented in CLAUDE.md as not-your-change: no
# OpenXR runtime, the template_debug GDExtension paths that only exist after a
# build, no .NET SDK, and the XR staging shim's placeholder instance. Filtered
# from the captured output so a real error is not buried in it.
NOISE = re.compile(
    r"xrCreateInstance failed"
    r"|libgodotopenxrvendors"
    r"|godot-pdfium|libpdfium"
    r"|libretro_godot|libvlc_godot|libverlet_rope|libarchive_godot|metaxr_audio"
    r"|\.NET Sdk not found|Unable to load .NET runtime"
    r"|xr_staging_shim\.gd"
    r"|is_xr_class"
    r"|placeholder instance"
    r"|GDExtension dynamic library not found"
    r"|Can't open dynamic library"
    # The desktop box has no headset, so OpenXR always fails to bring one up and
    # says so across six lines including a Windows Mixed Reality aside.
    r"|HMD was not detected"
    r"|Check logged errors in debugger"
    r"|Windows Mixed Reality"
    r"|Godot will start in normal mode"
    r"|initialize_openxr_module"
    r"|Unicode parsing error"
    r"|Failed to create XR instance"
    r"|OpenXR was requested but failed to start",
    re.IGNORECASE,
)

# Per-case lines. The bracket prefix varies per suite ("[test]", "[av]", "[bay]",
# "[motion]") and so does the verdict word -- most print PASS/FAIL, netplay and
# the suites modelled on it print a lowercase "ok".
CASE = re.compile(r"^\[[a-z_]+\]\s+(PASS|FAIL|ok)\b", re.MULTILINE)

# Four summary shapes are in use across the suites, and a fifth would be easy to
# add by accident -- so the total and the failure count are matched separately
# rather than as one rigid line. None of this is the verdict: a suite can print a
# clean summary and still die on the way out (see CRASH). It is for the table.
#
# "N passed, M failed"           binding, card, link, romm, rope, state, system, motion
# "N checks, M case(s) failed"   av_suite, bay
# "N checks, M failure(s)"       object_sync (and "N checks, PASS|N FAILURE(S)")
# "N cases, PASS|FAIL"           netplay, poster, scene, time_of_day, web_server
SUMMARY_PASSED = re.compile(r"(\d+)\s+passed,\s*(\d+)\s+failed")
SUMMARY_TOTAL = re.compile(r"(\d+)\s+(?:checks|cases),", re.IGNORECASE)
# "N failed"                     firmware_digest, locomotion
#
# The bare form goes last because it is a suffix of the two above; the alternation
# is ordered so "3 case(s) failed" is not read as the number 3 followed by a bare
# "failed" it would also match. Without it those two suites' failure counts came
# from the per-case fallback instead of from the number the suite itself printed.
SUMMARY_FAILED = re.compile(
    r"(\d+)\s+(?:case\(s\)\s+failed|failure\(s\)|failed)", re.IGNORECASE)


def find_godot(explicit: str | None) -> str:
    """Locate a Godot 4.7 binary, preferring the console build on Windows.

    The plain Windows .exe is a GUI launcher that detaches, so its stdout never
    reaches us and every suite would look like it produced no output at all.
    """
    if explicit:
        if not Path(explicit).exists():
            sys.exit(f"--godot: no such file: {explicit}")
        return explicit

    env = os.environ.get("GODOT")
    if env and Path(env).exists():
        return env

    candidates = [
        Path("C:/Program Files/Godot/Godot_v4.7-stable_win64/"
             "Godot_v4.7-stable_win64_console.exe"),
        Path.home() / "Godot/Godot_v4.7-stable_linux.x86_64",
        Path("/Applications/Godot.app/Contents/MacOS/Godot"),
    ]
    for c in candidates:
        if c.exists():
            return str(c)

    for name in ("godot", "godot4", "Godot"):
        found = shutil.which(name)
        if found:
            return found

    sys.exit(
        "could not find Godot 4.7. Pass --godot <path> or set $GODOT.\n"
        "  Windows: C:/Program Files/Godot/Godot_v4.7-stable_win64/"
        "Godot_v4.7-stable_win64_console.exe\n"
        "  Linux:   ~/Godot/Godot_v4.7-stable_linux.x86_64"
    )


def discover() -> list[str]:
    """Every Tests/*.tscn that has a script beside it, in a stable order."""
    if not TESTS_DIR.is_dir():
        sys.exit(f"no such directory: {TESTS_DIR}")
    names = sorted(
        p.stem for p in TESTS_DIR.glob("*.tscn") if (TESTS_DIR / f"{p.stem}.gd").exists()
    )
    if not names:
        sys.exit(f"no suites found in {TESTS_DIR}")
    return names


def scrape(text: str) -> tuple[int, int]:
    """Best-effort (checks, failures) for the table. Never the verdict.

    A crashing suite loses whatever stdout was still buffered, so these numbers
    can be short or missing entirely for exactly the runs you most want to read.
    That is why the verdict is the exit status and this is only decoration.
    """
    def last(pattern: re.Pattern[str]) -> re.Match[str] | None:
        found = None
        for found in pattern.finditer(text):
            pass  # the LAST summary line is the whole-run one
        return found

    if (m := last(SUMMARY_PASSED)) is not None:
        passed, failed = int(m.group(1)), int(m.group(2))
        return passed + failed, failed

    cases_seen = CASE.findall(text)
    counted_failures = sum(1 for c in cases_seen if c == "FAIL")

    if (m := last(SUMMARY_TOTAL)) is not None:
        total = int(m.group(1))
        # Some of these shapes print a verdict word instead of a number
        # ("N cases, PASS"), so fall back to counting the per-case lines.
        f = last(SUMMARY_FAILED)
        return total, int(f.group(1)) if f else counted_failures

    if cases_seen:
        return len(cases_seen), counted_failures
    return 0, 0


BASELINE = Path(__file__).resolve().parent / "test_baseline.json"


def load_baseline() -> dict[str, int]:
    """Each suite's known case count, or an empty map when the file is absent."""
    if not BASELINE.exists():
        return {}
    try:
        raw = json.loads(BASELINE.read_text(encoding="utf-8")).get("suites", {})
        return {str(k): int(v) for k, v in raw.items()}
    except (ValueError, OSError) as exc:
        # A damaged baseline must not stop the suites from running: it is a
        # guard over them, not a precondition for them.
        print(f"[tests] ignoring unreadable {BASELINE.name}: {exc}")
        return {}


def write_baseline(counts: dict[str, int]) -> None:
    BASELINE.write_text(json.dumps({
        "_comment": "Case counts per suite. A DROP fails the run: a suite whose "
                    "group quietly stops running still passes every case it did "
                    "run and still exits 0, which is the one failure a green CI "
                    "cannot show you. Counts rise as cases are added -- rerun "
                    "with --update-baseline and commit this alongside them.",
        "suites": dict(sorted(counts.items())),
    }, indent=2) + "\n", encoding="utf-8")


def check_baseline(results: list[tuple[str, str, int, int, float]]) -> list[str]:
    """Suites whose count fell below the recorded baseline.

    Only a DROP is reported. A rise is how the suites are supposed to grow, and
    a suite absent from the file is new rather than broken — both pass, so
    adding cases never needs a second commit to keep the run green.
    """
    known = load_baseline()
    dropped = []
    for name, status, checks, _failures, _secs in results:
        if status != "OK" or name not in known:
            continue
        if checks < known[name]:
            dropped.append(f"{name}: {checks} checks, baseline {known[name]}")
    return dropped


def verdict(code: int, timed_out: bool) -> str:
    """OK / FAIL / CRASH / TIMEOUT.

    A suite can print a clean summary and still die on the way out -- both
    motion_tests and time_of_day_tests pass every case and then segfault during
    teardown. That is still a red run, but it needs a different fix from a failed
    assertion, so the table says which one it was instead of calling both FAIL.
    """
    if timed_out:
        return "TIMEOUT"
    if code == 0:
        return "OK"
    # Windows hands back the exception code itself (0xC0000005 and friends);
    # POSIX shells report 128+signal. Either way it is not an orderly exit(1).
    if code > 128 or code < 0:
        return "CRASH"
    return "FAIL"


# A suite that fails one of 105 cases should report that one case, not all 105.
# Engine-level errors are kept too: a suite can exit non-zero having printed no
# FAIL line at all -- a parse error, a crash, a timeout -- and the reason is then
# only in these.
TROUBLE = re.compile(
    r"\bFAIL\b|\bTIMEOUT\b"
    r"|SCRIPT ERROR|Parse Error|SHADER ERROR"
    r"|Failed to load|Failed to instantiate"
    r"|ERROR:|USER ERROR:|WARNING:|USER WARNING:",
)


def interesting(text: str) -> str:
    lines = [ln for ln in text.splitlines() if TROUBLE.search(ln)]
    if not lines:
        # Nothing matched, so the tail is the only clue about how it died.
        lines = text.strip().splitlines()[-15:]
    return "\n".join(lines[:60]).strip()


def run_one(godot: str, name: str, timeout: int, extra: list[str]) -> tuple[str, int, int, float, str]:
    cmd = [godot, "--headless", "--path", str(PROJECT), f"res://Tests/{name}.tscn"]
    if extra:
        cmd += ["--", *extra]

    print(f"=== {name}", flush=True)
    started = time.time()
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
        )
        code, out = proc.returncode, (proc.stdout or "") + (proc.stderr or "")
        timed_out = False
    except subprocess.TimeoutExpired as exc:
        code, timed_out = 124, True
        out = (exc.stdout or "") + (exc.stderr or "")
        if isinstance(out, bytes):
            out = out.decode("utf-8", "replace")

    secs = time.time() - started
    clean = "\n".join(ln for ln in out.splitlines() if not NOISE.search(ln))
    checks, failures = scrape(clean)

    status = verdict(code, timed_out)
    if timed_out:
        print(f"    TIMEOUT after {timeout}s", flush=True)
    else:
        note = f"  <-- exit 0x{code:08X}" if status == "CRASH" else ""
        print(f"    {status}  {checks} checks, {failures} failed  {secs:.1f}s{note}", flush=True)

    return status, checks, failures, secs, clean


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Run the RetroXR self-checking test suites.",
        epilog="Anything after a bare -- is forwarded to every suite "
               "(e.g. -- --only=contact).",
    )
    ap.add_argument("--only", help="comma-separated suite names (see --list)")
    ap.add_argument("--list", action="store_true", help="list the suites and exit")
    ap.add_argument("--godot", help="path to the Godot 4.7 binary")
    ap.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT,
                    help=f"per-suite seconds (default {DEFAULT_TIMEOUT})")
    ap.add_argument("--verbose", action="store_true",
                    help="print each suite's filtered output, not only failures'")
    ap.add_argument("--update-baseline", action="store_true",
                    help="rewrite Tools/test_baseline.json from this run's counts")
    ap.add_argument("forward", nargs="*", help=argparse.SUPPRESS)
    args = ap.parse_args()

    suites = discover()
    if args.list:
        for s in suites:
            print(s)
        return 0

    if args.only:
        wanted = [s.strip() for s in args.only.split(",") if s.strip()]
        unknown = [w for w in wanted if w not in suites]
        if unknown:
            sys.exit(f"unknown suite(s): {', '.join(unknown)}\n"
                     f"available: {', '.join(suites)}")
        suites = wanted

    godot = find_godot(args.godot)
    extra = list(args.forward)

    print(f"[tests] {godot}")
    print(f"[tests] {len(suites)} suite(s), sequential"
          + (f", forwarding {' '.join(extra)}" if extra else ""))
    print()

    results: list[tuple[str, str, int, int, float]] = []
    outputs: dict[str, str] = {}
    for name in suites:
        status, checks, failures, secs, out = run_one(godot, name, args.timeout, extra)
        results.append((name, status, checks, failures, secs))
        outputs[name] = out
        if args.verbose:
            print(out)

    print("\n" + "=" * 66)
    for name, status, checks, failures, secs in results:
        print(f"  {status:<7} {name:<22} "
              f"{checks:>5} checks {failures:>4} failed {secs:7.1f}s")

    bad = [(n, s) for n, s, _, _, _ in results if s != "OK"]
    total = sum(c for _, _, c, _, _ in results)
    elapsed = sum(s for _, _, _, _, s in results)

    if bad:
        # Without this the table says which suite broke and nothing about why,
        # and re-running it by hand is the only way to find out.
        if not args.verbose:
            for name, _ in bad:
                print(f"\n----- {name} -----")
                print(interesting(outputs[name]) or "(no output)")
            print("\n(--verbose for the full log of every suite)")
        # A crash after every case passed is a different problem from a failed
        # assertion, so name the kind rather than lumping them together.
        print(f"\n{len(bad)} of {len(results)} suites not OK: "
              + ", ".join(f"{n} ({s})" for n, s in bad))
        return 1

    # A suite whose group stopped running still passes every case it did run,
    # so the exit status alone cannot see it. The recorded count can.
    #
    # Skipped for a filtered run -- --only, or a forwarded --only= group --
    # where a lower count is the whole point rather than a regression.
    partial = bool(args.only) or any(a.startswith("--only=") for a in extra)
    if args.update_baseline:
        if partial:
            print("\nrefusing to write a baseline from a filtered run")
            return 1
        write_baseline({n: c for n, _, c, _, _ in results})
        print(f"\nwrote {BASELINE.name} from this run")
    elif not partial and (dropped := check_baseline(results)):
        print("\ncase count fell below the recorded baseline:")
        for line in dropped:
            print(f"  {line}")
        print("\nA suite that quietly stops running a group still passes every\n"
              "case it did run. If the drop is deliberate, rerun with\n"
              "--update-baseline and commit Tools/test_baseline.json with it.")
        return 1

    print(f"\nall {len(results)} suites OK -- {total} checks in {elapsed:.0f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
