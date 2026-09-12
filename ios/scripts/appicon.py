"""OpenCane icon v2 — 'White Cane'. A real mobility cane on the dark field: black
straight grip, gold joint ring, white shaft with two red wraps, red tip.
Renders 1024 PNGs into the iPhone + Watch AppIcon sets.

Usage: python3 ios/scripts/appicon.py
"""
# Owner / callers: run by hand when the icon design changes (CHANGELOG.md Step 17); nothing in the
# build calls it and the PNGs it writes are committed. Needs Pillow (`pip install pillow`) — the only
# ios/scripts tool with a non-stdlib dependency. Overwrites both Icon-1024.png files in place; no
# project.yml or Contents.json change is needed. It is a top-level script (runs on import).
# Tests: none automated. Step 17 checked it by a bbox probe of the squircle cut zone (zero content
# pixels) and masked 180 px / 60 px renders; re-check that way after moving the cane or `K`.
# Review history: the `PAD` / `SPAD` paddings and the top-RIGHT arcs comment came from the agy round.
from PIL import Image, ImageDraw, ImageFilter
import os

# Output size in px (App Store / single-size AppIcon set).
S = 1024
SS = 4  # supersample
# Working canvas in px; everything is drawn at 4× and LANCZOS-downsampled at the end (anti-aliasing).
W = S * SS

# ios/, so the script works from any working directory.
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Both AppIcon sets get the same RGB (no alpha) 1024 PNG: iPhone app, then Watch app.
OUTS = [
    os.path.join(ROOT, "CaneKit", "Resources", "Assets.xcassets", "AppIcon.appiconset", "Icon-1024.png"),
    os.path.join(ROOT, "CaneKitWatch", "Assets.xcassets", "AppIcon.appiconset", "Icon-1024.png"),
]


# RGBA layer w×h px filled with a top→bottom linear gradient between two RGB tuples. Per-pixel
# loop: slow at 4096 px but a one-off tool.
def vgrad(w, h, top, bottom):
    img = Image.new("RGB", (w, h), top)
    px = img.load()
    for y in range(h):
        t = y / max(h - 1, 1)
        px_line = tuple(int(a + (b - a) * t) for a, b in zip(top, bottom))
        for x in range(w):
            px[x, y] = px_line
    return img.convert("RGBA")


# Gradient layer with optional rounded corners (`radius` px, alpha mask); used for the red wraps.
def seg(w, h, top, bottom, radius=0):
    layer = vgrad(w, h, top, bottom)
    if radius:
        mask = Image.new("L", (w, h), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, w, h], radius=radius, fill=255)
        layer.putalpha(mask)
    return layer


# --- background: deep navy gradient ---
base = vgrad(W, W, (13, 22, 48), (6, 10, 24))

# --- faint gold signal arcs, top-right (brand echo, kept quiet) ---
arcs = Image.new("RGBA", (W, W), (0, 0, 0, 0))
ad = ImageDraw.Draw(arcs)
for r in (125 * SS, 185 * SS):
    ad.arc([804 * SS - r, 200 * SS - r, 804 * SS + r, 200 * SS + r],
           start=15, end=165, fill=(216, 178, 106, 110), width=11 * SS)
base.alpha_composite(arcs)

# --- cane strip, built horizontal then rotated ---
# Pieces are square-ended and overlapped, so no hairline seams; only the two
# outer ends get round caps (left = grip, right = tip).
GRIP_L, RING_W, SHAFT_L, TIP_L = 170 * SS, 18 * SS, 600 * SS, 140 * SS
OV = 30 * SS                      # joint overlap
H = 128 * SS                      # shaft height
GH = 108 * SS                     # grip height (thinner than shaft, like the real thing)
PAD = 8 * SS                      # vertical padding: bands stand proud, blur has room
strip = Image.new("RGBA", (GRIP_L + RING_W + SHAFT_L + TIP_L, H + 2 * PAD), (0, 0, 0, 0))


