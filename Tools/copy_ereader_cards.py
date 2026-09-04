#!/usr/bin/env python3
"""Copy a No-Intro e-Reader dotcode set into the RetroXR ROM library.

    python Tools/copy_ereader_cards.py --src //raspberrypi4.local/bigdrive/ereader
    python Tools/copy_ereader_cards.py --src <dir> --dry-run

Only .raw strips are copied. The set also ships a .7z of every strip and a pile
of .sav files; the archives are duplicates of what is already there, and the
.sav files are pre-scanned e-Reader flash images rather than cards.

A strip whose size is not one GBACartEReaderScan accepts is REPORTED and skipped
rather than copied. That function returns silently on an unknown size, so a bad
file installed here would be a card that does nothing with no diagnostic.
"""

import argparse
import os
import shutil
import sys

# Raw dotcode sizes GBACartEReaderScan accepts; mirrors EReaderCards.ACCEPTED_SIZES.
ACCEPTED_SIZES = {1308, 1344, 1872, 2076, 2112, 2912, 3520, 5456}

SYSTEMID = "ereader"


def default_roms_root() -> str:
    """Mirrors RomLibrary.default_roms_root() for the desktop platforms."""
    if sys.platform.startswith("win"):
        return os.path.join(os.environ["USERPROFILE"], "retroxr", "roms").replace("\\", "/")
    return os.path.join(os.path.expanduser("~"), "retroxr", "roms")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src", required=True, help="directory holding the .raw strips")
    ap.add_argument("--dst", default="", help="target dir (default: <roms root>/ereader)")
    ap.add_argument("--dry-run", action="store_true", help="report without writing")
    args = ap.parse_args()

    src = args.src
    if not os.path.isdir(src):
        print("error: --src is not a directory: %s" % src)
        return 2

    dst = args.dst or os.path.join(default_roms_root(), SYSTEMID).replace("\\", "/")

    copied = skipped_existing = 0
    rejected = []
    total_bytes = 0

    with os.scandir(src) as it:
        entries = sorted((e for e in it if e.name.lower().endswith(".raw")),
                         key=lambda e: e.name)

    if not entries:
        print("error: no .raw files in %s" % src)
        return 2

    if not args.dry_run:
        os.makedirs(dst, exist_ok=True)

    for e in entries:
        size = e.stat().st_size
        if size not in ACCEPTED_SIZES:
            rejected.append((e.name, size))
            continue
        target = os.path.join(dst, e.name)
        if os.path.exists(target) and os.path.getsize(target) == size:
            skipped_existing += 1
            continue
        if not args.dry_run:
            shutil.copy2(e.path, target)
        copied += 1
        total_bytes += size

    print("source        %s" % src)
    print("destination   %s" % dst)
    print("strips found  %d" % len(entries))
    print("copied        %d  (%.1f MB)%s"
          % (copied, total_bytes / 1048576.0, "  [dry run]" if args.dry_run else ""))
    print("already there %d" % skipped_existing)

    if rejected:
        print("rejected      %d  (size not one GBACartEReaderScan decodes)" % len(rejected))
        for name, size in rejected:
            print("    %7d  %s" % (size, name))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
