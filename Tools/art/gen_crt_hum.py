#!/usr/bin/env python3
"""Generate CRT television idle hum and power-on/off transients.

Synthesised from the actual physics of a CRT set rather than sampled, for two
reasons. Every "CRT hum" recording that turns up in a search is either
unlicensed, licensed for personal use only (the BBC RemArc library), or behind a
login with per-file terms that vary — and this app ships. Second, the components
are individually meaningful, so a note like "more hiss, less whine" is a number
change here rather than another hunt.

What a CRT actually emits:

  * FLYBACK WHINE at the horizontal line rate. 15734.264 Hz on NTSC, 15625 Hz on
    PAL. This is the iconic CRT sound, radiated mechanically by the flyback
    transformer's windings and core. It is right at the edge of adult hearing;
    plenty of people over about 25 cannot hear it at all, which is exactly why it
    is offered at several levels below.
  * MAINS BUZZ from the power transformer, at twice the line frequency (120 Hz in
    North America) with odd harmonics above it, because core magnetostriction
    tracks the absolute value of the current.
  * HISS, broadband, which is the audible half of a no-signal screen — the same
    thermal noise that draws the snow.
  * A DEGAUSS THUNK at switch-on as the degaussing coil fires: a low thump plus
    the mechanical clack of the coil against the funnel.

    python3 Tools/art/gen_crt_hum.py

Writes 48 kHz mono WAVs. Idle loops are exactly periodic — every component
completes a whole number of cycles in the loop, and the noise is built in the
frequency domain from random phases, so an inverse FFT is inherently seamless.
No click at the loop point, no crossfade needed.
"""

import os
import struct
import wave

import numpy as np

SR = 48000
LOOP = 4.0                      # seconds; 240 whole cycles of 60 Hz
NTSC_LINE = 15734.264

OUT = os.path.join(os.path.dirname(__file__), "..", "RetroXR", "Audio", "crt")
if len(__import__("sys").argv) > 1:
    OUT = __import__("sys").argv[1]


def _n(seconds):
    return int(round(seconds * SR))


def _fit(freq, seconds):
    """Nearest frequency completing a whole number of cycles in `seconds`."""
    return max(1, round(freq * seconds)) / seconds


def tone(freq, seconds, amp, wobble_hz=0.0, wobble_cents=0.0):
    """Sine at a loop-safe frequency, optionally with slow pitch drift."""
    n = _n(seconds)
    t = np.arange(n) / SR
    f = _fit(freq, seconds)
    if wobble_cents > 0.0:
        # Drift also has to close the loop, so its rate is fitted too.
        wf = _fit(wobble_hz, seconds)
        cents = wobble_cents * np.sin(2 * np.pi * wf * t)
        phase = 2 * np.pi * np.cumsum(f * (2.0 ** (cents / 1200.0))) / SR
    else:
        phase = 2 * np.pi * f * t
    return amp * np.sin(phase)


def noise(seconds, amp, lo=120.0, hi=13000.0, tilt=0.0, seed=0):
    """Band-limited noise, exactly periodic over `seconds`.

    Built as a spectrum with random phase and inverse-transformed, so the result
    wraps with no discontinuity. `tilt` in dB/octave shades it: negative is
    darker, 0 is flat (white).
    """
    n = _n(seconds)
    rng = np.random.default_rng(seed)
    freqs = np.fft.rfftfreq(n, 1.0 / SR)
    mag = np.zeros_like(freqs)
    band = (freqs >= lo) & (freqs <= hi)
    mag[band] = 1.0
    # Soft shoulders, or the band edges ring.
    lo_edge = (freqs > lo * 0.4) & (freqs < lo)
    mag[lo_edge] = (freqs[lo_edge] / lo) ** 2
    hi_edge = (freqs > hi) & (freqs < hi * 2.2)
    mag[hi_edge] = (hi / freqs[hi_edge]) ** 2
    if tilt != 0.0:
        ref = 1000.0
        with np.errstate(divide="ignore", invalid="ignore"):
            octaves = np.log2(np.maximum(freqs, 1e-9) / ref)
        mag = mag * (10.0 ** (tilt * octaves / 20.0))
    mag[0] = 0.0
    spec = mag * np.exp(2j * np.pi * rng.random(len(freqs)))
    x = np.fft.irfft(spec, n)
    peak = np.max(np.abs(x))
    return (amp * x / peak) if peak > 0 else x


def transformer_buzz(seconds, amp, mains=60.0):
    """Core magnetostriction: strongest at 2x mains, with decaying harmonics."""
    out = np.zeros(_n(seconds))
    for mult, rel in ((1, 0.25), (2, 1.0), (3, 0.45), (4, 0.30), (5, 0.16), (6, 0.10)):
        out += tone(mains * mult, seconds, rel)
    return amp * out / np.max(np.abs(out))


