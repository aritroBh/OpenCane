# Graph Report - 54FoundersHack  (2026-09-12)

## Corpus Check
- 190 files · ~442,477 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 3527 nodes · 8210 edges · 182 communities (175 shown, 7 thin omitted)
- Extraction: 89% EXTRACTED · 11% INFERRED · 0% AMBIGUOUS · INFERRED: 932 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `076fcaa8`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- AppModel
- Foundation
- CaneKitUITests
- DepthEngine
- NavSupportTests.swift
- BeaconEngine
- HapticCue
- HandsFreeOption
- CaneBLE
- LiveActivityController
- Waypoint
- docs/README.md
- CKBigButton
- HapticPlayer
- LaneTile
- NavigationEngine
- VLMClient
- VoiceInputEngine
- .computeLanes
- AppModel
- WKBigButton
- NavLiveActivity
- WatchModel
- SpeechQueue
- DepthFrameProcessor
- .samples
- DepthEngine
- Coordinate
- .say
- .describe
- Decodable
- PhoneToWatch
- Module: ui-tests-build — Phone UI, XCUITests, XcodeGen build, CI
- CourseSmoother
- DestinationField
- HazardScanner
- 2. Device test matrix
- .scenePhaseChanged
- e2e.py
- FaceYawTracker
- Ideas: retrofit smart-cane kit
- HazardTests.swift
- HapticLogic
- String
- TripTracker
- Sendable
- Module `depth-haptics` — `ios/CaneKit/Depth/*.swift`, `ios/CaneKit/Haptics/HapticPlayer.swift`
- Float
- .content
- OpenCane design system
- ConversationAction
- CaneKit grip module firmware
- LiveView
- SessionRelay
- `AppModel.swift` — engine owner, settings, cue router
- CKStatusPill
- .model
- Module: logic — `ios/Logic` (SwiftPM package `CaneKitLogic`)
- Cane mount for the iPhone 17 Pro Max: design brief
- CodingKeys
- ObstacleClass
- CaneKit — strict build checklist
- GroundHazard
- Module `watch-widget-shared`
- ObstacleNamer
- HazardRecord
- MultiCamDepthFindings
- HeadNodDetector
- DestinationSearch
- FrameReplay
- OffCourseDetector
- Package.swift
- SignPolicy
- LaunchMode
- Module `navigation-trip` — GPS, waypoint engine, turn settling, route sources, trip log/tracker, Live Activity
- CaneKit iPhone app target
- Module: speech-audio-scene (`ios/CaneKit/Speech`, `ios/CaneKit/Audio`, `ios/CaneKit/Scene`)
- .directions
- View
- LaneGrid
- Team handoff: read this first after you pull
- pitch_model.py
- SpeechResume
- CameraControlInteraction
- CaneKit changelog
- .session
- AGENTS.md — rules for anyone (human or AI) editing OpenCane / CaneKit
- Every doc
- Route: ISR Townsend Hall to CIF (UIUC, Urbana IL)
- SoundRecognitionGuard
- OpenCane: the iOS app for the phone-only smart cane
- CaneKit code reference
- Team brief: OpenCane / CaneKit at HEAD `076fcaa` (Sat 2026-09-12 evening)
- RuntimeRelay
- AirPods + Apple Watch — setup and what the app does about them
- OpenCane: a smart-cane kit that clips an iPhone onto the cane you already own
- SoundAlertsTests.swift
- hardware/: phone-to-cane mount
- streetview/README.md
- ConversationLogicTests
- DepthSnapshot
- cad/README.md
- CampusPlacesTests.swift
- test.sh
- Swift 6 approachable-concurrency build settings
- CueDecider
- GeoFix
- SightingKind
- .handle
- CueKind
- SceneVocabulary
- StatusFacts
- TorchSwitch
- PeopleAheadTests.swift
- ConversationCoordinator
- SoundWatcher
- DangerSound
- DepthReadiness
- CueRules
- Printing the screwless mount — operator runbook
- RootTab
- SensorProbe
- DualCameraSession
- SwiftUI
- .resumeOffset
- Text
- TripLogger
- ElevenLabsVoice
- CallbackBox
- ProbeSessionWatcher
- sign_probe.swift
- .probeCapture
- CloudSceneGateTests.swift
- SpeechLoadPolicy
- cue_audit.py
- DepthFrameContinuity
- DualCameraFrameRelay
- Codable
- OpenCane cue design v2: what blind travellers need, and how to make the cane calmer
- LiveViewTests.swift
- Testing
- .queue
- SoundAnalysisPump
- DualPreviewHostView
- LiveCameraView
- ios/CaneKit/UI/Theme.swift
- Driving OpenCane without looking at the screen
- SoundResultsRelay
- QuestionPromptTests.swift
- stl_tools.js
- OpenCane Speech Load Design
- .session
- Global Constraints
- ConversationTurn
- SoundRecognitionFailure
- .insetRect
- 3D print files — the screwless phone mount
- CueLevel
- WorkoutRelay
- SceneDescriber
- appicon.py
- ProbeIntrospection
- Auditory load: what the research says, what OpenCane does
- TileLevel
- MicrophoneSessionResult
- Bolt's Journal - Critical Learnings
- CampusDestination
- ConversationTool
- .publishReadiness
- .decide
- PlayerRelay
- ProbeOutputDelegate
- StatusAspect
- VoiceInputState
- BothCameras
- .jpegSnapshot
- .portDescription

## God Nodes (most connected - your core abstractions)
1. `AppModel` - 131 edges
2. `CaneKitLogic` - 76 edges
3. `Coordinate` - 70 edges
4. `SpeechQueue` - 64 edges
5. `DepthFrameProcessor` - 46 edges
6. `DepthEngine` - 44 edges
7. `CaneKit changelog` - 43 edges
8. `GroundHazardDetector` - 39 edges
9. `SoundWatcher` - 36 edges
10. `SignPolicy` - 36 edges

## Surprising Connections (you probably didn't know these)
- `UIFileSharingEnabled for trip logs and hazard map` --conceptually_related_to--> `TripLogger`  [INFERRED]
  ios/project.yml → ios/CaneKit/Trip/TripLogger.swift
- `CaneKitUITests target` --references--> `CaneKitUITests`  [INFERRED]
  ios/project.yml → ios/CaneKitUITests/CaneKitUITests.swift
- `CaneKitWidget Live Activity target` --conceptually_related_to--> `LiveActivityController`  [INFERRED]
  ios/project.yml → ios/CaneKit/Trip/LiveActivityController.swift
- `.body` --calls--> `LaneGridView`  [INFERRED]
  ios/CaneKit/UI/ContentView.swift → ios/CaneKit/UI/LaneGridView.swift