# Round end of the grip / tip: a gradient disc of diameter d px.
def cap(d, top, bottom):
    """Circle end-cap of diameter d with vertical gradient."""
    layer = vgrad(d, d, top, bottom)
    mask = Image.new("L", (d, d), 0)
    ImageDraw.Draw(mask).ellipse([0, 0, d, d], fill=255)
    layer.putalpha(mask)
    return layer


ring_x = GRIP_L
shaft_x = ring_x + RING_W
# red tip: square start buried in the shaft, round outer end
tip_len = TIP_L
tip_x = shaft_x + SHAFT_L - OV
tip_cap_cx = tip_x + tip_len - H // 2  # cap circle centre: white ends here
# white shaft runs under the tip only up to the cap centre (else white corners peek out)
strip.alpha_composite(vgrad(tip_cap_cx - shaft_x, H, (253, 254, 255), (203, 208, 216)), (shaft_x, PAD))
strip.alpha_composite(vgrad(tip_cap_cx - tip_x, H, (233, 72, 72), (170, 36, 36)), (tip_x, PAD))
strip.alpha_composite(cap(H, (233, 72, 72), (170, 36, 36)), (tip_cap_cx - H // 2, PAD))
for frac in (0.38, 0.63):  # red wraps, slightly proud of the shaft
    bw = 72 * SS
    bx = int(shaft_x + SHAFT_L * frac - bw / 2)
    band = seg(bw, H + 4 * SS, (233, 72, 72), (178, 40, 40), radius=8 * SS)
    strip.alpha_composite(band, (bx, PAD - 2 * SS))
# black grip: square end buried under the gold ring, round outer end
grip_y = PAD + (H - GH) // 2
strip.alpha_composite(vgrad(GRIP_L - GH // 2, GH, (40, 42, 48), (16, 17, 22)),
                      (ring_x - GRIP_L + GH // 2, grip_y))
strip.alpha_composite(cap(GH, (40, 42, 48), (16, 17, 22)), (ring_x - GRIP_L, grip_y))
# gold joint ring on top of the grip/shaft boundary
strip.alpha_composite(vgrad(RING_W + OV, H, (216, 178, 106), (158, 122, 66)), (ring_x - OV // 2, PAD))
strip = strip.crop((0, 0, tip_x + tip_len, strip.height))  # drop trailing transparent space

# soft drop shadow (padded: an edge-to-edge blur clamps and cuts hard)
BLUR = 26 * SS
SPAD = 3 * BLUR
sh = Image.new("RGBA", (strip.width + 2 * SPAD, strip.height + 2 * SPAD), (0, 0, 0, 0))
ImageDraw.Draw(sh).rounded_rectangle([SPAD, SPAD, SPAD + strip.width, SPAD + strip.height],
                                     radius=H // 2, fill=(0, 0, 0, 110))
sh = sh.filter(ImageFilter.GaussianBlur(BLUR))

ANG = -60  # grip upper-left, red tip lower-right: the cane leans like it is held
shadow = sh.rotate(ANG, resample=Image.BICUBIC, expand=True)
cane = strip.rotate(ANG, resample=Image.BICUBIC, expand=True)
# pull inside the squircle: the full-size tip end sat on the mask boundary
# (K = 0.88 cleared it with margin, Step 17; the shadow is scaled with the cane so it stays under it)
K = 0.88
shadow = shadow.resize((int(shadow.width * K), int(shadow.height * K)), Image.BICUBIC)
cane = cane.resize((int(cane.width * K), int(cane.height * K)), Image.BICUBIC)
# Centre of the rotated cane, in 1024-px units (×SS); the shadow is drawn 26 px lower.
cx, cy = 498 * SS, 505 * SS
base.alpha_composite(shadow, (int(cx - shadow.width / 2), int(cy - shadow.height / 2 + 26 * SS)))
base.alpha_composite(cane, (int(cx - cane.width / 2), int(cy - cane.height / 2)))

out = base.convert("RGB").resize((S, S), Image.LANCZOS)
for path in OUTS:
    out.save(path)
    print("wrote", path)
