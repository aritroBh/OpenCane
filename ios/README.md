# CaneKit: the iOS app for the phone-only smart cane

This is a native SwiftUI app in Swift 6 with strict concurrency (main-actor default isolation). It
builds against iOS 26 / watchOS 26 and uses Apple frameworks only, with no third-party packages.
The hardware is an iPhone 17 Pro Max on iOS 27 (LiDAR, Action button, Camera Control) clamped to a
non-metal 28.75 mm cane, plus AirPods Pro and an Apple Watch. For the demo everything runs
**untethered on the phone**. The Mac only signs and installs.

| Target / package | What it is | Bundle ID (frozen) |
|---|---|---|
| **CaneKit** | The iPhone app, and the only computer in the kit | `com.aritro.canekit` |
| **CaneKitWatch** | watchOS companion: wrist taps, Repeat / Next / Describe / Recenter | `com.aritro.canekit.watchkitapp` |
| **CaneKitWidget** | Live Activity (Dynamic Island + lock screen) | `com.aritro.canekit.widget` |
| **CaneKitUITests** | XCUITests + the screenshot tour | `com.aritro.canekit.uitests` |
| **CaneKitLogic** (`Logic/`) | SwiftPM package with every pure decision that has a number in it, plus its Swift Testing tests. Runs without Xcode. | — |

