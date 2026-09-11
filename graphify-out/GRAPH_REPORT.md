# Graph Report - 54FoundersHack  (2026-09-11)

## Corpus Check
- 110 files · ~198,688 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 1874 nodes · 4053 edges · 108 communities (99 shown, 9 thin omitted)
- Extraction: 90% EXTRACTED · 10% INFERRED · 0% AMBIGUOUS · INFERRED: 422 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `45230fee`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- HapticCue
- Foundation
- CaneKitUITests
- DepthEngine
- NavSupportTests.swift
- BeaconEngine
- gen.sh
- AppIntents.swift
- CaneBLE
- HapticPlayer
- .waypoints
- docs/README.md
- Theme.swift
- VLMClient
- LaneTile
- NavigationEngine
- VLMError
- WorkoutRelay
- ObstacleClass
- AppModel
- WatchToPhone
- NavLiveActivity
- WatchModel
- SpeechQueue
- DepthFrameProcessor
- Waypoint
- DepthEngine
- Coordinate
- CueDecider
- .describe
- Decodable
- NavCue
- Module: ui-tests-build — Phone UI, XCUITests, XcodeGen build, CI
- CourseSmoother
- .samples
- HazardScanner
- 2. Device test matrix
- Double
- e2e.py
- TripLogger
- Ideas: retrofit smart-cane kit
- HazardTests.swift
- String
- SceneVocabularyTests.swift
- TripTracker
- .wireNavigation
- SessionRelay
- LocationService
- SwiftUI
- CaneKit design system
- ArrivalCardView
- CaneKit grip module firmware
- .computeLanes
- AppModel
- `AppModel.swift` — engine owner, settings, cue router
- GuideCard
- .say
- Module: logic — `ios/Logic` (SwiftPM package `CaneKitLogic`)
- Cane mount for the iPhone 17 Pro Max: design brief
- CodingKeys
- CKBigButtonStyle
- CaneKit — strict build checklist
- Sendable
- Module `watch-widget-shared`
- RuntimeRelay
- HazardRecord
- DescribeError
- NSObject
- DelegateRelay
- FrameReplay
- Codable
- Package.swift
- SignPolicy
- .describe
- Module `navigation-trip` — GPS, waypoint engine, turn settling, route sources, trip log/tracker, Live Activity
- .session
- Module: speech-audio-scene (`ios/CaneKit/Speech`, `ios/CaneKit/Audio`, `ios/CaneKit/Scene`)
- .handle
- View
- SceneDescriber
- Team handoff: read this first after you pull
- pitch_model.py
- HazardWatchPolicy
- CameraControlInteraction
- CaneKit changelog
- VLMProvider
- AGENTS.md — rules for anyone (human or AI) editing OpenCane / CaneKit
- Every doc
- Route: ISR Townsend Hall to CIF (UIUC, Urbana IL)
- GeoFix
- CaneKit: the iOS app for the phone-only smart cane
- CaneKit code reference
- Module `depth-haptics` — `ios/CaneKit/Depth/*.swift`, `ios/CaneKit/Haptics/HapticPlayer.swift`
- LaneGrid
- AirPods + Apple Watch — setup and what the app does about them
- OpenCane: a smart-cane kit that clips an iPhone onto the cane you already own
- `ios/CaneKit/Speech/SpeechQueue.swift`
- hardware/: phone-to-cane mount
- streetview/README.md
- CueKind
- Text
- cad/README.md
- CKStatusPill
- test.sh
- Swift 6 approachable-concurrency build settings
- PlayerRelay
- ContentValue

## God Nodes (most connected - your core abstractions)
1. `AppModel` - 80 edges
2. `Coordinate` - 45 edges
3. `SpeechQueue` - 41 edges
4. `DepthFrameProcessor` - 39 edges
5. `CaneKitLogic` - 36 edges
6. `HapticPlayer` - 35 edges
7. `NavigationEngine` - 33 edges
8. `GroundHazardDetector` - 32 edges
9. `GeofenceTracker` - 31 edges
10. `GeoFix` - 29 edges

## Surprising Connections (you probably didn't know these)
- `UIFileSharingEnabled for trip logs and hazard map` --conceptually_related_to--> `TripLogger`  [INFERRED]
  ios/project.yml → ios/CaneKit/Trip/TripLogger.swift
- `CaneKitUITests target` --references--> `CaneKitUITests`  [INFERRED]
  ios/project.yml → ios/CaneKitUITests/CaneKitUITests.swift
- `.body` --calls--> `ContentView`  [INFERRED]
  ios/CaneKit/App/CaneKitApp.swift → ios/CaneKit/UI/ContentView.swift
- `CaneKitWidget Live Activity target` --conceptually_related_to--> `LiveActivityController`  [INFERRED]
  ios/project.yml → ios/CaneKit/Trip/LiveActivityController.swift
