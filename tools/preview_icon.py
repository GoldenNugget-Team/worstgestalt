#!/usr/bin/env python3
"""
Preview renderer for AppIcon.icon (pure Python, no PIL/cairosvg).

Approximates the icon.json composition analytically:
  - plate: vertical display-p3 gradient (light) / system-dark (dark) /
    flat translucent gray (tinted)
  - "Grid" group: 8px lattice every 128px, layer opacity per appearance
  - "Glyph" group: 45-degree pencil (baked from the SVG's (s,v) axis)
  - rounded-rect mask approximating the iOS superellipse
No glass refraction / specular / shadow is simulated.

Outputs into IconPreview/: icon-{light,dark,tinted}-512.png + icon-sizes.png
"""
import zlib, struct, os

OUT = os.path.join(os.path.dirname(__file__), "..", "IconPreview")
os.makedirs(OUT, exist_ok=True)

CANVAS = 1024.0
K = 0.7071067811865476        # cos/sin 45deg
INV = 1.0 / (2 * K)           # (s,v) inverse transform factor
INV2 = 1.0 / (2 * K)          # same

# pencil polygons in (s, v): s along the 45deg axis (eraser side positive),
# v across. Mirror of the baked SVG paths in Assets/Pencil.svg.
BODY   = [(-162, -32), (-150, -44), (174, -44), (186, -32),
          (186, 32), (174, 44), (-150, 44), (-162, 32)]
CONE   = [(-150, -44), (-278, 0), (-150, 44)]
ERASER = [(196, -44), (196, 44), (242, 44), (266, 30), (276, 12),
          (276, -12), (266, -30), (242, -44)]
POLYS = (BODY, CONE, ERASER)

def pencil_coverage(ox, oy):
    ox -= 512.0
    oy -= 512.0
    s = (ox - oy) * INV
    v = (ox + oy) * INV2
    if abs(s) > 279 or abs(v) > 45:
        return False
    for poly in POLYS:
        inside = False
        n = len(poly)
        j = n - 1
        for i in range(n):
            si, vi = poly[i]
            sj, vj = poly[j]
            if (vi > v) != (vj > v):
                t = (v - vi) / (vj - vi)
                if s < si + t * (sj - si):
                    inside = not inside
            j = i
        if inside:
            return True
    return False

def axis_line(c):
    """1 if the coordinate sits on one of the 128px lattice lines (8px)."""
    k = round(c / 128.0)
    return 1 <= k <= 7 and abs(c - k * 128.0) <= 4.0

def grid_coverage(gx, gy):
    return axis_line(gx) or axis_line(gy)

def squircle_alpha(gx, gy, size, radius):
    """Rounded-rect mask (approximation of the iOS superellipse)."""
    in_mid_x = radius <= gx <= size - radius
    in_mid_y = radius <= gy <= size - radius
    if in_mid_x and in_mid_y:
        return 1.0
    corner = False
    for (cx, cy) in ((radius, radius), (size - radius, radius),
                     (radius, size - radius), (size - radius, size - radius)):
        if ((gx < radius) == (cx > radius * 1.0)) and ((gy < radius) == (cy > radius * 1.0)):
            pass
    # simpler: identify which corner region
    if not in_mid_x and not in_mid_y:
        nx = radius if gx < radius else size - radius
        ny = radius if gy < radius else size - radius
        corner = (gx - nx) ** 2 + (gy - ny) ** 2 <= radius ** 2
        if corner:
            return 1.0
        return 0.0
    return 1.0  # on the straight edge strip

SS = 2  # supersampling grid

APPEARANCES = {
    "light":  {"top": (0.48, 0.33, 1.00), "bot": (0.22, 0.06, 0.72), "grid_op": 0.14},
    "dark":   {"top": (0.11, 0.11, 0.13), "bot": (0.05, 0.05, 0.06), "grid_op": 0.09},
    "tinted": {"top": (0.62, 0.62, 0.66), "bot": (0.62, 0.62, 0.66), "grid_op": 0.35},
}

