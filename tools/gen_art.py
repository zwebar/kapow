"""Draws Kapow's comic textures (bursts, pips, energy cells...) and writes them as TGA.

Pure Python, no dependencies:  python3 tools/gen_art.py [preview_dir]
Shapes are white/grey with black ink outlines, so the addon can tint them with vertex colours
(white becomes the colour, black stays ink). With a preview_dir it also writes PNG contact sheets.
"""
import math
import os
import random
import struct
import sys
import zlib

SS = 4  # supersampling per axis
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Kapow", "Art")


class Bitmap:
    """A 1-bit supersampled canvas; shapes drawn on it are unioned."""

    def __init__(self, w, h):
        self.w, self.h = w, h
        self.W, self.H = w * SS, h * SS
        self.rows = [bytearray(self.W) for _ in range(self.H)]

    def poly(self, pts):
        pts = [(x * SS, y * SS) for x, y in pts]
        n = len(pts)
        ys = [p[1] for p in pts]
        y0 = max(0, int(math.floor(min(ys))))
        y1 = min(self.H - 1, int(math.ceil(max(ys))))
        for y in range(y0, y1 + 1):
            yc = y + 0.5
            xs = []
            for i in range(n):
                ax, ay = pts[i]
                bx, by = pts[(i + 1) % n]
                if (ay <= yc < by) or (by <= yc < ay):
                    xs.append(ax + (yc - ay) * (bx - ax) / (by - ay))
            xs.sort()
            row = self.rows[y]
            for i in range(0, len(xs) - 1, 2):
                a = max(0, int(math.ceil(xs[i] - 0.5)))
                b = min(self.W, int(math.floor(xs[i + 1] - 0.5)) + 1)
                if b > a:
                    row[a:b] = b"\x01" * (b - a)
        return self

    def circle(self, cx, cy, r, seg=40):
        return self.poly([(cx + r * math.cos(2 * math.pi * i / seg), cy + r * math.sin(2 * math.pi * i / seg))
                          for i in range(seg)])

    def stroke(self, pts, width, closed=True):
        n = len(pts)
        hw = width / 2.0
        for i in range(n if closed else n - 1):
            ax, ay = pts[i]
            bx, by = pts[(i + 1) % n]
            dx, dy = bx - ax, by - ay
            d = math.hypot(dx, dy) or 1.0
            nx, ny = -dy / d * hw, dx / d * hw
            self.poly([(ax + nx, ay + ny), (bx + nx, by + ny), (bx - nx, by - ny), (ax - nx, ay - ny)])
        for x, y in pts:
            self.circle(x, y, hw, 16)
        return self

    def intersect(self, other):
        for y in range(self.H):
            a, b = self.rows[y], other.rows[y]
            self.rows[y] = bytearray(x & z for x, z in zip(a, b))
        return self

    def subtract(self, other):
        for y in range(self.H):
            a, b = self.rows[y], other.rows[y]
            self.rows[y] = bytearray(x & (1 - z) for x, z in zip(a, b))
        return self

    def coverage(self):
        out = []
        full = float(SS * SS)
        for y in range(self.h):
            rows = self.rows[y * SS:(y + 1) * SS]
            line = []
            for x in range(self.w):
                a, b = x * SS, (x + 1) * SS
                line.append(sum(sum(r[a:b]) for r in rows) / full)
            out.append(line)
        return out