- `logic-tests job (Linux, swift:6.2)` --references--> `CaneKitLogic SwiftPM package`  [EXTRACTED]
  .github/workflows/ci.yml → ios/project.yml

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Navigation rules: fences, veer, arrival, turn settling** — ios_canekit_navigation_navigationengine_navigationengine, ios_logic_sources_canekitlogic_geomath_geofencetracker, ios_logic_sources_canekitlogic_geomath_offcoursedetector, ios_logic_sources_canekitlogic_navsupport_turnsettle, ios_logic_sources_canekitlogic_navsupport_straightwalkdetector [EXTRACTED 1.00]
- **Obstacle cue pipeline (~15 Hz)** — ios_canekit_depth_depthframeprocessor_depthframeprocessor, ios_canekit_depth_depthengine_depthengine, ios_logic_sources_canekitlogic_lanereport_lanereport, ios_canekit_app_appmodel_appmodel_handle, ios_logic_sources_canekitlogic_cuedecider_cuedecider, ios_canekit_haptics_hapticplayer_hapticplayer, ios_canekit_watch_phonewatchlink_phonewatchlink, ios_logic_sources_canekitlogic_navsupport_cuespeechpolicy, ios_canekit_speech_obstaclenamer_obstaclenamer [EXTRACTED 1.00]
- **Per-GPS-fix route guidance loop** — ios_canekit_navigation_locationservice_locationservice, ios_canekit_app_appmodel_appmodel_wirenavigation, ios_canekit_navigation_navigationengine_navigationengine, ios_logic_sources_canekitlogic_geomath_geofencetracker, ios_logic_sources_canekitlogic_navsupport_turnsettle, ios_logic_sources_canekitlogic_geomath_offcoursedetector, ios_canekit_app_appmodel_appmodel_startticker, ios_canekit_audio_beaconengine_beaconengine [EXTRACTED 1.00]
- **Phone-watch cue and command link over the WatchMessage wire contract** — ios_canekit_watch_phonewatchlink_phonewatchlink, ios_logic_sources_canekitlogic_watchmessage, ios_canekitwatch_watchmodel_watchmodel [EXTRACTED 1.00]
- **Watch command round trip (button/crown to phone action)** — ios_canekitwatch_watchmodel_watchmodel_send, ios_logic_sources_canekitlogic_watchmessage_watchenvelope, ios_canekit_watch_phonewatchlink_sessionrelay, ios_canekit_watch_phonewatchlink_phonewatchlink, ios_canekit_app_appmodel_appmodel_handlewatchcommand, ios_canekit_navigation_navigationengine_navigationengine [EXTRACTED 1.00]

## Communities (108 total, 9 thin omitted)

### Community 0 - "HapticCue"
Cohesion: 0.12
Nodes (16): .logicPackageOK, CueOutput, fire, stop, updateCenter, CueThresholds, GeigerRate, HapticCue (+8 more)

### Community 1 - "Foundation"
Cohesion: 0.06
Nodes (36): ActivityKit, AppKit, ARKit, AVFoundation, CaneKitLogic, CGImage, CoreBluetooth, CoreHaptics (+28 more)

### Community 2 - "CaneKitUITests"
Cohesion: 0.05
Nodes (29): Activity, ActivityAttributes, logic-tests job (Linux, swift:6.2), Hashable, LiveActivityController, Int, CaneKitUITests, Bool (+21 more)

### Community 3 - "DepthEngine"
Cohesion: 0.13
Nodes (16): ARConfidenceLevel, DepthEngine, LaneReport, ARFrame, ARSession, ARWorldTrackingConfiguration, CGFloat, CVPixelBuffer (+8 more)

### Community 4 - "NavSupportTests.swift"
Cohesion: 0.09
Nodes (37): Config, CrownAccumulator, CueSpeechPolicy, StraightWalkDetector, Bool, Double, Int, TimeInterval (+29 more)

### Community 5 - "BeaconEngine"
Cohesion: 0.11
Nodes (17): AVAudioFormat, AVAudioPCMBuffer, AudioRouteMonitor, .isAirPods, Bool, Never, NSObjectProtocol, Task (+9 more)

### Community 7 - "AppIntents.swift"
Cohesion: 0.15
Nodes (18): AppIntent, AppIntents, AppShortcut, AppShortcutsProvider, CustomLocalizedStringResourceConvertible, Error, IntentModes, IntentResult (+10 more)

### Community 8 - "CaneBLE"
Cohesion: 0.11
Nodes (21): CBCentralManager, CBCentralManagerDelegate, CBCharacteristic, CBPeripheral, CBPeripheralDelegate, CBService, CaneBLE, ConnectionState (+13 more)

### Community 9 - "HapticPlayer"
Cohesion: 0.14
Nodes (12): CHHapticEngine, CHHapticPattern, CHHapticPatternPlayer, HapticPlayer, .silenced, Float, Int, Never (+4 more)

### Community 10 - ".waypoints"
Cohesion: 0.15
Nodes (11): CLLocationCoordinate2D, MKPolyline, .coordinates, RouteSource, .current, RouteBuilder, RouteStepInput, Data (+3 more)

