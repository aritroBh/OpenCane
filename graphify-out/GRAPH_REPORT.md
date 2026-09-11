# Graph Report - 54FoundersHack  (2026-09-11)

## Corpus Check
- 110 files · ~195,444 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 1857 nodes · 4003 edges · 106 communities (97 shown, 9 thin omitted)
- Extraction: 90% EXTRACTED · 10% INFERRED · 0% AMBIGUOUS · INFERRED: 414 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `7b152561`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Sendable
- Foundation
- CaneKitUITests
- DepthEngine
- NavSupportTests.swift
- BeaconEngine
- CaneKit iPhone app target
- AppIntents.swift
- CaneBLE
- HapticPlayer
- .waypoints
- docs/README.md
- CKBigButtonStyle
- VLMClient
- LaneTile
- NavigationEngine
- VLMError
- NSObject
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
- GeoFix
- .samples
- HazardScanner
- 2. Device test matrix
- Codable
- e2e.py
- TripLogger
- Ideas: retrofit smart-cane kit
- HazardTests.swift
- ElevenLabsVoice
- .nouns
- TripTracker
- .wireNavigation
- SessionRelay
- .laneRow
- SwiftUI
- CaneKit design system
- Text
- CaneKit grip module firmware
- .computeLanes
- AppModel
- `AppModel.swift` — engine owner, settings, cue router
- CKStatusPill
- .event
- Module: logic — `ios/Logic` (SwiftPM package `CaneKitLogic`)
- Cane mount for the iPhone 17 Pro Max: design brief
- CodingKeys
- sign_probe.swift
- CaneKit — strict build checklist
- WKBigButton
- Module `watch-widget-shared`
- RuntimeRelay
- HazardRecord
- DescribeError
- HeadPoseTracker
- GroundHazardPolicy
- FrameReplay
- .distanceMeters
- Package.swift
- ArrivalCardView
- DepthFrameProcessor.swift
- Module `navigation-trip` — GPS, waypoint engine, turn settling, route sources, trip log/tracker, Live Activity
- SessionObserver
- Module: speech-audio-scene (`ios/CaneKit/Speech`, `ios/CaneKit/Audio`, `ios/CaneKit/Scene`)
- .handle
- SceneDescriber
- String
- Team handoff: read this first after you pull
- pitch_model.py
- HazardWatchPolicy
- CameraControlInteraction
- CaneKit changelog
- VLMCodec.swift
- AGENTS.md — rules for anyone (human or AI) editing OpenCane / CaneKit
- Every doc
- Route: ISR Townsend Hall to CIF (UIUC, Urbana IL)
- StraightWalkDetector
- CaneKit: the iOS app for the phone-only smart cane
- CaneKit code reference
- Module `depth-haptics` — `ios/CaneKit/Depth/*.swift`, `ios/CaneKit/Haptics/HapticPlayer.swift`
- LaneGrid
- AirPods + Apple Watch — setup and what the app does about them
- OpenCane: a smart-cane kit that clips an iPhone onto the cane you already own
- `ios/CaneKit/Speech/SpeechQueue.swift`
- hardware/: phone-to-cane mount
- streetview/README.md
- .subscript
- .jpegSnapshot
- cad/README.md
- ElevenLabsVoice.swift
- test.sh
- Swift 6 approachable-concurrency build settings

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
- `rawEntrypointHonoursPaddedRowStrides()` --calls--> `scene`  [INFERRED]
  ios/Logic/Tests/CaneKitLogicTests/LaneMathTests.swift → ios/CaneKit/Speech/SpeechQueue.swift