class Image:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.px = [[[0.0, 0.0, 0.0, 0.0] for _ in range(w)] for _ in range(h)]

    def paint(self, bitmap, color, alpha=1.0):
        """Composite a flat colour (0..1 rgb) through the bitmap's coverage, 'over'."""
        cov = bitmap.coverage()
        r, g, b = color
        for y in range(self.h):
            row, crow = self.px[y], cov[y]
            for x in range(self.w):
                a = crow[x] * alpha
                if a <= 0:
                    continue
                p = row[x]
                oa = a + p[3] * (1 - a)
                for i, c in enumerate((r, g, b)):
                    p[i] = (c * a + p[i] * p[3] * (1 - a)) / oa
                p[3] = oa
        return self

    def bytes_rgba(self):
        out = bytearray()
        for row in self.px:
            for r, g, b, a in row:
                out += bytes((int(r * 255 + 0.5), int(g * 255 + 0.5), int(b * 255 + 0.5), int(a * 255 + 0.5)))
        return bytes(out)

    def save_tga(self, name):
        os.makedirs(OUT, exist_ok=True)
        head = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, self.w, self.h, 32, 8)  # bottom-left origin
        body = bytearray()
        for row in reversed(self.px):
            for r, g, b, a in row:
                body += bytes((int(b * 255 + 0.5), int(g * 255 + 0.5), int(r * 255 + 0.5), int(a * 255 + 0.5)))
        with open(os.path.join(OUT, name + ".tga"), "wb") as f:
            f.write(head + bytes(body))
        ART[name] = self
        print("wrote", name, "%dx%d" % (self.w, self.h))


ART = {}
INK = (0.05, 0.04, 0.08)
WHITE = (1.0, 1.0, 1.0)
SHADE = (0.80, 0.80, 0.80)


def star_points(cx, cy, n, r_out, r_in, rng, jitter_r=0.12, jitter_a=0.25, rot=0.0):
    pts = []
    for i in range(n * 2):
        a = rot + math.pi * i / n + rng.uniform(-jitter_a, jitter_a) * math.pi / n
        if i % 2 == 0:
            r = r_out * (1 - rng.uniform(0, jitter_r))
        else:
            r = r_in * (1 + rng.uniform(-jitter_r, jitter_r) * 0.6)
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def halftone(w, h, pitch, radius_at, angle=0.35):
    """Dots on a rotated grid; radius_at(x, y) gives each dot's radius (<=0 skips it)."""
    bm = Bitmap(w, h)
    ca, sa = math.cos(angle), math.sin(angle)
    span = int((w + h) / pitch) + 2
    for i in range(-span, span):
        for j in range(-span, span):
            x = w / 2 + (i * ca - j * sa) * pitch
            y = h / 2 + (i * sa + j * ca) * pitch
            if -pitch < x < w + pitch and -pitch < y < h + pitch:
                r = radius_at(x, y)
                if r > 0.3:
                    bm.circle(x, y, r, 14)
    return bm


def burst(name, n, r_in, seed, jr, ja, dots=True):
    S = 256
    rng = random.Random(seed)
    pts = star_points(S / 2, S / 2, n, 118, 118 * r_in, rng, jr, ja, rot=rng.uniform(0, 1))
    img = Image(S, S)
    img.paint(Bitmap(S, S).poly(pts).stroke(pts, 11), INK)
    fill = Bitmap(S, S).poly(pts)
    img.paint(fill, WHITE)
    if dots:
        d = halftone(S, S, 11, lambda x, y: 4.6 * max(0.0, min(1.0, ((x - S / 2) * 0.5 + (y - S / 2)) / 95.0)))
        img.paint(d.intersect(fill), SHADE)
    img.paint(Bitmap(S, S).stroke(pts, 4.5), INK)
    img.save_tga(name)


def cloud():
    S = 256
    rng = random.Random(7)
    puffs = []
    n = 11
    for i in range(n):
        a = 2 * math.pi * i / n + rng.uniform(-0.1, 0.1)
        puffs.append((S / 2 + 74 * math.cos(a), S / 2 + 62 * math.sin(a), rng.uniform(30, 42)))
    body = Bitmap(S, S).circle(S / 2, S / 2, 78, 48)
    ink = Bitmap(S, S).circle(S / 2, S / 2, 84, 48)
    for x, y, r in puffs:
        body.circle(x, y, r, 36)
        ink.circle(x, y, r + 6, 36)
    img = Image(S, S)
    img.paint(ink, INK)
    img.paint(body, WHITE)
    d = halftone(S, S, 11, lambda x, y: 4.2 * max(0.0, min(1.0, ((x - S / 2) * 0.4 + (y - S / 2)) / 90.0)))
    img.paint(d.intersect(body), SHADE)
    img.save_tga("cloud")