### Community 12 - "Theme.swift"
Cohesion: 0.19
Nodes (10): ColorSchemeContrast, Configuration, .body, CKColor, CKMetrics, CKRadius, CKSpacing, CGFloat (+2 more)

### Community 13 - "VLMClient"
Cohesion: 0.20
Nodes (11): Duration, Secrets, .hasElevenLabs, Bool, AnthropicClient, FallbackVLMClient, .name, GeminiClient (+3 more)

### Community 14 - "LaneTile"
Cohesion: 0.20
Nodes (11): LaneGridView, .body, LaneTile, .fill, .level, .levelWord, .text, Bool (+3 more)

### Community 15 - "NavigationEngine"
Cohesion: 0.15
Nodes (10): Element, Array, NavigationEngine, Bool, Date, Double, Int, TimeInterval (+2 more)

### Community 16 - "VLMError"
Cohesion: 0.20
Nodes (15): Data, Int, VLMError, emptyResponse, .errorDescription, http, malformed, refused (+7 more)

### Community 17 - "WorkoutRelay"
Cohesion: 0.12
Nodes (15): HealthKit, HKWorkoutSessionDelegate, HKWorkoutSessionState, Any, Bool, Date, Error, Void (+7 more)

### Community 18 - "ObstacleClass"
Cohesion: 0.06
Nodes (36): ClosedRange, MeshClassifier, ARFrame, Bool, Float, ObstacleNamer, Float, LaneReport (+28 more)

### Community 19 - "AppModel"
Cohesion: 0.11
Nodes (17): AppModel, .beaconEnabled, .fallbackToWatch, .groundHazardsEnabled, .hapticsSilenced, .hazardWatchEnabled, .loggingEnabled, .mirrorLeftRight (+9 more)

### Community 20 - "WatchToPhone"
Cohesion: 0.20
Nodes (11): CaseIterable, Any, WatchEnvelope, WatchToPhone, describe, nextWaypoint, recenter, repeatLast (+3 more)

### Community 21 - "NavLiveActivity"
Cohesion: 0.20
Nodes (10): CaneKitWidgetBundle, .body, Widget, NavLiveActivity, .body, Int, View, Widget (+2 more)

### Community 22 - "WatchModel"
Cohesion: 0.21
Nodes (8): HKWorkoutSession, Double, Int, Never, Task, TimeInterval, WatchModel, WKHapticType

### Community 23 - "SpeechQueue"
Cohesion: 0.16
Nodes (17): AVAudioSession, Int, Pending, Result, SpeechPriority, nav, obstacle, safety (+9 more)

### Community 24 - "DepthFrameProcessor"
Cohesion: 0.11
Nodes (17): ARSessionDelegate, AsyncStream, SessionObserver, DepthFrameProcessor, .hasCameraFrame, .rotationRate, ProcessorSettings, ARFrame (+9 more)

### Community 25 - "Waypoint"
Cohesion: 0.26
Nodes (9): Identifiable, Bool, Decoder, Double, Int, Waypoint, .coordinate, .placeName (+1 more)

### Community 26 - "DepthEngine"
Cohesion: 0.16
Nodes (10): DepthEngine, ARSession, ARWorldTrackingConfiguration, Bool, Double, LaneReport, Never, Task (+2 more)

### Community 27 - "Coordinate"
Cohesion: 0.27
Nodes (21): Coordinate, GeofenceTracker, .isFinished, aGatedOutFixDoesNotBreakTheArrivalStreak(), arrivalStreakResetsOnAMiss(), cardinalBearings(), fix(), geofenceGatesOnAccuracyAndSpeedExceptArrival() (+13 more)

### Community 28 - "CueDecider"
Cohesion: 0.24
Nodes (21): CueDecider, Bool, LaneReport, TimeInterval, centerApproachFiresThenUpdatesDistance(), centerDistanceIsClampedToNearFloor(), centerLoopIsExemptFromTheFloor(), cueChangeNeeds400ms() (+13 more)

### Community 29 - ".describe"
Cohesion: 0.21
Nodes (9): OnDeviceHazards, OnDeviceVision, OnDeviceVLMClient, Bool, Data, Float, Set, VisionDetections (+1 more)

### Community 30 - "Decodable"
Cohesion: 0.20
Nodes (19): Decodable, Encodable, Candidate, Content, ErrorEnvelope, GenerateRequest, GenerateResponse, GenerationConfig (+11 more)

### Community 31 - "NavCue"
Cohesion: 0.13
Nodes (15): PhoneWatchLink, Any, Int, TimeInterval, NavCue, arrived, crossing, obstacle (+7 more)

### Community 32 - "Module: ui-tests-build — Phone UI, XCUITests, XcodeGen build, CI"
Cohesion: 0.06
Nodes (31): docs/design.md — rules the UI code implements, `enum CKColor` (namespace, no cases), `enum CKFont`, `enum CKMetrics`, `enum CKRadius`, `enum CKSpacing` (4 pt base), .github/workflows/ci.yml, ios/CaneKit/UI/ArrivalCardView.swift (+23 more)

