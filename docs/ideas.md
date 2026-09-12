# Ideas: retrofit smart-cane kit

> **Status banner (written Fri 2026-09-11 after build Step 10; markers refreshed Sat 2026-09-12 after Step 37).** This file is
> the original pitch and plan, compiled Thu Sep 10. It is kept as history. Statements that no longer
> describe the build are marked inline (**[Superseded]**, **[Changed]**, **[Status]**, **[Built]**,
> **[Not built]**, **[Answered]**, **[Moot]**); nothing was deleted. For
> what the app does today read [`AGENTS.md`](../AGENTS.md), [`docs/CODE_REFERENCE.md`](CODE_REFERENCE.md),
> [`docs/design.md`](design.md) (UI and cue design, audited against the code) and
> [`CHANGELOG.md`](../CHANGELOG.md) / [`docs/todo.md`](todo.md) (build log and checklist).
>
> | Area | Plan in this file | What shipped / changed | Details |
> |---|---|---|---|
> | Computer | iPhone + XIAO ESP32-S3 grip over BLE | **Phone-only.** The iPhone 17 Pro Max (iOS 27, app targets iOS 26) is the only computer. No ESP32, no grip motors, no ToF pod, no chest plate, nothing bought. `firmware/`, `cad/` and `ios/stretch/CaneBLE.swift` are kept as stretch/history only. | §9 below, [`AGENTS.md`](../AGENTS.md), `CHANGELOG.md` Step 0 |
> | Cane | Ambutech 12.7 mm white cane | A non-metal stick (a broom handle), phone on a 3D-printed mount (Lamicall bike mount as insurance). **[Changed, Sep 12]** The shaft measured 27.65 mm on the printed bore rings, not the 28.75 mm used below; the live mount is the screwless one in `hardware/mount_screwless/` | §7, §9, [`hardware/README.md`](../hardware/README.md) |
> | Obstacle haptics | Two ERM motors in the grip | The phone's Taptic Engine through the clamp: centre Geiger loop (2 → 8 Hz), left 2 taps, right 3 taps, head-height double hit + "Head height."; mirrored to the watch when the phone can't buzz | [`design.md` §5.2](design.md) |
> | Wrist | Watch for turns + ESP32-failure fallback; crown / side button = Next (§7) | Apple Watch is a core channel: turn / crossing / arrival taps; Repeat, Next, Describe, Recenter buttons; crown 3 detents = Next (no side-button API) | [`design.md` §6.6](design.md), [`devices_setup.md`](devices_setup.md) |
> | Audio | Bone-conduction / open-ear only | AirPods Pro: speech (ElevenLabs natural voice with a system-voice fallback) and an HRTF beacon; head yaw from `CMHeadphoneMotionManager` (the head-pose entitlement needs a paid team) | [`ios/README.md` §2](../ios/README.md) |
> | Demo route | 8–12 waypoints recorded on foot Friday | [`route_isr_cif.json`](../ios/CaneKit/Resources/route_isr_cif.json): 9 OSM-derived waypoints, ISR **Townsend Hall** → CIF east entrance, 989 m, crossings at Green St, Goodwin (at Springfield) and Mathews; **not yet walked** | [`route_isr_cif.md`](route_isr_cif.md) |
> | Scene read | Gemini Flash on a tap | "Where am I": custom OpenAI-compatible (Muse 1.3) / Anthropic / Gemini / OpenAI, chosen in `Secrets.plist`; Action button App Shortcut, watch, on-screen button; Camera Control unverified under ARKit | [`ios/README.md` §4](../ios/README.md) |
> | Day-2 list | Live Activity, YOLO, OCR, MTD, events | Live Activity **shipped** (Step 10). **[Built, Step 11]** on-device sign reading (Vision text), Apple's on-device language model for "Where am I" (`FoundationModels`), hazard map (GeoJSON). **[Built, Steps 13 and 23]** voice commands and the conversational assistant, with `SFSpeechRecognizer` (not SpeechAnalyzer). Still not built: YOLO names, SpeechAnalyzer, UWB, MTD buses, calendar events, Aira handoff, "find my cane" chirp | §5.2, §5.4, `CHANGELOG.md` |
> | Added, not in the plan | — | MapKit "any destination"; trip card (distance, minutes, steps via HealthKit / pedometer); JSONL trip log; AirPods / watch presence announcements; Repeat everywhere | `CHANGELOG.md` Steps 6–10 |
<<<<<<< HEAD
> | Code state | "uncompiled starter code" | **Historical Step 10 snapshot:** builds under Swift 6 strict concurrency; 79 logic tests, 6 XCUITests and a screenshot tour on the iPhone 17 Pro Max / iOS 27 simulator. **[Status, Sep 12]** After Step 37 the Logic package has 457 `@Test` annotations and 11 XCUITests (Step 37 run: 457/457, uitest 10 passed + 1 skipped, e2e PASS), and the build has been installed on the phone; current state is tracked in [`ios/README.md`](../ios/README.md) | [`docs/todo.md`](todo.md) |
=======
> | Code state | "uncompiled starter code" | **Historical Step 10 snapshot:** builds under Swift 6 strict concurrency; 79 logic tests, 6 XCUITests and a screenshot tour on the iPhone 17 Pro Max / iOS 27 simulator. The current checkout is tracked in [`ios/README.md`](../ios/README.md) and has 378 Logic-test annotations; device tests pending | [`docs/todo.md`](todo.md) |
>>>>>>> 21b1717 (Step 29: interlock AR sensor mode restarts during routes)
>
> "Shipped" above means the Step 10 build. Work in progress on Sep 11 when this banner was written: a
> hazards layer (LiDAR drop-off / pothole / curb detection, on-device sign reading, a periodic vision
> "hazard watch", a shareable hazard map; `CaneKitLogic/Hazards.swift`, `UI/HazardsCard.swift`) and a
> distance-based course smoother for veer cues. **[Built, Step 11]** Both landed (`CHANGELOG.md` Step 11),
> so the "curbs", "OCR" and "hazard map" notes below that say not built describe the Step 10 build only.
> Ground-hazard warnings and the hazard watch ship off by default until tuned on the cane.