def pip():
    S = 64
    c = S / 2
    pts = [(c + 4, 5), (S - 6, c - 2), (c - 4, S - 5), (6, c + 2)]  # a diamond leaning forward
    img = Image(S, S)
    img.paint(Bitmap(S, S).poly(pts).stroke(pts, 9), INK)
    img.paint(Bitmap(S, S).poly(pts), (0.84, 0.84, 0.84))
    shine = Bitmap(S, S).poly([(c + 2, 11), (c + 12, 21), (c - 9, 40), (13, c + 1)])
    img.paint(shine.intersect(Bitmap(S, S).poly(pts)), WHITE)
    img.paint(Bitmap(S, S).stroke(pts, 4), INK)
    img.save_tga("pip")


SEG_W, SEG_H, SEG_M, SEG_SLANT = 128, 64, 7, 26


def seg_points(inset=0.0):
    m = SEG_M + inset
    return [(m + SEG_SLANT, m), (SEG_W - m, m), (SEG_W - m - SEG_SLANT, SEG_H - m), (m, SEG_H - m)]


def segments():
    pts = seg_points()
    Image(SEG_W, SEG_H).paint(Bitmap(SEG_W, SEG_H).poly(pts), WHITE).save_tga("seg_mask")
    Image(SEG_W, SEG_H).paint(Bitmap(SEG_W, SEG_H).stroke(pts, 7), INK).save_tga("seg_frame")
    # The fill: flat, with a lighter band along the top and halftone shading at the bottom.
    img = Image(SEG_W, SEG_H)
    img.paint(Bitmap(SEG_W, SEG_H).poly([(0, 0), (SEG_W, 0), (SEG_W, SEG_H), (0, SEG_H)]), (0.88, 0.88, 0.88))
    img.paint(Bitmap(SEG_W, SEG_H).poly([(0, 0), (SEG_W, 0), (SEG_W, 22), (0, 22)]), WHITE)
    img.paint(halftone(SEG_W, SEG_H, 8, lambda x, y: 3.3 * max(0.0, min(1.0, (y - 30) / 26.0)), 0.5), (0.70, 0.70, 0.70))
    img.save_tga("seg_fill")


def glow():
    S = 128
    img = Image(S, S)
    for y in range(S):
        for x in range(S):
            d = math.hypot(x + 0.5 - S / 2, y + 0.5 - S / 2) / (S / 2)
            a = max(0.0, 1 - d)
            img.px[y][x] = [1.0, 1.0, 1.0, a * a]
    img.save_tga("glow")


def lines():
    S = 256
    rng = random.Random(21)
    bm = Bitmap(S, S)
    n = 34
    for i in range(n):
        a = 2 * math.pi * i / n + rng.uniform(-0.05, 0.05)
        r0 = rng.uniform(52, 86)
        r1 = 127
        w = rng.uniform(0.012, 0.045)
        bm.poly([(S / 2 + r0 * math.cos(a), S / 2 + r0 * math.sin(a)),
                 (S / 2 + r1 * math.cos(a - w), S / 2 + r1 * math.sin(a - w)),
                 (S / 2 + r1 * math.cos(a + w), S / 2 + r1 * math.sin(a + w))])
    Image(S, S).paint(bm, WHITE).save_tga("lines")


def ring():
    S = 128
    c = S / 2
    img = Image(S, S)
    img.paint(Bitmap(S, S).circle(c, c, 60, 64).subtract(Bitmap(S, S).circle(c, c, 44, 64)), INK)
    img.paint(Bitmap(S, S).circle(c, c, 56, 64).subtract(Bitmap(S, S).circle(c, c, 48, 64)), WHITE)
    img.save_tga("ring")