### Community 33 - "CourseSmoother"
Cohesion: 0.16
Nodes (13): C, CourseSmoother, Double, Int, TimeInterval, aRealTurnShowsUpAfterTheBaseline(), at(), jitterOnAStraightWalkNeverLooksLikeAVeer() (+5 more)

### Community 34 - ".samples"
Cohesion: 0.33
Nodes (6): GroundSampler, ARFrame, Float, Int, SIMD3, UInt8

### Community 35 - "HazardScanner"
Cohesion: 0.16
Nodes (12): HazardScanner, Any, Bool, CGFloat, Data, Double, Int, Never (+4 more)

### Community 36 - "2. Device test matrix"
Cohesion: 0.07
Nodes (30): 0. Read this before testing: facts from the code that change how you test, 1.0 The next 24 hours, 1.1 Automated (Mac, no phone): run on every change, 1.2 Bench (indoors, phone plugged in, ISR lobby), 1.3 Outdoor walks, 1.4 Log toolkit (Aritro), 1. Test levels, 2. Device test matrix (+22 more)

### Community 37 - "Double"
Cohesion: 0.47
Nodes (3): GeoMath, Double, wrapping()

### Community 38 - "e2e.py"
Cohesion: 0.17
Nodes (25): check(), container(), densify(), dist(), launch_and_wait_for_route(), load_waypoints(), main(), navcues() (+17 more)

### Community 39 - "TripLogger"
Cohesion: 0.18
Nodes (11): FileHandle, Double, Float, Int, LaneReport, Never, Task, TimeInterval (+3 more)

### Community 40 - "Ideas: retrofit smart-cane kit"
Cohesion: 0.08
Nodes (24): 0. One-liner, 1. Verdict, 2.1 A camera on a sweeping cane sees motion blur, 2.2 The cane tip already finds the ground, 2.3 "A to B in rain and dark" needs careful wording, 2. Three pushbacks on the original brief, 3. Form factor (Sagar), 4. Buy list (order Thursday night, Amazon only) (+16 more)

### Community 41 - "HazardTests.swift"
Cohesion: 0.23
Nodes (22): GroundHazardDetector, aCurbDownIsADropOff(), aCurbUpIsAStepUp(), aCurbYouWalkTowardStillConfirms(), aHazardNeedsThreeAgreeingFrames(), aHoleThatComesBackUpIsAPothole(), aMidBinCurbFaceIsStillFound(), aPartialWallIsNotAStep() (+14 more)

### Community 42 - "String"
Cohesion: 0.19
Nodes (13): String, .sentenceCased, SceneContext, ElevenLabsVoice, .cacheDir, Data, Int, TimeInterval (+5 more)

### Community 43 - "SceneVocabularyTests.swift"
Cohesion: 0.07
Nodes (32): Role, destructive, primary, secondary, Bool, CGFloat, Color, UInt32 (+24 more)

### Community 44 - "TripTracker"
Cohesion: 0.20
Nodes (9): HKObserverQuery, Date, Double, Int, Never, Task, TimeInterval, Void (+1 more)

### Community 46 - "SessionRelay"
Cohesion: 0.32
Nodes (6): SessionRelay, Bool, Error, Void, WCSession, WCSessionActivationState

### Community 47 - "LocationService"
Cohesion: 0.14
Nodes (13): CLBackgroundActivitySession, CLHeading, CLLocation, CLLocationManager, CLLocationManagerDelegate, LocationService, .authorizationDenied, Bool (+5 more)

### Community 48 - "SwiftUI"
Cohesion: 0.13
Nodes (11): App, CaneKitApp, .body, Scene, Scene, WatchApp, .body, WatchContentView (+3 more)

### Community 49 - "CaneKit design system"
Cohesion: 0.07
Nodes (29): 0. Who looks at the screen, and what that forces, 10. Open design gaps (code ≠ intent, not yet fixed), 1. Typography, 2. Colour tokens, 3. Spacing and radius, 4. Motion, 5.1 Speech priorities (`SpeechQueue`, AGENTS.md hard rule 8), 5.2 Obstacle cues (phone Taptic Engine, felt through the cane) (+21 more)

### Community 50 - "ArrivalCardView"
Cohesion: 0.43
Nodes (4): ArrivalCardView, .body, Double, TimeInterval

### Community 51 - "CaneKit grip module firmware"
Cohesion: 0.29
Nodes (6): Build — Arduino IDE, Build — PlatformIO, CaneKit grip module firmware, Protocol (NUS, device name `CANE`), Testing with nRF Connect (Android / iOS), Wiring

### Community 52 - ".computeLanes"
Cohesion: 0.19
Nodes (18): LaneGrid, scene, LaneConfig, UInt8, groundBandIsSkipped(), headRowIsTopBand(), landscapeModeUsesBufferAsScene(), leftWallOnlyHitsLeftLanes() (+10 more)

