"""Locate Wii Sports' hand pointer in a captured frame.

The glove is outlined in one very specific royal blue, [18, 76, 202], which
nothing else in that menu uses -- the panels are all pale, desaturated blues.
Matching the outline and taking the topmost pixel of the largest blob gives the
fingertip, which is the point the game treats as the cursor.
"""
import sys, glob, os
import numpy as np
from PIL import Image
from scipy import ndimage

def find(path):
    im = np.asarray(Image.open(path).convert("RGB")).astype(int)
    r, g, b = im[..., 0], im[..., 1], im[..., 2]
    # Tight: within 26 of the outline colour exactly. Loosening this by even
    # a little starts catching the 'Wii Sports' wordmark and the panel edges.
    d = np.abs(r - 18) + np.abs(g - 76) + np.abs(b - 202)
    mask = d < 26
    lab, n = ndimage.label(mask)
    if n == 0:
        return None, im.shape[1], im.shape[0], 0
    sizes = ndimage.sum(mask, lab, range(1, n + 1))
    k = int(np.argmax(sizes)) + 1
    ys, xs = np.nonzero(lab == k)
    top = ys.min()
    tipx = xs[ys == top].mean()
    return (tipx, float(top)), im.shape[1], im.shape[0], int(sizes[k - 1])

for path in sorted(sys.argv[1:]):
    pt, w, h, size = find(path)
    name = os.path.basename(path)
    if pt is None:
        print("%-28s cursor NOT FOUND (hidden or off-screen)" % name)
    else:
        print("%-28s tip=(%6.1f,%6.1f)  frac=(%+.3f,%+.3f from centre)  blob=%d px"
              % (name, pt[0], pt[1], (pt[0] - w / 2) / (w / 2), (pt[1] - h / 2) / (h / 2), size))
