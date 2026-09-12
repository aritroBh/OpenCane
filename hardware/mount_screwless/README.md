# hardware/mount_screwless/: the no-hardware phone mount

> **At a printer? [`../3d_print_files/`](../3d_print_files/) has the G-code, the STLs and the print list.**

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

**Status (2026-09-12, evening):** designed, rendered clean, and **simulated** - every
pair of parts that must not touch has been intersected in the model and comes out empty,
the thread has been driven through its travel in the model, and each printable is a single
shell in its print orientation (`.\scripts\verify_mount.ps1`, 30 checks, all green).
**Still never printed as a whole.** The bore rings have been printed and read (`pole_d` =
27.65, settled - see `CHANGELOG.md` Step 21), and one thread coupon pair was printed and jammed two
turns in; that is now explained and fixed twice over (see the thread note below). Every other
clearance is still a guess until the coupons come off the bed, and nobody has put this on a real
cane - the prototype shaft is a **broom handle**; real long canes are 9.5–13 mm at the tip end.

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
>
> **The first printed thread pair jammed two turns in (2026-09-12), and the model says
> why - twice.** First, the tooth was not the tooth the parameters described: the flank was a
> straight chord that dipped inside the minor circle, so the union with the core swallowed it and
> the printed root was 0.74 mm instead of 1.5 (Step 21 measured it; the profile is polar now).
> Second, on the real collar the ring could not have reached the shoulder even with a perfect
> thread: lift the ring in the model and turn it with the helix, and at every height from
> 6 mm up there was 0.165 cm³ of ring inside collar: the collar's cone started at the
> thread's *major* radius, 0.75 mm outside the ring's thread crests, so the ring's own
> internal thread ploughed into the cone's base with 3.8 mm still to go. The cone now
> starts 0.10 mm *inside* the crest radius (`cone_relief`) and the ring's threaded band
> passes it freely; the sweep is empty until the cone is meant to engage. The thread is cut
> to nut 3 of the four-nut coupon, [0.45 radial, 0.45 axial] (the pair that jammed was
> [0.35, 0.25]; 0.125 mm per flank is under one line of over-extrusion), and its flank is 60°
> from vertical now (was 69°, which printed every lower flank in air). With real 60° flanks the
> radial clearance also becomes axial slack - about 0.49 mm per flank in total - so **a loose ring
> rocks about 1 mm at the top; that is normal and disappears once it bears on the cone.**
> **On the cane the ring is supposed to stop about 3 mm short of the shoulder** - that is the
> collet gripping. If it reaches the shoulder with the cane in, the bore is too big.

The assembly preview (`part = "assembly"`) is a look, not a test. It draws the
ghost cane, the ghost phone and a red ray along the rear camera's optical axis, and three
faults were found by looking at it: the dovetail sockets were on the wrong axis, the
collar's pad was shorter than the dovetail, and the phone's bottom corner cleared the
shaft by 1.1 mm. Render it after any change; if the red ray does not come out roughly
horizontal, tipped slightly down, and miss the shaft, the arm is wrong. **But it cannot
show an overlap** - two parts drawn through each other look like two parts. On 2026-09-12
it was hiding 6.9 cm³ of arm inside the phone. The test is `verify.scad` run by
`.\scripts\verify_mount.ps1`: it renders the *intersection* of every pair that must not
touch (empty = pass), the intersections that must exist (the collet squeeze), the thread
lifted and turned through its travel, and the ring as the arm's lock, and it counts shells.
Run it after any change. It takes two minutes.

## Print these in this order

Do not skip to step 3. The three clearances decided in steps 1 and 2 are printer-
and cane-specific, and every part depends on them.

| # | Render | Solid volume | What it settles |
|---|---|---|---|
| 1 | `coupons.scad`, `what="bore"` | ~20 cm³ | **the cane diameter itself** — see the conflict below |
| 2 | `coupons.scad`, `what="thread"` then `"dovetail"` | 12 + 31 cm³ | `thr_clear`, `dt_clear` |
| 3 | `collar` + `ring` | 36 + 24 cm³ | the clamp |
| 4 | `arm` + `cradle` | 38 + 33 cm³ | the rest |

Volumes are measured off the rendered STLs at 100% infill. At 25% gyroid the real
mass is well under half.

**Sliced, per part, 2026-09-12 (evening)** - see the table in [`PRINTING.md`](PRINTING.md).
Every plate is a separate file written by `slice_gcode.ps1`, which is also the only thing that
knows to turn support on for the cradle. The old `opencane_mount_plate.3mf` (six parts, 4 h 31)
predates the redesign below and must not be printed.

