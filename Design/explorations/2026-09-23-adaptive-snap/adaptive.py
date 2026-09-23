"""Snap AI 'pixel art' onto its real, non-uniform grid: cut lines follow the
image's own edge peaks (searched within +-TOL of the nominal period)."""
import sys, collections
from PIL import Image
import numpy as np

src, out, period = sys.argv[1], sys.argv[2], float(sys.argv[3])
TOL = 5
im = Image.open(src).convert('RGBA'); a = np.asarray(im).astype(int)
H, W = a.shape[:2]

def cuts(profile, n):
    PEN = np.percentile(profile, 90)
    # dynamic programming: choose cut positions maximising edge energy,
    # consecutive gaps constrained to period +- TOL
    lo, hi = int(period) - TOL, int(period) + TOL + 1
    best = np.full(n + 1, -1e18); prev = np.full(n + 1, -1, int)
    best[0] = 0
    for i in range(1, n + 1):
        for g in range(lo, hi + 1):
            j = i - g
            if j < 0: continue
            if j != 0 and best[j] <= -1e17: continue
            s = best[j] + (profile[i - 1] - PEN if i < n else 0)
            if s > best[i]: best[i], prev[i] = s, j
    # allow free start/end: pick last cut among positions near n
    c = [n]; i = n
    while i > 0: i = prev[i]; c.append(i)
    return sorted(set(c))

rgb = a[..., :3]
px = np.abs(np.diff(rgb, axis=1)).sum(axis=2).sum(axis=0).astype(float)
py = np.abs(np.diff(rgb, axis=0)).sum(axis=2).sum(axis=1).astype(float)
# profile[k] = energy of boundary at position k+1  -> index by cut position
xs = cuts(np.r_[px, 0], W); ys = cuts(np.r_[py, 0], H)
print('cells', len(xs) - 1, 'x', len(ys) - 1, 'gaps x', sorted(collections.Counter(np.diff(xs)).items()))

def mode(x0, x1, y0, y1):
    ix = int((x1 - x0) * .25); iy = int((y1 - y0) * .25)
    blk = a[y0 + iy:y1 - iy, x0 + ix:x1 - ix].reshape(-1, 4)
    blk = (blk // 8) * 8  # tolerate AA noise
    v = collections.Counter(map(tuple, blk)).most_common(1)[0][0]
    return v
grid = np.array([[mode(xs[i], xs[i+1], ys[j], ys[j+1]) for i in range(len(xs)-1)] for j in range(len(ys)-1)], dtype=np.uint8)
Image.fromarray(grid, 'RGBA').save(out)
