# Opaque prop pass: Quest 3 results, 2026-09-08

`pbr_prop_unshaded.gdshader` stopped writing `ALPHA`. Nothing else differs
between the two arms: same UV, normal and GI code, same textures, same boxes.

## Measured GPU viewport time

| Layers | Reference ms | Fixed ms | Saved ms | Saved % | Paired savings range ms | Reference/fixed p95 ms |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 4.975 | 4.829 | +0.146 | +2.9% | -0.003 to +0.384 | 5.164 / 5.009 |
| 4 | 7.646 | 4.673 | +2.973 | +38.9% | +1.651 to +2.973 | 7.972 / 4.942 |

Each value is the median of three run medians (p95 likewise). Each run is 600
measured frames after 120 settling frames, AB/BA/AB after warming both arms;
12 runs, 7,200 measured frames. Positive savings means faster. Raw samples are
in [quest3-opaque.json](results/quest3-opaque.json).

Quest 3 / Adreno 740, Godot 4.7.2.stable Vulkan Mobile, stereo **2520x2640 per
eye** (the 1.5x render target multiplier the app keeps for sharpness), 2x MSAA,
foveation off, 72 Hz confirmed in VrApi logs (FPS=72-73/72 throughout, a
handful of 79s at scene changes). GPU clock sat at 492 MHz for most of the run
and 545 MHz for the rest, with battery temperature at 39-40 C; the pairs that
straddled a clock change are why the four-layer paired range is 1.65-2.97 ms
rather than a point. Each arm was at both clocks at least once, and the fixed
arm's worst run (4.91 ms) is still below the reference arm's best (6.28 ms).

## Reading it

One layer is the null case: 35 boxes that cover nothing, so early depth
rejection has nothing to reject and the two arms are the same shader with
one blend state apart. Four layers is three layers of covered geometry. The
reference arm shades every fragment of every layer because a transparent-pass
draw writes no depth and cannot be sorted front to back; the fixed arm shades
the front layer and rejects most of the rest. The 3 ms it saves is the
fragment cost of three hidden layers of a 0.2 clk/frag shader at this eye
size, and it scales with how much of the view is covered geometry rather
than with anything in the shader.

In the arcade that covered geometry is every console behind a television,
every cable behind a console and the room walls behind everything, all of
which `PropLighting` puts on this shader. The bench is synthetic and the
number is not an arcade frame time; it is the ceiling on what one blend-state
bit was costing per covered layer.

## Correctness

The desktop visual run (RTX 5070 Ti, Vulkan Mobile) passed all three checks:
the arms render byte-identical colour, a later transparent draw behind the
fixed arm's box is depth-rejected, and the same draw shows through the
reference arm's box. The last check is what makes the first two mean
something: the reference arm really does exhibit the bug the fixed arm lacks.