Founders hackathon, Champaign-Urbana, Sat Sep 12 – Sun Sep 13 2026.
Owners: Aritro = software (iPhone is the brain). Sagar = 3D printing + cane hardware. Aarav joins the team.

Compiled Thu Sep 10. Amazon prices unverified. ~~All code in this repo is uncompiled starter code.~~
**[Superseded]** The app now builds and is simulator-tested (see the banner).

---

## 0. One-liner

**Clip three parts onto the cane you already own. Your phone does the rest. Head-level protection for $60, not $850.**

Retrofit, not replacement. User keeps the cane their O&M instructor trained them on. Kit clips onto any 1/2" or 7/8" shaft in under a minute, unclips in five seconds. Pull the battery and it's still a white cane.

**[Superseded]** for the build: there are no clip-on electronics and no battery. The kit is one printed
phone mount; the phone, watch and AirPods are ones the user already owns. "Pull the battery" becomes
"unclip the phone: still a cane".

---

## 1. Verdict

| Decision | Call | Why |
|---|---|---|
| Cane | Ambutech 4-section folding, 1/2" (12.7 mm) shaft, or whatever stick we have | Clamp everything to the solid top section. Folding canes have an elastic cord inside: never drill. |
| Brain | iPhone 17 Pro Max, native Swift, ARKit LiDAR | All 3 team phones (17 Pro Max, 17 Pro, 15 Pro Max) have LiDAR. Web Bluetooth doesn't work on iOS Safari; Expo Go can't do BLE. Native is the only fast path. |
| Cane module | XIAO ESP32-S3 + 2 coin ERM motors in a printed grip, BLE from phone | Left buzz / right buzz / both = stop. Fail-safe: no BLE for 5 s → local mode or silent. |
| ToF pod at base | Stretch, not core | Cane tip already finds the ground. What the cane can't see is waist-to-head. |
| iOS version | Build on iOS 26 APIs | iOS 27 ships Mon Sep 14, one day after demo. Xcode 27 RC is out. iOS 27-only features (Foundation Models image input) are optional, never required. |
| Biggest risk | Parts not arriving by Saturday | Amazon order before midnight Thursday. Adafruit/SparkFun/DigiKey won't make it. |

**[Superseded]** rows: *Cane* (a 28.75 mm stick, §7), *Cane module* (no ESP32; the phone's Taptic Engine
shakes the cane, §9) and *Biggest risk* (nothing was ordered; the risks became GPS accuracy at the ISR
door, haptic feel through the clamp and device time; see the go/no-go list in `ios/README.md` §5).
*Brain* and *iOS version* stand: native Swift on iOS 26 APIs, built with Xcode 27 RC for an iOS 27 phone.

---

## 2. Three pushbacks on the original brief

### 2.1 A camera on a sweeping cane sees motion blur
2025 study, same camera on head vs cane: head-mounted tracking >98%; cane-mounted 55–58% outdoors. Holding the cane still raised it to 83%. Blind participants rated chest mount 4.0/5 comfort vs cane 3.1/5. https://arxiv.org/html/2504.19345v1

**Fix that keeps the concept:** gate capture on the gyro. Sample depth at the two sweep endpoints (angular velocity crosses zero) and when the cane pauses. LiDAR depth is far less blur-sensitive than RGB tracking anyway. Say this on stage as a feature: "sweep-aware capture."
**Hedge:** phone clamp has a GoPro knuckle; the same holder snaps onto a chest plate (`cad/chest_plate.scad`).
**[Status]** Sweep-aware capture shipped (depth is trusted only while |ω| < 0.6 rad/s; cues freeze while
sweeping). The chest plate was not printed or tested; `cad/chest_plate.scad` is an unrendered draft.

### 2.2 The cane tip already finds the ground
A ToF at the tip duplicates what the tip does by touch, 0.5 s earlier. What a cane cannot do is waist-to-head: 13% of blind travelers hit their head at least monthly, 23% of those needed medical care, 86% outdoors (branches, signs, poles). https://users.soe.ucsc.edu/~manduchi/papers/MobilityAccidents.pdf

**Fix:** phone LiDAR overhead/torso warning is the core demo. Pitch line: "the cane covers the ground; we cover everything above it."

