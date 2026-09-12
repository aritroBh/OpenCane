# hardware/mount_screwless/: the no-hardware phone mount

**Sagar owns this folder.** It is an alternative to [`../mount/`](../mount/), not a
replacement — pick whichever one is fitted on the day and say so in `CHANGELOG.md`.

The difference is the bill of materials. `../mount/` needs four M4 screws, four M4
brass heat-set inserts, an M5 bolt, an M5 nyloc, two M3 countersunk screws, two M3
inserts, two M3 nylon screws and two nylon nuts, plus a soldering iron with a
heat-set tip to fit them. This folder needs **none of that**. Four printed parts (six
if you choose the ball joint), a cane, and a phone.

That is the pitch, not a shortcut: the iPhone already is the sensor suite, the
compute, the battery and the speaker. If the retrofit that turns an ordinary white
cane into a smart cane is *one spool of filament and nothing else*, then anyone with
a printer can make one, and the reason a smart cane costs $850 stops being obvious.

**Status (2026-09-12):** designed and rendered clean; **never printed.** Every
clearance below is a guess until the coupons come off the bed. Nobody has put this
on a real cane yet.

> **Read [`PRINTING.md`](PRINTING.md) before you send anything to a machine.** It is the
> operator runbook: which file, which filament slot, which temperatures, in what order,
> and how to read each coupon.
>
> **The thread did not exist until 2026-09-12.** `linear_extrude(twist=)` maps *angle*
> to height, so the tooth — drawn as a flat offset in y — came out 0.031 mm thick and
> sliced away to a smooth cylinder. The collar's clamp was a plain tube. It is rewritten
> as an angular sector and measures 0.62–0.75 mm, but **that has never been printed.**
> The thread coupon is the first physical proof either way, and if the ring will not
> thread onto the stub, do not print the collar.

The assembly preview (`part = "assembly"`) is not decoration - it is the test. It
draws the ghost cane, the ghost phone and a red ray along the rear camera's optical
axis. Three separate faults were found by looking at it and at nothing else: the
dovetail sockets were on the wrong axis, the collar's pad was shorter than the
dovetail it was supposed to hold, and the phone's bottom corner cleared the shaft by
1.1 mm. Render it after any change. If the red ray does not come out roughly
horizontal, tipped slightly down, and miss the shaft, the arm is wrong.

## Print these in this order

Do not skip to step 3. The three clearances decided in steps 1 and 2 are printer-
and cane-specific, and every part depends on them.

| # | Render | Solid volume | What it settles |
|---|---|---|---|
| 1 | `coupons.scad`, `what="bore"` | ~20 cm³ | **the cane diameter itself** — see the conflict below |
| 2 | `coupons.scad`, `what="thread"` then `"dovetail"` | 12 + 31 cm³ | `thr_clear`, `dt_clear` |
| 3 | `collar` + `ring` | 30 + 14 cm³ | the clamp |
| 4 | `arm` + `cradle` | 19 + 34 cm³ | the rest |

Volumes are measured off the rendered STLs at 100% infill. At 25% gyroid the real
mass is well under half.

**Sliced, 2026-09-12.** All six mount parts on one SPARKX i7 plate, `0.20mm Standard
@SPARKX i7 0.4 nozzle`, support on, build-plate-only: **4 h 31 min, 101.94 g, 34.18 m**
of filament. Support is 6.8% of the time and support interface another 3.2% — almost
all of it under the cradle. The saved project is `opencane_mount_plate.3mf` in this
folder (gitignored, like every other build artifact). Slice positions, X/Y in mm:
cradle (65, 150), collar (150, 200), ring (150, 140), lock (215, 140),
socket (215, 200), arm (70, 42). Creality Print's auto-arrange packs them too tightly
and reports gcode path conflicts; these positions do not.

