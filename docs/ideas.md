# Ideas: retrofit smart-cane kit

Founders hackathon, Champaign-Urbana, Sat Sep 12 – Sun Sep 13 2026.
Owners: Aritro = software (iPhone is the brain). Sagar = 3D printing + cane hardware.

Compiled Thu Sep 10. Amazon prices unverified. All code in this repo is uncompiled starter code.

---

## 0. One-liner

**Clip three parts onto the cane you already own. Your phone does the rest. Head-level protection for $60, not $850.**

Retrofit, not replacement. User keeps the cane their O&M instructor trained them on. Kit clips onto any 1/2" or 7/8" shaft in under a minute, unclips in five seconds. Pull the battery and it's still a white cane.

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

---

## 2. Three pushbacks on the original brief

### 2.1 A camera on a sweeping cane sees motion blur
2025 study, same camera on head vs cane: head-mounted tracking >98%; cane-mounted 55–58% outdoors. Holding the cane still raised it to 83%. Blind participants rated chest mount 4.0/5 comfort vs cane 3.1/5. https://arxiv.org/html/2504.19345v1

**Fix that keeps the concept:** gate capture on the gyro. Sample depth at the two sweep endpoints (angular velocity crosses zero) and when the cane pauses. LiDAR depth is far less blur-sensitive than RGB tracking anyway. Say this on stage as a feature: "sweep-aware capture."
**Hedge:** phone clamp has a GoPro knuckle; the same holder snaps onto a chest plate (`cad/chest_plate.scad`).

### 2.2 The cane tip already finds the ground
A ToF at the tip duplicates what the tip does by touch, 0.5 s earlier. What a cane cannot do is waist-to-head: 13% of blind travelers hit their head at least monthly, 23% of those needed medical care, 86% outdoors (branches, signs, poles). https://users.soe.ucsc.edu/~manduchi/papers/MobilityAccidents.pdf

**Fix:** phone LiDAR overhead/torso warning is the core demo. Pitch line: "the cane covers the ground; we cover everything above it."

