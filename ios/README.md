# CaneKit — iOS starter for a smart-cane retrofit kit

iOS 18+ · SwiftUI · `@Observable` · Apple frameworks only (ARKit, CoreMotion, CoreBluetooth,
AVFoundation, CoreImage). Tested target hardware: iPhone 15 Pro Max / iPhone 17 Pro (LiDAR).

```
canekit-ios/
├── README.md                ← you are here
└── CaneKit/
    ├── CaneKitApp.swift     App entry, AppModel (wiring + settings), ContentView
    ├── DepthEngine.swift    ARKit sceneDepth → LaneReport (3 lanes × 2 bands), gyro sweep gate, JPEG snapshot
    ├── HapticLogic.swift    LaneReport → "H:<L|R|B>:<1-4>:<ms>\n" with hysteresis + rate limit; spoken warnings
    ├── CaneBLE.swift        CoreBluetooth central for Nordic UART Service, auto-reconnect, "D:<mm>,B:<pct>" parser
    └── SceneDescriber.swift Gemini 2.5 Flash generateContent (image + prompt) → text
```

Data flow:

```
ARSession(.sceneDepth) ─▶ DepthEngine ─▶ LaneReport ─▶ HapticLogic ─▶ CaneBLE.send("H:B:4:250\n")
        │                     │  (main queue)                 └─▶ Speech ("Obstacle ahead, one meter")
        │                     └─▶ jpegSnapshot() ─▶ SceneDescriber ─▶ Speech
CMMotionManager (gyro) ─▶ sweep gate (|ω| ≥ 0.6 rad/s ⇒ frame ignored)
Cane (NUS TX notify) ─▶ CaneBLE ─▶ caneDistanceMM / batteryPercent (UI)
```

---

## 1. Create the Xcode project (≈5 min)

There is no `.xcodeproj` here on purpose — generate it, then drop the files in.

1. Xcode → **File → New → Project → iOS → App**.
   - Product Name: `CaneKit`
   - Interface: **SwiftUI**, Language: **Swift**, Storage: None, Testing: none needed
2. Delete the template `ContentView.swift` and `CaneKitApp.swift` that Xcode generated.
3. Drag the five files from `CaneKit/` into the project navigator (check **Copy items if needed**, target = CaneKit).
4. Target → **General**:
   - Minimum Deployments: **iOS 18.0**
   - Supported Destinations: iPhone only (remove iPad/Mac).
5. Target → **Signing & Capabilities**:
   - Team: your Apple ID (free personal team is fine for a hackathon; the app expires in 7 days).
   - Bundle ID: something unique, e.g. `com.yourname.canekit`.
   - **+ Capability → Background Modes → ✓ Uses Bluetooth LE accessories** (adds `bluetooth-central`).
6. Target → **Info** → add the keys in §2.
7. Target → **Build Settings** (only if you get concurrency *errors*, not warnings):
   - `Swift Language Version` = **Swift 5**
   - `Default Actor Isolation` (Xcode 26+) = **nonisolated**
   - `Strict Concurrency Checking` = Minimal
   The code hops to main explicitly and does not rely on Swift-6 isolation checking.
8. Plug in the iPhone, pick it as the run destination, ⌘R. First launch: on the phone go to
   Settings → General → VPN & Device Management → trust your developer certificate, then launch again.

## 2. Info.plist additions

Xcode 15+ templates have no `Info.plist` file; use **Target → Info → Custom iOS Target Properties**
(right-click → Add Row), or add `INFOPLIST_KEY_…` build settings. Equivalent XML:

```xml
<key>NSCameraUsageDescription</key>
<string>CaneKit uses the camera and LiDAR to detect obstacles ahead of you.</string>

<key>NSBluetoothAlwaysUsageDescription</key>
<string>CaneKit connects to your cane to send vibration alerts and read its sensors.</string>

<key>NSMotionUsageDescription</key>
<string>CaneKit uses motion sensors to tell when the cane is being swept.</string>

<key>NSLocationWhenInUseUsageDescription</key>
<string>CaneKit can use your location to improve scene descriptions.</string>

<key>UIRequiredDeviceCapabilities</key>
<array>
    <string>arkit</string>
    <string>armv7</string>
</array>

<key>UIBackgroundModes</key>
<array>
    <string>bluetooth-central</string>
</array>

<!-- Scene description -->
<key>GEMINI_API_KEY</key>
<string>AIza…your key…</string>
```

