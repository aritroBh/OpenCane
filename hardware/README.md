# hardware/: phone-to-cane mount

> **Printing? Start at the print list at the top of
> [`mount_screwless/PRINTING.md`](mount_screwless/PRINTING.md).** It says which files, in what
> order, on which filament slot, and what to check when each one comes off the bed. The G-code
> itself is on the repo's Releases page (`mount-gcode-step25`) or regenerated in five commands
> on a Windows machine with OpenSCAD + Creality Print.

The only new hardware in OpenCane / CaneKit is a mount. It clamps the iPhone 17 Pro Max upright to
the 27.65 mm non-metal stick (measured by the bore rings on 2026-09-12; it is a broom handle
standing in for a cane), near the grip, with the LiDAR and rear camera facing forward and
~5° down. The phone's own buzz has to be felt through the cane. Everything else (AirPods Pro,
Apple Watch) is off the shelf. This folder replaces the old `cad/` drafts for the phone mount;
those drafts assumed a 12.7 mm cane and an ESP32 grip.

**Sagar owns this folder.** Everything here is a starting point drafted on the software side from
Apple's dimensional drawings and a pitch model. Change the concept, the CAD tool, the geometry and
the print plan with your own ideas and experience. The app needs only four things from any mount:
the phone upright with the rear camera and LiDAR clear and facing forward; the camera 3–8° below
the horizon with the cane held normally (the Mount card shows it live); a firm enough grip that the
phone's buzz is felt in the handle, with nothing magnetic near the phone's bottom edge (compass);
and the shaft out of the camera's view. The full team context is in
[`docs/TEAM_HANDOFF.md`](../docs/TEAM_HANDOFF.md).

