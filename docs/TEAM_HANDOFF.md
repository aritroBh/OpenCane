# Team handoff: read this first after you pull

State of OpenCane / CaneKit at **HEAD `076fcaa`** (Sat 2026-09-12 evening): Steps 26–37 plus the
per-camera rotation fix are on `main`. Written for Aritro, Aarav, Tejas, Sagar and Tommy, and for
AI agents picking the work up. It says what exists, what is proven, what is not, what is open, and
which decisions are already made so nobody re-litigates them at 2 a.m. Every sentence marked
**historical** was true when it was written and is kept for context; everything else was checked
against the code, `git log` and `CHANGELOG.md` at `076fcaa`. The commits after it (`e459b3a`,
`c706856`, `d775d4b`) are documentation passes plus the new `ios/scripts/streetview_stim.py`; they
change no Swift code outside comments, so every behaviour and test count here still holds.

> **The 2-minute version: [`TEAM_BRIEF.md`](TEAM_BRIEF.md). Open work: [`todo.md`](todo.md) →
> "Cue design v2 — Steps 35–45".** AI agents: read §10 ("How an agent resumes") before touching
> anything. The code wins over every doc, this one included; fix the doc when they disagree.

## 0. Start here (5 minutes)

1. `git pull`, then `cd ios && make test` (457 Logic tests, Swift 6 / Xcode 27). Check the exit
   code of `make test` itself, never through `| tail` (§10.4).
2. Read the "Still needs the phone" list in §2.4. Most of the last day's work is built and
   simulator-green but not yet checked on the phone.
3. **Sagar, Tommy:** open `hardware/README.md` → quick start. The mount is yours to change; the app
   needs only what §5 lists (phone upright, camera 3–8° down, firm, shaft out of view). The cue
   tuning in §2.4 is blocked on a walk **with the phone on the mount**.
4. **Aarav:** read §6 (what is on and off; obstacle names are now **off** by default) and the D2 /
   D11 tests in `stress_test_plan.md`; you will feel the haptic patterns and wear the watch.
5. **Anyone changing code:** read `AGENTS.md` (hard rules + "How we engineer"), then
   `docs/CODE_REFERENCE.md`, then ask the graph where things live: `graphify query "…"`.
6. Stuck? The symptom → fix tables are in `docs/devices_setup.md` and the gotchas in `ios/README.md` §6.

## 1. The one-paragraph version

An iPhone 17 Pro Max (iOS 27) clamped to a non-metal cane is the only computer (the prototype
shaft is a broom handle measured at 27.65 mm by the printed bore rings; the older 28.75 mm figure
is retired as `pole_d` in both mount models and survives only as the alternate-cane fit check). LiDAR warns about waist-to-head obstacles by shaking the cane
(Core Haptics), GPS walks a 9-waypoint route from ISR Townsend Hall to the CIF east entrance (or
any destination through the campus gazetteer and MapKit), AirPods Pro play a spatial click from the
direction to walk and speak the instructions, and an Apple Watch taps turns and crossings onto the
wrist. The phone UI is three icon-only tabs: **Guide**, **Sense** (depth status, Obstacles,
Hazards) and **Settings** (Cues, Haptics, Watch, Mount, This phone). Voice control runs through
Siri App Shortcuts and "Talk to OpenCane" on the Action Button. Since Step 35 the work is **cue
design v2**: making the cane calmer, because the owner found the voice choppy and overstimulating.
The demo runs **untethered on the phone**; the Mac only signs and installs. Pitch and hardware:
the root [`README.md`](../README.md).

## 2. What is proven, and what is not

### 2.1 Automated gates at HEAD (Mac, simulator)

Recorded in `CHANGELOG.md` Step 37 and the `076fcaa` / `dd65c6b` commit messages; rerun them
yourself before claiming anything (AGENTS.md "How we engineer" 1).