### 2.3 "A to B in rain and dark" needs careful wording
GPS is ~4.9 m under open sky, worse near buildings (https://www.gps.gov/gps-accuracy). It can't tell which side of a curb you're on. Consumer ToF loses range in sun; water on the window gives false reads.

**Fix:** don't build routing. Hand off to MapKit walking directions and convert turn events to haptics. Own the last 5 m: obstacles, curbs, doors. Dark is our friend: LiDAR works better in the dark than cameras. Demo in a dim room. For rain: "IP68 phone, hooded sensor, cane works dry or wet." Don't promise more.

### Smaller
- Bone conduction / open-ear only. Masking traffic is a safety failure. https://www.mdpi.com/1424-8220/22/14/5454
- Haptics strong and rare. BuzzClip failed in a 2026 trial: "too weak," "too frequent," confused with normal cane feel. Two motors, ≤4 intensity levels, silent by default. https://www.nature.com/articles/s41598-026-37578-9
- Speaker on the cane: broadcasts the user's disability to the street and masks traffic. One use only: "find my cane" chirp. Everything else goes to headphones.
- Fitness / social features: scope trap. Every non-safety feature makes judges ask "who is this for?" Keep fitness to the arrival card (steps via HealthKit). Social = one slide.

---

## 3. Form factor (Sagar)

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

### 5.1 Architecture

```
iPhone 17 Pro Max
  ├─ ARKit sceneDepth (LiDAR, 60 Hz, ~5 m) → 3 cols × 2 rows lanes (torso / head), 10th-pct depth per cell
  ├─ ARKit meshWithClassification → door / wall / floor / seat / window raycast from screen center
  ├─ Core Motion gyro → sweep gate (trust frame only when |ω| < 0.6 rad/s)
  ├─ HapticLogic → hysteresis + rate limit → "H:<L|R|B>:<1-4>:<ms>"
  ├─ CoreBluetooth central ──BLE UART──▶ ESP32-S3 "CANE" ──PWM──▶ L / R coin motors
  ├─ AVSpeechSynthesizer → open-ear headphones
  ├─ Gemini 2.5 Flash (one JPEG on tap / Action button / Camera Control) → "sidewalk, bike rack left, crosswalk ahead"
  ├─ CLLocationUpdate.liveUpdates + waypoint geofences → turn / crossing cues
  ├─ Head-tracked audio beacon (AirPods) or stereo pan → continuous bearing
  └─ HealthKit steps → arrival card
```

Protocol both sides speak: `H:<L|R|B>:<1-4>:<ms>` (motor, intensity, duration), `P:<1-4>` (patterns: 1 double-pulse both, 2 left triple, 3 right triple, 4 long both = stop), `S:<0|1>` silence. ESP32 notifies `D:<mm>,B:<pct>` at 10 Hz.

Starter code: `ios/` (SwiftUI: DepthEngine, HapticLogic, CaneBLE, SceneDescriber, README with Info.plist keys) and `firmware/` (NimBLE 2.x, motor PWM, parser, ToF fail-safe). Neither compiled. Expect 20–40 min of Xcode fixes, mostly Swift 6 isolation and `@Observable` on NSObject delegates.

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

Constraints: camera cannot run in the background on iPhone; app stays foregrounded (screen may dim). Watch `ProcessInfo.thermalState`: at `.serious` drop mesh classification, then YOLO, keep LiDAR lanes.

Cloud VLM: Gemini 2.5 Flash `generateContent`, $0.30/M input tokens, free tier. Skip Live API (2-min video session cap, ≤1 fps). OpenAI Realtime is ~10× the price.

### 5.3 The A→B demo: ISR → CIF

Route: ISR front desk (918–1012 W Illinois St, ~40.1095, -88.2214) → W on Illinois St ~180 m → N on Goodwin Ave ~410 m → W on Springfield Ave ~370 m → CIF east entrance (1405 W Springfield, ~40.1125, -88.2283). ~1.0 km, 13–17 min at cane pace. Crossings: Illinois/Goodwin, Green/Goodwin, Springfield/Goodwin, Springfield/Mathews, (Springfield/Wright for west door). APS presence unverified. Walk it Friday, note which beep.

**Decision: don't trust live routing for the demo.** Build on a hand-verified waypoint file (8–12 points, instructions, crossing flags) recorded Friday. Live MapKit = fallback / "any destination" mode. Judges see identical guidance; we control failure modes.

Waypoint schema (`ios/route_isr_cif.json`, to be recorded):
```json
{ "id": 3, "lat": 40.1103, "lon": -88.2236, "radius_m": 15,
  "say": "Goodwin Avenue. Crossing. Listen for traffic.",
  "crossing": true, "bearing_next_deg": 355 }
```

| Layer | User gets | How | Fallback |
|---|---|---|---|
| Bearing | Continuous "which way" without words | Head-tracked beacon, or phone heading + stereo pan | L/R grip buzz every 3 s when off-bearing >25° |
| Turns and crossings | "Goodwin Avenue. Crossing. Listen for traffic." | Geofence per waypoint, 15 m radius, speak once | Manual "next" via Action button |
| Obstacles waist-to-head | Buzz at 1.5 m; hard buzz + "sign ahead, right" at 0.8 m | sceneDepth lanes → BLE → grip | Phone Core Haptics if grip drops |
| Doors, walls, seats | "Door ahead, two meters" | meshWithClassification raycast | Skip; pitch it |
| Scene read | "Sidewalk, bike rack left, crosswalk ahead" | Tap / Camera Control → Gemini Flash | Pre-cached description per waypoint |
| Signs, room numbers | "CIF. Room 0035." | Vision RecognizeTextRequest | – |
| Arrival | "CIF east entrance. 1.0 km, 14 min, 1,300 steps." | Geofence + HealthKit | – |

Campus data: MTD API (free key, `getdeparturesbystop`) https://developer.mtd.org/ ; UIUC calendar feeds likely `https://calendars.illinois.edu/ical/7.ics` (unverified); DRES pays for Aira on campus (handoff button = one deep link) https://dres.illinois.edu/community/accessibility-transportation/aira-on-demand-description-service/

### 5.4 Brainstorm: sorted by what to build

**Build (demo beats)**
- Sweep-aware capture. Gyro gates depth frames at sweep endpoints. Turns the blur objection into a named feature.
- Crossing protocol. Stop cue (both motors long) → "Goodwin Avenue, two lanes, listen" → tap to confirm → beacon re-aims at far curb.
- Head-height guardian. Top row of lanes only. Own cue: short double-buzz both.
- "What's here?" Action button → one-line scene read with clock-face directions.
- Dumb-cane proof. Pull the battery on stage. Snap the module off in 5 s.
- Arrival card. Distance, minutes, steps. The fitness hook without a fitness app.

**Day 2 if ahead**
- YOLO object names. Vision OCR for room numbers. Live Activity.
- MTD: "Next 22 Illini in 4 min at Goodwin & Illinois." ~1.5 h, very Champaign.
- Events along route from the UIUC calendar feed: "Quad Day booth 40 m on your right." ~2 h. This is the social layer.

**Slide only**
- Fitness reminders. Scope trap.
- Indoor: UWB anchors / DL-TDOA (iOS 27, no entitlement) / iBeacon per door. Roadmap.
- Route memory: record a walk once with a sighted friend, replay forever (waypoint file productized).
- Community hazard map: every obstacle hit becomes a pin others get warned about. Network effect.
- Aira handoff button.

### 5.5 Day plan

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

---

## 6. Pitch

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

---

## 7. Answered (Sep 10 night)
- **Stick shaft = 1.132 in = 28.75 mm.** Not a white cane (12.7 mm). Consequences:
  - Lamicall bike mount (15–40 mm) fits with no shim. Buy it; it's the guaranteed phone mount.
  - Printables handlebar mounts fit directly: https://www.printables.com/model/165853-universal-handlebar-phone-mount-v2 (20–32 mm) and https://www.printables.com/model/164840-handlebartube-phone-mount-no-screw (18–100 mm). j-h-a pole grip: `poleDiameter=28.75`.
  - `cad/grip_module.scad` and `cad/sensor_pod.scad`: set shaft to 28.75, clearance 0.4. Grip module gets roomier; battery + XIAO fit easily.
  - Still buy one real Ambutech cane (12.7 mm). Pitch is "any cane," so show both: kit on the 28.75 stick for dev, kit on a real cane for the demo, TPU shim between.
- **AirPods Pro: yes.** Build the head-tracked audio beacon (§5.2 #3). Core, not stretch.
- **Apple Watch: yes.** New exploits:
  - Wrist haptics via `WKInterfaceDevice.play(.directionUp/.directionDown/.notification)` over WatchConnectivity. Left/right turn on the wrist, obstacles on the grip. Two channels, no confusion.
  - **Fallback if the ESP32 grip fails on stage:** watch carries all haptics. Demo survives.
  - Digital Crown / side button = "next waypoint" / "describe" without touching the phone.
  - Heart rate + steps for the arrival card via HealthKit.
  - Watch heading (`CMMotionManager` on watchOS) as a second compass source.
- **Gemini key: not required.** Only the "what's here?" tap needs a VLM. Options: Gemini free tier ($0), or any Claude/OpenAI key already on hand (swap the URL in `SceneDescriber.swift`). Everything else (LiDAR lanes, mesh classification, OCR, speech, beacon) is on-device with no key.
- Rules: not a concern.

## 8. Still open
1. Who owns Xcode?
2. PETG/TPU on hand or PLA only?
3. Budget cap for tonight's order.

## 9. Phone-only mode (decision Sep 10 night: phone is king, buy nothing)

Hardware owned: iPhone 17 Pro Max, Apple Watch, AirPods Pro, 28.75 mm stick, 3 printers.
Only purchase: none required. Phone mount is printed (Printables 165853, fits 20–32 mm). Lamicall $30 is the insurance buy.

Haptic channels, zero new hardware:
1. Phone Taptic Engine. Phone is clamped to the shaft, so Core Haptics shakes the cane. Obstacle cues live here.
2. Apple Watch on the cane hand. Turns / crossings on the wrist. Also the stage fallback for channel 1.
3. AirPods Pro. Head-tracked beacon for bearing. Speech for everything with words.
ESP32 grip: demoted to stretch. Firmware stays in repo; ignore unless everything else works by H12.

Power: phone battery only. ARKit + LiDAR ≈ 3–4 h. Carry a power bank on the strap for the walk; MagSafe pack on the phone's back if the clamp allows.