### 2.3 "A to B in rain and dark" needs careful wording
GPS is ~4.9 m under open sky, worse near buildings (https://www.gps.gov/gps-accuracy). It can't tell which side of a curb you're on. Consumer ToF loses range in sun; water on the window gives false reads.

**Fix:** don't build routing. Hand off to MapKit walking directions and convert turn events to haptics. Own the last 5 m: obstacles, curbs, doors. Dark is our friend: LiDAR works better in the dark than cameras. Demo in a dim room. For rain: "IP68 phone, hooded sensor, cane works dry or wet." Don't promise more.
**[Status]** Built as planned in spirit: a recorded waypoint file for the demo, MapKit walking
directions for any typed destination, turn / crossing cues on the watch. Not in the Step 10 build: curb
detection (the obstacle lanes skip the bottom 25 % of the depth image so pavement never reads as an
obstacle; a separate LiDAR drop-off / curb detector is in progress, see the banner) and the hooded sensor.
Doors are named indoors only ("door ahead, two meters"; mesh classification fails in sunlight).

### Smaller
- Bone conduction / open-ear only. Masking traffic is a safety failure. https://www.mdpi.com/1424-8220/22/14/5454 **[Superseded]** by AirPods Pro (§7): speech and the beacon go to AirPods; keep traffic audible with Transparency. The app never plays obstacle sounds.
- Haptics strong and rare. BuzzClip failed in a 2026 trial: "too weak," "too frequent," confused with normal cane feel. Two motors, ≤4 intensity levels, silent by default. https://www.nature.com/articles/s41598-026-37578-9 **[Status]** The principle held; the channel changed: the phone's Taptic Engine plays four distinct patterns (tap count, not motor side, tells left from right), discrete cues re-fire at most once a second, and nothing buzzes when the path is clear.
- Speaker on the cane: broadcasts the user's disability to the street and masks traffic. One use only: "find my cane" chirp. Everything else goes to headphones. **[Status]** No chirp was built. The beacon only plays into headphones; speech falls back to the phone speaker when no headphones are connected (and the app says so).
- Fitness / social features: scope trap. Every non-safety feature makes judges ask "who is this for?" Keep fitness to the arrival card (steps via HealthKit). Social = one slide. **[Status]** Held: the only fitness surface is the trip card (distance, minutes, steps).

---

## 3. Form factor (Sagar)

**[Superseded]** by §9 (phone-only, Sep 10 night). Of the modules below only **B, the phone mount**, is
part of the build, on a 28.75 mm shaft (not 12.7 mm). A, C and D are stretch drafts; the `cad/` files
still use the 12.7 mm shaft and have never been rendered.

Side view: grip module at the top, phone clamp 6 cm below the grip, optional sensor pod near the base, stock tip.

| Module | What's in it | Print |
|---|---|---|
| A. Grip module | XIAO ESP32-S3, 2× 10 mm coin ERM motors (thumb + index positions), 500 mAh LiPo, M3 join, wire channels | `cad/grip_module.scad` (custom, unrendered). Split PETG sleeve, TPU overgrip optional. |
| B. Phone clamp | Pole grip (12.7 mm) → GoPro knuckle → spring phone clamp. Rear camera faces forward-up. Close to the hand = short lever arm on the wrist. | Pole grip: https://github.com/j-h-a/go-pro-mounts (OpenSCAD, set `poleDiameter=12.7`, `poleClearance=0.3`). Clamp: https://www.printables.com/model/145012 (CC BY-SA, fits 69.5–86 mm phones; 17 Pro Max = 78 mm). Needs M3×50 + nut, ~30 mm compression spring, M5×20 + nut. |
| C. Sensor pod (stretch) | VL53L1X in a hooded tube clamp, aimed at the ground 0.6–1 m ahead | `cad/sensor_pod.scad`, or https://makerworld.com/en/models/1009606-esp32-c3-super-mini-vl53l1x-tof-sensor-case + https://www.printables.com/model/1214545-print-in-place-tube-clamp-fully-parametric |
| D. Chest plate (hedge) | Flat plate, 25 mm webbing slots, GoPro 3-prong | `cad/chest_plate.scad` |
| Tip (optional) | 608-bearing roller tip | https://www.printables.com/model/699705-white-cane-tip (made for M8 threaded canes) |
| Fallback mount | Lamicall bike mount, shim to 12.7 mm | https://www.amazon.com/Lamicall-Bike-Phone-Holder-Mount/dp/B08R8MZYMH |

Nobody has published a cane grip with an ESP32 + motor cavity (checked Printables, Thingiverse, MakerWorld, Cults, GitHub). Everything else exists.

Shaft diameters (verified): Ambutech aluminum/graphite folding 12.7 mm; fiberglass 22.2 mm; Slimline graphite 9.5 mm. Make clamps parametric for 12.7 and 22.2 with a TPU shim.

Reference designs: Stanford AugmentedCane https://github.com/pslade2/AugmentedCane (`cane_hull.stl`, BOM), Hackaday Digital White Cane https://hackaday.io/project/27111-digital-white-cane (DRV2605L wiring), https://github.com/manishmeganathan/smartwalkingcane (MIT, haptic firmware).

Print schedule Friday (3 printers): P1 phone clamp ~2.5 h → sensor pod ~1 h. P2 pole grip ~1 h → chest plate ~1.5 h. P3 grip module ~3 h.

---

## 4. Buy list (order Thursday night, Amazon only)

**[Superseded]** Nothing on this list was needed (§9: "buy nothing"). Kept for the stretch grip / pod and
as a record of prices.

| Qty | Part | Link | ~$ | Notes |
|---|---|---|---|---|
| 1 | Ambutech aluminum folding cane, 1/2" | https://www.amazon.com/Ambutech-Alum-4-Section-Folding-Cane-Marsh-36-in/dp/B007SMPE8Q | 40 | Length = sternum height of tallest teammate |
| 1 | Generic folding cane (spare) | https://www.amazon.com/VISIONU-White-Aluminum-Folding-sections/dp/B06XTSRXB9 | ~20 | To destroy while fitting clamps |
| 2 | Seeed XIAO ESP32-S3 | https://www.amazon.com/ESP32S3-2-4GHz-Dual-core-Supported-Efficiency-Interface/dp/B0BYSB66S5 | ~12 ea | BLE 5, onboard LiPo charge, 21×17.5 mm. 5V pin dead on battery. |
| 1 | ESP32-C3 SuperMini 3-pack | https://www.amazon.com/Suuoo-3-Pack-ESP32-C3-Development-Bluetooth/dp/B0GX966R9R | ~12 | Spares + pod MCU. No charger; needs TP4056. |
| 1 | 10 mm coin ERM motors ×10 | Amazon search "10mm coin vibration motor 3V" | ~10 | 2–5 V, 60–100 mA. Fragile; buy a pack. |
| 1 | VL53L1X ToF | https://www.amazon.com/VL53L1X-Time-Flight-Distance-Sensor/dp/B09K4V92H1 | ~15 | Stretch pod |
| 1 | JSN-SR04T waterproof ultrasonic | https://www.amazon.com/Waterproof-Ultrasonic-JSN-SR04T-Transducer-Electronic/dp/B07KDPFRCP | ~10 | Rain story only. Optional. |
| 1 | TP4056 USB-C 3-pack | https://www.amazon.com/HiLetgo-Lithium-Charging-Protection-Functions/dp/B07PKND8KG | ~8 | Only for SuperMini |
| 2 | 3.7 V 500 mAh LiPo JST-PH | Amazon search "3.7V 500mAh lipo JST PH 2.0" | ~14 | ~29×36×4.75 mm. XIAO uses pads, not JST; check polarity. |
| 1 | MPU-6050 | Amazon search "MPU-6050 GY-521" | ~6 | Optional; phone gyro can gate sweeps |
| 1 | Lamicall bike mount (fallback) | https://www.amazon.com/Lamicall-Bike-Phone-Holder-Mount/dp/B08R8MZYMH | 30 | Insurance |
| 1 | Shokz OpenMove | https://www.amazon.com/Shokz-OpenMove-Headphones-Conduction-Sweatproof/dp/B09BW29FJS | 56–80 | Optional; any open-ear BT works |
| – | M3×50 + nuts, M5×20 + nuts, ~30 mm spring, zip ties, spiral wrap, Dual Lock, heat shrink, 22 AWG wire, 2N2222 + 1 kΩ, 1N4148 | ECEB 1041 (free) · ECEB 1031 · Ace / Lowe's | ~15 | |

Core ≈ $110. With fallbacks + headphones ≈ $200.

### Local sourcing (Friday)
- **ECE Supply Center, ECEB 1031** (306 N. Wright St, first floor by loading dock). Fri 9–12, 1–3:30. UIUC students, in person, personal funds. No Saturday. Catalog: https://my.ece.illinois.edu/storeroom/catalog.asp. https://ece.illinois.edu/about/supplycenter
- **ECE Services Shop, ECEB 1041** (first floor near cargo elevator). Free self-service: transistors, MOSFETs, resistors, motors, connectors, some MCUs. Inventory: https://docs.google.com/spreadsheets/d/1InSHH3_mebTMyk4SWF0S2R67ZWSWq7FpKZRyKWeDHm0/edit — https://courses.grainger.illinois.edu/ece445/lab/getting-parts.asp
- Nearest Micro Center is Chicago. Not happening.

---

## 5. Software (Aritro): the phone is the product

### 5.1 Architecture (phone-only, see §9; superseded the ESP32 diagram on Sep 10; re-checked against the code Sep 11)

```
iPhone 17 Pro Max (clamped to the shaft)
  ├─ ARKit sceneDepth + smoothedSceneDepth (LiDAR, ~5 m) → 3 cols × 2 rows lanes (torso / head), 10th-pct depth per cell, 15 Hz
  ├─ ARKit meshWithClassification → door / wall / seat / window / table at screen center (indoors; sunlight kills it) → spoken name
  ├─ Core Motion gyro → sweep gate (frame trusted only when |ω| < 0.6 rad/s)
  ├─ CueDecider (CaneKitLogic: hysteresis + rate limit) → HapticPlayer (Core Haptics, phone Taptic Engine) → the cane shakes
  │     center: tap rate ∝ 1/distance (2 Hz @ 2 m → 8 Hz @ 0.5 m) · left: 2 taps · right: 3 taps · head row: sharp double hit
  ├─ SpeechQueue (ElevenLabs natural voice, AVSpeechSynthesizer fallback; scene < obstacle < route < "Head height.") → AirPods
  ├─ WatchConnectivity → Apple Watch: turn / crossing / arrived on the wrist; crown + buttons = Repeat / Next / Describe / Recenter;
  │     mirrors obstacle cues whenever the phone cannot buzz (engine down or silenced)
  ├─ CLLocationUpdate.liveUpdates + heading + waypoint geofences with turn settling (route_isr_cif.json; MapKit walking for any destination)
  ├─ AVAudioEnvironmentNode HRTF beacon into headphones only; head yaw from CMHeadphoneMotionManager (AirPods Pro), compass-only without it
  ├─ "Where am I": Action button App Shortcut / watch / on-screen button (Camera Control spiked) → one JPEG → VLM (Muse, Anthropic, Gemini, OpenAI) → speech
  └─ HealthKit / pedometer steps + elapsed + GPS distance → trip card · Live Activity in the Dynamic Island · thermal: mesh off at .serious
```

Code: `ios/` — see `ios/README.md` for the build workflow, the verified spec deviations (head-pose entitlement,
watch side button, Camera Control) and the test strategy. Build log: `CHANGELOG.md`.
The ESP32 protocol (`H:<L|R|B>:<1-4>:<ms>`, `P:<1-4>`, `S:<0|1>`, `D:<mm>,B:<pct>`) lives on in `firmware/` and
`ios/stretch/CaneBLE.swift` for the stretch goal only.

### 5.2 iPhone 17 Pro Max exploits, ranked by payoff ÷ hours

| # | Exploit | h | Build? | Doc |
|---|---|---|---|---|
| 1 | LiDAR obstacle radar: `sceneDepth` + `confidenceMap`, use `smoothedSceneDepth` | 3 | core | https://developer.apple.com/documentation/arkit/arframe/scenedepth |
| 2 | Mesh classification: door/wall/floor/seat/window/table/ceiling, raycast | 3 | core | https://developer.apple.com/documentation/arkit/armeshclassification |
| 3 | Head-tracked audio beacon: `AVAudioEnvironmentNode.isListenerHeadTrackingEnabled` (iOS 18+, needs head-pose entitlement) or `CMHeadphoneMotionManager` + own panner | 4 | core if AirPods | https://developer.apple.com/documentation/avfaudio/avaudioenvironmentnode/islistenerheadtrackingenabled |
| 4 | Speech + Core Haptics cadence: interruptible utterances, ducking, distance-scaled taps on phone | 2 | core | https://developer.apple.com/documentation/corehaptics |
| 5 | `CLLocationUpdate.liveUpdates` + `CLHeading` + `MKDirections` `.walking` | 3 | core | https://developer.apple.com/documentation/corelocation/cllocationupdate |
| 6 | Action button → App Shortcut "Where am I?"; Camera Control → `AVCaptureEventInteraction` describe-on-press | 2 | core | https://developer.apple.com/documentation/avkit/avcaptureeventinteraction |
| 7 | Vision `RecognizeTextRequest`, accurate, `customWords` = room list | 2 | day 2 | https://developer.apple.com/documentation/vision/recognizetextrequest |
| 8 | YOLO26n Core ML, 3.2 ms detect on iPhone 17 Pro (Ultralytics). Names the obstacle. | 3 | day 2 | https://docs.ultralytics.com/integrations/coreml/ |
| 9 | Live Activity / Dynamic Island: next turn + distance on lock screen | 2 | day 2 | https://developer.apple.com/documentation/activitykit |
| 10 | Foundation Models on-device. iOS 26 text-only `@Generable`; iOS 27 adds image input + OCRTool. No network, no key. | 4 | only if iOS 27 | https://developer.apple.com/documentation/foundationmodels/analyzing-images-with-multimodal-prompting |
| 11 | `SpeechAnalyzer` on-device voice: "take me to CIF" | 2 | stretch | https://developer.apple.com/documentation/speech/speechanalyzer |
| 12 | UWB door beacon via `NearbyInteraction` + third-party accessory (Qorvo DWM3001CDK). AirTags NOT exposed to apps. | 8+ | slide | https://developer.apple.com/documentation/nearbyinteraction |

**[Status]** Shipped: #1, #2 (indoor names), #3 via `CMHeadphoneMotionManager` (the
`isListenerHeadTrackingEnabled` path needs the paid-team Head Pose capability, `ios/README.md` §2), #4,
#5, #6 (Action button "Where am I" App Shortcut; the Camera Control press is spiked but unverified while
ARKit owns the camera), #9. Not built: #7 (on-device sign reading is in progress, see the banner), #8, #10, #11, #12.