Notes:
- `UIRequiredDeviceCapabilities: arkit` keeps non-ARKit devices from installing; it does **not**
  guarantee LiDAR. The app checks `ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)`
  at runtime and shows "No LiDAR / sceneDepth on this device" if it's missing.
- `NSLocationWhenInUseUsageDescription` is included as requested but nothing in the starter calls
  CoreLocation; harmless.
- `GEMINI_API_KEY`: a plain string key in Info.plist. If you'd rather not commit it, put
  `$(GEMINI_API_KEY)` in Info.plist and define `GEMINI_API_KEY` in an `.xcconfig` you git-ignore; the
  code treats an unresolved `$(…)` as missing. For dev runs you can also set it as an environment
  variable in Product → Scheme → Edit Scheme → Run → Arguments.
- Get a key at https://aistudio.google.com/apikey (free tier is enough for a demo).

## 3. Cane protocol (what the firmware must speak)

Nordic UART Service:
| UUID | Role |
|---|---|
| `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` | service (advertise this) |
| `6E400002-…` RX | phone → cane, Write / Write Without Response |
| `6E400003-…` TX | cane → phone, Notify |

Advertised local name must start with **`CANE`** (case-insensitive) — or set `ble.requireName = false`.

Phone → cane (ASCII, newline terminated):
```
H:<motor>:<intensity>:<ms>\n     motor = L | R | B(both)   intensity = 1..4   ms = pulse length
```
e.g. `H:B:4:250\n` (urgent, center), `H:L:2:120\n` (warn, left), `H:R:3:300\n` (test buzz).

Cane → phone (ASCII, newline terminated, any order, unknown keys ignored):
```
D:<mm>,B:<pct>\n     e.g. D:850,B:92\n
```

## 4. First 30 minutes checklist

- [ ] **0–5 min** Project builds and installs on the phone (§1). Camera + Bluetooth prompts appear on first launch. Grant both.
- [ ] **5–8 min** Status line shows "Depth OK" and "Frames:" is counting up. Point at a wall at ~1 m: all six cells ≈ 1.0 m.
      If cells read "—": you're on a non-LiDAR device or the simulator.
- [ ] **8–12 min** Orientation sanity check (see §5.3). Hold the phone upright, put your hand on the **left** edge of the
      view at ~0.5 m: the **Left** cells should go red, not Right. If swapped → toggle **Mirror left / right**.
      Then hold your hand high vs. chest height: **Head** vs **Torso** rows should respond. If the head/torso rows look
      like left/right instead → toggle **Phone held upright**.
- [ ] **12–15 min** Sweep the phone quickly side to side: the yellow **SWEEPING** badge appears and no buzz/speech fires.
- [ ] **15–20 min** Power the cane. State goes Scanning → Connecting → Setting up → **Connected**.
      Press **Test buzz Left / Both / Right** and feel the motors. "Last cmd:" shows what was sent.
      If it never leaves "Scanning": check the advertised name (§3), or set `requireName = false` in `AppModel.init`.
- [ ] **20–25 min** Walk toward a wall. Expect: yellow at 1.5 m + "Obstacle ahead, one and a half meters" + both motors,
      red at 0.8 m + stronger pulse. Walk away: warning clears only after receding an extra 0.15 m (hysteresis).
- [ ] **25–30 min** Press **Describe scene**. You should hear "Describing" then the Gemini sentence within ~2–4 s.
      Errors show in red under the button (`GEMINI_API_KEY is not set…`, HTTP 400/403 = bad key, 429 = quota).

## 5. Known gotchas

