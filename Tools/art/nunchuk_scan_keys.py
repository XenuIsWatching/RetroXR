"""Cut the Nunchuk's shell and its C and Z keys out of Wesk's laser scan and bake
them for gen_nunchuk.gd.

    blender --background --python Tools/glb/decimate_stl.py -- \
        --in <scan>/Top.stl --in <scan>/Bottom.stl --out /tmp/shell.stl --target 8000
    python Tools/art/nunchuk_scan_keys.py --scan <scan dir> --shell /tmp/shell.stl

Source: Wesk's "Wiimote Nunchuck Scan" on bitbuilt.net, released under the
Unlicense (public domain) -- bitbuilt.net/forums/threads/wesks-3d-scans-license.5444/
The scans are 250 MB and are NOT in this repo; this writes the small meshes that
are, into RetroXR/Tools/scan/. See that folder's LICENSE.txt.

The shell arrives already decimated, because Blender's Collapse is worth the
extra step on a surface this smooth -- vertex clustering, which is all this
script does for the keys, goes visibly lumpy when it is the main form rather
than a 15 mm button.

Everything is expressed in ONE frame, solved from the shell, and that is what
makes the placement trivial: with the shell coming from the scan too, each key
simply keeps the position it was scanned in. No seating, no bisection, no
estimate. The frame is centred on the shell's bounding box so the RigidBody's
origin sits near its centre of mass.

Solving that frame is the only subtle part. PCA gives the long axis and, because
a mirror-symmetric body always has its symmetry plane's normal as a principal
axis, the across/front pair too -- but their moments are within 2% (10.84 vs
10.65) so their ORDER is noise. The roll is settled by the one test that
discriminates: every cross-section of a moulded shell is left-right symmetric,
so max(x) + min(x) is zero slice by slice. Get it wrong and the body measures
43-45 mm across instead of the published 38.

The two keys are cut on a shared panel axis taken from Z's inertia tensor --
textbook for a flat near-square part, two near-equal in-plane moments (33.0,
29.0) and one distinct (16.4), giving 31.6 degrees. C's own tensor is useless
(34.7 / 11.2 / 7.6, no pair close: its stem dominates the cloud) and centroid
chords are worse still, giving 9.6 degrees for C against -24.8 for Z, which
cannot both describe one panel.

Winding is REVERSED on the way out. STL orders a facet counter-clockwise seen
from outside; Godot's front face is clockwise, so a straight copy bakes a part
you can see straight through.
"""
import argparse
import os
import struct

import numpy as np

# gen_nunchuk.gd's frame. Its loft runs Y_TOP..Y_TIP with the nose at +Y, its
# front face is -Z, and its axis sits AXIS_SHIFT in front of the scan's own PCA
# chord (that offset is what keeps both reaches positive on a body this bent).
GEN_Y_TOP, GEN_Y_TIP = 56.0, -57.0
AXIS_SHIFT = 2.0

CAP_KEEP = 5.5       # mm of key kept below its outermost point: cap plus a skirt
WELD = 0.45          # mm; vertex-cluster grid for the decimation


def load_stl(path, stride=1):
    with open(path, "rb") as f:
        f.seek(80)
        n = int(np.frombuffer(f.read(4), "<u4")[0])
        raw = np.fromfile(f, dtype=np.uint8, count=n * 50)
    raw = raw.reshape(n, 50)[::stride]
    return raw[:, 12:48].copy().view("<f4").reshape(-1, 3, 3).astype(np.float64)