- `CaneKitWidget Live Activity target` --conceptually_related_to--> `LiveActivityController`  [INFERRED]
  ios/project.yml → ios/CaneKit/Trip/LiveActivityController.swift

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Navigation rules: fences, veer, arrival, turn settling** — ios_canekit_navigation_navigationengine_navigationengine, ios_logic_sources_canekitlogic_geomath_geofencetracker, ios_logic_sources_canekitlogic_geomath_offcoursedetector, ios_logic_sources_canekitlogic_navsupport_turnsettle, ios_logic_sources_canekitlogic_navsupport_straightwalkdetector [EXTRACTED 1.00]
- **Obstacle cue pipeline (~15 Hz)** — ios_canekit_depth_depthframeprocessor_depthframeprocessor, ios_canekit_depth_depthengine_depthengine, ios_logic_sources_canekitlogic_lanereport_lanereport, ios_canekit_app_appmodel_appmodel_handle, ios_logic_sources_canekitlogic_cuedecider_cuedecider, ios_canekit_haptics_hapticplayer_hapticplayer, ios_canekit_watch_phonewatchlink_phonewatchlink, ios_logic_sources_canekitlogic_navsupport_cuespeechpolicy, ios_canekit_speech_obstaclenamer_obstaclenamer [EXTRACTED 1.00]
- **Per-GPS-fix route guidance loop** — ios_canekit_navigation_locationservice_locationservice, ios_canekit_app_appmodel_appmodel_wirenavigation, ios_canekit_navigation_navigationengine_navigationengine, ios_logic_sources_canekitlogic_geomath_geofencetracker, ios_logic_sources_canekitlogic_navsupport_turnsettle, ios_logic_sources_canekitlogic_geomath_offcoursedetector, ios_canekit_app_appmodel_appmodel_startticker, ios_canekit_audio_beaconengine_beaconengine [EXTRACTED 1.00]
- **Phone-watch cue and command link over the WatchMessage wire contract** — ios_canekit_watch_phonewatchlink_phonewatchlink, ios_logic_sources_canekitlogic_watchmessage, ios_canekitwatch_watchmodel_watchmodel [EXTRACTED 1.00]
- **Watch command round trip (button/crown to phone action)** — ios_canekitwatch_watchmodel_watchmodel_send, ios_logic_sources_canekitlogic_watchmessage_watchenvelope, ios_canekit_watch_phonewatchlink_sessionrelay, ios_canekit_watch_phonewatchlink_phonewatchlink, ios_canekit_app_appmodel_appmodel_handlewatchcommand, ios_canekit_navigation_navigationengine_navigationengine [EXTRACTED 1.00]

## Communities (106 total, 9 thin omitted)

### Community 0 - "Sendable"
Cohesion: 0.11
Nodes (22): Equatable, HazardSource, ground, sign, vision, NavEvent, reached, Config (+14 more)

### Community 1 - "Foundation"
Cohesion: 0.15
Nodes (9): ActivityKit, AVFoundation, CaneKitLogic, CoreBluetooth, CoreHaptics, CoreLocation, Foundation, MapKit (+1 more)

### Community 2 - "CaneKitUITests"
Cohesion: 0.09
Nodes (12): CaneKitUITests, Bool, TimeInterval, XCUIApplication, XCUIElement, CaneKitVisualTour, Data, TimeInterval (+4 more)

### Community 3 - "DepthEngine"
Cohesion: 0.16
Nodes (14): ARConfidenceLevel, DepthEngine, LaneReport, ARFrame, ARSession, ARWorldTrackingConfiguration, CVPixelBuffer, Double (+6 more)

### Community 4 - "NavSupportTests.swift"
Cohesion: 0.11
Nodes (33): Config, CrownAccumulator, CueSpeechPolicy, Bool, Double, TimeInterval, Tier, obstacle (+25 more)

### Community 5 - "BeaconEngine"
Cohesion: 0.07
Nodes (29): AVAudioFormat, AVAudioPCMBuffer, CLBackgroundActivitySession, CLHeading, CLLocationManager, CLLocationManagerDelegate, AudioRouteMonitor, .isAirPods (+21 more)

### Community 6 - "CaneKit iPhone app target"
Cohesion: 0.20
Nodes (11): CI workflow (manual trigger only), logic-tests job (Linux, swift:6.2), sim-build job (macOS, informational), Background modes (audio, location; workout-processing, mindfulness), CaneKit iPhone app target, CaneKitLogic SwiftPM package, CaneKitUITests target, CaneKitWatch target (+3 more)

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
Cohesion: 0.18
Nodes (9): CLLocation, CLLocationCoordinate2D, MKPolyline, .coordinates, RouteSource, .current, RouteBuilder, RouteStepInput (+1 more)

### Community 12 - "CKBigButtonStyle"
Cohesion: 0.09
Nodes (24): ButtonStyle, ColorSchemeContrast, Configuration, .body, CKBigButton, .body, .icon, .text (+16 more)

### Community 13 - "VLMClient"
Cohesion: 0.17
Nodes (14): CaseIterable, Secrets, .hasElevenLabs, Bool, AnthropicClient, GeminiClient, OpenAICompatibleClient, VLMClient (+6 more)

