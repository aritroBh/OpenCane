# CaneKit changelog

Build log for the hackathon. One entry per step; each ends with what to test on the phone.

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
