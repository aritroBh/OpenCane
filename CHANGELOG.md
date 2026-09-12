# CaneKit changelog

Build log for the hackathon. One entry per step; each ends with what to test on the phone.

## Step 25 — The arm went through the phone: the screwless mount simulated, redesigned, and re-sliced (Sat Sep 12, evening)

Windows-side hardware pass over `hardware/mount_screwless/`, prompted by a printed ring that
would not go fully down. Done in parallel with Step 21 on a different machine and merged onto it
afterwards: Step 21's measured `pole_d`, its polar `thread_profile` (the chord version printed a
0.74 mm square tooth whatever the parameters said), `thr_sink`, `pawl_catch_h` and the four-nut
thread coupon are kept; its `block_y` / `arm_tip_t` / `arm_boss` / `dt_stand` / `port_w` are
superseded by the socket-below-the-phone layout and the open floor below, which close the four
items Step 21 left as "still open and blocking" (numbers 1-3; number 4, the closed bore, stands). Instead of trusting the assembly preview, every pair of parts that
must not touch was **intersected** in OpenSCAD and measured, the ring was driven through its
travel in the model, and each printable was checked for shells and overhangs in its print
orientation. The harness is in the repo: `hardware/mount_screwless/verify.scad` run by
`scripts/verify_mount.ps1` (30 checks; measuring done by `scripts/stl_tools.js`). All green at
the end of the pass; the design has still not been printed as a set.

**What was wrong, in order of how badly it would have gone at the printer:**

- **The arm passed through the phone - 6.9 cm³ of overlap - and through the cradle's block
  (2.2 cm³ — Step 21 measured 4.7 / 0.95 cm³ on its own variant).** Forced by geometry, not a typo: the camera must face away from the cane, so the
  cradle's back plate is on the far side of the phone from the arm, and a fin landing at
  mid-phone height has to go through the phone. The preview showed nothing because overlapping
  colours look like parts. Fix: the cradle's dovetail socket moved to below the phone's bottom
  edge (`sock_y`), the arm runs out and up to a pad under it, and the fin lands on the pad's
  foot. Same layout the screwed mount uses.
- **The cradle's top latch was drawn straight through the phone.** Its riser was inside the
  phone pocket, so the phone cut left the hook as a **loose island 8.75 mm off the bed**
  (0.275 cm³, its own shell in the STL), and its leaf sat on the camera plateau (0.574 cm³).
  Replaced by two sprung top-corner caps on rails beside the phone, behind the button line;
  the phone loads from the front. Floor opened between the cups for USB-C.
- **The cradle slid off the arm under its own weight**: gravity runs 5° off the dovetail's
  slide and the socket was a through-slot with no stop. Stops at the lower end of both sockets
  now. The collar joint is locked by the ring (socket open at the top, arm drops in with the
  ring off, the ring's rim reaches 1.5 mm past the tenon); the far joint has a leaf pawl that
  lies on the fin's bed face - the only place a printed spring in a pocket comes out solid.
- **The ring could not reach the shoulder.** The collar's cone started at the thread's major
  radius, 0.75 mm outside the ring's thread crests, so the ring's own thread hit the cone's base
  with 3.8 mm to go: 0.165 cm³ of overlap at every height from 6 mm up, found by lifting the ring
  in the model. The cone now starts 0.10 mm inside the crest radius (`cone_relief`), taper 1.6
  (finger tips 1.75 mm), and the sweep is empty until the last 7.5 mm, where the squeeze (now
  0.6, was 0.8 - about 1 N·m at the ring) builds to 0.83 cm³ at the shoulder. Thread slack and radial
  clearance are cut to nut 3 of Step 21's four-nut coupon, [0.45, 0.45] (the bench's [0.35, 0.25]
  jammed; 0.125 mm per flank is under one line of over-extrusion); flank 60° (was 69°, every lower
  flank in air).
- **Every headless slice had support OFF** (`enable_support = 0` in the footer; the GUI plate had
  it on by hand). The cradle's plate would have printed in mid-air. `slice_gcode.ps1` turns it on
  for the cradle, bridges the socket roof rather than filling the socket with support (Orca's
  default `max_bridge_length` 10 did fill it - checked in the gcode), and refuses a cradle file
  without support.