### Community 14 - "LaneTile"
Cohesion: 0.20
Nodes (11): LaneGridView, .body, LaneTile, .fill, .level, .levelWord, .text, Bool (+3 more)

### Community 15 - "NavigationEngine"
Cohesion: 0.22
Nodes (7): NavigationEngine, Bool, Date, Double, Int, TimeInterval, Void

### Community 16 - "VLMError"
Cohesion: 0.13
Nodes (22): post(), Data, URL, Data, Int, VLMError, emptyResponse, .errorDescription (+14 more)

### Community 17 - "NSObject"
Cohesion: 0.11
Nodes (17): HealthKit, HKWorkoutSession, HKWorkoutSessionDelegate, HKWorkoutSessionState, Any, Bool, Date, Error (+9 more)

### Community 18 - "ObstacleClass"
Cohesion: 0.07
Nodes (35): ClosedRange, MeshClassifier, ARFrame, Bool, Float, ObstacleNamer, Float, LaneReport (+27 more)

### Community 19 - "AppModel"
Cohesion: 0.10
Nodes (18): AppModel, .beaconEnabled, .fallbackToWatch, .groundHazardsEnabled, .hapticsSilenced, .hazardWatchEnabled, .loggingEnabled, .mirrorLeftRight (+10 more)

### Community 20 - "WatchToPhone"
Cohesion: 0.22
Nodes (10): Any, WatchEnvelope, WatchToPhone, describe, nextWaypoint, recenter, repeatLast, phoneToWatchRoundTrips() (+2 more)

### Community 21 - "NavLiveActivity"
Cohesion: 0.16
Nodes (11): CaneKitWidgetBundle, .body, Widget, NavLiveActivity, .body, Int, View, Widget (+3 more)

### Community 22 - "WatchModel"
Cohesion: 0.22
Nodes (8): .content, Double, Int, Never, Task, TimeInterval, WatchModel, WKHapticType

### Community 23 - "SpeechQueue"
Cohesion: 0.05
Nodes (48): AVAudioPlayer, AVAudioPlayerDelegate, AVAudioSession, AVSpeechSynthesisVoice, AVSpeechSynthesizer, AVSpeechSynthesizerDelegate, AVSpeechUtterance, Comparable (+40 more)

### Community 24 - "DepthFrameProcessor"
Cohesion: 0.11
Nodes (16): AsyncStream, DepthFrameProcessor, .hasCameraFrame, .rotationRate, ProcessorSettings, ARFrame, ARSession, Bool (+8 more)

### Community 25 - "Waypoint"
Cohesion: 0.17
Nodes (13): Identifiable, GeoMath, Double, Route, Bool, Decoder, Double, Int (+5 more)

### Community 26 - "DepthEngine"
Cohesion: 0.19
Nodes (8): DepthEngine, ARWorldTrackingConfiguration, Bool, Double, LaneReport, Never, TimeInterval, Void

### Community 27 - "Coordinate"
Cohesion: 0.27
Nodes (21): Coordinate, GeofenceTracker, .isFinished, aGatedOutFixDoesNotBreakTheArrivalStreak(), arrivalStreakResetsOnAMiss(), cardinalBearings(), fix(), geofenceGatesOnAccuracyAndSpeedExceptArrival() (+13 more)

### Community 28 - "CueDecider"
Cohesion: 0.08
Nodes (46): Hashable, .logicPackageOK, CueDecider, CueKind, center, clear, head, left (+38 more)

### Community 29 - ".describe"
Cohesion: 0.18
Nodes (11): FoundationModels, OnDeviceHazards, OnDeviceVision, OnDeviceVLMClient, SceneContext, Bool, Data, Float (+3 more)

### Community 30 - "Decodable"
Cohesion: 0.19
Nodes (19): Decodable, Encodable, Candidate, Content, ErrorEnvelope, GenerateRequest, GenerateResponse, GenerationConfig (+11 more)

### Community 31 - "NavCue"
Cohesion: 0.13
Nodes (15): PhoneWatchLink, Any, Int, TimeInterval, NavCue, arrived, crossing, obstacle (+7 more)