Constraints: camera cannot run in the background on iPhone; app stays foregrounded (screen may dim). Watch `ProcessInfo.thermalState`: at `.serious` drop mesh classification, then YOLO, keep LiDAR lanes. **[Status]** The app keeps the screen awake (idle timer off) and drops mesh classification at `.serious` / `.critical`; there is no YOLO to drop. Lanes and haptics never stop.

Cloud VLM: Gemini 2.5 Flash `generateContent`, $0.30/M input tokens, free tier. Skip Live API (2-min video session cap, ≤1 fps). OpenAI Realtime is ~10× the price. **[Status]** The app supports four providers; `VLM_PROVIDER` in `Secrets.plist` pins one (falling back to any other configured key), otherwise the first key found in this order wins: custom OpenAI-compatible (default model `muse-1.3`), Anthropic (`claude-opus-5`), Gemini (`gemini-2.5-flash`), OpenAI (`gpt-4o-mini`). Prompt: one sentence, under 20 words, clock-face directions, metres, hazards first.

### 5.3 The A→B demo: ISR → CIF

Route: ISR front desk (918–1012 W Illinois St, ~40.1095, -88.2214) → W on Illinois St ~180 m → N on Goodwin Ave ~410 m → W on Springfield Ave ~370 m → CIF east entrance (1405 W Springfield, ~40.1125, -88.2283). ~1.0 km, 13–17 min at cane pace. Crossings: Illinois/Goodwin, Green/Goodwin, Springfield/Goodwin, Springfield/Mathews, (Springfield/Wright for west door). APS presence unverified. Walk it Friday, note which beep.

