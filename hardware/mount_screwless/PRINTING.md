# Printing the screwless mount — operator runbook

This is the how-to. [`README.md`](README.md) is the why. If you are standing at a
printer and want to know which file to send, you are in the right document.

Everything here was established on the night of 2026-09-12 on the SPARKX i7s in the
room, mostly by getting it wrong first. Where a number came from a measurement it says
so; where it is still a guess it says that too.

## The one rule

**A G-code file carries its own temperatures. You cannot fix a wrong one at the printer.**

Creality's machine profile substitutes the numbers into the start macro at *slice* time:

```
START_PRINT EXTRUDER_TEMP=220 BED_TEMP=55
```

That line is frozen into the file. Re-tagging the spool on the touchscreen does not
change it. All the filament-slot choice decides is *which plastic gets fed to that
temperature* — and nothing on the machine checks that the two agree.

So a PETG plate sent to a printer whose CFS holds four PLA spools will heat to 250 °C
and push PLA through it: stringing, ooze, a likely heat-creep jam, and a first layer
squashed soft on an 80 °C bed. That nearly happened here. The tell is on the Filament
Selection screen — the job chip reads

```
PETG  ->  [blank]
```

and that blank means the machine has nothing to satisfy it. **Back out. Do not map it
onto a PLA slot.**

| Material | Nozzle | Bed | Slot, on the machines in this room |
|---|---|---|---|
| PLA | 220 °C | 55 °C | 3 or 4 |
| PETG | 250 °C | 80 °C | 2 |

The slot numbers are *not* a property of the design — they are where the spools happened
to be. One machine in the room has PLA in all four. Check the screen every time, and set
the slot by hand rather than tapping AUTO so you can see which spool it picked.

## Slicing

```powershell
.\scripts\build_stl.ps1                                    # .scad -> stl/
.\scripts\slice_gcode.ps1 -Plate bore -Material PLA -Walls 4   # stl -> gcode/
```

`slice_gcode.ps1` drives Creality Print 7.2 headlessly — it is an Orca fork and takes
Orca's command line, so no GUI, no fighting for the mouse, and the same inputs give the
same file every time. It re-opens what it wrote and prints the material, both
temperatures, the wall count, the time and the weight, and it **refuses to name a file
safe if it cannot read the material back out**. Read that block before you print.

G-code lands in `hardware/mount_screwless/gcode/`, which is gitignored like `stl/`.

Two Windows gotchas are baked into that script with comments explaining them. Do not
tidy either away:

- The Creality exe needs `2>&1 | Out-String` **and** a relaxed `$ErrorActionPreference`.
  It logs its whole run to stderr at `[error]` level even on success; unredirected under
  `-ErrorAction Stop` the call returns instantly with an empty exit code and writes no
  G-code, which looks exactly like "the model does not fit the bed".
- This is the **opposite** of `build_stl.ps1`, where `2>&1` must be *avoided* because it
  trips `$?` on OpenSCAD's clean exits. Same shell, same version, opposite fix — the two
  executables use the streams differently.

Orca writes its settings block as a **footer**, roughly 600 to 36 lines before EOF, not
a header. Reading only the head of the file gets you the `START_PRINT` line and nothing
else.

## Print order

The cane's diameter gates everything. `collar`, `ring`, `cradle` and `socket` all derive
from `pole_d`, so none of them can be sliced honestly until the bore rings have been read.

| # | Plate | Material | Time | What it settles |
|---|---|---|---|---|
| 1 | `-Plate bore -Walls 4` | PLA | 52m53s, 22.4 g | the cane diameter |
| 2 | `-Plate bore -Walls 4` | PETG | — | the same, without a shrinkage correction |
| 3 | `-Plate thread` | PETG | — | `thr_clear`, and whether the thread exists at all |
| 4 | `-Plate dovetail` | PLA | — | `dt_clear` |
| 5 | `-Plate arm` | PLA | 23m42s, 13.4 g | nothing — it is a real part, see below |
| 6 | `-Plate coupons -Walls 4` | PETG | 3h01m, 62.8 g | all three rows at once |

**The arm is the exception and it is worth knowing why.** It is the only real part that
can be printed before any measurement comes back. Its tenons are drawn at
`dt_section(0)` — nominal, no clearance applied — and the pawl is fixed geometry, so
neither `pole_d` nor `dt_clear` reaches it. Print it whenever a machine is free.