### Community 32 - "Module: ui-tests-build — Phone UI, XCUITests, XcodeGen build, CI"
Cohesion: 0.06
Nodes (31): docs/design.md — rules the UI code implements, `enum CKColor` (namespace, no cases), `enum CKFont`, `enum CKMetrics`, `enum CKRadius`, `enum CKSpacing` (4 pt base), .github/workflows/ci.yml, ios/CaneKit/UI/ArrivalCardView.swift (+23 more)

### Community 33 - "GeoFix"
Cohesion: 0.20
Nodes (13): C, CourseSmoother, Double, Int, TimeInterval, GeoFix, aRealTurnShowsUpAfterTheBaseline(), at() (+5 more)

### Community 34 - ".samples"
Cohesion: 0.33
Nodes (6): GroundSampler, ARFrame, Float, Int, SIMD3, UInt8

### Community 35 - "HazardScanner"
Cohesion: 0.15
Nodes (12): HazardScanner, Any, Bool, CGFloat, Data, Double, Int, Never (+4 more)

### Community 36 - "2. Device test matrix"
Cohesion: 0.07
Nodes (30): 0. Read this before testing: facts from the code that change how you test, 1.0 The next 24 hours, 1.1 Automated (Mac, no phone): run on every change, 1.2 Bench (indoors, phone plugged in, ISR lobby), 1.3 Outdoor walks, 1.4 Log toolkit (Aritro), 1. Test levels, 2. Device test matrix (+22 more)

### Community 37 - "Codable"
Cohesion: 0.23
Nodes (8): Codable, OffCourseDetector, TimeInterval, Turn, left, right, offCourseNeedsThreeSecondsThenCoolsDown(), offCourseResetsWhenBackOnBearing()

### Community 38 - "e2e.py"
Cohesion: 0.17
Nodes (25): check(), container(), densify(), dist(), launch_and_wait_for_route(), load_waypoints(), main(), navcues() (+17 more)

### Community 39 - "TripLogger"
Cohesion: 0.13
Nodes (12): FileHandle, ScenePhase, Double, Float, Int, LaneReport, Never, Task (+4 more)

### Community 40 - "Ideas: retrofit smart-cane kit"
Cohesion: 0.08
Nodes (24): 0. One-liner, 1. Verdict, 2.1 A camera on a sweeping cane sees motion blur, 2.2 The cane tip already finds the ground, 2.3 "A to B in rain and dark" needs careful wording, 2. Three pushbacks on the original brief, 3. Form factor (Sagar), 4. Buy list (order Thursday night, Amazon only) (+16 more)

### Community 41 - "HazardTests.swift"
Cohesion: 0.23
Nodes (22): GroundHazardDetector, aCurbDownIsADropOff(), aCurbUpIsAStepUp(), aCurbYouWalkTowardStillConfirms(), aHazardNeedsThreeAgreeingFrames(), aHoleThatComesBackUpIsAPothole(), aMidBinCurbFaceIsStillFound(), aPartialWallIsNotAStep() (+14 more)

### Community 42 - "ElevenLabsVoice"
Cohesion: 0.23
Nodes (10): ElevenLabsVoice, .cacheDir, Data, Int, TimeInterval, URL, VoiceError, badResponse (+2 more)

### Community 43 - ".nouns"
Cohesion: 0.16
Nodes (14): .body, Group, SceneVocabulary, Bool, Float, Int, crossingInformationComesFirst(), indoorSceneIsPlain() (+6 more)

### Community 44 - "TripTracker"
Cohesion: 0.20
Nodes (9): HKObserverQuery, Date, Double, Int, Never, Task, TimeInterval, Void (+1 more)

### Community 45 - ".wireNavigation"
Cohesion: 0.18
Nodes (7): Activity, ActivityAttributes, Task, LiveActivityController, Int, CaneKitWidget Live Activity target, NavActivityAttributes

### Community 46 - "SessionRelay"
Cohesion: 0.32
Nodes (6): SessionRelay, Bool, Error, Void, WCSession, WCSessionActivationState

### Community 47 - ".laneRow"
Cohesion: 0.39
Nodes (5): LaneFormat, LaneGrid, .body, Float, LaneReport

### Community 48 - "SwiftUI"
Cohesion: 0.10
Nodes (15): App, AVKit, CaneKitApp, .body, Scene, Scene, WatchApp, .body (+7 more)

