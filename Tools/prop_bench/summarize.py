"""Summarize a prop_bench timings.json: python Tools/prop_bench/summarize.py timings.json"""
import json
import statistics
import sys

runs = json.load(open(sys.argv[1]))
NAMES = {0: "reference (ALPHA written)", 1: "fixed (opaque)"}
print(f"eye size {runs[0]['eye_size']}, {len(runs)} runs")
for layers in sorted({r["layers"] for r in runs}):
    rows = [r for r in runs if r["layers"] == layers]
    by = {v: [r for r in rows if r["variant"] == v] for v in (0, 1)}
    med = {v: statistics.median(r["median_ms"] for r in by[v]) for v in (0, 1)}
    p95 = {v: statistics.median(r["p95_ms"] for r in by[v]) for v in (0, 1)}
    pairs = []
    for rep in sorted({r["repeat"] for r in rows}):
        a = next(r for r in rows if r["repeat"] == rep and r["variant"] == 0)
        b = next(r for r in rows if r["repeat"] == rep and r["variant"] == 1)
        pairs.append(a["median_ms"] - b["median_ms"])
    saved = med[0] - med[1]
    print(f"layers={layers}: {NAMES[0]} {med[0]:.3f} ms, {NAMES[1]} {med[1]:.3f} ms, "
          f"saved {saved:+.3f} ms ({saved / med[0] * 100:+.1f}%), "
          f"paired {min(pairs):+.3f} to {max(pairs):+.3f} ms, p95 {p95[0]:.3f} / {p95[1]:.3f}")