**[Superseded]** by [`docs/route_isr_cif.md`](route_isr_cif.md). The start is the **Townsend Hall** doors
(the ISR front doors at Townsend's SW corner, 40.10949, -88.22135) and the end the CIF east entrance at
40.11242, -88.22788. Legs: plaza path to Illinois St (~81 m walked), W on Illinois ~176 m, N on the east
side of Goodwin ~415 m, W on Springfield ~293 m, then ~48 m to the door; 989 m of chords. Illinois/Goodwin
is **not** crossed (the route stays on the east side of Goodwin) and Wright is not on the east-door route:
the crossings are Green St, Goodwin at Springfield, and Mathews. APS beeps are still unverified.

**Decision: don't trust live routing for the demo.** Build on a hand-verified waypoint file (8–12 points, instructions, crossing flags) recorded Friday. Live MapKit = fallback / "any destination" mode. Judges see identical guidance; we control failure modes.
**[Status]** Decision held, but the file shipped before the walk: 9 waypoints taken from OpenStreetMap,
still to be re-recorded on foot (the list is in `docs/route_isr_cif.md`). MapKit "any destination" is
built (type a place, tap Go).

Waypoint schema (`ios/route_isr_cif.json`, to be recorded):
```json
{ "id": 3, "lat": 40.1103, "lon": -88.2236, "radius_m": 15,
  "say": "Goodwin Avenue. Crossing. Listen for traffic.",
  "crossing": true, "bearing_next_deg": 355 }
```
**[Superseded]** The file is [`ios/CaneKit/Resources/route_isr_cif.json`](../ios/CaneKit/Resources/route_isr_cif.json),
and each waypoint also has a short `name` (for "Passed <name>.") and an optional `curved` flag. This example
is illustrative only: the real WP3 at Goodwin is a turn (`crossing: false`, 12 m fence).

| Layer | User gets | How | Fallback |
|---|---|---|---|
| Bearing | Continuous "which way" without words | Head-tracked beacon, or phone heading + stereo pan | L/R grip buzz every 3 s when off-bearing >25° |
| Turns and crossings | "Goodwin Avenue. Crossing. Listen for traffic." | Geofence per waypoint, 15 m radius, speak once | Manual "next" via Action button |
| Obstacles waist-to-head | Buzz at 1.5 m; hard buzz + "sign ahead, right" at 0.8 m | sceneDepth lanes → BLE → grip | Phone Core Haptics if grip drops |
| Doors, walls, seats | "Door ahead, two meters" | meshWithClassification raycast | Skip; pitch it |
| Scene read | "Sidewalk, bike rack left, crosswalk ahead" | Tap / Camera Control → Gemini Flash | Pre-cached description per waypoint |
| Signs, room numbers | "CIF. Room 0035." | Vision RecognizeTextRequest | – |
| Arrival | "CIF east entrance. 1.0 km, 14 min, 1,300 steps." | Geofence + HealthKit | – |

**[Status]** per layer, as built (details in [`docs/design.md` §5](design.md)):
- *Bearing*: head-tracked HRTF beacon into headphones (compass-only without AirPods motion). The fallback is not a grip buzz but "Veer left." / "Veer right." plus a wrist tap after 3 s off by > 25° (10 s cooldown).
- *Turns and crossings*: 15 m fences, 12 m at the three turns, 20 m arrival; the recorded line is spoken once; the wrist gets a turn or crossing tap; at a crossing the beacon goes quiet until you stop at the curb. Manual Next is on the watch (button or crown) and the phone; the Action button runs "Where am I", not Next.
- *Obstacles*: phone Taptic Engine, not BLE: head row < 1.5 m (double hit + "Head height."), centre < 2 m (Geiger taps), sides < 1.2 m (2 / 3 taps). The watch is the fallback when the phone cannot buzz. No "sign ahead, right": obstacles are not named outdoors.
- *Doors, walls, seats*: built ("door ahead, two meters"), indoors.
- *Scene read*: built without the pre-cached per-waypoint fallback.
- *Signs, room numbers*: not in the Step 10 build (on-device sign reading is in progress, see the banner).
- *Arrival*: built; spoken as "<last waypoint line>. 1.0 kilometers, 14 minutes, 1300 steps." with steps from HealthKit or the phone pedometer.

Campus data: MTD API (free key, `getdeparturesbystop`) https://developer.mtd.org/ ; UIUC calendar feeds likely `https://calendars.illinois.edu/ical/7.ics` (unverified); DRES pays for Aira on campus (handoff button = one deep link) https://dres.illinois.edu/community/accessibility-transportation/aira-on-demand-description-service/

### 5.4 Brainstorm: sorted by what to build

**Build (demo beats)**
- Sweep-aware capture. Gyro gates depth frames at sweep endpoints. Turns the blur objection into a named feature. **[Built]** (frames trusted only while |ω| < 0.6 rad/s).
- Crossing protocol. Stop cue (both motors long) → "Goodwin Avenue, two lanes, listen" → tap to confirm → beacon re-aims at far curb. **[Changed]** Wrist `.notification` + the recorded crossing line ("… Crossing. Signalized, push button. Listen for traffic …"); the beacon is silent until you stop at the curb or turn, then aims down the next leg by itself. No confirm tap.
- Head-height guardian. Top row of lanes only. Own cue: short double-buzz both. **[Built]** on the phone Taptic Engine (hard double hit) plus "Head height." once per obstacle.
- "What's here?" Action button → one-line scene read with clock-face directions. **[Built]** as "Where am I".
- Dumb-cane proof. Pull the battery on stage. Snap the module off in 5 s. **[Changed]** No battery or module: unclip the phone.
- Arrival card. Distance, minutes, steps. The fitness hook without a fitness app. **[Built]** as the inline trip card.

**Day 2 if ahead**
- YOLO object names. Vision OCR for room numbers. Live Activity. **[Status]** Live Activity built; YOLO and OCR not in the Step 10 build. **[Built, Step 11]** On-device sign reading (Vision text) landed; YOLO names are still not built.
- MTD: "Next 22 Illini in 4 min at Goodwin & Illinois." ~1.5 h, very Champaign. **[Not built]**
- Events along route from the UIUC calendar feed: "Quad Day booth 40 m on your right." ~2 h. This is the social layer. **[Not built]**

**Slide only**
- Fitness reminders. Scope trap.
- Indoor: UWB anchors / DL-TDOA (iOS 27, no entitlement) / iBeacon per door. Roadmap.
- Route memory: record a walk once with a sighted friend, replay forever (waypoint file productized).
- Community hazard map: every obstacle hit becomes a pin others get warned about. Network effect.
- Aira handoff button.

### 5.5 Day plan

**[Superseded]** This was the ESP32 plan. The software was built Thu night – Fri (Steps 0–10 in
`CHANGELOG.md`); nothing was ordered or flashed. The milestone became "walk at a wall → the cane shakes"
from the phone's Taptic Engine (`docs/todo.md` Step 3), and the Friday afternoon walk now re-records the
route file ([`docs/route_isr_cif.md`](route_isr_cif.md)).

| When | Do |
|---|---|
| Thu night | Amazon order. |
| Fri 9–15:30 | ECEB 1031 + 1041. Ace for bolts/spring. Prints start. |
| Fri afternoon | Two people walk ISR→CIF with the app logging GPS. Waypoint file. |
| Fri eve | Xcode project from `ios/`. Firmware flashed. nRF Connect → motor buzz. |
| Sat H0–H2 | Hardware fits clamp + grip. iOS prints depth lanes. Firmware echoes BLE. |
| Sat H2–H6 | **Milestone:** walk at a wall → motors fire. If not by H6, cut everything else. |
| H6–H12 | Lane tuning in a hallway. Speech. Gemini tap. Head-height box test. |
| H12–H16 | Outdoor night walk. Waypoint cues. Sweep gating. Battery + overgrip. |
| H16–H20 | Stretch: ToF pod, chest plate, MTD. Or shoot the demo video (backup for live failure). |
| H20–H24 | Pitch, slides, rehearse blindfold demo twice. Charge everything. Spare cane. |

Demo script (3 min): 1) blindfolded teammate, plain cane, walks into head-height box. 2) Same walk with kit: buzz at 1.5 m, "sign ahead, right" at 0.8 m, steps left. 3) Lights off, repeat. 4) Tap: "hallway, door on left, two people ahead." Pull battery. Still a cane.
**[Status]** With the build: step 2 is the head-height double hit at < 1.5 m plus "Head height." (no
"sign ahead, right"); step 4 is "Where am I" (needs a VLM key and network); the ending is "unclip the
phone". Run the go/no-go list in `ios/README.md` §5 before any blindfolded walk.