### Community 49 - "CaneKit design system"
Cohesion: 0.07
Nodes (29): 0. Who looks at the screen, and what that forces, 10. Open design gaps (code ≠ intent, not yet fixed), 1. Typography, 2. Colour tokens, 3. Spacing and radius, 4. Motion, 5.1 Speech priorities (`SpeechQueue`, AGENTS.md hard rule 8), 5.2 Obstacle cues (phone Taptic Engine, felt through the cane) (+21 more)

### Community 50 - "Text"
Cohesion: 0.16
Nodes (20): ContentView, .body, .capabilityCard, .mountAimRow, .statusCard, AppModel, Bindable, Bool (+12 more)

### Community 51 - "CaneKit grip module firmware"
Cohesion: 0.29
Nodes (6): Build — Arduino IDE, Build — PlatformIO, CaneKit grip module firmware, Protocol (NUS, device name `CANE`), Testing with nRF Connect (Android / iOS), Wiring

### Community 52 - ".computeLanes"
Cohesion: 0.23
Nodes (16): LaneConfig, UInt8, groundBandIsSkipped(), headRowIsTopBand(), landscapeModeUsesBufferAsScene(), leftWallOnlyHitsLeftLanes(), lowConfidencePixelsAreIgnored(), mirrorSwapsLeftAndRight() (+8 more)

### Community 53 - "AppModel"
Cohesion: 0.11
Nodes (21): AppModel, .extendedRange, .hapticsEnabled, .mirrorLeftRight, .portraitMode, .speechEnabled, .urgentDistance, .warnDistance (+13 more)

### Community 54 - "`AppModel.swift` — engine owner, settings, cue router"
Cohesion: 0.12
Nodes (16): `AppModel.swift` — engine owner, settings, cue router, Auto-recenter — `autoRecenterIfWalkingStraight(_ fix: GeoFix)` (private, per GPS fix while navigating), Constants, Cue router — `handle(_ report: LaneReport)` (private, ~15 Hz, called from `depth.onReport`), Engine wiring (all `let`, created in the property initialisers except `describer`, `sceneContext` and `hazards`, which `init` builds), Hazards the maps do not know about (Step 11), Headphones / watch presence, Lifecycle (+8 more)

### Community 55 - "CKStatusPill"
Cohesion: 0.10
Nodes (19): Font, GuideCard, .beaconWord, .body, .gpsTone, .gpsWord, .headSpoken, .headWord (+11 more)

### Community 57 - "Module: logic — `ios/Logic` (SwiftPM package `CaneKitLogic`)"
Cohesion: 0.12
Nodes (16): `CourseSmoother.swift` — direction of travel over ≥ 15 m, for veer decisions only (Step 11), Cross-module contracts (who uses what), `CueDecider.swift` — LaneReport → haptic cue with hysteresis and rate limiting (decides *what/when*; player is elsewhere), `GeoMath.swift` — haversine distance/bearing, angle wrapping, off-course detection, waypoint geofences, `Hazards.swift` — hazards the maps do not know about: LiDAR ground profile, sign phrases, vision-model hazard replies, GeoJSON hazard map (Step 11), `ios/Logic/Package.swift`, `ios/scripts/test.sh` — runs the package tests (`make test`), `LaneMath.swift` — LiDAR depth map → 3 lanes × 2 bands (10th-percentile per cell) + centre median (+8 more)

### Community 58 - "Cane mount for the iPhone 17 Pro Max: design brief"
Cohesion: 0.12
Nodes (16): 0. Decisions, 10. Print settings, 11. Assembly and setting the angle, 12. Test protocol, 13. Open risks and follow-ups, 14. Sources, 1. Inputs and where they come from, 2. What the software needs from the mount (+8 more)

### Community 59 - "CodingKeys"
Cohesion: 0.18
Nodes (11): CodingKey, CodingKeys, bearingNextDeg, crossing, curved, id, lat, lon (+3 more)

### Community 60 - "sign_probe.swift"
Cohesion: 0.16
Nodes (14): AppKit, CGImage, CoreText, composite(), Entry, metres(), normalize(), reads() (+6 more)

### Community 61 - "CaneKit — strict build checklist"
Cohesion: 0.13
Nodes (15): CaneKit — strict build checklist, Cross-cutting, Step 0 — phone-only reset, Step 10 — Review fixes + UI tests (pre-device), Step 11 — Hazards the maps don't know, on-device vision, stress harness (pre-device), Step 12 — Google Street View mock of ISR → CIF (pre-device), Step 1 — project scaffold, Step 2 — DepthEngine (+7 more)