def render(size, mode, wallpaper, crop=True):
    a = APPEARANCES[mode]
    top, bot, grid_op = a["top"], a["bot"], a["grid_op"]
    radius = 0.22 * size
    scale = CANVAS / size
    glyph_color = (1.0, 1.0, 1.0)

    rows = []
    for y in range(size):
        fy = (y + 0.5) / size
        bgc = tuple(top[i] + (bot[i] - top[i]) * fy for i in range(3))
        row = bytearray((0,))
        for x in range(size):
            acc = [0.0, 0.0, 0.0, 0.0]
            for sy in range(SS):
                for sx in range(SS):
                    cx = x + (sx + 0.5) / SS
                    cy = y + (sy + 0.5) / SS
                    alpha = squircle_alpha(cx, cy, size, radius) if crop else 1.0
                    wm = wallpaper(cx, cy, cx, cy)
                    r = wm[0] * (1 - alpha) + bgc[0] * alpha
                    g = wm[1] * (1 - alpha) + bgc[1] * alpha
                    b = wm[2] * (1 - alpha) + bgc[2] * alpha
                    if grid_coverage(cx * scale, cy * scale):
                        r = r * (1 - grid_op) + 1.0 * grid_op
                        g = g * (1 - grid_op) + 1.0 * grid_op
                        b = b * (1 - grid_op) + 1.0 * grid_op
                    if pencil_coverage(cx * scale, cy * scale):
                        r, g, b = glyph_color
                    acc[0] += r; acc[1] += g; acc[2] += b; acc[3] += alpha
            n = SS * SS
            row += bytes((
                int(max(0, min(255, acc[0] / n * 255 + 0.5))),
                int(max(0, min(255, acc[1] / n * 255 + 0.5))),
                int(max(0, min(255, acc[2] / n * 255 + 0.5))),
                int(max(0, min(255, acc[3] / n * 255 + 0.5))),
            ))
        rows.append(bytes(row))
    return rows

def flat(color):
    return lambda x, y, gx, gy: color

def write_png(path, size, rows):
    sig = b"\x89PNG\r\n\x1a\n"
    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)
    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    idat = zlib.compress(b"".join(rows), 6)
    with open(path, "wb") as f:
        f.write(sig)
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", idat))
        f.write(chunk(b"IEND", b""))
    print("wrote", path)

# Also produce the shipped legacy icon: full-bleed 1024 PNG, no squircle
# crop (iOS masks it itself), light appearance.
def main():
    rows = render(1024, "light", flat((0.95, 0.95, 0.97)), crop=False)
    write_png(os.path.join(os.path.dirname(__file__), "..", "AppIcon.png"), 1024, rows)

    for mode in ("light", "dark", "tinted"):
        rows = render(512, mode, flat((0.95, 0.95, 0.97)))
        write_png(os.path.join(OUT, f"icon-{mode}-512.png"), 512, rows)

    compose_strip()
    print("done")

# small-size strip: 60 / 80 / 120 px icons side by side
sizes = (60, 80, 120)
pad = 12
W = H = sum(sizes) + pad * (len(sizes) + 1)
grid_bg = (0.92, 0.93, 0.96)

def compose_strip():
    canvas = [[None] * W for _ in range(H)]
    x0 = pad
    for s in sizes:
        rows = render(s, "light", flat(grid_bg))
        pix = []
        for row in rows:
            row_bytes = row[1:]
            pix.append([tuple(row_bytes[i:i+4]) for i in range(0, len(row_bytes), 4)])
        y_off = (H - s) // 2
        for yy in range(s):
            for xx in range(s):
                canvas[y_off + yy][x0 + xx] = pix[yy][xx]
        x0 += s + pad
    bg8 = tuple(int(c * 255) for c in grid_bg) + (255,)
    rows_out = []
    for y in range(H):
        buf = bytearray((0,))
        for x in range(W):
            p = canvas[y][x]
            buf += bytes(p if p is not None else bg8)
        rows_out.append(bytes(buf))
    write_png(os.path.join(OUT, "icon-sizes.png"), W, rows_out)


if __name__ == "__main__":
    main()