### Community 53 - "AppModel"
Cohesion: 0.05
Nodes (45): Comparable, AppModel, .extendedRange, .hapticsEnabled, .mirrorLeftRight, .portraitMode, .speechEnabled, .urgentDistance (+37 more)

### Community 54 - "`AppModel.swift` — engine owner, settings, cue router"
Cohesion: 0.12
Nodes (16): `AppModel.swift` — engine owner, settings, cue router, Auto-recenter — `autoRecenterIfWalkingStraight(_ fix: GeoFix)` (private, per GPS fix while navigating), Constants, Cue router — `handle(_ report: LaneReport)` (private, ~15 Hz, called from `depth.onReport`), Engine wiring (all `let`, created in the property initialisers except `describer`, `sceneContext` and `hazards`, which `init` builds), Hazards the maps do not know about (Step 11), Headphones / watch presence, Lifecycle (+8 more)

### Community 55 - "GuideCard"
Cohesion: 0.18
Nodes (10): Font, GuideCard, .beaconWord, .body, .gpsTone, .gpsWord, .headSpoken, .headWord (+2 more)

### Community 56 - ".say"
Cohesion: 0.18
Nodes (4): Settings, Bool, TimeInterval, Any

### Community 57 - "Module: logic — `ios/Logic` (SwiftPM package `CaneKitLogic`)"
Cohesion: 0.12
Nodes (16): `CourseSmoother.swift` — direction of travel over ≥ 15 m, for veer decisions only (Step 11), Cross-module contracts (who uses what), `CueDecider.swift` — LaneReport → haptic cue with hysteresis and rate limiting (decides *what/when*; player is elsewhere), `GeoMath.swift` — haversine distance/bearing, angle wrapping, off-course detection, waypoint geofences, `Hazards.swift` — hazards the maps do not know about: LiDAR ground profile, sign phrases, vision-model hazard replies, GeoJSON hazard map (Step 11), `ios/Logic/Package.swift`, `ios/scripts/test.sh` — runs the package tests (`make test`), `LaneMath.swift` — LiDAR depth map → 3 lanes × 2 bands (10th-percentile per cell) + centre median (+8 more)

### Community 58 - "Cane mount for the iPhone 17 Pro Max: design brief"
Cohesion: 0.12
Nodes (16): 0. Decisions, 10. Print settings, 11. Assembly and setting the angle, 12. Test protocol, 13. Open risks and follow-ups, 14. Sources, 1. Inputs and where they come from, 2. What the software needs from the mount (+8 more)

### Community 59 - "CodingKeys"
Cohesion: 0.18
Nodes (11): CodingKey, CodingKeys, bearingNextDeg, crossing, curved, id, lat, lon (+3 more)

### Community 60 - "CKBigButtonStyle"
Cohesion: 0.13
Nodes (16): ButtonStyle, HapticsCard, .body, .cueWord, CKBigButton, .body, .icon, .text (+8 more)

### Community 61 - "CaneKit — strict build checklist"
Cohesion: 0.13
Nodes (15): CaneKit — strict build checklist, Cross-cutting, Step 0 — phone-only reset, Step 10 — Review fixes + UI tests (pre-device), Step 11 — Hazards the maps don't know, on-device vision, stress harness (pre-device), Step 12 — Google Street View mock of ISR → CIF (pre-device), Step 1 — project scaffold, Step 2 — DepthEngine (+7 more)

### Community 62 - "Sendable"
Cohesion: 0.14
Nodes (16): Equatable, Config, GroundHazard, GroundHazardKind, dropOff, lowObstacle, pothole, .spoken (+8 more)

### Community 63 - "Module `watch-widget-shared`"
Cohesion: 0.14
Nodes (14): Cross-module map, `ios/CaneKit/Watch/PhoneWatchLink.swift` — phone side of WatchConnectivity, `ios/CaneKitWatch/CaneKitWatch.entitlements`, `ios/CaneKitWatch/WatchApp.swift` — watchOS entry point, `ios/CaneKitWatch/WatchContentView.swift` — the wrist screen, `ios/CaneKitWatch/WatchModel.swift` — watch side: haptics, commands, crown, keep-alive, `ios/CaneKitWatch/WatchTheme.swift` — watch design tokens (docs/design.md §6.6), `ios/CaneKitWidget/CaneKitWidgetBundle.swift` — widget extension entry (+6 more)

### Community 64 - "RuntimeRelay"
Cohesion: 0.20
Nodes (8): RuntimeEvent, ended, expiring, started, RuntimeRelay, WKExtendedRuntimeSession, WKExtendedRuntimeSessionDelegate, WKExtendedRuntimeSessionInvalidationReason

### Community 65 - "HazardRecord"
Cohesion: 0.13
Nodes (14): HazardSource, ground, sign, vision, HazardLog, .fileURL, Data, URL (+6 more)

