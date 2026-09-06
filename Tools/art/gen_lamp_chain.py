#!/usr/bin/env python3
"""Generate lamp pull-chain sounds: the bead rattle and the switch snap.

Synthesised rather than sampled. The one properly-licensed recording found
(mshahen's "Pull Chain Light Switch Desk Lamp" on Freesound, CC BY 4.0) is gated
behind an account, and these components are individually meaningful, so "more
rattle, softer click" is a number here rather than another hunt.

A pull-chain lamp makes three distinct sounds, and the whole point is that they
happen in sequence rather than as one blob:

  * BEAD RATTLE as the chain is drawn — a train of tiny brass balls knocking
    together. Each is a hard, light impact: a couple of milliseconds of contact
    noise exciting high resonant modes that die almost immediately.
  * The SWITCH SNAP — a rotary snap-action detent going over centre. Sharper and
    louder than a bead, and it excites the lamp's metal HOUSING, so it carries
    low modes a bead never does. That contrast is what makes it read as a switch
    rather than another bead.
  * RECOIL — the chain springing back and dangling, so the rattle returns after
    the snap, sparser and decaying.

    python3 Tools/art/gen_lamp_chain.py [OUT_DIR]

48 kHz mono WAVs. Note the shipping target may not be 48 kHz: the Quest reports
44100 whatever project.godot asks for, so whatever consumes these must build its
buffer against AudioServer.get_mix_rate() rather than assuming.
"""

import os
import sys
import wave

import numpy as np

SR = 48000


def _n(seconds):
    return int(round(seconds * SR))


def modes(dur, freqs, decays, amps, seed=0):
    """Sum of exponentially damped sinusoids — a struck metal object's ring.

    Real impacts are inharmonic: brass balls and switch housings ring at ratios
    that are not integer multiples, which is why the frequencies below are not a
    harmonic series. Making them harmonic makes it sound like a tuned bell.
    """
    n = _n(dur)
    t = np.arange(n) / SR
    rng = np.random.default_rng(seed)
    out = np.zeros(n)
    for f, d, a in zip(freqs, decays, amps):
        phase = rng.random() * 2.0 * np.pi
        out += a * np.sin(2.0 * np.pi * f * t + phase) * np.exp(-t / d)
    return out


def contact(dur, amp, lo, hi, decay, seed=0):
    """The click of two things touching: a very short filtered noise burst."""
    n = _n(dur)
    rng = np.random.default_rng(seed)
    x = rng.standard_normal(n)
    spec = np.fft.rfft(x)
    f = np.fft.rfftfreq(n, 1.0 / SR)
    spec[(f < lo) | (f > hi)] = 0.0
    x = np.fft.irfft(spec, n)
    t = np.arange(n) / SR
    x *= np.exp(-t / decay)
    peak = np.max(np.abs(x))
    return (amp * x / peak) if peak > 0 else x


def bead(seed=0, pitch=1.0, amp=1.0):
    """One brass ball striking another. Tiny, bright, gone in ~20 ms."""
    dur = 0.045
    f = np.array([4200.0, 6100.0, 7900.0, 9600.0]) * pitch
    x = modes(dur, f, [0.010, 0.007, 0.005, 0.0035], [1.0, 0.7, 0.45, 0.3], seed)
    x += contact(dur, 0.9, 2500.0, 12000.0, 0.0018, seed + 1)
    peak = np.max(np.abs(x))
    return (amp * x / peak) if peak > 0 else x


def snap(seed=0, body=1.0, amp=1.0, bright=1.0):
    """The switch detent going over centre.

    Carries LOW modes (the lamp housing) as well as high ones. A bead has no
    equivalent, which is the whole difference between "click" and "tick".
    """
    dur = 0.16
    f = np.array([420.0, 980.0, 1730.0, 3100.0, 5400.0]) * body
    x = modes(dur, f, [0.030, 0.020, 0.012, 0.007, 0.004],
              [1.0, 0.85, 0.6, 0.4, 0.25], seed)
    x += contact(dur, 1.1 * bright, 1200.0, 11000.0, 0.0022, seed + 3)
    peak = np.max(np.abs(x))
    return (amp * x / peak) if peak > 0 else x