---

## 6. Pitch

**[Status]** The numbers and prior art below still stand. The 90-second script and the slides describe
the original three-part kit (grip with two motors, sensor pod, $99) and say "nothing in your ears"; the
build is a phone mount plus the phone, watch and AirPods Pro the user already owns, and it speaks and
clicks in the AirPods. Rewrite those lines before pitching the build (see the notes after the script).

### Numbers (sourced)
| Claim | Number | Source |
|---|---|---|
| Blind people worldwide (2020) | 43.3 M | https://pure.johnshopkins.edu/en/publications/trends-in-prevalence-of-blindness-and-distance-and-near-vision-im/ |
| US vision impairment / blind | ~7 M / ~1 M | https://www.cdc.gov/vision-health/data-research/vision-loss-facts/index.html |
| Visually impaired who use a white cane | 2–8% | https://www.fightforsight.org.uk/news-and-insights/news/social-change/white-canes-myth-busting-and-learning/ |
| Top barrier to smart canes: cost | 67% | https://link.springer.com/chapter/10.1007/978-3-031-05039-8_36 |
| Head injuries monthly / needed medical care | 13% / 23% | https://users.soe.ucsc.edu/~manduchi/papers/MobilityAccidents.pdf |
| WeWALK Smart Cane 2 | $850 + $4.99/mo | https://techcrunch.com/2025/01/10/these-startups-are-making-smarter-canes-for-people-with-visual-impairments |
| Glidance Glide | $1,499 + $30/mo | https://www.glidance.io/frequently-asked-questions |
| biped NOA | €4,990 | https://www.applevis.com/forum/assistive-technology/my-sightcity-impressions-about-noa-mobility-device-biped-ai |
| .lumen glasses | €9,999 | https://www.dotlumen.com/glasses |
| Plain graphite cane | $39–75 | https://ambutech.com/collections/graphite-mobility-folding-canes |
| Closest concept (CES 2026 honoree) | NaviCane: ToF + IMU + dual haptics + Braille dial | https://www.ces.tech/ces-innovation-awards/2026/navicane/ |
| Chest-worn phone + cane, research | 13% faster, 41% fewer contacts | https://www.nature.com/articles/s41551-026-01772-x |

