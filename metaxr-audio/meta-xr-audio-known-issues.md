# Meta XR Audio SDK v85 — findings from a native (non-Unity/Unreal) integration

Compiled 2026-07-29 while binding the SDK's native C API into a Godot 4.7 GDExtension
for a Quest 3 title, and **substantially revised 2026-07-30**. Reported in case any of
it is useful.

Each item is tagged with how confident I am, because I got several intermediate
conclusions wrong during this investigation before isolating the real causes. Anything
not marked **Confirmed** should be treated as a lead, not a bug report.

> ### Retraction — please disregard the 2026-07-29 revision
>
> That version led with an apparent **arm64 rendering defect**: redundant
> `mxra_source_set_position` calls injecting sidebands (80.8 % / 73.4 % / 96.0 % of
> in-band energy retained), plus a secondary report of off-axis renders landing in the
> opposite ear on arm64 versus x64.
>
> **Both were our bug, not the SDK's.** We had declared the position argument as a
> pointer, which is right on Windows x64 and wrong on AArch64 — see issue 1 below. Every
> call was therefore spatialising whatever happened to be in `s0`/`s1`/`s2`, so each
> redundant call moved the source somewhere random. That is precisely why the artefact
> scaled with call frequency and why x64 was immune.
>
> With the signature corrected, all four call-frequency cases measure **100.000 %**
> in-band on a Quest 3 with identical peak amplitude, and the orbit envelope is
> byte-identical to Windows. There is no arm64 rendering defect here.

---

## Environment

| | |
|---|---|
| SDK | Meta XR Audio SDK **v85.0.0** (`com.meta.xr.sdk.audio`, npm.developer.oculus.com) |
| `mxra_get_version` reports | `1.117.0` |
| Windows binary | `Runtime/Plugins/x86_64/MetaXRAudioUnity.dll` — 2,671,104 bytes, md5 `7569f2b2e04944966adccdcdc9e5155c` |
| Android binary | `Runtime/Plugins/Android/libs/arm64-v8a/libMetaXRAudioUnity.so` — 2,705,728 bytes, md5 `2ca91e8632d0239d7e34ce55d67a8a50` |
| Device | Quest 3, Horizon OS / Android 14, build `52433670016300520`, arm64-v8a |
| Host toolchain | MSVC 14.51.36231 (x64); NDK r27d clang, `aarch64-linux-android29` |
| API used | the undecorated `mxra_*` C entry points (103 symbols, identical set on both binaries) |

All measurements below come from rendering to WAV and analysing **both platforms with the
same numpy script** — never from measuring inside the code under test.

---

## 1. Vector/pose arguments are passed **by value**, so their ABI differs per platform — **Confirmed, and the single most expensive item here**

This is a documentation issue, not a code defect, but it cost more debugging time than
everything else combined and it fails *silently*: audio keeps playing, sources are simply
in the wrong places, and only on arm64.

`mxra_source_set_position` takes its position **by value**, as a 3-float aggregate — not
as a pointer. That distinction is invisible on Windows and fatal on Android:

| | Windows x64 | AArch64 (AAPCS64) |
|---|---|---|
| 3-float aggregate | hidden pointer in `r8` | **`s0`/`s1`/`s2`** (homogeneous float aggregate ≤ 4 members) |

So a single `const float*` declaration is correct on x64 and wrong on arm64, where the
callee reads the FP argument registers and the pointer is never dereferenced. The arm64
disassembly is unambiguous — the context and index checks, then straight to `s0`:

```
mxra_source_set_position:
    cbz     x0, <err>          ; context null check
    ...
    tbnz    w1, #0x1f, <err>   ; source index sign check
    fabs    s3, s0             ; <-- reads the coordinate from s0; x2 is never touched
```

Compare Windows x64, which dereferences the pointer (`movsd (%r8)` / `movl 0x8(%r8)`)
immediately after the same index check.

What makes this nasty is that **the obvious smoke test passes anyway.** A test that builds
`float pos[3]` from constants tends to leave those very values in `s0`–`s2` as a side
effect of materialising the array, so a pointer-declared binding renders correctly. Ours
did — including a Windows-vs-arm64 comparison that came out MD5-identical. The failure only
appeared once real code supplied positions from memory, where the FP registers hold
unrelated data.

`mxra_listener_set_pose` and `mxra_source_set_pose` are also by-value, but at 36 bytes the
pose exceeds both ABIs' register thresholds and is passed indirectly on each, so a pointer
declaration happens to work there. That inconsistency is itself a trap.

**Ask:** publishing the header (see the closing section) would eliminate this entire class
of problem. Failing that, stating the by-value convention in any native-API note would.

---

## 1b. `mxra_source_set_position` does not null-check its position argument — **Minor**

On x64, where the argument does arrive as a pointer, the function validates the context
pointer, the source index (sign *and* upper bound) and the finiteness of the components,
but dereferences the pointer without a null check — so a bad pointer faults inside the
library instead of returning `2001` like every neighbouring error path. Given how thorough
the rest of the validation is, this reads as an oversight. Low severity for correct callers.

---

## 2. `mxra_context_create` writes a context pointer even when it fails — **Confirmed**

`mxra_context_create(&ctx, &params)` with an invalid `params` returns `2001`
(invalid-parameter) **but still writes a non-null value to `*out_ctx`**.

```
create(&c, nullptr)                    -> 0,    c = valid
create(&c, &params_with_wrong_size)    -> 2001, c = NON-NULL but not initialised
```

A caller that checks the out-pointer rather than the return code proceeds with an
uninitialised context. Subsequent calls then either return `2005` or fault. Suggest either
leaving `*out_ctx` untouched on failure or nulling it.

---

## 3. `mxra_context_params` layout is undocumented and differs from the v47 config — **Documentation**

