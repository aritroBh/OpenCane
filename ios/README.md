# CaneKit — iOS 26 app for the phone-only smart-cane kit

Native SwiftUI · Swift 6 strict concurrency · Apple frameworks only. Targets: **CaneKit** (iPhone),
**CaneKit Watch** (watchOS companion), **CaneKitWidget** (Live Activity, added in step 9).
Hardware: iPhone 17 Pro Max (LiDAR, Action button, Camera Control) clamped to a 28.75 mm non-metal pole,
Apple Watch, AirPods Pro. Nothing else.

**Status:** built step by step during the hackathon — `CHANGELOG.md` says which steps have landed. Paths marked
`[step N]` below do not exist until that step; until step 1 lands there is no Xcode project in the repo.

```
ios/
├── README.md                 ← you are here
├── project.yml               XcodeGen spec (3 targets)              [step 1]
├── Makefile, scripts/gen.sh  CLI build / install / launch            [step 1]
├── Secrets.example.plist     copy to CaneKit/Resources/Secrets.plist [step 8]
├── Logic/                    SwiftPM package: pure logic + unit tests, runs without Xcode [step 1]
├── Shared/                   WatchMessage (iOS+watch), NavActivityAttributes (iOS+widget) [step 1]
├── CaneKit/                  the iPhone app (App, Depth, Haptics, Speech, Watch, Navigation, Audio, Scene, Trip, UI)
├── CaneKitWatch/             the watch app                          [step 1]
├── CaneKitWidget/            Live Activity                          [step 9]
├── stretch/CaneBLE.swift     ESP32 grip client. Not in any target.
└── route_isr_cif.json        → CaneKit/Resources/ once recorded (Fri)
```

Data flow:

```
ARSession ─▶ DepthFrameProcessor (bg queue) ─▶ LaneReport (15 Hz) ─▶ DepthEngine (main)
                    │ gyro gate: trusted only when |ω| < 0.6 rad/s          │
                    │ mesh classification at screen center (~4 Hz)          ├─▶ HapticLogic ─▶ HapticPlayer (Core Haptics)
                    └─ last camera frame → JPEG for "Where am I"            ├─▶ ObstacleNamer ─▶ SpeechQueue ─▶ AirPods
                                                                            └─▶ PhoneWatchLink (fallback + turns)
CLLocationUpdate + CLHeading ─▶ NavigationEngine ─▶ speech · watch taps · BeaconEngine (spatial click) · Live Activity
```

---

## 1. Day-0 checklist (do this before the hackathon — it is the critical path)

The build Mac had **no Xcode** on Sep 10 (Command Line Tools only). Budget 2–3 h for this list.

1. Install **Xcode 27 RC** (developer.apple.com/download → needs an Apple ID; ~3–4 GB xip, ~15 GB installed).
   The phone runs iOS 27 RC, so Xcode 26 cannot deploy to it. Deployment target stays **iOS 26 / watchOS 26**.
   ```sh
   sudo xcode-select -s /Applications/Xcode.app
   sudo xcodebuild -license accept
   xcodebuild -runFirstLaunch
   xcodebuild -downloadPlatform watchOS      # separate download; watch target fails without it
   brew install xcodegen                     # 2.46.0
   ```
2. Open Xcode once → Settings → Accounts → add your Apple ID. A **Personal Team** appears (free; the app
   expires after 7 days, 10 App IDs per week — we use 3, never rename bundle IDs).
   Team ID: `security find-identity -v -p codesigning` → the 10 characters in parentheses.
3. iPhone **and** Watch: Settings → Privacy & Security → **Developer Mode** → on (reboots).
4. Plug the phone in, Xcode → Window → Devices. The paired watch shows under the phone (this registers its UDID).
   Watch pairing over Wi-Fi is flaky — if the watch is not paired within 30 min, the watch app becomes a day-2 item.
5. Device ID for the Makefile: `xcrun devicectl list devices` (or `xcodebuild -showdestinations -scheme CaneKit`).
6. First install on the phone: Settings → General → VPN & Device Management → trust the developer app.
7. Phone Settings → Action Button → Shortcut → **Where am I** (available after the first launch, step 8).
8. Control Center → AirPods → Spatial Audio **Off** (system head-tracking would re-spatialize our beacon).

## 2. Verified spec deviations (don't "fix" these back)