- `NavActivityAttributes` --shares_data_with--> `CaneKit iPhone app target`  [EXTRACTED]
  ios/Shared/LiveActivity/NavActivityAttributes.swift → ios/project.yml

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Navigation rules: fences, veer, arrival, turn settling** — ios_canekit_navigation_navigationengine_navigationengine, ios_logic_sources_canekitlogic_geomath_geofencetracker, ios_logic_sources_canekitlogic_geomath_offcoursedetector, ios_logic_sources_canekitlogic_navsupport_turnsettle, ios_logic_sources_canekitlogic_navsupport_straightwalkdetector [EXTRACTED 1.00]
- **Obstacle cue pipeline (~15 Hz)** — ios_canekit_depth_depthframeprocessor_depthframeprocessor, ios_canekit_depth_depthengine_depthengine, ios_logic_sources_canekitlogic_lanereport_lanereport, ios_canekit_app_appmodel_appmodel_handle, ios_logic_sources_canekitlogic_cuedecider_cuedecider, ios_canekit_haptics_hapticplayer_hapticplayer, ios_canekit_watch_phonewatchlink_phonewatchlink, ios_logic_sources_canekitlogic_navsupport_cuespeechpolicy, ios_canekit_speech_obstaclenamer_obstaclenamer [EXTRACTED 1.00]
- **Per-GPS-fix route guidance loop** — ios_canekit_navigation_locationservice_locationservice, ios_canekit_app_appmodel_appmodel_wirenavigation, ios_canekit_navigation_navigationengine_navigationengine, ios_logic_sources_canekitlogic_geomath_geofencetracker, ios_logic_sources_canekitlogic_navsupport_turnsettle, ios_logic_sources_canekitlogic_geomath_offcoursedetector, ios_canekit_app_appmodel_appmodel_startticker, ios_canekit_audio_beaconengine_beaconengine [EXTRACTED 1.00]
- **Phone-watch cue and command link over the WatchMessage wire contract** — ios_canekit_watch_phonewatchlink_phonewatchlink, ios_logic_sources_canekitlogic_watchmessage, ios_canekitwatch_watchmodel_watchmodel [EXTRACTED 1.00]
- **Watch command round trip (button/crown to phone action)** — ios_canekitwatch_watchmodel_watchmodel_send, ios_logic_sources_canekitlogic_watchmessage_watchenvelope, ios_canekit_watch_phonewatchlink_sessionrelay, ios_canekit_watch_phonewatchlink_phonewatchlink, ios_canekit_app_appmodel_appmodel_handlewatchcommand, ios_canekit_navigation_navigationengine_navigationengine [EXTRACTED 1.00]

## Communities (182 total, 7 thin omitted)

### Community 0 - "AppModel"
Cohesion: 0.09
Nodes (29): AppModel, .extendedRange, .hapticsEnabled, .mirrorLeftRight, .portraitMode, .speechEnabled, .urgentDistance, .warnDistance (+21 more)

### Community 1 - "Foundation"
Cohesion: 0.09
Nodes (18): AVFoundation, CaneKitLogic, CoreBluetooth, CoreHaptics, CoreLocation, CoreMedia, CryptoKit, Foundation (+10 more)

### Community 2 - "CaneKitUITests"
Cohesion: 0.08
Nodes (12): CaneKitUITests, Bool, TimeInterval, XCUIApplication, XCUIElement, CaneKitVisualTour, Data, TimeInterval (+4 more)

### Community 3 - "DepthEngine"
Cohesion: 0.16
Nodes (13): ARConfidenceLevel, DepthEngine, LaneReport, ARFrame, ARSession, ARWorldTrackingConfiguration, CVPixelBuffer, Double (+5 more)

### Community 4 - "NavSupportTests.swift"
Cohesion: 0.06
Nodes (53): .spokenLine, Config, CrownAccumulator, CueSpeechPolicy, StraightWalkDetector, Bool, Double, Int (+45 more)

### Community 5 - "BeaconEngine"
Cohesion: 0.06
Nodes (29): CLBackgroundActivitySession, CLHeading, CLLocationManager, CLLocationManagerDelegate, AudioRouteMonitor, .isAirPods, Bool, Never (+21 more)

### Community 6 - "HapticCue"
Cohesion: 0.10
Nodes (18): .logicPackageOK, CueOutput, fire, stop, updateCenter, CueThresholds, GeigerRate, HapticCue (+10 more)

### Community 7 - "HandsFreeOption"
Cohesion: 0.09
Nodes (31): AppEnum, AppIntent, AppIntents, AppModel, AskSceneIntent, HandsFreeOption, beacon, dropOffs (+23 more)

### Community 8 - "CaneBLE"
Cohesion: 0.11
Nodes (21): CBCentralManager, CBCentralManagerDelegate, CBCharacteristic, CBPeripheral, CBPeripheralDelegate, CBService, CaneBLE, ConnectionState (+13 more)

### Community 9 - "LiveActivityController"
Cohesion: 0.21
Nodes (10): Activity, ActivityAttributes, Hashable, LiveActivityController, Bool, Int, CaneKitWidget Live Activity target, ContentState (+2 more)

### Community 10 - "Waypoint"
Cohesion: 0.26
Nodes (8): Bool, Decoder, Double, Int, Waypoint, .coordinate, .placeName, bearingConsistencyCheckCatchesTypos()

### Community 11 - "docs/README.md"
Cohesion: 0.30
Nodes (5): Hard rules, CaneKit — Claude Code project rules, CI workflow (manual trigger only), sim-build job (macOS, informational), gen.sh script

### Community 12 - "CKBigButton"
Cohesion: 0.13
Nodes (15): ButtonStyle, Configuration, .selfTests, CKBigButton, .body, .icon, .text, CKBigButtonStyle (+7 more)

### Community 13 - "HapticPlayer"
Cohesion: 0.14
Nodes (12): CHHapticEngine, CHHapticPattern, CHHapticPatternPlayer, HapticPlayer, .silenced, Float, Int, Never (+4 more)

### Community 14 - "LaneTile"
Cohesion: 0.21
Nodes (11): LaneGridView, .body, LaneTile, .fill, .level, .levelWord, .text, Bool (+3 more)

### Community 15 - "NavigationEngine"
Cohesion: 0.15
Nodes (9): Element, Array, NavigationEngine, Bool, Date, Double, Int, TimeInterval (+1 more)

### Community 16 - "VLMClient"
Cohesion: 0.05
Nodes (54): Duration, Secrets, .hasElevenLabs, Bool, AnthropicClient, FallbackVLMClient, .cloudPrimary, .name (+46 more)

### Community 17 - "VoiceInputEngine"
Cohesion: 0.08
Nodes (29): SpeechBufferBox, SpeechResultsRelay, Any, AVAudioFormat, AVAudioNode, AVAudioPCMBuffer, Bool, Double (+21 more)

### Community 18 - ".computeLanes"
Cohesion: 0.17
Nodes (21): LaneGrid, scene, LaneConfig, UInt8, UnsafeRawPointer, PublishGate, Double, groundBandIsSkipped() (+13 more)

### Community 19 - "AppModel"
Cohesion: 0.07
Nodes (22): AppModel, .beaconEnabled, .cueLevel, .cuePlace, .dangerSoundsEnabled, .fallbackToWatch, .groundHazardsEnabled, .hapticsSilenced (+14 more)

### Community 20 - "WKBigButton"
Cohesion: 0.12
Nodes (15): Role, destructive, primary, secondary, Bool, CGFloat, Color, UInt32 (+7 more)

### Community 21 - "NavLiveActivity"
Cohesion: 0.20
Nodes (10): CaneKitWidgetBundle, .body, Widget, NavLiveActivity, .body, Int, View, Widget (+2 more)

### Community 22 - "WatchModel"
Cohesion: 0.26
Nodes (6): HKWorkoutSession, Int, Never, Task, WatchModel, WKHapticType

### Community 23 - "SpeechQueue"
Cohesion: 0.18
Nodes (15): Int, Pending, SpeechPriority, nav, obstacle, safety, SpeechQueue, .microphoneRouteSnapshot (+7 more)

### Community 24 - "DepthFrameProcessor"
Cohesion: 0.15
Nodes (15): ARSessionDelegate, AsyncStream, SessionObserver, DepthFrameProcessor, .hasCameraFrame, .rotationRate, ProcessorSettings, Bool (+7 more)

### Community 25 - ".samples"
Cohesion: 0.33
Nodes (6): GroundSampler, ARFrame, Float, Int, SIMD3, UInt8

### Community 26 - "DepthEngine"
Cohesion: 0.16
Nodes (11): DepthEngine, .arSession, .supportedFormats, .supportsFrontCameraWithLiDAR, ARConfiguration, ARWorldTrackingConfiguration, Bool, Int (+3 more)

