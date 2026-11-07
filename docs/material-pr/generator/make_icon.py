"""Platin Hub icon: the supplied logo redrawn as a 24x24 single-path Material icon.

Pipeline (measured, not eyeballed):
  1. the logo's ink box (271..1631 x 247..1602 of the 1875 px source) is fitted
     to 20 of the 24 units, centred - Material's 2 px padding;
  2. the C-and-tail is rasterised at 40 px per unit, DILATED by a disk of
     radius R units so the hairline tail and the hook's tip survive at 24 px
     (the source tail is 0.25-0.4 units wide; it would grey out), traced, lightly
     smoothed, and FITTED WITH CUBIC BEZIERS (Schneider's algorithm) - a smooth
     path with few nodes, not a polygon;
  3. the slash is DRAWN, not traced: a capsule on its measured axis (centre
     (1003,856) source px, 71.2 deg, 526 px long), width SW units.
One <path>, fill="#000": the two shapes do not overlap, so it themes with the
single fill substitution in Material's _svgHandler.

usage: make_icon.py R SW out.svg

The shipped icon is `python3 make_icon.py 0.25 1.4 platin.svg` (version C of
three weights Simon compared, 2026-10-25), then the <svg> wrapper written as in
../platin.svg. Needs Pillow; runs in about a minute.
"""
import math, sys
from PIL import Image, ImageChops

import os
SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'platin-logo.png')
PPU = 40                       # canvas px per icon unit
X0, Y0, X1, Y1 = 271, 247, 1631, 1602
R = float(sys.argv[1]) if len(sys.argv) > 1 else 0.25
# the DILATED ink must fit 2..22: the source box gets 20 - 2R, centred
S = (20.0 - 2 * R) / (X1 - X0 + 1)       # source px -> units
OX = 2.0 + R
OY = 2.0 + R + ((20.0 - 2 * R) - (Y1 - Y0 + 1) * S) / 2

def to_units(x, y):
    return ((x - X0) * S + OX, (y - Y0) * S + OY)

# ---------------------------------------------------------------- the C mask
def c_mask(R):
    src = Image.open(SRC).convert('L').crop((X0, Y0, X1 + 1, Y1 + 1))
    w = round((X1 - X0 + 1) * S * PPU); h = round((Y1 - Y0 + 1) * S * PPU)
    small = src.resize((w, h), Image.LANCZOS)
    ink = small.point(lambda v: 255 if v < 128 else 0)
    canvas = Image.new('L', (24 * PPU, 24 * PPU), 0)
    canvas.paste(ink, (round(OX * PPU), round(OY * PPU)))
    # drop the slash: keep the largest component only
    W, H = canvas.size; px = canvas.load()
    seen = set(); best = None
    for y in range(H):
        for x in range(W):
            if px[x, y] and (x, y) not in seen:
                comp = []; st = [(x, y)]; seen.add((x, y))
                while st:
                    cx, cy = st.pop(); comp.append((cx, cy))
                    for nx, ny in ((cx+1,cy),(cx-1,cy),(cx,cy+1),(cx,cy-1)):
                        if 0 <= nx < W and 0 <= ny < H and px[nx, ny] and (nx, ny) not in seen:
                            seen.add((nx, ny)); st.append((nx, ny))
                if best is None or len(comp) > len(best): best = comp
    m = Image.new('L', (W, H), 0); mp = m.load()
    for x, y in best: mp[x, y] = 255
    # disk dilation
    r = R * PPU
    if r > 0:
        out = m.copy(); ir = int(math.ceil(r))
        for dy in range(-ir, ir + 1):
            for dx in range(-ir, ir + 1):
                if dx * dx + dy * dy <= r * r and (dx or dy):
                    out = ImageChops.lighter(out, ImageChops.offset(m, dx, dy))
        m = out
    return m

