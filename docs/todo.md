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
- [x] Commit "Step 10 (pre-device)" + push (1de6efb)
- **test on device:** see CHANGELOG Step 10 and docs/devices_setup.md

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
- [x] Logic tests (130 green after Step 12), simulator build, 7 XCUITests + tour, `make e2e` (clean, missed_fence, gps_jitter, wrong_turn)
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
- [x] "CaneKit ready." no longer spoken after "Camera access is off"
- [x] On-device model gate (`isFaithful`: names a detected thing, no invented numbers), OCR-junk filter, new prompt
- [x] One-word sign phrases must be close (`shortPhraseMinHeight` 1/80); people / ice / plants in the vocabulary
- [x] Engineering bar written into AGENTS.md + CLAUDE.md; hardware/ handed to Sagar
- [x] Commit b1c35bd pushed (Steps 11–12); follow-up commit with the model-gate fixes
- [x] docs/TEAM_HANDOFF.md + README / docs index / iOS README refreshed; Muse + Antigravity docs review folded in
- **test on device:** see CHANGELOG Step 12

## Cross-cutting
- [x] UI design system (docs/design.md, Theme.swift, WatchTheme.swift) applied to grid + root screen
- [x] route_isr_cif.json with OSM-verified coordinates (docs/route_isr_cif.md); re-record Friday on foot
- [x] TripLogger JSONL (Documents folder; AirDrop from Files)
- [x] Simulator build + run on the iOS 27 simulator (now the iPhone 17 Pro Max, the demo phone) — UI verified by screenshot
- [ ] Go/no-go checklist rehearsed before any blindfolded walk
- [ ] Open (not fixed, from the review's unverified list): accidental taps on the clamped screen (Stop / Mirror have no
      lock), obstacle sensing stopping silently on screen lock (use Guided Access + keep the screen on), compass
      readings dropped while iOS wants calibration (heading is nil until walking > 0.7 m/s), VoiceOver double-speak on
      frequently-updating pills, MapKit route build waits only 15 s for a first fix
