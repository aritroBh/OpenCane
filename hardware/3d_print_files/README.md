# 3D print files — the screwless phone mount

Everything a person at a printer needs is in this folder. `gcode/` is sliced for the
**Creality SPARKX i7** (0.4 nozzle, 0.2 mm layers) and ready to copy onto a USB stick.
`stl/` is the same parts for any other slicer. The design, the reasoning and the runbook are in
[`../mount_screwless/`](../mount_screwless/); this page is only *what to print*.

**The G-code carries its own temperatures.** The filament slot you pick on the touchscreen only
decides which plastic gets fed to them. Check the Filament Selection screen before every job.
If it shows `PETG -> [blank]`, that machine has no PETG — do not map it onto a PLA slot.

| Material | Nozzle | Bed | Slot on the room's machines (check!) |
|---|---|---|---|
| PLA | 220 °C | 55 °C | 3 or 4 |
| PETG | 250 °C | 80 °C | 2 |

## Print in this order

Do not skip step 1 — three clearances in it are printer-specific and every part depends on
them. The bore rings are **already done** (`pole_d` = 27.65 mm, measured 2026-09-12); their
files are here only for completeness.

| # | File in `gcode/` | Slot | Time | Then |
|---|---|---|---|---|
| 1 | `PETG_slot2__next_3h33m17s.gcode` | PETG | 3 h 33 | Thread row + dovetail row in one job. Read it — below. On two machines: `PETG_slot2__thread_2h23m36s` (2 h 24) + `PLA_slot3or4__dovetail_41m57s` (42 min) |
| 2 | `PETG_slot2__arm_38m55s.gcode` | PETG | 39 min | Needs no coupon. Any free machine, any time |
| 3 | `PETG_slot2__collar_1h43m27s.gcode` | PETG | 1 h 43 | After step 1 is read |
| 4 | `PETG_slot2__ring_54m38s.gcode` | PETG | 55 min | Same |
| 5 | `PETG_slot2__cradle_1h34m24s.gcode` | PETG | 1 h 34 | Prints with support under the back plate. Peel it off; nothing touches that face |

Flat on the bed as sliced. Rotate nothing.

## Reading step 1

**Thread row — one threaded stub, four fluted nuts, notched on the top rim.** Screw each nut
down the stub by hand. Take the **smallest nut that runs freely for the whole length**. A loose
nut rocks about 1 mm at the top — normal, not a fault.

| Notches | `thr_clear` | `thr_axial` | |
|---|---|---|---|
| 1 | 0.45 | 0.25 | |
| 2 | 0.35 | 0.45 | |
| 3 | 0.45 | 0.45 | **the collar and ring in this folder are cut to this one** |
| 4 | 0.55 | 0.65 | if only this one works, something else is wrong — say so |

**Dovetail row — three tenons, three sockets, notched 1 / 2 / 3.** Notched base face **down**,
the way it printed. Slide each tenon into its socket; you want the one that moves with thumb
pressure and stays put when shaken.

| Notches | `dt_clear` | |
|---|---|---|
| 1 | 0.15 | |
| 2 | 0.25 | **the parts in this folder are cut to this one** |
| 3 | 0.35 | |

If the winners are **nut 3 and dovetail 2, print steps 3–5 as they are.** If not, write the
numbers on the coupon with a paint pen and tell whoever has the Windows machine: they go into
`hardware/mount_screwless/screwless_mount.scad` (`thr_clear`, `thr_axial`, `dt_clear`), then
`scripts\verify_mount.ps1`, `scripts\build_stl.ps1`, `scripts\slice_gcode.ps1` — five minutes —
and the new files get copied back here.

## Putting it together

1. **Ring off.** Drop the arm into the collar's socket from the top until it lands on the stop.
   Screw the ring on over it. The ring is the lock; there is no catch on this joint.
2. Slide the cradle **down** onto the arm's far tenon until it stops. The leaf catch clicks into
   the little window just under where the phone's bottom edge sits. Fingernail through that
   window to release.
3. Phone in from the **front**: bottom edge into the two corner cups first, then press the top
   back until the two corner caps snap over the top corners. To take it out: spread the two
   rails with a thumb and finger, lift the top edge.
4. On the cane: collar on, slide it to where it goes, tighten the ring.

**Pass/fail at the collar:** with **no cane** in it the ring reaches the shoulder. With the
**cane in** it stops about 3 mm short — that is the clamp gripping. If it reaches the shoulder
with the cane in, the bore is too big for that shaft.

## Not settled yet

- The three coupon numbers — step 1 decides. The parts here are cut to the expected winners.
- The camera plateau height (`plateau_h` = 49 mm) is scaled off Apple's drawing. Measure it with
  calipers while the phone is out; if it is under 47 mm, say so before the cradle is printed.
- The prototype shaft is a **broom handle** (27.65 mm). A real long cane is 9.5–13 mm at the tip
  and has a tip and a handle; this collar is a closed bore and goes on over the end. Later.
- Nothing from this geometry has been printed yet. The model checks are all green
  (`scripts\verify_mount.ps1`); the printer has the last word.

## Files

| `gcode/` | material, slot | what |
|---|---|---|
| `PETG_slot2__next_3h33m17s.gcode` | PETG, 2 | fit coupons: thread stub + 4 nuts, 3 dovetail pairs |
| `PETG_slot2__thread_2h23m36s.gcode` | PETG, 2 | the thread row alone |
| `PLA_slot3or4__dovetail_41m57s.gcode` | PLA, 3/4 | the dovetail row alone |
| `PETG_slot2__arm_38m55s.gcode` | PETG, 2 | arm |
| `PETG_slot2__collar_1h43m27s.gcode` | PETG, 2 | collar (the cane clamp body) |
| `PETG_slot2__ring_54m38s.gcode` | PETG, 2 | ring (the clamp nut) |
| `PETG_slot2__cradle_1h34m24s.gcode` | PETG, 2 | cradle (the phone holder), support on |

`stl/` has the same parts plus `coupons_bore.stl` (done, not needed again), already in print
orientation — do not rotate them in a slicer. The cradle needs support on build plate only,
with bridges left unsupported so its dovetail socket stays empty. Nothing else needs support.

These are a snapshot of `hardware/mount_screwless/` at the commit that added them. If the
`.scad` changes, regenerate and copy them back here — the file names carry the print time, so
a stale file is easy to spot.