def boundary(m):
    W, H = m.size; px = m.load()
    ink = lambda x, y: 0 <= x < W and 0 <= y < H and px[x, y] > 0
    edges = {}
    for y in range(H):
        for x in range(W):
            if not px[x, y]: continue
            if not ink(x, y - 1): edges[(x, y)] = (x + 1, y)
            if not ink(x + 1, y): edges[(x + 1, y)] = (x + 1, y + 1)
            if not ink(x, y + 1): edges[(x + 1, y + 1)] = (x, y + 1)
            if not ink(x - 1, y): edges[(x, y + 1)] = (x, y)
    loops = []
    while edges:
        start = next(iter(edges)); loop = [start]; cur = start
        while True:
            nxt = edges.pop(cur, None)
            if nxt is None or nxt == start: break
            loop.append(nxt); cur = nxt
        loops.append(loop)
    loops.sort(key=len, reverse=True)
    return loops

def smooth(loop, k):
    n = len(loop); out = []
    for i in range(n):
        sx = sy = 0
        for j in range(-k, k + 1):
            x, y = loop[(i + j) % n]; sx += x; sy += y
        out.append((sx / (2 * k + 1) / PPU, sy / (2 * k + 1) / PPU))
    return out

# ------------------------------------------------- Schneider cubic fitting
def sub(a, b): return (a[0]-b[0], a[1]-b[1])
def add(a, b): return (a[0]+b[0], a[1]+b[1])
def mul(a, s): return (a[0]*s, a[1]*s)
def dot(a, b): return a[0]*b[0]+a[1]*b[1]
def norm(a):
    l = math.hypot(*a); return (a[0]/l, a[1]/l) if l else (0, 0)
def bez(c, t):
    mt = 1-t
    return add(add(mul(c[0], mt*mt*mt), mul(c[1], 3*mt*mt*t)), add(mul(c[2], 3*mt*t*t), mul(c[3], t*t*t)))
def bez1(c, t):
    mt = 1-t
    return add(add(mul(sub(c[1], c[0]), 3*mt*mt), mul(sub(c[2], c[1]), 6*mt*t)), mul(sub(c[3], c[2]), 3*t*t))
def bez2(c, t):
    return add(mul(add(sub(c[2], mul(c[1], 2)), c[0]), 6*(1-t)), mul(add(sub(c[3], mul(c[2], 2)), c[1]), 6*t))

def chord(pts):
    u = [0.0]
    for i in range(1, len(pts)): u.append(u[-1] + math.hypot(*sub(pts[i], pts[i-1])))
    return [v / u[-1] for v in u]

def gen(pts, u, t1, t2):
    A = [(mul(t1, 3*(1-x)*(1-x)*x), mul(t2, 3*(1-x)*x*x)) for x in u]
    C = [[0, 0], [0, 0]]; X = [0, 0]
    for i, x in enumerate(u):
        C[0][0] += dot(A[i][0], A[i][0]); C[0][1] += dot(A[i][0], A[i][1]); C[1][1] += dot(A[i][1], A[i][1])
        tmp = sub(pts[i], bez((pts[0], pts[0], pts[-1], pts[-1]), x))
        X[0] += dot(A[i][0], tmp); X[1] += dot(A[i][1], tmp)
    C[1][0] = C[0][1]
    det = C[0][0]*C[1][1] - C[1][0]*C[0][1]
    a1 = (C[0][0]*X[1] - C[1][0]*X[0]) / det if det else 0
    a2 = (X[0]*C[1][1] - X[1]*C[0][1]) / det if det else 0
    seg = math.hypot(*sub(pts[-1], pts[0]))
    if a1 < 1e-6*seg or a2 < 1e-6*seg:
        a1 = a2 = seg / 3
    return (pts[0], add(pts[0], mul(t1, a2)), add(pts[-1], mul(t2, a1)), pts[-1])

def maxerr(pts, c, u):
    worst, wi = 0, len(pts)//2
    for i in range(1, len(pts)-1):
        d = math.hypot(*sub(bez(c, u[i]), pts[i]))
        if d > worst: worst, wi = d, i
    return worst, wi