| Spec said | Reality (Apple docs, checked Sep 10) | What CaneKit does |
|---|---|---|
| `AVAudioEnvironmentNode.isListenerHeadTrackingEnabled` | Needs the **Head Pose** capability — paid team only | `CMHeadphoneMotionManager` yaw (relative, drifts) drives `listenerAngularOrientation`; **Recenter** on watch / every waypoint / auto when walking straight 3 s |
| Watch side button = "next" | No API for the side button or a crown *press* | Crown rotation (≥ 3 detents) + big on-screen Next / Describe / Recenter |
| Camera Control press = describe | `AVCaptureEventInteraction` only fires for apps "actively performing capture"; unverified with ARKit owning the camera | Built and spiked in step 2; Action button + watch + on-screen button are the guaranteed paths |
| Watch haptics on demand | `WKInterfaceDevice.play` no-ops unless the watch app is frontmost; `sendMessage` needs reachability | Watch runs a walking `HKWorkoutSession` (HealthKit on the watch target) so cues play wrist-down; `WKExtendedRuntimeSession` fallback |
| Haptic rate ∝ 1/distance | `sendParameters` can't retime events | Geiger loop: one pre-built transient player fired on a timer, 2 Hz at 2 m → 8 Hz at 0.5 m |
| One audio session | Mixing `.playback` / `.playAndRecord` / HFP flips AirPods routes | `.playback`, mode `.default`, `[.duckOthers]`, no Bluetooth options; TTS uses the app session; haptics use `CHHapticEngine(audioSession: nil)` |
| XcodeGen project | 2.46.0 embeds the watch app in `Watch/` (bug #1613, Xcode 26+) | `scripts/gen.sh` patches the pbxproj after generate; `WATCH=0 scripts/gen.sh` = phone-only project |

Also: mesh classification ("door ahead") is an **indoor** feature — LiDAR range is ~5 m and sunlight kills it.
Outdoors the lanes (distance only) are the product. Demo doors at the ISR lobby and CIF entrance.

## 3. Build, install, launch (CLI; no Xcode GUI needed after day 0)

```sh
cd ios
scripts/gen.sh                      # xcodegen generate + watch-embed patch + Secrets.plist copy
make build TEAM=ABCDE12345 DEVICE=00008150-…   # xcodebuild, automatic signing, personal team
make install DEVICE=…               # xcrun devicectl device install app
make launch DEVICE=…                # xcrun devicectl device process launch
make run                            # all of the above
```
The watch app installs through the Watch app on the phone (Automatic App Install on, or Available Apps → Install).
`make test` runs the pure-logic unit tests in `Logic/` (`swift test`; works with Command Line Tools alone).

## 4. Secrets

`Secrets.example.plist` → `CaneKit/Resources/Secrets.plist` (git-ignored; `gen.sh` copies it if missing).
Keys: `VLM_PROVIDER` (`custom` | `anthropic` | `gemini` | `openai`), `CUSTOM_BASE_URL` / `CUSTOM_API_KEY` /
`CUSTOM_MODEL` (OpenAI-compatible chat endpoint — Muse 1.3), `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `OPENAI_API_KEY`.
No key → the app speaks "no scene-description key" instead of crashing. Keys ship in plaintext inside the .app;
fine for a local install, rotate them after the event.

Permissions (declared in `project.yml`, prompted on first use): camera + LiDAR (`NSCameraUsageDescription`),
location when in use, motion (sweep gate, AirPods head tracking, steps), speech recognition + microphone
(reserved), HealthKit share/update (steps; also on the watch target for the workout session). Background modes:
`audio`, `location` on the phone; `workout-processing` on the watch. `NSSupportsLiveActivities` for the Dynamic Island.

## 5. Testing

- **Unit (`ios/Logic`, no device):** lane extraction on synthetic depth buffers, hysteresis / rate-limit state
  machine, geofence + bearing math, MapKit steps → waypoints, watch message codec, VLM response parsing.
  `cd ios/Logic && swift test`.
- **Device-only (manual, per step's "test on device" line in `CHANGELOG.md`):** LiDAR scale, haptic feel through the
  clamp, beacon left/right + head-tracking sign, wrist-down watch taps, geofence timing, VLM latency, thermal.
- **Reproducibility:** `TripLogger` writes a JSONL log (lanes, cue, GPS, heading, thermal, battery, speech) to the
  app's Documents folder → Files app / AirDrop. Film every outdoor test with a second phone.
- **Go / no-go before a blindfolded ISR→CIF walk:** GPS accuracy ≤ 15 m for 30 s at the ISR door · wall at 1 m reads
  0.8–1.2 m in all six tiles · head cue re-fires with a hand overhead · beacon L/R correct after Recenter · watch tap
  felt wrist-down · arrival fires at CIF east within 25 m · battery > 40 %, thermal nominal/fair · spotter assigned,
  kill-word ("stop") rehearsed. Any miss → sighted demo only.

## 6. Gotchas that survive from the first draft

- **Depth map orientation.** `sceneDepth.depthMap` is 256×192 landscape in sensor orientation. Phone upright →
  buffer is the scene rotated 90° CCW: `bufferX = sceneY`, `bufferY = (H-1) - sceneX`. Debug toggles
  "Phone held upright" and "Mirror left/right" exist for this; verify with a hand at the left edge.
- **CVPixelBuffer.** Lock before reading, unlock in `defer`, use `CVPixelBufferGetBytesPerRow` (rows are padded).
  Retain exactly one camera buffer for the snapshot; retaining `ARFrame`s makes ARKit drop frames.
- **Ground.** Bottom 25 % of the upright image is skipped so pavement is not a permanent obstacle. Tune if the mount tilts.
- **Sweep gate.** Frames with |gyro| ≥ 0.6 rad/s are untrusted; `HapticLogic` freezes and emits nothing.
- **Foreground only.** ARKit stops when the app is backgrounded or the screen locks. `isIdleTimerDisabled = true`;
  use Guided Access (triple-click side button) for the demo. Power bank on the strap: ARKit + LiDAR ≈ 3–4 h.
- **Thermal.** `.serious` → mesh classification + obstacle names off; `.critical` → beacon off too. Lanes + haptics never stop.
