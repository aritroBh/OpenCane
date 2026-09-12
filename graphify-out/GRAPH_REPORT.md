# Graph Report - 54FoundersHack  (2026-09-12)

## Corpus Check
- 184 files · ~389,827 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 3374 nodes · 7882 edges · 171 communities (164 shown, 7 thin omitted)
- Extraction: 89% EXTRACTED · 11% INFERRED · 0% AMBIGUOUS · INFERRED: 903 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `d1238ebf`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- AppModel
- Foundation
- CaneKitUITests
- DepthEngine
- NavSupportTests.swift
- BeaconEngine
- CueDecider
- HandsFreeOption
- CaneBLE
- .wireNavigation
- Waypoint
- docs/README.md
- CKBigButtonStyle
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
- LaneCell
- .describe
- Decodable
- NavCue
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
- Config
- WatchApp
- OpenCane design system
- Codable
- CaneKit grip module firmware
- .state
- PhoneWatchLink
- `AppModel.swift` — engine owner, settings, cue router
- CKStatusPill
- SensorProbe.swift
- Module: logic — `ios/Logic` (SwiftPM package `CaneKitLogic`)
- Cane mount for the iPhone 17 Pro Max: design brief
- CodingKeys
- LaneReport
- CaneKit — strict build checklist
- GroundHazard
- Module `watch-widget-shared`
- ObstacleClass
- HazardRecord
- MultiCamDepthFindings
- HeadNodDetector
- DestinationSuggestion
- FrameReplay
- OffCourseDetector
- Package.swift
- SignPolicy
- Bool
- Module `navigation-trip` — GPS, waypoint engine, turn settling, route sources, trip log/tracker, Live Activity
- CaneKit iPhone app target
- Module: speech-audio-scene (`ios/CaneKit/Speech`, `ios/CaneKit/Audio`, `ios/CaneKit/Scene`)
- .buildRoute
- View
- LaneGrid
- Team handoff: read this first after you pull
- pitch_model.py
- HazardWatchPolicy
- CameraControlInteraction
- CaneKit changelog
- .session
- AGENTS.md — rules for anyone (human or AI) editing OpenCane / CaneKit
- Every doc
- Route: ISR Townsend Hall to CIF (UIUC, Urbana IL)
- SoundRecognitionGuard
- OpenCane: the iOS app for the phone-only smart cane
- CaneKit code reference
- Team brief: OpenCane / CaneKit, merged safety build (Sat 2026-09-12)
- NSObject
- AirPods + Apple Watch — setup and what the app does about them
- OpenCane: a smart-cane kit that clips an iPhone onto the cane you already own
- SoundAlertsTests.swift
- hardware/: phone-to-cane mount
- streetview/README.md
- ConversationTool
- DepthSnapshot
- cad/README.md
- CampusPlacesTests.swift
- test.sh
- Swift 6 approachable-concurrency build settings
- VLMProvider
- GeoFix
- SightingKind
- StraightWalkDetector
- .handle
- NavigationEngine.swift
- SceneVocabularyTests.swift
- StatusFacts
- TorchSwitch
- PeopleAheadTests.swift
- ConversationTurn
- SoundWatcher
- DangerSound
- DepthReadiness
- SpokenPhrases
- Printing the screwless mount — operator runbook
- RootTab
- SensorProbe
- DualCameraSession
- CaneKitLogic
- DestinationSearch
- Text
- LocationService
- ElevenLabsVoice
- CompletionLine
- ProbeSessionWatcher
- sign_probe.swift
- .probeCapture
- CloudSceneGateTests.swift
- SpeechLoadPolicy
- VLMCodecTests.swift
- DepthFrameContinuity
- DualCameraFrameRelay
- .describe
- VLMError
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
- ArrivalCardView
- SoundRecognitionFailure
- .insetRect
- 3D print files — the screwless phone mount
- CampusPlace
- FallbackVLMClient
- WatchModel.swift
- appicon.py
- ProbeIntrospection
- Auditory load: what the research says, what OpenCane does
- TileLevel
- vision_probe.swift
- Bolt's Journal - Critical Learnings

## God Nodes (most connected - your core abstractions)
1. `AppModel` - 123 edges
2. `CaneKitLogic` - 74 edges
3. `Coordinate` - 70 edges
4. `SpeechQueue` - 62 edges
5. `DepthFrameProcessor` - 46 edges
6. `DepthEngine` - 44 edges
7. `GroundHazardDetector` - 39 edges
8. `CaneKit changelog` - 39 edges
9. `SoundWatcher` - 36 edges
10. `HapticPlayer` - 35 edges

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

## Communities (171 total, 7 thin omitted)

### Community 0 - "AppModel"
Cohesion: 0.16
Nodes (14): AppModel, .extendedRange, .hapticsEnabled, .mirrorLeftRight, .portraitMode, .speechEnabled, .urgentDistance, .warnDistance (+6 more)

### Community 1 - "Foundation"
Cohesion: 0.12
Nodes (9): AVFoundation, CoreBluetooth, CoreHaptics, CoreLocation, CoreMedia, Foundation, Observation, SoundAnalysis (+1 more)

### Community 2 - "CaneKitUITests"
Cohesion: 0.08
Nodes (12): CaneKitUITests, Bool, TimeInterval, XCUIApplication, XCUIElement, CaneKitVisualTour, Data, TimeInterval (+4 more)

### Community 3 - "DepthEngine"
Cohesion: 0.13
Nodes (16): ARConfidenceLevel, DepthEngine, LaneReport, ARFrame, ARSession, ARWorldTrackingConfiguration, CGFloat, CVPixelBuffer (+8 more)

### Community 4 - "NavSupportTests.swift"
Cohesion: 0.10
Nodes (35): Config, CrownAccumulator, CueSpeechPolicy, Bool, Double, TimeInterval, Tier, obstacle (+27 more)

### Community 5 - "BeaconEngine"
Cohesion: 0.11
Nodes (17): AudioRouteMonitor, .isAirPods, Bool, Never, NSObjectProtocol, Task, Void, BeaconEngine (+9 more)

### Community 6 - "CueDecider"
Cohesion: 0.06
Nodes (54): FileHandle, Double, Float, Int, LaneReport, Never, Task, TimeInterval (+46 more)