### Community 27 - "Coordinate"
Cohesion: 0.26
Nodes (22): Coordinate, GeofenceTracker, .isFinished, aGatedOutFixDoesNotBreakTheArrivalStreak(), arrivalStreakResetsOnAMiss(), cardinalBearings(), fix(), geofenceGatesOnAccuracyAndSpeedExceptArrival() (+14 more)

### Community 28 - ".say"
Cohesion: 0.16
Nodes (4): .faceHeadTrackingEnabled, PendingRouteStart, Any, Route

### Community 29 - ".describe"
Cohesion: 0.13
Nodes (12): .namePeopleEnabled, OnDeviceHazards, OnDeviceVision, OnDeviceVLMClient, SceneContext, Bool, Data, Float (+4 more)

### Community 30 - "Decodable"
Cohesion: 0.10
Nodes (30): Decodable, Encodable, Candidate, Content, DescribeError, badResponse, .errorDescription, http (+22 more)

### Community 31 - "PhoneToWatch"
Cohesion: 0.16
Nodes (15): PhoneToWatch, nav, obstacle, status, Any, Int, WatchEnvelope, WatchToPhone (+7 more)

### Community 32 - "Module: ui-tests-build — Phone UI, XCUITests, XcodeGen build, CI"
Cohesion: 0.09
Nodes (23): docs/design.md — rules the UI code implements, .github/workflows/ci.yml, ios/CaneKit/UI/ArrivalCardView.swift, ios/CaneKit/UI/ContentView.swift, ios/CaneKit/UI/DestinationField.swift (Step 14), ios/CaneKit/UI/GuideCard.swift, ios/CaneKit/UI/HapticsCard.swift, ios/CaneKit/UI/HazardsCard.swift (Step 11) (+15 more)

### Community 33 - "CourseSmoother"
Cohesion: 0.19
Nodes (12): C, CourseSmoother, Double, Int, TimeInterval, aRealTurnShowsUpAfterTheBaseline(), at(), jitterOnAStraightWalkNeverLooksLikeAVeer() (+4 more)

### Community 34 - "DestinationField"
Cohesion: 0.11
Nodes (17): ColorSchemeContrast, Font, DestinationField, .body, .suggestionList, Bool, ScrollViewProxy, .body (+9 more)

### Community 35 - "HazardScanner"
Cohesion: 0.11
Nodes (18): HazardScanner, .signAllowedPhrases, HazardSource, ground, sign, vision, Any, Bool (+10 more)

### Community 36 - "2. Device test matrix"
Cohesion: 0.07
Nodes (30): 0. Read this before testing: facts from the code that change how you test, 1.0 The next 24 hours, 1.1 Automated (Mac, no phone): run on every change, 1.2 Bench (indoors, phone plugged in, ISR lobby), 1.3 Outdoor walks, 1.4 Log toolkit (Aritro), 1. Test levels, 2. Device test matrix (+22 more)

### Community 37 - ".scenePhaseChanged"
Cohesion: 0.11
Nodes (8): .bothCamerasEnabled, Settings, AVCaptureDevice, Bool, MainActor, ScenePhase, Task, URL

### Community 38 - "e2e.py"
Cohesion: 0.12
Nodes (33): check(), container(), densify(), dist(), fix_cadence(), hazards(), launch_and_wait_for_route(), load_waypoints() (+25 more)

### Community 39 - "FaceYawTracker"
Cohesion: 0.10
Nodes (31): FaceHeadPose, .readout, Double, FaceYawGeometry, FaceYawTracker, HeadYawChoice, HeadYawSelector, HeadYawSource (+23 more)

### Community 40 - "Ideas: retrofit smart-cane kit"
Cohesion: 0.08
Nodes (24): 0. One-liner, 1. Verdict, 2.1 A camera on a sweeping cane sees motion blur, 2.2 The cane tip already finds the ground, 2.3 "A to B in rain and dark" needs careful wording, 2. Three pushbacks on the original brief, 3. Form factor (Sagar), 4. Buy list (order Thursday night, Amazon only) (+16 more)

### Community 41 - "HazardTests.swift"
Cohesion: 0.21
Nodes (26): GroundHazardDetector, aCurbDownIsADropOff(), aCurbUpIsAStepUp(), aCurbYouWalkTowardStillConfirms(), aDeepDropIsReportedAtItsNearEdge(), aDeskIsNotTheGround(), aHazardNeedsThreeAgreeingFrames(), aHoleThatComesBackUpIsAPothole() (+18 more)

### Community 42 - "HapticLogic"
Cohesion: 0.10
Nodes (19): AVSpeechSynthesizer, Comparable, HapticLogic, Lane, center, left, .motorCode, right (+11 more)

### Community 43 - "String"
Cohesion: 0.19
Nodes (11): String, .sentenceCased, CloudSceneGate, Int, Set, Verdict, ConversationPrompt, ConversationResponseParser (+3 more)

### Community 44 - "TripTracker"
Cohesion: 0.20
Nodes (9): HKObserverQuery, Date, Double, Int, Never, Task, TimeInterval, Void (+1 more)

### Community 45 - "Sendable"
Cohesion: 0.10
Nodes (25): Equatable, Identifiable, RouteDestination, place, query, MicrophoneOwner, soundRecognition, voiceInput (+17 more)

### Community 46 - "Module `depth-haptics` — `ios/CaneKit/Depth/*.swift`, `ios/CaneKit/Haptics/HapticPlayer.swift`"
Cohesion: 0.25
Nodes (8): `ios/CaneKit/Depth/DepthEngine.swift`, `ios/CaneKit/Depth/DepthFrameProcessor.swift`, `ios/CaneKit/Depth/DualCameraSession.swift` — both cameras at once (Step 14, off by default), `ios/CaneKit/Depth/FrameReplay.swift` (Step 11, simulator-only), `ios/CaneKit/Depth/GroundSampler.swift` (Step 11), `ios/CaneKit/Depth/MeshClassifier.swift`, `ios/CaneKit/Haptics/HapticPlayer.swift`, Module `depth-haptics` — `ios/CaneKit/Depth/*.swift`, `ios/CaneKit/Haptics/HapticPlayer.swift`

### Community 47 - "Float"
Cohesion: 0.23
Nodes (5): Box, Config, GroundSample, ClosedRange, Float

### Community 48 - ".content"
Cohesion: 0.12
Nodes (12): App, CaneKitApp, .body, Scene, Scene, WatchApp, .body, WatchContentView (+4 more)

### Community 49 - "OpenCane design system"
Cohesion: 0.07
Nodes (29): 0. Who looks at the screen, and what that forces, 10. Open design gaps (code ≠ intent, not yet fixed), 1. Typography, 2. Colour tokens, 3. Spacing and radius, 4. Motion, 5.1 Speech priorities (`SpeechQueue`, AGENTS.md hard rule 8), 5.2 Obstacle cues (phone Taptic Engine, felt through the cane) (+21 more)

### Community 50 - "ConversationAction"
Cohesion: 0.12
Nodes (16): ConversationAction, answerHistory, answerStatus, inspectScene, recordMarker, silenceCane, speakImmediate, startRoute (+8 more)

### Community 51 - "CaneKit grip module firmware"
Cohesion: 0.29
Nodes (6): Build — Arduino IDE, Build — PlatformIO, CaneKit grip module firmware, Protocol (NUS, device name `CANE`), Testing with nRF Connect (Android / iOS), Wiring

### Community 52 - "LiveView"
Cohesion: 0.19
Nodes (11): CameraRate, DualCameraRotation, LiveView, cameraOff, hot, live, off, Bool (+3 more)