### Community 62 - "WKBigButton"
Cohesion: 0.13
Nodes (14): Role, destructive, primary, secondary, Bool, CGFloat, Color, UInt32 (+6 more)

### Community 63 - "Module `watch-widget-shared`"
Cohesion: 0.14
Nodes (14): Cross-module map, `ios/CaneKit/Watch/PhoneWatchLink.swift` — phone side of WatchConnectivity, `ios/CaneKitWatch/CaneKitWatch.entitlements`, `ios/CaneKitWatch/WatchApp.swift` — watchOS entry point, `ios/CaneKitWatch/WatchContentView.swift` — the wrist screen, `ios/CaneKitWatch/WatchModel.swift` — watch side: haptics, commands, crown, keep-alive, `ios/CaneKitWatch/WatchTheme.swift` — watch design tokens (docs/design.md §6.6), `ios/CaneKitWidget/CaneKitWidgetBundle.swift` — widget extension entry (+6 more)

### Community 64 - "RuntimeRelay"
Cohesion: 0.20
Nodes (8): RuntimeEvent, ended, expiring, started, RuntimeRelay, WKExtendedRuntimeSession, WKExtendedRuntimeSessionDelegate, WKExtendedRuntimeSessionInvalidationReason

### Community 65 - "HazardRecord"
Cohesion: 0.20
Nodes (10): HazardLog, .fileURL, Data, URL, HazardGeoJSON, HazardPrompt, HazardRecord, Data (+2 more)

### Community 66 - "DescribeError"
Cohesion: 0.14
Nodes (15): RouteError, destinationNotFound, .errorDescription, missingBundledRoute, noRoute, DescribeError, badResponse, .errorDescription (+7 more)

### Community 67 - "HeadPoseTracker"
Cohesion: 0.21
Nodes (7): CMHeadphoneMotionManager, CMHeadphoneMotionManagerDelegate, ConnectionRelay, HeadPoseTracker, Bool, Double, Void

### Community 68 - "GroundHazardPolicy"
Cohesion: 0.23
Nodes (10): GroundHazardPolicy, SignPolicy, aPartialReadOfTheSameSignIsQuiet(), aSecondSignIsStillRead(), farTextReadsSafetySignsButNotStorefrontWords(), hazardWatchAsksOnlyWhileWalkingAndRarely(), irrelevantOrUnsureTextIsIgnored(), signsAreReadOnceAndSpecifically() (+2 more)

### Community 69 - "FrameReplay"
Cohesion: 0.29
Nodes (7): Frame, FrameReplay, .currentName, State, Bool, Data, URL

### Community 70 - ".distanceMeters"
Cohesion: 0.14
Nodes (6): Bool, Int, Data, isrToCifIsAboutSevenHundredMetres(), routeFileDecodesSnakeCaseSchema(), shippedRouteFileIsConsistent()

### Community 72 - "ArrivalCardView"
Cohesion: 0.43
Nodes (4): ArrivalCardView, .body, Double, TimeInterval

### Community 73 - "DepthFrameProcessor.swift"
Cohesion: 0.23
Nodes (7): ARKit, CoreImage, CoreMotion, CoreVideo, ImageIO, simd, Synchronization

### Community 74 - "Module `navigation-trip` — GPS, waypoint engine, turn settling, route sources, trip log/tracker, Live Activity"
Cohesion: 0.17
Nodes (12): Data flow (who calls whom), `docs/route_isr_cif.md`, `ios/CaneKit/Navigation/LocationService.swift`, `ios/CaneKit/Navigation/NavigationEngine.swift`, `ios/CaneKit/Navigation/RouteSource.swift`, `ios/CaneKit/Resources/route_isr_cif.json` — schema and waypoints, `ios/CaneKit/Trip/HazardLog.swift` (Step 11), `ios/CaneKit/Trip/LiveActivityController.swift` (+4 more)

### Community 75 - "SessionObserver"
Cohesion: 0.19
Nodes (8): ARCamera, ARSessionDelegate, SessionObserver, ARFrame, ARSession, Error, Int, Task

