# Cane mount for the iPhone 17 Pro Max: design brief

Owner: Sagar (hardware, printing, CAD). App-side checks: Aritro. Written 2026-09-11 for the Sat
2026-09-12 demo. Files: `cane_mount.scad` (parametric model), `test_coupons.scad` (fit tests),
`pitch_model.py` (the tilt and clearance numbers in sections 4 and 5).

**Status: the SCAD files have not been rendered.** No OpenSCAD was installed where they were
written. They passed a bracket-balance and undefined-identifier check only. Press F5 before you
trust any of it.

---

## 0. Decisions

1. **Aim the camera 5° below horizontal. Keep it within 3–8°, not the 10–20° first proposed.**
   `LaneMath` splits the image into rows and never corrects for gravity. When the camera pitches
   10° or more, its torso band sees bare pavement at 1.6–2.1 m. The centre cue fires below
   2.0 m, so the cane would buzz all the time. The head band would also stop covering head
   height at the 1.5 m head-cue distance. The ground-hazard detector *is* gravity-aligned and
   still gets its near-field reference at 5° (section 4). Pitching steeper needs a software
   change first (section 13).
2. **Hinge angle φ = 90° − cane angle + camera pitch.** For a cane held 45° above horizontal,
   φ = 50°. The hinge is a 72-tooth face rosette, which gives 5° detents. Its usable range is
   35–80°, and an angle scale is engraved on the ear.
3. **Concept A, fully printed, is the primary mount.** Concept C (strap holder) is a bench-only
   fallback. Use concept B (commercial bike mount) only if a non-magnetic one is already in hand.
4. **Rigid and non-magnetic throughout.** No TPU in the load path. All metal is brass inserts,
   A4/A2 stainless that passes a fridge-magnet test, or nylon for the two cap screws only. No
   magnets anywhere, no MagSafe pack.
5. **Tooling:** everything is in OpenSCAD in git today. Move the cradle to Onshape or Fusion only
   if you have time to refine it.

---

## 1. Inputs and where they come from