| Check | Result at `076fcaa` | How to rerun (from `ios/`) |
|---|---|---|
| Logic tests (every rule with a number in it) | **457/457** passed (457 `@Test` annotations in `ios/Logic/Tests`; 6 named `@Suite`s) | `make test` |
| App + watch + widget build, Swift 6 strict | green | `make sim` |
| XCUITests on the iPhone 17 Pro Max / iOS 27 simulator | **11 run, 10 passed, 1 skipped, 0 failures**. The 11 are the 10 in `CaneKitUITests.swift` (including Step 36's `testCuePickersChangeAndRestore`) plus `CaneKitVisualTour.testTour`. The skip is `testWhereAmIDescribesAStreetViewFrame`: CHANGELOG and the commits say "needs a key", but the code's `XCTSkip` fires when `CANEKIT_FRAME_DIR` is unset, so it only runs under `make uitest-streetview` with the local Street View frames | `make uitest` (set a simulator location first, §10.4) |
| GPS replay through the real app | **PASS** (266 s) | `make e2e` (silent: the app mutes itself) |
| Cue audit script fixtures | `cue_audit.py --selftest` ok | `python3 scripts/cue_audit.py --selftest` |

Steps 34, 36, 37 and the rotation fix each had their own adversarial review (multi-agent
workflow, Muse, Antigravity). Step 35 had Muse only: its Antigravity run returned no output and was
retried on Step 36. The findings, fixes
and rejections with evidence are in each CHANGELOG entry. A review is not a device test.

### 2.2 What landed on the app line, Steps 26–37

| Step | What exists now | Commit |
|---|---|---|
| 26 | Team credits: software is Aritro, Aarav and Tejas; hardware is Sagar and Tommy (docs only) | `1724a74`, `2f4e37d` |
| 27 | Three icon-only root tabs (`CKTabBar`, `ios/CaneKit/UI/TabBar.swift`); `make test` compile fix for `#expect` + `mutating` | `e1c2c93` / `a4b4ed0`, `073fc5e` |
| 28 | Sound recognition ("Listen for sirens and horns", off by default) fails safe across its whole microphone lifetime (`SoundRecognitionGuard`) | `a428d66` |
| 29 | "Talk to OpenCane" registered as an App Shortcut, so the Action Button can pick it; warnings lead with distance ("Two meters ahead, door") | `6bac446` |
| 30 | Speech holds while the walker talks (`SpeechQueue.setVoiceHold`); `.safety` still speaks through; `docs/auditory-load.md` | `6bac446` |
| 31 | Instant system-voice answers, "set location / destination" phrases, Sift / Granger aliases, exit-first clause on a weak fix | `6bac446` |
| 32 | Flashlight toggle; why both cameras pause obstacle detection | `6bac446` |
| 33 | Snappy tab switch: 0.16 s fade-in, pill and page land together | `6bac446` |
| 34 | Flashlight settles on KVO (`TorchSwitch`); the both-cameras refusal caption stays visible for the whole route; face tracking refused mid-route (`FaceTrackingChange`); every dispatched line logged as `speech_dispatch` | `d636232` |
| 35 | Cue design v2 research (`docs/cue_design_v2.md`), the approved plan, and `ios/scripts/cue_audit.py` / `make audit` ("measure first") | `61cdb67` |
| 36 | `CueRules` (`CueProfile.swift`): Settings → **Cues** card with Quiet / Standard / Detailed × Outdoors / Indoors, default **Detailed + Outdoors**; obstacle names default **off**. Speech and signs only; haptics are the same at every level until Step 41 | `ec4845a` |
| fix | Both cameras: rotation chosen per camera (`DualCameraRotation`: back fixed at 90, front fixed at 0, never a `RotationCoordinator` angle) | `dd65c6b` |
| 37 | Talk floor: a line cut by a warning resumes from the clause it was cut in (`SpeechResume`, at most 3 resumes), with a 0.35 s pause between different priority bands that `.safety` never waits for; trip log gains `resume_from` and `speech_end` | `076fcaa` |

Hardware line on the same day (Sagar's machine): Step 25 (screwless mount simulated, redesigned
and re-sliced, `scripts/verify_mount.ps1`; the Step 25 entry says 30 checks, the script now prints
32 PASS/FAIL lines on a full run) and the committed G-code / STLs (`0c425de`).
Step numbers 15, 16, 17, 21, 22 and 25 each appear twice in `CHANGELOG.md` on purpose; read the
date and subject, not the number.

### 2.3 Device evidence from trip logs (Sat 2026-09-12)

| Trip log (`canekit-…jsonl`) | Build | What it showed |
|---|---|---|
| `2026-09-12T20-57-17Z` | before Step 34 | The flashlight read `isTorchActive` too early, so every change took two presses. A voice command ("set the location from here to Granger library") had started a real 750 m route, so every Both-cameras press was correctly refused with no visible caption. Face tracking was switched on mid-route (t = 80.7 s). The first cue-load baseline: **handheld** (tilt median 25.8°, only 14 % of frames inside 3–8°), 34 head cues/min, 7.6 unsolicited lines/min, of 360 head-band cells under 1.5 m 349 had the torso equally near, zero head cells in mount-tilt frames. Fixed in Step 34; measured in Step 35 |
| `2026-09-12T22-02-03Z` | preview-angle rotation for both cameras (`1caff45`) | `back_rotation: 0` with the owner's screenshot of a sideways back feed. Led to the per-camera rotation fix |
| `2026-09-12T22-20-53Z` | Step 36 + rotation fix | `back_rotation` 90, `front_rotation` 0, `front_size` 1080x1920. At t = 132–152 s every Cues level and place tap logged one `cue_profile` record and dispatched its line. 5 of 58 dispatched lines were restarts, and 9 line starts were < 1 s apart |
| `2026-09-12T22-27-00Z` | Step 36 | A friend's 37-minute **handheld** walk: 45 "Head height." lines and 4 restarts, including the whole route intro played twice. With 22-20-53Z this led to Step 37 |

Every restart in the last two logs was a `.nav` line cut by `.safety` "Head height." and replayed
from its first word. No log so far was recorded with the phone on the mount, so none of them can
tune a distance.

**Historical: first desk test on the real phone, Fri 2026-09-11 afternoon** (trip logs pulled off
the phone, before the merge that followed):

| Check | Result |
|---|---|
| Signed, installed, launched (free Personal Team) | yes; runs unplugged |
| LiDAR depth, Taptic haptics, mesh classification | all available (`start` event) |
| Obstacle names from the mesh | "table ahead, very close", "seat ahead, two meters" (the wording the walker heard then; Step 29 moved the distance first) |
| Head-height cue | fired and spoken ("Head height.") |
| On-device "Where am I" (no key, no network) | Apple Vision labels + Apple's on-device model, e.g. "Chairs and desks are ahead…" in 0.7 s |
| Depth reports | 30 per second (was 10: a timing bug the phone exposed; fixed) with the 1x camera at 60 fps |
| Heat | nominal during the test |
| Cameras available *with* LiDAR | only the 1x wide camera (up to 60 fps, 1920x1440); no 0.5x ultra-wide, no 120 fps; the front camera can run only as ARKit face tracking |

**Historical: upstream verification before Steps 26–37** (Step 11–12 era): the GPS replay passed
4 of 4 scenarios (clean, missed fence, ±6 m jitter, wrong turn); the real `NavigationEngine` in a
scratch harness gave 0 false "Veer" over 72 simulated walks and caught an injected 35° veer 18/18
(CHANGELOG Step 11); the Logic suite was 146 tests then, 366 at Step 27 and 372 at Step 28.

### 2.4 Still needs the phone

In the order it unblocks the most. Each item is the "test on device" line of its CHANGELOG entry.

1. **Mounted cue baseline (Step 35), blocks all cue tuning.** Walk 2 minutes with the phone **on
   the mount**, plug in, `cd ios && make audit`. It must print "ON THE MOUNT"; its head-band and
   per-minute numbers are the baseline Steps 38–42 are judged against.
2. **Talk floor (Step 37).** Installed on the phone Sat evening; not yet checked. Start the route,
   point the phone at a wall at head height 1 m away mid-sentence: "Head height.", a short pause,
   then the intro continues from its phrase, not "Route started." again. `make audit`:
   `replays_resumed_mid_line` > 0, `replays_from_line_start` only for cuts in a first clause,
   `cross_band_pause_under_0_3s` = 0. Check both voices, then tune `SpeechResume.mp3MarginUTF16` /
   `clipLead` from `resume_from` (todo Step 37 sub-items).
3. **Cues card (Step 36).** Only the level and place switching is proven (22-20-53Z). Still to see:
   Quiet says "Quiet cues." and names nothing even with "Speak obstacle names" on; Indoors says
   "Indoor mode." and does not read an EXIT sign while it does read WET FLOOR / CLOSED; Detailed +
   Outdoors with names on names a door and a table, never a wall; the `start` record carries
   `cue_level`, `cue_place`, `obstacle_names`.
4. **Both cameras rotation (fix `dd65c6b`).** Upright start is proven (22-20-53Z). Still to see:
   start Both cameras with the phone held sideways (CHANGELOG) and flat on a table (commit
   message); the back picture and front inset must be upright each time. Whether buffer dimensions
   swap under `videoRotationAngle` is an open question; `front_size` is logged as evidence only.
5. **Flashlight, both-cameras caption, face tracking (Step 34).** Written and simulator-green; the
   phone went unavailable mid-session, and although the build was installed during Step 35, no log
   since confirms these fixes. Flashlight on, off, on: each
   press moves the switch once and speaks once; a fast off→on gives one confirmation and no "turned
   off". Mid-route, Both cameras bounces and the caption "…Stop the route on the Guide tab first."
   stays; Head tracking without AirPods is refused and spoken. Trip log: `speech_dispatch` for the
   refusal lines and `torch {action: confirmed(on: true)}`. The 2 s settle deadline is a hypothesis
   to confirm here.
6. **Older device items.** Unticked in `todo.md` → "TONIGHT": Action Button → Talk to OpenCane
   (`voice_toggle {source: actionButton}`), distance-first warnings on a walk, the 7 s speech calm
   window, voice hold (Step 30), the blindfold walk to Grainger / Siebel (Step 31), flashlight with a
   route and inside Both cameras (Step 32). Only in the `test on device` lines of their CHANGELOG
   entries: tab-switch feel (Step 33), the sound-recognition AirPods / HFP / permission checklist
   (Step 28), and the Step 25 camera interlock checklist.
7. **Not proven on the cane at all:** LiDAR distances through the clamp, how the haptics feel in
   the hand, the beacon's left / right, wrist-down watch taps, GPS fence timing on campus, heat and
   battery over a 20-minute walk, and the ground-hazard thresholds on real pavement. That is what
   [`stress_test_plan.md`](stress_test_plan.md) is for. Until those pass, **the blindfolded walk is
   a no-go**; a sighted demo is always the fallback.

## 3. Who does what next

The hour-by-hour plan is [`stress_test_plan.md` §1.0](stress_test_plan.md#10-the-next-24-hours).
The app tests are D1–D18 and F1–F12 in that plan; the mount's own bench tests are T0–T11 in
[`hardware/mount/DESIGN.md`](../hardware/mount/DESIGN.md). Do the mount's T-tests before D1.

Teams: software is **Aritro**, **Aarav** and **Tejas**; hardware is **Sagar** and **Tommy**.

**Historical: the assignments written Fri 2026-09-11 for that night and Saturday.** The roles
still stand; the "Tonight" column is from before Steps 26–37.

| Person | Tonight | Saturday |
|---|---|---|
| **Aritro**, **Tejas** (software) | Add Apple ID in Xcode, Developer Mode on phone + watch, `make run` (§4). Bench tests D18 first, then D1–D8, D10, D11, D13, D15–D17. | Logs, fixes, code freeze ≥ 3 h before the demo walk, filming. |
| **Sagar**, **Tommy** (hardware) | Render and print the mount (`hardware/README.md` quick start). Bench tests D1–D5 and D16 with the clamp. Set the tilt by reading the phone (§5). | Spotter on every walk. Power bank, sun shade, heat checks. |
| **Aarav** (software, walker) | Feel the haptic patterns (D2), wear the watch (D11). | Survey walk W1, reference walk W2, blindfolded rehearsal W4. |

**Open work at `076fcaa`** (source: `todo.md`; tick it there, not here):

- **Device checks** in §2.4, the mounted `make audit` walk first.
- **Cue design v2, Steps 38–45** (not started):
  - **38** Head speech episode ends after 2 s of trusted clear frames; no new head speech while
    still (`MotionState`, net displacement < 0.3 m in 2 s, so a cane swinging in place is still).
  - **39** Speech de-chop: interrupted `.obstacle` / `.scene` lines dropped (kept for Repeat), late
    optional lines dropped (> 1.5 s), cue tier always the system voice, rate follows the user's
    Spoken Content setting.
  - **40** Speech budget: unsolicited non-safety lines ≥ 8 s apart, none while still or at a
    crossing; ground hazards pinned to `.safety`; beacon silent when still > 3 s.
  - **41** Torso haptics by level (Standard onset taps, Detailed = today + shoreline suppression,
    Quiet none).
  - **42** "Calm head alerts (test on the cane first)", **default off**: per-cell sample validity,
    overhang signature, band re-fire, same-overhang dedup; a hanging-sign rig test 10/10 before it
    can default on.
  - **43** Hush (Watch double tap + app button + Siri, 60 s, never touches safety cues).
  - **44** "What's ahead?" from LiDAR lanes + mesh class + ground hazard, no vision model.
  - **45** Indoor suggestion after 20 s of GPS accuracy > 30 m, never switching by itself.
  - Safety floor for every one of them: the head haptic at every onset, "Head height." spoken at a
    moving onset, ground hazards (when on) speak their first confirmation, hush never touches them.
- **Deferred, not scheduled:** gravity-corrected metric head band; speed-scaled head distance;
  route distance updates every 15 m; in-app speech-rate override; AirPods stem-press hush.
- **Deferred from the Step 37 review:** a system-voice line resumed from a cached mp3 maps an exact
  word offset to a proportional clip time; the interruption resume retry is not cancelled by a new
  `.began` (pre-existing).
- **Still open from the Step 34 audit:** the conversation fallthrough is not grounded in the scene
  context; the hazard-watch prompt still asks for metres; the AirPods head tracker starts without
  checking headphones; `observeThermalAndBattery` runs before the audio session is configured; the
  background teardown of both cameras has no background-task assertion; the debug sensor-probe +
  demo-route flag clash; Steps 27–33 never had their Muse / Antigravity reviews.
- **Hardware** (Sagar, Tommy): print `coupons_next` to set `thr_clear` / `thr_axial` / `dt_clear`,
  then collar + ring, cradle, arm; decide screwed vs screwless on the day; T7 shake / T8 drop. The
  collar is a closed bore and needs a split collar or removable tip on a real cane (not designed).
- **Post-demo:** an AVFoundation depth pipeline (`AVCaptureMultiCamSession` + LiDAR depth, measured
  as possible on this phone) so both cameras could keep obstacle detection.

## 4. Pull, build, install

```sh
git pull
cd ios
make test          # 457 Logic tests; requires the Swift 6 toolchain
make gen           # generates CaneKit.xcodeproj (git-ignored) and Secrets.plist from the template
make sim17         # once per Mac: the iPhone 17 Pro Max / iOS 27 simulator
make sim           # simulator build
```

To put it on the phone (full list: [`ios/README.md` §1](../ios/README.md#1-day-0-checklist)):

1. Xcode → Settings → Accounts → add your Apple ID (a free Personal Team; installs last 7 days).
   After `make gen`, open `ios/CaneKit.xcodeproj` once, select the **CaneKit** target →
   **Signing & Capabilities** and pick the Personal Team. That creates the Apple Development
   certificate (before it exists, `security find-identity -v -p codesigning` lists nothing).
   The **Team ID** is shown in Xcode → Settings → Accounts → the team's details, or use the `OU=`
   value from `security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject`.
   The 10 characters in parentheses of "Apple Development: Name (…)" are **not** the Team ID.
2. Settings → Privacy & Security → **Developer Mode** on, on the iPhone **and** the Watch.
3. Plug the phone in, tap Trust, then `make devices` and create `ios/local.mk` (values on their own
   lines; a comment after a value broke the first build):
   ```make
   TEAM   = ABCDE12345                # the OU= value from step 1
   DEVICE = 00008150-…                # from make devices
   ```
4. Keys (optional) go in `ios/CaneKit/Resources/Secrets.plist` **before** building; it rides inside
   the app. Never commit it. With no keys everything still works: the system voice speaks and
   "Where am I" runs on the phone. A build from a git worktree gets an **empty** Secrets.plist.
5. `make run`. On the phone: Settings → General → VPN & Device Management → trust the developer
   app, then open OpenCane again.
6. If watch signing or pairing fights you, unblock the phone first: `WATCH=0 scripts/gen.sh`, then
   `make build install launch` (phone-only), and add the watch later ([`ios/README.md`](../ios/README.md)).
7. Follow [`devices_setup.md`](devices_setup.md) for AirPods, the watch, Guided Access and warming
   the voice cache on Wi-Fi (keys must already be in `Secrets.plist`).
8. After a walk, `make audit` pulls the newest trip log off the phone named by `DEVICE` (phone
   plugged in, unlocked, trusted) and prints its cue load; `make audit LOG=path` reads a local file.

## 5. The mount angle (read this, Sagar and Tommy)

**The mount is yours.** `hardware/` is a starting point drafted on the software side (Apple's
dimensional drawings, a pitch model, an OpenSCAD model, test coupons); change anything with your own
CAD, ideas and printing experience. The app only needs these from any mount:

- the phone **upright (portrait)**, rear camera and LiDAR unobstructed and facing forward;
- the camera aimed **3–8° below the horizon** with the cane held normally (the app shows it live);
- firm enough that the phone's buzz is felt in the grip, and nothing magnetic near the phone's
  compass (bottom edge);
- the screen reachable for Guided Access, and the cane shaft out of the camera's view.

The camera must look **3–8° below the horizon, about 5°, not 10–20°.** The obstacle grid ignores the
bottom quarter of the image as "ground" without correcting for gravity. At 10° down or more the
torso lanes see bare pavement near 2 m and the cane buzzes on an empty sidewalk. Level or tilted
up, the drop-off detector loses its ground reference. The numbers are in
[`hardware/mount/DESIGN.md`](../hardware/mount/DESIGN.md) and `hardware/mount/pitch_model.py`.

You set it by reading the phone: **Settings tab → Mount card**, first line
`Camera tilt 5° down, good · N fps` (N is live, about 30). Hold the cane the way Aarav holds it and
click the hinge until it says **good**; chase "good", not the fps. The same number is in every
trip-log `lanes` line as `tilt`, and `make audit` uses it to decide whether a walk was on the mount.
Every field log so far was handheld, so the mount is now what unblocks cue tuning.

## 6. What is on, what is off, and why

Defaults read from `AppModel` at `076fcaa`. Toggles that persist keep the walker's last choice; the
flashlight, both cameras, face tracking, sound recognition, nod to talk and live camera view start
off at every launch.

| Setting (tab → card) | Default | Why |
|---|---|---|
| Cue detail (Settings → Cues) | **Detailed** | Owner decision: today's behaviour until a mounted log tunes the calmer levels. Detailed's one change from before: it never names walls |
| Place (Settings → Cues) | **Outdoors** | Head distance 1.5 m outdoors; Indoors is 1.2 m, names nothing and reads only safety signs |
| Obstacle cues on the cane (Settings → Haptics: "Silence haptics" mutes them) | on | The core product |
| **Speak obstacle names** (Settings → Haptics) | **off** (Step 36) | Research #2 in `cue_design_v2.md`: names are the lowest-value speech. Walkers who never touched the switch lost names; D6 in the stress plan says to turn it on |
| Mirror obstacle cues to the watch (Settings → Watch) | off | Opt-in |
| Phone held upright (portrait) (Settings → Mount) | on | The clamp holds the phone upright; turn off only if it is clamped sideways |
| Mirror left / right (Settings → Mount) | off | Turn on if a left obstacle buzzes as right (bench test D1) |
| 60 fps camera (warmer) (Settings → Mount) | off | Heat untested over a long walk |
| Audio beacon while navigating (Settings → Mount) | on | Plays only into headphones |
| Write trip log (Settings → Mount) | on | Every test needs a log; Files → On My iPhone → OpenCane |
| **Detect drop-offs** (Sense → Hazards) | **off** | Untuned on a real cane |
| Read signs (Sense → Hazards) | on | On-device, offline, once a minute per phrase; Quiet and Indoors read only safety phrases |
| **Hazard watch** (Sense → Hazards) | **off** | Every 8 s while walking; on-device labels are weak (§8), the cloud needs a key and network |
| Name people ahead (Sense → Hazards) | on | Direction and a LiDAR-measured distance |
| Listen for sirens and horns (Sense → Hazards) | off | Needs the microphone; fails safe to off (Step 28); AirPods case unmeasured |
| Nod to talk, Head tracking without AirPods (Sense → Hazards) | off | Opt-in experiments; face tracking is refused while a route guides (Step 34) |
| Live camera view (Sense → Hazards) | off | For a sighted helper and the demo video |
| Both cameras (pauses obstacle detection) (Sense → Hazards) | off | Pauses ARKit, so it is refused while a route guides |
| Flashlight (Sense → Hazards) | off | Never persisted (pocket heater risk); works mid-route |

## 7. Decisions already made (do not re-open without new evidence)

- **Phone-only, buy nothing.** The ESP32 grip, ToF pod (`firmware/`, `cad/`, `ios/stretch/`) are
  stretch only. Why: [`ideas.md` §9](ideas.md).
- **No Gemma / MLX on the phone.** Gemma 4 E2B/E4B would need third-party packages and a 2.5–3.6 GB
  download, and the only Swift port found is macOS-only. "Where am I" uses Apple Vision + Apple's
  on-device language model instead (template sentence when Apple Intelligence is off), with the
  cloud model first when a key is set.
- **The front camera never does scene work.** It faces the walker on the cane, and ARKit owns the
  capture pipeline. It has two opt-in jobs, both off by default: head tracking without AirPods
  (ARKit face tracking, no picture) and Both cameras (`AVCaptureMultiCamSession` with ARKit paused;
  ARKit can never deliver two pictures).
- **Both-cameras rotation is fixed per camera** (back 90, front 0). Three earlier fixes used one
  `RotationCoordinator` angle for both feeds and each broke the other one; do not unify them again.
- **Cue design v2 (approved Sat evening):** default Detailed + Outdoors until a *mounted* log tunes
  the numbers; speech calming ships on; every new haptic behaviour ships behind a level or setting
  that defaults to today; the overhang signature ships off until the rig test passes on the cane.
- **"Head height." stays instant (Step 37).** Holding it behind a direction was rejected: a walker
  reaches a 1.5 m overhang in about 1.5 s, before the words. The owner chose "cut in, then resume"
  for directions, and "leave as is" for walls, which still get "Head height." until Step 42.
- **CI is manual-trigger only.** GitHub Actions billing is exhausted; the local `make` gate is
  authoritative ([`ios/README.md` §5](../ios/README.md#5-testing)).
- **Everything that looks like a bug but is deliberate** (fences firing early, veer muted at
  corners, the 30 s curb repeat, the arrival hint, …) is listed in
  [`AGENTS.md`](../AGENTS.md) → "Things that look wrong but are deliberate". Read it before
  "fixing" navigation, speech or hazards.

## 8. Google Street View mock of ISR → CIF

We cannot walk the route from a laptop, so 14 Google Street View captures of the route stand in for
the camera in the simulator (`FrameReplay`, simulator only, inert on the phone). The JPEGs are
**local-only (git-ignored, Google imagery)**; `ios/scripts/streetview/frames.json` lists where each
was taken and [`ios/scripts/streetview/README.md`](../ios/scripts/streetview/README.md) says how to
capture your own.

| Command (from `ios/`) | What it proves |
|---|---|
| `swift scripts/vision_probe.swift scripts/streetview` | What the on-device camera would say at each corner (labels, text, sign line, hazard line), on the Mac |
| `make uitest-streetview` | "Where am I" answers with a sentence from a real street frame (the one UI test plain `make uitest` skips) |
| `make e2e SCENARIO=streetview` | The clean route walked with the Street View frames as the camera; the report lists every sign / hazard line spoken |

What it found and fixed (historical, `CHANGELOG.md` Step 12 and
[`ios/scripts/streetview/README.md`](../ios/scripts/streetview/README.md)): Vision taxonomy words
read aloud, Apple's on-device model inventing "Distance: zero meters", sign range (now measured:
7.5 cm letters ≈ 7 m on a flat frontal sign), STOP signs and far storefront words, and a camera
path the log could not see.

**Diagnosed:** scene recognition cannot be tested in the *simulator* at all. Vision's scene
classification fails there with "Failed to create espresso context" (the simulator has no
neural-network context; the `vision_error` field in the trip log's `describe_result` records it).
That is a simulator limit, not a phone bug: the same frames classify fine on the Mac
(`vision_probe.swift`), and the phone has the Neural Engine. A CPU-only fallback was tried and
removed again: it returned all 1,303 labels at ~0 confidence, so the Street View mock does not
exercise the scene words. Scene words are covered by `ios/scripts/vision_probe.swift` on the Mac,
`SceneVocabularyTests` (logic tests) and the phone. Still, **check "Where am I" on the real phone
first thing** (stress plan D17): it should name what is there.

## 9. How to find anything

- **Install the graph tool once:** `uv tool install graphifyy` (or `pipx install graphifyy`); the
  command is `graphify`. The graph is committed in `graphify-out/`, so queries work right after a
  pull. The committed `graphify-out/GRAPH_REPORT.md` (refreshed in `e459b3a`) says it was built
  from `076fcaa8`, so it includes `TorchSwitch`, `CueRules`, `DualCameraRotation` and
  `SpeechResume`; compare it with `git rev-parse HEAD` and run `graphify update .` after any code
  change.
- **Ask the knowledge graph first:** from the repo root, `graphify query "how does a curb warning reach
  the speech queue"`, `graphify path "HazardScanner" "SpeechQueue"`, `graphify explain "TurnSettle"`.
  Communities are listed in `graphify-out/GRAPH_REPORT.md`; `graphify-out/graph.html` opens in a
  browser.
- **Every file, type and function:** [`CODE_REFERENCE.md`](CODE_REFERENCE.md).
- **Every doc and when to read it:** [`docs/README.md`](README.md).
- **What landed when, and each step's device test list:** [`CHANGELOG.md`](../CHANGELOG.md).
- **What is still open:** [`todo.md`](todo.md) → "Cue design v2" (Steps 35–45) and the open
  findings list near the top.
- **Why the cues are changing:** [`cue_design_v2.md`](cue_design_v2.md) (74 source-checked
  findings, the violations table V1–V9, the ranked change list, the field-log addendum) and
  [`auditory-load.md`](auditory-load.md).
- **How loud a walk was:** `cd ios && make audit` (`ios/scripts/cue_audit.py`).

## 10. How an agent resumes (and how we work)

The engineering bar is [`AGENTS.md` → "How we engineer"](../AGENTS.md). This section is the
checklist version for picking up the next cue v2 step.

### 10.1 Read order

1. `AGENTS.md` (hard rules, "How we engineer", the traps, "Things that look wrong but are
   deliberate") and `CLAUDE.md`.
2. `docs/CODE_REFERENCE.md` for the module you will touch.
3. This file, then `docs/todo.md` → "Cue design v2" for the step you are taking, and its research
   in `docs/cue_design_v2.md` (§3 is the design, §4 the ranked list with the test names it expects).
4. The newest `CHANGELOG.md` entries (Step 37 at the top), for what the last step deferred.
5. `graphify update .`, then `graphify query "…"` to find every caller of what you change.

### 10.2 Measure first

Before tuning any cue number, get evidence from a trip log: `cd ios && make audit` (runs
`cue_audit.py --selftest`, then `--pull` copies the newest `canekit-*.jsonl` off the phone named by
`DEVICE` in `ios/local.mk`), or `make audit LOG=path/to/log.jsonl`, or
`python3 scripts/cue_audit.py --json log.jsonl`. It reports whether the walk was ON THE MOUNT, the
head band wall vs overhang (all frames and mounted frames only), cues and lines per minute,
suppressed lines, `speech_dispatch` replays (mid-line vs from line start), cross-band pauses under
0.3 s, and any `field_kind` / `field_t` app bug. A handheld log must not tune a distance. If a
constant moves in `CaneKitLogic`, move it in `cue_audit.py` too.

### 10.3 The per-step bar

1. **Plan as a checklist** in `docs/todo.md`; for a large or risky change, review the plan with
   Muse before building.
2. **Tests first in `ios/Logic`.** Every rule with a number is a pure `CaneKitLogic` type with a
   Swift Testing test written before or with the code; a bug fix starts with a failing test. The
   app types (`SpeechQueue`, `AppModel`, `HapticPlayer`) stay thin owners of state and timing.
3. **Build and verify silently:** `make test`, `make sim`, `make uitest` (and `make tour`) for UI
   changes, `make e2e` (plus `SCENARIO=streetview` when the camera path changed), all on the iPhone
   17 Pro Max / iOS 27 simulator. Automation is muted (`CANEKIT_MUTE=1` / `CANEKIT_UITEST=1`).
4. **Adversarial review, three independent reviewers, then verify every finding yourself:**
   a multi-agent workflow (finders + skeptics), **Muse** (`muse exec … --workspace <scratch>`,
   read-only), and **Antigravity** (`agy -p …`) pointed at a **copy** of the repo, because it has
   edited files despite a read-only prompt. Keep prompts small and on the diff. Fix what is real;
   reject what is not with evidence in `CHANGELOG.md`.
5. **Same commit:** code, tests, `docs/CODE_REFERENCE.md` (every file header, type and function doc
   comment), `CHANGELOG.md` (why, what changed, review, verification, a `test on device:` line),
   `docs/design.md` when a cue or UI changes, `docs/todo.md` ticked, AGENTS.md rule 9 when an
   accessibility label changes, and `graphify update .`.
6. **Commit message ends with `test on device: …`.** New untuned behaviour ships **off by
   default** (or behind a level that defaults to today). Never trade guidance away for a stricter
   check, and never speak something the sensors did not see.

### 10.4 Traps that already produced a false green or a lost hour

- ⚠ Never verify a command through `tail`: `make test | tail -8` once printed a passing summary
  while the build failed. Redirect to a file, check the command's own exit code, grep `error:`.
- ⚠ `#expect` cannot call a `mutating` member; hoist the call into a local first.
- ⚠ `make uitest` / `make tour` need a simulator location first
  (`xcrun simctl location <udid> set 40.1140,-88.2249`), or the route tests fail.
- ⚠ Never run two simulator jobs at once; concurrent `make uitest` and `make e2e` produced a bogus
  "harness error". Use `make uitest SIM="iPhone 18 Pro"` beside someone else's run.
- ⚠ `xcodebuild` can hang after "All tests passed" (seen in Step 36 and with `make tour`):
  `xcrun simctl shutdown all` and retry.
- ⚠ A worktree build ships an empty `Secrets.plist` (git-ignored), so it silently loses the keys.
- ⚠ Speech strings are prefetched by bytes (`AppModel.commonLines`); change a spoken line in both
  places or it falls back to the system voice.

## 11. Known risks going into the walk

- **No cue number has been tuned on the mounted cane.** Every field log is handheld. "Head height."
  still fires on walls, doors and people inside 1.5 m (`cue_design_v2.md` V1: the head band is
  image rows with no gravity correction and no torso check); the friend's 37-minute handheld walk
  heard it 45 times. Steps 38–42 address it.
- Drop-off warnings and the hazard watch are extras until the D-tests pass; the lanes, haptics,
  route and watch are the product.
- Ramps steeper than ~11 % can read as a drop-off or step (the price of catching curb faces that
  fall mid-bin). ADA ramps (≤ 8.3 %) stay quiet in tests.
- The screen is exposed on the cane: use Guided Access so a brush cannot hit Stop. To arm it
  (Settings → Accessibility → Guided Access on, passcode set), triple-click the side button in
  OpenCane → Options: **Touch Off, Side Button Off, Volume Buttons Off, Keyboards Off, Motion On** →
  Start. While armed the watch (Repeat / Next / Describe / Recenter) is the only input. "Where am I"
  from the Action button may be blocked too (it is a hardware button; stress plan D16 records
  whether it works), so use the watch's Describe.
- ARKit stops when the screen locks; the app keeps the screen on while open.
- A voice command can start a real route (20-57-17Z: "set the location … to Granger library"
  started a 750 m route), and a running route refuses Both cameras and face tracking.
- Compass readings on the cane are only trusted when the cane is still; while walking > 0.7 m/s the
  veer decision uses the smoothed GPS course.
- Tree canopy and buildings on Goodwin / Springfield can push GPS past 20 m; the app says "GPS weak"
  and pauses fences rather than guess.
- **Historical:** by Step 12, five adversarial review rounds by Claude workflows, Muse and
  Antigravity had run, with every finding fixed or rejected with evidence in `CHANGELOG.md`. Since
  then Steps 34–37 each had their own review; Steps 27–33 still have not had Muse / Antigravity.