### Community 76 - "Module: speech-audio-scene (`ios/CaneKit/Speech`, `ios/CaneKit/Audio`, `ios/CaneKit/Scene`)"
Cohesion: 0.17
Nodes (12): `ios/CaneKit/Audio/AudioRouteMonitor.swift`, `ios/CaneKit/Audio/BeaconEngine.swift`, `ios/CaneKit/Audio/HeadPoseTracker.swift`, `ios/CaneKit/Scene/CameraControlInteraction.swift`, `ios/CaneKit/Scene/HazardScanner.swift` (Step 11), `ios/CaneKit/Scene/OnDeviceVision.swift` (Step 11), `ios/CaneKit/Scene/SceneDescriber.swift`, `ios/CaneKit/Scene/Secrets.swift` (+4 more)

### Community 77 - ".handle"
Cohesion: 0.27
Nodes (4): CGFloat, Data, LaneReport, TimeInterval

### Community 78 - "SceneDescriber"
Cohesion: 0.22
Nodes (6): CGFloat, Data, SceneDescriber, Data, Int, Void

### Community 80 - "String"
Cohesion: 0.19
Nodes (10): Duration, Settings, String, .sentenceCased, FallbackVLMClient, .name, Entry, normalize() (+2 more)

### Community 81 - "Team handoff: read this first after you pull"
Cohesion: 0.17
Nodes (12): 10. How we work (read before changing anything), 11. Known risks going into the walk, 1. The one-paragraph version, 2. What is proven, and what is not, 3. Who does what next, 4. Pull, build, install, 5. The mount angle (read this, Sagar), 6. What is on, what is off, and why (+4 more)

### Community 82 - "pitch_model.py"
Cohesion: 0.27
Nodes (11): clearance(), convex_hull(), ground_hit(), outside(), pitch_table(), Where the cane shaft (toward the tip) appears in the wide camera's portrait…, z-depth and range where a ray alpha deg above the optical axis meets the ground., Smallest gap (mm) between the cradle box and the cane / collar / ear over phi =… (+3 more)

### Community 83 - "HazardWatchPolicy"
Cohesion: 0.27
Nodes (7): HazardWatchPolicy, Bool, Double, Set, TimeInterval, hazardReplyKeepsDecimals(), hazardWatchRepliesBecomeShortCautions()

### Community 84 - "CameraControlInteraction"
Cohesion: 0.29
Nodes (7): AVCaptureEventInteraction, Context, CameraControlInteraction, Coordinator, Void, UIView, UIViewRepresentable

### Community 85 - "CaneKit changelog"
Cohesion: 0.18
Nodes (11): CaneKit changelog, Step 0 — phone-only reset (Thu Sep 10), Step 10 — Two adversarial review rounds, AirPods/Watch presence, XCUITests (Fri Sep 11, pre-device), Step 11 — Hazards the maps don't know, on-device vision, stress harness (Fri Sep 11, pre-device), Step 12 — Google Street View mock of ISR → CIF: what failed and the fixes (Fri Sep 11, pre-device), Step 3 — Core Haptics (Fri Sep 11, pre-device), Step 4 — Speech + obstacle names (Fri Sep 11, pre-device), Step 5 — Watch (Fri Sep 11, pre-device) (+3 more)

### Community 86 - "VLMCodec.swift"
Cohesion: 0.25
Nodes (6): Drafts (iOS 18, pre-hackathon), .spokenLine, ScenePrompt, SpokenDistance, Float, spokenDistances()

### Community 87 - "AGENTS.md — rules for anyone (human or AI) editing OpenCane / CaneKit"
Cohesion: 0.25
Nodes (8): AGENTS.md — rules for anyone (human or AI) editing OpenCane / CaneKit, Commands, Hard rules, How we engineer (the bar for every change, human or AI), Layout, Things that look wrong but are deliberate, What this is, Where the plan and history live

### Community 88 - "Every doc"
Cohesion: 0.25
Nodes (8): `docs/`, Docs index, Every doc, Hardware, iOS app, Outside `docs/`, Repo root, Where do I find…

### Community 89 - "Route: ISR Townsend Hall to CIF (UIUC, Urbana IL)"
Cohesion: 0.25
Nodes (8): Evidence per waypoint (OSM), Route: ISR Townsend Hall to CIF (UIUC, Urbana IL), Sources, To re-record on the Friday walk, Waypoints (from the JSON), What the app does at each waypoint, Where Townsend Hall is, and which door is "the Townsend exit", Why the file looks the way it does