- **Dovetail flanks were 67° overhangs** wherever the width is the build axis (the arm's tenons,
  the cradle's socket). Now 45° (24 / 14 / 5); the dovetail coupon's tenons lie on their side
  like the arm's so `dt_clear` is read on the real geometry.
- `build_stl.ps1` never rendered the coupon rows under the names `slice_gcode.ps1` asks for
  (`coupons_bore.stl`; Step 21 added them as `bore.stl`, which the slicer still could not find), so
  the runbook's first command failed on a fresh clone. Fixed; `coupons_next` and the ball-tip parts
  are in the same list. `-PoleD` added to both scripts for the day a different shaft turns up.

**Measured, not asserted:** wide camera axis −5.00°; lower shaft 47.5° off it (keep-out 45°),
5.4° outside the LiDAR cone; closest printed point to the shaft 55.5 mm (assert and vertex
scan agree); thread handedness confirmed (turned against the helix: 0.16 cm³ of tooth clash);
flank slack measured at 0.25 per side; ring lock: arm free at 0.4 mm, stopped at 1 mm.

**Still unknown:** `thr_clear`/`thr_axial` (four-nut coupon, not yet printed from this geometry),
`dt_clear`, `plateau_h`, and everything a printer does to a number. **Still open from Step 21:** the
collar is a closed 71 mm bore, so on a real cane it goes on over the tip or the handle. On the
broom-handle prototype that is a non-issue; on a cane it is a split collar or a removable tip,
and neither is designed.

test on the bench: run `.\scripts\verify_mount.ps1` (all green); print the bore rings, then the
thread set - ring 1 must run the stub's full length by hand; then collar + ring: with no cane
the ring reaches the shoulder, with the cane it stops ~3 mm short.

## Step 27 — Three icon-only root tabs (Sat Sep 12)

The phone UI was one long scroll. A sighted helper (and the XCUITests that scroll it) had to
page past Guide, the grid, hazards, haptics, watch and mount to reach anything. Split into
three pages under an icon-only bottom bar:

| Tab | Icon | Cards |
|---|---|---|
| Guide | `figure.walk` | Guide + trip / arrival |
| Sense | `square.grid.3x3.fill` | Depth status, Obstacles, Hazards |
| Settings | `gearshape.fill` | Haptics, Watch, Mount, This phone |

The bar is `CKTabBar` (`ios/CaneKit/UI/TabBar.swift`): ivory/ink sliding capsule
(`matchedGeometryEffect`), 60 pt hit targets, VoiceOver words **Guide / Sense / Settings**
(⚠ test contract). The page cross-fades over 0.2 s; Reduce Motion is an instant swap. Tab
changes do not speak through `SpeechQueue` (VoiceOver already announces the selected button).
Only the visible page is in the tree, so the 30 Hz depth isolation on Sense holds.

XCUITests that used to find Head row / haptic buttons / Mount toggles on the same scroll now
open the matching tab first. Existing Guide labels are unchanged.

Two layout bugs found by looking at the screen, both fixed in this step:

- **The bar filled the screen.** A `Capsule` is a flexible shape; as a `ZStack` sibling it accepted
  the whole proposed height, so the bar took most of the page. The capsule is now the
  `.background` of a fixed 62 × 36 box. The tappable frame stays 60 pt (design.md §3) — only the
  drawn pill is smaller.
- **Every page slid in from the right.** Going Settings → Sense looked like moving forward.
  Direction tracking was tried first, then dropped: pages now **cross-fade** (`.transition(.opacity)`,
  0.2 s) and never slide. A horizontal slide implies travel through an ordered set, which is not
  what a tab change means here. The capsule still slides between icons.

**Rebased onto Step 25, which renamed the button underneath it.** This work was written against
"Start demo route" while `main` moved on to "Start route to CIF" (Step 22, app line). The rebase
conflicted in exactly the three places that pin the label — `CaneKitUITests`, `CaneKitVisualTour`
and the design.md §9 table — and each took both sides: the new name *and* the tab rows. The
conversation-mode and Action Button work of Steps 23–25 touches `GuideCard`, which the Guide page
still hosts, so it needed no change. Two stale lines in `docs/CODE_REFERENCE.md` surfaced in the
merge and were corrected: the motion summary still claimed the button press was the only
animation, and the "divergence to know" note still described a 4-tab design that neither the doc
nor the code has.

**Also in this step: `make test` did not compile at all, and a `tail` hid it.** Two tests added by
the Step 25 interlock work call `DepthFrameContinuity.accepts`, which is `mutating`, directly inside
`#expect`. The macro expands its argument into a closure that captures the value immutably
(`$0.accepts($1)` → *cannot use mutating member on immutable value*), so `CaneKitLogicTests` failed
to build on Xcode 27. The six calls are now hoisted into locals before the `#expect`s, in the same
order (each call advances the anchor, so the order is the test). Note the pattern that *is* safe and
appears hundreds of times: `#expect(d.update(…) == value)` compiles fine, because a comparison
expands through a different check — only the bare-boolean form breaks. ⚠ If you add a `mutating`
call to an `#expect`, hoist it.

> **How this was nearly missed.** An earlier run of `make test | tail -8` printed a passing summary
> and exited 0 — the exit code was `tail`'s, and the head of the log held the errors. Pipe to a file
> and check the exit code, or grep for `error:`; never let `tail` be the verification.

**Verified:** `scripts/gen.sh` clean, `make test` **366/366 passed** (was: build failure), `make sim`
BUILD SUCCEEDED, app installed and launched on the booted iPhone 17 Pro Max simulator (compact bar
confirmed by screenshot after the size fix).

**Not yet run:** `make uitest` and `make tour` (AGENTS.md rule 10 wants both for a UI change) —
the simulator needs `xcrun simctl location <udid> set 40.1140,-88.2249` first or the route tests
fail for want of a fix, unrelated to the tabs. No Muse / Antigravity review of this diff yet.

**test on device:** open each tab with VoiceOver on — the three icons read "Guide" / "Sense" /
"Settings" with the selected one announced as selected; the rotor still reaches every card header
on the current page; Reduce Motion turns the cross-fade into an instant swap; the selection tick
is felt once per tab change and never during a route cue.


> **Step numbers 15, 16, 17, 21, 22 and 25 each appear twice, and that is not a mistake to "fix".**
> `feat/screwless-mount` (hardware, Windows) and `main` (iOS, Mac) numbered their steps
> independently and in parallel, then met in a merge on 2026-09-12. For 15, 16, 17, 21 and 25 the
> first of each pair is the hardware line and the second the app line. **22 is different**: both
> are app-line entries, because the route-start depth gate and the button rename were written at
> the same time on separate checkouts — the gate's own work was later finished as the app-line
> Step 25, and its heading says so. Renumbering any of them would break every commit message that
> already refers to them. Read the date and the subject, not the number.
>
> The app line has since passed the hardware line: 26 (README credits) and 27 (root tabs) are
> app-line only, so the next hardware step should take the next free number rather than 26.

## Step 26 — Team credits corrected in the README (Sat Sep 12)

The README credited the team by a role split that no longer matched who is doing what. Hardware is
**Sagar and Tommy**; the iOS app is **Aritro, Aarav and Tejas**. The docs-index line pointing at
`hardware/README.md` named Sagar alone and now names both.

Numbered 26 rather than 22 because Steps 23–25 (voice assistant, Action Button audio isolation,
camera interlock hardening) landed upstream while this was being written.

The same split is now in the other three places that named the team: the second "Who does what"
table in `hardware/README.md`, the **People** paragraph in `docs/stress_test_plan.md`, and the
per-person table in `docs/TEAM_HANDOFF.md`. The walk-day safety roles are deliberately left alone —
Aarav still walks, Sagar still spots, Aritro still films — because those are physical assignments,
not team membership, and rewriting them from a credits change would be inventing facts.

Nothing else changed — no code, no geometry, no parameter.

test on device: nothing. Documentation only.

## Step 25 — Camera interlock adversarial hardening and documentation sync (Sat Sep 12)

The full review after merging the voice-assistant work found and fixed the remaining safety/UI
edges:

- AR reconfiguration now drains the serial frame queue before taking a readiness boundary, so
  reports from the previous camera configuration cannot earn post-transition trust.
- High-frame-rate mode publishes every camera frame (60 Hz) instead of leaving an untrusted frame
  hidden behind the 30 Hz cap; the normal shipped path remains 30 Hz.
- Published-frame continuity is a pure `DepthFrameContinuity` policy with Logic tests for dropped
  reports and transition boundaries.
- `routeStartWaiting` is observable, and Guide now exposes **Cancel route start** with an explicit
  spoken/watch confirmation while depth is warming. No queued request can be stranded behind a
  disabled Stop button.
- Current docs, route labels, test counts and the OpenCane/CaneKit name split were synchronized;
  historical verification claims are marked historical rather than presented as current.
- No screenshot-tour state was added: the cancel control exists only during a LiDAR camera warm-up,
  which the no-LiDAR simulator cannot reproduce; the Guide layout remains covered by the existing
  idle tour state.

**Verification:** 366 `@Test` annotations are present. Logic sources and changed app files pass
local Swift parsing/type checking; the local Xcode 15.1 / Swift 5.9.2 toolchain cannot execute the
Swift-tools-version 6.0 package, and XcodeGen/CoreSimulator/Muse/Antigravity are unavailable in
this environment. The Xcode 27 device/simulator gates remain explicitly pending.

test on device: while a two-camera view is active, request Start route to CIF, confirm the warm-up
status and Cancel route start button, cancel once, then retry and wait for automatic start; background
the app mid-route, confirm the spoken obstacle-warning pause, resume, and verify fresh depth reports
return before obstacle cues resume; toggle 60 fps and verify the trip log shows contiguous `frame_seq` values.

## Step 24 — Audio tap Swift 6 isolation fix, Action Button PTT toggle, and session coordination (Sat Sep 12)

Fixed physical-device voice-input crash paths:

- Moved Core Audio tap installation into nonisolated relay helpers so realtime callbacks do not
  inherit MainActor isolation under Swift 6.
- Added microphone-format settling validation and reused the voice audio engine safely across PTT
  sessions.
- Made the Action Button toggle listening on/off with tactile confirmation and coordinated playback
  restoration with the optional sound watcher.

test on device: open Settings → Action Button → Shortcut → Talk to OpenCane; press Action Button,
feel the haptic tick, speak “set a post here”, then press Action Button again to submit.

Additional details: the Core Audio tap isolation, microphone format guard, audio-engine reuse, Action
Button toggle, tactile confirmation, and SoundWatcher session coordination were verified in the
physical-device build described by the upstream commit.

## Step 23 — Conversational voice assistant with Action Button trigger, marker drops, and context memory (Sat Sep 12)

Hands-free voice assistant mode designed specifically for blind white-cane users:
- **Architecture & strict audio isolation**: Built `VoiceInputEngine` using Apple's on-device `SFSpeechRecognizer` (< 300 ms response). Audio session strictly complies with AGENTS.md Hard Rule 7: transitions to `.playAndRecord` with `[.duckOthers, .allowBluetoothA2DP, .defaultToSpeaker]` (never `.allowBluetoothHFP`), capturing voice from the iPhone's upward-facing beamforming microphone while keeping AirPods Pro in 44.1/48 kHz AAC/A2DP mode. Audio session returns immediately to `.playback` and spatial beacon un-mutes upon speech completion.
- **Fast-path intent classifier (`FastPathIntentClassifier.swift`)**: Sub-millisecond, zero-token, zero-network deterministic parser handling settings (beacon, drop-offs, hazard watch, silence cane), status queries (battery, GPS accuracy, AirPods connection), route controls (stop, distance remaining), UIUC campus destinations (`CampusPlaces`), marker/post drops, and trip metrics (steps, distance walked).
- **Post & breadcrumb marker dropping (`WalkMarker`)**: Users can speak "set a post here", "mark Townsend entrance", or "drop a pin". Markers capture GPS coordinate, custom name, altitude, and timestamp, accessible both during navigation and retrospectively.
- **Rolling conversational context & anti-slop guard (`ConversationModels.swift`, `ConversationPrompt.swift`)**: 6-turn rolling memory (`ConversationHistory`) with tool execution tracking. Anti-slop prompt (< 25 words per response, zero pleasantries) and `ConversationResponseParser` with `CloudSceneGate` safety filters that strictly strip hallucinated "all clear" reassurance.
- **Hardware triggers**: Wired into the physical iPhone Action Button via `TalkToOpenCaneIntent: AppIntent` (with `requestValueDialog: "How can OpenCane help?"`), plus accessible push-to-talk in `GuideCard.swift`.
- **Speech priority hierarchy & double-speak elimination**: Spoken conversational replies are strictly `.scene` priority (lowest band, priority 3). Route instructions (`.nav`), obstacle alerts (`.obstacle`), and head-height warnings (`.head` / `.safety`) immediately interrupt any conversational reply. Actions that already announce themselves out loud (`setHapticsSilenced`, `setOption`, `stopRoute`, `navigate(to:)`) skip the coordinator's spoken repetition to prevent echoing.
- **Muse adversarial audit (rounds 1 & 2)**: Addressed all findings: (1) `cloudPrimary` routing on `VLMClient` avoiding on-device prompt drops; (2) off-main thread JPEG encoding via detached task; (3) weak `appModel` across async gaps; (4) beacon state save and restoration across voice sessions; (5) eliminated fast-path and tool double-speaking; (6) fixed sticky `.error` state and guarded stale recognition callbacks against unlistening states; (7) reentrancy guards on `handleQuery`.
- **Historical upstream verification**: 359/359 unit tests green (`make test`), simulator build clean (`make sim`), 10/10 XCUITests + visual tour green (`make uitest`). Deployed and installed on physical iPhone 17 Pro Max (`00008150-001A698C1108401C`, build sequence 2308); rerun after the current merge with Xcode 27. **Rerun done in Step 27:** the
  Logic suite needed a compile fix before it would build on Xcode 27 at all, and now reports 366/366.
- **Follow-up fixes**: cloud-primary routing, detached JPEG encoding, stale recognition callbacks,
  double-speak suppression, and query reentrancy guard.

test on device: trigger Action Button or tap the mic; say “set a post here named curb”, verify the
confirmation, ask “how is my battery”, then say “take me to CIF”.

## Step 22 — Gate route start on fresh trusted LiDAR depth (implementation precursor; superseded by Step 25 heading above) (Sat Sep 12)

Added the camera-transition interlock for route guidance:

- `CaneKitLogic.DepthReadiness` is a pure, testable state machine. It requires 3 consecutive
  same-frame reports with `.normal` AR tracking, active scene depth and the existing sweep trust
  bit; a gap over 0.5 s restarts the run and a 5 s bounded wait times out.
- `LaneReport.trackingNormal` is captured from the exact `ARFrame` in `DepthFrameProcessor`; the
  interlock does not trust the lagging `cameraDidChangeTrackingState` display string.
- `DepthEngine` owns the thin ARKit adapter, resets readiness on interruption, pause/resume and
  configuration re-runs, excludes buffered pre-transition reports with a processor sequence
  boundary, and restarts the run if the newest-only report stream skipped a frame.
- `AppModel.beginRoute` waits for serialized two-camera teardown, queues the route with a spoken
  and on-screen warm-up state, auto-starts on readiness, and fails loudly on a five-second request
  deadline (including a camera transition that never drains). Two-camera controls and self-tests
  are blocked while a route is waiting. Stop and newer destination requests cancel the pending
  start. The intentional no-LiDAR and camera-denied degraded guidance paths remain unchanged and
  explicit.

**Verification at implementation time:** 353 `@Test` cases were present; changed Logic sources pass `swiftc -typecheck` with
the local module cache. `make test` could not run in this environment because the selected Xcode is
15.1 / Swift 5.9.2 while the package requires Swift tools 6.0; simulator/device gates remain pending
on the Xcode 27 toolchain.

test on device: with the two-camera view enabled, request Start and confirm the route intro waits
for fresh depth; background/resume during that queued warm-up and confirm auto-start still requires
a new trusted-depth sequence; then background/resume an already-guiding route and confirm ARKit
recovers without stale depth; leave the camera unavailable for 5 s and confirm the spoken
"Obstacle detection is not ready" failure and no route begins.

## Step 21 — The bore rings were printed, and five things they touched were wrong (Sat Sep 12)

First physical measurement on this project. Everything below either came off the bed or was
measured against the geometry; nothing here is reasoned-only unless it says so.

**`pole_d` is 27.65 mm, settled.** The bore coupons were printed and fitted to the prototype
shaft. Ring 1 (27.75) barely went on; rings 2 and 3 went on decently, and both filament colours
agreed. `pole_d = (smallest ring that goes on) − 0.10 = 27.65` — landing exactly on the dial
caliper reading taken a day earlier by a completely unrelated method. Two independent
measurements to 0.01 mm. The rival **28.75 is retired** in `hardware/mount/cane_mount.scad` and
`test_coupons.scad` as well as the screwless folder.

One honest limit: no ring *refused* to go on, so the shaft is bounded from above (≤ 27.75) but
never hard-bounded from below. If the collet ever comes up short, reprint the rings from 27.15
before blaming the collet.

And one reading deliberately thrown away: an inside-jaw caliper measurement of a printed ring's
bore came out 27.28 mm. That is physically impossible — a rigid 4.2 mm wall cannot stretch
0.37 mm to pass a 27.65 shaft — and it is the classic chord/inside-jaw artifact. Printed bores get
measured by which gauge ring fits, never with inside jaws.

**The shaft is a broom handle.** Stated plainly because every fit number in this repo now depends
on it: the mount is being prototyped on a broom handle, not a cane. Real long canes are 9.5–13 mm
at the tip end (Ambutech's published 0.5 in / 3/8 in figures; Rodgers & Wall Emerson, *Materials
Testing in Long Cane Design*, JVIB 99(11) 2005; the WHO APS24 procurement draft says "13mm or
smaller"). Our 27.65 is roughly double anything published. Retargeting to a real cane is a 2x
change, not a tweak.

**The thread coupon jammed, and the coupon was the wrong shape to diagnose it.** The first pair
went down two turns of four and then stopped. That symptom rules out both simple explanations: not
radial clearance, because the first two turns were free; not elephant's foot on the stub, because
that binds at the *last* turn against the flange. Binding that worsens as more teeth engage points
at **axial** clearance — `thr_axial` was 0.25 mm, about one layer at 0.2.

The coupon could not tell us which, because it carried exactly **one** thread sample where the bore
row has five and the dovetail row three. A single sample can say "too tight" and never "by how
much". It is now a four-nut bracket that steps the two axes *separately* — `[0.45,0.25]` radial
only, `[0.35,0.45]` axial only, `[0.45,0.45]`, `[0.55,0.65]` — so the nut that frees it identifies
the cause. `thr_clear`/`thr_axial` in `screwless_mount.scad` are marked **PLACEHOLDER**: leaving a
value the bench has disproved sitting in the file as though it were settled is exactly what the
no-invented-specs rule forbids.

A geometric explanation was proposed and **disproved** rather than quietly dropped: the thread's
twisted extrude is faceted at 15 degrees per slice, dipping the crest 0.156 mm below true radius,
which looked like a strong candidate. Mating the two solids at eight phases through a full slice
gives **zero interference at every one**. The model is clean; the jam is a printing artifact.

**The arm can no longer be printed before the dovetail coupon.** `arm_tip_t = dt_narrow −
2·dt_clear` — added earlier the same night when the fin was narrowed to pass the socket mouth —
makes the arm's geometry depend on `dt_clear`: 42.865 / 42.656 / 42.448 cm3 at 0.15 / 0.25 / 0.35.
`pole_d` genuinely does not reach it. Four places still say otherwise (`PRINTING.md`, this file's
Step 18, `docs/todo.md`, `slice_gcode.ps1`); todo.md is corrected here, the rest are open.

**The arm's first layer had regressed to 0.30 mm2.** Same `arm_tip_t` taper: it is symmetric about
the build axis, so the fin came out a wedge balanced on a line, against 450–820 mm2 for every other
part. `assert(arm_t >= dt_wide)` did not catch it because `arm_t` is still 20 — the taper moved to
the far end. The fin now holds full width along the reach and narrows only over the last
`arm_taper` = 16 mm: bed contact **0.30 → 814 mm2**, and the arm got 3.7 cm3 lighter. Interference
with the cradle fell 2345 → 954 mm3 as a side effect.

**Four fitter-facing tables were wrong**, which is the most dangerous class of defect here — someone
reads them with parts in hand and a paint pen, and a wrong number poisons a parameter permanently.
The bore table in `coupons.scad` still listed a superseded set (27.85/28.25/28.45/28.95/29.15
against the real 27.75/28.05/28.35/28.65/28.95). The thread table described three nuts at
0.35/0.45/0.55 after the code had become four paired clearances. `coupons.scad` carried a
self-contradictory shrinkage instruction whose two halves move `pole_d` 0.36 mm in opposite
directions. And the stated print time was "~25 minutes" against a measured 52 m 53 s for the bore
row alone and 3 h 01 m for the full plate.

**Also fixed, each measured before and after:**

| | before | after |
|---|---|---|
| Collar dovetail socket axial play | 1.00 mm (void z −1→31 vs tenon z 0→30) | 0.00 |
| Zero-volume helical sheets on collar+ring | 20 (ring exported as 21 solids) | 0, both 1 solid |
| Cradle bottom wall over the charging port | 2382 mm3 solid, full 83.8 mm width | 34 mm window, 1786 mm3 |
| Thread coupon plate width | 251.11 mm on a 260 mm bed | 149.07 mm, wrapped to two rows |
| Coupon plate solids | 14 (two pairs had silently merged) | 16 |

The merged-coupon one is worth naming: wrapping the thread row to fit the bed pushed its second row
into the bore rings, and the plate rendered as 14 solids instead of 16 with no error of any kind.
Component count is now the pass/fail on every plate.

**Three bugs were introduced and caught by re-testing within the same session** — recorded because
the catching matters more than the introducing: notches placed 13 degrees apart landed inside the
nut's flutes where a thumb cannot read them (volume drop per notch 0.002/0.007/0.008 cm3 where a
constant 0.007 was due; now 36 degrees apart, at flute midpoints, constant); the swivel-test coupon
for the ball tip was geometrically impossible (a stem sized for a 27.65 shaft cannot enter a 25 mm
ball); and the plate collision above.

**Still open and blocking.** The mount cannot be assembled or trusted:

1. The cradle **slides off the arm**. There is exactly one `pawl_spring()` in the file and it is at
   the collar end; the cradle's socket is cut open at both ends and its slide axis is near-vertical
   in the walking pose.
2. The cradle's **top latch is a floating island** (0.275 cm3) — the phone has no top retention and
   the cradle exports as 2 solids. The latch riser stands in the middle of the phone's footprint and
   the phone-pocket cut severs it.
3. The **arm still passes through the phone** (4702 mm3).
4. The collar is a closed 71 mm bore and **cannot be fitted or removed without taking off the cane's
   tip or handle**.

**Reviews.** Four adversarial agents completed (CAD geometry, docs truth-audit, printability/safety,
and a verifier re-checking the docs findings); a second round of four all stalled and returned
nothing, so their ground is *not* covered. Every finding acted on above was re-verified here by
measurement first — and one of the verifier's own findings was rejected with evidence: it claimed the
"parts were printed" comments were unverifiable because five other files still say "never printed".
The rings were printed; those five files are the stale ones, and they are listed for correction.

Muse and Antigravity were **not** run — `muse`, `agy`, `make`, `xcodebuild` and `swift` are all
absent on this Windows machine. Recorded as not-done, not as passed.

test on device: nothing new on the phone. Print `coupons.scad what="next"` (11 solids, 149x178 mm,
57.32 cm3) in PLA at 0.2 mm, 4 walls, 25% gyroid, no support; take the smallest thread nut that runs
the full length freely and the dovetail that slides with thumb pressure and stays put when shaken,
then put those three numbers in the parameter block. Do not print the collar, ring, arm or cradle —
all four are blocked by the defects above.

## Step 22 — Rename primary route action to "Start route to CIF" and synchronize test contracts (Sat Sep 12)

Clarity and usability enhancement for the Townsend Hall to CIF walk:
- **Button rename**: Renamed primary route action in `GuideCard.swift` from "Start demo route" to "Start route to CIF", clarifying that it is the live, pre-surveyed route from Townsend Hall (dorm) to CIF rather than a simulation.
- **Siri App Shortcut**: Added "Start route to CIF in OpenCane" to `AppShortcutsProvider` in `AppIntents.swift` while retaining legacy phrases for backwards compatibility.
- **Contract & documentation sync**: Updated test contracts across `AGENTS.md` (Rule 9), `docs/CODE_REFERENCE.md`, `docs/design.md`, `CaneKitUITests.swift`, and `CaneKitVisualTour.swift`.
- **Adversarial review with Muse**: Muse confirmed 1:1 label pairing, accessibility contract preservation, strict concurrency invariance, and clean naming split.
- **Verification**: 348/348 unit tests pass (`make test`), simulator build clean (`make sim`), 10/10 UITests pass (`make uitest`), and deployed to physical iPhone 17 Pro Max (`00008150-001A698C1108401C`).

test on device: open app, verify button reads 'Start route to CIF', tap to start route from Townsend Hall.

## Step 21 — Bolt: Decouple 30 Hz depth stream from ContentView root to prevent full-screen SwiftUI re-renders (Sat Sep 12)

Performance optimization addressing root-level SwiftUI Observation invalidation:
- **Observation root decoupling**: In iOS 26 / Swift 6 `@Observable`, referencing high-frequency sensor streams (`model.depth.report` at 15–30 Hz, `model.depth.fps`, and `cameraTiltDownDeg`) directly in `ContentView.body` caused the entire root scroll view and all 9 navigation/status/settings cards to invalidate and re-evaluate on every LiDAR depth frame.
- **Leaf isolation pattern**: Extracted `ObstaclesCard` and `MountAimRow` leaf subviews inside `ContentView.swift`. Kept `LaneGridView(report:)` pure and testable while ensuring observation tracking of `model.depth.report` is scoped strictly to `ObstaclesCard` and `MountAimRow`. Also hoisted `laneNames` array in `LaneGridView` to a static constant to avoid heap allocations per render.
- **Impact**: Eliminates ~97% of unnecessary root `ContentView.body` evaluations during active walking with LiDAR (reducing CPU cycles and thermal throttling during prolonged use).
- **Adversarial review with Muse**: Muse confirmed decoupling direction, verified concurrency and display logic invariance, and recommended the pure leaf wrapper pattern over environment fallback inside `LaneGridView`.
- **Verification**: 348/348 unit tests pass (`make test`), simulator build clean (`make sim`), 10/10 UITests pass (`make uitest`), and clean GPS e2e replay (989 m, 9/9 waypoints).

test on device: verify Obstacles card and Mount aim row update smoothly with cane in hand, check phone thermal status during 5-minute continuous walk.
## Step 20 — Passed-by slow approach fix, Live Activity overlap prevention, and Watch keep-alive guard (Sat Sep 12)

Full codebase stress test and multi-agent audit across LiDAR depth, cameras, navigation logic, watch connectivity, audio, speech, and hardware:
- **Passed-by receding fixes reset on slow approach**: In `GeofenceTracker.update`, walking toward an intermediate waypoint at < 1 m/s (step < 1 m) meant `d > last - 1` evaluated true, accumulating false receding fixes before reaching closest approach. Now explicitly resets `recedingFixes = 0` whenever `d <= minDistance`. Added `@Test func passedByResetsRecedingStreakDuringSlowApproach()` in `GeoMathTests.swift`.
- **Live Activity dismissal policy**: `LiveActivityController.end(final:immediate:)` now supports an `immediate: Bool = false` dismissal policy (`.immediate` vs `.after(.now + 60)`). `start()` and `AppModel.endRouteQuietly()` invoke `end(immediate: true)`, preventing stacked/overlapping stale Live Activities on the lock screen during rapid route restarts.
- **Watch keep-alive guard**: Guarded `!text.hasPrefix("No route")` in `WatchModel.updateKeepAlive` to ensure "No route running." status lines do not spuriously trigger workout keep-alives while idle.
- **LiDAR multi-cam architecture audit**: Researched and audited user query regarding front selfie camera + back camera + LiDAR depth. Verified hardware probe on iPhone 17 Pro Max confirms 12 multi-cam sets pair the front camera with rear LiDAR depth at 320×240 (AVFoundation). Documented why ARKit's single-camera architecture (`ARFrame.capturedImage`) pauses in dual-cam mode and what an AVFoundation-based pipeline would require (replacing ARKit, manual gravity via CoreMotion, lens undistortion, loss of classified mesh).
- **Demo route guidance for Townsend Hall (dorm) to CIF**: Clarified that "Start demo route" (`route_isr_cif.json`) is specifically the pre-surveyed, pre-cached Townsend Hall to CIF route with tested curb gates and turn settling. Kept "Start demo route" and pinned accessibility label.
- **AirPods Pro & Apple Watch necessity**: Clarified why AirPods Pro (spatial audio HRTF beacon, head yaw tracking, Transparency mode) and Apple Watch (wrist haptic taps, remote controls without cane phone access) remain essential for the blindfolded demo walk.
- **Verification**: 348/348 Logic tests pass, `make sim` clean, 10/10 XCUITest / visual tour passed, `make e2e` clean scenario passed (989 m, 9/9 waypoints in order, 0 veer errors).

test on device: start demo route, lock phone to check single Live Activity on Lock Screen; verify 3 detents on Watch crown advances waypoint; verify Townsend Hall -> CIF route navigation.

## Step 19 — The collar had no thread on it (Sat Sep 12, overnight)

Three adversarial sub-agent reviews were run over `hardware/mount_screwless/` before
committing the sliced plate to a printer. Every load-bearing finding was verified here
by measurement before it was acted on, because the first pass of my own verification was
wrong (see "a wrong measurement" below). Six defects fixed; each one re-measured after.

**`thread()` never produced a thread.** This is the headline and it invalidated the
entire clamp — the mechanism the whole design is built around.

`linear_extrude(twist=)` maps **angle** to height, not distance. At `thr_pitch = 3` the
twist rate is 360/3 = **120°/mm**. The tooth was drawn as a linear offset in y, so a
tooth `y` mm "tall" came out `atan(y/r)/120` mm thick — about **0.031 mm**, a fifth of a
layer. The collar's threaded band sliced as a plain smooth cylinder. The ring would have
slid straight off.

The tooth is now drawn as an angular **sector**, via `thr_ang(axial_mm) = axial_mm *
360 / thr_pitch`, with `thr_duty` / `thr_crest` / `thr_axial` expressed as fractions of
the pitch in the parameter block and three asserts that catch a tooth wider than half a
turn, an inverted flank, and no room left between turns. Measured on the rendered
collar by sectioning at five heights: **0.616–0.747 mm**. `coupons.scad` carried a
hand-copied duplicate of the same bug and got the same rewrite.

The other five:

| Fix | Before | After |
|---|---|---|
| Thread tooth, axial thickness | 0.031 mm | **0.616–0.747 mm** |
| Arm first-layer bed contact | 42 mm² (Creality's own figure) | **1627.4 mm²** |
| Material blocking the cradle's dovetail slide | 986.57 mm³ | **0.00 mm³** |
| Cradle overhanging the phone's front face | 0.02 mm³ | **514.99 mm³** |

- **`collet_nut()` cancelled its own squeeze.** It applied `thr_clear` to the cone as
  well as the thread, so the ring closed the collet by ~0.04 mm instead of the intended
  amount. The nut's internal cone must share the collar cone's **taper rate**, not its
  end radii — `ring_cone_lo/hi` and `lock_cone_lo/hi` are now derived that way, with
  `collet_squeeze = 0.80` and `ball_squeeze = 0.60` as the stated closures, and asserts
  that the squeeze exceeds the clearance it has to take up first.
- **The cradle's phone cut removed every retention feature.** `phone_block`'s default
  runs 10 mm past the phone's front face, and the side lips, the corner cups' lips and
  the whole top latch live in exactly that 10 mm. The cut now stops at the front face.
- **The latch hook was buried inside the phone.** It sat at `phone_d - back_t`, i.e.
  3.2 mm *inside* the phone, gripping nothing. It sits on the front face now.
- **The cradle's dovetail socket was a blind pocket**, so the arm could not slide in at
  all. Opened through.
- **`arm_t` 10.0 → 20.0.** At 10 mm the arm stood balanced on its two dovetail edges:
  42 mm² of bed contact. It would have been knocked off the plate. Asserted against
  `dt_wide` so it cannot regress.

All six parts re-render `Status: NoError` with every assert passing;
`part = "assembly"` echoes a 13.15 mm phone-to-shaft gap.

**`coupons.scad`'s selection formula contradicted its own criterion.** It said
`pole_d = bore − 0.35` while describing a ring that "goes on with firm thumb pressure",
which is 0.05–0.15 mm of clearance, not 0.35. For a collet, ~0.25 mm is the difference
between gripping the cane and never reaching it. Corrected to **−0.10**, and the note
now says plainly that `bore_clear` is *not* an output of this test — the rings are
rigid, the collar is a collet that closes, so clearance is a design decision and
`collet_squeeze` takes it up.

The bore set was also rebuilt: **27.75 / 28.05 / 28.35 / 28.65 / 28.95** in even 0.30
steps, replacing 27.85 / 28.25 / 28.45 / 28.95 / 29.15. The old set *started above* the
27.65 caliper reading, so if the caliper was right the smallest ring still fitted and
the test had no lower bracket — it could only contradict itself. It also put 28.65 and
28.75 inside one 0.50 mm gap.

**A wrong measurement, recorded because it nearly cleared a real bug.** My first check
of the thread filtered the collar's cross-section by `r > 17.10` and found healthy 66°
runs. Those were the dovetail pad, which sits at azimuth 0 and reaches past r = 22.
Restricting to azimuths 80–280° isolated the real thread crossing at 3.77–7.48°, i.e.
0.031–0.062 mm, and confirmed the agent was right. A filter that accidentally selects a
different feature reads as a pass.

**Headless slicing.** `scripts/slice_gcode.ps1` drives Creality Print 7.2 from the
command line — it is an Orca fork and takes Orca's arguments — so slicing is
reproducible and needs no GUI. It re-opens every file it writes and echoes the material,
both temperatures, walls, time and weight, and **refuses to name a file safe if it
cannot read the material back out**. That guard exists because a PETG plate was very
nearly sent to a machine holding four PLA spools: `START_PRINT EXTRUDER_TEMP=250
BED_TEMP=80` is substituted at *slice* time and cannot be corrected at the printer.
Two Windows traps are documented in the script: the Creality exe needs
`2>&1 | Out-String` *and* a relaxed `$ErrorActionPreference` or it silently writes
nothing, which is the exact opposite of `build_stl.ps1`'s OpenSCAD rule.

New `hardware/mount_screwless/PRINTING.md` is the operator runbook: material → slot →
temperature, print order, how to read each coupon, and what the coupons do not settle.

**Not done, and not claimed:** Muse and Antigravity are both absent from this Windows
machine (`muse`, `agy`, `make`, `xcodebuild` and `swift` all resolve to nothing), so the
diff has had the multi-agent review the engineering bar asks for but **not** the Muse or
Antigravity passes. No iOS source changed in this step, so no Logic tests were affected.
Run both on a Mac before this merges to `main`.

**Still open** (found by review, not yet fixed): the pawl release window is ~79% blocked
by the arm, so there may be no way to press the catch; no lead-in ramp on the pawl
catch; `socket_part()`'s "flare" is a flat 90° ledge; the button windows overrun the top
of both side walls; `dt_clear` gives 0.325 mm at the mouth and 0.139 mm buried instead
of a uniform 0.25; the ball-socket fingers at ~7–9% strain will crack. All are in
`docs/todo.md`.

test on device: nothing printed yet at time of writing. Print the bore rings first
(`-Plate bore -Material PLA -Walls 4`, 52m53s), read `pole_d` off them, then the thread
coupon — if the ring will not thread onto the stub, do not print the collar. The arm can
go on any free machine now; it depends on neither `pole_d` nor `dt_clear`.

## Step 18 — Sliced on the SPARKX i7 (Sat Sep 12)

All six mount parts on one plate, sliced clean in Creality Print 7.2 against
`0.20mm Standard @SPARKX i7 0.4 nozzle`: **4 h 31 min, 101.94 g, 34.18 m**. Project saved
as `hardware/mount_screwless/opencane_mount_plate.3mf` (gitignored).

Support is **on, build-plate-only**. That combination is deliberate. The cradle stands on
its dovetail block and needs support under the back plate; the socket's ball cavity must
NOT be supported, because support inside the cup cannot be got out through a 17 mm mouth.
Build-plate-only draws the first and skips the second, because support for the cavity
would have to stand on the model. Support is 6.8% of print time, interface another 3.2%.

**Do not use auto-arrange on this plate.** It packs the parts tight enough that Creality
Print reports gcode path conflicts (lock↔arm at z=2.75, then ring↔cradle at z=5.20).
Explicit positions that slice clean, X/Y mm: cradle (65, 150), collar (150, 200),
ring (150, 140), lock (215, 140), socket (215, 200), arm (70, 42).

**Diameter call: 27.65 mm is self-consistent and the collet has margin, but it is a
one-way bet.** Bore is 28.05 mm (27.65 + 0.40). On a 27.65 shaft the collet closes a
0.20 mm radial gap; the cone sheds 0.13 mm of radius per mm of ring travel, so that is
1.5 mm of travel — half a turn of a 3 mm pitch — against 17 mm of cone engagement. Huge
margin. But 28.05 is SMALLER than both competing figures (28.65, 28.75), so if the caliper
is wrong the collar does not grip loosely, it does not go on at all. Coupons first.

While checking that, found `grip_ribs` are **grooves, not ribs** — the cylinders are
subtracted, scalloping eight ~0.3 mm dishes out of the bore. The behaviour is right (eight
narrow lands grip harder than a full bore) but the names and comments said the opposite.
Comments fixed; no geometry changed, so the sliced plate still stands.

test on device: nothing printed yet. Coupon plate first, then this one.

## Step 17 — The assembly preview earned its keep (Fri Sep 11)

Built the full `part = "assembly"` preview — ghost cane, ghost phone, and a red ray down
the rear camera's optical axis — because the previous preview drew only the collar, ring
and arm, and everything it left out was broken. Four faults, all found by looking:

- **Both dovetail sockets were on the wrong axis.** `rotate([0,-90,0])` put the slide
  along the radius instead of along the cane, so the joint resisted nothing the phone
  actually does to it. Now `rotate([0,0,90])` everywhere, one orientation, arm drawn in
  the collar's own frame so `assembly()` is a single translate you can check by eye.
- **The collar's pad was shorter than the dovetail it holds.** `base_len` was 9 mm
  against a 30 mm slide, so the socket cut clean through the pad. `base_len` is 36 mm
  and there are asserts on it, on `pad_w` and on `pad_t`.
- **The arm's cradle end hung off nothing.** The fin tapered to 15 mm deep under a 30 mm
  tenon. The fin is now one hull from the collar face to the cradle face.
- **The phone's bottom corner cleared the shaft by 1.1 mm.** `arm_angle` rakes the phone
  back toward the cane, which `arm_reach = 46` (inherited from the screwed mount, whose
  geometry differs) did not account for. `arm_reach` is 58 mm, gap is **13.1 mm**, and
  `tip_clear` asserts it and echoes it on every render.

Also fixed the camera's direction, which was mirrored — it looked at the shaft. The frame
now matches `mount/cane_mount.scad` lines 26–35: screen toward the walker, camera forward
past the open top of the cradle, `arm_angle + cane_angle - 90` = 5° below the horizon.

**The cradle needs support.** It stands on its dovetail block with the back plate 7 mm
off the bed. Added a 45° flare that carries the plate for 7 mm all round; the rest needs
"support on build plate only". The header's blanket no-support claim was wrong and now
says so per part. Every other part is still support-free.

All seven printables still render `NoError`.

test on device: nothing yet — none of this has been printed. Print `coupons` first.

## Step 16 — Cane diameter disputed, clamped ball joint, SPARKX i7 (Fri Sep 11)

**The cane is 27.65 mm, not 28.75.** Dial caliper, Sagar. That contradicts
`hardware/mount/cane_mount.scad`, the hardware brief, and the 1.128 in (28.65 mm) quoted
earlier the same evening. The spread is 1.1 mm — three times any sane bore clearance, so
a collar bored for 28.75 would spin freely on a 27.65 shaft. `mount_screwless/` now uses
27.65 and the bore coupons were changed from *clearances* to *absolute bore diameters*
(27.85 / 28.25 / 28.45 / 28.95 / 29.15, 1–5 notches) so one 20-minute print settles it
against the real cane instead of against anyone's memory. **`hardware/mount/` is still
modelled at 28.75 — one of the two folders is wrong.** Whoever prints first, record the
answer here.

**Clamped ball joint, `joint = "ball"`.** Sagar asked for a gyroscopic / ball-socket aim.
Both the hardware brief and `mount/DESIGN.md` rejected ball joints on purpose — "ball
joints slip under sweep vibration and break the Point-to-Identify calibration" — so this
is not a free ball. It is the cane collar's collet trick at small scale: a slotted socket
cup squeezed onto the ball by a threaded lock ring, so holding force comes from a wedge
you tighten rather than from how snugly it printed. That answers the recorded objection
without deleting it: an undertightened clamp still slips, and now in two axes. The
fixed-angle dovetail arm stays the default and the safe demo part. T7 (shake) decides.
Two new parts, `socket` and `lock`, still zero bought hardware. The collar's ring and the
ball's lock ring are now one `collet_nut()` module, so a thread-fit fix lands in both.

**Printer is the Creality SPARKX i7** (260 × 260 × 255, 0.4 hardened nozzle, Klipper, on
the network at 172.23.209.71:4408, profile `0.20mm Standard @SPARKX i7 0.4 nozzle`).
Largest part is the coupon plate at 174 × 195 mm, so everything lies flat with room.
Print single-colour — it is a multi-material machine and the purge would waste more PETG
than the parts use.

**Not done:** still never printed, never fitted, never walked. The ball socket's grip is
reasoning about a wedge, not a measurement. No rain hood.

test on device: n/a (no app change). On the printer: bore coupons first — they decide
whether 27.65 or 28.75 is right, and everything else waits on that.

## Step 15 — Screwless phone mount, Windows CAD toolchain (Fri Sep 11)

Hardware side, on Sagar's Windows machine. Nothing here touches the app.

**Why another mount.** `hardware/mount/` needs four M4 screws, four M4 brass heat-set inserts, an
M5 bolt and nyloc, two M3 countersunk screws, two M3 inserts, two nylon screws and two nylon nuts,
plus a soldering iron with a heat-set tip. On the night before the build none of that was confirmed
to be in the building, and heat-set inserts are the one item no hardware store in Champaign stocks.
`hardware/mount_screwless/` does the same job with four printed parts and nothing else. It is an
alternative, not a replacement — whichever gets fitted, say which in this file.

**Clamp is a collet**, not a snap fit and not a printed bolt across a C-clamp. The collar's nose is
a slotted cone; the ring screws down over it and squeezes the slots onto the cane, like a drill
chuck. Clamping force comes from a wedge, so sweep vibration cannot walk it loose, and both thread
helices run along the print Z axis — the only orientation a printed thread is reliable in. A printed
bolt across the split would have put the thread axis horizontal, where it prints as stacked overhangs.

**Modularity is the pitch.** collar (cane interface) | arm (angle interface) | cradle (phone
interface), all meeting at one sliding dovetail that runs along the cane axis, so the phone's weight
loads every joint in shear across its widest face instead of trying to peel it open. Different cane,
different pose or different phone each reprint exactly one part. `arm_angle` stays derived as
`90 - cane_angle + cam_down`, so the 3–8° camera requirement is inherited, not re-litigated.

**Toolchain.** OpenSCAD 2021.01 (the winget release, `OpenSCAD.OpenSCAD`) has no Manifold backend
and renders the threaded collar in **6 min 52 s**. The 2025.09.15 portable snapshot renders it in
**0.3 s**. `scripts/build_stl.ps1` prefers a snapshot in `%USERPROFILE%\Tools\` and warns loudly
when it falls back. Two Windows PowerShell 5.1 traps are commented in that script because both fail
silently: 5.1 strips the quotes from `-D part="collar"` so OpenSCAD renders an empty file, and a
local `$png` clobbers the `-Png` switch parameter because variables are case-insensitive.

**Coupons carry notches, not numbers.** `text()` needs fontconfig, which the portable Windows
snapshot does not ship; it renders as nothing at all, silently, leaving four identical unlabelled
bore rings. Count notches instead — which also reads by thumb.

**`.gitignore` now covers `stl/`, `*.stl`, `*.3mf`, `*.gcode`.** It did not before, and the
hardware brief wrongly claimed it did.

**Not done:** never printed, never fitted, never walked. Every clearance in the file is a guess
until the coupons come off the bed. No rain hood. The pawl spring thickness is untested and may be
too stiff to click or too thin to survive.

test on device: n/a (no app change). On the printer: coupons `what="bore"` first, set `bore_clear`,
then thread and dovetail coupons, then collar + ring, then arm + cradle.
## Step 17 — App icon (Sat Sep 12, on phone and launched)

Both `AppIcon` sets were empty — the app shipped with no icon. v1 ("Folded Signal", from
`/tmp/icon.py`) was abstract bars; v2 ("White Cane") is a real mobility cane on the navy
field: black grip, gold joint ring, white shaft with two red wraps, red tip leaning
lower-right, faint gold signal arcs. Generator committed as `ios/scripts/appicon.py`
(`python3 ios/scripts/appicon.py` rewrites both 1024 PNGs).

Review: `agy` cannot run in this sandbox (needs localhost bind + log writes), so the user
ran it in their own terminal against a `/tmp` copy. It found 3 real defects, all fixed and
re-verified: (1) red wrap bands clipped flush — strip had no vertical padding so
`alpha_composite` cut the proud 8 px + rounded corners; (2) drop shadow hard-edged — the
blur clamped at the unpadded layer bounds; (3) stale "top-left" comment on the top-right
arcs. Fixes: `PAD` strip padding, `SPAD`-padded shadow layer. My own numeric review before
that caught the v2 tip on the mask boundary (fixed by the 0.88 scale). Final probe: zero
content pixels in the mask cut zone; masked 180 px + 60 px renders confirm tip intact and
cane legible. agy also confirmed asset wiring (both sets, RGB, no alpha) and squircle safety.

test on device: OpenCane icon on the Home Screen after install; red tip intact inside the
squircle at small sizes (check a folder view too).

Installed 2026-09-12 ~01:25 via `make run` (build + `actool` icon compile + devicectl install
all green, incl. the 10 Siri phrases training under the OpenCane name). Auto-launch refused:
phone was locked — unlock and tap the icon by hand.

Re-installed ~01:45 with the v3 icon (`AppIcon60x60@2x.png` emplaced in the build log):
**BUILD SUCCEEDED**, devicectl install green, and `device process launch` succeeded (phone
unlocked). White Cane icon live on the Home Screen.

## Step 16 — Emergency sirens + hands-free integrated (Sat Sep 12, uncommitted)

Both worktrees are now in the main checkout, hand-merged so nothing the renames and fixes
built since is lost:
- Emergency (`cane-wt-emergency`): siren gate 0.50 → 0.60 with three agreeing windows,
  `.emergency` urgency → `.nav` band (never `.safety`), `best(of:)` so traffic noise cannot
  shadow a siren, `speechTTL` per kind. `SoundAlerts.swift` + `SoundAlertsTests.swift` copied
  verbatim (main never touched them); `SoundWatcher` + `AppModel` merged keeping every OpenCane
  rename. Verified: API fully additive (`labels`, `candidateLabels`, `kind(for:)` retained;
  `SensorProbe` only uses `candidateLabels`), `best(of:)` fallback preserves the policy's
  below-gate reset, no force-unwraps, `.nav` exists on `SpeechPriority`.
- Hands-free (`cane-wt-handsfree`): Status / Ask / Silence-haptics shortcuts (list now 10/10),
  `HandsFreeIntents.swift` + `QuestionPrompt` / `StatusSummary` + tests + `docs/handsfree.md`
  copied; `AppIntents` shortcuts block, `VLMClient.cloudPrimary` contract, `SceneDescriber`
  question path and the `describe_result` question field merged. Two corrections while merging:
  spoken strings say OpenCane (the branch predates the rename), and main's newer 18/25 s cloud
  timeouts kept over the branch's 8/12 s. Verified: all four `AppModel` methods the intents call
  exist (as an extension in the intents file), every member they touch exists, sources are globs
  so no `project.yml` change needed. A 4-agent verification wave over the integrated tree
  confirmed all contracts with file:line evidence.
- Deliberately NOT merged as branches (the work is uncommitted in the worktrees); this is the
  merge, done by hand with the rename applied. Commit after the gate, then merge the branches
  only to retire them.

test on device: siren needs ~1.5 s of continuous siren before "Siren. Do not start crossing.";
horns stay passive; "How is OpenCane doing" answers in the fixed six-clause order; "Ask OpenCane
about the scene" answers the question asked, never a generic description.

### Antigravity review of Step 16 (7 findings — 4 fixed, 1 instrumented, 2 rejected with evidence)

1. **Siren expired unheard behind crossing lines — FIXED, real.** 5 s assumed a siren queues
   behind "at most the route line already playing". Wrong: `.nav` queues FIFO behind any `.nav`
   line (crossing 4–8 s, lock warning 10 s, location-denied 20 s) and the queue purges expired
   lines on line end (`SpeechQueue` header). Siren `speechTTL` 5 → 15 (= repeat interval) with
   the test rewritten to pin both bounds.
2. **Siren blocked by long `.nav` lines — same fix; pre-empting obstacle NAMES — REJECTED.**
   Haptic warnings never pass through speech: the cane keeps buzzing under any announcement, so
   nothing safety-critical is delayed. Names resume (interrupted lines re-queue).
3. **Siri invocation may kill the mic permanently — INSTRUMENTED, unproven.** `SoundWatcher` had
   no interruption observer (confirmed by reading the file). No lifecycle change without device
   proof; added a log-only `interruption_began/ended` observer so the trip log can correlate the
   next death. Repro: sirens on → "Ask OpenCane about the scene" → check switch + log.
4. **"SetOption announces on before async validation" — FIXED the overclaim, real.** The
   read-back is synchronous; the 0.25 s format settle can refuse after. Comment now states that;
   behavior kept (the failure line corrects within ~a second).
5. **Silence confirmation delays spoken cues 3–4 s — ACCEPTED as residual, overstated.**
   `SpeechQueue` queues (not suppresses); only a cue arriving in that window AND expiring (4 s
   TTL) is lost, and only when the user just silenced haptics with no watch. `handsfree.md` now
   says to stand still for a few seconds after.
6. **Ask answers go stale while walking — ACCEPTED, bounded.** Question-path answer TTL 20 →
   10 (plain Where-Am-I keeps 20: that walker stands still). Cloud-wait staleness remains;
   bounded by the 18/25 s session budget and auditable via `ms` + `frame` in `describe_result`.
7. **No-cloud downgrade "violates" the ask contract — REJECTED.** The downgrade is announced out
   loud ("needs the cloud model... Describing instead.") and the original question is preserved
   in `lastQuestion` + the trip log. No silent substitution; the contract bans silent ones.

## Step 15 — Front-inset tilt, second attempt (Sat Sep 12, compiled + installed)

The front inset of the both-cameras view still came out tilted with the back feed fine, after the
first fix (0f32282) asked `RotationCoordinator` for `videoRotationAngleForHorizonLevelPreview`.
That connection feeds a video *data output* — a capture connection — and the preview angle follows
the interface orientation while the capture angle follows the horizon, which accounts for exactly a
90° disagreement on a phone clamped to a cane. `connect()` now prefers
`videoRotationAngleForHorizonLevelCapture`, falls back to the preview angle, then to a
per-position portrait default (front 270, back 90) instead of a blind 90, and records the applied
angle per camera. `diagnostics` gains `front_rotation` / `back_rotation` (logged in the
`both_cameras` start record; `-1` = that camera never connected), so the next device run says
whether the coordinator or the fallback is to blame with no further guess-runs. `CODE_REFERENCE.md`
gains the missing `DualCameraSession` section in the same change. Follow-up the same morning:
the upright front inset read backwards (mirrored) — the inset now sets `isVideoMirrored = false`
so it agrees with the back feed on left/right, and logs `front_mirrored` beside the angles.

Reviewed but deliberately **not** merged tonight: the emergency-siren rework
(`cane-wt-emergency`: siren gate 0.50 → 0.60, three agreeing windows, `.emergency` urgency → `.nav`
band, `best(of:)` so traffic noise cannot shadow a siren) and hands-free voice control
(`cane-wt-handsfree`: Status / Ask / Silence-haptics shortcuts taking the list to the 10-shortcut
limit, `QuestionPrompt` / `StatusSummary` in Logic with tests). Both were read end to end: the
siren `best(of:)` fallback path preserves the policy's below-gate reset semantics and introduces no
force-unwrap or crash path, and the Hazards-toggle crash itself is already fixed on main
(`fix/launch-crash` + `fix/sound-watch-hardening`). They stay unmerged because the merge gate needs
`make test` / `make sim` / `make uitest` / `make e2e` green and none of those can run from this
sandboxed session — merging untested the night before the demo would break the gate that protects
the walker.

test on device: turn on Both cameras with the phone clamped in portrait; front inset upright and
mirrored, back feed upright; trip log `both_cameras` start record reads `front_rotation: 270,
back_rotation: 90` with both frame counts climbing. Then run the gate in your own terminal
(`cd ios && make test`, `make sim`, `make uitest`, `make e2e`) before merging anything.

## Step 14 — The night before: what was broken and what is new (Fri Sep 11, simulator only)

Everything below is verified by 303 CaneKitLogic tests, a clean Swift 6 strict build and a green
`make uitest`. The phone left the building partway through, so **the device column is honest: much
of this has never run on hardware.** See the WHERE WE ARE block in docs/todo.md.

### Found broken, fixed

- **The Live Activity has never existed in any installed build.** `scripts/gen.sh` worked around
  XcodeGen issue #1613 with an unanchored `sed` that rewrote *every* copy-files phase from
  `dstSubfolderSpec` 13 to 16. XcodeGen already emits 16 for the watch, so the substitution's only
  live effect was moving the **widget's** embed phase out of `PlugIns/` — and a widget outside
  PlugIns is never loaded, so `Activity.request` failed and the error was swallowed into
  `lastError`. No crash, no log, just no Dynamic Island, while the docs promised one. Confirmed
  before the fix: zero `dstSubfolderSpec = 13` in the pbxproj and no `PlugIns/` inside
  `CaneKit.app`, with `CaneKitWidget.appex` sitting loose beside it. The patch now touches only the
  phase whose `dstPath` is the Watch folder, and `gen.sh` **asserts both phases afterwards** rather
  than hoping — a widget in the wrong folder produces no error at build or run time, which is
  exactly why this survived so long.
- **Muse Spark could not answer at all.** With the key wired, the trip log showed
  `provider: "Muse + On-device"`, `ms: 11066`, and a spoken line that was the on-device LiDAR
  template. `max_tokens` was 120, which one sentence needs — but on that endpoint the budget covers
  **reasoning plus visible output**, and the model spent it thinking and returned `content: null`.
  An empty reply reads as a failure, so the app fell back, silently, after blowing the 8 s timeout.
  A direct probe with `max_tokens: 10` reproduced it in miniature: `finish_reason: "length"`,
  `content: null`, `reasoning_tokens: 7`. Now 1024 tokens and `reasoning_effort: "low"` (Meta's own
  guidance for direct-answer tasks; `"none"` is a documented HTTP 400 on Muse Spark). The field is
  omitted for any other OpenAI-compatible endpoint, because a non-reasoning chat model rejects it.
- **The cloud scene sentence was spoken ungated.** `SceneVocabulary.isFaithful` ran only on the
  on-device path. Measured hallucination classes now refused: street names Vision never read on this
  route's own frames ("S Grand Blvd"), distances that contradict LiDAR, counts (models measure ~53 %
  there), clock-face directions — and, worst, a false all-clear: handed a solid white frame a model
  said *"The path ahead is clear and unobstructed"* four times out of four. Telling a blind walker
  the path is clear when the lens is covered is the worst failure this app has.
- **The voice alternated between Bella and Apple's, line to line.** Warnings never wait for the
  network, so an `.obstacle` / `.safety` cache miss is spoken by AVSpeechSynthesizer at once, while
  nav and scene lines — prefetched per route — played as Bella. `commonLines` only prefetched
  *fixed* strings and warning lines are generated. `SpokenPhrases` now enumerates the whole finite
  warning phrase space and the launch prefetch warms it: **74 lines, 1,722 characters, 17.2 % of the
  monthly free tier**, paid once because every line is cached on disk forever. The safety rule is
  untouched — the cache simply already has the line.
- **VoiceOver read the words on screen instead of the sentence we wrote.** A suggestion row's
  accessibility modifiers sat on the `Button` rather than on its label, so `children: .ignore`
  applied outside it left the composed children exposed: "Grainger Engineering Library, On campus,
  Campus". Both labels were observed on the same row in one test run, which is what made the test
  flaky. (The second "failing" test was not a bug at all — it was simulator contention from a
  concurrent `make e2e`, which also produced a bogus "harness error: No such file or directory".)
- **Tapping Go with an empty box said nothing** — it only drew the error. The person most likely to
  do that is the one who cannot see the box is empty.
- **A self-test paused ARKit for ~13 s at launch**, so pressing "Where am I" in that window answered
  "Camera warming up. Try again." and looked like a broken app. The self-tests are debug buttons now.

### New, all off by default

- **"Both cameras (pauses obstacle detection)"** — the front and back camera on screen at once via
  `AVCaptureMultiCamSession`, with ARKit explicitly paused. ARKit can never deliver both pictures;
  Apple DTS, developer forums 677731: *"There can only be one running capture session at a time,
  ARKit requires a running capture session, and there is no ARConfiguration that will enable you to
  receive both the front and rear camera image, so the functionality that you are looking for is not
  possible."* `ARFrame` structurally has one `capturedImage`. Pausing ARKit is therefore the only
  design. Announced out loud both ways, refused while a route is guiding, torn down on backgrounding.
  **No `AVCaptureVideoPreviewLayer`**: forums 742501 reports LiDAR depth going unreliable once a
  preview layer joins a session producing depth, and depth is the safety channel.
- **"Head tracking without AirPods"** — `userFaceTrackingEnabled` → `ARFaceAnchor` yaw as a second
  source for the beacon and Recenter. This is what lets the beacon work for someone who has only the
  phone, which is the point.
- **"Listen for sirens and horns"** — SoundAnalysis over the microphone, the one feature that leaves
  `.playback`. It never requests HFP, compares the **output route** before and after, and reverts —
  refusing itself — on any change. Measured with no headphones: output stayed `Speaker`, restore
  worked. **The AirPods case is unmeasured**, which is precisely why the revert exists.
- **People and animals named with measured distances** — `DetectHumanRectanglesRequest` and
  `RecognizeAnimalsRequest`, different models from the 1,303-class classifier that returned *zero*
  usable labels on the phone. Distances come from a LiDAR grid read inside each detection's own
  bounding box; outside 0.3–5 m the walker hears the direction with **no** distance rather than a
  made-up one.

test on device: **most of this has not run on hardware.** In priority order: the Dynamic Island now
that the widget is actually embedded; "Where am I" with the Muse key (expect `provider: Muse`, `ms`
well under 8000, and a sentence naming what is really there); that every warning comes out in Bella's
voice; people named with plausible distances; and only then the two-camera mode, whose render path
was rewritten after its only device run and has never been seen to draw.

## Step 13 — Voice control, live camera view, natural voice, nearest-result search (Fri Sep 11, on device)

Everything in this step was driven by the phone itself, not the simulator.

**Voice control (a blind walker cannot use the Guide card).** Seven App Shortcuts — of the ten an app
may register — in `AppIntents.swift`: Where am I · Take me to *\<place\>* · Navigate to CIF from here ·
Start the demo route · Repeat the last instruction · Next waypoint · Stop the route. Each forwards to
one `AppModel` method, so Siri, the Action button, the watch and the on-screen buttons all share one
code path. All are `.foreground(.immediate)` because ARKit obstacle warnings only run frontmost:
guidance must never start silently in the background. App Shortcut phrases cannot interpolate a
`String` (Apple allows only an `AppEnum`/`AppEntity`), so the phrase form carries the seven gazetteer
places as a `CampusDestination` AppEnum and any other destination goes through "Take me somewhere in
CaneKit", where Siri asks for the free text. Verified from the built
`CaneKit.app/Metadata.appintents/extract.actionsdata`: 7 shortcuts, 21 phrase templates.

**"Navigate to CIF from here."** MKDirections walking from the live fix to `route_isr_cif.json`'s last
waypoint as a bare coordinate — no search, so MapKit cannot pick a different "CIF".

**Destination search was bad.** `CampusPlaces` (CIF, ISR, Grainger, Illini Union, Siebel, Main Library,
ARC → entrance coordinates) is now consulted *before* MapKit, because MKLocalSearch answered "Grainger"
with an industrial supply store. On a miss it searches a ±3 km region with `regionPriority = .required`
and `DestinationPicker` takes the **nearest** sensible result rather than MapKit's first. Every MapKit
route now speaks "Walking to Grainger Engineering Library, 750 meters." before guidance starts, so a
wrong pick can be stopped before the walker moves.

**Fixed: route hijack (safety).** A Siri search still in flight when the walker pressed Start demo route
would return later and call `beginRoute` again, swapping them onto the searched route mid-walk with no
indication. Start and Stop now abandon an in-flight build.

**Fixed: trip-log field collision.** Cue and hazard events passed a field named `kind` that overwrote
the record's own, so hazard records came out as `{"kind":"sign"}` and `e2e.py` never saw one. Fields
renamed (`cue`, `type`), and `TripLogRecord` (CaneKitLogic) now makes it structurally impossible: a
colliding field is kept as `field_t` / `field_kind` and can never win.

**Live camera view** (`LiveCameraView`, Hazards card, off by default). An `ARSCNView` bound to the app's
existing `ARSession` — display only, it never runs, pauses or delegates the session — replacing a 3 Hz
JPEG. Drawn at the camera rate, capped at 30 fps so the preview cannot steal frames from obstacle
detection, blank in the background and on the lock screen, and torn down safely. For the sighted spotter
and the demo video; it is off by default because it costs battery and heat and a blind user gains
nothing from it.

**Natural voice (ElevenLabs) made first-run-proof.** The code has existed since Step 7 but had never run
against a real key. Two things would have bitten: prefetch shared the 2.5 s live-speech timeout (nobody
waits on a prefetch — on a slow first connection every one would fail silently, turning each route line
into a live miss that *also* had 2.5 s to fail), and `voiceError` was recorded but never rendered, so a
wrong key looked exactly like no key. Prefetch now gets 15 s and reports its first real failure to the
Haptics card, where a bad key reads "ElevenLabs HTTP 401" seconds after launch. Still blocked on
`ELEVENLABS_API_KEY` in the git-ignored `Secrets.plist` — see docs/todo.md.

Verified: 164 Logic tests pass, `BUILD SUCCEEDED` with no warnings, installed and launched on the phone.

test on device: say each of the seven phrases with the phone locked and AirPods in (the app must come to
the foreground and act); "Take me to Grainger in CaneKit" must reach the Springfield Avenue entrance,
not the supply store; say "Stop the route" while "Finding a route…" still plays and confirm nothing
starts after; turn on Live camera view on the Hazards card and confirm it is smooth and goes blank when
the screen locks; AirDrop the trip log and confirm hazard records read `"kind":"hazard"` with a `"type"`
field and that no line contains `field_kind`.

## Step 12 — Google Street View mock of ISR → CIF: what failed and the fixes (Fri Sep 11, pre-device)
The 14 Street View frames of the route (local-only, `ios/scripts/streetview/`) now drive the camera in
the simulator end to end, and the log shows what the camera saw, not only what was spoken.
- **Found: "Where am I" spoke Vision's taxonomy.** At Green Street the on-device template would say
  "Automobile, machine and vehicle in view.", at Springfield "Conveyance, portal and manhole in view.",
  in the ISR lounge "Furniture, table and conveyance in view." **Fix:** `SceneVocabulary` (CaneKitLogic,
  5 tests built from the real Street View labels) keeps pedestrian nouns only, merges synonyms, drops
  hypernyms and says crossing information first: "Ahead: the street and cars.", "Ahead: a crosswalk,
  a path and the street.", "Ahead: tables, chairs and windows." It feeds both the template and the facts
  given to Apple's on-device model.
- **Found: sign reading range was a guess.** `ios/scripts/sign_probe.swift` pastes a "SIDEWALK CLOSED"
  sign onto every route frame at many sizes and runs the app's exact text request. Measured: the old
  1/80 floor read 7.5 cm letters from ≈ 4.4 m (Vision's default only 1.7 m). **Fix:** 1/128 → 7.5 cm
  letters from ≈ 7 m and 15 cm from ≈ 14 m on every frame, with no measurable extra OCR time
  (~7 ms/frame on the Mac). At walking pace that is two 3 s scans before you reach a sign, not one.
- **Found: STOP signs would be read at every corner.** With the longer range a STOP sign (a drivers'
  sign) reads from across an intersection. **Fix:** "STOP" is no longer a sign phrase; "PUSH BUTTON"
  (a crossing sign a walker can use) is. Test `stopSignsAreForDriversPushButtonIsForWalkers`.
- **Found: the camera path was invisible.** The Street View e2e "passed" with no record of any sign scan
  or description. **Fix:** new trip-log records `scan` (text read, line said, frame), `hazard_watch`
  (raw reply, latency, dropped/why, error) and `describe_result` (what "Where am I" actually said,
  error, ms), useful on the phone too. `make e2e SCENARIO=streetview` now turns on the hazard watch,
  asks "Where am I" at the start and every waypoint (`CANEKIT_DESCRIBE_EVERY_WAYPOINT`), fails unless
  ≥ 8 of 10 corners are described, and reports per-corner sentences.
- **Found: far storefront words would be read** (Muse + Antigravity): with 1/128 text, "EXIT" / "PUSH"
  across the street matches. **Fix:** one-word phrases need the text line ≥ 1/80 of the frame tall
  (close); multi-word safety phrases ("SIDEWALK CLOSED") still read from far (`SignPolicy.SeenText`,
  `shortPhraseMinHeight`, test `farTextReadsSafetySignsButNotStorefrontWords`). The measured range is
  for a flat, frontal sign in good light; expect less on a moving cane.
- **Found: Apple's on-device model invented facts.** On a Street View corner "Where am I" said "No
  hazards detected. Distance: 0 meters." **Fix:** a new prompt (name what is there; numbers only from
  the facts; never "no hazards") and `SceneVocabulary.isFaithful`: the model's sentence is spoken only
  if it names something detected and invents no numbers, else the template speaks (test
  `modelSentencesMustBeFaithfulToTheFacts`). The unguarded Street View e2e showed the model said "No
  hazards detected. Distance: zero meters." at 7 of 10 corners and turned OCR junk ("11", "J.I" off
  road markings) into "11 meters to the edge". Now spelled-out numbers are checked too and only
  word-like text (`SceneVocabulary.readableTexts`) reaches the model; all four real bad sentences are
  test fixtures (`streetViewModelNonsenseIsRejectedAndOCRJunkFiltered`).
- **Found (Muse + Antigravity): people, ice and houseplants.** People were filtered out entirely (a busy
  sidewalk said "nothing"); ice and snow ranked below benches; an indoor "plant" became "bushes".
  Fixed with tests (`peopleIceAndPlantsAreSaidSensibly`). Diagnostics now record the frame that was
  *sent*, not the one current when the reply came back; the arrival corner is described too.
- **Rejected:** refusing to start a route when the camera is off (Antigravity). Guidance works without
  the camera; the app warns loudly and still guides. The on-screen error now survives (it was cleared
  right after being set). Antigravity also edited files during a "read-only" review; its edits were
  audited one by one and reviews now run it on a copy of the repo.
- **Final review of b1c35bd (Muse + Antigravity on a repo copy), all fixed with tests:** the model gate
  now accepts synonyms and plurals ("road", "car", "crossing"), rejects prefix look-alikes
  ("businesses" ≠ "bus"), and compares numbers with spelled facts and decimals kept whole ("two
  meters" allows "2"; "1.4" does not license an invented "4"); far text lines are never joined (a
  distant "ROAD" + a shop's "CLOSED" is not a sign) and missing text heights count as far; the "Where
  am I" template uses sized text too; the camera-denied warning is spoken once, not twice in a row.
  Tests `faithfulnessUnderstandsSynonymsAndSpelledNumbers`, `decimalsInTheFactsStayWhole`,
  `farLinesAreNotJoinedIntoAPhantomSign`.
- **Review of 3efc0b1 (Muse), all fixed with tests:** with nothing detected the model is never
  trusted (a blank wall cannot become "A door ahead."); teens and tens count as numbers; a misread
  "EX1T" still counts as text; a `SeenText` of unknown size is far by default (the tuple overload is
  for test fixtures only); the Street View e2e needs a clean hazard-watch reply, not just a record.
  Tests `blankWallsTeensAndMisreadsAreHandled`, `unknownTextSizeCountsAsFar`.
- **Review of 3efc0b1 (Antigravity, on a repo copy):** "Where am I" still showed the language model
  far lone words; `SignPolicy.mayMention` (close, or several words) now filters the facts too (test
  `onlyCloseOrMultiWordTextMayBeMentioned`).
- **Muse camera review (after 45230fe):** fixed — the retained camera frame is refused after 2 s
  (`DepthFrameProcessor.maxFrameAge`: an ARKit stall no longer describes a corner already left); the
  Mount card judges the tilt it shows (2.6° reads "3°" and is now "good"); a sign scan with no fresh
  frame no longer spends its 3 s slot. Rejected with reasons — gating *cloud* sentences with
  on-device labels (the cloud model sees the image; coarse labels would reject good answers), dropping
  the LiDAR gate on on-device hazard labels (deliberate, AGENTS.md: it stops "fence" chatter along
  railings). Deferred — clamping cloud hazard-watch distances (the watch ships off by default).
- **Antigravity nav review:** fixed — a new route no longer starts from a GPS fix older than 30 s.
  Rejected — stopping the watch keep-alive on "No route" (deliberate: a suspended watch app could not
  restart it for the next route). Deferred to the device session (logged in docs/todo.md): head
  tracker started without AirPods (battery), the launch "Phone is hot" line before the audio session
  is configured, skipped waypoints not announced in the rare passed-by-plus-skip case.
- **Simulator scene recognition, settled:** Vision classification fails in the simulator ("Failed to
  create espresso context"); a CPU-pinned `VNClassifyImageRequest` was tried and returns all 1,303
  labels at ~0 confidence, so it was removed again. Scene words are tested with `vision_probe.swift`
  on the Mac (real labels) and `SceneVocabularyTests`, and on the phone. The trip log's
  `describe_result.vision_error` shows this directly.
- **Antigravity camera review:** fixed — `VLM_PROVIDER` is case-insensitive ("Gemini" no longer
  silently ignored); a hazard-watch reply that lands after the watch was switched off (or paused hot)
  is not spoken; a failed request clears its latency. Rejected with a test — "the tilt sign is
  inverted": the formula moved to `MountTilt.downDegrees` and `tiltSignIsDownPositive` proves down is
  positive. Rejected — ground-hazard "flicker" (a hazard the current frame no longer sees drops out
  by design; the repeat policy prevents re-announcing it).
- **Muse nav review:** fixed — a GPS jump past the destination's fence (passed-by arrival) now gives
  the arrival tap; Repeat after a skip-ahead includes "Passed one waypoint."; a heading-age check that
  could never fail was removed (headings arrive current). Rejected — "Repeat dropped during a call"
  (no caller uses a zero TTL; a 12 s Repeat expiring mid-call matches the queue's staleness rule and
  Repeat works again after the call).
- **Claude review workflow (10 agents, 16 confirmed, 9 rejected), all addressed:** Apple's model
  invented "a crosswalk, then stairs, then a door" from the prompt's own examples (4/4 on the Mac)
  → examples removed, `isFaithful` now rejects any vocabulary object that was not detected, and a
  LiDAR distance is spoken first (test `inventedObjectsAreRejected`); `.prefix(8)` cut the crosswalk
  behind synonyms → removed; far two-line signs ("SIDEWALK" over "CLOSED") are joined when the line
  geometry shows one sign (`SeenText.box`, test `farStackedSignLinesAreJoined`; sign_probe
  re-measured with the same rule: still ≈ 7 m for 7.5 cm letters); a deep drop is reported at the
  end of the last visible ground, not a metre past its hidden edge (test
  `aDeepDropIsReportedAtItsNearEdge`), and long stairs down / ledges over ~0.6 m are documented as
  not detected; a second "Veer" now needs a full 3 s hold after the course reset
  (`OffCourseDetector.endEpisode`, test `endEpisodeRequiresAFullHoldAgain`); sign lines keep 20 s in
  the queue; the first head-height cue after unlock is spoken; the Street View e2e reports "no scene
  labels (simulator limit)" as a warning; docs: the Team ID instructions (the parentheses in a
  certificate name are not the Team ID), the AirPods check order, Guided Access options, stale
  comments.
- **Muse + Antigravity on f5413b8:** fixed — the LiDAR distance is prefixed unless the model's sentence
  states that *number* (`SceneVocabulary.mentionsDistance`; "parking meters" / "kilometers" matched
  the old substring check); words the facts contain (and "sign" when text is visible) count as
  grounded, so "a sign says sidewalk closed" is accepted; sign lines keep 8 s in the queue (20 s could
  play 25 m past the sign); a gated-out veer moment ends the episode (no instant veer after a GPS
  gap). Tests `plainGoodSentencesStillPass`, `factWordsAreAllowedAndDistanceIsANumber`. Rejected —
  "the first head cue after unlock replays a stale cue": the decider is reset on background, so any
  head cue after unlock is a fresh LiDAR detection and should be spoken.
- **First real-phone build (iPhone 17 Pro Max, iOS 27.0):** signed with the free Personal Team,
  installed. Found: a comment after the value in `ios/local.mk` (the format the docs showed) left
  trailing spaces in `DEVICE`, so xcodebuild could not find the phone; the Makefile now strips
  `TEAM` and `DEVICE`. First launch needs Settings → General → VPN & Device Management → Trust.
- **Real-phone desk test (iPhone 17 Pro Max, iOS 27.0) — found and fixed:**
  - *Depth ran at exactly 10 reports/s, not 15*: a `now − last ≥ 1/15` check fails by a hair on the
    second 33.3 ms frame. `PublishGate` (CaneKitLogic, tested with 30 and 60 Hz input) fixes it; the
    cap is now **30 reports/s** (CueDecider is timed in seconds, so no logic change), mesh lookups stay
    ~4 Hz. Measured: 30/s, thermal nominal.
  - *Camera*: ARKit with LiDAR offers only the 1x wide camera on this phone (up to 60 fps; no 0.5x,
    no 120 fps; the front camera only as face tracking), logged in the `start` event. The app now
    runs the full 4:3 frame at 60 fps (was 16:9 at 30).
  - *"Where am I" mixed two moments*: the LiDAR context was read for the facts and again ~0.7 s later
    for the prefix ("…looks like a table. A door is one meter ahead."). One snapshot per description.
  - Proven: LiDAR, haptics, mesh names, head-height cue, on-device Vision + Apple's model.
- **Final Muse + Antigravity reviews (after 33fc636), all addressed with tests:** a closer hazard-watch
  update is not a duplicate; stacked sign lines join across the close/far boundary and close words
  need geometry too; missing depth bins allow for ramp slope (no false drop-off); a drop in the last
  bin waits; invented hazard words ("cone", "barrier") are rejected; the watch slot is refunded
  without a frame; a mid-route screen lock *says* obstacle warnings are paused; a new route clears
  the last drop-off line; haptics failure is always announced; the mount tilt updates every frame;
  a new route forgets the old heading; the hazard watch ignores a stale fix's speed. Rejected —
  waiting for a fresh fix before a typed-destination route (a standing walker's fix is still right
  and iOS may not send a new one). Antigravity again edited and committed in its *copy*; the real
  repo was untouched.
- **Phone follow-up (hand-held false hazards, heat, spam):** ground hazards are judged only with a
  mount-like camera tilt (0-15 deg, `MountTilt.groundUsable`) and a plausible ground 0.5-1.3 m below
  the camera (`groundHeightRange`): every false "Hole ahead" on the phone came at 10-57 deg with the
  phone in the hand, or with a desk as "ground" (tests `aDeskIsNotTheGround`,
  `groundHazardsNeedAMountLikeTilt`). Drop-off and hole frames agree as one hazard (no last-bin wait;
  `dropAndHoleFramesAgreeAsOneHazard`); missing bins get per-reference ramp slack. Camera back to the
  full 4:3 frame at **30 fps by default** with a "60 fps camera (warmer)" switch (both reviewers:
  60 fps + 30 Hz untested for heat over a walk). The screen-lock warning is spoken once per route,
  and the "back" line is gone. Hazard-watch refund retries in 2 s, not every tick. Rejected —
  "tilt on every frame skews lanes/veer" (the tilt feeds only the Mount card and the log).
- **Engineering bar written down:** `AGENTS.md` → "How we engineer" (and `CLAUDE.md`), so every
  contributor, human or AI, works the same way.
- **Found: "CaneKit ready." after "Camera access is off"** (Antigravity docs review): the ready line is
  now skipped when the camera is refused.
- **Teammate handoff:** `docs/TEAM_HANDOFF.md` (read first after a pull), README / docs index / iOS README
  refreshed, doc drift fixed after Muse + Antigravity reviewed the teammate-facing docs.
- Test on device: in airplane mode, "Where am I" at a street corner says plain words ("Ahead: a
  crosswalk…"), never "conveyance" or "portal"; a printed "SIDEWALK CLOSED" sign (7.5 cm letters) is read
  from ~6–7 m; walking past a STOP sign says nothing; the trip log has `scan` and `describe_result` lines.

## Step 11 — Hazards the maps don't know, on-device vision, stress harness (Fri Sep 11, pre-device)
- **LiDAR ground hazards.** `GroundSampler` projects the depth map into the walker's
  gravity-aligned frame; `GroundHazardDetector` (CaneKitLogic) finds drop-offs, holes, curbs up and
  low obstacles 1.5–3.5 m ahead in the walking corridor, ignoring smooth ramps and anything taller
  than 50 cm (the lane grid's job), confirmed on 3 of 5 trusted frames. Spoken at safety priority
  ("Drop-off ahead, two meters.") with 4 heavy taps on the cane.
- **Signs, on-device.** Vision text recognition every 3 s: "Sign: sidewalk closed." / detour /
  construction / stop / exit…, each at most once a minute. Offline.
- **Hazard watch.** While walking a route, one frame every 8 s to the vision model asking only for
  path hazards (cones, barriers, trenches, scooters, low branches); "NONE" is silent.
- **On-device "Where am I".** Apple Vision (scene labels + text) + Apple's on-device language
  model phrase one sentence with the LiDAR facts; a template when Apple Intelligence is off. Cloud
  providers now fall back to it automatically, fail fast (8 s), and a key is no longer required.
- **Hazard map.** Every announced hazard → `Documents/hazards/hazards-<session>.geojson` with GPS and
  a photo; "Share hazard map" on the new Hazards card, which also has a live camera view.
- **Route cues on the cane.** Long soft buzzes (turn left 1, right 2, crossing 3, arrived
  long-short-long) alongside the watch.
- **Review fixes (Muse + Antigravity full-app reviews):** GPS course no longer dropped by the sweep
  gate; location / camera denied are spoken instead of silent; GPS stops after arrival; a second
  route start restarts cleanly; beacon restarts on foreground; natural-voice circuit breaker on weak
  networks; interruption fallback never drains over a live call; AirPods route flaps debounced; head
  tracker stops when AirPods disconnect; watch workout stops after arrival and restarts next route;
  late watch send failures tap `.retry`; heat downgrade is announced; no force-unwrapped URLs from
  Secrets. Rejected with evidence: `@concurrent` and `HKQuantityType(.stepCount)` "don't compile"
  (both valid; the build is green).
- **Jitter-proof veer.** `CourseSmoother` (15 m / 5-fix ends) feeds the veer decision while walking:
  simulated ±6 m jitter produced 28 false veers with per-fix course, zero across 20 runs smoothed.
  An arrival hint is spoken after 20 s near the destination without arrival.
- **Stress harness.** `make e2e`: GPS-replay scenarios through the real app in the simulator
  (clean, missed_fence, gps_jitter, wrong_turn) asserting on the trip log. The debug footer is gone.
- **Round-5 review (22 confirmed findings, all fixed).** A 61-agent adversarial review with
  ray-cast and nav-engine simulations found, and this step fixes:
  - *Curbs warned too late under a real sweep* (confirmed only 1.2–1.7 m ahead at 1.2 m/s): the
    ground path now has its own 1.5 rad/s gate on raw depth, ~7 evaluations/s (simulated: 2.3–2.6 m).
    A curb face landing mid-bin is found (edge vs the previous two bins); the distance is the nearer
    edge; a rise in the last bin waits for a closer look.
  - *False "Veer" after the WP2/WP3/WP6 corners on every clean walk*: the course smoother stays empty
    inside the corner's fence and resets after each veer cue. Nav harness running the real
    NavigationEngine: 0 false veers in 72 walks (clean, ±2 m jitter, ±15°/25° course noise), and an
    injected 35° veer caught once in 18/18 walks.
  - *The 2.5 s voice deadline repeated a finished line in the robot voice*: fetch and deadline are
    now mutually exclusive.
  - *Stale camera after unlock*: the paused frame is dropped; LiDAR context cleared on background.
  - Standing at a curb no longer repeats the warning every 6 s (same hazard: 1 m closer or 30 s);
    partial sign reads ("CLOSED" after "SIDEWALK CLOSED") stay quiet; signs read from farther
    (small text); hazard-watch cloud cut off at 2.5 s, stale replies dropped or lose their
    distance; the on-device LiDAR gate uses the centre lane only; hazards after arrival keep their
    location (null geometry with no fix); arrival hint works while standing still; a typed
    destination with Location off is refused at once; haptic engine retries after non-suspension
    stops; watch keep-alive ignores callbacks from old sessions; live view pauses when hot.
  - e2e: tick-based time budget (gps_jitter could never arrive), per-scenario error isolation, no
    stale report, and an opt-in `streetview` scenario (Street View frames as the camera).
    `make tour` / `make uitest-streetview` never passed their folder to the test runner
    (`TEST_RUNNER_*` was a trailing build setting); it is now in xcodebuild's environment.
- **Round-6 check (Muse + Antigravity on the round-5 fixes).** Muse: the "head height" context line
  now uses the centre lane only too; a hazard is geotagged with the nav engine's last fix only if it
  is under 2 minutes old; the haptic engine is not retried during a call (restarted on the
  interruption's end) and retry loops never stack. Antigravity's "swap max/min in the edge test"
  was rejected: it reverts the mid-bin curb fix (the tests show the fix finds the curb and 10 %
  ramps stay silent); the ~11 % ramp trade-off is documented in AGENTS.md.
- **Phone-to-cane mount (hardware/mount/, for Sagar).** Printed PETG clamp for the 28.75 mm pole with
  a 5°-detent hinge, OpenSCAD model, test coupons, a pitch model and a T0–T11 bench protocol. Its key
  finding: the lane grid has no gravity correction, so the camera must aim 3–8° below the horizon,
  not 10–20°. The Mount card now shows "Camera tilt N° down · N fps" live (`MountTilt`, tested), and
  every `lanes` log line carries `tilt` and `fps`.
- Test on device: Mount card reads "Camera tilt …, good" with the cane held normally and the cane stays
  quiet on an empty sidewalk; turn on "Detect drop-offs", then walk at a curb sweeping normally → the warning
  comes ≥ 2 m before the edge, once, and not again while you stand there; point the cane at a curb 2 m ahead → "Drop-off ahead, two meters." + 4 taps; hold a
  printed "SIDEWALK CLOSED" sign in view → "Sign: sidewalk closed." once; airplane mode + "Where am I" →
  an on-device sentence; walk past a waypoint → cane buzzes as well as the watch; Share hazard map →
  a GeoJSON that opens in geojson.io.

## Step 10 — Two adversarial review rounds, AirPods/Watch presence, XCUITests (Fri Sep 11, pre-device)
Round 1 (full-app review, 65 agents) and round 2 (review of the round-1 fixes, 5 dimensions, 30+
findings) and a Muse review of the result are folded in. Verified by 79 logic tests, a green simulator build, 6 XCUITests and the
screenshot tour on the **iPhone 17 Pro Max / iOS 27** simulator, and a GPS replay with deliberately
missed fences. Every rule with a number in it moved to `CaneKitLogic` with tests
(`NavSupport.swift`: TurnSettle, StraightWalkDetector, CueSpeechPolicy, CrownAccumulator).

- **A missed fence never strands the route.** Skip-ahead over the next two waypoints ("Passed one
  waypoint." + the real line); passed-by detection (2× radius, then receding a radius, 1 m jitter
  tolerance) says "Passed Goodwin Avenue. Green Street in 150 meters." instead of a stale "turn right";
  near a waypoint the beacon follows the recorded leg bearing and veer cues are muted, so nothing points
  back at a missed waypoint. "GPS weak" fires at the same 20 m that pauses the fences.
- **Arrival is plausible, not lucky.** `distance + accuracy/2 ≤ 20 m` on two consecutive fixes; one 30 m
  blob 45 m short of CIF can no longer end the route.
- **No false "Veer" at corners.** The turn settles on distance (6 m, or receding on two good moving
  fixes), on the body heading matching the new leg, or after 25 s of *moving* time — never on a timer,
  never on a standing fix. At a crossing the beacon is silent until you reach the curb. WP1's S-shaped
  path is marked `curved` (no veer, beacon quiet), WP3 is a turn not a crossing, turn fences are 12 m,
  and WP6 now says "Turn left to face west" before the crossing.
- **Beacon honesty.** Plays only into headphones; ignores AirPods yaw until re-zeroed after a turn (no
  double-counted body turn); auto-recenter needs 3 straight fixes and never fires within 15 m of a
  crossing; restarts after a phone call with retries.
- **Speech that is never lost or looped.** Priorities scene < obstacle < route < "Head height.";
  an interrupted line resumes once (then Repeat); "Head height." once per obstacle episode; warnings
  never wait for ElevenLabs; calls/Siri queue lines and drain afterwards; watchdog for stalled backends.
  **Repeat** (phone, watch, "Repeat in CaneKit") says the last line actually spoken + where the next
  waypoint is, even mid-line.
- **AirPods + Watch presence.** New `AudioRouteMonitor`: "<AirPods name> connected." / "Headphones
  disconnected. Beacon paused."; at route start the app says which channel is missing (no headphones,
  watch not reachable, no haptics). Guide card pills show "No AirPods" / "Head tracked" / "Compass only".
  Watch: distance in the title bar, phone-link glyph, Repeat / Next / Describe / Recenter fit a 42–46 mm
  screen, crown = 3 detents within 1 s, "Update the phone app" when the phone is older than the watch.
  Watch gets a status update on every fix (was: only at waypoints). See `docs/devices_setup.md`.
- Silenced or dead haptics mirror obstacle cues to the watch and speak them.
- UI: two-per-row guide buttons (no hyphenated "Recen-ter"), single-line pills, fixed "Go" button,
  full instruction text; Repeat stays after arrival.
- Infra: `make uitest` / `make tour` / `make sim17` / `make sim-grant`; `.github/workflows/ci.yml`
  (logic tests on every push); `AGENTS.md`, `CLAUDE.md`, `docs/CODE_REFERENCE.md` for future agents.
- Test on device: see `docs/devices_setup.md` first (AirPods Spatial Audio off, watch app open). Then:
  walk past WP2 on the far side of the path → "Passed Illinois Street sidewalk…" and no "Veer"; at
  Goodwin keep walking to the corner → no "Veer" until you turn, beacon then swings north; at Green St
  stand at the curb with your head turned → no clicks until you face north; tap Repeat on the watch
  mid-line → the line again + distance to the next waypoint; pull the AirPods out → "Headphones
  disconnected. Beacon paused."; toggle Silence haptics and raise a hand overhead → wrist tap +
  "Head height." once; take a call mid-route → speech and beacon resume.

## Steps 8–9 — Scene description, arrival card, Live Activity (Fri Sep 11, pre-device)
- "Where am I": VLMClient protocol with OpenAI-compatible (Muse 1.3 / OpenAI), Anthropic and Gemini
  transports (bodies + parsing unit-tested), SceneDescriber (waits ≤ 3 s for a camera frame, 1024 px JPEG
  off-main, speaks the sentence or a spoken error), triggers: on-screen "Where am I", watch Describe,
  Camera Control (spike), Action button via the "Where am I" App Shortcut (+ "Start CaneKit route").
- TripTracker: elapsed, GPS-integrated distance (moving fixes only), steps from HealthKit (watch-merged)
  with the phone pedometer running alongside; spoken arrival summary after the count refreshes.
- Live Activity: CaneKitWidget target (Dynamic Island + lock screen glyph/instruction/distance), updates
  coalesced to waypoint changes or ≥ 10 m, ends 60 s after arrival. ArrivalCardView while walking / on arrival.
- Automation: `CANEKIT_DEMO_ROUTE=1` env (or `--demo-route`) starts the demo route at launch.
- Test on device: press "Where am I" → "Describing." then one sentence (needs a key in Secrets.plist; without
  one it says so); Action button → same from the lock screen; walk the route → Dynamic Island shows the
  next instruction + distance; arrival → card + "CIF … meters, minutes, steps".

## Steps 6–7 — Navigation + beacon + natural voice (Fri Sep 11, pre-device)
- LocationService: `CLLocationUpdate.liveUpdates` + compass; GPS course replaces the compass while walking;
  background activity session so guidance survives a screen lock. NavigationEngine: geofence per waypoint
  (speak once, wrist cue crossing/turn, advance), live target bearing (recorded bearing when the fix is poor),
  veer left/right after 3 s off-course with an 8 s settle window after every turn, "GPS weak"/"GPS back".
  RouteSource: bundled Townsend→CIF file or MapKit walking directions to any typed destination.
  **Verified in the simulator with a GPS replay: waypoints 1→4 fire in order with the right lines and cues.**
- BeaconEngine: AVAudioEngine → AVAudioEnvironmentNode (HRTF) soft click at the absolute target bearing,
  listener yaw = −(heading + head yaw), silent < 10° error, full by 90°, ducks while speaking, survives
  AirPods route changes, safe across routes. HeadPoseTracker: AirPods yaw via CMHeadphoneMotionManager,
  Recenter (button / watch / auto 8 s after each turn).
- Natural voice: ElevenLabs TTS (`eleven_flash_v2_5`, warm premade voice by default) with a disk cache;
  route lines + common phrases pre-synthesized at route start; AVSpeech fallback offline / without a key.
  Keys: `ELEVENLABS_API_KEY`, `ELEVENLABS_VOICE_ID`, `ELEVENLABS_MODEL` in Secrets.plist.
- GuideCard: instruction, hero distance, on-course pill, GPS pill, Next / Recenter / Stop, demo route or
  typed destination. `--demo-route` launch flag for automation.
- Test on device (outside, AirPods in): Start demo route at the ISR doors → route intro; walk west → sidewalk
  line + wrist tap at WP2; at Goodwin → crossing line + wrist notification; turn 45° off for 3 s → "Veer
  right"; beacon clicks from the walking direction and goes quiet when facing it; turn your head, body still
  → click moves the other way; Recenter zeroes it; AirPods out → still pans from the compass; Stop → silence.

## Step 5 — Watch (Fri Sep 11, pre-device)
- PhoneWatchLink (WCSession): nav cues (turn/crossing/arrived), obstacle mirror throttled 1/s per kind when the
  phone haptic engine is unhealthy or "Mirror obstacle cues" is on, status line via application context +
  live message, Next/Describe/Recenter commands in.
- Watch app: WKHapticType map (turnLeft .directionUp, turnRight .directionDown, crossing .notification,
  arrived .success, obstacle .failure; mirrored left .start / right .stop / center .click / head .failure),
  Next/Describe/Recenter buttons, crown = Next after 3 detents (0.8 s debounce), walking HKWorkoutSession
  keep-alive with delegate + WKExtendedRuntimeSession fallback (mindfulness background mode), initial
  application-context read, "Phone not reachable" feedback. HealthKit entitlements on both targets.
- Route: renamed "ISR Townsend Hall to CIF"; Townsend's only Illinois-St door is the ISR front door (WP1
  unchanged, spoken line updated); docs/route_isr_cif.md documents the evidence.
- Test on device (watch app open, wrist up): phone Watch card shows "Reachable"; Left/Right/Cross/Arrive
  buttons → distinct wrist taps; crown three clicks → phone says "Next."; Describe/Recenter buttons → phone
  acknowledges; toggle "Mirror obstacle cues" → obstacle taps on the wrist ≤ 300 ms after the phone buzz;
  lower the wrist for 30 s → cues still arrive (workout keep-alive).

## Step 4 — Speech + obstacle names (Fri Sep 11, pre-device)
- SpeechQueue: one `.playback` session (`.duckOthers`, no Bluetooth options, interruption re-activation),
  priorities scene < nav < obstacle, higher priority interrupts at a word boundary, FIFO within priority,
  TTL drops stale lines, utterance identity guards against the late `didCancel` race, enhanced en-US voice.
- ObstacleNamer: mesh class at the image centre → "door ahead, two meters" (door/wall/seat/window/table;
  walls only < 1.5 m), one line per 2.5 s, re-announces only on class change or a full metre of movement.
- AppModel: "CaneKit ready." on start, obstacle names toggle, speech test button + Speaking pill.
- Test on device (AirPods in): "CaneKit ready" comes out of the AirPods; walk to a door → "door ahead, two
  meters" once, closer → "door ahead, one meter"; a chair → "seat ahead…"; Speech test → the obstacle
  line cuts the scene line at a word boundary; take a phone call → speech resumes afterwards.

## Step 3 — Core Haptics (Fri Sep 11, pre-device)
- HapticPlayer: haptics-only CHHapticEngine, pre-built left (2 taps) / right (3 taps) / head (2 sharp hits)
  players, Geiger approach loop (single-transient player on a Task, 2 Hz at 2 m → 8 Hz at 0.5 m, intensity
  0.6 → 1.0), reset/stopped handlers, `isHealthy` for the watch fallback, silence toggle, test buttons.
- Cue router in AppModel: CueDecider → HapticPlayer; background stops cues and resets the decider.
- TripLogger: JSONL in Documents (lanes at 2 Hz, cues, session events; flushed every 2 s and on background).
- Runs in the iOS 27 simulator (UI verified); haptics + LiDAR need the phone.
- Test on device: clamp the phone; walk at a wall → taps speed up from 2 m to 0.5 m; hand at torso-left →
  2 taps, torso-right → 3 taps, head height → sharp double; back away → cue clears only past +0.15 m;
  "Silence haptics" stops everything; the four test buttons play their patterns; a log file appears in Files.

## Steps 1–2 — project scaffold + depth engine (Fri Sep 11, pre-device)
- Xcode 27 RC (27A266a) installed; XcodeGen 2.46.0; `ios/project.yml`, `scripts/gen.sh` (watch-embed patch,
  `WATCH=0` phone-only mode, Secrets copy), `Makefile`, `scripts/test.sh` (works with CLT alone).
- `ios/Logic` SwiftPM package (Foundation-only): LaneMath, LaneReport/TileLevel, CueDecider + GeigerRate,
  GeoMath (haversine, bearings, OffCourseDetector, GeofenceTracker), Waypoint/Route/RouteBuilder,
  WatchMessage envelope, VLM request/response codecs, SpokenDistance. **49 unit tests green.**
- App: CaneKitApp, AppModel (capabilities, settings, thermal + battery, Camera Control counter),
  DepthEngine (main-actor owner) + DepthFrameProcessor (background ARSessionDelegate, gyro gate, 15 Hz,
  smoothed depth, AsyncStream), MeshClassifier (centre-face lookup, face budget, raw-value guard),
  CameraControlInteraction spike, LaneGridView + DebugFooter, Theme.swift design system (docs/design.md).
- Watch: scaffold app + WatchTheme. Route: `Resources/route_isr_cif.json` (9 OSM-verified waypoints, 989 m).
- Reviews: 4-dimension adversarial workflow on Logic (56 agents) → fixed the 1 s no-repeat bypass on cue
  changes, the geofence speed gate accepting CoreLocation's -1, Anthropic max_tokens; Muse review of the
  diff → idempotent `DepthEngine.start()`, ARError codes surfaced, mesh face budget, CKCard a11y label.
- Builds clean for the iOS Simulator under Swift 6 strict concurrency. Not yet run on a device.
- Test on device: app shows "Depth OK" with six live tiles; wall at 1 m ≈ 1.0 in all tiles; hand at the
  left edge → Left tiles red; raise the hand → Head row; swing the cane → SWEEPING; fps ≈ 15;
  note whether a Camera Control press increments the footer counter.

## Step 0 — phone-only reset (Thu Sep 10)
- Decision: iPhone 17 Pro Max is the only computer. ESP32 grip, ToF pod, buy list → stretch/historical.
- `ios/CaneKit/CaneBLE.swift` moved to `ios/stretch/` (out of the app).
- Docs rewritten for the phone-only build: `README.md`, `ios/README.md`, `docs/ideas.md` §5.1.
- Plan reviewed twice with Muse; spec deviations recorded in `ios/README.md` §2.
- Test on device: nothing yet (no Xcode on the build Mac until the 27 RC download lands).