### Community 7 - "HandsFreeOption"
Cohesion: 0.05
Nodes (61): AppEnum, AppIntent, AppIntents, AppShortcut, AppShortcutsProvider, CustomLocalizedStringResourceConvertible, Error, CampusDestination (+53 more)

### Community 8 - "CaneBLE"
Cohesion: 0.11
Nodes (21): CBCentralManager, CBCentralManagerDelegate, CBCharacteristic, CBPeripheral, CBPeripheralDelegate, CBService, CaneBLE, ConnectionState (+13 more)

### Community 9 - ".wireNavigation"
Cohesion: 0.12
Nodes (8): Activity, ActivityAttributes, LiveActivityController, Bool, Int, Int, CaneKitWidget Live Activity target, NavActivityAttributes

### Community 10 - "Waypoint"
Cohesion: 0.13
Nodes (17): .current, Route, RouteBuilder, RouteStepInput, Bool, Data, Decoder, Double (+9 more)

### Community 11 - "docs/README.md"
Cohesion: 0.35
Nodes (4): CaneKit — Claude Code project rules, CI workflow (manual trigger only), sim-build job (macOS, informational), gen.sh script

### Community 12 - "CKBigButtonStyle"
Cohesion: 0.14
Nodes (14): ButtonStyle, Configuration, CKBigButton, .body, .icon, .text, CKBigButtonStyle, .fill (+6 more)

### Community 13 - "HapticPlayer"
Cohesion: 0.14
Nodes (12): CHHapticEngine, CHHapticPattern, CHHapticPatternPlayer, HapticPlayer, .silenced, Float, Int, Never (+4 more)

### Community 14 - "LaneTile"
Cohesion: 0.21
Nodes (11): LaneGridView, .body, LaneTile, .fill, .level, .levelWord, .text, Bool (+3 more)

### Community 15 - "NavigationEngine"
Cohesion: 0.19
Nodes (7): NavigationEngine, Bool, Date, Double, Int, TimeInterval, Void

### Community 16 - "VLMClient"
Cohesion: 0.16
Nodes (13): Secrets, .hasElevenLabs, Bool, AnthropicClient, GeminiClient, OpenAICompatibleClient, Bool, VLMClient (+5 more)

### Community 17 - "VoiceInputEngine"
Cohesion: 0.08
Nodes (29): SpeechBufferBox, SpeechResultsRelay, Any, AVAudioFormat, AVAudioNode, AVAudioPCMBuffer, Bool, Double (+21 more)

### Community 18 - ".computeLanes"
Cohesion: 0.14
Nodes (25): LaneGrid, scene, LaneConfig, UInt8, UnsafeRawPointer, PublishGate, Double, groundBandIsSkipped() (+17 more)

### Community 19 - "AppModel"
Cohesion: 0.07
Nodes (25): AppModel, .beaconEnabled, .dangerSoundsEnabled, .fallbackToWatch, .groundHazardsEnabled, .hapticsSilenced, .hazardWatchEnabled, .highFrameRateCamera (+17 more)

### Community 20 - "WKBigButton"
Cohesion: 0.12
Nodes (15): Role, destructive, primary, secondary, Bool, CGFloat, Color, UInt32 (+7 more)

### Community 21 - "NavLiveActivity"
Cohesion: 0.13
Nodes (12): ActivityKit, CaneKitWidgetBundle, .body, Widget, NavLiveActivity, .body, Int, View (+4 more)

### Community 22 - "WatchModel"
Cohesion: 0.20
Nodes (9): HKWorkoutSession, .content, Double, Int, Never, Task, TimeInterval, WatchModel (+1 more)

### Community 23 - "SpeechQueue"
Cohesion: 0.07
Nodes (33): AVAudioPlayer, AVAudioPlayerDelegate, AVAudioSessionPortDescription, AVSpeechSynthesisVoice, AVSpeechSynthesizer, AVSpeechSynthesizerDelegate, AVSpeechUtterance, Int (+25 more)

### Community 24 - "DepthFrameProcessor"
Cohesion: 0.15
Nodes (14): ARSessionDelegate, AsyncStream, SessionObserver, DepthFrameProcessor, .hasCameraFrame, .rotationRate, ProcessorSettings, Bool (+6 more)

### Community 25 - ".samples"
Cohesion: 0.33
Nodes (6): GroundSampler, ARFrame, Float, Int, SIMD3, UInt8

### Community 26 - "DepthEngine"
Cohesion: 0.16
Nodes (12): DepthEngine, .arSession, .supportedFormats, .supportsFrontCameraWithLiDAR, ARConfiguration, ARWorldTrackingConfiguration, Bool, Double (+4 more)

### Community 27 - "Coordinate"
Cohesion: 0.26
Nodes (22): Coordinate, GeofenceTracker, .isFinished, aGatedOutFixDoesNotBreakTheArrivalStreak(), arrivalStreakResetsOnAMiss(), cardinalBearings(), fix(), geofenceGatesOnAccuracyAndSpeedExceptArrival() (+14 more)

### Community 28 - "LaneCell"
Cohesion: 0.27
Nodes (8): LaneCell, LaneFormat, LaneGrid, .body, Bool, Color, Float, LaneReport

### Community 29 - ".describe"
Cohesion: 0.11
Nodes (17): FoundationModels, .namePeopleEnabled, OnDeviceHazards, OnDeviceVision, OnDeviceVLMClient, SceneContext, Bool, Data (+9 more)

### Community 30 - "Decodable"
Cohesion: 0.11
Nodes (29): Decodable, Encodable, Candidate, Content, DescribeError, badResponse, .errorDescription, http (+21 more)

### Community 31 - "NavCue"
Cohesion: 0.11
Nodes (21): NavCue, arrived, crossing, obstacle, turnLeft, turnRight, PhoneToWatch, nav (+13 more)

### Community 32 - "Module: ui-tests-build — Phone UI, XCUITests, XcodeGen build, CI"
Cohesion: 0.09
Nodes (23): docs/design.md — rules the UI code implements, .github/workflows/ci.yml, ios/CaneKit/UI/ArrivalCardView.swift, ios/CaneKit/UI/ContentView.swift, ios/CaneKit/UI/DestinationField.swift (Step 14), ios/CaneKit/UI/GuideCard.swift, ios/CaneKit/UI/HapticsCard.swift, ios/CaneKit/UI/HazardsCard.swift (Step 11) (+15 more)