Don't claim WeWALK can't see overhead; its ultrasonic does chest-up. Our differentiators: price, LiDAR resolution, scene description, retrofit.

### Retrofit prior art (judges will ask)
| Device | Type | Price | Outcome |
|---|---|---|---|
| WeWALK Gen 1 | Handle attachment on Ambutech cane | $499–600 | ~1,500 pre-orders 2018, £2M raised; Gen 2 abandoned retrofit, full cane $850–1,150, proprietary tip. Complaints: battery, price, bulk. https://abilitynet.org.uk/news-blogs/techshare-pro-wewalk-smart-cane-now-production |
| SmartCane (IIT Delhi / Saksham) | Clip-on ultrasonic, any cane | ~$36 | The success case: free via India's ADIP scheme. https://saksham.org/smartcane/ |
| BuzzClip (iMerciv) | Clip-on ultrasonic, clothing | $129–249 | ~$50K raised, gone. Aims inconsistently. https://www.afb.org/aw/18/3/15228 |
| Sunu Band | Wrist sonar | £288 | Discontinued; "build quality poor." https://www.applevis.com/reviews/sunu-band |
| Ray (Caretec) | Handheld ultrasonic | $300 | Still sold; occupies second hand. |
| Gallardo-Hernandez 2025 | Ultrasonic accessory on existing canes | – | 29% faster, zero collisions; "personal attachment to their canes." https://link.springer.com/article/10.1007/s12193-025-00469-w |

Patent to read: US8922759B2 (ToF in detachable cane handle, ams-OSRAM 2014) https://patents.google.com/patent/US8922759. Overlaps ToF pod, not phone-LiDAR grip.
Regulatory: canes are FDA Class I, 510(k)-exempt (21 CFR 890.3075). WeWALK/Ray/Sunu sell without clearance. Say "general controls only, legal review pending."
Who pays: Medicare doesn't cover white canes. State VR agencies and VA Blind Rehabilitation Service buy equipment at no cost to the user. NFB gives away rigid fiberglass canes; clamp must fit those.
Names: Tapline, Sidecar, Lumen, Outrider, Clipcane taken/crowded. "Sherpa Cane", "Halo Cane" look free. Also: Keepcane, Antler, GripKit. Run USPTO first.

### 90-second script
"Forty-three million people are blind. Almost all of them walk with a white cane that costs forty dollars. That cane works. They trust it. Their instructor trained them on it. The problem is what it can't see: a branch at head height, a truck mirror, an open door. Thirteen percent of blind travelers hit their head at least once a month.

Smart canes tried to fix that by replacing the cane. WeWALK's is $850 to $1,150. Users say the same three things: too expensive, battery dies, doesn't feel like my cane. No electronic travel aid has ever reached broad adoption.

So we don't replace the cane. We clip onto it. Three parts: a clamp for the phone you already own, a grip with two haptic motors, and an optional sensor pod. The phone's LiDAR sees waist to head. The grip just buzzes: left, right, above. Nothing in your ears, nothing masking traffic.

Why now: every iPhone Pro since 2020 has LiDAR. A four-meter ToF sensor is $15. Bluetooth is free. The parts cost less than a cane tip.

The kit is $99. We sell it to people, and to the state rehab agencies and the VA that already buy blind people their equipment.

[Demo.] Regular cane, head-height sign: hit. Clip the kit on, same cane, same hand: buzz at two meters, harder at one. Lights off. Same. Pull the battery. Still a white cane."

Slides: 1 Keep your cane, add the smarts · 2 The $40 cane works, it just can't see up · 3 Every smart cane replaced the cane and stalled at $850+ · 4 Three parts, one clamp · 5 $99, sold to people and to the agencies that already pay · 6 Live demo.