def solve_frame(shell):
    """The scan's body frame. See Tools/scan notes: PCA gives the long axis and,
    because a mirror-symmetric body always has its symmetry-plane normal as a
    principal axis, the across/front pair too -- but their moments are within 2%
    so the ORDER is noise. The roll is settled by the one test that
    discriminates: every cross-section of a moulded shell is left-right
    symmetric, so max(x) + min(x) is zero slice by slice."""
    c = shell.mean(0)
    X = shell - c
    w, V = np.linalg.eigh((X.T @ X) / len(X))
    V = V[:, np.argsort(w)[::-1]]
    long_ax = V[:, 0]
    u0, v0 = V[:, 1], V[:, 2]
    s = X @ long_ax
    edges = np.linspace(s.min(), s.max(), 40)
    bo = np.clip(np.digitize(s, edges) - 1, 0, 38)
    ok = [b for b in range(3, 36) if (bo == b).sum() >= 200]

    def score(th):
        x = X @ (u0 * np.cos(th) + v0 * np.sin(th))
        return sum(abs(x[bo == b].max() + x[bo == b].min()) for b in ok)

    ths = np.linspace(0, np.pi, 361)
    best = ths[int(np.argmin([score(t) for t in ths]))]
    side = u0 * np.cos(best) + v0 * np.sin(best)
    front = np.cross(long_ax, side)
    front /= np.linalg.norm(front)
    return c, long_ax, side, front


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scan", required=True, help="directory holding the .stl files")
    ap.add_argument("--shell", help="pre-decimated Top+Bottom, from decimate_stl.py")
    ap.add_argument("--out", default=os.path.join("RetroXR", "Tools", "scan"))
    args = ap.parse_args()

    here = lambda n: os.path.join(args.scan, n)
    shell_t = load_stl(here("Top.stl"), 3).reshape(-1, 3)
    shell_b = load_stl(here("Bottom.stl"), 3).reshape(-1, 3)
    shell = np.vstack([shell_t, shell_b])
    keys = {"c": load_stl(here("C.stl")), "z": load_stl(here("Z.stl"))}

    c, long_ax, side, front = solve_frame(shell)
    probe = np.vstack([k.reshape(-1, 3) for k in keys.values()]).mean(0) - c
    if probe @ long_ax < 0:
        long_ax = -long_ax
    if probe @ front < 0:
        front, side = -front, -side
    R = np.vstack([side, long_ax, front])
    to_scan = lambda v: (v - c) @ R.T

    S = to_scan(shell)
    # Centre the controller frame on the shell's own box, so the RigidBody spins
    # about something near its centre of mass rather than about a scan origin.
    ctr = np.array([0.0, (S[:, 1].max() + S[:, 1].min()) * 0.5,
                    (S[:, 2].max() + S[:, 2].min()) * 0.5])
    NOSE, TAIL = S[:, 1].max(), S[:, 1].min()
    L = NOSE - TAIL

    def to_gen(q):
        """scan mm -> gen_nunchuk.gd's controller frame, metres. The generator's
        front face is -Z where the scan's is +Z, so that axis flips."""
        return np.stack([q[:, 0] - ctr[0], q[:, 1] - ctr[1], -(q[:, 2] - ctr[2])], 1) / 1000.0

    G = to_gen(S)
    print("controller frame: y %+.2f .. %+.2f mm   x +/-%.2f   z %+.2f .. %+.2f"
          % (G[:, 1].min() * 1000, G[:, 1].max() * 1000, np.ptp(G[:, 0]) * 500,
             G[:, 2].min() * 1000, G[:, 2].max() * 1000))
    print("  gen_nunchuk.gd:  Y_TOP = %.4f   Y_TIP = %.4f"
          % (G[:, 1].max(), G[:, 1].min()))

    os.makedirs(args.out, exist_ok=True)

    def write_tri(path, verts, idx):
        with open(path, "wb") as f:
            f.write(b"NCTR")
            f.write(struct.pack("<II", len(verts), len(idx)))
            f.write(verts.astype("<f4").tobytes())
            f.write(idx.astype("<u4").tobytes())
        return os.path.getsize(path)

    def weld(loc, grid):
        q = np.round(loc / grid).astype(np.int64)
        _, inv = np.unique(q, axis=0, return_inverse=True)
        verts = np.zeros((inv.max() + 1, 3))
        cnt = np.zeros(inv.max() + 1)
        np.add.at(verts, inv, loc)
        np.add.at(cnt, inv, 1.0)
        verts /= cnt[:, None]
        idx = inv.reshape(-1, 3)
        good = ((idx[:, 0] != idx[:, 1]) & (idx[:, 1] != idx[:, 2])
                & (idx[:, 0] != idx[:, 2]))
        idx = idx[good]
        used, idx = np.unique(idx, return_inverse=True)
        return verts[used], idx.reshape(-1, 3)

    if args.shell:
        sv = load_stl(args.shell).reshape(-1, 3)
        g = to_gen(to_scan(sv))
        # Already decimated by Blender, so weld only to index it -- 1 micron, far
        # below anything the Collapse pass left behind.
        verts, idx = weld(g, 1e-6)
        idx = idx[:, ::-1]
        path = os.path.join(args.out, "nunchuk_body.tri")
        kb = write_tri(path, verts, idx) // 1024
        span = (verts.max(0) - verts.min(0)) * 1000
        print("\nSHELL: %d tris, %d verts, %d KiB   %.2f x %.2f x %.2f mm"
              % (len(idx), len(verts), kb, span[0], span[1], span[2]))

    # one axis for both keys, from Z's inertia tensor
    zv = to_scan(keys["z"].reshape(-1, 3))
    d = zv - zv.mean(0)
    lam, E = np.linalg.eigh((d.T @ d) / len(d))
    order = np.argsort(lam)[::-1]
    lam, E = lam[order], E[:, order]
    axis = E[:, 0] if (lam[0] - lam[1]) > (lam[1] - lam[2]) else E[:, 2]
    if axis[2] < 0:
        axis = -axis
    axis[0] = 0.0
    axis /= np.linalg.norm(axis)
    print("panel axis from Z's inertia (moments %s): %.1f deg from horizontal"
          % (np.round(lam, 1), np.degrees(np.arctan2(axis[1], axis[2]))))

    for name, tris in keys.items():
        allv = to_scan(tris.reshape(-1, 3))
        p = allv @ axis
        cut = p.max() - CAP_KEEP
        keep = (p.reshape(-1, 3) > cut).all(1)
        tri = tris.reshape(-1, 3, 3)[keep]
        vk = to_scan(tri.reshape(-1, 3))
        base = vk[(vk @ axis) < cut + 0.8]
        o_scan = base.mean(0) if len(base) else vk.mean(0)
        o_scan = o_scan - axis * ((o_scan @ axis) - cut)

        n = np.array([0.0, axis[1], -axis[2]])
        n /= np.linalg.norm(n)
        o = to_gen(o_scan[None, :])[0]
        th = float(np.arctan2(n[2], n[1]))
        cs, sn = np.cos(th), np.sin(th)
        ya = n
        za = np.array([0.0, -sn, cs])

        g = to_gen(vk)
        loc = np.stack([g[:, 0] - o[0], (g - o) @ ya, (g - o) @ za], 1)
        verts, idx = weld(loc, WELD / 1000.0)
        idx = idx[:, ::-1]      # STL is CCW-out; Godot wants CW

        # Close the cut. An open mesh has no honest enclosed volume and no
        # outward normal at its rim, and gen_nunchuk's winding check reports the
        # whole key INSIDE OUT on -Y purely because the -Y extreme vertex is a
        # boundary vertex. Fanning the boundary loop to a point below the cut
        # closes it with consistent winding.
        e = np.concatenate([idx[:, [0, 1]], idx[:, [1, 2]], idx[:, [2, 0]]])
        uq, inv, cnt = np.unique(np.sort(e, axis=1), axis=0,
                                 return_inverse=True, return_counts=True)
        border = e[cnt[inv] == 1]
        if len(border):
            hub = len(verts)
            rim = verts[np.unique(border)]
            # 0.3 mm BELOW the lowest vertex, not level with it. Level, the hub
            # ties with a rim vertex for the -Y extreme and the winding check can
            # pick that one, whose normal points inward along the cut.
            verts = np.vstack([verts, [[rim[:, 0].mean(),
                                        verts[:, 1].min() - 0.0003,
                                        rim[:, 2].mean()]]])
            idx = np.vstack([idx, np.stack([border[:, 1], border[:, 0],
                                            np.full(len(border), hub)], 1)])

        path = os.path.join(args.out, "nunchuk_%s.tri" % name)
        kb = write_tri(path, verts, idx) // 1024

        span = (verts.max(0) - verts.min(0)) * 1000.0
        print("\n%s: %d tris in, %d kept, %d out  (%d verts, %d KiB)"
              % (name.upper(), len(tris), keep.sum(), len(idx), len(verts), kb))
        print("   local extent  across %.2f  along %.2f  proud %.2f mm"
              % (span[0], span[2], span[1]))
        print("   half-length along the body: %.4f m" % (span[2] / 2000.0))
        print("   transform = Transform3D(1, 0, 0, 0, %.5f, %.5f, 0, %.5f, %.5f, 0, %.5f, %.5f)"
              % (cs, -sn, sn, cs, o[1], o[2]))


if __name__ == "__main__":
    main()