### Community 90 - "StraightWalkDetector"
Cohesion: 0.39
Nodes (4): StraightWalkDetector, Int, straightWalkNeedsThreeSteadyFixesCountingTheFirst(), straightWalkRestartsOnATurnAStopOrAHeadTurn()

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

## Ambiguous Edges - Review These
- `AGENTS.md` → `drafts/README.md`  [AMBIGUOUS]
  ios/drafts/README.md · relation: conceptually_related_to

## Knowledge Gaps
- **444 isolated node(s):** `AppIntents`, `.localizedStringResource`, `.status`, `.hapticsSilenced`, `.loggingEnabled` (+439 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **9 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **What is the exact relationship between `AGENTS.md` and `drafts/README.md`?**
  _Edge tagged AMBIGUOUS (relation: conceptually_related_to) - confidence is low._
- **Why does `String` connect `String` to `Sendable`, `Foundation`, `CaneKitUITests`, `DepthEngine`, `NavSupportTests.swift`, `BeaconEngine`, `CaneBLE`, `HapticPlayer`, `.waypoints`, `CKBigButtonStyle`, `VLMClient`, `LaneTile`, `NavigationEngine`, `VLMError`, `NSObject`, `ObstacleClass`, `AppModel`, `WatchToPhone`, `NavLiveActivity`, `WatchModel`, `SpeechQueue`, `Waypoint`, `CueDecider`, `.describe`, `Decodable`, `NavCue`, `HazardScanner`, `Codable`, `TripLogger`, `ElevenLabsVoice`, `.nouns`, `TripTracker`, `.wireNavigation`, `SessionRelay`, `.laneRow`, `Text`, `AppModel`, `CKStatusPill`, `.event`, `CodingKeys`, `sign_probe.swift`, `WKBigButton`, `RuntimeRelay`, `HazardRecord`, `DescribeError`, `HeadPoseTracker`, `GroundHazardPolicy`, `FrameReplay`, `ArrivalCardView`, `SessionObserver`, `.handle`, `SceneDescriber`, `HazardWatchPolicy`, `VLMCodec.swift`?**
  _High betweenness centrality (0.440) - this node is a cross-community bridge._
- **Why does `AppModel` connect `AppModel` to `Foundation`, `NavSupportTests.swift`, `BeaconEngine`, `HapticPlayer`, `.waypoints`, `docs/README.md`, `NavigationEngine`, `ObstacleClass`, `SpeechQueue`, `DepthEngine`, `CueDecider`, `.describe`, `NavCue`, `HazardScanner`, `TripLogger`, `TripTracker`, `.wireNavigation`, `SwiftUI`, `.event`, `HazardRecord`, `HeadPoseTracker`, `GroundHazardPolicy`, `.handle`, `String`, `StraightWalkDetector`?**
  _High betweenness centrality (0.281) - this node is a cross-community bridge._
- **Why does `CaneKit code reference` connect `CaneKit code reference` to `Module: ui-tests-build — Phone UI, XCUITests, XcodeGen build, CI`, `Module `navigation-trip` — GPS, waypoint engine, turn settling, route sources, trip log/tracker, Live Activity`, `docs/README.md`, `Module: speech-audio-scene (`ios/CaneKit/Speech`, `ios/CaneKit/Audio`, `ios/CaneKit/Scene`)`, `Module: logic — `ios/Logic` (SwiftPM package `CaneKitLogic`)`, `Module `depth-haptics` — `ios/CaneKit/Depth/*.swift`, `ios/CaneKit/Haptics/HapticPlayer.swift``, `Module `watch-widget-shared``?**
  _High betweenness centrality (0.118) - this node is a cross-community bridge._
- **Are the 19 inferred relationships involving `AppModel` (e.g. with `AudioRouteMonitor` and `BeaconEngine`) actually correct?**
  _`AppModel` has 19 INFERRED edges - model-reasoned connections that need verification._
- **Are the 5 inferred relationships involving `Coordinate` (e.g. with `.ingest()` and `.mapKit()`) actually correct?**
  _`Coordinate` has 5 INFERRED edges - model-reasoned connections that need verification._
- **What connects `AppIntents`, `.localizedStringResource`, `.status` to the rest of the system?**
  _444 weakly-connected nodes found - possible documentation gaps or missing edges._