Start with [`AGENTS.md`](../AGENTS.md) (hard rules; it wins every conflict), then
[`docs/CODE_REFERENCE.md`](../docs/CODE_REFERENCE.md), which maps every file, type and function and
has the **data-flow diagram** ([§ Data flow](../docs/CODE_REFERENCE.md#data-flow)). Before the
AirPods, the watch or the untethered demo, read [`docs/devices_setup.md`](../docs/devices_setup.md).
Every other doc is listed in [`docs/README.md`](../docs/README.md).

**Status.** Steps 0–11 have landed and are verified on the simulator: 128 logic tests, 7
XCUITests (one needs the local Street View frames), the screenshot tour, and `make e2e` (GPS replay
of the route through the real app, four scenarios, plus an opt-in Street View camera scenario).
Device testing (LiDAR, haptics through the clamp, AirPods, watch) is the open work. [`docs/todo.md`](../docs/todo.md) and
[`CHANGELOG.md`](../CHANGELOG.md) are the source of truth.

## Layout

| Path | Contents |
|---|---|
| `CaneKit/` | The phone app: `App/` (`AppModel` owns every engine; App Intents), `Depth/`, `Haptics/`, `Speech/`, `Audio/`, `Navigation/`, `Scene/`, `Trip/`, `Watch/`, `UI/`, `Resources/` (`route_isr_cif.json`, assets, your git-ignored `Secrets.plist`) |
| `CaneKitWatch/`, `CaneKitWidget/`, `CaneKitUITests/` | The targets above |
| `Shared/LiveActivity/` | `NavActivityAttributes`, compiled into the app and the widget |
| `Logic/` | `CaneKitLogic`: `LaneMath`, `LaneReport`, `CueDecider`, `GeoMath`, `NavSupport`, `Waypoint`, `WatchMessage`, `VLMCodec` + `Tests/` |
| `project.yml` | XcodeGen spec. `CaneKit.xcodeproj` is generated and git-ignored. |
| `Makefile`, `scripts/` | `gen.sh` (project generation), `test.sh` (logic tests), `e2e.py` (GPS-replay end-to-end) |
| `Secrets.example.plist` | Template for `CaneKit/Resources/Secrets.plist` |
| `local.mk` | Git-ignored, and you create it: `TEAM` and `DEVICE` for device builds |
| `stretch/`, `drafts/` | Not in any target (old ESP32 BLE client, iOS 18 starter files). Leave them alone. |

---

## 1. Day-0 checklist

These steps are done once per Mac and per phone. On the build Mac, Xcode 27 RC (27A266a) and
XcodeGen 2.46.0 are already installed. Apple ID, Developer Mode and `local.mk` are still open in
`docs/todo.md`.

1. Install **Xcode 27 RC** (developer.apple.com/download; ~15 GB installed). The phone runs iOS 27,
   so Xcode 26 cannot deploy to it. The deployment target stays **iOS 26 / watchOS 26**.
   ```sh
   sudo xcode-select -s /Applications/Xcode.app
   sudo xcodebuild -license accept
   xcodebuild -runFirstLaunch
   xcodebuild -downloadPlatform watchOS      # separate download; the watch target fails without it
   brew install xcodegen                     # 2.46.0
   ```
2. Open Xcode once → Settings → Accounts → add your Apple ID. A free **Personal Team** appears. An
   install expires after 7 days, and the team gets 10 App IDs per week. We use 3, so never rename
   bundle IDs. Your Team ID is the 10 characters in parentheses from
   `security find-identity -v -p codesigning`.
3. iPhone **and** Watch: Settings → Privacy & Security → **Developer Mode** → on (this reboots).
4. Plug the phone in and open Xcode → Window → Devices. The paired watch shows under the phone,
   which registers its UDID. Watch pairing over Wi-Fi is flaky: if the watch isn't paired within
   30 min, the watch app becomes a day-2 item.
5. Run `cd ios && make devices` and copy the phone's identifier. Then create `ios/local.mk`:
   ```make
   TEAM   = ABCDE12345                # security find-identity -v -p codesigning
   DEVICE = 00008150-000A1B2C3D4E5F   # make devices
   ```
6. First install (`make run`), then on the phone: Settings → General → VPN & Device Management →
   trust the developer app.
7. Phone Settings → Action Button → Shortcut → **Where am I**. The shortcut appears after the first
   launch.
8. Settings → Bluetooth → (i) next to the AirPods → **Spatial Audio: Off** and **Head Tracking: Off**.
   System head-tracking would re-spatialize the beacon. The rest of the AirPods and watch list is in
   `docs/devices_setup.md`.

## 2. Verified spec deviations (don't "fix" these back)

| Spec said | Reality (Apple docs, checked Sep 10) | What CaneKit does |
|---|---|---|
| `AVAudioEnvironmentNode.isListenerHeadTrackingEnabled` | Needs the **Head Pose** capability, which is paid-team only | `CMHeadphoneMotionManager` yaw (relative, drifts) drives `listenerAngularOrientation`. **Recenter** comes from the phone or watch button, or auto-recenter when walking straight (`StraightWalkDetector`: 3 steady fixes, never within 15 m of a crossing). The beacon ignores head yaw until the first recenter after a turn. |
| Watch side button = "next" | There is no API for the side button or a crown *press* | Crown rotation (3 detents within 1 s of the first) + big on-screen Repeat / Next / Describe / Recenter |
| Camera Control press = describe | `AVCaptureEventInteraction` only fires for apps "actively performing capture". Unverified with ARKit owning the camera. | Spike built (`Scene/CameraControlInteraction.swift`; the debug footer counts presses). The Action button, the watch and the on-screen button are the guaranteed paths. |
| Watch haptics on demand | `WKInterfaceDevice.play` no-ops unless the watch app is frontmost, and `sendMessage` needs reachability | The watch runs a walking `HKWorkoutSession` (HealthKit on the watch target) so cues play wrist-down, with a `WKExtendedRuntimeSession` fallback |
| Haptic rate ∝ 1/distance | `sendParameters` can't retime events | Geiger loop: one pre-built transient player fired on a timer, 2 Hz at 2 m → 8 Hz at 0.5 m |
| One audio session | Mixing `.playback` / `.playAndRecord` / HFP flips AirPods routes | `.playback`, mode `.default`, `[.duckOthers]`, no Bluetooth options. TTS uses the app session. Haptics use `CHHapticEngine(audioSession: nil)`. |
| XcodeGen project | 2.46.0 embeds the watch app in `Watch/` (bug #1613, Xcode 26+) | `scripts/gen.sh` patches the pbxproj after generating. `WATCH=0 scripts/gen.sh` gives a phone-only project. |

Also: mesh classification ("door ahead") is an **indoor** feature. LiDAR range is ~5 m and
sunlight kills it. Outdoors the product is the lanes (distance only). Demo doors are at the ISR
lobby and the CIF entrance.

## 3. Build, install, launch

Everything runs from `ios/` on the command line. You don't need the Xcode GUI after day 0.
`TEAM` and `DEVICE` come from `local.mk`, and you can override either on the command line
(`make build DEVICE=…`).

| Command | What it does |
|---|---|
| `make gen` | `scripts/gen.sh`: `xcodegen generate` + the watch-embed patch, and it copies `Secrets.example.plist` → `CaneKit/Resources/Secrets.plist` if missing. Run it only after `project.yml` or the file list changes. `WATCH=0 scripts/gen.sh` gives a phone-only project. |
| `make test` | `scripts/test.sh`: the 128 `CaneKitLogic` tests (Swift Testing). Works with the Command Line Tools alone. |
| `make build` | Device build, automatic signing, personal team (needs `TEAM` + `DEVICE`) |
| `make install` | `xcrun devicectl device install app` onto the phone |
| `make launch` | `xcrun devicectl device process launch com.aritro.canekit` |
| `make run` | `gen` + `build` + `install` + `launch`. Use this for the phone. |
| `make sim` | Build for the iOS simulator (no LiDAR, haptics or watch there) |
| `make sim17` | Create the **iPhone 17 Pro Max / iOS 27** simulator. Run it once, because Xcode 27 only pre-creates iPhone 18s. |
| `make sim-grant` | Boot the simulator and pre-grant location + motion so no system alert races a test's first tap. `uitest`, `tour` and `e2e` run it for you. |
| `make uitest` | The XCUITests (`CaneKitUITests`) on the iPhone 17 Pro Max simulator |
| `make tour` | Screenshot every screen state (`CaneKitVisualTour`) → PNGs in `build/shots/` |
| `make e2e` | GPS-replay end-to-end through the real app (`scripts/e2e.py`). `SCENARIO=all` (default, ~20 min), `clean`, `missed_fence`, `gps_jitter` or `wrong_turn`. It asserts on the app's JSONL trip log. The report and logs go to `build/e2e/`. |
| `make devices` | `xcrun devicectl list devices` (to find `DEVICE`) |
| `make clean` | Delete `build/`, `CaneKit.xcodeproj` and `Logic/.build` |

The simulator targets use `SIM ?= iPhone 17 Pro Max`. You can override it per call or in `local.mk`.
The watch app rides inside the phone app and installs through the Watch app on the phone
(Automatic App Install on, or Available Apps → CaneKit → Install).

## 4. Secrets and permissions

`Secrets.example.plist` is the template for `CaneKit/Resources/Secrets.plist`, which is
**git-ignored**. `make gen` copies it if missing. Never commit the real file. It is bundled into the
.app at build time, so fill in the keys *before* `make run`.

| Key | Meaning |
|---|---|
| `VLM_PROVIDER` | `custom` \| `anthropic` \| `gemini` \| `openai`. If empty, the first provider with a key is used. |
| `CUSTOM_BASE_URL` / `CUSTOM_API_KEY` / `CUSTOM_MODEL` | Any OpenAI-compatible chat endpoint (Muse 1.3). The base URL goes without `/chat/completions`. |
| `ANTHROPIC_API_KEY` / `ANTHROPIC_MODEL`, `GEMINI_API_KEY` / `GEMINI_MODEL`, `OPENAI_API_KEY` / `OPENAI_MODEL` | The other "Where am I" providers |
| `ELEVENLABS_API_KEY`, `ELEVENLABS_VOICE_ID`, `ELEVENLABS_MODEL` | Natural voice. The defaults are a warm premade voice and `eleven_flash_v2_5`. |

With no ElevenLabs key the app uses the system voice. With no VLM key, "Where am I" says there is
no key instead of crashing (a UI test checks this). Keys ship in plaintext inside the .app, which is
fine for a local install; rotate them after the event.

Permissions are declared in `project.yml` and prompted on first use:

- **Location** is requested at launch, so have a sighted helper present. `CANEKIT_UITEST=1` skips
  the request.
- **Motion** and **HealthKit** are requested at route start.
- **Health** is requested again on the watch.
- **Camera + LiDAR** are used for obstacles.
- **Speech recognition + microphone** are reserved.

Background modes are `audio` and `location` on the phone and `workout-processing` and `mindfulness`
on the watch. `NSSupportsLiveActivities` is on for the Dynamic Island.

## 5. Testing

The **commit gate** (from `AGENTS.md` rule 10): `make test` and `make sim` must be green. For UI
changes, also run `make uitest` and `make tour` on the iPhone 17 Pro Max / iOS 27 simulator. Run
`make e2e` for navigation or speech changes. Then run the Muse review of the diff.

- **Unit tests (`Logic/`, no device):** 128 Swift Testing tests. They cover lane extraction on
  synthetic depth buffers, the hysteresis / rate-limit cue state machine, geofence and bearing
  math (skip-ahead, passed-by, arrival gate), MapKit steps → waypoints, the watch message codec,
  VLM bodies and parsing, turn settling, straight-walk, the spoken-cue policy and the crown
  gesture.
- **UI (`make uitest`):** 7 XCUITests (one skipped unless `make uitest-streetview`) drive the real screens: start, Next, Repeat, Recenter and
  Stop on the demo route; Where am I without a key; the haptic test buttons and the Silence toggle;
  a mount toggle; VoiceOver labels; and the empty-destination error. Accessibility labels are a
  test contract (`AGENTS.md` rule 9).
- **Visual (`make tour`):** one PNG per screen state in `build/shots/`, for review by eye.
- **End-to-end (`make e2e`):** replays the ISR → CIF route in the simulator with
  `xcrun simctl location`. The app auto-starts the route under `CANEKIT_DEMO_ROUTE=1`. Assertions
  run on the trip log: waypoint order, wrist cues, veer cues, "Passed …" lines and arrival. The
  four scenarios are a clean walk, a missed fence, ±6 m GPS jitter and a wrong turn at Goodwin.
  Manual replay: `SIMCTL_CHILD_CANEKIT_DEMO_ROUTE=1 xcrun simctl launch booted com.aritro.canekit`,
  then `xcrun simctl location booted start --speed=4 --interval=1 <lat,lon> …` with the waypoints
  from `CaneKit/Resources/route_isr_cif.json`. The log is `Documents/canekit-*.jsonl` under
  `xcrun simctl get_app_container booted com.aritro.canekit data`.
- **CI (`.github/workflows/ci.yml`) is manual-trigger only** (Actions → CI → Run workflow). GitHub
  Actions billing on the account is exhausted, so pushes don't run it. When run, it does logic tests
  on Linux and an informational phone-only simulator build on macOS. **The local gate above is
  authoritative.**
- **Device only (manual, following each step's "test on device" line in `CHANGELOG.md`):** LiDAR
  scale, haptic feel through the clamp, beacon left/right and head-tracking sign, wrist-down watch
  taps, geofence timing, VLM latency and thermal.
- **Reproducibility:** `TripLogger` writes a JSONL log to the app's Documents folder (lanes, cues,
  GPS, heading, thermal, battery, speech). Get it off the phone with the Files app or AirDrop. Film
  every outdoor test with a second phone.
- **Go / no-go before a blindfolded ISR → CIF walk.** Any miss means a sighted demo only.
  - GPS accuracy ≤ 20 m for 30 s at the ISR door. Fences and veer cues pause above 20 m, and the
    app says so.
  - A wall at 1 m reads 0.8–1.2 m in all six tiles.
  - The head cue re-fires with a hand overhead, and "Head height." is spoken.
  - Beacon left/right is correct after Recenter.
  - The watch tap is felt wrist-down.
  - Repeat on the watch re-speaks the last line.
  - Arrival fires at CIF east within 20 m.
  - Battery is > 40 % and thermal is nominal or fair.
  - A spotter is assigned and the kill-word ("stop") is rehearsed.

## 6. Gotchas

- **Depth map orientation.** `sceneDepth.depthMap` is 256×192 landscape in sensor orientation.
  With the phone upright, the buffer is the scene rotated 90° CCW: `bufferX = sceneY`,
  `bufferY = (H-1) - sceneX`. The Mount toggles "Phone held upright (portrait)" and "Mirror left /
  right" exist for this. Verify with a hand at the left edge.
- **CVPixelBuffer.** Lock before reading, unlock in `defer`, and use `CVPixelBufferGetBytesPerRow`
  (rows are padded). Retain exactly one camera buffer for the snapshot. Retaining `ARFrame`s makes
  ARKit drop frames.
- **Ground and mount tilt.** The bottom 25 % of the upright image is skipped (`LaneMath`
  `groundSkipFraction`) so pavement isn't a permanent obstacle. There is no gravity correction, so
  the mount must aim the camera 3–8° below the horizon: the Mount card shows "Camera tilt N° down"
  live. Fix the mount before touching `groundSkipFraction`.
- **Sweep gate.** Frames with |gyro| ≥ 0.6 rad/s are untrusted. The cue decider freezes and emits
  nothing, and the grid pill reads SWEEPING.
- **Foreground only.** ARKit stops when the app is backgrounded or the screen locks. The app sets
  `isIdleTimerDisabled = true`. Use Guided Access (triple-click the side button) for the demo. Keep
  a power bank on the strap, since ARKit + LiDAR run ≈ 3–4 h.
- **Thermal.** `.serious` or worse turns off mesh classification, and with it the obstacle names.
  Lanes and haptics never stop.
- **Fence radii come from the route file.** Most waypoints use 15 m, turns (WP3, WP6, WP8) use
  12 m and arrival (WP9, CIF) uses 20 m. Before you touch a fence, veer or speech rule, read
  `AGENTS.md` → "Things that look wrong but are deliberate".