### Community 33 - "CourseSmoother"
Cohesion: 0.19
Nodes (12): C, CourseSmoother, Double, Int, TimeInterval, aRealTurnShowsUpAfterTheBaseline(), at(), jitterOnAStraightWalkNeverLooksLikeAVeer() (+4 more)

### Community 34 - "DestinationField"
Cohesion: 0.11
Nodes (18): Binding, ColorSchemeContrast, Font, DestinationField, .body, .suggestionList, Bool, ScrollViewProxy (+10 more)

### Community 35 - "HazardScanner"
Cohesion: 0.15
Nodes (15): HazardScanner, HazardSource, ground, sign, vision, Any, Bool, CGFloat (+7 more)

### Community 36 - "2. Device test matrix"
Cohesion: 0.07
Nodes (30): 0. Read this before testing: facts from the code that change how you test, 1.0 The next 24 hours, 1.1 Automated (Mac, no phone): run on every change, 1.2 Bench (indoors, phone plugged in, ISR lobby), 1.3 Outdoor walks, 1.4 Log toolkit (Aritro), 1. Test levels, 2. Device test matrix (+22 more)

### Community 37 - ".scenePhaseChanged"
Cohesion: 0.13
Nodes (9): .bothCamerasEnabled, .faceHeadTrackingEnabled, MainActor, ScenePhase, .body, ObstacleNamer, Float, LaneReport (+1 more)

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
Cohesion: 0.17
Nodes (28): GroundHazardDetector, GroundSample, Int, aCurbDownIsADropOff(), aCurbUpIsAStepUp(), aCurbYouWalkTowardStillConfirms(), aDeepDropIsReportedAtItsNearEdge(), aDeskIsNotTheGround() (+20 more)

### Community 42 - "HapticLogic"
Cohesion: 0.11
Nodes (18): Comparable, HapticLogic, Lane, center, left, .motorCode, right, .spoken (+10 more)

### Community 43 - "String"
Cohesion: 0.18
Nodes (10): String, .sentenceCased, CloudSceneGate, Int, Set, Verdict, SceneVocabulary, Bool (+2 more)

### Community 44 - "TripTracker"
Cohesion: 0.20
Nodes (9): HKObserverQuery, Date, Double, Int, Never, Task, TimeInterval, Void (+1 more)

### Community 45 - "Sendable"
Cohesion: 0.06
Nodes (41): AVCaptureVideoDataOutputSampleBufferDelegate, Equatable, VoiceInputState, error, idle, listening, processing, recognizing (+33 more)

### Community 46 - "Module `depth-haptics` — `ios/CaneKit/Depth/*.swift`, `ios/CaneKit/Haptics/HapticPlayer.swift`"
Cohesion: 0.25
Nodes (8): `ios/CaneKit/Depth/DepthEngine.swift`, `ios/CaneKit/Depth/DepthFrameProcessor.swift`, `ios/CaneKit/Depth/DualCameraSession.swift` — both cameras at once (Step 14, off by default), `ios/CaneKit/Depth/FrameReplay.swift` (Step 11, simulator-only), `ios/CaneKit/Depth/GroundSampler.swift` (Step 11), `ios/CaneKit/Depth/MeshClassifier.swift`, `ios/CaneKit/Haptics/HapticPlayer.swift`, Module `depth-haptics` — `ios/CaneKit/Depth/*.swift`, `ios/CaneKit/Haptics/HapticPlayer.swift`

### Community 48 - "WatchApp"
Cohesion: 0.18
Nodes (8): App, CaneKitApp, Scene, Scene, WatchApp, .body, WatchContentView, .body

### Community 49 - "OpenCane design system"
Cohesion: 0.07
Nodes (29): 0. Who looks at the screen, and what that forces, 10. Open design gaps (code ≠ intent, not yet fixed), 1. Typography, 2. Colour tokens, 3. Spacing and radius, 4. Motion, 5.1 Speech priorities (`SpeechQueue`, AGENTS.md hard rule 8), 5.2 Obstacle cues (phone Taptic Engine, felt through the cane) (+21 more)

### Community 50 - "Codable"
Cohesion: 0.08
Nodes (36): Codable, ConversationAction, answerHistory, answerStatus, inspectScene, recordMarker, silenceCane, speakImmediate (+28 more)

### Community 51 - "CaneKit grip module firmware"
Cohesion: 0.29
Nodes (6): Build — Arduino IDE, Build — PlatformIO, CaneKit grip module firmware, Protocol (NUS, device name `CANE`), Testing with nRF Connect (Android / iOS), Wiring

### Community 52 - ".state"
Cohesion: 0.24
Nodes (9): CameraRate, Bool, Int, cameraFrameRateFollowsTheSwitch(), liveViewCameraOffWhenSessionNotRunning(), liveViewIsOffInTheBackground(), liveViewOffBuildsNothing(), liveViewPausesWhileHot() (+1 more)

### Community 53 - "PhoneWatchLink"
Cohesion: 0.20
Nodes (9): PhoneWatchLink, SessionRelay, Any, Bool, Error, TimeInterval, Void, WCSession (+1 more)

### Community 54 - "`AppModel.swift` — engine owner, settings, cue router"
Cohesion: 0.12
Nodes (16): `AppModel.swift` — engine owner, settings, cue router, Auto-recenter — `autoRecenterIfWalkingStraight(_ fix: GeoFix)` (private, per GPS fix while navigating), Constants, Cue router — `handle(_ report: LaneReport)` (private, ~30 Hz, called from `depth.onReport`), Engine wiring (all `let`, created in the property initialisers except `describer`, `sceneContext` and `hazards`, which `init` builds), Hazards the maps do not know about (Step 11), Headphones / watch presence, Lifecycle (+8 more)

### Community 55 - "CKStatusPill"
Cohesion: 0.10
Nodes (20): GuideCard, .beaconWord, .body, .gpsTone, .gpsWord, .headSpoken, .headWord, Double (+12 more)

### Community 56 - "SensorProbe.swift"
Cohesion: 0.17
Nodes (8): ARKit, CoreImage, CoreMotion, CoreVideo, ImageIO, ObjectiveC, simd, Synchronization