### Community 53 - "SessionRelay"
Cohesion: 0.26
Nodes (7): SessionRelay, Any, Bool, Error, Void, WCSession, WCSessionActivationState

### Community 54 - "`AppModel.swift` — engine owner, settings, cue router"
Cohesion: 0.12
Nodes (16): `AppModel.swift` — engine owner, settings, cue router, Auto-recenter — `autoRecenterIfWalkingStraight(_ fix: GeoFix)` (private, per GPS fix while navigating), Constants, Cue router — `handle(_ report: LaneReport)` (private, ~30 Hz, called from `depth.onReport`), Engine wiring (all `let`, created in the property initialisers except `describer`, `sceneContext` and `hazards`, which `init` builds), Hazards the maps do not know about (Step 11), Headphones / watch presence, Lifecycle (+8 more)

### Community 55 - "CKStatusPill"
Cohesion: 0.10
Nodes (20): GuideCard, .beaconWord, .body, .gpsTone, .gpsWord, .headSpoken, .headWord, Double (+12 more)

### Community 56 - ".model"
Cohesion: 0.16
Nodes (19): AppShortcut, AppShortcutsProvider, CustomLocalizedStringResourceConvertible, CaneKitShortcuts, .appShortcuts, IntentSupport, NavigateToCIFIntent, NextWaypointIntent (+11 more)

### Community 57 - "Module: logic — `ios/Logic` (SwiftPM package `CaneKitLogic`)"
Cohesion: 0.07
Nodes (29): `CampusPlaces.swift` — where "take me to …" goes (Step 13; `center` added in Step 14), `ConversationModels.swift` / `FastPathIntentClassifier.swift` / `ConversationPrompt.swift` — conversational assistant logic (Step 23), `CourseSmoother.swift` — direction of travel over ≥ 15 m, for veer decisions only (Step 11), Cross-module contracts (who uses what), `CueDecider.swift` — LaneReport → haptic cue with hysteresis and rate limiting (decides *what/when*; player is elsewhere), `CueProfile.swift` — cue verbosity level × place (Step 36, cue design v2), `DepthReadiness.swift` — bounded ARKit/LiDAR route-start interlock, `DestinationSuggestions.swift` — the destination search box's ranked list (Step 14) (+21 more)

### Community 58 - "Cane mount for the iPhone 17 Pro Max: design brief"
Cohesion: 0.12
Nodes (16): 0. Decisions, 10. Print settings, 11. Assembly and setting the angle, 12. Test protocol, 13. Open risks and follow-ups, 14. Sources, 1. Inputs and where they come from, 2. What the software needs from the mount (+8 more)

### Community 59 - "CodingKeys"
Cohesion: 0.18
Nodes (11): CodingKey, CodingKeys, bearingNextDeg, crossing, curved, id, lat, lon (+3 more)

### Community 60 - "ObstacleClass"
Cohesion: 0.11
Nodes (22): LaneReport, .head, MeshHit, MountTilt, ObstacleClass, ceiling, door, floor (+14 more)

### Community 61 - "CaneKit — strict build checklist"
Cohesion: 0.06
Nodes (35): Branch state (updated 2026-09-12 morning), CaneKit — strict build checklist, Cross-cutting, Cue design v2 — Steps 35–45 (approved 2026-09-12 evening; talk floor inserted as 37 the same night, later steps renumbered +1 — CHANGELOG entries before Step 37 use the old numbers), ElevenLabs setup (2 minutes, Aritro only — nobody else can do this), Gemini setup (optional, 3 minutes, Aritro only), Hardware, later that evening (Windows machine) — see CHANGELOG Step 25, Hardware tonight (Sagar, Windows machine) (+27 more)

### Community 62 - "GroundHazard"
Cohesion: 0.13
Nodes (14): GroundHazard, GroundHazardKind, dropOff, lowObstacle, pothole, .shortNoun, .spoken, stepUp (+6 more)

### Community 63 - "Module `watch-widget-shared`"
Cohesion: 0.14
Nodes (14): Cross-module map, `ios/CaneKit/Watch/PhoneWatchLink.swift` — phone side of WatchConnectivity, `ios/CaneKitWatch/CaneKitWatch.entitlements`, `ios/CaneKitWatch/WatchApp.swift` — watchOS entry point, `ios/CaneKitWatch/WatchContentView.swift` — the wrist screen, `ios/CaneKitWatch/WatchModel.swift` — watch side: haptics, commands, crown, keep-alive, `ios/CaneKitWatch/WatchTheme.swift` — watch design tokens (docs/design.md §6.6), `ios/CaneKitWidget/CaneKitWidgetBundle.swift` — widget extension entry (+6 more)

### Community 64 - "ObstacleNamer"
Cohesion: 0.20
Nodes (9): MeshClassifier, ARFrame, Bool, Float, ObstacleNamer, Bool, Float, LaneReport (+1 more)

### Community 65 - "HazardRecord"
Cohesion: 0.20
Nodes (10): HazardLog, .fileURL, Data, URL, HazardRecord, Data, Double, TimeInterval (+2 more)

### Community 66 - "MultiCamDepthFindings"
Cohesion: 0.10
Nodes (27): MultiCamDepthProbe, Result, .logFields, Any, AVCaptureDevice, MultiCamCost, MultiCamDepth, MultiCamDepthFindings (+19 more)

### Community 67 - "HeadNodDetector"
Cohesion: 0.12
Nodes (24): CMHeadphoneMotionManager, CMHeadphoneMotionManagerDelegate, ConnectionRelay, HeadPoseTracker, Bool, Double, Void, HeadNodDetector (+16 more)

### Community 68 - "DestinationSearch"
Cohesion: 0.07
Nodes (39): CompleterRelay, DestinationSearch, Bool, Error, Never, Sendable, Task, Void (+31 more)

### Community 69 - "FrameReplay"
Cohesion: 0.31
Nodes (7): Frame, FrameReplay, .currentName, State, Bool, Data, URL

### Community 70 - "OffCourseDetector"
Cohesion: 0.33
Nodes (9): OffCourseDetector, TimeInterval, aGpsGapForgetsTheHoldSoThereIsNoInstantVeer(), aStopMidDriftRestartsTheHold(), endEpisodeRequiresAFullHoldAgain(), gatedMomentsInsideGoodTrackingKeepTheHold(), offCourseNeedsThreeSecondsThenCoolsDown(), offCourseResetsWhenBackOnBearing() (+1 more)

### Community 72 - "SignPolicy"
Cohesion: 0.10
Nodes (25): GroundHazardPolicy, HazardWatchPolicy, SeenText, SignPolicy, Bool, Set, SignPhraseFilterTests, aCloserUpdateIsNotADuplicate() (+17 more)

### Community 73 - "LaunchMode"
Cohesion: 0.18
Nodes (10): LaunchMode, normal, recovered, LaunchRecovery, Bool, Double, aCompletedPreviousLaunchStartsNormally(), anIncompletePreviousLaunchRecovers() (+2 more)

### Community 74 - "Module `navigation-trip` — GPS, waypoint engine, turn settling, route sources, trip log/tracker, Live Activity"
Cohesion: 0.15
Nodes (13): Data flow (who calls whom), `docs/route_isr_cif.md`, `ios/CaneKit/Navigation/DestinationSearch.swift` (Step 14), `ios/CaneKit/Navigation/LocationService.swift`, `ios/CaneKit/Navigation/NavigationEngine.swift`, `ios/CaneKit/Navigation/RouteSource.swift`, `ios/CaneKit/Resources/route_isr_cif.json` — schema and waypoints, `ios/CaneKit/Trip/HazardLog.swift` (Step 11) (+5 more)