**Support: none, except the cradle.** The cradle stands on its dovetail block, so its
back plate sits 5 mm off the bed, and the rails and corner caps with it. The block has a
45-degree flare that carries the plate around the block; the rest wants support - "on
build plate only" is enough, and it lands on the outer face of the back plate, which
nothing touches in use. `slice_gcode.ps1` turns it on for the cradle by itself, sets
`max_bridge_length` to 30 so the socket's 24.5 mm roof is bridged instead of being filled
with support (Orca's default is 10, and it did fill it), and refuses to write a cradle
file without support. Every other part is drawn so no downward face passes 45 degrees,
and the dovetail flanks are exactly 45 for that reason - they were 67, which put the
lower flank of every tenon and socket in the air.

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
peel one open. Gravity runs within 5° of both slides, so each joint has a stop at its
lower end and something to keep it from riding back up:

- **collar ↔ arm.** With the ring off, the arm drops into the collar's socket from
  above and lands on the stop. The ring then screws on over it, and its rim reaches
  1.5 mm past the tenon's buried face: the arm can rise 0.5 mm and no more. No spring,
  nothing to click, nothing to fail. (The first design had the socket the other way up,
  held by a pawl alone against the phone's whole weight.)
- **arm ↔ cradle.** The cradle slides down onto the arm's far tenon and lands on its
  stop; a printed leaf pawl on the tenon cams in on the way and clicks out into a
  window in the cradle's roof, just below the phone's bottom edge, where a fingernail
  can push it back to release. The leaf lies on the fin's bed face, which is the only
  place a printed spring in a pocket comes out solid.

**The cradle's socket is below the phone, not behind its middle.** This is forced. The
camera has to face away from the cane, so the cradle's back plate is on the far side of
the phone from the arm, and the only route from the collar to that plate that does not go
through the phone is around its bottom edge. The arm therefore runs out and up to a pad
under the phone's bottom edge and the cradle hangs off that.

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

`arm_reach` is load-bearing in the same way. It sets how far the phone stands off
the shaft and with it how far the shaft sits outside the camera cones: at 58 mm the lower
shaft is **47.5° off the wide camera's axis against Apple's 45° keep-out, and 5.4° outside
the LiDAR's**. Shorter is worse. The closest printed thing to the shaft is now the
cradle's dovetail block; there is an assert on that gap, it is **55 mm**, and the echo
prints it on every render.

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

  **Settled: 27.65 mm, by the bore rings, 2026-09-12** (ring 1 = 27.75 barely went on, 2 and 3
  went on, both colours agreed; see Step 21). 28.75 is retired everywhere. For the day a
  different shaft turns up, `.scriptsuild_stl.ps1 -PoleD 28.75` writes a collar and ring for it
  next to the 27.65 ones and `slice_gcode.ps1 -Plate collar -PoleD 28.75` slices them; only those
  two parts are sized by the cane. A closed 71 mm bore goes on over the end of the shaft - fine
  on the broom handle, not designed for a real cane with a tip and a handle (Step 21, item 4).
- **`phone_r`, `plateau_h`** — scaled off Apple's drawing, flagged MEASURE in
  `../mount/cane_mount.scad`. Same caveat here; the cradle inherits them.
- **Real clamping force.** Unknown. The collet either holds a 233 g phone through a
  full sweep or it does not, and nothing but a cane and ten minutes of walking will
  tell you.

## Known-unknown list

- Never printed as a set. Never fitted. Never walked. One ring + one collar were printed
  from the previous geometry and the ring stopped short - explained and fixed above, not
  yet re-printed.
- The pawl spring (`pawl_t` 1.2 mm, three lines) is a calculation, not a measurement:
  about 4 N to press the catch flush, 1% strain. It is on the far tenon only, and its
  pocket costs that tenon its bed-side lip over 22 of its 30 mm.
- The cradle holds the phone with bottom corner cups and two sprung top-corner caps on
  rails; the phone goes in from the front, bottom edge first, and the caps spread about
  6 mm to let the top corners past (about 2 N each, by calculation). Retention is
  positive in all six directions and needs no friction. Untested.
- The arm's dovetail tenons print on their side, so one flank of each is a 45° overhang
  and its surface is what it is; the dovetail coupon's tenons now lie the same way so the
  `dt_clear` you read off them is the one the arm gets.
- `plateau_h` (49) is still scaled off the drawing, not measured. The plate stops 2 mm
  below it; if the real plateau is lower than 47 mm from the top edge, the plate top and
  the rails' roots need to come down.
- The cane's lower shaft sits 2.5° outside the wide camera's keep-out cone at a 45° cane
  angle. A flatter walking pose puts it inside; the Mount card's tilt reading is the
  thing to watch.
- No rain hood. `../mount/DESIGN.md` wants one; this design does not have one yet.