**Status (2026-09-12, late):** two designs. `mount/` (screwed, this page's quick start) is a
draft nobody has rendered. `mount_screwless/` is the live one: simulated end to end
(`scripts/verify_mount.ps1`, 30 checks green), sliced, bore rings printed and read; the rest is
not yet printed. See `CHANGELOG.md` Steps 21 and 25.

## Files

| File | What it is |
|---|---|
| [`mount/DESIGN.md`](mount/DESIGN.md) | The design brief: Apple dimensions and sources, what the app needs, requirements, the tilt derivation (**camera 5° down, not 10–20°**), concepts A/B/C, 24 h plan, tooling, print settings, assembly, test protocol |
| [`mount/cane_mount.scad`](mount/cane_mount.scad) | Parametric OpenSCAD model: split collar, rosette hinge with 5° detents and an angle scale, arm, cradle, cap, knob, and an assembly preview. Set `part` to export each STL, already in print orientation. |
| [`mount/test_coupons.scad`](mount/test_coupons.scad) | Bore-fit rings (28.75 −0.2 / +0 / +0.2 / +0.4), phone-corner fit coupons (gap 0.2 / 0.3 / 0.4), rosette mesh plates |
| [`mount/pitch_model.py`](mount/pitch_model.py) | `python3 mount/pitch_model.py` reproduces the pitch table and the cradle-to-cane clearance check. Edit camera height and FOV after measuring. |

## Quick start (Sagar)

1. Install OpenSCAD (`brew install --cask openscad`; a 2025 development snapshot renders much
   faster). Open `mount/cane_mount.scad` and press F5 with `part = "assembly"`. Look at
   `hinge_angle` 35, 50 and 80. Fix anything it reports.
2. Measure with calipers: the stick Ø where the collar goes, the phone's corner radius
   (`phone_r`), the camera plateau height from the top edge (`plateau_h`), and the button windows.
3. Print `mount/test_coupons.scad` and read it (instructions are in the file header). Set
   `bore_clear`, `clear` and `teeth`.
4. Export and print collar_a, collar_b, arm, cradle, cap and knob in PETG
   (`DESIGN.md` §10).
5. Assemble (`DESIGN.md` §11). Set `hinge_angle` = 95 − cane angle. Run the tests in
   `DESIGN.md` §12 with Aritro.
6. Fine-tune by reading the phone: OpenCane's Mount card shows "Camera tilt N° down · N fps" live.
   Click the hinge until it says **good** (3–8° down) with the cane held the way the walker holds
   it. The same number is in every trip-log `lanes` line as `tilt`.

## Bill of materials

Printed (PETG, light colour; times and masses are estimates, so trust the slicer and the scale):

| Part | Qty | Source | Print | ≈ Mass |
|---|---|---|---|---|
| collar_a (upper half + ear + rosette) | 1 | `cane_mount.scad`, `part = "collar_a"` | ~1.5 h, standing | 30 g |
| collar_b (lower half) | 1 | `part = "collar_b"` | ~1 h, standing | 18 g |
| arm (fin + rosette) | 1 | `part = "arm"` | ~45 min, flat | 16 g |
| cradle | 1 | `part = "cradle"` | ~3.5 h, back down | 30 g |
| cap | 1 | `part = "cap"` | ~30 min, back down | 6 g |
| knob | 1 | `part = "knob"` | ~20 min | 5 g |
| Coupons | 1 set | `test_coupons.scad` | ~40 min | 30 g |

Hardware (no magnets; brass, A4/A2 stainless or nylon only; see `DESIGN.md` R5). **Fridge-magnet
test every screw and nut before use**: reject anything the magnet picks up (cold-worked A2 can
be slightly magnetic).

| Item | Qty | Goes in | Note |
|---|---|---|---|
| M4 × 16 socket-head screw, A2 | 4 | collar clamp | |
| M4 brass heat-set insert, ~8 mm long | 4 | collar_b split face | model hole Ø5.6; check the insert's datasheet |
| M5 × 30 hex bolt, A2 | 1 | hinge | head pressed into the knob (drop of CA) |
| M5 nyloc nut, A2 | 1 | ear pocket | stops the knob backing off from tapping vibration |
| M3 × 8 countersunk screw, A4 (or magnet-tested A2) | 2 | arm → back plate, from the phone side | not nylon: this joint carries the haptics. Heads sit 0.3 mm below the surface; no metal touches the phone |
| M3 brass heat-set insert, 5.7 mm long | 2 | arm root edge | model hole Ø4.0 |
| M3 × 14 screw, nylon preferred | 2 | cap → cradle tabs | next to the phone's top antenna zone |
| M3 nut, nylon preferred | 2 | cradle tab pockets | |
| Right-angle USB-C to USB-C cable, 30–50 cm, plug body ≤ 12 mm | 1 | power | plug turned toward the back of the phone |
| USB-C PD power bank ≥ 5,000 mAh, **not MagSafe** | 1 | strap below the grip or pocket | ≥ 20 cm from the phone (compass) |
| Zip ties 2.5 mm / velcro straps | 5 / 3 | cable routing | slots in the arm and the ear |
| PETG filament | ~150 g | | |
| Paint pen, painter's tape | 1 / 1 | witness marks on screws, hinge, collar | |

Tools: calipers, soldering iron with a heat-set tip, hex keys 2 / 2.5 / 3 mm, 8 mm spanner.

Optional fallback: a Lamicall bike phone holder (15–40 mm clamp, no magnets, ~$30), for a sighted
bench demo only (`DESIGN.md` §7). Do **not** use a Quad Lock MAG or Peak Design SlimLink head:
both put magnets on the phone's back, and the app uses the compass whenever the walker stands
still.

## Who does what

| Who | Owns |
|---|---|
| **Sagar**, **Tommy** (hardware) | Calipers, OpenSCAD render and fixes, coupons, all prints, inserts, assembly, setting the hinge angle, T0 fit, T7 shake, T8 drop, reprints |
| **Aritro**, **Aarav**, **Tejas** (app) | Phone charged; Guided Access (triple-click the side button in OpenCane → Options: Touch, Side Button, Volume Buttons, Keyboards Off, Motion On → Start; then the watch is the only input, see `docs/devices_setup.md` step 4) and the Camera Control setting; app-side tests T2–T6, T9, T10; trip logs; `CHANGELOG.md` / `docs/todo.md` entries (AGENTS.md rule 10); any `CaneKitLogic` change the tests call for (e.g. `groundSkipFraction`, `DESIGN.md` §13) |
| **Walker** (blindfolded tester) | Holds the cane in their own natural pose for the angle measurement (T1); identifies haptic patterns (T6); walks |
| **Spotter** (sighted teammate) | Walks beside the walker on every outdoor test and films it with a second phone (`ios/README.md`) |