### Community 66 - "DescribeError"
Cohesion: 0.14
Nodes (15): RouteError, destinationNotFound, .errorDescription, missingBundledRoute, noRoute, DescribeError, badResponse, .errorDescription (+7 more)

### Community 67 - "NSObject"
Cohesion: 0.19
Nodes (8): CMHeadphoneMotionManager, CMHeadphoneMotionManagerDelegate, ConnectionRelay, HeadPoseTracker, Bool, Double, Void, NSObject

### Community 68 - "DelegateRelay"
Cohesion: 0.18
Nodes (9): AVSpeechSynthesisVoice, AVSpeechSynthesizer, AVSpeechSynthesizerDelegate, AVSpeechUtterance, CallbackBox, DelegateRelay, Speech, Bool (+1 more)

### Community 69 - "FrameReplay"
Cohesion: 0.29
Nodes (7): Frame, FrameReplay, .currentName, State, Bool, Data, URL

### Community 70 - "Codable"
Cohesion: 0.24
Nodes (8): Codable, OffCourseDetector, TimeInterval, Turn, left, right, offCourseNeedsThreeSecondsThenCoolsDown(), offCourseResetsWhenBackOnBearing()

### Community 72 - "SignPolicy"
Cohesion: 0.18
Nodes (13): GroundHazardPolicy, SignPolicy, Bool, aPartialReadOfTheSameSignIsQuiet(), aSecondSignIsStillRead(), farLinesAreNotJoinedIntoAPhantomSign(), farTextReadsSafetySignsButNotStorefrontWords(), irrelevantOrUnsureTextIsIgnored() (+5 more)

### Community 73 - ".describe"
Cohesion: 0.22
Nodes (6): post(), Data, URL, VLMRequest, anthropicRequestShape(), geminiRequestCarriesImageAndPrompt()

### Community 74 - "Module `navigation-trip` — GPS, waypoint engine, turn settling, route sources, trip log/tracker, Live Activity"
Cohesion: 0.17
Nodes (12): Data flow (who calls whom), `docs/route_isr_cif.md`, `ios/CaneKit/Navigation/LocationService.swift`, `ios/CaneKit/Navigation/NavigationEngine.swift`, `ios/CaneKit/Navigation/RouteSource.swift`, `ios/CaneKit/Resources/route_isr_cif.json` — schema and waypoints, `ios/CaneKit/Trip/HazardLog.swift` (Step 11), `ios/CaneKit/Trip/LiveActivityController.swift` (+4 more)

### Community 75 - ".session"
Cohesion: 0.33
Nodes (4): ARCamera, ARFrame, Error, Int

### Community 76 - "Module: speech-audio-scene (`ios/CaneKit/Speech`, `ios/CaneKit/Audio`, `ios/CaneKit/Scene`)"
Cohesion: 0.17
Nodes (12): `ios/CaneKit/Audio/AudioRouteMonitor.swift`, `ios/CaneKit/Audio/BeaconEngine.swift`, `ios/CaneKit/Audio/HeadPoseTracker.swift`, `ios/CaneKit/Scene/CameraControlInteraction.swift`, `ios/CaneKit/Scene/HazardScanner.swift` (Step 11), `ios/CaneKit/Scene/OnDeviceVision.swift` (Step 11), `ios/CaneKit/Scene/SceneDescriber.swift`, `ios/CaneKit/Scene/Secrets.swift` (+4 more)

### Community 78 - "View"
Cohesion: 0.23
Nodes (12): ContentView, .body, .capabilityCard, .statusCard, AppModel, Bindable, Bool, CKCard (+4 more)

### Community 80 - "SceneDescriber"
Cohesion: 0.16
Nodes (8): CGFloat, Data, CGFloat, Data, SceneDescriber, Data, Int, Void

### Community 81 - "Team handoff: read this first after you pull"
Cohesion: 0.15
Nodes (13): 0. Start here (5 minutes), 10. How we work (read before changing anything), 11. Known risks going into the walk, 1. The one-paragraph version, 2. What is proven, and what is not, 3. Who does what next, 4. Pull, build, install, 5. The mount angle (read this, Sagar) (+5 more)

### Community 82 - "pitch_model.py"
Cohesion: 0.27
Nodes (11): clearance(), convex_hull(), ground_hit(), outside(), pitch_table(), Where the cane shaft (toward the tip) appears in the wide camera's portrait…, z-depth and range where a ray alpha deg above the optical axis meets the ground., Smallest gap (mm) between the cradle box and the cane / collar / ear over phi =… (+3 more)

### Community 83 - "HazardWatchPolicy"
Cohesion: 0.26
Nodes (7): HazardWatchPolicy, Double, Set, TimeInterval, hazardReplyKeepsDecimals(), hazardWatchAsksOnlyWhileWalkingAndRarely(), hazardWatchRepliesBecomeShortCautions()

### Community 84 - "CameraControlInteraction"
Cohesion: 0.23
Nodes (8): AVCaptureEventInteraction, AVKit, Context, CameraControlInteraction, Coordinator, Void, UIView, UIViewRepresentable