### Community 75 - "CaneKit iPhone app target"
Cohesion: 0.32
Nodes (8): logic-tests job (Linux, swift:6.2), Background modes (audio, location; workout-processing, mindfulness), CaneKit iPhone app target, CaneKitLogic SwiftPM package, CaneKitUITests target, CaneKitWatch target, UIFileSharingEnabled for trip logs and hazard map, Privacy purpose strings

### Community 76 - "Module: speech-audio-scene (`ios/CaneKit/Speech`, `ios/CaneKit/Audio`, `ios/CaneKit/Scene`)"
Cohesion: 0.11
Nodes (18): Constants, Functions, `ios/CaneKit/Audio/AudioRouteMonitor.swift`, `ios/CaneKit/Audio/BeaconEngine.swift`, `ios/CaneKit/Audio/HeadPoseTracker.swift`, `ios/CaneKit/Audio/SoundWatcher.swift` — optional microphone sound recognition, `ios/CaneKit/Scene/CameraControlInteraction.swift`, `ios/CaneKit/Scene/HazardScanner.swift` (Step 11) (+10 more)

### Community 77 - ".directions"
Cohesion: 0.24
Nodes (10): CLLocation, CLLocationCoordinate2D, PlannedRoute, RouteSource, Double, .current, RouteBuilder, RouteStepInput (+2 more)

### Community 78 - "View"
Cohesion: 0.10
Nodes (30): ArrivalCardView, .body, Double, TimeInterval, .page, dismissKeyboard(), GuidePage, .body (+22 more)

### Community 80 - "LaneGrid"
Cohesion: 0.32
Nodes (5): LaneGrid, LaneMath, Float, Int, .torso

### Community 81 - "Team handoff: read this first after you pull"
Cohesion: 0.10
Nodes (21): 0. Start here (5 minutes), 10.1 Read order, 10.2 Measure first, 10.3 The per-step bar, 10.4 Traps that already produced a false green or a lost hour, 10. How an agent resumes (and how we work), 11. Known risks going into the walk, 1. The one-paragraph version (+13 more)

### Community 82 - "pitch_model.py"
Cohesion: 0.27
Nodes (11): clearance(), convex_hull(), ground_hit(), outside(), pitch_table(), Where the cane shaft (toward the tip) appears in the wide camera's portrait…, z-depth and range where a ray alpha deg above the optical axis meets the ground., Smallest gap (mm) between the cradle box and the cane / collar / ear over phi =… (+3 more)

### Community 83 - "SpeechResume"
Cohesion: 0.16
Nodes (8): Character, SpeechResume, Bool, Int, Set, TimeInterval, Substring, UInt16

### Community 84 - "CameraControlInteraction"
Cohesion: 0.29
Nodes (7): AVCaptureEventInteraction, CameraControlInteraction, Coordinator, Context, Coordinator, UIView, Void

### Community 85 - "CaneKit changelog"
Cohesion: 0.04
Nodes (46): Antigravity review of Step 16 (7 findings — 4 fixed, 1 instrumented, 2 rejected with evidence), CaneKit changelog, Fix — Both cameras: the back feed was sideways again; rotation is now chosen per camera (Sat Sep 12), Found broken, fixed, New, all off by default, Step 0 — phone-only reset (Thu Sep 10), Step 10 — Two adversarial review rounds, AirPods/Watch presence, XCUITests (Fri Sep 11, pre-device), Step 11 — Hazards the maps don't know, on-device vision, stress harness (Fri Sep 11, pre-device) (+38 more)

### Community 86 - ".session"
Cohesion: 0.26
Nodes (6): ARCamera, ARAnchor, ARFrame, ARSession, Error, Task

### Community 87 - "AGENTS.md — rules for anyone (human or AI) editing OpenCane / CaneKit"
Cohesion: 0.22
Nodes (9): AGENTS.md — rules for anyone (human or AI) editing OpenCane / CaneKit, Commands, Hardware / OpenSCAD — traps that have already cost us a night, How we engineer (the bar for every change, human or AI), Layout, The name split — OpenCane to a human, CaneKit in the code (deliberate, do not "fix"), Things that look wrong but are deliberate, What this is (+1 more)

### Community 88 - "Every doc"
Cohesion: 0.22
Nodes (9): `docs/`, Docs index, Every doc, Generated, Hardware (the printed mount), iOS app, Outside Markdown, Repo root (+1 more)

### Community 89 - "Route: ISR Townsend Hall to CIF (UIUC, Urbana IL)"
Cohesion: 0.25
Nodes (8): Evidence per waypoint (OSM), Route: ISR Townsend Hall to CIF (UIUC, Urbana IL), Sources, To re-record on the Friday walk, Waypoints (from the JSON), What the app does at each waypoint, Where Townsend Hall is, and which door is "the Townsend exit", Why the file looks the way it does

### Community 90 - "SoundRecognitionGuard"
Cohesion: 0.11
Nodes (27): SoundInputQuality, hfp, unavailable, usable, SoundRecognitionDecision, cancelPendingStart, continueRunning, ignored (+19 more)