def ticks(seconds, amp, count=6, seed=1):
    """Sparse thermal ticks from the case and chassis expanding.

    Kept clear of both ends of the loop so nothing is clipped at the seam.
    """
    n = _n(seconds)
    out = np.zeros(n)
    rng = np.random.default_rng(seed)
    guard = _n(0.08)
    for _ in range(count):
        at = rng.integers(guard, n - guard)
        dur = _n(rng.uniform(0.004, 0.012))
        env = np.exp(-np.linspace(0, 9, dur))
        click = rng.standard_normal(dur) * env
        out[at:at + dur] += click * rng.uniform(0.4, 1.0)
    peak = np.max(np.abs(out))
    return (amp * out / peak) if peak > 0 else out


def write(path, x, peak=0.5):
    """Normalise to `peak` and write 16-bit mono."""
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


# --------------------------------------------------------------------------
# Idle loops. Levels are relative within each mix; the file is normalised, so
# what differs between variants is the BALANCE, not the loudness.
# --------------------------------------------------------------------------
def idle(whine, buzz, hiss, tick=0.0, wobble=False, pal=False, seed=0):
    line = 15625.0 if pal else NTSC_LINE
    x = np.zeros(_n(LOOP))
    if whine > 0.0:
        x += tone(line, LOOP, whine,
                  wobble_hz=0.7 if wobble else 0.0,
                  wobble_cents=6.0 if wobble else 0.0)
        # NO second harmonic. 15734 x 2 = 31469 Hz is above the 24 kHz Nyquist
        # limit at 48 kHz, so it does not reproduce — it ALIASES back to
        # 48000 - 31469 = 16531 Hz, an inharmonic whistle a fifth above the
        # whine. A spectrum check caught it sitting only 15 dB down.
    if buzz > 0.0:
        x += transformer_buzz(LOOP, buzz)
    if hiss > 0.0:
        x += noise(LOOP, hiss, lo=140.0, hi=12500.0, tilt=-1.5, seed=seed)
    if tick > 0.0:
        x += ticks(LOOP, tick, seed=seed + 5)
    return x


def _steady(seconds, whine, buzz, hiss, pal=False, seed=7, env=None):
    """The idle mix, rendered over an arbitrary length with an optional envelope.

    Transients are built from THIS so that what a power-on fades up to, and what
    a power-off starts from, is bit-for-bit the same recipe as the loop it hands
    off to. Hardcoding the transients was the first version's mistake: they
    carried hiss at 0.30 and buzz at 0.22 regardless of the idle variant, so
    against the whine-only loop the power-on faded in a hiss bed that then
    vanished the instant the loop started.
    """
    line = 15625.0 if pal else NTSC_LINE
    n = _n(seconds)
    t = np.arange(n) / SR
    if env is None:
        env = np.ones(n)
    x = np.zeros(n)
    if whine > 0.0:
        x += whine * np.sin(2 * np.pi * line * t) * env
    if buzz > 0.0:
        x += transformer_buzz(seconds, buzz) * env
    if hiss > 0.0:
        x += noise(seconds, hiss, lo=140.0, hi=12500.0, tilt=-1.5, seed=seed) * env
    return x


def _degauss(seconds, thump=0.9, clack=0.5, seed=11):
    """The degaussing coil firing: a low thump plus its mechanical clack."""
    n = _n(seconds)
    t = np.arange(n) / SR
    env = np.exp(-t * 14.0)
    out = (np.sin(2 * np.pi * 46.0 * t) * thump
           + np.sin(2 * np.pi * 92.0 * t) * thump * 0.33) * env
    if clack > 0.0:
        rng = np.random.default_rng(seed)
        k = _n(0.05)
        out[:k] += rng.standard_normal(k) * np.exp(-np.linspace(0, 7, k)) * clack
    return out


def power_on(idle_kw, dur=1.4, rise=0.30, thump=0.9, clack=0.5, glide=0.45):
    """Degauss, then the set coming up to its idle state.

    Returns (steady, events) so the caller can gain them separately: the steady
    part has to match the idle loop exactly, while a one-shot thump is allowed to
    peak above it the way a real degauss does.
    """
    n = _n(dur)
    t = np.arange(n) / SR
    ramp = np.clip(t / rise, 0.0, 1.0)
    line = 15625.0 if idle_kw.get("pal") else NTSC_LINE

    # The whine also slides up to pitch as the flyback comes to frequency, so it
    # cannot come from _steady's fixed-frequency tone.
    f = line * (1.0 - glide * (1.0 - ramp))
    steady = np.zeros(n)
    if idle_kw.get("whine", 0.0) > 0.0:
        steady += idle_kw["whine"] * np.sin(2 * np.pi * np.cumsum(f) / SR) * ramp
    rest = dict(idle_kw)
    rest["whine"] = 0.0
    steady += _steady(dur, env=ramp, **rest)
    return steady, _degauss(dur, thump=thump, clack=clack)