### 5.1 `sceneDepth` only exists on LiDAR devices
`ARFrame.sceneDepth` is nil on non-Pro iPhones and on the Simulator. Guard with
`ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)` (done in `DepthEngine.start()`).
The depth map is **256 × 192 Float32** (metres) plus an optional **256 × 192 UInt8 confidence map**
(0 low, 1 medium, 2 high). Values are reliable to roughly 5 m; beyond that confidence drops. Anything
> 4.5 m is displayed as "clear".

### 5.2 ARKit pauses in the background
The camera and `ARSession` stop the moment the app is backgrounded or the screen locks — there is no
background depth. The app disables the idle timer (`isIdleTimerDisabled = true`) so the screen stays on.
For the demo: keep the app foregrounded, Guided Access (triple-click side button) is your friend.
Bluetooth *does* keep working in the background (`bluetooth-central` mode), so the cane's own ultrasonic
"D:" readings still arrive — but nothing in the starter acts on them; that's an obvious extension.

### 5.3 Depth map orientation (the one that bites everyone)
`capturedImage` and `sceneDepth.depthMap` are always delivered in **landscape sensor orientation**
(width 256 > height 192) regardless of how the phone is held. Holding the phone upright (portrait,
camera at the top), the buffer contains the scene rotated 90° counter-clockwise — EXIF orientation 6:

```
                  buffer x →  (0 … 255)
              ┌───────────────────────────┐
 buffer y = 0 │  RIGHT side of scene      │   x = 0    ⇒ TOP of scene (sky / head)
      ↓       │                           │   x = 255  ⇒ BOTTOM of scene (ground)
 buffer y=191 │  LEFT side of scene       │
              └───────────────────────────┘
```

So in portrait, **lanes L/C/R run along buffer rows (y)** — y ∈ [128,192) is LEFT, [0,64) is RIGHT —
and **head/torso/ground bands run along buffer columns (x)**. `DepthEngine.rotateForPortrait` (UI:
"Phone held upright") does exactly this remap: `bufferX = sceneY`, `bufferY = (H-1) - sceneX`. Turn it off
if you mount the phone sideways (landscape-right, home indicator on the right), and use
"Mirror left / right" if the mount points the camera the other way (upside-down portrait). Verify
physically (§4, 8–12 min); don't trust the diagram over your hand.

The same rotation is applied to the JPEG sent to Gemini (`CIImage.oriented(.right)`), otherwise the
model sees a sideways street and clock-face directions will be wrong.

### 5.4 CVPixelBuffer locking
Always `CVPixelBufferLockBaseAddress(_, .readOnly)` before reading and unlock in a `defer`. Use
`CVPixelBufferGetBytesPerRow` for the row stride — it is **not** `width * 4` (rows are padded to 64 bytes).
Both the depth and confidence buffers are locked for the duration of `computeLanes`. Don't keep the
`ARFrame` around: the engine only retains the `capturedImage` pixel buffer (one at a time) for the
snapshot; retaining frames or several buffers makes ARKit drop frames with a console warning.

### 5.5 Ground and the bottom 25 %
The bottom quarter of the upright image is skipped (`groundSkipFraction = 0.25`) so the pavement
doesn't read as a permanent 1 m obstacle. This assumes the phone is mounted roughly level at chest/hip
height on the cane. If the camera tilts down, raise the fraction; if it tilts up you'll miss curbs — a
gravity-based horizon estimate from `frame.camera.transform` is the proper fix.

### 5.6 Sweep gating
`CMMotionManager` gyro magnitude ≥ 0.6 rad/s ⇒ `isSweeping`. During a sweep `HapticLogic` freezes and
sends nothing. Raw gyro has a small bias (< 0.05 rad/s), no calibration needed. If the cane is swept
gently the threshold may never trip — lower it, or use `frame.camera.transform` angular delta instead.

### 5.7 Haptic / speech pacing
- Min 400 ms between commands (`minCommandInterval`), repeat every 1.2 s (warn) / 0.5 s (urgent).
- Speech only on escalation or lane change, 2 s cooldown. Uses the `.playback` audio session so it
  plays with the silent switch on and ducks music.