Official Apple specs ([iPhone 17 Pro Max Tech Specs](https://support.apple.com/en-us/125091)):
78.0 mm wide × 163.4 mm tall × 8.75 mm deep; the camera plateau protrudes beyond the 8.75 mm.
233 g, aluminium unibody, IP68. Buttons: volume up/down, Action button, Camera Control, side
button, USB-C. MagSafe magnet array plus alignment magnet. Magnetometer. LiDAR Scanner on the
rear. Operating ambient 0–35 °C. Dual-frequency GPS.

Apple's dimensional drawing for accessory makers
([iphone-17-pro-max.pdf](https://developer.apple.com/download/files/accessories/dimensional-drawings/iphone-17-pro-max.pdf),
dated 2025-09-09) gives the values below, all in mm. Button positions are **centre ± half-length,
measured from the top edge**. "Left" and "right" are as seen from the screen.

| Feature | Value | Used for |
|---|---|---|
| Body | 77.98 × 163.43 × 8.75 | cradle pocket |
| Camera plateau | 2.55 above the back glass; lens glass a further 1.88 (4.43 total, 13.18 overall depth) | back plate stops below the plateau |
| Plateau height from the top edge | **~47–49, scaled off the drawing: MEASURE** | `plateau_h = 49` |
| Plan-view corner radius | **~11.7–12, from keep-out zones: MEASURE** | `phone_r = 11.7` |
| Rear camera 2 (Main / wide; the camera ARKit and the depth map use) | 33.61 from top, 14.37 from the right edge, Ø16.20 | optical axis in the preview |
| Rear camera 1 (ultra-wide), rear camera 3 (tele) | 14.37 / 23.99 from top | keep-outs |
| LiDAR ("rear sensor") | 34.16 from top, 64.18 from the right edge (the Action-button side), Ø6.65 | keep-outs |
| Flash | 13.82 from top, Ø6.80 | keep-outs |
| Rear keep-out cones (full angle) | ultra-wide 125°, **wide 90°**, tele 34°, **LiDAR 84°**, flash 123° inner / 157° outer | nothing may enter them |
| Left side | Action 34.28 ± 3.45; Vol+ 48.43 ± 5.60; Vol− 62.63 ± 5.60; buttons 2.66 wide, centred at 4.375 in depth | window 28–71 from top |
| Right side | side button 55.53 ± 8.85; Camera Control 111.82 ± 8.55 (Apple keep-out 25 long) | windows 44–67 and 97–127 |
| Bottom | USB-C centred, plug keep-out 12.45 × 6.60; 5 speaker holes and 2 mics span 15.4–62.6 from one edge | 52 mm open floor |
| Display border | 2.56 from the housing edge to the active area | lip reach 1.2 < 2.56 |
| Compass (magnetometer) | 156.91 from top (6.5 above the bottom edge), about 10 mm off centre | no metal near the bottom |
| Drawing notes | 1 no metal contact with the product; 3 do not obstruct the imaging features; 5 metal permeability ≤ 1.05 µ; 7 no magnets on the rear except MagSafe | hardware choice |

**Measure with calipers before the final print:** stick Ø at the collar location, `phone_r`,
`plateau_h`, and the button windows against the real buttons. Everything else comes from the
drawing.

---

## 2. What the software needs from the mount

| Software fact (file) | Consequence for the mount |
|---|---|
| `LaneMath` portrait remap (`rotateForPortrait = true`); Mount toggle "Phone held upright (portrait)" | Phone upright in portrait, top up, rear camera facing forward. |
| `LaneMath` skips the bottom 25 % of the image as ground. Head band = rows 0–37.5 %, torso = 37.5–75 %. 10th-percentile depth per cell. No gravity correction. | The camera pitch must be small, 3–8° down (section 4). |
| `CueDecider`: head < 1.5 m, centre < 2.0 m (clears at 2.15), side < 1.2 m | Pavement must read above ~2.2 m in the torso band. A 1.8 m overhang must still be in the head band 1.5 m away. |
| `GroundSampler` + `GroundHazardDetector`: gravity-aligned; needs ≥ 12 samples 0.8–1.5 m ahead as the ground reference; scans 1.5–3.5 m; ignores depth < 0.3 m (the cane shaft) and > 4.5 m | The ground from ~1.2 m out must be in view, which holds at ≥ 3° down. A shaft in view closer than 0.3 m is harmless. |
| Sweep gate: frames with \|gyro\| ≥ 0.6 rad/s are untrusted (`ios/README.md` §6) | A wobbly mount adds gyro spikes and loses frames, so the mount must be stiff. |
| `HapticPlayer`: obstacle cues are Taptic Engine transients (Geiger 2–8 Hz, left 2 taps 120 ms apart, right 3 taps 100 ms apart, head 2 hard hits 80 ms apart). The phone's buzz is the obstacle channel; the watch is the fallback. | Rigid coupling from phone to cane to hand. No foam or TPU in the path. |
| `LocationService`: GPS course above 0.7 m/s; **compass when slower**; `headingOrientation = .portrait`; the calibration sheet is declined | No magnets and no permeable metal near the phone. The compass sets the heading at every standstill (start, crossings). |
| `DepthEngine` (`worldAlignment = .gravity`); ARKit stops when backgrounded or locked (`ios/README.md` §6) | The side button and Camera Control must not be pressable by accident, but the side button must still be reachable for the Guided Access triple-click. |
| Thermal `.serious` turns off mesh classification (`ios/README.md` §6) | Don't insulate the back. Shade the phone from the sun. |
| ARKit + LiDAR ≈ 3–4 h on battery (`ios/README.md` §6) | Power bank and cable routing (R12). |
| Go / no-go: "A wall at 1 m reads 0.8–1.2 m in all six tiles" (`ios/README.md`) | Bench test T2. |

---

## 3. Requirements

| # | Requirement | How the design meets it |
|---|---|---|
| R1 | Wide camera, LiDAR, ultra-wide and tele fully unobstructed | Back plate stops 2 mm below the plateau. Above that line, nothing sits behind the back glass except the cap's side walls and top bridge. They lie outside the phone outline and reach at most 3.5 mm back, which is in front of the lens glass (4.43). At the flash they are ~84° off its axis, outside even its 157° cone. The hinge, arm and collar are ≥ 76° off the wide camera's axis. |
| R2 | Portrait, facing forward | Cradle holds the phone upright; the hinge axis is lateral. |
| R3 | Pitch 5° down (3–8°), adjustable | Rosette hinge, 5° detents, φ = 35–80°, engraved scale (section 4). |
| R4 | Rigid coupling, so taps are felt at the grip | PETG throughout; clamped Hirth teeth; 4 × M4 split collar; 0.3 mm phone clearance. |
| R5 | No magnets; low-permeability metal only | Brass inserts. A4 (316) stainless screws, or A2 that pass a **fridge-magnet test** (reject any screw the magnet picks up; cold-worked A2 can be slightly magnetic). Nylon only for the cap screws next to the top antenna zone, which carry little load and no haptics. No MagSafe accessories. |
| R6 | Buttons and screen usable | Full screen visible (1.2 mm lips on the border only). Windows over Action/volume, side button and Camera Control. The buttons sit ~2 mm below the rail surface, so a brush can't press them but a finger can. |
| R7 | Guided Access workable | Side-button window for the triple-click. See T0 for the Camera Control setting. |
| R8 | Thermal | Four vent windows in the back plate. Plateau and top fully exposed. Light-coloured filament. |
| R9 | Power bank and USB-C | 52 mm open floor. Right-angle USB-C plug turned toward the back. Zip-tie slots in the arm and the ear. The bank stays ≥ 20 cm from the phone. |
| R10 | Quick release | Phone: 2 thumb screws, lift the cap, slide the phone up (~20 s). Cradle: unscrew the knob; the collar stays put, so its position is kept. |
| R11 | Weight near the grip | Collar ~150 mm below the hand. About 120 g printed plus 233 g phone (estimate; weigh it). |
| R12 | Sweep loads, vibration | Clamp friction ≫ sweep torque. Nyloc M5 and witness marks; re-snug after 1 h (PETG creep). |
| R13 | 1 m drop onto grass | Lips stand 1.6 mm proud of the glass. Corner cups. The arm and ear land before the lenses. |
| R14 | Rain | Phone is IP68; PETG doesn't care. Optional visor (`visor_depth` ≤ 15 mm stays outside the wide and LiDAR cones). Wipe the lenses. |
| R15 | Printable in hours with no supports | Every part has a support-free orientation (section 10). |
| R16 | Fits the 28.75 mm stick exactly | `pole_d` + `bore_clear`, tuned with the bore rings. |

---

## 4. Tilt: from cane geometry to hinge angle

**Cane angle.** The grip is ~0.85–0.95 m high and the tip ~1 m ahead of it, so the cane runs at
atan(0.9 / 1.0) ≈ 42°. The realistic range is 40–50° above horizontal, and it moves a few degrees
with every tap.

**Why the phone rotates back toward vertical.** A phone lying flat along the shaft would have its
camera looking ~45° *up* into the sky. The hinge turns it until the long axis is φ from the cane
axis:

    phi = 90 deg - cane_angle + camera_pitch_down
    cane 40 / 45 / 50 deg, pitch 5 deg  ->  phi = 55 / 50 / 45 deg

**Camera height.** In this geometry the camera sits ~178 mm above the collar. The collar is
150 mm down the shaft from a 0.9 m hand, which is 106 mm lower at 45°, so it sits at 0.79 m and
the camera at ≈ 0.97 m.

**What each pitch does.** `pitch_model.py` computes this for flat ground and a half vertical field
of view of 33.5° (portrait, long axis). The value in brackets is the spread for 31–36°. Measure
the real FOV as 2·atan(960 / f) from `frame.camera.intrinsics` at 1920 × 1440.

| Pitch down | Nearest ground seen | Torso band reads bare pavement at | Head band top at 1.5 m range | `groundSkipFraction` needed |
|---|---|---|---|---|
| 0° | 1.47 m (near field barely seen) | 3.05 m | 1.96 m | 0.20 |
| 3° | 1.31 m | 2.66 m | 1.88 m | 0.21 |
| **5°** | **1.22 m** | **2.46 m (2.29–2.65)** | **1.83 m** | 0.23 (default 0.25 is OK) |
| 8° | 1.10 m | 2.21 m (2.07–2.36), marginal | 1.74 m | 0.27 |
| 10° | 1.02 m | **2.08 m (1.96–2.21): constant false centre cue** | 1.69 m | 0.29 |
| 15° | 0.86 m | **1.79 m** | **1.54 m: a 1.8 m branch is never in the band at 1.5 m** | 0.35 |
| 20° | 0.72 m | **1.60 m** | **1.39 m** | 0.42 |

**Reading the table.** The centre cue fires below 2.0 m and clears above 2.15 m, so pavement must
stay above ~2.2 m: that caps the pitch at ~8°. The ground-hazard detector needs ≥ 12 ground
samples 0.8–1.5 m ahead. `GroundSampler` reads every 4th row, and each sampled row gives roughly
25–30 samples inside the 0.9 m corridor. At 0° only ~3 of 256 image rows see that ground, so the
detector may get zero sampled rows: marginal. At 3° it is 17 rows (~4 sampled rows, ~100 samples)
and at 5° it is 26 rows, which is plenty. That sets the floor at ~3°. The cane's own angle wobbles by ±5° while
walking, and the sweep gate drops the worst frames. So the target is **5°** and the detent step is
**5°**; 10° steps would land at 0° or 10°, which is outside the window.

**If the team wants 10–15° for more ground coverage:** raise `groundSkipFraction` to ~0.30–0.35
in `CaneKitLogic`, with a test, and accept a lower head band. The better fix is a gravity-aware
ground cut in `LaneMath` that uses the ARKit camera pitch. Either is a Logic change for Aritro
(AGENTS.md rule 3). The mount can already reach those angles.

---

## 5. What the SCAD builds

```
  collar frame (side view, cane at 45 deg)          phone frame
        grip                                         top  +--------+  plateau (clear, no plate)
         \                                               |  cap   |
          \        phone (screen faces the walker)       |--------|  split_y = top - 20
           \      /                                      | rails  |  button windows
            \    /  <- camera looks 5 deg down, fwd      |  back  |  back plate (vents)
             \  /                                        | plate  |
     collar ==[]==o hinge (ear + rosette + knob)     bot +--cups--+  floor gap for USB-C
               \                                            arm fin -> hinge 14 below, 30 behind
                tip
```

- **Split collar** for the 28.75 mm stick, bore +0.3 mm. There are two halves with a 1.0 mm gap,
  so tightening always loads the stick and the halves never bottom out. Four M4 × 16 socket screws
  go into M4 brass heat-set inserts in the lower half.
- **Ear** on the upper half. It is 46 mm from the cane axis to the hinge axis, with a Ø44 disc,
  a 72-tooth rosette on its +X face, a captive M5 nyloc pocket on its −X face, an engraved φ scale
  (35–80°, long ticks every 10°, extra-long at the design angle) and a zip-tie slot.
- **Arm** (separate part, so both rosettes print well). An 8 mm fin carries the matching rosette
  (a half-tooth phase makes φ land on multiples of 5°) and a pointer notch. Its root edge sits in
  a 0.6 mm pocket in the back plate, held by 2 × M3 countersunk screws from the phone side into M3
  inserts. The hinge axis is 14 mm below the phone and 30 mm behind the back glass.
- **Cradle.** Back plate (below the plateau, 4 vents), side rails whose front lips form a slide-in
  channel, and bottom corner cups that leave a 52 mm open floor. The phone slides down from the top.
- **Cap.** Top corners plus a bridge, joined to the rails by 2 × M3 × 14 through tabs outside the
  side walls. The front lip exists only at the top corners, clear of the front camera, sensors and
  receiver. The bridge is notched over the receiver and front mic. Optional visor.
- **Knob.** A scalloped knob that an M5 × 30 hex bolt presses into.

**Clearance** (cradle box vs cane, collar and ear, `pitch_model.py`): 2.5 mm at φ = 35°, 3.7 mm
at 40°, 4.7 mm at 45°, **5.6 mm at 50°**, ≥ 6.2 mm from 55° up. The tightest spot is the
cradle's bottom-back corner against the ear. The cane shaft stays out of the wide camera's frame
up to φ = 60° (`shaft_in_view` in `pitch_model.py`). From 65° it shows in the bottom rows, which
`LaneMath` skips. At 80° it reaches the torso band and would read as a centre obstacle at 0.35 m.
That is one more reason to stay near 50°.

**Balance.** The phone's centre of mass sits ~97 mm off the cane axis and ~88 mm up-shaft of the
collar. With the collar ~150 mm below the hand, the moment of inertia about the wrist is
≈ 0.38 kg × (0.15 m)² ≈ 0.009 kg·m². The same mass at mid-cane (0.6 m) would be 16× that. Check
that the knuckles and the extended index finger clear the screen; in this geometry the fist is
~4 cm from it. Slide the collar lower if they touch.

---

## 6. Rigid coupling vs damping

| | Rigid (chosen) | Damped (rubber or TPU layer, silicone bands, vibration dampener) |
|---|---|---|
| Obstacle taps felt at the grip | Crisp: the 80–120 ms tap spacing survives | Smeared or lost; the Geiger 8 Hz blurs |
| Depth frames / sweep gate | Phone moves with the cane: fewer gyro spikes, stable pitch | Phone rocks on the damper: pitch wobble, more SWEEPING frames |
| Camera OIS | Tip taps reach the camera | Protected |
| Apple guidance | Apple warns that high-amplitude vibration, *specifically from high-power motorcycle engines*, can degrade OIS and advises a damping mount for lower-power vehicles ([support.apple.com/102175](https://support.apple.com/en-us/102175)) | — |

**Decision: rigid.** Haptics through the cane are the product. Cane taps are short, low-energy
impacts, not sustained engine vibration, and the demo is hours long, not months. If the team
later wants protection, use a thin, hard, preloaded layer: 0.5 mm of rubber under full clamp
load, never a soft band.

---

## 7. Concepts

| | A. Printed split collar + rosette hinge + cradle (this folder) | B. Commercial bike stem/bar mount + printed pole adapter | C. Rubber-strap universal holder |
|---|---|---|---|
| Examples | `cane_mount.scad` | Quad Lock Out Front Mount Pro (bars 22 / 25.4 / 31.8 mm, so print a 1.5 mm shim from 28.75 to 31.8; needs a Quad Lock case or adaptor; **the MAG adaptor and cases are magnetic**). Peak Design Universal Bar Mount (22–35 mm silicone band; **SlimLink is magnetic + mechanical**). Lamicall bike holder (15–40 mm spring jaws, no magnets; the repo's insurance buy). | Silicone "X-grip" or spider bike holder, or velcro around a case |
| Haptic coupling | Rigid | Twist-lock heads are rigid, but band clamps (Peak) damp | Poor |
| Camera angle | Designed: 5° down, 5° detents | Made for horizontal handlebars; on a 45° cane it needs a printed wedge to reach φ ≈ 50° | Whatever the strap allows; drifts |
| Magnets / compass | None | Quad Lock MAG and Peak SlimLink put magnets on the phone's back; avoid for this app | None |
| Buttons, screen, plateau | Designed windows and keep-outs | Jaws often sit on the side buttons (Lamicall) | Straps cross buttons and screen |
| Time to a working mount | ~6–8 h (print + assembly), unrendered risk | Minutes if one is already in hand; no shipping by tomorrow | 10 min |
| Cost | ~$5 filament + ~$5 hardware | $40–80 (Quad Lock / Peak), ~$30 Lamicall | ~$10 |
| Drop / shake | Corner cups + lips; tested (section 12) | Proven phone retention | Phone can pop out |

**Recommendation: build A tonight.** Keep C, or a Lamicall if someone can get one locally today,
as the stage fallback for a sighted bench demo only: its compliance mutes the taps, so the
obstacle cues then go to the watch ("Silence haptics" routes them there). Use B only if a
non-MAG Quad Lock or a Lamicall is already in someone's bag. Never use a magnetic head for this
app.

---

## 8. 24-hour build plan (H+0 = start, 3 printers)

| When | Sagar (hardware) | Aritro (app / phone) |
|---|---|---|
| H+0:00–0:45 | Install OpenSCAD (`brew install --cask openscad`, or a 2025 snapshot for the fast Manifold backend). F5 every `part`; fix anything reported. Calipers: stick Ø at the collar spot, `phone_r`, `plateau_h`, button positions. | Charge the phone and power bank. Find a right-angle USB-C to USB-C cable (≤ 12 mm plug body). |
| H+0:45–1:30 | Print coupons: P1 rings + corners, P2 rosettes (~40 min). | Guided Access set up (T0). Camera Control setting. |
| H+1:30–2:00 | Read the coupons (see `test_coupons.scad`). Set `bore_clear`, `clear`, `teeth`. F6 and export STLs. | Measure the walker's cane angle c (T1). Tell Sagar φ = 95 − c. |
| H+2:00–6:00 | P1 cradle (~3.5 h). P2 collar_a then collar_b (~2.5 h). P3 arm + cap + knob (~1.5 h). Times are estimates; the slicer's number wins. | App dry run with the phone hand-held. |
| H+6:00–7:00 | Heat-set inserts, assembly, collar on the stick, set φ, witness marks. | — |
| H+7:00–8:00 | Bench tests T2–T6 together. | Reads the tiles and cues. |
| H+8:00–9:00 | T7 shake/sweep, T8 drop (dummy block first). Fix. | — |
| H+9:00–10:30 | Outdoor T9–T11: curb, compass, thermal walk. | Trip log off the phone. |
| H+10:30–14:00 | Reprint buffer. A cradle reprint takes 3.5 h, so start by H+11. | CHANGELOG / todo entries (AGENTS.md rule 10). |
| H+14–22 | Sleep. | Sleep; phone and bank on charge. |
| H+22–24 | Re-snug all screws, check witness marks and φ, demo dry run with Guided Access on. | Same. |

---

## 9. Tooling

| Tool | Cost | Good at | Weak at | Verdict |
|---|---|---|---|---|
| **OpenSCAD** | Free, open source | Text files that diff in git; every dimension is a named parameter; parameter sweeps (coupons); the Manifold backend is fast | No fillets or constraints; CGAL renders are slow; complex organic shapes | **Use for the collar, hinge and coupons (and the whole mount today).** |
| CadQuery | Free (Python) | Code in git *and* real B-rep fillets; STEP export | Conda/pip setup; nobody on the team has used it | Good later, not in 24 h |
| **Onshape** | Free plan (documents public) | Browser, nothing to install; sketch constraints, fillets, assemblies with mates; version history; can trace Apple's PDF drawing | Free docs are public; needs internet; not in git (export STEP and STL into the repo) | **Use to refine the cradle** (fillets, grip feel) if time allows |
| **Fusion** | Free personal licence | Strongest sketch and fillet tools; CAM; Sagar may already know it | Install and account; closed format; personal-licence limits | Equal to Onshape; pick whichever Sagar is faster in |
| FreeCAD 1.x | Free, open source | Offline, parametric, spreadsheet-driven | Steep UI; topological naming (better in 1.0) | Not for a 24 h build |

---

## 10. Print settings

| Setting | Value | Why |
|---|---|---|
| Material | **PETG** (ASA if the printer is enclosed); PLA only for coupons | PLA creeps under bolt clamp load, softens near 55–60 °C (sun on a dark part gets there) and cracks in drops. PETG is tough and stable to ~75 °C. Use a light colour. |
| Nozzle / layer | 0.4 mm; 0.2 mm layers, **0.12 mm for collar_a and arm** | Rosette teeth are 0.8 mm tall |
| Walls | 5 perimeters (2.0 mm), 5 top / 5 bottom layers | Clamp bosses and insert holes need solid walls |
| Infill | 40 % gyroid (cradle, cap); **60 % gyroid (collar, arm)** | Load path |
| Supports | None needed | See orientations |
| Brim | 5 mm on collar_a/b and the standing rosette coupon | Tall narrow footprints |
| Holes | M3 3.4, M4 4.4, M5 5.5; nut pockets +0.2; inserts per datasheet (M4 5.6, M3 4.0 as modelled) | |
| Bore | 28.75 + `bore_clear`. Default +0.3 on the diameter; tune with the rings: first ring that slides on, + 0.1. | The printed bore minus the stick must stay under `clamp_gap` (1.0), or the halves bottom out before clamping |
| Phone gap | `clear` 0.3 per side; tune with the corner coupons | |
| Heat-set inserts | Iron at ~230–245 °C for PETG, press straight, let cool before loading | |

**Orientations** (each `part` exports already oriented):

- **collar_a, collar_b: standing on an end face, bore vertical.** The clamp hoop force and the
  boss-to-ring bending, which is the load across the split, run along the layers rather than
  across them. The bore prints round with no arch overhang. The ear's bending also stays in the
  layer plane. The ear's teeth print on a vertical face; all flanks are ≤ 45°.
- **arm: +X face down, teeth up.** Fin bending stays in the layer plane.
- **cradle, cap: back side down.** Lips are 3-step chamfers. The rails' weak direction (the phone
  pulling toward the screen side loads the wall root across layers) is covered by 2.4 mm walls,
  short wall height and the cap tying the rail tops together.
- **knob: flat.**

---

## 11. Assembly and setting the angle

1. Press 4 × M4 inserts into collar_b's split face and 2 × M3 inserts into the arm's root edge.
2. Clamp the collar on the stick with the ear on the **upper** side of the cane in the walking
   pose, **~150 mm below the hand** (the index finger must not reach the screen). Tighten the
   4 × M4 × 16 evenly until snug; the 1 mm gap should not close. Mark the stick at both collar
   ends with tape.
3. Screw the arm to the back plate: 2 × M3 × 8 countersunk, A4 or magnet-tested A2. Nylon is
   too compliant here because this joint carries the haptics. Heads sit 0.3 mm below the
   surface.
4. Put an M5 nyloc nut in the ear pocket. Run the M5 × 30 (pressed into the knob) through the
   arm and the ear.
5. Measure the walker's cane angle c (T1). Set φ = 90 − c + 5 by reading the arm's notch against
   the ear's ticks (long tick = multiple of 10°; the extra-long tick is 50°). Tighten the knob
   firmly by hand. Draw a paint-pen witness line across the ear and arm.
6. Slide the phone down between the rails into the bottom cups. Fit the cap: 2 × M3 × 14, nylon
   preferred, with nuts in the cradle tabs.
7. If using power: right-angle USB-C turned toward the back. Zip-tie the cable to the arm slot
   and the ear slot, then along the shaft with 2–3 velcro ties. The bank goes on a velcro strap on
   the shaft just below the hand, or in the walker's pocket, ≥ 20 cm from the phone. For a walk
   under ~1 h, start at 100 % and skip the cable; there is less to snag.

---

## 12. Test protocol

Run in order. Record pass/fail and numbers in `CHANGELOG.md` under "test on device".

| # | Test | Pass |
|---|---|---|
| T0 | **Fit.** Coupons read (bore ring, corner clearance, rosette mesh). Collar doesn't turn under a firm two-hand twist. Phone slides in and the cap fits; no rattle when shaken by hand. Action, volume and side buttons press through their windows; the full screen is visible. Guided Access: triple-click the side button in CaneKit works through the window. Camera Control can't take the app away: Guided Access blocks it, and also turn off or remap Camera Control's launch in Settings (verify on this iOS 27 build). Check that the Action button still reaches "Where am I" under Guided Access. | All yes |
| T1 | **Angle.** The walker holds the cane in their normal pose. A second phone's Measure → Level laid along the shaft reads c. Set φ = 90 − c + 5. | φ set, witness mark drawn |
| T2 | **Wall at 1 m** (from `ios/README.md` go/no-go). Face a flat wall, phone back 1.0 m from it. | All six tiles read 0.8–1.2 m |
| T3 | **Empty floor** (pitch check). Flat floor, ≥ 4 m clear ahead, stand still, then walk slowly. | Torso tiles CLEAR or > 2.2 m, **no centre Geiger buzz**. If the centre reads 1.5–2.2 m, the pitch is too steep: go down one detent (−5°). |
| T4 | **Head row.** A helper holds a flat board level, lower edge at 1.7 m (a branch at head height); walk toward it. Repeat with a hand overhead (`ios/README.md` go/no-go). | Head cue plus "Head height." before the board is 1.3 m away. If not, the pitch is too steep. |
| T5 | **Curb** with "Detect drop-offs" on. Walk slowly toward a down-curb from 4 m, then an up-curb. | "Drop-off ahead, …" spoken before the edge is 2 m ahead (the detector looks 1.5–3.5 m out); "Step up ahead" for the up-curb. If never announced, check pitch ≥ 3° with T3 still clear. |
| T6 | **Haptics felt at the grip.** Blindfolded walker, normal grip. Haptics card: Test left, centre, right and head haptic, 5 random trials each, standing and while sweeping. Compare with the phone hand-held. | 5/5 identified for each pattern; felt "about as strong as hand-held". If weaker, look for a loose joint (knob, collar, cap). |
| T7 | **5 min shake/sweep.** Normal sweeping plus two-point tapping on concrete for 5 min, app running a route. | Witness marks unmoved (collar, hinge, screws). Phone unmoved in the cradle. App still in the foreground with no lock. Trip log shows continuous lanes/cues. |
| T8 | **1 m drop onto grass.** First with a 233 g dummy block of the phone's size, then with the phone. Drop the cane from grip height 3×: phone side down, sideways, tip first. | Phone stays in; no cracks; φ within one detent (re-check the witness line); app still running |
| T9 | **Compass.** Face a known direction (sidewalk edge, map), standing still. Compare the heading hand-held and mounted, then mounted with the USB-C cable and bank attached. | Within 10°; within 15° with power attached |
| T10 | **Thermal.** 30 min outdoor walk with ARKit on. | Thermal pill never `.serious` (if it is: shade, lighter filament, remove the bank from near the phone) |
| T11 | **Rain** (optional). Spray the lenses. | Note degradation; wipe; demo only in the dry |

---

## 13. Open risks and follow-ups

- **Unrendered SCAD.** Budget 30–45 min for the first F5 and fixes. The `assert()`s encode the
  clearance rules.
- **Plateau height and corner radius** are scaled, not dimensioned. Measure them before the
  3.5 h cradle print.
- **72-tooth rosette** may print mushy on a worn nozzle. The rosette coupon tells you; fall back
  to `teeth = 36` (10° steps: pick φ closest to 95 − c and accept ±5°). If the nearest 10° detent
  lands outside 3–8° down on the Mount card, pick the nearest detent inside the window (prefer the
  flatter one); if none fits, tell Aritro (the app's `groundSkipFraction` would need a tested change).
- **PETG creep** under the M4 clamp: re-snug after the first hour and before the demo.
- **Single-shear hinge.** One rosette face carries the phone ~97 mm off the cane axis. Pitch is
  locked by the teeth, but a sideways knock pries the faces apart. That preload comes from a
  hand-tight knob. If T6 or T7 shows the phone rocking sideways, tighten the knob with pliers or
  swap to a plain M5 hex bolt and spanner. A second ear (a fork around the arm) is the proper fix
  after the demo.
- **Software: none of this is in `hardware/`, so it is for Aritro.**
  (a) If T3 fails at every usable pitch, raise `LaneConfig.groundSkipFraction` using the table in
  section 4. (b) A gravity-aware ground cut in `LaneMath` would let the mount pitch further down
  for more hazard coverage. (c) Log the camera pitch from `frame.camera.transform` in the trip log
  so the mount angle is recorded with every test.
- The old `cad/` drafts (12.7 mm cane, ESP32 grip, sensor pod) are the superseded
  pre-phone-only plan. This folder replaces `cad/` for the phone mount.

---

## 14. Sources

- [Apple: iPhone 17 Pro Max Tech Specs](https://support.apple.com/en-us/125091)
- [Apple Developer: Dimensional Drawings (iPhone 17 Pro Max PDF)](https://developer.apple.com/download/files/accessories/dimensional-drawings/iphone-17-pro-max.pdf), index at [developer.apple.com/accessories/dimensional-drawings](https://developer.apple.com/accessories/dimensional-drawings/)
- [Apple: exposure to vibrations might impact iPhone cameras](https://support.apple.com/en-us/102175)
- [Quad Lock: Out Front Mount and Pro](https://support.quadlockcase.com/hc/en-us/articles/6880482299151-Out-Front-Mount-and-Pro), and the Pro's 22 / 25.4 / 31.8 mm fit and bundled MAG adaptor per [road.cc review](https://road.cc/content/review/quad-lock-out-front-mount-pro-278471)
- [Peak Design: Universal Bar Mount](https://www.peakdesign.com/products/universal-bar-mount) (22–35 mm, magnetic/mechanical SlimLink)
- Repo: `ios/README.md` §6, `ios/Logic/Sources/CaneKitLogic/LaneMath.swift`, `CueDecider.swift`,
  `Hazards.swift`, `ios/CaneKit/Depth/GroundSampler.swift`, `ios/CaneKit/Haptics/HapticPlayer.swift`,
  `ios/CaneKit/Navigation/LocationService.swift`, `docs/ideas.md` §7 and §9 (stick 28.75 mm,
  3 printers, Lamicall 15–40 mm)
