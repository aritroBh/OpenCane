#!/usr/bin/env python3
"""pitch_model.py - why the camera should look ~5 deg down, and whether the cradle clears the cane.

Reproduces the two tables in DESIGN.md sections 4 and 5 (stdlib only):  python3 pitch_model.py
Change CAM_H / HALF_VFOV after measuring on the device and re-run.

Model (flat ground, phone upright in portrait, ARKit depth registered to the wide camera):
  * LaneMath (ios/Logic/.../LaneMath.swift): bottom 25 % of the portrait image is skipped as ground;
    rows 0-37.5 % are the head band, 37.5-75 % the torso band; each cell reports the 10th
    percentile of its valid depths (z along the optical axis). It is NOT gravity-compensated, so
    pavement seen by the torso band reads as an obstacle. CueDecider: centre cue < 2.0 m (clears at
    2.15), head cue < 1.5 m.
  * GroundHazardDetector (Hazards.swift) is gravity-aligned; it needs >= 12 ground samples 0.8-1.5 m
    ahead as its reference and scans to 3.5 m. GroundSampler takes every 4th row and column and
    caps depth at 4.5 m. LaneMath has no depth cap, so LIDAR_MAX (5 m, the sensor's useful range)
    decides which torso rows return pavement at all.
  * Head-band height uses z-depth (what LaneMath compares with 1.5 m), not range along the ray.
"""
import math

CAM_H = 0.97        # m, camera height: grip 0.9 m, collar 150 mm below the hand, camera ~178 mm above it
HALF_VFOV = 33.5    # deg, half the portrait (long-axis) FOV of the ARKit image; check with intrinsics
LIDAR_MAX = 5.0     # m
ROWS = 256          # portrait rows of the 256 x 192 depth map


def row_angles(half):
    t = math.tan(math.radians(half))
    return [((i + 0.5) / ROWS, math.degrees(math.atan((0.5 - (i + 0.5) / ROWS) * 2 * t))) for i in range(ROWS)]


def ground_hit(alpha, pitch, h):
    """z-depth and range where a ray alpha deg above the optical axis meets the ground."""
    a, p = math.radians(alpha), math.radians(pitch)
    den = math.sin(p) - math.tan(a) * math.cos(p)
    if den <= 0:
        return None
    z = h / den
    return z, z / math.cos(a), z * math.cos(p) + z * math.tan(a) * math.sin(p)   # z, range, horizontal


def torso_p10(pitch, h, half, skip):
    usable = 1 - skip
    vals = sorted(g[0] for r, a in row_angles(half) if usable / 2 <= r < usable
                  for g in [ground_hit(a, pitch, h)] if g and g[1] <= LIDAR_MAX)
    return vals[int(len(vals) * 0.10)] if len(vals) >= 8 else float("inf")


def pitch_table(h=CAM_H, half=HALF_VFOV):
    print(f"camera {h} m, half vFOV {half} deg")
    print(" pitch | nearest ground | rows seeing 0.8-1.5 m | torso reads pavement at | head band top @1.5 m | skip for >=2.3 m")
    for p in (-5, 0, 3, 5, 8, 10, 15, 20):
        rows = row_angles(half)
        dep = half + p
        nearest = h / math.tan(math.radians(dep)) if dep > 0 else float("inf")
        nf = sum(1 for _, a in rows for g in [ground_hit(a, p, h)] if g and 0.8 <= g[2] <= 1.5)
        top = h + 1.5 * (math.tan(math.radians(half)) * math.cos(math.radians(p)) - math.sin(math.radians(p)))
        need = next((s / 100 for s in range(20, 70) if torso_p10(p, h, half, s / 100) >= 2.3), None)
        print(f" {p:5d} | {nearest:10.2f} m   | {nf:12d}          | {torso_p10(p, h, half, 0.25):14.2f} m      |"
              f" {top:12.2f} m        | {need}")


# ---- cradle-to-cane clearance (same geometry as cane_mount.scad) ----
L, D = 163.4, 8.75


