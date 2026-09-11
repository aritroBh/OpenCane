# CaneKit — strict build checklist

Legend: `[ ]` open · `[x]` done · `[~]` written, not yet compiled/tested (no Xcode on the Mac yet) · `[!]` blocked

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
- **test on device:** app shows "LiDAR OK — ready" with three green capability rows; watch shows "CaneKit / Waiting for the phone"

## Step 2 — DepthEngine
- [x] DepthFrameProcessor (ARSession delegate on a background queue, gyro gate, 15 Hz, AsyncStream)
- [x] DepthEngine (main-actor owner: start/pause/resume, video format, thermal hook, fps)
- [x] LaneGridView / DebugView (6 tiles, TRUSTED pill, fps, |ω|, thermal, battery, portrait/mirror toggles)
- [x] CameraControlInteraction spike (AVCaptureEventInteraction) — log whether it fires under ARKit
- [ ] Build, install, run the test list; Muse review; commit
- **test on device:** wall at 1 m ≈ 1.0 in all six tiles; hand at left edge → Left tiles red; raise hand → Head row; swing cane → TRUSTED off; fps ≈ 15; Camera Control press shows "CC event" (or not — record which)

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
- [ ] Commit "Step 10 (pre-device)" + push
- **test on device:** see CHANGELOG Step 10 and docs/devices_setup.md

## Cross-cutting
- [x] UI design system (docs/design.md, Theme.swift, WatchTheme.swift) applied to grid + root screen
- [x] route_isr_cif.json with OSM-verified coordinates (docs/route_isr_cif.md); re-record Friday on foot
- [x] TripLogger JSONL (Documents folder; AirDrop from Files)
- [x] Simulator build + run on iPhone 18 Pro sim (iOS 27) — UI verified by screenshot
- [ ] Go/no-go checklist rehearsed before any blindfolded walk
- [ ] Open (not fixed, from the review's unverified list): accidental taps on the clamped screen (Stop / Mirror have no
      lock), obstacle sensing stopping silently on screen lock (use Guided Access + keep the screen on), compass
      readings dropped while iOS wants calibration (heading is nil until walking > 0.7 m/s), VoiceOver double-speak on
      frequently-updating pills, MapKit route build waits only 15 s for a first fix