### Community 85 - "CaneKit changelog"
Cohesion: 0.18
Nodes (11): CaneKit changelog, Step 0 — phone-only reset (Thu Sep 10), Step 10 — Two adversarial review rounds, AirPods/Watch presence, XCUITests (Fri Sep 11, pre-device), Step 11 — Hazards the maps don't know, on-device vision, stress harness (Fri Sep 11, pre-device), Step 12 — Google Street View mock of ISR → CIF: what failed and the fixes (Fri Sep 11, pre-device), Step 3 — Core Haptics (Fri Sep 11, pre-device), Step 4 — Speech + obstacle names (Fri Sep 11, pre-device), Step 5 — Watch (Fri Sep 11, pre-device) (+3 more)

### Community 86 - "VLMProvider"
Cohesion: 0.15
Nodes (11): Drafts (iOS 18, pre-hackathon), .spokenLine, ScenePrompt, SpokenDistance, Float, VLMProvider, anthropic, custom (+3 more)

### Community 87 - "AGENTS.md — rules for anyone (human or AI) editing OpenCane / CaneKit"
Cohesion: 0.25
Nodes (8): AGENTS.md — rules for anyone (human or AI) editing OpenCane / CaneKit, Commands, Hard rules, How we engineer (the bar for every change, human or AI), Layout, Things that look wrong but are deliberate, What this is, Where the plan and history live

### Community 88 - "Every doc"
Cohesion: 0.25
Nodes (8): `docs/`, Docs index, Every doc, Hardware, iOS app, Outside `docs/`, Repo root, Where do I find…

### Community 89 - "Route: ISR Townsend Hall to CIF (UIUC, Urbana IL)"
Cohesion: 0.25
Nodes (8): Evidence per waypoint (OSM), Route: ISR Townsend Hall to CIF (UIUC, Urbana IL), Sources, To re-record on the Friday walk, Waypoints (from the JSON), What the app does at each waypoint, Where Townsend Hall is, and which door is "the Townsend exit", Why the file looks the way it does

### Community 90 - "GeoFix"
Cohesion: 0.24
Nodes (6): GeoFix, NavEvent, reached, Bool, Int, isrToCifIsAboutSevenHundredMetres()

