# CaneKit — strict build checklist

Legend: `[ ]` open · `[x]` done · `[~]` written, not yet compiled/tested · `[!]` blocked on a person

---

## WHERE WE ARE — Fri 2026-09-11, 19:45 (read this first)

Demo: Sat 2026-09-12. The app runs untethered on Aritro's iPhone 17 Pro Max (iOS 27), clamped to a
cane, with AirPods Pro. **This block is rewritten on every push; if it contradicts an older section
lower down, this block is right.**

### What is proven ON THE PHONE (measured, from trip logs in `Documents/`)

| Thing | Evidence |
| --- | --- |
| LiDAR depth, mesh names, haptics, head-height cue | `start` record: `lidar: true, mesh: true, haptics: true`; speech records "window ahead, one and a half meters", "table ahead, half a meter", "Head height." |
| Depth at 30 reports/s | `lanes.fps` median **29.988** (was exactly 10.0 before the `PublishGate` timing fix) |
| Both cameras at once — ⚠ **superseded evidence** | The `both_cameras` records (`supported: true, front: true, back: true, error: ""`, `hardware_cost: 0.26`, and after stopping `depth_running: true, depth_fps: 30, status: "Depth OK"`) were measured against the **preview-layer** version, which no longer exists: the feeds now render from `AVCaptureVideoDataOutput` into `AVSampleBufferDisplayLayer` because a preview layer makes LiDAR depth unreliable (Apple forums 742501). What still carries over is that multi-cam is supported and that ARKit resumes cleanly after the mode stops. **Whether the two feeds actually draw has never been seen on hardware.** |
| Trip-log field collision fixed | zero rows carry `field_kind` / `field_t` |
| ElevenLabs (Bella) reachable | key verified `HTTP 200`, free tier 0/10 000 chars; a real 9 kB mono mp3 at 22.05 kHz came back for the app's exact payload |
| Muse Spark 1.3 reachable + multimodal | key verified `HTTP 200` from `muse-spark-1.3-contributor`; docs confirm `/v1/chat/completions` and image understanding |

### MEASURED ON THE PHONE: both cameras AND depth is possible, without ARKit

The `multicam_depth` probe ran on Aritro's iPhone 17 Pro Max (iOS 27) on 2026-09-12 and answered the
question Apple's documentation could not:

```
multicam_supported:    True
front_plus_depth_sets: 12
device_sets:           front:BuiltInWideAngleCamera + back:BuiltInLiDARDepthCamera  depth 320x240
                       front:BuiltInTrueDepthCamera depth 640x480 + back:BuiltInLiDARDepthCamera
depth_multicam_formats: 33
best_format:           video 640x480, depth 320x240
arkit_depth_size:      256x192
keeps_depth:           True
verdict:               depthAboveARKitResolution
```

**Twelve multi-cam device sets pair the front camera with a depth-capable back camera**, including
the wide-angle front camera with the LiDAR depth camera. Apple's own sources only ever name the rear
Telephoto and Ultra Wide as the second camera (WWDC22 110429; DTS forum 702875), so this had to be
measured. AVFoundation's streaming LiDAR depth is **320×240 — higher than ARKit's 256×192**.

**What this means:** the current design pauses ARKit to show both cameras, because ARKit itself can
never hand over two images (Apple DTS, forum 677731). But a future version could run
`AVCaptureMultiCamSession` with `builtInLiDARDepthCamera` + the front camera, take depth from
`AVCaptureDepthDataOutput`, and have **both feeds and working obstacle detection at once.**