### Community 57 - "Module: logic — `ios/Logic` (SwiftPM package `CaneKitLogic`)"
Cohesion: 0.08
Nodes (26): `CampusPlaces.swift` — where "take me to …" goes (Step 13; `center` added in Step 14), `ConversationModels.swift` / `FastPathIntentClassifier.swift` / `ConversationPrompt.swift` — conversational assistant logic (Step 23), `CourseSmoother.swift` — direction of travel over ≥ 15 m, for veer decisions only (Step 11), Cross-module contracts (who uses what), `CueDecider.swift` — LaneReport → haptic cue with hysteresis and rate limiting (decides *what/when*; player is elsewhere), `DepthReadiness.swift` — bounded ARKit/LiDAR route-start interlock, `DestinationSuggestions.swift` — the destination search box's ranked list (Step 14), `GeoMath.swift` — haversine distance/bearing, angle wrapping, off-course detection, waypoint geofences (+18 more)

### Community 58 - "Cane mount for the iPhone 17 Pro Max: design brief"
Cohesion: 0.12
Nodes (16): 0. Decisions, 10. Print settings, 11. Assembly and setting the angle, 12. Test protocol, 13. Open risks and follow-ups, 14. Sources, 1. Inputs and where they come from, 2. What the software needs from the mount (+8 more)

### Community 59 - "CodingKeys"
Cohesion: 0.18
Nodes (11): CodingKey, CodingKeys, bearingNextDeg, crossing, curved, id, lat, lon (+3 more)

### Community 60 - "LaneReport"
Cohesion: 0.22
Nodes (10): .body, LaneReport, .head, MeshHit, MountTilt, Bool, ClosedRange, Float (+2 more)

### Community 61 - "CaneKit — strict build checklist"
Cohesion: 0.06
Nodes (34): Branch state (updated 2026-09-12 morning), CaneKit — strict build checklist, Cross-cutting, ElevenLabs setup (2 minutes, Aritro only — nobody else can do this), Gemini setup (optional, 3 minutes, Aritro only), Hardware, later that evening (Windows machine) — see CHANGELOG Step 25, Hardware tonight (Sagar, Windows machine), Honest capability table — what the demo can and cannot claim (+26 more)

### Community 62 - "GroundHazard"
Cohesion: 0.19
Nodes (11): GroundHazard, GroundHazardKind, dropOff, lowObstacle, pothole, .shortNoun, .spoken, stepUp (+3 more)

### Community 63 - "Module `watch-widget-shared`"
Cohesion: 0.14
Nodes (14): Cross-module map, `ios/CaneKit/Watch/PhoneWatchLink.swift` — phone side of WatchConnectivity, `ios/CaneKitWatch/CaneKitWatch.entitlements`, `ios/CaneKitWatch/WatchApp.swift` — watchOS entry point, `ios/CaneKitWatch/WatchContentView.swift` — the wrist screen, `ios/CaneKitWatch/WatchModel.swift` — watch side: haptics, commands, crown, keep-alive, `ios/CaneKitWatch/WatchTheme.swift` — watch design tokens (docs/design.md §6.6), `ios/CaneKitWidget/CaneKitWidgetBundle.swift` — widget extension entry (+6 more)

### Community 64 - "ObstacleClass"
Cohesion: 0.17
Nodes (12): MeshClassifier, ARFrame, Bool, Float, ObstacleClass, ceiling, door, floor (+4 more)

### Community 65 - "HazardRecord"
Cohesion: 0.20
Nodes (10): HazardLog, .fileURL, Data, URL, HazardGeoJSON, HazardPrompt, HazardRecord, Data (+2 more)

### Community 66 - "MultiCamDepthFindings"
Cohesion: 0.10
Nodes (27): MultiCamDepthProbe, Result, .logFields, Any, AVCaptureDevice, MultiCamCost, MultiCamDepth, MultiCamDepthFindings (+19 more)

### Community 67 - "HeadNodDetector"
Cohesion: 0.12
Nodes (24): CMHeadphoneMotionManager, CMHeadphoneMotionManagerDelegate, ConnectionRelay, HeadPoseTracker, Bool, Double, Void, HeadNodDetector (+16 more)

### Community 68 - "DestinationSuggestion"
Cohesion: 0.15
Nodes (13): DestinationSuggestion, .detailLine, .searchQuery, .voiceOverHint, DestinationSuggestionKind, campus, map, DestinationSuggestions (+5 more)

### Community 69 - "FrameReplay"
Cohesion: 0.31
Nodes (7): Frame, FrameReplay, .currentName, State, Bool, Data, URL

### Community 70 - "OffCourseDetector"
Cohesion: 0.33
Nodes (9): OffCourseDetector, TimeInterval, aGpsGapForgetsTheHoldSoThereIsNoInstantVeer(), aStopMidDriftRestartsTheHold(), endEpisodeRequiresAFullHoldAgain(), gatedMomentsInsideGoodTrackingKeepTheHold(), offCourseNeedsThreeSecondsThenCoolsDown(), offCourseResetsWhenBackOnBearing() (+1 more)

### Community 72 - "SignPolicy"
Cohesion: 0.14
Nodes (19): .seenTexts, Box, GroundHazardPolicy, SeenText, SignPolicy, Bool, Float, aPartialReadOfTheSameSignIsQuiet() (+11 more)

### Community 73 - "Bool"
Cohesion: 0.12
Nodes (13): Settings, Bool, URL, LaunchMode, normal, recovered, LaunchRecovery, Bool (+5 more)

### Community 74 - "Module `navigation-trip` — GPS, waypoint engine, turn settling, route sources, trip log/tracker, Live Activity"
Cohesion: 0.15
Nodes (13): Data flow (who calls whom), `docs/route_isr_cif.md`, `ios/CaneKit/Navigation/DestinationSearch.swift` (Step 14), `ios/CaneKit/Navigation/LocationService.swift`, `ios/CaneKit/Navigation/NavigationEngine.swift`, `ios/CaneKit/Navigation/RouteSource.swift`, `ios/CaneKit/Resources/route_isr_cif.json` — schema and waypoints, `ios/CaneKit/Trip/HazardLog.swift` (Step 11) (+5 more)

### Community 75 - "CaneKit iPhone app target"
Cohesion: 0.32
Nodes (8): logic-tests job (Linux, swift:6.2), Background modes (audio, location; workout-processing, mindfulness), CaneKit iPhone app target, CaneKitLogic SwiftPM package, CaneKitUITests target, CaneKitWatch target, UIFileSharingEnabled for trip logs and hazard map, Privacy purpose strings