**[Superseded] lines in the script and slides**, with what the build supports instead:
- "Three parts: a clamp …, a grip with two haptic motors, and an optional sensor pod" / slide 4 → one printed clamp; the phone's Taptic Engine shakes the cane; the watch taps turns.
- "The grip just buzzes: left, right, above. Nothing in your ears" → the cane buzzes (2 taps left, 3 right, a hard double hit above); AirPods Pro carry short spoken lines and a direction click.
- "A four-meter ToF sensor is $15. Bluetooth is free." → not in the build; the LiDAR is already in the phone.
- "The kit is $99" / slide 5 → the build's only new part is the printed mount; pricing is a pitch decision, not a build fact.
- "Pull the battery. Still a white cane." → "Unclip the phone. Still a white cane."

---

## 7. Answered (Sep 10 night)
- **Stick shaft = 1.132 in = 28.75 mm.** Not a white cane (12.7 mm). Consequences:
  - Lamicall bike mount (15–40 mm) fits with no shim. Buy it; it's the guaranteed phone mount.
  - Printables handlebar mounts fit directly: https://www.printables.com/model/165853-universal-handlebar-phone-mount-v2 (20–32 mm) and https://www.printables.com/model/164840-handlebartube-phone-mount-no-screw (18–100 mm). j-h-a pole grip: `poleDiameter=28.75`.
  - `cad/grip_module.scad` and `cad/sensor_pod.scad`: set shaft to 28.75, clearance 0.4. Grip module gets roomier; battery + XIAO fit easily. **[Status]** Not done: the grip and pod are stretch, and the `cad/` drafts still use 12.7 mm.
  - Still buy one real Ambutech cane (12.7 mm). Pitch is "any cane," so show both: kit on the 28.75 stick for dev, kit on a real cane for the demo, TPU shim between. **[Superseded]** by §9 "buy nothing": the demo uses the 28.75 mm stick.
- **AirPods Pro: yes.** Build the head-tracked audio beacon (§5.2 #3). Core, not stretch. **[Built]** via `CMHeadphoneMotionManager`; AirPods also carry all speech.
- **Apple Watch: yes.** New exploits:
  - Wrist haptics via `WKInterfaceDevice.play(.directionUp/.directionDown/.notification)` over WatchConnectivity. Left/right turn on the wrist, obstacles on the grip. Two channels, no confusion. **[Built]** turn left `.directionUp`, turn right `.directionDown`, crossing `.notification`, arrived `.success`; obstacles are on the phone, not a grip. A walking workout session keeps the watch app alive wrist-down.
  - **Fallback if the ESP32 grip fails on stage:** watch carries all haptics. Demo survives. **[Changed]** There is no grip; the watch is the fallback for the phone's Taptic Engine (engine down or "Silence haptics" on).
  - Digital Crown / side button = "next waypoint" / "describe" without touching the phone. **[Changed]** No API for the side button or a crown press: crown rotation (3 detents within 1 s) = Next; on-screen watch buttons Repeat, Next, Describe, Recenter.
  - Heart rate + steps for the arrival card via HealthKit. **[Status]** Steps only (HealthKit, merged with the watch; phone pedometer fallback). No heart rate.
  - Watch heading (`CMMotionManager` on watchOS) as a second compass source. **[Not built]** Heading comes from the phone (GPS course while walking, compass otherwise).
- **Gemini key: not required.** Only the "what's here?" tap needs a VLM. Options: Gemini free tier ($0), or any Claude/OpenAI key already on hand (swap the URL in `SceneDescriber.swift`). Everything else (LiDAR lanes, mesh classification, OCR, speech, beacon) is on-device with no key. **[Changed]** No code edit needed: put a key (custom / Anthropic / Gemini / OpenAI) and optionally `VLM_PROVIDER` in `ios/CaneKit/Resources/Secrets.plist` (template `ios/Secrets.example.plist`). Without a key "Where am I" says so. OCR was not in the Step 10 build. **[Changed, Step 11]** Without a key "Where am I" now answers on the phone (Apple Vision + the on-device model; today `VLM_PROVIDER` = `ondevice` forces it), and on-device sign reading landed. The ElevenLabs voice also needs a key (system voice without one).
- Rules: not a concern.

## 8. Still open
1. Who owns Xcode? **[Answered]** Aritro's build Mac: Xcode 27 RC is installed (`CHANGELOG.md` Steps 1–2); the Apple ID / team and Developer Mode items are still open in `docs/todo.md` Step 0.
2. PETG/TPU on hand or PLA only? Still relevant only for the printed phone mount.
3. Budget cap for tonight's order. **[Moot]** Nothing was ordered (§9).

## 9. Phone-only mode (decision Sep 10 night: phone is king, buy nothing)

Hardware owned: iPhone 17 Pro Max, Apple Watch, AirPods Pro, 28.75 mm stick, 3 printers.
Only purchase: none required. Phone mount is printed (Printables 165853, fits 20–32 mm). Lamicall $30 is the insurance buy.

Haptic channels, zero new hardware:
1. Phone Taptic Engine. Phone is clamped to the shaft, so Core Haptics shakes the cane. Obstacle cues live here.
2. Apple Watch on the cane hand. Turns / crossings on the wrist. Also the stage fallback for channel 1.
3. AirPods Pro. Head-tracked beacon for bearing. Speech for everything with words.
ESP32 grip: demoted to stretch. Firmware stays in repo; ignore unless everything else works by H12.

Power: phone battery only. ARKit + LiDAR ≈ 3–4 h. Carry a power bank on the strap for the walk; MagSafe pack on the phone's back if the clamp allows.

**[Status]** This section is what was built (Steps 0–10, `CHANGELOG.md`). The ESP32 grip was not
revisited. The demo runs untethered on the phone; the Mac only signs and installs
([`docs/devices_setup.md`](devices_setup.md)).