**Support: none, except the cradle.** The cradle stands on its dovetail block, so
its back plate sits 7 mm off the bed. The block has a 45-degree flare that carries
the plate for 7 mm all round, and the rest wants support - "on build plate only" is
enough, and it lands on the outer face of the back plate, which nothing touches in
use. Every other part is drawn so no downward face passes 45 degrees.

Coupons carry **notches, not numbers**: count the notches, fewest = smallest. OpenSCAD's `text()` needs fontconfig, which the portable Windows snapshot
does not ship, so text silently renders as nothing and you get four identical
unlabelled rings. Notches also read by thumb, which is on-brand here.

## Build

```powershell
.\scripts\build_stl.ps1
```

STLs land in `stl/`, which is gitignored. `-Part collar` does one part; `-Png` also
writes previews.

**Use a 2025 snapshot of OpenSCAD, not the winget release.** The 2021.01 build that
`winget install OpenSCAD.OpenSCAD` gives you has no Manifold backend and takes
**6 minutes 52 seconds** to render the collar. The snapshot does the same part in
**0.3 s**. One is a workable edit loop and the other is not. Download the portable
zip from <https://files.openscad.org/snapshots/> and unzip into `%USERPROFILE%\Tools\`;
the build script finds it there on its own. One is already unzipped at
`C:\Users\sriva\Tools\OpenSCAD-2025.09.15\`.

## Printer

Sliced for the **Creality SPARKX i7** (the profile is already in Creality Print 7.2):

- build volume **260 × 260 × 255 mm** — the largest part, the coupon plate, is
  174 × 195 mm, so everything fits flat with room
- 0.4 mm hardened steel nozzle, Klipper; default profile
  `0.20mm Standard @SPARKX i7 0.4 nozzle`
- the machine is on the network at `172.23.209.71:4408`, so Creality Print can send
  straight to it
- it is a multi-material machine. Print these single-colour — a filament change mid
  part buys nothing here and the purge wastes more PETG than the parts use.

Nothing in the design needs a specific printer; this is just what it was sized against.

## How it works

**Clamp — a collet.** The collar's nose is a cone with four slots cut down it. The
ring screws down over that cone and squeezes the slots shut onto the cane. It is a
drill chuck. Clamping force comes from a wedge, so vibration cannot walk it loose the
way it walks a snap-fit collar loose, and the grip scales with how hard you turn the
ring rather than with how well you guessed the bore.

Both thread helices run along the **print Z axis**, which is the only orientation a
printed thread is reliable in. This is why the collar is not simply a C-clamp with a
printed bolt across it: that puts the thread axis horizontal, where it prints as a
stack of overhangs.

**Aiming — pick one.** `joint = "dovetail"` (default) gives a fixed angle set when you
print the arm: stiffest, nothing to slip, but you reprint the arm to change it.
`joint = "ball"` gives a clamped ball joint — aim by hand, then screw the lock ring
down. It adds two parts (`socket`, `lock`) and reuses the same collet trick as the cane
clamp, so its holding force comes from a wedge you tighten rather than from friction.

Read this before choosing the ball: **both the hardware brief and
`../mount/DESIGN.md` rejected ball joints deliberately** — "ball joints slip under
sweep vibration and break the Point-to-Identify calibration." Clamping answers that
objection but does not delete it. An undertightened clamp still slips, and it now slips
in two axes instead of none. The dovetail arm stays the safe demo part. Run T7 (shake)
on whichever you fit and confirm the Mount card still reads 3–8° down afterwards.

**Modularity — one joint type, three interfaces.**

| Part | Is the interface to | Reprint it when |
|---|---|---|
| `collar` | the cane | the cane diameter changes |
| `arm` | the walking pose | you want a different camera angle |
| `cradle` | the phone | you change phone |
| `socket` + `lock` | the aim, if `joint = "ball"` | — |

All three meet at the same sliding dovetail running **along the cane axis**, so the
phone's weight loads every joint in shear across its widest face and never tries to
peel one open. A printed cantilever pawl clicks into each socket; press it to release.

## What the app needs from any mount

From [`../README.md`](../README.md) and `../mount/DESIGN.md` — these are requirements,
not preferences, and this design inherits all of them:

- phone upright, rear camera and LiDAR clear and facing forward
- camera **3–8° below the horizon** with the cane held normally (CaneKit's Mount card
  shows it live; the trip log records it as `tilt`)
- grip firm enough that the phone's own buzz is felt in the handle
- **nothing magnetic** anywhere near the phone — the app uses the compass whenever the
  walker stands still. This design has no metal in it at all, which is the one
  requirement it satisfies for free.
- the shaft out of the camera's view

`arm_angle` is derived, not typed: `90 - cane_angle + cam_down`. Change `cane_angle`
to match how the walker actually holds it and the camera angle follows. The identity
is the one stated in `../mount/cane_mount.scad` line 33: camera pitch below the
horizon = `arm_angle + cane_angle - 90`.

`arm_reach` is load-bearing in the same way. The phone hangs below the dovetail by
half the back plate, and `arm_angle` rakes that bottom corner back toward the shaft,
so the reach is what buys knuckle clearance, not just standoff. There is an assert
on it; the current gap is **13.1 mm** and the echo prints it on every render.

## Measure these before you trust anything

Every one of these is currently a number someone read off a drawing or a caliper once.

- **`pole_d` — the cane. UNRESOLVED, and it is the one number everything depends on.**
  Three figures are in circulation:

  | Source | Value |
  |---|---|
  | Dial caliper, Sagar, Sep 11 — **what this folder uses** | **27.65 mm** |
  | `1.128 in`, quoted Sep 11 | 28.65 mm |
  | `hardware/mount/cane_mount.scad` + the hardware brief | 28.75 mm |

  This is a 1.1 mm spread. That is not a rounding difference — it is three times any
  sane bore clearance, and a collar bored for 28.75 will simply spin on a 27.65 shaft.
  The bore coupons bracket all three — **27.75 / 28.05 / 28.35 / 28.65 / 28.95 mm**
  bores, 1–5 notches, even 0.30 steps — so the cane settles it in one **53-minute**
  print (`-Plate bore -Material PLA -Walls 4`: 52m53s, 22.4 g).

  The earlier set (27.85 / 28.25 / 28.45 / 28.95 / 29.15) was replaced because it
  *started above* the caliper reading: if 27.65 was right, the smallest ring still
  fitted and the test had no lower bracket, so it could only contradict itself. It
  also buried 28.65 and 28.75 inside one 0.50 mm gap.

  Read them with `pole_d = (smallest ring that goes on) − 0.10` — **not −0.35**, which
  is what `coupons.scad` said until 2026-09-12 and was wrong by about 0.25 mm. For a
  collet that is the difference between gripping the cane and never reaching it. Full
  procedure in [`PRINTING.md`](PRINTING.md).

  Whatever wins, **`hardware/mount/` is still modelled at 28.75 — one of the two
  folders is wrong**, so say which in `CHANGELOG.md` once you know. Measure at the
  exact spot the collar sits; canes taper.
- **`phone_r`, `plateau_h`** — scaled off Apple's drawing, flagged MEASURE in
  `../mount/cane_mount.scad`. Same caveat here; the cradle inherits them.
- **Real clamping force.** Unknown. The collet either holds a 233 g phone through a
  full sweep or it does not, and nothing but a cane and ten minutes of walking will
  tell you.

## Known-unknown list

- Never printed. Never fitted. Never walked.
- The pawl spring thickness (`pawl_t` 1.6 mm) is a guess. PETG at that thickness may
  be stiff enough to never click or thin enough to snap; find out on the dovetail
  coupons before printing the arm.
- The cradle holds the phone with side lips, bottom cups and one sprung top latch, and
  covers only the bottom 112 mm of a 163 mm phone so the camera plateau stays clear.
  Whether that is enough retention when the cane taps a kerb is untested.
- No rain hood. `../mount/DESIGN.md` wants one; this design does not have one yet.