### Community 76 - "Module: speech-audio-scene (`ios/CaneKit/Speech`, `ios/CaneKit/Audio`, `ios/CaneKit/Scene`)"
Cohesion: 0.11
Nodes (18): Constants, Functions, `ios/CaneKit/Audio/AudioRouteMonitor.swift`, `ios/CaneKit/Audio/BeaconEngine.swift`, `ios/CaneKit/Audio/HeadPoseTracker.swift`, `ios/CaneKit/Audio/SoundWatcher.swift` — optional microphone sound recognition, `ios/CaneKit/Scene/CameraControlInteraction.swift`, `ios/CaneKit/Scene/HazardScanner.swift` (Step 11) (+10 more)

### Community 77 - ".buildRoute"
Cohesion: 0.14
Nodes (17): CLLocation, CLLocationCoordinate2D, MKPolyline, .coordinates, PlannedRoute, RouteDestination, place, query (+9 more)

### Community 78 - "View"
Cohesion: 0.13
Nodes (25): .page, dismissKeyboard(), GuidePage, .body, MountAimRow, ObstaclesCard, .body, pageScroll() (+17 more)

### Community 80 - "LaneGrid"
Cohesion: 0.38
Nodes (4): LaneGrid, LaneMath, Float, Int

### Community 81 - "Team handoff: read this first after you pull"
Cohesion: 0.15
Nodes (13): 0. Start here (5 minutes), 10. How we work (read before changing anything), 11. Known risks going into the walk, 1. The one-paragraph version, 2. What is proven, and what is not, 3. Who does what next, 4. Pull, build, install, 5. The mount angle (read this, Sagar) (+5 more)

### Community 82 - "pitch_model.py"
Cohesion: 0.27
Nodes (11): clearance(), convex_hull(), ground_hit(), outside(), pitch_table(), Where the cane shaft (toward the tip) appears in the wide camera's portrait…, z-depth and range where a ray alpha deg above the optical axis meets the ground., Smallest gap (mm) between the cradle box and the cane / collar / ear over phi =… (+3 more)

### Community 83 - "HazardWatchPolicy"
Cohesion: 0.16
Nodes (11): HazardWatchPolicy, Double, Set, TimeInterval, aCloserUpdateIsNotADuplicate(), aLateReplyLosesItsDistance(), hazardReplyKeepsDecimals(), hazardWatchAsksOnlyWhileWalkingAndRarely() (+3 more)

### Community 84 - "CameraControlInteraction"
Cohesion: 0.29
Nodes (7): AVCaptureEventInteraction, CameraControlInteraction, Coordinator, Context, Coordinator, UIView, Void

### Community 85 - "CaneKit changelog"
Cohesion: 0.05
Nodes (42): Antigravity review of Step 16 (7 findings — 4 fixed, 1 instrumented, 2 rejected with evidence), CaneKit changelog, Found broken, fixed, New, all off by default, Step 0 — phone-only reset (Thu Sep 10), Step 10 — Two adversarial review rounds, AirPods/Watch presence, XCUITests (Fri Sep 11, pre-device), Step 11 — Hazards the maps don't know, on-device vision, stress harness (Fri Sep 11, pre-device), Step 12 — Google Street View mock of ISR → CIF: what failed and the fixes (Fri Sep 11, pre-device) (+34 more)

### Community 86 - ".session"
Cohesion: 0.26
Nodes (6): ARCamera, ARAnchor, ARFrame, ARSession, Error, Task

### Community 87 - "AGENTS.md — rules for anyone (human or AI) editing OpenCane / CaneKit"
Cohesion: 0.20
Nodes (10): AGENTS.md — rules for anyone (human or AI) editing OpenCane / CaneKit, Commands, Hard rules, Hardware / OpenSCAD — traps that have already cost us a night, How we engineer (the bar for every change, human or AI), Layout, The name split — OpenCane to a human, CaneKit in the code (deliberate, do not "fix"), Things that look wrong but are deliberate (+2 more)

### Community 88 - "Every doc"
Cohesion: 0.25
Nodes (8): `docs/`, Docs index, Every doc, Hardware, iOS app, Outside `docs/`, Repo root, Where do I find…

### Community 89 - "Route: ISR Townsend Hall to CIF (UIUC, Urbana IL)"
Cohesion: 0.25
Nodes (8): Evidence per waypoint (OSM), Route: ISR Townsend Hall to CIF (UIUC, Urbana IL), Sources, To re-record on the Friday walk, Waypoints (from the JSON), What the app does at each waypoint, Where Townsend Hall is, and which door is "the Townsend exit", Why the file looks the way it does

### Community 90 - "SoundRecognitionGuard"
Cohesion: 0.11
Nodes (27): SoundInputQuality, hfp, unavailable, usable, SoundRecognitionDecision, cancelPendingStart, continueRunning, ignored (+19 more)