## Reading the bore rings

Before anything else, spend 60 seconds with the caliper at the exact spot the collar will
sit, three times, rotating 120° between readings. The two figures in dispute are **27.65**
and **28.65 mm** — exactly 1.00 mm apart, which is the signature of a digit slip rather
than two honest disagreeing measurements. If three readings agree, you do not need the
print.

Rings are identified by **notches**, fewest = smallest:

| Notches | Bore |
|---|---|
| 1 | 27.75 mm |
| 2 | 28.05 mm |
| 3 | 28.35 mm |
| 4 | 28.65 mm |
| 5 | 28.95 mm |

Slide each onto the cane **at the collar station** — not up from the tip, canes taper.
Record the whole pattern ("1,2 will not go; 3 goes firm; 4,5 rattle"), not just the
winner; the pattern is what shows the reading is real. A ring that hangs up in the first
millimetre and then slides free is first-layer squish, not the bore — judge at mid-height.

Then:

```
pole_d = (the SMALLEST ring that goes on at all) - 0.10
```

**Not −0.35.** The older note in `coupons.scad` said 0.35 and was wrong by about 0.25 mm.
For a collet that is the difference between gripping the cane and never reaching it.

Print the rings at **4 walls**. At the profile default of 2, a 10 mm ring is 1.7 mm of
solid over 2.5 mm of 15% grid — it flexes under your thumb, so a bore that is genuinely
too tight still feels like it "goes on" and the gauge reads large.

`bore_clear` is **not** an output of this test. The rings are rigid; the collar is a
collet that closes onto the cane when you tighten the nut. Clearance there is a design
decision (0.40 today) and `collet_squeeze` takes it up.

### Why both a PLA and a PETG ring set

The collar will be PETG. PETG shrinks more than PLA — the estimate is ~0.06 mm on a
28 mm bore, worst case 0.168 mm, and that worst case is larger than the clearance the
collet has to work with. It is the weakest link in the whole measurement. A PETG ring set
removes it: you measure with rings made of the material the real part will be made of.

If you have both, **use the PETG answer.** If you only have PLA and you are borderline
between two rings, take the larger one.

## Reading the thread pair

Screw the ring onto the stub. It should turn by hand for the full length — no tool, no
slop you can feel at the top. Binds → raise `thr_clear` by 0.1. Wobbles → drop it by 0.1.

This is the coupon that matters most right now. Until 2026-09-12 the thread generator
produced no thread at all: a twisted `linear_extrude` maps **angle** to height, and the
tooth was drawn as a flat offset in y, so it came out **0.031 mm** thick and sliced away
to a smooth cylinder. The collar's "clamp" was a plain tube. It measures 0.62–0.75 mm
now, and this coupon is the first physical proof either way.

**If the ring will not thread on, do not print the collar.**

Prefer the PETG result — `thr_clear` is material-dependent and the collar is PETG.

## Reading the dovetail pair

Notched 1/2/3 = 0.15 / 0.25 / 0.35 mm. Slide each tenon into its socket: it should move
with thumb pressure and stay put when you shake it. That number goes in `dt_clear`.

The socket and the real part are built by the same method, so the number transfers even
though the clearance is not perfectly uniform around the flank — see the known-issue list
in `README.md`.

## Calibration

- **Bed mesh: yes**, worth the two minutes. Ring 1 and ring 5 sit 182 mm apart, so bed
  tilt reads as a fake difference in bore size.
- **Input shaping and flow calibration: no**, not before a gauge print — they run at job
  temperature and cost time.
- Whatever calibration state you print the coupons in, **print the collar in the same
  state**. The point of a gauge is that it and the part share their errors.

## Getting files onto a machine

These printers were not reachable over the LAN from the dev laptop (`172.23.209.71:4408`
refused), so it was USB the whole night.

- A printer's file browser gets slow with a few hundred loose files on the stick. Putting
  everything else in one subfolder fixes it — the browser only lists the root.
- **Do not assume you can pull the stick out once a print starts.** Whether the machine
  streams from USB or copies to internal storage was never confirmed on these units. If
  you need the stick for a second printer, check the touchscreen for a "copy to local"
  option first; failing that, start the print, let it lay real plastic for two minutes,
  then pull it — if it stops you have lost two minutes instead of an hour.
