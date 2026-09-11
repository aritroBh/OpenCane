# CaneKit changelog

Build log for the hackathon. One entry per step; each ends with what to test on the phone.

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