### Community 91 - "OpenCane: the iOS app for the phone-only smart cane"
Cohesion: 0.25
Nodes (8): 1. Day-0 checklist, 2. Verified spec deviations (don't "fix" these back), 3. Build, install, launch, 4. Secrets and permissions, 5. Testing, 6. Gotchas, Layout, OpenCane: the iOS app for the phone-only smart cane

### Community 92 - "CaneKit code reference"
Cohesion: 0.25
Nodes (8): `App/HandsFreeIntents.swift` — Siri status, questions, voice switches (Step 16), `AppIntents.swift` — Action button / Siri entry points, CaneKit code reference, `CaneKitApp.swift` — app entry point, Contents, Data flow, How to keep this file true, Module `app-core` — `ios/CaneKit/App/`

### Community 93 - "Team brief: OpenCane / CaneKit, merged safety build (Sat 2026-09-12)"
Cohesion: 0.22
Nodes (9): Aarav (walker), If you change code, Installing on the phone (Aritro), Known quirks, Sagar (hardware), Setup checklist for tonight (do these in order), State of things, Status right now (Sat 2026-09-12) — read this first (+1 more)

### Community 94 - "NSObject"
Cohesion: 0.07
Nodes (26): ARSCNViewDelegate, HKWorkoutSessionDelegate, HKWorkoutSessionState, Coordinator, ARAnchor, RuntimeEvent, ended, expiring (+18 more)

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

### Community 100 - "ConversationTool"
Cohesion: 0.07
Nodes (18): ConversationTool, dropMarker, navigateTo, queryHistory, queryScene, queryStatus, setCaneSilenced, setSetting (+10 more)

### Community 101 - "DepthSnapshot"
Cohesion: 0.12
Nodes (28): DepthSnapshot, .isEmpty, Bool, ClosedRange, Float, Int, UInt8, UnsafeRawPointer (+20 more)

### Community 103 - "CampusPlacesTests.swift"
Cohesion: 0.14
Nodes (18): DestinationPicker, PlaceCandidate, Double, Int, WalkingIntro, .voiceOverLabel, campusAliasesIgnoreCasePunctuationAndThe(), east() (+10 more)

### Community 106 - "VLMProvider"
Cohesion: 0.20
Nodes (9): Drafts (iOS 18, pre-hackathon), ScenePrompt, SpokenDistance, VLMProvider, anthropic, custom, gemini, openai (+1 more)

### Community 107 - "GeoFix"
Cohesion: 0.17
Nodes (9): GeoFix, GeoMath, NavEvent, reached, Bool, Double, Int, isrToCifIsAboutSevenHundredMetres() (+1 more)

### Community 108 - "SightingKind"
Cohesion: 0.09
Nodes (28): Group, Group, PeopleAhead, SightingBearing, ahead, left, .order, right (+20 more)

### Community 109 - "StraightWalkDetector"
Cohesion: 0.39
Nodes (4): StraightWalkDetector, Int, straightWalkNeedsThreeSteadyFixesCountingTheFirst(), straightWalkRestartsOnATurnAStopOrAHeadTurn()

### Community 110 - ".handle"
Cohesion: 0.24
Nodes (4): CGFloat, Data, LaneReport, TimeInterval

### Community 112 - "SceneVocabularyTests.swift"
Cohesion: 0.13
Nodes (19): Group, Float, Int, detectedPeopleAreFaithfulWithoutSceneLabels(), blankWallsTeensAndMisreadsAreHandled(), crossingInformationComesFirst(), decimalsInTheFactsStayWhole(), factWordsAreAllowedAndDistanceIsANumber() (+11 more)

### Community 113 - "StatusFacts"
Cohesion: 0.15
Nodes (21): StatusFacts, StatusSummary, Bool, Double, Int, aRunningDepthSessionWithNoFramesIsNotReportedAsOn(), everyStatusClauseIsOneFinishedSentence(), gpsClauseSeparatesDeniedFromNoFix() (+13 more)

### Community 114 - "TorchSwitch"
Cohesion: 0.15
Nodes (13): Configuration, Outcome, changedByDevice, confirmed, failed, none, .queueSeconds, .spokenLine (+5 more)

### Community 115 - "PeopleAheadTests.swift"
Cohesion: 0.16
Nodes (23): NormalizedBox, .midX, .midY, Sighting, animalAloneIsSpoken(), animalsComeAfterPeople(), aRealDistanceIsNeverDropped(), groupWithoutDepthSortsLast() (+15 more)

### Community 116 - "ConversationTurn"
Cohesion: 0.14
Nodes (12): ConversationCoordinator, .markers, AppModel, Bool, PostStore, .fileURL, Bool, URL (+4 more)

### Community 117 - "SoundWatcher"
Cohesion: 0.22
Nodes (10): SoundWatcher, .ownsMicrophoneSession, Any, AVAudioSession, Bool, Int, Never, NSObjectProtocol (+2 more)

### Community 118 - "DangerSound"
Cohesion: 0.10
Nodes (22): CaseIterable, DangerSound, horn, .minimumConfidence, .repeatInterval, .requiredWindows, .selectionRank, siren (+14 more)

### Community 119 - "DepthReadiness"
Cohesion: 0.21
Nodes (14): Configuration, DepthReadiness, DepthReadinessState, idle, ready, timedOut, warming, Bool (+6 more)

### Community 120 - "SpokenPhrases"
Cohesion: 0.14
Nodes (14): .spokenLine, SpokenPhrases, Float, Int, Float, aNonFiniteObstacleDistanceHasNoDistanceClause(), bucketSamplesReturnOneDistancePerDistinctPhrase(), everyGroundHazardLineIsPrefetched() (+6 more)

### Community 121 - "Printing the screwless mount — operator runbook"
Cohesion: 0.09
Nodes (20): Calibration, Fitting it together, Getting files onto a machine, Print list — read this if you are standing at a printer, Print order, Printing the screwless mount — operator runbook, Reading the bore rings, Reading the dovetail pair (+12 more)

### Community 122 - "RootTab"
Cohesion: 0.12
Nodes (18): Animation, Hashable, ContentView, .body, TimeInterval, CKTabBar, .body, RootTab (+10 more)

### Community 123 - "SensorProbe"
Cohesion: 0.21
Nodes (8): SensorProbe, .applicationStateName, .isEnabled, .thermalName, Any, ARWorldTrackingConfiguration, AVAudioSession, Bool

### Community 124 - "DualCameraSession"
Cohesion: 0.17
Nodes (12): AVCaptureDeviceInput, AVCaptureMultiCamSession, DualCameraSession, Any, AVCaptureConnection, AVCaptureDevice, AVCaptureSession, AVSampleBufferDisplayLayer (+4 more)

### Community 125 - "CaneKitLogic"
Cohesion: 0.18
Nodes (6): AVKit, CaneKitLogic, CryptoKit, SceneKit, SwiftUI, UIKit

### Community 126 - "DestinationSearch"
Cohesion: 0.19
Nodes (10): CompleterRelay, DestinationSearch, Bool, Error, Never, Sendable, Task, Void (+2 more)

### Community 127 - "Text"
Cohesion: 0.21
Nodes (15): HazardsCard, .body, .bothCameras, .frontCameraReadout, .liveView, .selfTests, .soundStatus, ContentView (+7 more)

### Community 128 - "LocationService"
Cohesion: 0.15
Nodes (12): CLBackgroundActivitySession, CLHeading, CLLocationManager, CLLocationManagerDelegate, LocationService, .authorizationDenied, Bool, Double (+4 more)

### Community 129 - "ElevenLabsVoice"
Cohesion: 0.19
Nodes (12): ElevenLabsVoice, Failure, Bool, Data, Int, TimeInterval, URL, VoiceError (+4 more)

### Community 130 - "CompletionLine"
Cohesion: 0.24
Nodes (13): CompletionLine, campusCentreIsWithinWalkingRangeOfEveryPlace(), campusMatchingIsPartialUnlikeTheGazetteerLookup(), campusPlacesRankFirst(), detailLineShowsTheAddressOrTheCampusDistance(), emptyAndRepeatedMapRowsAreDropped(), fromCIF(), mapRowsThatDuplicateACampusPlaceAreDropped() (+5 more)

### Community 131 - "ProbeSessionWatcher"
Cohesion: 0.18
Nodes (9): Counts, ProbeSessionWatcher, ARAnchor, ARConfiguration, ARFrame, ARSession, Double, Error (+1 more)

### Community 132 - "sign_probe.swift"
Cohesion: 0.15
Nodes (15): AppKit, CGImage, CoreText, far, composite(), Entry, metres(), normalize() (+7 more)

### Community 133 - ".probeCapture"
Cohesion: 0.22
Nodes (6): ProbeCaptureCounter, ProbeCaptureNotes, AVCaptureDevice, AVCaptureSession, Int, NSObjectProtocol

### Community 134 - "CloudSceneGateTests.swift"
Cohesion: 0.23
Nodes (14): clockFaceDirectionsAreRefused(), countsOfHazardsLoseTheirNumeral(), distancesMustBeTheLidarNumber(), namesTheCameraDidReadSurvive(), nothingTrustworthyLeftReturnsNil(), numeralsThatAreNotCountsAreNotSnippedOut(), ordinaryDescriptionsReachTheWalkerUntouched(), paceAndBlockEstimatesAreRefusedNotMangled() (+6 more)

### Community 135 - "SpeechLoadPolicy"
Cohesion: 0.28
Nodes (5): Configuration, SpeechLoadPolicy, Bool, TimeInterval, SpeechLoadPolicyTests

### Community 136 - "VLMCodecTests.swift"
Cohesion: 0.19
Nodes (12): VLMRequest, anthropicRequestShape(), anthropicResponseParsesAndDetectsRefusal(), geminiRequestCarriesImageAndPrompt(), geminiResponseParses(), httpErrorsCarryProviderMessage(), json(), openAIRequestBudgetsForReasoningTokens() (+4 more)

### Community 137 - "DepthFrameContinuity"
Cohesion: 0.21
Nodes (6): LaneReport, Int, DepthFrameContinuity, Int, publishedFrameContinuityHonorsTransitionBoundary(), publishedFrameContinuityRejectsGapsAndRecovers()

### Community 138 - "DualCameraFrameRelay"
Cohesion: 0.21
Nodes (10): CaptureHandoff, DualCameraFrameRelay, .frameCount, State, AVCaptureOutput, CMSampleBuffer, Int, MainActor (+2 more)

### Community 139 - ".describe"
Cohesion: 0.22
Nodes (7): post(), Data, URL, VLMAnswer, VLMAnswerSource, cloud, onDevice

### Community 140 - "VLMError"
Cohesion: 0.29
Nodes (9): Data, Int, VLMError, emptyResponse, .errorDescription, http, malformed, refused (+1 more)

### Community 141 - "LiveViewTests.swift"
Cohesion: 0.26
Nodes (10): bothCamerasAreOffInTheBackground(), bothCamerasAreRefusedWhileARouteIsGuiding(), bothCamerasExplainTheRefusalForTheWholeRoute(), bothCamerasGoLiveWhenNothingIsWalking(), bothCamerasOffWithTheSwitchOff(), bothCamerasRefuseWithoutMultiCamSupport(), faceTrackingChangeAppliesWhenNoRouteIsActive(), faceTrackingChangeIsRefusedWhileARouteIsGuiding() (+2 more)

### Community 142 - "Testing"
Cohesion: 0.17
Nodes (7): Any, Double, Set, TripLogRecord, fieldsNeverOverwriteTheRecordTimeOrKind(), ordinaryFieldsPassThrough(), Testing

### Community 143 - ".queue"
Cohesion: 0.21
Nodes (8): Bool, Int, VoicePrefetch, aCancelledWarmUpResumesInsteadOfStartingOver(), aBadKeyStopsThePrefetchInsteadOfRepeatingItselfTwentyTimes(), prefetchDropsRepeatsAndAlreadyCachedLinesButKeepsTheRest(), prefetchIgnoresBlankLines(), prefetchKeepsSpeakingOrderSoTheFirstCueIsReadyFirst()

### Community 144 - "SoundAnalysisPump"
Cohesion: 0.24
Nodes (8): AVAudioFramePosition, DispatchQueue, SoundAnalysisPump, SoundBufferBox, AVAudioFormat, AVAudioNode, AVAudioPCMBuffer, SNAudioStreamAnalyzer

### Community 145 - "DualPreviewHostView"
Cohesion: 0.29
Nodes (6): BothCamerasView, DualPreviewHostView, AVSampleBufferDisplayLayer, Context, UIView, UIViewRepresentable

### Community 146 - "LiveCameraView"
Cohesion: 0.31
Nodes (6): ARSCNView, LiveCameraView, ARSession, Context, Coordinator, Int

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
Cohesion: 0.24
Nodes (7): QuestionPrompt, anOverlongQuestionIsCapped(), aQuestionWithNoLettersIsNotAQuestion(), askingForNumbersOrReassuranceIsStillRefused(), cannotTellSurvivesTheCloudGate(), cleanCollapsesWhitespaceAndRemovesQuotes(), questionPromptCarriesTheQuestionAndTheBans()

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

### Community 155 - "ArrivalCardView"
Cohesion: 0.36
Nodes (4): ArrivalCardView, .body, Double, TimeInterval

### Community 156 - "SoundRecognitionFailure"
Cohesion: 0.25
Nodes (8): SoundRecognitionFailure, analyzerFailed, inputRouteDegraded, inputUnavailable, interrupted, outputRouteChanged, permissionDenied, permissionRevoked

### Community 157 - ".insetRect"
Cohesion: 0.33
Nodes (5): CGRect, BothCamerasLayout, Double, bothCamerasInsetIsClampedInAShortBox(), bothCamerasInsetSitsInTheBottomTrailingCorner()

### Community 158 - "3D print files — the screwless phone mount"
Cohesion: 0.29
Nodes (6): 3D print files — the screwless phone mount, Files, Not settled yet, Print in this order, Putting it together, Reading step 1

### Community 159 - "CampusPlace"
Cohesion: 0.33
Nodes (5): Identifiable, CampusPlace, CampusPlaces, Set, campusPlaceIdsArePinned()

### Community 160 - "FallbackVLMClient"
Cohesion: 0.40
Nodes (5): Duration, FallbackVLMClient, .cloudPrimary, .name, .onDeviceFallback

### Community 161 - "WatchModel.swift"
Cohesion: 0.33
Nodes (3): HealthKit, WatchConnectivity, WatchKit

### Community 162 - "appicon.py"
Cohesion: 0.47
Nodes (5): cap(), OpenCane icon v2 — 'White Cane'. A real mobility cane on the dark field: black…, Circle end-cap of diameter d with vertical gradient., seg(), vgrad()

### Community 163 - "ProbeIntrospection"
Cohesion: 0.60
Nodes (4): AnyClass, ProbeIntrospection, .framePixelBufferProperties, .frameProperties

### Community 164 - "Auditory load: what the research says, what OpenCane does"
Cohesion: 0.40
Nodes (4): Auditory load: what the research says, what OpenCane does, Open questions (for walks with a blind / O&M-trained tester, not guesses), What OpenCane already does about each point, What the literature says

### Community 165 - "TileLevel"
Cohesion: 0.40
Nodes (5): TileLevel, clear, near, noData, urgent

### Community 166 - "vision_probe.swift"
Cohesion: 0.40
Nodes (4): Entry, normalize(), Double, Vision

## Ambiguous Edges - Review These
- `AGENTS.md` → `drafts/README.md`  [AMBIGUOUS]
  ios/drafts/README.md · relation: conceptually_related_to

## Knowledge Gaps
- **744 isolated node(s):** `cif`, `isr`, `grainger`, `illiniUnion`, `siebel` (+739 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **7 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **What is the exact relationship between `AGENTS.md` and `drafts/README.md`?**
  _Edge tagged AMBIGUOUS (relation: conceptually_related_to) - confidence is low._
- **Why does `String` connect `String` to `AppModel`, `CaneKitUITests`, `DepthEngine`, `NavSupportTests.swift`, `BeaconEngine`, `CueDecider`, `HandsFreeOption`, `CaneBLE`, `.wireNavigation`, `Waypoint`, `CKBigButtonStyle`, `HapticPlayer`, `LaneTile`, `NavigationEngine`, `VLMClient`, `VoiceInputEngine`, `AppModel`, `WKBigButton`, `NavLiveActivity`, `WatchModel`, `SpeechQueue`, `DepthEngine`, `LaneCell`, `.describe`, `Decodable`, `NavCue`, `DestinationField`, `HazardScanner`, `.scenePhaseChanged`, `FaceYawTracker`, `HapticLogic`, `TripTracker`, `Sendable`, `Codable`, `PhoneWatchLink`, `CKStatusPill`, `CodingKeys`, `LaneReport`, `GroundHazard`, `ObstacleClass`, `HazardRecord`, `MultiCamDepthFindings`, `HeadNodDetector`, `DestinationSuggestion`, `FrameReplay`, `SignPolicy`, `Bool`, `.buildRoute`, `View`, `HazardWatchPolicy`, `SoundRecognitionGuard`, `NSObject`, `SoundAlertsTests.swift`, `ConversationTool`, `CampusPlacesTests.swift`, `VLMProvider`, `SightingKind`, `.handle`, `NavigationEngine.swift`, `SceneVocabularyTests.swift`, `StatusFacts`, `TorchSwitch`, `PeopleAheadTests.swift`, `ConversationTurn`, `SoundWatcher`, `DangerSound`, `DepthReadiness`, `SpokenPhrases`, `RootTab`, `SensorProbe`, `DualCameraSession`, `DestinationSearch`, `Text`, `LocationService`, `ElevenLabsVoice`, `CompletionLine`, `ProbeSessionWatcher`, `sign_probe.swift`, `.probeCapture`, `CloudSceneGateTests.swift`, `VLMCodecTests.swift`, `.describe`, `VLMError`, `Testing`, `.queue`, `SoundResultsRelay`, `QuestionPromptTests.swift`, `ArrivalCardView`, `SoundRecognitionFailure`, `CampusPlace`, `FallbackVLMClient`, `ProbeIntrospection`, `vision_probe.swift`?**
  _High betweenness centrality (0.488) - this node is a cross-community bridge._
- **Why does `AppModel` connect `AppModel` to `LocationService`, `Foundation`, `NavSupportTests.swift`, `BeaconEngine`, `CueDecider`, `.wireNavigation`, `docs/README.md`, `HapticPlayer`, `NavigationEngine`, `VoiceInputEngine`, `SpeechQueue`, `DepthEngine`, `.describe`, `HazardScanner`, `.scenePhaseChanged`, `FaceYawTracker`, `String`, `TripTracker`, `PhoneWatchLink`, `HazardRecord`, `MultiCamDepthFindings`, `HeadNodDetector`, `SignPolicy`, `Bool`, `.buildRoute`, `StraightWalkDetector`, `.handle`, `TorchSwitch`, `ConversationTurn`, `SoundWatcher`, `DualCameraSession`?**
  _High betweenness centrality (0.204) - this node is a cross-community bridge._
- **Why does `CaneKit code reference` connect `CaneKit code reference` to `Module: ui-tests-build — Phone UI, XCUITests, XcodeGen build, CI`, `Module `navigation-trip` — GPS, waypoint engine, turn settling, route sources, trip log/tracker, Live Activity`, `docs/README.md`, `Module: speech-audio-scene (`ios/CaneKit/Speech`, `ios/CaneKit/Audio`, `ios/CaneKit/Scene`)`, `Module `depth-haptics` — `ios/CaneKit/Depth/*.swift`, `ios/CaneKit/Haptics/HapticPlayer.swift``, `Module: logic — `ios/Logic` (SwiftPM package `CaneKitLogic`)`, `Module `watch-widget-shared``?**
  _High betweenness centrality (0.086) - this node is a cross-community bridge._
- **Are the 20 inferred relationships involving `AppModel` (e.g. with `AudioRouteMonitor` and `BeaconEngine`) actually correct?**
  _`AppModel` has 20 INFERRED edges - model-reasoned connections that need verification._
- **What connects `cif`, `isr`, `grainger` to the rest of the system?**
  _744 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Foundation` be split into smaller, more focused modules?**
  _Cohesion score 0.12473118279569892 - nodes in this community are weakly interconnected._