def reparam(pts, c, u):
    out = []
    for p, t in zip(pts, u):
        d = sub(bez(c, t), p); q1 = bez1(c, t); q2 = bez2(c, t)
        den = dot(q1, q1) + dot(d, q2)
        out.append(t - dot(d, q1) / den if den else t)
    return out

def fit(pts, t1, t2, err):
    if len(pts) == 2:
        d = math.hypot(*sub(pts[1], pts[0])) / 3
        return [(pts[0], add(pts[0], mul(t1, d)), add(pts[1], mul(t2, d)), pts[1])]
    u = chord(pts); c = gen(pts, u, t1, t2); e, si = maxerr(pts, c, u)
    if e < err: return [c]
    if e < err * 4:
        for _ in range(20):
            u = reparam(pts, c, u); c = gen(pts, u, t1, t2); e, si = maxerr(pts, c, u)
            if e < err: return [c]
    tc = norm(sub(pts[si-1], pts[si+1]))
    return fit(pts[:si+1], t1, tc, err) + fit(pts[si:], mul(tc, -1), t2, err)

def fit_closed(pts, err):
    # start at the leftmost point; tangents there from its neighbours
    i0 = min(range(len(pts)), key=lambda i: (pts[i][0], pts[i][1]))
    pts = pts[i0:] + pts[:i0] + [pts[i0]]
    t = norm(sub(pts[1], pts[-2]))
    return fit(pts, t, mul(t, -1), err)

# ------------------------------------------------------------- the slash
def slash(SW):
    (cx, cy) = to_units(1003, 856)
    ang = math.radians(-71.2); ux, uy = math.cos(ang), math.sin(ang)
    half = (526 * S) / 2 - SW / 2          # centre-to-cap-centre, so the ink length stays 526 px
    r = SW / 2; nx, ny = -uy, ux
    a = (cx - ux*half, cy - uy*half); b = (cx + ux*half, cy + uy*half)
    p1 = (a[0] + nx*r, a[1] + ny*r); p2 = (b[0] + nx*r, b[1] + ny*r)
    p3 = (b[0] - nx*r, b[1] - ny*r); p4 = (a[0] - nx*r, a[1] - ny*r)
    f = lambda v: ('%.2f' % v).rstrip('0').rstrip('.')
    return ('M%s %sL%s %sA%s %s 0 0 0 %s %sL%s %sA%s %s 0 0 0 %s %sZ' %
            (f(p1[0]), f(p1[1]), f(p2[0]), f(p2[1]), f(r), f(r), f(p3[0]), f(p3[1]),
             f(p4[0]), f(p4[1]), f(r), f(r), f(p1[0]), f(p1[1])))

def path_d(R, SW, err=0.03):
    loops = boundary(c_mask(R))
    pts = smooth(loops[0], 3)
    pts = pts[::2]
    segs = fit_closed(pts, err)
    f = lambda v: ('%.2f' % v).rstrip('0').rstrip('.')
    d = 'M%s %s' % (f(segs[0][0][0]), f(segs[0][0][1]))
    for c in segs:
        d += 'C%s %s %s %s %s %s' % (f(c[1][0]), f(c[1][1]), f(c[2][0]), f(c[2][1]), f(c[3][0]), f(c[3][1]))
    return d + 'Z' + slash(SW), len(segs), len(loops)

if __name__ == '__main__':
    R, SW, out = float(sys.argv[1]), float(sys.argv[2]), sys.argv[3]
    d, nseg, nloops = path_d(R, SW)
    open(out, 'w').write('<svg width="24" height="24" version="1.1" viewBox="0 0 24 24" '
                         'xmlns="http://www.w3.org/2000/svg">\n <path d="%s" fill="#000"/>\n</svg>\n' % d)
    print('%s: R %.2f slash %.2f -> %d curves, %d C-loop(s), %d chars' % (out, R, SW, nseg, nloops, len(d)))