### Community 91 - "OpenCane: the iOS app for the phone-only smart cane"
Cohesion: 0.22
Nodes (9): 1. Day-0 checklist, 2. Verified spec deviations (don't "fix" these back), 3. Build, install, launch, 4. Secrets and permissions, 5. Testing, 6. Gotchas, Automation environment variables, Layout (+1 more)

### Community 92 - "CaneKit code reference"
Cohesion: 0.25
Nodes (8): `App/HandsFreeIntents.swift` — Siri status, questions, voice switches (Step 16), `AppIntents.swift` — Action button / Siri entry points, CaneKit code reference, `CaneKitApp.swift` — app entry point, Contents, Data flow, How to keep this file true, Module `app-core` — `ios/CaneKit/App/`

### Community 93 - "Team brief: OpenCane / CaneKit at HEAD `076fcaa` (Sat 2026-09-12 evening)"
Cohesion: 0.20
Nodes (10): Aarav (walker), Historical: status as written earlier on Sat 2026-09-12 (after Step 28), If you change code, Installing on the phone (Aritro), Known quirks, Sagar and Tommy (hardware), Setup checklist (do these in order), Status right now — read this first (+2 more)

### Community 94 - "RuntimeRelay"
Cohesion: 0.14
Nodes (11): HKWorkoutSessionState, RuntimeEvent, ended, expiring, started, RuntimeRelay, Date, Error (+3 more)

### Community 95 - "AirPods + Apple Watch — setup and what the app does about them"
Cohesion: 0.33
Nodes (6): AirPods + Apple Watch — setup and what the app does about them, AirPods (beacon, speech, head tracking), Apple Watch (wrist taps, Repeat / Next / Describe / Recenter), If something is off, On-device vision (no key, no network), Untethered demo (phone only, no laptop)

### Community 96 - "OpenCane: a smart-cane kit that clips an iPhone onto the cane you already own"
Cohesion: 0.33
Nodes (6): Hardware, Links, OpenCane: a smart-cane kit that clips an iPhone onto the cane you already own, Quick start, Repo map, The demo

### Community 97 - "SoundAlertsTests.swift"
Cohesion: 0.10
Nodes (25): SoundAlertPolicy, Double, alternatingKindsDoNotAccumulate(), anEmergencySirenIsNotShadowedByTheAmbientTrafficClass(), aNonFiniteConfidenceIsIgnoredNotRanked(), aSirenJustUnderTheNewGateIsSilent(), aSubGateSirenDoesNotDisplaceAConfidentVehicle(), aWindowWithNoDangerLabelsSelectsNothing() (+17 more)

### Community 98 - "hardware/: phone-to-cane mount"
Cohesion: 0.40
Nodes (5): Bill of materials, Files, hardware/: phone-to-cane mount, Quick start (Sagar), Who does what

### Community 99 - "streetview/README.md"
Cohesion: 0.50
Nodes (3): Step 12 findings (2026-09-11, afternoon) and fixes, Street View route frames (local test input), What the first 2026-09-11 run showed

### Community 100 - "ConversationLogicTests"
Cohesion: 0.15
Nodes (5): FastPathIntentClassifier, Bool, ConversationLogicTests, nodToTalkSwitchesByVoice(), nodToTalkWithoutAVerbIsNotASetting()

### Community 101 - "DepthSnapshot"
Cohesion: 0.13
Nodes (27): DepthSnapshot, .isEmpty, Bool, ClosedRange, Float, Int, UInt8, UnsafeRawPointer (+19 more)

### Community 103 - "CampusPlacesTests.swift"
Cohesion: 0.16
Nodes (17): DestinationPicker, PlaceCandidate, Double, Int, WalkingIntro, .voiceOverLabel, campusAliasesIgnoreCasePunctuationAndThe(), east() (+9 more)

### Community 106 - "CueDecider"
Cohesion: 0.26
Nodes (20): CueDecider, Bool, LaneReport, centerApproachFiresThenUpdatesDistance(), centerDistanceIsClampedToNearFloor(), centerLoopIsExemptFromTheFloor(), cueChangeNeeds400ms(), headBeatsCenterBeatsSides() (+12 more)

### Community 107 - "GeoFix"
Cohesion: 0.14
Nodes (11): GeoFix, GeoMath, NavEvent, reached, Bool, Double, Int, everyCampusPlaceIsOnCampusAndAliasesAreUnique() (+3 more)

### Community 108 - "SightingKind"
Cohesion: 0.09
Nodes (25): Group, Group, PeopleAhead, SightingBearing, ahead, left, .order, right (+17 more)

### Community 110 - ".handle"
Cohesion: 0.24
Nodes (4): CGFloat, Data, LaneReport, TimeInterval

### Community 111 - "CueKind"
Cohesion: 0.11
Nodes (15): PhoneWatchLink, Int, TimeInterval, CueKind, center, clear, head, left (+7 more)

### Community 112 - "SceneVocabulary"
Cohesion: 0.10
Nodes (24): table, Group, SceneVocabulary, Bool, Float, Int, Set, groundedNumbersPredicateIsShared() (+16 more)

### Community 113 - "StatusFacts"
Cohesion: 0.15
Nodes (21): StatusFacts, StatusSummary, Bool, Double, Int, aRunningDepthSessionWithNoFramesIsNotReportedAsOn(), everyStatusClauseIsOneFinishedSentence(), gpsClauseSeparatesDeniedFromNoFix() (+13 more)

### Community 114 - "TorchSwitch"
Cohesion: 0.15
Nodes (13): Configuration, Outcome, changedByDevice, confirmed, failed, none, .queueSeconds, .spokenLine (+5 more)

### Community 115 - "PeopleAheadTests.swift"
Cohesion: 0.15
Nodes (26): NormalizedBox, .midX, .midY, Sighting, animalAloneIsSpoken(), animalsComeAfterPeople(), aRealDistanceIsNeverDropped(), groupWithoutDepthSortsLast() (+18 more)

### Community 116 - "ConversationCoordinator"
Cohesion: 0.18
Nodes (8): ConversationCoordinator, .markers, AppModel, Bool, PostStore, .fileURL, Bool, URL

### Community 117 - "SoundWatcher"
Cohesion: 0.22
Nodes (10): SoundWatcher, .ownsMicrophoneSession, Any, AVAudioSession, Bool, Int, Never, NSObjectProtocol (+2 more)

### Community 118 - "DangerSound"
Cohesion: 0.10
Nodes (22): CaseIterable, DangerSound, horn, .minimumConfidence, .repeatInterval, .requiredWindows, .selectionRank, siren (+14 more)

### Community 119 - "DepthReadiness"
Cohesion: 0.21
Nodes (14): Configuration, DepthReadiness, DepthReadinessState, idle, ready, timedOut, warming, Bool (+6 more)

### Community 120 - "CueRules"
Cohesion: 0.17
Nodes (8): .cueRules, CueRules, .allowedSignPhrases, .namesLimitLine, Bool, Float, Set, CueProfileTests

### Community 121 - "Printing the screwless mount — operator runbook"
Cohesion: 0.09
Nodes (20): Calibration, Fitting it together, Getting files onto a machine, Print list — read this if you are standing at a printer, Print order, Printing the screwless mount — operator runbook, Reading the bore rings, Reading the dovetail pair (+12 more)

### Community 122 - "RootTab"
Cohesion: 0.14
Nodes (15): Animation, ContentView, .body, TimeInterval, CKTabBar, .body, RootTab, guide (+7 more)

### Community 123 - "SensorProbe"
Cohesion: 0.19
Nodes (9): SensorProbe, .applicationStateName, .isEnabled, .thermalName, Any, ARConfiguration, ARWorldTrackingConfiguration, AVAudioSession (+1 more)

### Community 124 - "DualCameraSession"
Cohesion: 0.15
Nodes (14): AVCaptureDeviceInput, AVCaptureMultiCamSession, CaptureHandoff, DualCameraSession, .diagnostics, Any, AVCaptureDevice, AVCaptureSession (+6 more)

### Community 125 - "SwiftUI"
Cohesion: 0.09
Nodes (12): ActivityKit, ARKit, AVKit, CoreImage, CoreMotion, CoreVideo, ImageIO, SceneKit (+4 more)

### Community 126 - ".resumeOffset"
Cohesion: 0.24
Nodes (3): Double, SpeechResumeTests, Int

### Community 127 - "Text"
Cohesion: 0.38
Nodes (9): Binding, .body, HazardsCard, .body, .bothCameras, .frontCameraReadout, .liveView, .soundStatus (+1 more)

### Community 128 - "TripLogger"
Cohesion: 0.18
Nodes (11): FileHandle, Double, Float, Int, LaneReport, Never, Task, TimeInterval (+3 more)

### Community 129 - "ElevenLabsVoice"
Cohesion: 0.11
Nodes (19): Error, RouteError, destinationNotFound, .errorDescription, missingBundledRoute, noRoute, ElevenLabsVoice, Failure (+11 more)

### Community 130 - "CallbackBox"
Cohesion: 0.19
Nodes (9): AVSpeechSynthesisVoice, AVSpeechSynthesizerDelegate, AVSpeechUtterance, MKPolyline, .coordinates, CallbackBox, DelegateRelay, NSRange (+1 more)

### Community 131 - "ProbeSessionWatcher"
Cohesion: 0.21
Nodes (8): Counts, ProbeSessionWatcher, ARAnchor, ARFrame, ARSession, Double, Error, Float

### Community 132 - "sign_probe.swift"
Cohesion: 0.12
Nodes (18): AppKit, CGImage, CGRect, CoreText, far, composite(), Entry, metres() (+10 more)

### Community 133 - ".probeCapture"
Cohesion: 0.23
Nodes (6): ProbeCaptureCounter, ProbeCaptureNotes, AVCaptureDevice, AVCaptureSession, Int, NSObjectProtocol

### Community 134 - "CloudSceneGateTests.swift"
Cohesion: 0.25
Nodes (13): clockFaceDirectionsAreRefused(), countsOfHazardsLoseTheirNumeral(), distancesMustBeTheLidarNumber(), namesTheCameraDidReadSurvive(), nothingTrustworthyLeftReturnsNil(), numeralsThatAreNotCountsAreNotSnippedOut(), ordinaryDescriptionsReachTheWalkerUntouched(), paceAndBlockEstimatesAreRefusedNotMangled() (+5 more)

### Community 135 - "SpeechLoadPolicy"
Cohesion: 0.28
Nodes (5): Configuration, SpeechLoadPolicy, Bool, TimeInterval, SpeechLoadPolicyTests

### Community 136 - "cue_audit.py"
Cohesion: 0.22
Nodes (14): audit(), cross_band_short_pauses(), human(), load(), main(), pull_latest(), Path, The whole report as a dict (see the module docstring for what each part means). (+6 more)

### Community 137 - "DepthFrameContinuity"
Cohesion: 0.57
Nodes (4): DepthFrameContinuity, Int, publishedFrameContinuityHonorsTransitionBoundary(), publishedFrameContinuityRejectsGapsAndRecovers()

### Community 138 - "DualCameraFrameRelay"
Cohesion: 0.19
Nodes (11): DualCameraFrameRelay, .frameCount, .frameSize, .isPortrait, State, AVCaptureConnection, AVCaptureOutput, CMSampleBuffer (+3 more)

### Community 139 - "Codable"
Cohesion: 0.35
Nodes (9): Codable, ConversationContext, HazardFact, ObstacleFact, Bool, Double, Float, TimeInterval (+1 more)

### Community 140 - "OpenCane cue design v2: what blind travellers need, and how to make the cane calmer"
Cohesion: 0.14
Nodes (14): 1. What blind travellers actually need, 2. Where OpenCane violates them today, 3.1 Design rules, 3.2 Head height: much calmer, never suppressed, 3.3 Everything else, by verbosity level, 3.4 Speech budget (`SpeechBudget`, generalising `SpeechLoadPolicy`), 3.5 Indoor and outdoor, 3.6 What the cane tip already covers, so we drop it (+6 more)

### Community 141 - "LiveViewTests.swift"
Cohesion: 0.18
Nodes (14): backCameraIsPortraitUpWhateverThePhoneReads(), bothCamerasAreOffInTheBackground(), bothCamerasAreRefusedWhileARouteIsGuiding(), bothCamerasExplainTheRefusalForTheWholeRoute(), bothCamerasGoLiveWhenNothingIsWalking(), bothCamerasOffWithTheSwitchOff(), bothCamerasRefuseWithoutMultiCamSupport(), frontCameraIsPortraitUpWhateverThePhoneReads() (+6 more)

### Community 142 - "Testing"
Cohesion: 0.13
Nodes (10): Any, Double, Set, TripLogRecord, Data, routeFileDecodesSnakeCaseSchema(), shippedRouteFileIsConsistent(), fieldsNeverOverwriteTheRecordTimeOrKind() (+2 more)

### Community 143 - ".queue"
Cohesion: 0.21
Nodes (8): Bool, Int, VoicePrefetch, aCancelledWarmUpResumesInsteadOfStartingOver(), aBadKeyStopsThePrefetchInsteadOfRepeatingItselfTwentyTimes(), prefetchDropsRepeatsAndAlreadyCachedLinesButKeepsTheRest(), prefetchIgnoresBlankLines(), prefetchKeepsSpeakingOrderSoTheFirstCueIsReadyFirst()

### Community 144 - "SoundAnalysisPump"
Cohesion: 0.24
Nodes (8): AVAudioFramePosition, DispatchQueue, SoundAnalysisPump, SoundBufferBox, AVAudioFormat, AVAudioNode, AVAudioPCMBuffer, SNAudioStreamAnalyzer

### Community 145 - "DualPreviewHostView"
Cohesion: 0.26
Nodes (6): BothCamerasView, DualPreviewHostView, AVSampleBufferDisplayLayer, Context, UIView, UIViewRepresentable

### Community 146 - "LiveCameraView"
Cohesion: 0.17
Nodes (11): ARSCNView, ARSCNViewDelegate, Coordinator, LiveCameraView, ARAnchor, ARSession, Context, Coordinator (+3 more)

### Community 147 - "ios/CaneKit/UI/Theme.swift"
Cohesion: 0.20
Nodes (10): `enum CKColor` (namespace, no cases), `enum CKFont`, `enum CKMetrics`, `enum CKRadius`, `enum CKSpacing` (4 pt base), ios/CaneKit/UI/Theme.swift, `struct CKBigButton: View`, `struct CKBigButtonStyle: ButtonStyle` (+2 more)

### Community 148 - "Driving OpenCane without looking at the screen"
Cohesion: 0.20
Nodes (9): 1. The ten spoken commands, 2. What the status answer means, 3. Putting OpenCane on the Action button, 4. What does *not* work, and why, 5. Asking a question — what it will and will not do, 6. Still needs the screen, Driving OpenCane without looking at the screen, ⚠ The Action button and the lock screen (+1 more)

### Community 149 - "SoundResultsRelay"
Cohesion: 0.22
Nodes (7): SoundResultsRelay, Double, Error, Void, SNRequest, SNResult, SNResultsObserving

### Community 150 - "QuestionPromptTests.swift"
Cohesion: 0.27
Nodes (6): QuestionPrompt, anOverlongQuestionIsCapped(), aQuestionWithNoLettersIsNotAQuestion(), askingForNumbersOrReassuranceIsStillRefused(), cleanCollapsesWhitespaceAndRemovesQuotes(), questionPromptCarriesTheQuestionAndTheBans()

### Community 151 - "stl_tools.js"
Cohesion: 0.40
Nodes (9): base(), [cmd, ...args], fs, gsupport(), overhang(), readTris(), shells(), triVol() (+1 more)

### Community 152 - "OpenCane Speech Load Design"
Cohesion: 0.22
Nodes (8): Content selection, Design, OpenCane Speech Load Design, Pacing, Problem, Research conclusion, Safety boundaries, Testing

### Community 153 - ".session"
Cohesion: 0.28
Nodes (5): ARFrame, ARSession, Error, LaneReport, SIMD3

### Community 154 - "Global Constraints"
Cohesion: 0.25
Nodes (7): Global Constraints, OpenCane Speech Load Implementation Plan, Task 1: Add the pure optional-speech admission policy, Task 2: Apply the policy at the speech boundary, Task 3: Make scene narration select useful facts, Task 4: Fix the known persistence honesty bug, Task 5: Safety regression and independent review

### Community 155 - "ConversationTurn"
Cohesion: 0.33
Nodes (4): ConversationHistory, ConversationTurn, Int, UUID

### Community 156 - "SoundRecognitionFailure"
Cohesion: 0.25
Nodes (8): SoundRecognitionFailure, analyzerFailed, inputRouteDegraded, inputUnavailable, interrupted, outputRouteChanged, permissionDenied, permissionRevoked

### Community 157 - ".insetRect"
Cohesion: 0.50
Nodes (4): BothCamerasLayout, Double, bothCamerasInsetIsClampedInAShortBox(), bothCamerasInsetSitsInTheBottomTrailingCorner()

### Community 158 - "3D print files — the screwless phone mount"
Cohesion: 0.29
Nodes (6): 3D print files — the screwless phone mount, Files, Not settled yet, Print in this order, Putting it together, Reading step 1

### Community 159 - "CueLevel"
Cohesion: 0.15
Nodes (11): CueLevel, detailed, quiet, .spokenLine, standard, .title, CuePlace, indoors (+3 more)

### Community 160 - "WorkoutRelay"
Cohesion: 0.20
Nodes (9): HKWorkoutSessionDelegate, Any, Bool, Void, WCSession, WCSessionActivationState, WatchSessionRelay, WorkoutRelay (+1 more)

### Community 161 - "SceneDescriber"
Cohesion: 0.38
Nodes (5): SceneDescriber, Bool, Data, Int, Void

### Community 162 - "appicon.py"
Cohesion: 0.47
Nodes (5): cap(), OpenCane icon v2 — 'White Cane'. A real mobility cane on the dark field: black…, Circle end-cap of diameter d with vertical gradient., seg(), vgrad()

### Community 163 - "ProbeIntrospection"
Cohesion: 0.60
Nodes (4): AnyClass, ProbeIntrospection, .framePixelBufferProperties, .frameProperties

### Community 164 - "Auditory load: what the research says, what OpenCane does"
Cohesion: 0.50
Nodes (4): Auditory load: what the research says, what OpenCane does, Open questions (for walks with a blind / O&M-trained tester, not guesses), What OpenCane already does about each point, What the literature says

### Community 165 - "TileLevel"
Cohesion: 0.40
Nodes (5): TileLevel, clear, near, noData, urgent

### Community 166 - "MicrophoneSessionResult"
Cohesion: 0.20
Nodes (5): MicrophoneSessionResult, failed, granted, revertedRouteChanged, AVAudioSession

### Community 171 - "CampusDestination"
Cohesion: 0.20
Nodes (10): CampusDestination, arc, cif, grainger, illiniUnion, isr, mainLibrary, siebel (+2 more)

### Community 172 - "ConversationTool"
Cohesion: 0.20
Nodes (9): ConversationTool, dropMarker, navigateTo, queryHistory, queryScene, queryStatus, setCaneSilenced, setSetting (+1 more)

### Community 173 - ".publishReadiness"
Cohesion: 0.25
Nodes (3): Double, TimeInterval, Int

### Community 174 - ".decide"
Cohesion: 0.22
Nodes (8): FaceTrackingChange, apply, refusedRoute, refusedRouteStart, faceTrackingChangeAppliesWhenNoRouteIsActive(), faceTrackingChangeIsRefusedWhileARouteIsGuiding(), faceTrackingChangeIsRefusedWhileARouteIsStarting(), faceTrackingRouteRefusalTakesPrecedence()

### Community 175 - "PlayerRelay"
Cohesion: 0.29
Nodes (5): AVAudioPlayer, AVAudioPlayerDelegate, PlayerRelay, Error, Void

### Community 176 - "ProbeOutputDelegate"
Cohesion: 0.25
Nodes (6): AVCaptureVideoDataOutputSampleBufferDelegate, ProbeOutputDelegate, AVCaptureConnection, AVCaptureOutput, CMSampleBuffer, Void

### Community 177 - "StatusAspect"
Cohesion: 0.29
Nodes (7): StatusAspect, all, battery, gps, haptics, headphones, route

### Community 178 - "VoiceInputState"
Cohesion: 0.33
Nodes (6): VoiceInputState, error, idle, listening, processing, recognizing

### Community 179 - "BothCameras"
Cohesion: 0.40
Nodes (5): BothCameras, blockedByRoute, live, off, unsupported

## Ambiguous Edges - Review These
- `AGENTS.md` → `drafts/README.md`  [AMBIGUOUS]
  ios/drafts/README.md · relation: conceptually_related_to

## Knowledge Gaps
- **786 isolated node(s):** `cif`, `isr`, `grainger`, `illiniUnion`, `siebel` (+781 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **7 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **What is the exact relationship between `AGENTS.md` and `drafts/README.md`?**
  _Edge tagged AMBIGUOUS (relation: conceptually_related_to) - confidence is low._
- **Why does `String` connect `String` to `AppModel`, `Foundation`, `CaneKitUITests`, `DepthEngine`, `NavSupportTests.swift`, `BeaconEngine`, `HandsFreeOption`, `CaneBLE`, `LiveActivityController`, `Waypoint`, `CKBigButton`, `HapticPlayer`, `LaneTile`, `NavigationEngine`, `VLMClient`, `VoiceInputEngine`, `AppModel`, `WKBigButton`, `NavLiveActivity`, `WatchModel`, `SpeechQueue`, `DepthEngine`, `.say`, `.describe`, `Decodable`, `PhoneToWatch`, `DestinationField`, `HazardScanner`, `.scenePhaseChanged`, `FaceYawTracker`, `HapticLogic`, `TripTracker`, `Sendable`, `Float`, `ConversationAction`, `SessionRelay`, `CKStatusPill`, `.model`, `CodingKeys`, `ObstacleClass`, `GroundHazard`, `ObstacleNamer`, `HazardRecord`, `MultiCamDepthFindings`, `HeadNodDetector`, `DestinationSearch`, `FrameReplay`, `SignPolicy`, `LaunchMode`, `.directions`, `View`, `SpeechResume`, `SoundRecognitionGuard`, `RuntimeRelay`, `SoundAlertsTests.swift`, `ConversationLogicTests`, `CampusPlacesTests.swift`, `SightingKind`, `.handle`, `CueKind`, `SceneVocabulary`, `StatusFacts`, `TorchSwitch`, `PeopleAheadTests.swift`, `ConversationCoordinator`, `SoundWatcher`, `DangerSound`, `DepthReadiness`, `CueRules`, `RootTab`, `SensorProbe`, `DualCameraSession`, `.resumeOffset`, `Text`, `TripLogger`, `ElevenLabsVoice`, `ProbeSessionWatcher`, `sign_probe.swift`, `.probeCapture`, `CloudSceneGateTests.swift`, `DualCameraFrameRelay`, `Codable`, `Testing`, `.queue`, `SoundResultsRelay`, `QuestionPromptTests.swift`, `ConversationTurn`, `SoundRecognitionFailure`, `CueLevel`, `WorkoutRelay`, `SceneDescriber`, `ProbeIntrospection`, `MicrophoneSessionResult`, `CampusDestination`, `ConversationTool`, `StatusAspect`, `VoiceInputState`, `.portDescription`?**
  _High betweenness centrality (0.480) - this node is a cross-community bridge._
- **Why does `AppModel` connect `AppModel` to `TripLogger`, `Foundation`, `NavSupportTests.swift`, `BeaconEngine`, `LiveActivityController`, `docs/README.md`, `HapticPlayer`, `NavigationEngine`, `VoiceInputEngine`, `SpeechQueue`, `DepthEngine`, `ConversationTurn`, `.say`, `.describe`, `CueLevel`, `HazardScanner`, `.scenePhaseChanged`, `FaceYawTracker`, `String`, `TripTracker`, `ObstacleNamer`, `HazardRecord`, `HeadNodDetector`, `SignPolicy`, `CueDecider`, `.wireNavigation`, `.handle`, `CueKind`, `TorchSwitch`, `ConversationCoordinator`, `SoundWatcher`, `CueRules`, `DualCameraSession`?**
  _High betweenness centrality (0.189) - this node is a cross-community bridge._
- **Why does `CaneKit code reference` connect `CaneKit code reference` to `Module: ui-tests-build — Phone UI, XCUITests, XcodeGen build, CI`, `Module `navigation-trip` — GPS, waypoint engine, turn settling, route sources, trip log/tracker, Live Activity`, `docs/README.md`, `Module: speech-audio-scene (`ios/CaneKit/Speech`, `ios/CaneKit/Audio`, `ios/CaneKit/Scene`)`, `Module `depth-haptics` — `ios/CaneKit/Depth/*.swift`, `ios/CaneKit/Haptics/HapticPlayer.swift``, `Module: logic — `ios/Logic` (SwiftPM package `CaneKitLogic`)`, `Module `watch-widget-shared``?**
  _High betweenness centrality (0.066) - this node is a cross-community bridge._
- **Are the 20 inferred relationships involving `AppModel` (e.g. with `AudioRouteMonitor` and `BeaconEngine`) actually correct?**
  _`AppModel` has 20 INFERRED edges - model-reasoned connections that need verification._
- **What connects `cif`, `isr`, `grainger` to the rest of the system?**
  _786 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `AppModel` be split into smaller, more focused modules?**
  _Cohesion score 0.0858974358974359 - nodes in this community are weakly interconnected._