**What it would cost — a real rewrite, not a switch:** no ARKit means no world tracking, no
classified mesh (the source of "door" / "wall" / "table"), no per-pixel `confidenceMap`, and no
gravity-aligned world — gravity would come from `CMDeviceMotion.gravity` instead, and the depth map
would need rectifying with `AVDepthData.cameraCalibrationData` (it is non-rectilinear, unlike
ARKit's). Also: no `AVCaptureVideoPreviewLayer` anywhere near it (forums 742501), and
`systemPressureCost` must stay under 1.0 to run indefinitely.

- [ ] **Post-demo:** prototype the AVFoundation depth pipeline behind a setting and compare it with
      ARKit on the same walk — obstacle-cue parity first, then whether the extra depth resolution
      buys anything a cane user can feel.

### What is NOT proven on the phone yet

- People/animal detection (Vision's neural models cannot run in the simulator — phone-only).
- **That the two camera feeds actually appear.** The render path was rewritten after the only device
  run, so it is unproven; if it shows black, the fallback is Metal or `CIContext`, never a preview
  layer.
- The `.playAndRecord` microphone switch **with AirPods connected**. It was measured only with no
  headphones (output stayed `Speaker`, restore worked). The revert-on-route-change guard exists
  precisely because the AirPods case is unmeasured.
- The `multicam_depth` probe's answer — whether a future version could show both cameras *and* keep
  depth through AVFoundation instead of ARKit. The probe is in the build and has never run.
- The Muse scene sentence end to end after tonight's reasoning-token fix.
- Ground hazards (drop-offs, potholes) on real pavement; still **off by default**.
- Sound recognition (sirens, horns) and front-camera head tracking; both **off by default**.
- The outdoor ISR → CIF walk.

### Honest capability table — what the demo can and cannot claim

| Hazard | Mechanism | Status |
| --- | --- | --- |
| Poles, signs, branches, open doors (waist-to-head) | LiDAR geometry, no model | **Works, verified on device.** The strongest claim we have |
| Drop-offs, potholes, curbs, steps | LiDAR ground geometry | Built + tested, tilt-gated against the false "Hole ahead"; off by default, untested on real pavement |
| People, dogs, cats + direction + measured distance | Apple `DetectHumanRectanglesRequest` / `RecognizeAnimalsRequest` + LiDAR box depth | Built, 206 Logic tests, **never run on hardware** |
| Signs, crosswalk push-buttons | Vision OCR, measured to ≈ 7 m for 7.5 cm letters | Works |
| **Cars, bikes, ice, puddles, construction** | **No Apple detector exists.** Only the 1 303-label classifier — which returned *zero* usable labels on the phone — or a vision-language model | **Needs the Muse key, which is now wired.** Verify on device before claiming it |
| Route guidance, veer, crossings | GPS + MapKit + compass | Works; the veer regression below is being fixed |

**The line to say out loud at the demo:** *the model names things; LiDAR measures them. No number the
sensors did not see is ever spoken.*

### Keys (git-ignored `ios/CaneKit/Resources/Secrets.plist`, never committed)

- `ELEVENLABS_API_KEY` — set. Voice `EXAVITQu4vr4xnSDxMaL` (Bella), model `eleven_flash_v2_5`,
  settings stability 0.4 / similarity 0.75.
- `CUSTOM_*` — set to Meta Model API: `https://api.meta.ai/v1`, `muse-spark-1.3-contributor`,
  `VLM_PROVIDER = custom`. Key format is **pipe**-delimited (`LLM|<digits>|<chars>`).
- ⚠ **Rotate both keys after the event** — they were pasted into a chat transcript.
- ⚠ A build made in a git worktree gets an **empty** Secrets.plist (the file is git-ignored), so an
  agent's build silently loses both keys. The keys have been copied into every `cane-wt-*` worktree;
  do the same for any new one, or install only from the main checkout.

### Branch state (updated 2026-09-12 morning)

**Merged into main and verified (316 Logic tests, simulator build clean, `make uitest` green):**
- the destination-search rework + its accessibility fix
- `fix/cloud-scene-gate` — the cloud sentence is gated, and Muse Spark can actually answer
  (`max_tokens` 120 → 1024 and `reasoning_effort: "low"`; it was spending the whole budget
  reasoning and returning nothing after 11 s)
- `feat/detect-people` — people and animals named with direction and a LiDAR-measured distance
- the widget-embed fix: **the Live Activity had never been in any installed build**
- `fix/voice-consistency` — 74 warning lines prefetched so warnings stop alternating voices
- `fix/veer-gap-regression` — a veer episode is continuous evidence, not continuous samples
- `fix/launch-crash` — no optional feature may keep the app from starting (the Hazards-toggle crash)
- `fix/sound-watch-hardening` — six confirmed microphone defects fixed, incl. the crash
- `feat/all-sensors` + safety fixes — both cameras, front-camera head yaw, danger sounds, all off by default
- `feat/rename-opencane` — the product is OpenCane, the code is still CaneKit
- front-camera rotation, first attempt (0f32282) — coordinator angle, still tilted on device

**Step 16 gate GREEN (2026-09-12 ~01:00):** 347 Logic tests passed, device build + install on
the iPhone 17 Pro Max succeeded. The gate caught one real bug from the hand-merge: `\(.$state)`
in the SilenceHapticsIntent phrases (missing `\` escape — fixed in `99f0a37`). Branches retired.
Still to do on the phone: siren ~1.5 s behavior, "How is OpenCane doing" order, Both-cameras
inset re-check after reinstall.

**Committed in the main checkout:**
- `ios/CaneKit/Depth/DualCameraSession.swift` — capture-angle-first rotation, unmirrored front
  inset, `front_rotation` / `back_rotation` / `front_mirrored` in diagnostics (Step 15).
  Device build green, 316 Logic tests green, front inset verified on the phone.
- Emergency sirens — `SoundAlerts.swift` + tests (verbatim), `SoundWatcher` + `AppModel`
  wireSounds/commonLines (merged, renames kept).
- Hands-free — `HandsFreeIntents.swift`, `QuestionPrompt` / `StatusSummary` + tests,
  `docs/handsfree.md` (new); `AppIntents` 10-shortcut list, `VLMClient.cloudPrimary`,
  `SceneDescriber` ask path, `describe_result` question field (merged).
- Conversational voice assistant — `TalkToOpenCaneIntent`, `VoiceInputEngine` (SFSpeechRecognizer with Hard Rule 7 audio safety), `ConversationCoordinator`, `ConversationModels`, `FastPathIntentClassifier`, `ConversationPrompt`, `WalkMarker` post drops, and rolling context memory (Step 23). The current checkout has 366 Logic test annotations; upstream's original 359-test verification remains historical until rerun on Swift 6/Xcode 27.
- `CHANGELOG.md` (Step 16, 23), `docs/CODE_REFERENCE.md` (DualCameraSession, SoundAlerts,
  QuestionPrompt/StatusSummary, HandsFreeIntents, ConversationModels, VoiceInputEngine, cloudPrimary sections; AppIntents rewritten;
  stale 8/12 s timeouts and stale test-count references fixed; the current target has 366 `@Test` annotations).

**Committed on a branch, not yet merged:**
- `feat/fm-image-describe` — Apple's on-device model with the image (experiment, off by default).
  **Deliberately held**: it conflicts with the people-detection work in the same files and buys
  nothing for the demo.

**Branches (2026-09-12 cleanup):** 11 merged branches deleted, then `feat/emergency-alerts` +
`feat/handsfree` retired after the Step 16 gate went green (347 Logic tests, device build +
install). Remaining: `main`, `feat/fm-image-describe` (deliberately held, conflicts with
people-detection), `feat/multicam-depth` (worktree has uncommitted DepthEngine changes — triage
separately), `experiment/gemma-cactus` (untracked `CactusCodec` + bench script — triage
separately). New remote branch `feat/screwless-mount` (teammate) — not ours, do not touch.

**Worktrees:** only the 3 kept ones remain (`-emergency`/`-handsfree` backups removed with their
branches after the gate; 11 orphan dirs deleted from `~/Downloads`).

### Open findings from the Muse review of the sensor layer (2026-09-11, xhigh)

Twelve findings; three were fixed on the spot (a failed both-cameras start left the walker with no
obstacle detection; "Obstacle detection is back" was spoken before it was true; the microphone
setting persisted across launches). **Every one below is in a feature that is OFF by default**, so
none blocks the demo — but they are real, and several need the phone to judge.

- [x] **Camera-transition route-start interlock (Step 25).** `beginRoute` now waits for the
      serialized two-camera teardown, then requires three consecutive same-frame reports with
      `.normal` tracking, valid scene depth and the existing sweep trust bit. `DepthReadiness`
      resets on interruption/pause/resume/reconfiguration and times out after 5 s; queued starts
      resume automatically when ready and fail loudly otherwise. The adapter drains the old AR
      delegate queue at every reconfiguration, publishes every frame in 60 Hz mode, rejects
      newest-only stream gaps in pure `DepthFrameContinuity`, and exposes an observable **Cancel
      route start** action. The intentional no-LiDAR and camera-denied degraded paths still guide
      with an explicit obstacle-warning notice.
- [ ] **The microphone route guard checks once, synchronously.** `setMicrophoneEnabled` compares the
      output route immediately after `setActive(true)`, but iOS settles the route ~0.5 s later — so
      an AirPods flip to HFP would pass the check. Subscribe to route-change notifications for the
      whole time the mic is on and revert on any change. (The AirPods case is still unmeasured; this
      is the finding most likely to bite when it is.)
- [ ] **Analyzer death keeps the microphone session open.** `SoundWatcher`'s failure path sets
      `lastError` only: `isRunning` stays true, the session stays `.playAndRecord` (orange dot,
      degraded beacon), and no alert ever fires again. It should `stop()` and revert.
- [ ] **Permission race can start the mic after the user turned it off.** The `.undetermined` branch
      restarts unconditionally in the permission callback, so toggling on → off → "Allow" records
      with the switch showing off. Check a generation counter or the live toggle first.
- [ ] **Face tracking re-runs the AR session mid-route with no warning** (~1–2 s without frames).
      The two-camera mode correctly refuses during a route; this path does not.
- [ ] **The mic input format is read synchronously before the route settles**, so the first-ever
      enable with AirPods can fail spuriously with "No microphone input available". Re-read after
      the engine starts, with one short retry.
- [ ] **"Degrades to the back camera alone" is documented but not implemented** — on a phone without
      multi-cam the mode shows no picture. Implement the single-session fallback or correct the
      header and the card copy.
- [ ] **Backgrounding enqueues the camera teardown**, so if the system suspends first the app can
      hold both cameras in the background. Tear down best-effort with a timeout before pausing depth.
- [ ] **Debug-only:** launching with both the sensor-probe and demo-route flags guides a route for
      ~40 s with no depth, and the probe's 40 s announcement queues ahead of route lines with a 20 s
      TTL.

### The merge gate (nothing lands on main that fails any step)

1. `cd ios/Logic && swift test` · 2. `make sim` · 3. `make uitest` (muted) · 4. `make e2e` (4 scenarios)
· 5. Muse + Antigravity over the **merged whole**, every finding verified by hand before acting
· 6. install on the phone and confirm from the trip log.

⚠ Never run two simulator jobs at once — concurrent `make uitest` and `make e2e` produced a bogus
"harness error: No such file or directory" that looks like a real failure. Use
`make uitest SIM="iPhone 18 Pro"` to work alongside someone else's run.

---

## Step 0 — phone-only reset
- [x] Push 3 commits to origin/main
- [x] Docs rewritten (README, ios/README, ideas §5.1), CHANGELOG, .gitignore
- [x] CaneBLE.swift → ios/stretch/, old drafts → ios/drafts/
- [x] Muse review of plan (2 passes) + of the Step 0 diff
- [x] Xcode 27 RC installed (27A266a), license accepted, xcode-select set, XcodeGen 2.46.0
- [ ] Apple ID added in Xcode → Accounts; TEAM id in `ios/local.mk`
- [ ] Developer Mode on iPhone + Watch; `make devices` shows the phone; DEVICE in `ios/local.mk`

## Step 1 — project scaffold
- [x] `ios/Logic` SwiftPM package: LaneMath, LaneReport, CueDecider, GeoMath, Waypoint/RouteBuilder, WatchMessage, VLMCodec
- [x] Unit tests written (6 files, ~45 assertions groups)
- [x] `make test` green (43 tests) — `scripts/test.sh` works around the missing CLT overlay
- [x] project.yml (iOS + watch targets, plist keys, Swift 6 + approachable concurrency)
- [x] scripts/gen.sh (XcodeGen + watch-embed patch + Secrets copy + WATCH=0 mode), Makefile, Secrets.example.plist
- [x] App scaffold: CaneKitApp, AppModel (capability checks, settings), ContentView; watch app scaffold
- [x] Review workflow findings on Logic folded in (3 bugs fixed, 6 tests added → 49 green)
- [x] Muse review of the Steps 1–2 diff (start() idempotent, ARError codes, face budget, CKCard label)
- [ ] `scripts/gen.sh` → `make build` → `make install` on the phone; watch app installs
- [x] Commit "Steps 1–2 (pre-device)" + CHANGELOG entry
- [x] Simulator build green (Swift 6 strict)
- **test on device:** app shows "LiDAR OK — ready" with three green capability rows; watch shows "OpenCane / Waiting for the phone"

## Step 2 — DepthEngine
- [x] DepthFrameProcessor (historical Step 2 baseline: ARSession delegate on a background queue, gyro gate, 15 Hz, AsyncStream; current pipeline is 30 Hz normal / 60 Hz high-rate)
- [x] DepthEngine (main-actor owner: start/pause/resume, video format, thermal hook, fps)
- [x] LaneGridView / DebugView (6 tiles, TRUSTED pill, fps, |ω|, thermal, battery, portrait/mirror toggles)
- [x] CameraControlInteraction spike (AVCaptureEventInteraction) — log whether it fires under ARKit
- [ ] Build, install, run the test list; Muse review; commit
- **test on device (historical Step 2 baseline):** wall at 1 m ≈ 1.0 in all six tiles; hand at left edge → Left tiles red; raise hand → Head row; swing cane → TRUSTED off; fps ≈ 15; Camera Control press shows "CC event" (or not — record which). For the current pipeline use the Step 25 cadence/interlock checklist.

## Step 3 — Core Haptics
- [x] HapticPlayer (CHHapticEngine, pre-built players, Geiger loop, reset/stopped handlers, isHealthy) — compiles, untested on device
- [x] CueRouter in AppModel (CueDecider → player, silence toggle, trip log) + HapticsCard test buttons
- [ ] **Milestone: walk at a wall → the cane shakes** (go/no-go for steps 7–9)

## Step 4 — Speech + obstacle names
- [x] SpeechQueue (priority, interruptible, one audio session), ObstacleNamer, MeshClassifier (≤ 4 Hz) — compiles, Muse-reviewed, untested on device

## Step 5 — Watch
- [x] PhoneWatchLink (WCSession), WatchModel (haptics map, crown, HKWorkoutSession, buttons), cue mirroring — compiles, Muse-reviewed, untested on device

## Step 6 — Navigation
- [x] LocationService, NavigationEngine (GeofenceTracker + OffCourseDetector), route file, MapKit fallback — **verified in the simulator GPS replay**

## Step 7 — Beacon
- [x] BeaconEngine (AVAudioEnvironmentNode, mono click), HeadPoseTracker (CMHeadphoneMotionManager + Recenter) — compiles, Muse-reviewed, needs AirPods on device
- [x] ElevenLabs natural voice with cache + prefetch, AVSpeech fallback (needs key)

## Step 8 — Scene description
- [x] VLM clients (custom/Anthropic/Gemini/OpenAI), Secrets, SceneDescriber, WhereAmI App Shortcut — compiles, Muse-reviewed; needs a key + device

## Step 9 — Arrival, Live Activity, thermal, battery
- [x] TripTracker (HealthKit + pedometer), LiveActivityController + widget target, thermal downgrade (in AppModel since step 2), ArrivalCardView — compiles, Muse-reviewed

## Step 10 — Review fixes + UI tests (pre-device)
- [x] Round-1 full-app adversarial review (65 agents) + fixes
- [x] Round-2 review of the fixes (5 dimensions, 31 findings) + fixes, incl. unverified ones on inspection
- [x] TurnSettle / StraightWalkDetector / CueSpeechPolicy / CrownAccumulator extracted to Logic with tests (79 green)
- [x] Geofence skip-ahead, passed-by wording, leg bearing near waypoints, two-hit plausible arrival
- [x] Speech: priorities, single replay, Repeat bypasses coalescing, interruption queueing, no network wait for warnings
- [x] AirPods route monitor (beacon only in headphones, spoken connect/disconnect), channel check at route start
- [x] Watch: layout fits 42–46 mm, crown window, version-skew reply, status every fix
- [x] XCUITests (6) + screenshot tour on the iPhone 17 Pro Max / iOS 27 simulator; watch screenshot on a paired watchOS 27 sim
- [x] AGENTS.md, CLAUDE.md, docs/devices_setup.md, docs/CODE_REFERENCE.md, CI workflow
- [x] Muse review of the final Step 10 diff folded in (9 of 11 fixed; 2 refuted with evidence)
- [x] Commit "Step 10 (pre-device)" + push (1de6efb)
- **test on device:** see CHANGELOG Step 10 and docs/devices_setup.md

## TONIGHT (live checklist, Fri 2026-09-11 evening; updated with every push)

Phone: iPhone 17 Pro Max (iOS 27.0) connected, signed with the free Personal Team, app installed.

- [x] First real-phone desk test: LiDAR, haptics, mesh names, head-height cue, on-device "Where am I" work
- [x] Depth 10 → 30 reports/s (PublishGate timing bug found on the phone)
- [x] Camera: measured what ARKit allows with LiDAR (1x wide only, ≤ 60 fps, no 0.5x/120); full 4:3 frame
- [x] "60 fps camera (warmer)" switch on the Mount card, off by default (heat untested over a long walk)
- [x] "Where am I" uses one LiDAR snapshot (the phone mixed two moments)
- [x] False "Hole ahead" indoors: ground hazards judged only with a mount-like tilt (0-15 deg) and a
      plausible ground height (0.5-1.3 m below the camera); drop-off and hole frames agree as one hazard
- [x] Screen-lock warning once per route (no spam); Muse + Antigravity final-review fixes
- [!] **ElevenLabs natural voice — waiting on Aritro.** Code is done and merged (cache, prefetch,
      2.5 s timeout, circuit breaker, Apple-voice fallback). It is off only because
      `ELEVENLABS_API_KEY` in `ios/CaneKit/Resources/Secrets.plist` is empty. See "ElevenLabs
      setup" below.
- [x] Voice control: 7 Siri App Shortcuts (start route, take me to <place>, navigate to CIF, where am I,
      repeat, next, stop) — on the phone, needs a spoken test
- [x] "Navigate to CIF from here" (Apple Maps walking directions from the live GPS fix)
- [x] Destination search: campus gazetteer before MapKit, nearest result, spoken "Walking to X, N meters."
- [x] Fixed: a slow Siri search could swap the walker onto another route mid-walk
- [x] Live camera view at the camera's frame rate (GPU view instead of a 3 Hz JPEG), preview capped at 30 fps
- [x] Trip-log fix: cue / hazard records keep their record type (field name collision)
- [ ] A/B: Apple's on-device model *with the image* (iOS 27), every object backed by Vision/LiDAR
- [ ] Experiment branch: Gemma 4 E2B via Cactus, measured on the phone (latency, heat, made-up objects)
- [ ] Experiments, off by default: front camera head direction; microphone sound alerts (sirens, horns)
- [ ] Muse + Antigravity + Claude workflow review of all of the above; fix or reject with evidence
- [ ] Install on the phone, verify each item from the trip log, push
- [ ] Outdoor walk ISR → CIF (stress plan W1/W2) — needs Aarav, Sagar and daylight

### Hardware tonight (Sagar, Windows machine)
- [x] OpenSCAD on Windows: 2021.01 via winget renders the threaded collar in 6 min 52 s; 2025.09.15
      portable snapshot does it in 0.3 s and is unzipped at `%USERPROFILE%\Tools\`
- [x] `scripts/build_stl.ps1` — one command, all five printables, binary STL, finds the fast OpenSCAD
- [x] `hardware/mount_screwless/` designed and rendering clean: collet clamp (collar + ring), arm,
      cradle, coupons. Zero screws, inserts, nuts or magnets.
- [x] `.gitignore` now covers `stl/`, `*.stl`, `*.3mf`, `*.gcode` — it did not before
- [x] `scripts/slice_gcode.ps1` — headless slicing through Creality Print 7.2 (an Orca fork, so it
      takes Orca's command line). Reproducible, no GUI, and it reads back what it wrote and refuses
      to call a file safe if it cannot confirm the material. See `hardware/mount_screwless/PRINTING.md`.
- [x] **The thread generator never produced a thread.** A twisted `linear_extrude` maps *angle* to
      height; the tooth was drawn as a flat y-offset and came out 0.031 mm thick, so the collar's
      threaded band sliced as a smooth cylinder. Rewritten as an angular sector: 0.62–0.75 mm.
      Both copies had it — `screwless_mount.scad` and the hand-copied one in `coupons.scad`.
- [x] **Print the bore rings and set `pole_d` from them.** DONE 2026-09-12. Printed, and fitted to
      the prototype shaft: 1 notch (27.75) barely went on, 2 and 3 went on decently, both colours
      agreeing. `pole_d = 27.75 - 0.10 = 27.65`, which lands exactly on the dial-caliper reading by
      a completely different method. The rival 28.75 is retired in all four .scad files. Caveat: no
      ring REFUSED to go on, so the shaft is bounded from above but not hard-bounded from below.
      `pole_d = (smallest ring that goes on) − 0.10` — **not −0.35**, which is what `coupons.scad`
      said until 2026-09-12 and was wrong by ~0.25 mm. `bore_clear` is *not* an output of this
      test: the rings are rigid, the collar is a collet that closes, so clearance is a design
      decision and `collet_squeeze` takes it up.
- [ ] Thread + dovetail coupons; set `thr_clear` and `dt_clear`. Exported together as one plate
      (`what="next"`, 11 solids, 149x178 mm, 57.32 cm3) on 2026-09-12. First thread pair printed
      and JAMMED two turns of four at [0.35, 0.25], so the coupon is now a four-nut bracket
      stepping radial and axial clearance separately. The thread coupon is the first
      physical proof the rewritten thread exists — **if the ring will not thread on, do not print
      the collar.**
- [ ] Print the bore rings in PETG too. PLA rings need a shrinkage correction of ~0.06 mm (worst
      case 0.168 mm, which is larger than the clearance the collet has to work with); PETG rings
      need none, because the collar is PETG.
- [ ] Print collar + ring; check the ring actually closes the collet on the real cane
- [ ] Print arm + cradle; T0 fit with the phone in it. **CORRECTION 2026-09-12: the arm now DOES
      depend on `dt_clear`**, via `arm_tip_t = dt_narrow - 2*dt_clear`, added when the fin was
      narrowed to pass the socket mouth. Measured: arm volume 42.865 / 42.656 / 42.448 cm3 at
      dt_clear 0.15 / 0.25 / 0.35. `pole_d` genuinely does not reach it. So the dovetail coupon
      must be read BEFORE the arm is printed — the old "printable first" advice would have wasted
      it. The same wrong claim is in PRINTING.md, CHANGELOG Step 18 and slice_gcode.ps1.
- [ ] **Pawl release window is ~79% blocked by the arm** — there may be no way to press the catch
      to release the joint. Confirm on the printed arm, then either move the window or add a
      cutaway.
- [ ] Remaining unfixed, found by review on 2026-09-12 and not yet addressed: no lead-in ramp on
      the pawl catch; `socket_part()`'s "flare" is a flat 90° ledge, not a flare; the button
      windows overrun the top of both side walls; `dt_clear` gives 0.325 mm at the mouth and
      0.139 mm buried instead of a uniform 0.25; ball-socket fingers at ~7–9% strain will crack.
- [x] **Cane diameter SETTLED at 27.65 mm, 2026-09-12.** Was disputed three ways (27.65 dial
      caliper / 28.75 repo+brief / 28.65 = 1.128 in). The bore rings decided it against the real
      shaft and agreed with the caliper to 0.01 mm. `hardware/mount/cane_mount.scad` and
      `test_coupons.scad` moved off 28.75 in the same commit. NOTE: the shaft is a BROOM HANDLE
      standing in for a cane — real long canes are 9.5–13 mm at the tip end (Ambutech published
      figures; Rodgers & Wall Emerson, JVIB 99(11) 2005), so every fit number here is a number for
      the prototype shaft, not for a cane.
- [ ] Ball joint (`joint = "ball"`): print socket + lock, check the clamp actually holds the
      phone through a sweep. Brief and mount/DESIGN.md rejected free ball joints; this one is
      clamped, which answers that but is untested.
- [ ] Decide on the day: `hardware/mount/` (screwed) or `hardware/mount_screwless/`. Record which in
      CHANGELOG.md.
- [ ] T7 shake / T8 drop on whichever is fitted; check the camera still reads 3–8° down afterwards

### Scene understanding: the decision, and why (researched 2026-09-11, 65 agents)

**Question asked:** run Gemma 4 2B/4B locally via Cactus so the app can name everything it sees,
instead of the fixed 1,303-label Apple classifier that returned *nothing* on the phone tonight.

**Answer: no local VLM before this demo. Use the cloud client that is already in the repo, gated.**

- **Cactus is disqualified by an open bug, not by taste.** github.com/cactus-compute/cactus issue
  #802 (filed 2026-09-01, still open): `cactus_complete` **with an image never returns** — the Metal
  backend deadlocks in `waitUntilCompleted` during chunked media prefill, on iOS and macOS. Metal is
  the default backend on iPhone; the suggested workaround is CPU. v2.2.0 (2026-09-08) shipped without
  touching it. Separately, an independent iPhone 17 Pro benchmark found the CQ4 build `cactus run`
  ships by default scores **3.0 % on GSM8K** where the build they demoted scores 87 %. Licence is
  source-available (free under $2M funding *and* revenue), not open source.
- **Gemma 4 E2B locally is disqualified by cost and coverage, not capability.** It needs SPM packages
  (AGENTS.md hard rule 2), **~3.0 GB** charged footprint for the 4-bit build on an iPhone 17 Pro —
  text-only, before an image encoder, ARKit, LiDAR and audio — a 1.8–3.6 GB first-run download, and
  **MLX does not run in the iOS simulator**, so `make sim`, `make uitest` and `make e2e` would all
  break. No iPhone vision-encoder latency for Gemma 4 has been published by anyone; we would be
  measuring it for the first time, on the demo phone, the night before.
- **Gemma 3 / 3n:** the LiteRT repos are manually gated on HuggingFace — an approval delay we cannot
  absorb. If we ever do go local, go Gemma 4 E2B (Apache-2.0, ungated), not Gemma 3.
- **Apple FastVLM 0.5B:** right shape, but its model licence is research-only and excludes product
  development.
- **Apple FoundationModels with the image (iOS 27):** the best *future* path — first-party, no
  packages, no key, no network — and already built on `feat/fm-image-describe`, off by default. Not
  the demo path: it needs an iOS 26 availability waiver, and handed a solid white frame it said
  *"The path ahead is clear and unobstructed"* 4 times out of 4.

**What we do instead:** `ios/CaneKit/Scene/VLMClient.swift` already ships a working Gemini client with
cloud-primary / on-device fallback and unit-tested codecs. It needs a key, not code.

- [!] **Gemini key — waiting on Aritro** (optional; the app works without it). See below.
- [ ] Gate the cloud reply — `SceneVocabulary.isFaithful` runs on the on-device path **only**, so a
      cloud sentence is currently spoken ungated. Measured hallucinations of exactly this class on our
      own route frames: "S 5th St", "S Grand Blvd". In progress on `fix/cloud-scene-gate`.
- [ ] Fix the prompt: it asks for clock-face directions and distances in metres. VLMs read clock
      directions from the *image's* frame rather than the walker's, and distance is the one thing they
      are measurably worst at (below chance — GuideDog, ACL 2026). LiDAR supplies every number.
- [ ] Measure the real round trip from the phone on campus cellular and write down p50 and max. Do not
      quote anyone's benchmark at the demo; quote ours.
- [ ] Leave the hazard watch **off** for the demo (it is the only thing that would call a model in a
      loop).

**The line to say out loud at the demo:** *the model names things; LiDAR measures them. No number the
sensors did not see is ever spoken.*

### Gemini setup (optional, 3 minutes, Aritro only)

1. aistudio.google.com → **Get API key** → **Create API key**. Copy it.
2. In `ios/CaneKit/Resources/Secrets.plist` set `VLM_PROVIDER` to `gemini`, paste `GEMINI_API_KEY`,
   and set `GEMINI_MODEL` to `gemini-3.5-flash-lite` (fastest measured of 53 models: 2.70 s average).
3. ⚠ **Privacy, decide deliberately:** Google's pricing page marks "content used to improve our
   products" as **Yes** on every free-tier row and **No** on every paid row. This app points a camera
   at strangers on the Quad. Attach billing to the project, or accept that free-tier frames may be
   used for training. Either is a choice; making it by accident is not.
4. Kill switch if it misbehaves on stage: turn off Wi-Fi and cellular. `waitsForConnectivity = false`
   means the request fails at once and the on-device describer answers. Nothing else is affected.

### ElevenLabs setup (2 minutes, Aritro only — nobody else can do this)

The natural voice is already written, reviewed and merged (`ios/CaneKit/Speech/ElevenLabsVoice.swift`).
It stays silent for one reason: no key. Every line is cached as an mp3 on disk keyed by
voice + model + text, so a line the app has spoken once replays instantly and costs nothing; a miss
waits at most 2.5 s and then falls back to the Apple voice, and after a failure the app stops trying
for 60 s so a weak network can never stall a cue.

1. Sign in at elevenlabs.io → click your avatar (bottom left) → **API Keys** → **Create API key**.
   Copy it. The free tier's 10,000 characters a month is far more than the demo needs, because the
   route lines are prefetched once and then cached.
2. Pick the voice: **Voices** → play a few → on the voice you like, the **⋮** menu → **Copy voice ID**.
   Skip this to use the default (`21m00Tcm4TlvDq8ikWAM`, a calm premade voice).
3. Open `ios/CaneKit/Resources/Secrets.plist` (git-ignored, never committed) and paste:
   - `ELEVENLABS_API_KEY` → the key from step 1
   - `ELEVENLABS_VOICE_ID` → the ID from step 2, if you picked one
   - `ELEVENLABS_MODEL` → leave as `eleven_flash_v2_5` (lowest latency of the ElevenLabs models)
4. `cd ios && make build install launch`.
5. Verify on the phone: tap **Speech test** on the Haptics card. The pill next to "Speaking" reads
   **System** with no key and flips to **ElevenLabs** once a line has played through the new voice.
   If it stays System, the key is wrong or the network is down — the app still speaks, just in
   Apple's voice, so a bad key can never break the demo.

## Step 11 — Hazards the maps don't know, on-device vision, stress harness (pre-device)
- [x] LiDAR ground hazards (GroundSampler + GroundHazardDetector), 4-tap cane haptic, off by default
- [x] On-device sign reading (Vision text down to 1/128 of the frame, 7.5 cm letters from ≈ 7 m measured, once a minute per phrase)
- [x] Hazard watch (cloud 2.5 s → on-device; stale replies dropped), off by default
- [x] Keyless "Where am I" (Apple Vision + Foundation Models, template fallback)
- [x] Hazard map GeoJSON + photos, Share on the Hazards card; Files app sharing on
- [x] Route cues as long buzzes on the cane; debug footer removed
- [x] CourseSmoother veer (15 m); corner-fence reset; reset after each veer cue
- [x] Muse full-app review fixes (H1–H3, M1–M8, L2/L5/L6)
- [x] Round-4 and round-5 adversarial reviews (28 + 22 findings) fixed; nav harness 0 false veers / 72 walks
- [x] Logic tests (historical 146 green after Step 12), simulator build, 7 XCUITests + tour, `make e2e` (clean, missed_fence, gps_jitter, wrong_turn)
- [x] Street View mock of ISR → CIF: FrameReplay, `make uitest-streetview`, `make e2e SCENARIO=streetview`, vision_probe
- [x] graphify knowledge graph (`graphify-out/`, `graphify query`)
- [x] docs/stress_test_plan.md, docs/README.md, hardware/mount (phone-to-cane mount for Sagar)
- [x] Muse + Antigravity check of the final diff (rounds 6–7 and the docs review)
- [ ] Commit "Step 11 + 12 (pre-device)" + push
- **test on device:** see CHANGELOG Step 11 and docs/stress_test_plan.md

## Step 12 — Google Street View mock of ISR → CIF (pre-device)
- [x] Trip-log `scan`, `hazard_watch`, `describe_result` records; FrameReplay frame names
- [x] Street View e2e: hazard watch on, "Where am I" at start + every waypoint, ≥ 8 of 10 described
- [x] `SceneVocabulary`: plain pedestrian nouns instead of Vision taxonomy words (5 tests)
- [x] `sign_probe.swift`: measured sign range; text floor 1/128 (7.5 cm letters ≈ 7 m); STOP dropped, PUSH BUTTON added
- [x] "OpenCane ready." no longer spoken after "Camera access is off"
- [x] On-device model gate (`isFaithful`: names a detected thing, no invented numbers), OCR-junk filter, new prompt
- [x] One-word sign phrases must be close (`shortPhraseMinHeight` 1/80); people / ice / plants in the vocabulary
- [x] Engineering bar written into AGENTS.md + CLAUDE.md; hardware/ handed to Sagar
- [x] Commit b1c35bd pushed (Steps 11–12); follow-up commit with the model-gate fixes
- [x] docs/TEAM_HANDOFF.md + README / docs index / iOS README refreshed; Muse + Antigravity docs review folded in
- [ ] Deferred from the Antigravity nav review (verify on device, fix if real): head tracker only with
      AirPods connected; move `observeThermalAndBattery()` after the audio session is configured;
      announce skipped waypoints in the passed-by path too
- **test on device:** see CHANGELOG Step 12

## Step 20 — Passed-by slow approach fix, Live Activity overlap prevention, and Watch keep-alive guard (Sat Sep 12)
- [x] Full codebase stress test across Depth, Navigation, Audio, Speech, Watch, and Trip Logging
- [x] `GeofenceTracker.update`: reset `recedingFixes` when approaching waypoint (`d <= minDistance`), tested in `passedByResetsRecedingStreakDuringSlowApproach`
- [x] `LiveActivityController`: added `immediate: Bool = false` dismissal policy; `start()` and `AppModel.endRouteQuietly()` use `immediate: true` to prevent stacked lock screen activities
- [x] `WatchModel.updateKeepAlive`: guarded with `!text.hasPrefix("No route")` to prevent false workout starts on idle status messages
- [x] Dual camera + LiDAR depth architecture audit: verified hardware capabilities on iPhone 17 Pro Max (12 multi-cam sets with front + rear LiDAR depth at 320x240) and ARKit single-camera constraint
- [x] Historical verification: 348/348 unit tests, `make sim` build, 10/10 UITests + visual tour, and clean GPS e2e replay (100% pass, 9/9 waypoints)
- [x] Device install and verification on connected iPhone 17 Pro Max
- **test on device:** see CHANGELOG Step 20

## Step 21 — Bolt: Decouple 30 Hz depth stream from ContentView root (Sat Sep 12)
- [x] Profiled SwiftUI Observation invalidation under high-frequency LiDAR updates (historical 15–30 Hz `model.depth.report`; current normal cadence is 30 Hz, high-rate is up to 60 Hz)
- [x] Extracted `ObstaclesCard` and `MountAimRow` leaf subviews inside `ContentView.swift`
- [x] Preserved pure value semantics on `LaneGridView(report:)` and hoisted `laneNames` static array
- [x] Verified zero concurrency regressions under Swift 6 strict concurrency (`SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`)
- [x] Muse adversarial review passed, adopting Muse's recommendation for leaf container over environment fallback
- [x] Historical verification: 348/348 Logic tests (`make test`), clean simulator build (`make sim`), 10/10 UITests (`make uitest`), and e2e replay
- **test on device:** see CHANGELOG Step 21

## Step 22 — Rename primary route action to "Start route to CIF" (Sat Sep 12)
- [x] Renamed GuideCard button from the historical "Start demo route" to "Start route to CIF"
- [x] Added "Start route to CIF in OpenCane" to Siri App Shortcuts in AppIntents
- [x] Synchronized test contracts across `AGENTS.md` (Rule 9), `docs/CODE_REFERENCE.md`, `docs/design.md`
- [x] Updated `CaneKitUITests` and `CaneKitVisualTour` and verified all 10 tests pass
- [x] Muse adversarial review passed confirming 1:1 label parity and zero contract regressions
- [x] Built and deployed to physical iPhone 17 Pro Max (`00008150-001A698C1108401C`)
- **test on device:** see CHANGELOG Step 22

## Cross-cutting
- [x] Three icon-only root tabs (Guide / Sense / Settings) — `CKTabBar`, VoiceOver labels pinned, XCUITests open the matching tab
- [x] UI design system (docs/design.md, Theme.swift, WatchTheme.swift) applied to grid + root screen
- [x] route_isr_cif.json with OSM-verified coordinates (docs/route_isr_cif.md); re-record Friday on foot
- [x] TripLogger JSONL (Documents folder; AirDrop from Files)
- [x] Simulator build + run on the iOS 27 simulator (now the iPhone 17 Pro Max, the demo phone) — UI verified by screenshot
- [ ] Go/no-go checklist rehearsed before any blindfolded walk
- [ ] Open (not fixed, from the review's unverified list): accidental taps on the clamped screen (Stop / Mirror have no
      lock), the screen-lock safety trade-off (the app now speaks that obstacle warnings are paused, but the ARKit
      path still requires Guided Access + keeping the screen on for a blindfolded walk), compass readings dropped while
      iOS wants calibration (heading is nil until walking > 0.7 m/s), VoiceOver double-speak on frequently-updating
      pills, MapKit route build waits only 15 s for a first fix
