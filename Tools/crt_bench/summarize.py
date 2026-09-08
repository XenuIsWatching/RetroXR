"""Summarize raw probe timings, retaining paired-run variability.

python Tools/crt_bench/summarize.py timings.json

"Before" is the first variant of the run's pair and "after" the second; the
2026-09-07 reference/optimized file predates the pair field and is read as
reference -> optimized.
"""
import json
from pathlib import Path
import statistics as st
import sys

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8-sig"))
before_name, after_name = data["metadata"].get("pair", ["reference", "optimized"])
print(f"Pair: {before_name} -> {after_name}")
print("| TVs | Distance | Before ms | After ms | Saved ms | Saved % | Paired savings range ms | Before/after p95 ms |")
print("|---:|---:|---:|---:|---:|---:|---:|---:|")
for key in sorted({(r["count"], r["distance"]) for r in data["runs"]}):
    runs = [r for r in data["runs"] if (r["count"], r["distance"]) == key]
    before = sorted([r for r in runs if r["variant"] == before_name], key=lambda r: r["repeat"])
    after = sorted([r for r in runs if r["variant"] == after_name], key=lambda r: r["repeat"])
    if len(before) != 3 or len(after) != 3:
        print(f"Incomplete scenario {key}: {len(before)} before, {len(after)} after", file=sys.stderr)
        continue
    assert all(len(r["samples_ms"]) == 600 and min(r["samples_ms"]) > 0 for r in runs)
    a = st.median(r["median_ms"] for r in before)
    b = st.median(r["median_ms"] for r in after)
    deltas = [x["median_ms"] - y["median_ms"] for x, y in zip(before, after)]
    p95a = st.median(r["p95_ms"] for r in before)
    p95b = st.median(r["p95_ms"] for r in after)
    print(f"| {key[0]} | {key[1]:.2f} m | {a:.3f} | {b:.3f} | {a-b:+.3f} | {(a-b)/a*100:+.1f}% | {min(deltas):+.3f} to {max(deltas):+.3f} | {p95a:.3f} / {p95b:.3f} |")