def power_off(idle_kw, dur=0.9, fall=0.35, thump=0.5, clunk=0.35, glide=0.6):
    """Idle state collapsing: whine slides down and away, relay clunks."""
    n = _n(dur)
    t = np.arange(n) / SR
    env = np.clip(1.0 - t / fall, 0.0, 1.0) ** 1.5
    line = 15625.0 if idle_kw.get("pal") else NTSC_LINE

    f = line * (1.0 - glide * (1.0 - env))
    steady = np.zeros(n)
    if idle_kw.get("whine", 0.0) > 0.0:
        steady += idle_kw["whine"] * np.sin(2 * np.pi * np.cumsum(f) / SR) * env
    rest = dict(idle_kw)
    rest["whine"] = 0.0
    steady += _steady(dur, env=env, **rest)

    events = np.sin(2 * np.pi * 55.0 * t) * np.exp(-t * 20.0) * thump
    if clunk > 0.0:
        rng = np.random.default_rng(12)
        k = _n(0.04)
        events[:k] += rng.standard_normal(k) * np.exp(-np.linspace(0, 8, k)) * clunk
    return steady, events


VARIANTS = {
    # name:                        whine buzz  hiss  tick  wobble
    "idle_a_whine_only":     dict(whine=0.22, buzz=0.05, hiss=0.00),
    "idle_b_transformer":    dict(whine=0.04, buzz=0.30, hiss=0.00),
    "idle_c_static_heavy":   dict(whine=0.08, buzz=0.14, hiss=0.34),
    "idle_d_balanced":       dict(whine=0.14, buzz=0.16, hiss=0.18),
    "idle_e_aged_set":       dict(whine=0.16, buzz=0.20, hiss=0.20, tick=0.22, wobble=True),
    "idle_f_pal_balanced":   dict(whine=0.14, buzz=0.16, hiss=0.18, pal=True),
}

# Transient flavours, all matched to whichever idle mix is passed in.
ON_FLAVOURS = {
    "on_1_minimal":     dict(dur=1.3, rise=0.28, thump=0.85, clack=0.0, glide=0.40),
    "on_2_clack":       dict(dur=1.4, rise=0.30, thump=0.90, clack=0.45, glide=0.45),
    "on_3_slow_warmup": dict(dur=2.0, rise=0.85, thump=0.60, clack=0.20, glide=0.55),
}
OFF_FLAVOURS = {
    "off_1_quick": dict(dur=0.8, fall=0.30, thump=0.26, clunk=0.20, glide=0.55),
    "off_2_coast": dict(dur=1.5, fall=0.95, thump=0.18, clunk=0.12, glide=0.75),
}

PEAK = 0.5          # idle loops land here; transients share the same gain
CEILING = 0.92      # transient ceiling, leaving headroom for the emitter


def matched_set(idle_name, out_dir):
    """Write an idle loop and every transient flavour on ONE shared gain.

    Independently normalising each file was the other half of the mismatch: the
    loop went to 0.5 peak and the transients to 0.7, so the level jumped at the
    handoff even when the spectra agreed.
    """
    kw = VARIANTS[idle_name]
    idle_x = idle(seed=7, **kw)
    m = float(np.max(np.abs(idle_x)))
    g = PEAK / m if m > 0 else 1.0

    written = [(idle_name + ".wav", write(os.path.join(out_dir, idle_name + ".wav"),
                                         idle_x, peak=PEAK))]
    steady_kw = {k: v for k, v in kw.items() if k in ("whine", "buzz", "hiss", "pal")}

    for label, flavours, fn in (("on", ON_FLAVOURS, power_on),
                                ("off", OFF_FLAVOURS, power_off)):
        for fname, fkw in flavours.items():
            steady, events = fn(steady_kw, **fkw)
            # Only the one-shot gives way, so the steady portion still lines up
            # with the loop. Scaling events by ceiling/peak does NOT bound the
            # sum — the sum's peak sits at a different sample than the events'
            # peak, which let the power-offs clip at full scale. Bisect instead.
            x = (steady + events) * g
            if float(np.max(np.abs(x))) > CEILING:
                lo, hi = 0.0, 1.0
                for _ in range(40):
                    mid = 0.5 * (lo + hi)
                    if float(np.max(np.abs((steady + events * mid) * g))) > CEILING:
                        hi = mid
                    else:
                        lo = mid
                x = (steady + events * lo) * g
            path = os.path.join(out_dir, fname + ".wav")
            pcm = np.clip(x * 32767.0, -32768, 32767).astype("<i2")
            with wave.open(path, "wb") as w:
                w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
                w.writeframes(pcm.tobytes())
            written.append((fname + ".wav", len(pcm) / SR))

            # Prove the handoff: the tail of an on (or head of an off) must have
            # the same RMS as the loop it meets.
            ref = float(np.sqrt(np.mean((idle_x * g) ** 2)))
            seg = x[-_n(0.2):] if label == "on" else x[:_n(0.2)]
            got = float(np.sqrt(np.mean(seg ** 2)))
            print("    %-16s handoff RMS %.5f vs loop %.5f  (%+.1f%%)" % (
                fname, got, ref, 100.0 * (got / ref - 1.0) if ref > 0 else 0.0))
    return written


if __name__ == "__main__":
    import sys
    which = sys.argv[2] if len(sys.argv) > 2 else "idle_a_whine_only"
    os.makedirs(OUT, exist_ok=True)
    print("matched set for %s:" % which)
    for name, secs in matched_set(which, OUT):
        print("  wrote %-24s %.2f s" % (name, secs))