def convex_hull(pts):
    pts = sorted(set(pts))
    cross = lambda o, a, b: (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    lo, up = [], []
    for p in pts:
        while len(lo) >= 2 and cross(lo[-2], lo[-1], p) <= 0:
            lo.pop()
        lo.append(p)
    for p in reversed(pts):
        while len(up) >= 2 and cross(up[-2], up[-1], p) <= 0:
            up.pop()
        up.append(p)
    return lo[:-1] + up[:-1]


def outside(poly, p):
    m = -1e9
    for i in range(len(poly)):
        a, b = poly[i], poly[(i + 1) % len(poly)]
        ex, ey = b[0] - a[0], b[1] - a[1]
        n = math.hypot(ex, ey)
        m = max(m, ((p[0] - a[0]) * ey - (p[1] - a[1]) * ex) / n)
    return m


def clearance(ear_len=46, arm_off=30, hinge_below=14, ear_r=22, collar_r=19.5, collar_half=22,
              pole_r=14.375, back=3.5, front=2.2, bottom=2.7, plate_top=112.4):
    """Smallest gap (mm) between the cradle box and the cane / collar / ear over phi = 35..80."""
    ear = convex_hull([(ear_len + ear_r * math.cos(t * math.pi / 18), ear_r * math.sin(t * math.pi / 18))
                       for t in range(36)] + [(0, collar_half), (0, -collar_half),
                                              (collar_r, collar_half), (collar_r, -collar_half)])
    worst = (1e9, None)
    for phi in range(35, 81, 5):
        b = math.radians(90 - phi)
        for i in range(121):
            v = -bottom + (L + 2 * bottom) * i / 120
            for j in range(13):
                w = -back + (D + front + back) * j / 12
                if v > plate_top and w < 0:
                    continue                       # no back plate behind the camera plateau
                y = ear_len + (v + hinge_below) * math.cos(b) - (w + arm_off) * math.sin(b)
                z = (v + hinge_below) * math.sin(b) + (w + arm_off) * math.cos(b)
                m = min(y - pole_r, outside(ear, (y, z)))
                if abs(z) <= collar_half:
                    m = min(m, y - collar_r)
                worst = min(worst, (m, (phi, round(v), round(w, 1))))
    return worst


def shaft_in_view(phi, ear_len=46, arm_off=30, hinge_below=14, pole_r=14.375, half_v=HALF_VFOV):
    """Where the cane shaft (toward the tip) appears in the wide camera's portrait image at hinge
    angle phi: (nearest z-depth in view in m, highest image angle vs the optical axis in deg), or
    None when the shaft is out of frame. Torso band starts ~18.3 deg below the axis."""
    half_h = math.degrees(math.atan(math.tan(math.radians(half_v)) * 0.75))   # 4:3 image
    b = math.radians(90 - phi)
    a, n = (math.cos(b), math.sin(b)), (math.sin(b), -math.cos(b))           # long axis, camera axis
    cv, cw, cx = L - 33.61, -4.43, 78.0 / 2 - 14.37                           # wide camera, phone frame
    cy = ear_len + (cv + hinge_below) * a[0] - (cw + arm_off) * n[0]
    cz = (cv + hinge_below) * a[1] - (cw + arm_off) * n[1]
    seen = []
    for k in range(0, 1300, 10):                                              # 1.3 m of shaft to the tip
        for y in (-pole_r, 0.0, pole_r):
            dy, dz = y - cy, -k - cz
            fwd, up = dy * n[0] + dz * n[1], dy * a[0] + dz * a[1]
            if fwd > 50 and abs(math.degrees(math.atan2(up, fwd))) <= half_v \
                    and abs(math.degrees(math.atan2(-cx, fwd))) <= half_h:
                seen.append((fwd / 1000, math.degrees(math.atan2(up, fwd))))
    if not seen:
        return None
    return round(min(s[0] for s in seen), 2), round(max(s[1] for s in seen), 1)


if __name__ == "__main__":
    for half in (31.0, HALF_VFOV, 36.0):
        pitch_table(half=half)
        print()
    gap, where = clearance()
    print(f"cradle clearance over phi 35-80: {gap:.1f} mm (worst at phi, phone Y, phone Z = {where})")
    for phi in range(35, 81, 5):
        print(f"phi {phi}: cane shaft in wide-camera view -> {shaft_in_view(phi)}")