def bolt():
    S = 64
    pts = [(38, 3), (12, 36), (28, 36), (22, 61), (52, 24), (35, 24), (46, 3)]
    img = Image(S, S)
    img.paint(Bitmap(S, S).poly(pts).stroke(pts, 8), INK)
    img.paint(Bitmap(S, S).poly(pts), WHITE)
    img.save_tga("bolt")


def star():
    S = 64
    c = S / 2
    pts = []
    for i in range(8):
        a = math.pi * i / 4 - math.pi / 2
        r = 28 if i % 2 == 0 else 8
        pts.append((c + r * math.cos(a), c + r * math.sin(a)))
    img = Image(S, S)
    img.paint(Bitmap(S, S).poly(pts).stroke(pts, 6), INK)
    img.paint(Bitmap(S, S).poly(pts), WHITE)
    img.save_tga("star")


def streak():
    """A tapered slash, drawn along the horizontal middle of a square (so it can be rotated)."""
    S = 256
    c = S / 2
    top, bot = [], []
    n = 24
    for i in range(n + 1):
        t = i / n
        x = 10 + t * (S - 20)
        half = 15 * math.sin(math.pi * t) ** 0.7
        bend = -16 * math.sin(math.pi * t)
        top.append((x, c + bend - half))
        bot.append((x, c + bend + half * 0.35))
    pts = top + bot[::-1]
    img = Image(S, S)
    img.paint(Bitmap(S, S).poly(pts).stroke(pts, 7), INK)
    img.paint(Bitmap(S, S).poly(pts), WHITE)
    img.save_tga("streak")


def png(path, w, h, rgba):
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + rgba[y * w * 4:(y + 1) * w * 4] for y in range(h))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def contact_sheet(path, names, tints, bg=(0.23, 0.29, 0.20), cell=256):
    """Each texture, multiplied by a tint and laid over a background, like the game would draw it."""
    w, h = cell * len(names), cell
    buf = bytearray(w * h * 4)
    for i in range(w * h):
        buf[i * 4:i * 4 + 4] = bytes((int(bg[0] * 255), int(bg[1] * 255), int(bg[2] * 255), 255))
    for k, name in enumerate(names):
        img, tint = ART[name], tints[k % len(tints)]
        ox, oy = k * cell + (cell - img.w) // 2, (cell - img.h) // 2
        for y in range(img.h):
            for x in range(img.w):
                r, g, b, a = img.px[y][x]
                if a <= 0:
                    continue
                i = ((oy + y) * w + ox + x) * 4
                for c, v in enumerate((r * tint[0], g * tint[1], b * tint[2])):
                    buf[i + c] = int((v * a + buf[i + c] / 255.0 * (1 - a)) * 255 + 0.5)
    png(path, w, h, bytes(buf))
    print("preview", path)


if __name__ == "__main__":
    burst("burst", 12, 0.60, 3, 0.16, 0.30)
    burst("burst2", 17, 0.50, 11, 0.30, 0.45)
    cloud()
    pip()
    segments()
    glow()
    lines()
    ring()
    bolt()
    star()
    streak()
    if len(sys.argv) > 1:
        d = sys.argv[1]
        os.makedirs(d, exist_ok=True)
        yellow, red, cyan, purple = (1.0, 0.82, 0.25), (1.0, 0.2, 0.33), (0.18, 0.89, 0.9), (0.6, 0.45, 1.0)
        contact_sheet(os.path.join(d, "sheet1.png"), ["burst", "burst2", "cloud", "streak"], [yellow, red, purple, cyan])
        contact_sheet(os.path.join(d, "sheet2.png"), ["pip", "seg_mask", "seg_frame", "seg_fill", "bolt", "star", "ring", "glow"],
                      [red, yellow, WHITE, yellow, cyan, WHITE, WHITE, yellow], cell=140)
        contact_sheet(os.path.join(d, "sheet3.png"), ["lines"], [WHITE])