def rattle(dur, count, amp=1.0, pitch_spread=0.22, seed=0, envelope=None):
    """A train of bead impacts scattered over `dur`.

    Timing is random rather than regular: an evenly-spaced train reads as a
    machine-gun buzz, not a chain.
    """
    n = _n(dur)
    out = np.zeros(n + _n(0.06))
    rng = np.random.default_rng(seed)
    for i in range(count):
        at = _n(rng.uniform(0.0, dur))
        p = 1.0 + rng.uniform(-pitch_spread, pitch_spread)
        a = rng.uniform(0.35, 1.0)
        if envelope is not None:
            a *= float(envelope(at / float(max(1, n))))
        b = bead(seed=seed * 97 + i, pitch=p, amp=a)
        out[at:at + len(b)] += b
    peak = np.max(np.abs(out))
    return (amp * out / peak) if peak > 0 else out


def _mix(*parts):
    """Overlay (offset_seconds, signal) pairs onto one buffer."""
    total = max(_n(off) + len(sig) for off, sig in parts)
    out = np.zeros(total)
    for off, sig in parts:
        a = _n(off)
        out[a:a + len(sig)] += sig
    return out


def pull(draw=0.13, draw_beads=7, snap_at=0.15, recoil=0.55, recoil_beads=9,
         body=1.0, snap_amp=1.0, rattle_amp=0.55, seed=1):
    """Full pull: chain drawn, switch snaps, chain recoils and dangles."""
    drawn = rattle(draw, draw_beads, amp=rattle_amp, seed=seed,
                   envelope=lambda u: 0.5 + 0.5 * u)          # builds as it tightens
    click = snap(seed=seed + 11, body=body, amp=snap_amp)
    back = rattle(recoil, recoil_beads, amp=rattle_amp * 0.85, seed=seed + 23,
                  envelope=lambda u: (1.0 - u) ** 1.6)        # dies away
    return _mix((0.0, drawn), (snap_at, click), (snap_at + 0.045, back))


def write(path, x, peak=0.6):
    m = np.max(np.abs(x))
    if m > 0:
        x = x / m * peak
    pcm = np.clip(x * 32767.0, -32768, 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    return len(pcm) / SR


# Off is not a different mechanism — the same detent going the other way — so the
# variants differ only in body pitch and recoil, the way the real thing does.
VARIANTS = {
    "a_crisp_on":    dict(draw=0.10, draw_beads=6, snap_at=0.12, recoil=0.40,
                          recoil_beads=7, body=1.12, snap_amp=1.0, rattle_amp=0.45, seed=1),
    "a_crisp_off":   dict(draw=0.10, draw_beads=6, snap_at=0.12, recoil=0.44,
                          recoil_beads=8, body=1.04, snap_amp=0.94, rattle_amp=0.45, seed=5),
    "b_heavier_on":  dict(draw=0.16, draw_beads=9, snap_at=0.18, recoil=0.70,
                          recoil_beads=12, body=0.82, snap_amp=1.0, rattle_amp=0.62, seed=2),
    "b_heavier_off": dict(draw=0.16, draw_beads=9, snap_at=0.18, recoil=0.75,
                          recoil_beads=13, body=0.76, snap_amp=0.95, rattle_amp=0.62, seed=6),
    "c_loose_on":    dict(draw=0.22, draw_beads=13, snap_at=0.24, recoil=1.00,
                          recoil_beads=18, body=0.95, snap_amp=0.9, rattle_amp=0.78, seed=3),
    "c_loose_off":   dict(draw=0.22, draw_beads=13, snap_at=0.24, recoil=1.05,
                          recoil_beads=19, body=0.9, snap_amp=0.86, rattle_amp=0.78, seed=7),
}


if __name__ == "__main__":
    out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(__file__), "..", "RetroXR", "Audio", "lamp")
    os.makedirs(out_dir, exist_ok=True)
    for name, kw in VARIANTS.items():
        secs = write(os.path.join(out_dir, "pull_%s.wav" % name), pull(**kw))
        print("wrote pull_%-14s %.2f s" % (name + ".wav", secs))
    # The rattle on its own, for the cord being handled without the switch firing.
    secs = write(os.path.join(out_dir, "rattle_handle.wav"),
                 rattle(0.75, 14, amp=0.7, seed=41,
                        envelope=lambda u: 0.35 + 0.65 * np.sin(np.pi * u)))
    print("wrote %-19s %.2f s" % ("rattle_handle.wav", secs))
    # A bare click, if the chain noise turns out to be too busy in the room.
    secs = write(os.path.join(out_dir, "click_bare.wav"), snap(seed=9, body=1.0))
    print("wrote %-19s %.2f s" % ("click_bare.wav", secs))
