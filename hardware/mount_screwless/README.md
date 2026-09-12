# hardware/mount_screwless/: the no-hardware phone mount

**Sagar owns this folder.** It is an alternative to [`../mount/`](../mount/), not a
replacement — pick whichever one is fitted on the day and say so in `CHANGELOG.md`.

The difference is the bill of materials. `../mount/` needs four M4 screws, four M4
brass heat-set inserts, an M5 bolt, an M5 nyloc, two M3 countersunk screws, two M3
inserts, two M3 nylon screws and two nylon nuts, plus a soldering iron with a
heat-set tip to fit them. This folder needs **none of that**. Four printed parts, a
cane, and a phone.

That is the pitch, not a shortcut: the iPhone already is the sensor suite, the
compute, the battery and the speaker. If the retrofit that turns an ordinary white
cane into a smart cane is *one spool of filament and nothing else*, then anyone with
a printer can make one, and the reason a smart cane costs $850 stops being obvious.

**Status (2026-09-11):** designed and rendered clean; **never printed.** Every
clearance below is a guess until the coupons come off the bed. Nobody has put this
on a real cane yet.

## Print these in this order

Do not skip to step 3. The three clearances decided in steps 1 and 2 are printer-
and cane-specific, and every part depends on them.

| # | Render | Solid volume | What it settles |
|---|---|---|---|
| 1 | `coupons.scad`, `what="bore"` | 17 cm³ · 22 g | `bore_clear` — how the collar sits on **your** cane |
| 2 | `coupons.scad`, `what="thread"` then `"dovetail"` | 12 + 31 cm³ | `thr_clear`, `dt_clear` |
| 3 | `collar` + `ring` | 16 + 14 cm³ | the clamp |
| 4 | `arm` + `cradle` | 19 + 34 cm³ | the rest |

Volumes are measured off the rendered STLs at 100% infill. At 25% gyroid the real
mass is well under half. Print times are **unknown — slice them and read the number**;
they depend on your machine and profile, and no two of your three printers will agree.

Coupons carry **notches, not numbers**: count the notches, fewest = smallest
clearance. OpenSCAD's `text()` needs fontconfig, which the portable Windows snapshot
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

**Modularity — one joint type, three interfaces.**

| Part | Is the interface to | Reprint it when |
|---|---|---|
| `collar` | the cane | the cane diameter changes |
| `arm` | the walking pose | you want a different camera angle |
| `cradle` | the phone | you change phone |

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
to match how the walker actually holds it and the camera angle follows.

## Measure these before you trust anything

Every one of these is currently a number someone read off a drawing or a caliper once.

- **`pole_d` — the cane.** Recorded 28.75 mm on Sep 10; Sagar later quoted 1.128 in
  (28.65) and asked for 1.13 in (28.70), which is what the file uses. All three are
  inside one print tolerance and `bore_clear` dominates, but measure at the exact spot
  the collar sits, because canes taper.
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