- Hysteresis 0.15 m prevents flapping at the thresholds.

### 5.8 Bluetooth
- `CBCentralManager` is created on `start()` (first `.task` of ContentView) so the permission prompt
  appears after the UI. Bluetooth permission is separate from camera — both must be granted.
- Writes use Write Without Response when the RX characteristic supports it (NUS does); if the
  radio is busy (`canSendWriteWithoutResponse == false`) the data is queued and flushed on
  `peripheralIsReady`.
- Reconnect: on disconnect the app calls `connect()` again immediately; CoreBluetooth keeps that
  pending indefinitely and completes it when the cane is back in range. No rescan needed.
- If you want reconnection to survive the app being killed in the background, add
  `CBCentralManagerOptionRestoreIdentifierKey` + `centralManager(_:willRestoreState:)` (not in the starter).
- Scan filters by service UUID, so the firmware must put the NUS UUID in its advertisement (Nordic
  samples do). The name may arrive in the scan response; if `CANE` is only in the scan response and
  the first packet has no name, the peripheral is simply skipped until the next packet — fine.

### 5.9 Gemini
- Endpoint: `POST https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent`
  with the key in the `x-goog-api-key` header (`?key=` query param also works).
- `thinkingConfig.thinkingBudget = 0` is set because 2.5 Flash otherwise spends its output budget
  thinking and can return an empty `parts` array with `maxOutputTokens: 120`.
- JPEG is downscaled to 1024 px long edge, quality 0.7 (~150–250 KB); round trip ≈ 2–4 s on LTE.
- Description is spoken with `interrupt: true` so it cuts off any pending haptic warning speech.

### 5.10 Threading model
| Object | Runs on | Publishes on |
|---|---|---|
| `DepthEngine` ARSession delegate | `canekit.depth` serial queue | main (`report`, `onReport`) |
| `CaneBLE` delegates | `canekit.ble` serial queue | main (`state`, telemetry) |
| `HapticLogic.process` | main (called from `onReport`) | main |
| `Speech.say` | any → dispatches to main | — |
| `SceneDescriber.describe` | async, URLSession | main (`lastDescription`) |

## 6. Tuning knobs (all plain `var`s)

| Where | Knob | Default |
|---|---|---|
| `DepthEngine` | `minConfidence` | `.medium` — try `.low` if cells are often "clear" at close range |
| | `groundSkipFraction` | 0.25 |
| | `subsampleStep` | 4 (≈ 24×16 samples per cell in portrait) |
| | `maxProcessingRate` | 20 Hz |
| | `sweepThreshold` | 0.6 rad/s |
| `HapticLogic` | `warnDistance` / `urgentDistance` | 1.5 / 0.8 (toggle → 1.0 / 0.5) |
| | `hysteresis` | 0.15 m |
| | `minCommandInterval` | 0.4 s |
| | `speechCooldown` | 2.0 s |
| `CaneBLE` | `targetName`, `requireName` | "CANE", true |
| `SceneDescriber` | `modelName`, `prompt` | gemini-2.5-flash |

## 7. Things to verify in Xcode (written without a compiler)

1. `@Observable` on `NSObject` subclasses that adopt `ARSessionDelegate` / `CBCentralManagerDelegate`
   (`DepthEngine`, `CaneBLE`) — this is a supported pattern but the macro is picky about
   `@ObservationIgnored` on every non-observed stored property; if it complains, add the attribute.
2. `@Bindable var model = model` at the top of `ContentView.body`, then `settingsSection($model)` taking
   `Bindable<AppModel>` — the dynamic-member `Binding`s (`model.extendedRange`) should type-check.
3. `CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)` —
   needs `import ImageIO` (present). If the initializer signature differs, use `[.init(rawValue: …): 0.7]`.
4. Property observers (`didSet`) on `@Observable` stored properties in `AppModel` — supported since the
   macro's introduction, but check the settings toggles actually reach `applySettings()`.
5. Swift language mode / default actor isolation (§1 step 7) if you see "call to main actor-isolated …"
   errors in the delegate methods.