Recovered from the validation chain in `mxra_context_init`:

```c
struct mxra_context_params {
    uint32_t size;             // [0x00] must be EXACTLY 28 (0x1c)
    uint32_t max_num_sources;  // [0x04] >= 1
    uint32_t sample_rate;      // [0x08] 16000 .. 48000 inclusive
    uint32_t buffer_length;    // [0x0c] 128 .. 65536, and must be <= sample_rate
    uint32_t flags;            // [0x10] read as a byte; bit 4 forces a mutex re-create
    uint32_t mode;             // [0x14] must be <= 8
    uint32_t reserved;         // [0x18]
};
```

The trap: this is **not** the legacy `ovrAudioContextConfiguration`. `size` is 32-bit here,
not 64-bit, and there is no `provider` field. Anyone porting from the documented v47 native
API will pass a 24-byte struct with a 64-bit size, get `2001`, and — per issue 2 — receive a
context pointer anyway.

`buffer_length` is also the fixed block size for the whole context: `mxra_source_process`
takes no frame count and reads it from here.

---

## 4. `mxra_source_process` takes a recursive mutex — **Confirmed behaviour, design concern**

`mxra_source_process` calls `ovrAudioInternal_LockRecursiveMutex` on every invocation
(visible in the arm64 disassembly at `mxra_source_process+0x13c`). For a real-time audio
callback this means:

- a lock is taken per source, per block, on the audio thread;
- any main-thread call into the same context (setting a pose, changing room parameters) can
  contend with the audio thread.

Not a bug, but it is not documented, and it forces integrators to funnel *all* context
mutation through a queue drained on the audio thread. Worth stating explicitly in any
future native documentation.

---

## 5. No distance attenuation by default; only one of four modes attenuates — **Confirmed behaviour**

Measured on **Windows x64**, where the position ABI in issue 1 was correct; the clean
monotonic curve for mode 2 below is itself evidence the positions were being applied. Not
re-measured on arm64 since the correction, so treat the platform scope as x64-only.

A newly created context applies **no distance law at all** — a source at 4 m measures the
same level as at 1 m. Of the modes accepted by `mxra_source_set_attenuation` (validated
`<= 2`, and 3 is accepted too), only **mode 2** attenuates:

| mode | 0.5 m | 1 m | 4 m | 10 m |
|---|---|---|---|---|
| (none set) | −26.4 | −24.0 | −24.0 | −24.0 dB |
| 0 | −26.4 | −24.0 | −24.0 | −24.0 dB |
| 1 | −26.4 | −24.0 | −24.0 | −24.0 dB |
| **2** | −26.4 | −42.3 | −59.2 | −67.9 dB |
| 3 | −26.4 | −24.0 | −24.0 | −24.0 dB |

Mode 2's curve is also steeper than inverse-distance (≈ −18 dB per 4× rather than −12 dB),
which put a source 4.8 m away at −44 dB — inaudible in a normal room mix. We ended up
applying the engine's own inverse-distance law through the gain parameter instead.

Modes 0, 1 and 3 returning success while doing nothing is the part worth fixing — silent
no-ops are hard to distinguish from a wiring mistake.

---

## 6. ~~Cross-platform render divergence for off-axis sources~~ — **RETRACTED**

Previously reported as an unconfirmed lead: off-axis sources rendering to the opposite ear
on arm64 (ILD −4.31 dB on Windows, +4.11 dB on arm64) while static on-axis sources matched
bit-for-bit.

Root-caused to issue 1 — our pointer-vs-by-value error. The static on-axis case matched
because the position happened to survive in the FP registers; off-axis cases did not.
Nothing here for Meta to action.

---

## Note for anyone reproducing this: FMA contraction

This one was **our bug, not the SDK's**, but it wasted hours and will bite anyone doing
cross-platform bit-exact comparison:

Clang contracts `a*b+c` into a single FMA by default on ARM; MSVC does not. That alone made
our test *signal* differ between platforms and looked exactly like an SDK defect. Building
the NDK side with `-ffp-contract=off` made the generator hash match Windows exactly
(`0x5a14a1bc97ae400f` on both).

Any cross-platform comparison of this SDK should disable FP contraction first, or it will
generate phantom bugs.

(An earlier revision used this to explain why static renders matched across platforms while
moving ones diverged. That explanation was wrong — the real cause was issue 1. The FMA
observation itself still holds and still needs disabling.)

---

## Context: why we were on the native API at all

Not a bug, but it is the reason all of the above had to be reverse-engineered:

- v85 ships only as Unity / Unreal / FMOD / Wwise plugins. There is no native/C++ package.
- The legacy native download (`oculus-spatializer-native`, v47, Dec 2022) is the last one
  with published headers and reference docs, and its API differs from the current one.
- The current `mxra_*` C API has **no published header and no reference documentation**
  anywhere I could find, though it is clearly the intended stable ABI: 103 undecorated
  symbols, byte-identical between the Windows and Android binaries.
- We recovered signatures from the MSVC-mangled C++ exports (which encode full parameter
  types) plus targeted disassembly.

Publishing `MetaXRAudio*.h` and the `mxra_*` reference — even as-is, unsupported, alongside
the feature freeze — would make the SDK usable from engines Meta doesn't ship plugins for,
at essentially zero cost.

## Performance, for reference

Measured on Quest 3, since no per-source figure is published. 256-frame block at 48 kHz
(5.333 ms real-time budget), one `mxra_source_process` per source per block:

| sources | µs/source/block | % of real-time budget |
|---|---|---|
| 8 | 4.7 | 0.70 % |
| 16 | 4.7 | 1.41 % |
| 32 | 5.0 | 2.99 % |

Linear, ~5 µs per source. Cost is not a concern — this was the risk we expected to find and
did not.