### Community 91 - "CaneKit: the iOS app for the phone-only smart cane"
Cohesion: 0.25
Nodes (8): 1. Day-0 checklist, 2. Verified spec deviations (don't "fix" these back), 3. Build, install, launch, 4. Secrets and permissions, 5. Testing, 6. Gotchas, CaneKit: the iOS app for the phone-only smart cane, Layout

### Community 92 - "CaneKit code reference"
Cohesion: 0.29
Nodes (7): `AppIntents.swift` — Action button / Siri entry points, CaneKit code reference, `CaneKitApp.swift` — app entry point, Contents, Data flow, How to keep this file true, Module `app-core` — `ios/CaneKit/App/`

### Community 93 - "Module `depth-haptics` — `ios/CaneKit/Depth/*.swift`, `ios/CaneKit/Haptics/HapticPlayer.swift`"
Cohesion: 0.29
Nodes (7): `ios/CaneKit/Depth/DepthEngine.swift`, `ios/CaneKit/Depth/DepthFrameProcessor.swift`, `ios/CaneKit/Depth/FrameReplay.swift` (Step 11, simulator-only), `ios/CaneKit/Depth/GroundSampler.swift` (Step 11), `ios/CaneKit/Depth/MeshClassifier.swift`, `ios/CaneKit/Haptics/HapticPlayer.swift`, Module `depth-haptics` — `ios/CaneKit/Depth/*.swift`, `ios/CaneKit/Haptics/HapticPlayer.swift`

### Community 94 - "LaneGrid"
Cohesion: 0.38
Nodes (4): LaneGrid, LaneMath, Float, Int

### Community 95 - "AirPods + Apple Watch — setup and what the app does about them"
Cohesion: 0.33
Nodes (6): AirPods + Apple Watch — setup and what the app does about them, AirPods (beacon, speech, head tracking), Apple Watch (wrist taps, Repeat / Next / Describe / Recenter), If something is off, On-device vision (no key, no network), Untethered demo (phone only, no laptop)

### Community 96 - "OpenCane: a smart-cane kit that clips an iPhone onto the cane you already own"
Cohesion: 0.33
Nodes (6): Hardware, Links, OpenCane: a smart-cane kit that clips an iPhone onto the cane you already own, Quick start, Repo map, The demo

### Community 97 - "`ios/CaneKit/Speech/SpeechQueue.swift`"
Cohesion: 0.40
Nodes (5): Constants, Functions, `ios/CaneKit/Speech/SpeechQueue.swift`, Published state (observed by UI / AppModel), Types

### Community 98 - "hardware/: phone-to-cane mount"
Cohesion: 0.40
Nodes (5): Bill of materials, Files, hardware/: phone-to-cane mount, Quick start (Sagar), Who does what

### Community 99 - "streetview/README.md"
Cohesion: 0.50
Nodes (3): Step 12 findings (2026-09-11, afternoon) and fixes, Street View route frames (local test input), What the first 2026-09-11 run showed

### Community 100 - "CueKind"
Cohesion: 0.20
Nodes (7): ScenePhase, CueKind, center, clear, head, left, right

### Community 101 - "Text"
Cohesion: 0.36
Nodes (7): HazardsCard, .body, .body, .content, openAIRequestUsesDataURI(), Text, UIImage

### Community 103 - "CKStatusPill"
Cohesion: 0.22
Nodes (9): CKStatusPill, .body, .fill, Bool, Tone, danger, neutral, trusted (+1 more)

### Community 106 - "PlayerRelay"
Cohesion: 0.29
Nodes (5): AVAudioPlayer, AVAudioPlayerDelegate, PlayerRelay, Error, Void

## Ambiguous Edges - Review These
- `AGENTS.md` → `drafts/README.md`  [AMBIGUOUS]
  ios/drafts/README.md · relation: conceptually_related_to

## Knowledge Gaps
- **446 isolated node(s):** `AppIntents`, `.localizedStringResource`, `.status`, `.hapticsSilenced`, `.loggingEnabled` (+441 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **9 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **What is the exact relationship between `AGENTS.md` and `drafts/README.md`?**
  _Edge tagged AMBIGUOUS (relation: conceptually_related_to) - confidence is low._
- **Why does `String` connect `String` to `Foundation`, `CaneKitUITests`, `DepthEngine`, `NavSupportTests.swift`, `BeaconEngine`, `CaneBLE`, `HapticPlayer`, `.waypoints`, `VLMClient`, `LaneTile`, `NavigationEngine`, `VLMError`, `WorkoutRelay`, `ObstacleClass`, `AppModel`, `WatchToPhone`, `NavLiveActivity`, `WatchModel`, `SpeechQueue`, `Waypoint`, `.describe`, `Decodable`, `NavCue`, `HazardScanner`, `TripLogger`, `SceneVocabularyTests.swift`, `TripTracker`, `.wireNavigation`, `SessionRelay`, `LocationService`, `ArrivalCardView`, `AppModel`, `GuideCard`, `.say`, `CodingKeys`, `CKBigButtonStyle`, `Sendable`, `RuntimeRelay`, `HazardRecord`, `DescribeError`, `NSObject`, `DelegateRelay`, `FrameReplay`, `Codable`, `SignPolicy`, `.describe`, `.session`, `.handle`, `View`, `SceneDescriber`, `HazardWatchPolicy`, `VLMProvider`, `CueKind`, `Text`, `CKStatusPill`, `ContentValue`?**
  _High betweenness centrality (0.484) - this node is a cross-community bridge._
- **Why does `AppModel` connect `AppModel` to `Foundation`, `CaneKitUITests`, `NavSupportTests.swift`, `BeaconEngine`, `HapticPlayer`, `docs/README.md`, `NavigationEngine`, `ObstacleClass`, `SpeechQueue`, `DepthEngine`, `CueDecider`, `.describe`, `NavCue`, `HazardScanner`, `TripLogger`, `String`, `TripTracker`, `.wireNavigation`, `LocationService`, `SwiftUI`, `.say`, `HazardRecord`, `NSObject`, `SignPolicy`, `.handle`, `SceneDescriber`, `CueKind`?**
  _High betweenness centrality (0.269) - this node is a cross-community bridge._
- **Why does `CaneKit code reference` connect `CaneKit code reference` to `Module: ui-tests-build — Phone UI, XCUITests, XcodeGen build, CI`, `Module `navigation-trip` — GPS, waypoint engine, turn settling, route sources, trip log/tracker, Live Activity`, `docs/README.md`, `Module: speech-audio-scene (`ios/CaneKit/Speech`, `ios/CaneKit/Audio`, `ios/CaneKit/Scene`)`, `Module: logic — `ios/Logic` (SwiftPM package `CaneKitLogic`)`, `Module `depth-haptics` — `ios/CaneKit/Depth/*.swift`, `ios/CaneKit/Haptics/HapticPlayer.swift``, `Module `watch-widget-shared``?**
  _High betweenness centrality (0.109) - this node is a cross-community bridge._
- **Are the 19 inferred relationships involving `AppModel` (e.g. with `AudioRouteMonitor` and `BeaconEngine`) actually correct?**
  _`AppModel` has 19 INFERRED edges - model-reasoned connections that need verification._
- **Are the 5 inferred relationships involving `Coordinate` (e.g. with `.ingest()` and `.mapKit()`) actually correct?**
  _`Coordinate` has 5 INFERRED edges - model-reasoned connections that need verification._
- **What connects `AppIntents`, `.localizedStringResource`, `.status` to the rest of the system?**
  _446 weakly-connected nodes found - possible documentation gaps or missing edges._