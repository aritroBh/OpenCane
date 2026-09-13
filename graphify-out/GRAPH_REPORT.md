# Graph Report - 54FoundersHack  (2026-09-12)

## Corpus Check
- 215 files · ~530,969 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 4020 nodes · 9423 edges · 205 communities (196 shown, 9 thin omitted)
- Extraction: 88% EXTRACTED · 12% INFERRED · 0% AMBIGUOUS · INFERRED: 1102 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `29178956`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- AppModel
- Foundation
- CaneKitUITests
- DepthEngine
- NavSupportTests.swift
- BeaconEngine
- FallDetector
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
- WatchToPhone
- Module: ui-tests-build — Phone UI, XCUITests, XcodeGen build, CI
- GeoFix
- DestinationField
- HazardScanner
- 2. Device test matrix
- .scenePhaseChanged
- e2e.py
- FaceYawTracker
- Ideas: retrofit smart-cane kit
- HazardTests.swift
- HapticLogic
- FamilyAlerts
- TripTracker
- SupabaseClient
- CaneKit code reference
- Float
- .content
- OpenCane design system
- ConversationAction
- CaneKit grip module firmware
- FamilyAlertPolicy
- PhoneWatchLink
- `AppModel.swift` — engine owner, settings, cue router
- CKStatusPill
- OpenCaneEvent
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
- CompletionLine
- Sendable
- OffCourseDetector
- Package.swift
- SignPolicy
- LaunchMode
- Module `navigation-trip` — GPS, waypoint engine, turn settling, route sources, trip log/tracker, Live Activity
- SwiftUI
- Module: speech-audio-scene (`ios/CaneKit/Speech`, `ios/CaneKit/Audio`, `ios/CaneKit/Scene`)
- .directions
- Text
- LaneGrid
- Team handoff: read this first after you pull
- pitch_model.py
- SpeechResume
- AlertContext
- CaneKit changelog
- NSObject
- AGENTS.md — rules for anyone (human or AI) editing OpenCane / CaneKit
- Every doc
- Route: ISR Townsend Hall to CIF (UIUC, Urbana IL)
- SoundRecognitionGuard
- OpenCane: the iOS app for the phone-only smart cane
- FamilyContactsTests.swift
- Team brief: OpenCane / CaneKit at HEAD `076fcaa` (Sat 2026-09-12 evening)
- RuntimeRelay
- AirPods + Apple Watch — setup and what the app does about them
- OpenCane: a smart-cane kit that clips an iPhone onto the cane you already own
- SoundAlertsTests.swift
- hardware/: phone-to-cane mount
- streetview/README.md
- ConversationLogicTests
- DepthSnapshot
- SpokenPhrases
- CampusPlacesTests.swift
- test.sh
- Swift 6 approachable-concurrency build settings
- CodingKeys
- LocationService
- SightingKind
- CueDecider
- .handle
- Codable
- SceneVocabularyTests.swift
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
- WatchModel.swift
- .resumeOffset
- ProfilePage
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
- ConversationTurn
- OpenCane cue design v2: what blind travellers need, and how to make the cane calmer
- LiveViewTests.swift
- .make
- .queue
- SoundAnalysisPump
- HapticCue
- LiveCameraView
- ios/CaneKit/UI/Theme.swift
- Driving OpenCane without looking at the screen
- SoundResultsRelay
- QuestionPromptTests.swift
- stl_tools.js
- OpenCane Speech Load Design
- healthy
- Global Constraints
- LaneCell
- SoundRecognitionFailure
- LiveActivitySnapshot
- 3D print files — the screwless phone mount
- CaneKitLogic
- WorkoutRelay
- DestinationSearch
- appicon.py
- ProbeIntrospection
- Auditory load: what the research says, what OpenCane does
- TileLevel
- .setMicrophoneEnabled
- Bolt's Journal - Critical Learnings
- CodingKeys
- ConversationTool
- CodingKeys
- VLMError
- PlayerRelay
- ProbeOutputDelegate
- LiveActivityObstacleGlance
- HazardWatchPolicy
- ActionRateLimit
- String
- Module `family-alerts` — cane events → the Grok Bot routine (Step 39)
- RouteSource.swift
- .invalidateReadiness
- .sighting
- GrokBotClient
- AudioRouteMonitor
- .isUsableInputFormat
- HandsFreeIntents.swift
- DepthSnapshotTests.swift
- AppIntent
- .model
- View
- SensorProbe.swift
- streetview_stim.py
- FrameReplay
- HazardsCard
- CampusDestination
- Settings
- Module `depth-haptics` — `ios/CaneKit/Depth/*.swift`, `ios/CaneKit/Haptics/HapticPlayer.swift`
- CueKind
- .portDescription
- Step 14 — The night before: what was broken and what is new (Fri Sep 11, simulator only)
- Step 16 — Emergency sirens + hands-free integrated (Sat Sep 12, uncommitted)
- .jpegSnapshot

## God Nodes (most connected - your core abstractions)
1. `AppModel` - 153 edges
2. `CaneKitLogic` - 90 edges
3. `Coordinate` - 71 edges
4. `SpeechQueue` - 64 edges
5. `CaneKit changelog` - 51 edges
6. `DepthFrameProcessor` - 46 edges
7. `DepthEngine` - 44 edges
8. `OpenCaneEvent` - 43 edges
9. `Testing` - 42 edges
10. `GroundHazardDetector` - 39 edges

## Surprising Connections (you probably didn't know these)
- `UIFileSharingEnabled for trip logs and hazard map` --conceptually_related_to--> `TripLogger`  [INFERRED]
  ios/project.yml → ios/CaneKit/Trip/TripLogger.swift
- `CaneKitUITests target` --references--> `CaneKitUITests`  [INFERRED]
  ios/project.yml → ios/CaneKitUITests/CaneKitUITests.swift
- `rawEntrypointHonoursPaddedRowStrides()` --calls--> `scene`  [INFERRED]
  ios/Logic/Tests/CaneKitLogicTests/LaneMathTests.swift → ios/CaneKit/Speech/SpeechQueue.swift
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

## Communities (205 total, 9 thin omitted)

### Community 0 - "AppModel"
Cohesion: 0.11
Nodes (20): App, AppModel, .extendedRange, .hapticsEnabled, .mirrorLeftRight, .portraitMode, .speechEnabled, .urgentDistance (+12 more)

### Community 1 - "Foundation"
Cohesion: 0.12
Nodes (8): ActivityKit, AVFoundation, CoreBluetooth, CoreHaptics, CoreMedia, Foundation, Observation, Speech

### Community 2 - "CaneKitUITests"
Cohesion: 0.08
Nodes (13): CaneKitUITests, Bool, TimeInterval, XCUIApplication, XCUIElement, CaneKitVisualTour, Data, TimeInterval (+5 more)

### Community 3 - "DepthEngine"
Cohesion: 0.16
Nodes (14): ARConfidenceLevel, DepthEngine, LaneReport, ARFrame, ARSession, ARWorldTrackingConfiguration, CVPixelBuffer, Double (+6 more)

### Community 4 - "NavSupportTests.swift"
Cohesion: 0.09
Nodes (39): Config, CrownAccumulator, CueSpeechPolicy, StraightWalkDetector, Bool, Double, Int, TimeInterval (+31 more)

### Community 5 - "BeaconEngine"
Cohesion: 0.17
Nodes (10): BeaconEngine, .enabled, .headphonesConnected, AVAudioFormat, AVAudioPCMBuffer, Bool, Double, Float (+2 more)

### Community 6 - "FallDetector"
Cohesion: 0.11
Nodes (30): CMDeviceMotion, FallWatcher, .isSupported, Bool, Double, Void, Config, Fall (+22 more)

### Community 7 - "HandsFreeOption"
Cohesion: 0.11
Nodes (20): AppEnum, AppModel, HandsFreeOption, beacon, dropOffs, hazardWatch, namePeople, nodToTalk (+12 more)

### Community 8 - "CaneBLE"
Cohesion: 0.11
Nodes (21): CBCentralManager, CBCentralManagerDelegate, CBCharacteristic, CBPeripheral, CBPeripheralDelegate, CBService, CaneBLE, ConnectionState (+13 more)

### Community 9 - "LiveActivityController"
Cohesion: 0.15
Nodes (14): Activity, ActivityAttributes, logic-tests job (Linux, swift:6.2), LiveActivityController, Bool, Double, Int, Background modes (audio, location; workout-processing, mindfulness) (+6 more)

### Community 10 - "Waypoint"
Cohesion: 0.13
Nodes (16): .current, NavEvent, reached, Int, Route, RouteBuilder, RouteStepInput, Bool (+8 more)

### Community 11 - "docs/README.md"
Cohesion: 0.30
Nodes (5): Hard rules, CaneKit — Claude Code project rules, CI workflow (manual trigger only), sim-build job (macOS, informational), gen.sh script

### Community 12 - "CKBigButton"
Cohesion: 0.09
Nodes (25): ButtonStyle, ColorSchemeContrast, Configuration, .selfTests, .body, CKBigButton, .body, .icon (+17 more)

### Community 13 - "HapticPlayer"
Cohesion: 0.14
Nodes (12): CHHapticEngine, CHHapticPattern, CHHapticPatternPlayer, HapticPlayer, .silenced, Float, Int, Never (+4 more)

### Community 14 - "LaneTile"
Cohesion: 0.19
Nodes (12): .body, LaneGridView, .body, LaneTile, .fill, .level, .levelWord, .text (+4 more)

### Community 15 - "NavigationEngine"
Cohesion: 0.16
Nodes (9): Element, Array, NavigationEngine, Bool, Date, Double, Int, TimeInterval (+1 more)

### Community 16 - "VLMClient"
Cohesion: 0.07
Nodes (32): Secrets, .hasElevenLabs, Bool, AnthropicClient, FallbackVLMClient, .cloudPrimary, .name, .onDeviceFallback (+24 more)

### Community 17 - "VoiceInputEngine"
Cohesion: 0.08
Nodes (29): SpeechBufferBox, SpeechResultsRelay, Any, AVAudioFormat, AVAudioNode, AVAudioPCMBuffer, Bool, Double (+21 more)

### Community 18 - ".computeLanes"
Cohesion: 0.18
Nodes (21): LaneGrid, LaneConfig, UInt8, UnsafeRawPointer, PublishGate, Double, groundBandIsSkipped(), headRowIsTopBand() (+13 more)

### Community 19 - "AppModel"
Cohesion: 0.06
Nodes (25): AppModel, .beaconEnabled, .cueLevel, .cuePlace, .fallbackToWatch, .fallDetectionEnabled, .familyAlertsAIContext, .familyAlertsEnabled (+17 more)

### Community 20 - "WKBigButton"
Cohesion: 0.12
Nodes (15): Role, destructive, primary, secondary, Bool, CGFloat, Color, UInt32 (+7 more)

### Community 21 - "NavLiveActivity"
Cohesion: 0.17
Nodes (12): CaneKitWidgetBundle, .body, Widget, NavLiveActivity, .body, Color, Double, Int (+4 more)

### Community 22 - "WatchModel"
Cohesion: 0.26
Nodes (6): HKWorkoutSession, Int, Never, Task, WatchModel, WKHapticType

### Community 23 - "SpeechQueue"
Cohesion: 0.16
Nodes (17): AVSpeechUtterance, Int, Pending, SpeechPriority, nav, obstacle, safety, scene (+9 more)

### Community 24 - "DepthFrameProcessor"
Cohesion: 0.11
Nodes (17): AsyncStream, DepthFrameProcessor, .hasCameraFrame, .rotationRate, ProcessorSettings, ARFrame, ARSession, Bool (+9 more)

### Community 25 - ".samples"
Cohesion: 0.33
Nodes (6): GroundSampler, ARFrame, Float, Int, SIMD3, UInt8

### Community 26 - "DepthEngine"
Cohesion: 0.14
Nodes (12): DepthEngine, .arSession, .supportedFormats, .supportsFrontCameraWithLiDAR, ARWorldTrackingConfiguration, Double, Int, LaneReport (+4 more)

### Community 27 - "Coordinate"
Cohesion: 0.23
Nodes (22): Coordinate, GeofenceTracker, .isFinished, aGatedOutFixDoesNotBreakTheArrivalStreak(), arrivalStreakResetsOnAMiss(), cardinalBearings(), fix(), geofenceGatesOnAccuracyAndSpeedExceptArrival() (+14 more)

### Community 28 - ".say"
Cohesion: 0.10
Nodes (3): .dangerSoundsEnabled, Any, Int

### Community 29 - ".describe"
Cohesion: 0.12
Nodes (16): OnDeviceHazards, OnDeviceVision, OnDeviceVLMClient, SceneContext, Bool, Data, Float, Set (+8 more)

### Community 30 - "Decodable"
Cohesion: 0.10
Nodes (30): Decodable, Encodable, Candidate, Content, DescribeError, badResponse, .errorDescription, http (+22 more)

### Community 31 - "WatchToPhone"
Cohesion: 0.22
Nodes (10): Any, WatchEnvelope, WatchToPhone, describe, nextWaypoint, recenter, repeatLast, phoneToWatchRoundTrips() (+2 more)

### Community 32 - "Module: ui-tests-build — Phone UI, XCUITests, XcodeGen build, CI"
Cohesion: 0.07
Nodes (27): docs/design.md — rules the UI code implements, .github/workflows/ci.yml, ios/CaneKit/Trip/MedicalProfileStore.swift (Step 44), ios/CaneKit/Trip/SupabaseClient.swift (Step 45), ios/CaneKit/UI/ArrivalCardView.swift, ios/CaneKit/UI/ContentView.swift, ios/CaneKit/UI/DestinationField.swift (Step 14), ios/CaneKit/UI/GuideCard.swift (+19 more)

### Community 33 - "GeoFix"
Cohesion: 0.11
Nodes (19): C, CourseSmoother, Double, Int, TimeInterval, GeoFix, GeoMath, Bool (+11 more)

### Community 34 - "DestinationField"
Cohesion: 0.24
Nodes (6): Binding, DestinationField, .body, .suggestionList, Bool, ScrollViewProxy

### Community 35 - "HazardScanner"
Cohesion: 0.13
Nodes (17): HazardScanner, .signAllowedPhrases, HazardSource, ground, sign, vision, Any, Bool (+9 more)

### Community 36 - "2. Device test matrix"
Cohesion: 0.07
Nodes (30): 0. Read this before testing: facts from the code that change how you test, 1.0 The next 24 hours, 1.1 Automated (Mac, no phone): run on every change, 1.2 Bench (indoors, phone plugged in, ISR lobby), 1.3 Outdoor walks, 1.4 Log toolkit (Aritro), 1. Test levels, 2. Device test matrix (+22 more)

### Community 37 - ".scenePhaseChanged"
Cohesion: 0.12
Nodes (8): .bothCamerasEnabled, .faceHeadTrackingEnabled, AVCaptureDevice, Bool, Double, MainActor, ScenePhase, Task

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
Cohesion: 0.19
Nodes (27): GroundHazardDetector, GroundSample, aCurbDownIsADropOff(), aCurbUpIsAStepUp(), aCurbYouWalkTowardStillConfirms(), aDeepDropIsReportedAtItsNearEdge(), aDeskIsNotTheGround(), aHazardNeedsThreeAgreeingFrames() (+19 more)

### Community 42 - "HapticLogic"
Cohesion: 0.11
Nodes (18): Comparable, HapticLogic, Lane, center, left, .motorCode, right, .spoken (+10 more)

### Community 43 - "FamilyAlerts"
Cohesion: 0.17
Nodes (9): FamilyAlerts, .canSummarize, .isConfigured, .summarizerName, Bool, Double, Int, MainActor (+1 more)

### Community 44 - "TripTracker"
Cohesion: 0.21
Nodes (9): HKObserverQuery, Date, Double, Int, Never, Task, TimeInterval, Void (+1 more)

### Community 45 - "SupabaseClient"
Cohesion: 0.13
Nodes (18): CKMobilityStats, MedicalProfileStore, .profile, Date, Double, Int, TimeInterval, SupabaseClient (+10 more)

### Community 46 - "CaneKit code reference"
Cohesion: 0.25
Nodes (8): `App/HandsFreeIntents.swift` — Siri status, questions, voice switches (Step 16), `AppIntents.swift` — Action button / Siri entry points, CaneKit code reference, `CaneKitApp.swift` — app entry point, Contents, Data flow, How to keep this file true, Module `app-core` — `ios/CaneKit/App/`

### Community 47 - "Float"
Cohesion: 0.24
Nodes (4): Box, Config, ClosedRange, Float

### Community 48 - ".content"
Cohesion: 0.18
Nodes (8): Scene, WatchApp, .body, WatchContentView, .body, .content, Double, TimeInterval

### Community 49 - "OpenCane design system"
Cohesion: 0.07
Nodes (29): 0. Who looks at the screen, and what that forces, 10. Open design gaps (code ≠ intent, not yet fixed), 1. Typography, 2. Colour tokens, 3. Spacing and radius, 4. Motion, 5.1 Speech priorities (`SpeechQueue`, AGENTS.md hard rule 8), 5.2 Obstacle cues (phone Taptic Engine, felt through the cane) (+21 more)

### Community 50 - "ConversationAction"
Cohesion: 0.09
Nodes (23): ConversationAction, answerHistory, answerStatus, inspectScene, recordMarker, silenceCane, speakImmediate, startRoute (+15 more)

### Community 51 - "CaneKit grip module firmware"
Cohesion: 0.22
Nodes (7): Cane printable drafts (OpenSCAD), legacy ESP32 era, Build — Arduino IDE, Build — PlatformIO, CaneKit grip module firmware, Protocol (NUS, device name `CANE`), Testing with nRF Connect (Android / iOS), Wiring

### Community 52 - "FamilyAlertPolicy"
Cohesion: 0.15
Nodes (16): FamilyAlertLimits, FamilyAlertPolicy, Bool, Double, Int, TimeInterval, fallAndSOSAreAlwaysCritical(), locationBreadcrumbsAreThrottled() (+8 more)

### Community 53 - "PhoneWatchLink"
Cohesion: 0.20
Nodes (9): PhoneWatchLink, SessionRelay, Any, Bool, Error, TimeInterval, Void, WCSession (+1 more)

### Community 54 - "`AppModel.swift` — engine owner, settings, cue router"
Cohesion: 0.12
Nodes (16): `AppModel.swift` — engine owner, settings, cue router, Auto-recenter — `autoRecenterIfWalkingStraight(_ fix: GeoFix)` (private, per GPS fix while navigating), Constants, Cue router — `handle(_ report: LaneReport)` (private, ~30 Hz, called from `depth.onReport`), Engine wiring (all `let`, created in the property initialisers except `describer`, `sceneContext` and `hazards`, which `init` builds), Hazards the maps do not know about (Step 11), Headphones / watch presence, Lifecycle (+8 more)

### Community 55 - "CKStatusPill"
Cohesion: 0.10
Nodes (20): GuideCard, .beaconWord, .body, .gpsTone, .gpsWord, .headSpoken, .headWord, Double (+12 more)

### Community 56 - "OpenCaneEvent"
Cohesion: 0.09
Nodes (35): ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral, ExpressibleByStringLiteral, OpenCaneEvent, OpenCaneEventType, OpenCaneGeo, OpenCaneJSON (+27 more)

### Community 57 - "Module: logic — `ios/Logic` (SwiftPM package `CaneKitLogic`)"
Cohesion: 0.07
Nodes (29): `CampusPlaces.swift` — where "take me to …" goes (Step 13; `center` added in Step 14), `ConversationModels.swift` / `FastPathIntentClassifier.swift` / `ConversationPrompt.swift` — conversational assistant logic (Step 23), `CourseSmoother.swift` — direction of travel over ≥ 15 m, for veer decisions only (Step 11), Cross-module contracts (who uses what), `CueDecider.swift` — LaneReport → haptic cue with hysteresis and rate limiting (decides *what/when*; player is elsewhere), `CueProfile.swift` — cue verbosity level × place (Step 36, cue design v2), `DepthReadiness.swift` — bounded ARKit/LiDAR route-start interlock, `DestinationSuggestions.swift` — the destination search box's ranked list (Step 14) (+21 more)

### Community 58 - "Cane mount for the iPhone 17 Pro Max: design brief"
Cohesion: 0.12
Nodes (16): 0. Decisions, 10. Print settings, 11. Assembly and setting the angle, 12. Test protocol, 13. Open risks and follow-ups, 14. Sources, 1. Inputs and where they come from, 2. What the software needs from the mount (+8 more)

### Community 59 - "CodingKeys"
Cohesion: 0.20
Nodes (10): CodingKeys, bearingNextDeg, crossing, curved, id, lat, lon, name (+2 more)

### Community 60 - "LaneReport"
Cohesion: 0.17
Nodes (13): LaneReport, .head, MeshHit, MountTilt, Bool, ClosedRange, Float, LaneGrid (+5 more)

### Community 61 - "CaneKit — strict build checklist"
Cohesion: 0.05
Nodes (42): Branch state (updated 2026-09-12 morning), CaneKit — strict build checklist, Cross-cutting, Cue design v2 — Steps 35–45 (approved 2026-09-12 evening; talk floor inserted as 37 the same night, later steps renumbered +1 — CHANGELOG entries before Step 37 use the old numbers), ElevenLabs setup (2 minutes, Aritro only — nobody else can do this), Gemini setup (optional, 3 minutes, Aritro only), Hardware, later that evening (Windows machine) — see CHANGELOG Step 25, Hardware tonight (Sagar, Windows machine) (+34 more)

### Community 62 - "GroundHazard"
Cohesion: 0.14
Nodes (16): GroundHazard, GroundHazardKind, dropOff, .isDepression, .isElevation, lowObstacle, pothole, .shortNoun (+8 more)

### Community 63 - "Module `watch-widget-shared`"
Cohesion: 0.14
Nodes (14): Cross-module map, `ios/CaneKit/Watch/PhoneWatchLink.swift` — phone side of WatchConnectivity, `ios/CaneKitWatch/CaneKitWatch.entitlements`, `ios/CaneKitWatch/WatchApp.swift` — watchOS entry point, `ios/CaneKitWatch/WatchContentView.swift` — the wrist screen, `ios/CaneKitWatch/WatchModel.swift` — watch side: haptics, commands, crown, keep-alive, `ios/CaneKitWatch/WatchTheme.swift` — watch design tokens (docs/design.md §6.6), `ios/CaneKitWidget/CaneKitWidgetBundle.swift` — widget extension entry (+6 more)

### Community 64 - "ObstacleClass"
Cohesion: 0.12
Nodes (16): ARFrame, Float, ObstacleNamer, Bool, Float, LaneReport, TimeInterval, ObstacleClass (+8 more)

### Community 65 - "HazardRecord"
Cohesion: 0.16
Nodes (13): HazardLog, .fileURL, Data, Double, URL, HazardGeoJSON, HazardPrompt, HazardRecord (+5 more)

### Community 66 - "MultiCamDepthFindings"
Cohesion: 0.10
Nodes (27): MultiCamDepthProbe, Result, .logFields, Any, AVCaptureDevice, MultiCamCost, MultiCamDepth, MultiCamDepthFindings (+19 more)

### Community 67 - "HeadNodDetector"
Cohesion: 0.12
Nodes (24): CMHeadphoneMotionManager, CMHeadphoneMotionManagerDelegate, ConnectionRelay, HeadPoseTracker, Bool, Double, Void, HeadNodDetector (+16 more)

### Community 68 - "CompletionLine"
Cohesion: 0.16
Nodes (18): CompletionLine, .detailLine, DestinationSuggestions, Int, announcementCountsTheRows(), atMostThreeCampusRows(), campusMatchingIsPartialUnlikeTheGazetteerLookup(), campusPlacesRankFirst() (+10 more)

### Community 69 - "Sendable"
Cohesion: 0.09
Nodes (30): Equatable, Identifiable, VoiceInputState, error, idle, listening, processing, recognizing (+22 more)

### Community 70 - "OffCourseDetector"
Cohesion: 0.33
Nodes (9): OffCourseDetector, TimeInterval, aGpsGapForgetsTheHoldSoThereIsNoInstantVeer(), aStopMidDriftRestartsTheHold(), endEpisodeRequiresAFullHoldAgain(), gatedMomentsInsideGoodTrackingKeepTheHold(), offCourseNeedsThreeSecondsThenCoolsDown(), offCourseResetsWhenBackOnBearing() (+1 more)

### Community 72 - "SignPolicy"
Cohesion: 0.15
Nodes (16): GroundHazardPolicy, SeenText, SignPolicy, SignPhraseFilterTests, aPartialReadOfTheSameSignIsQuiet(), aSecondSignIsStillRead(), farLinesAreNotJoinedIntoAPhantomSign(), farStackedSignLinesAreJoined() (+8 more)

### Community 73 - "LaunchMode"
Cohesion: 0.18
Nodes (10): LaunchMode, normal, recovered, LaunchRecovery, Bool, Double, aCompletedPreviousLaunchStartsNormally(), anIncompletePreviousLaunchRecovers() (+2 more)

### Community 74 - "Module `navigation-trip` — GPS, waypoint engine, turn settling, route sources, trip log/tracker, Live Activity"
Cohesion: 0.15
Nodes (13): Data flow (who calls whom), `docs/route_isr_cif.md`, `ios/CaneKit/Navigation/DestinationSearch.swift` (Step 14), `ios/CaneKit/Navigation/LocationService.swift`, `ios/CaneKit/Navigation/NavigationEngine.swift`, `ios/CaneKit/Navigation/RouteSource.swift`, `ios/CaneKit/Resources/route_isr_cif.json` — schema and waypoints, `ios/CaneKit/Trip/HazardLog.swift` (Step 11) (+5 more)

### Community 75 - "SwiftUI"
Cohesion: 0.15
Nodes (5): AVKit, SceneKit, SwiftUI, UIKit, WidgetKit

### Community 76 - "Module: speech-audio-scene (`ios/CaneKit/Speech`, `ios/CaneKit/Audio`, `ios/CaneKit/Scene`)"
Cohesion: 0.11
Nodes (18): Constants, Functions, `ios/CaneKit/Audio/AudioRouteMonitor.swift`, `ios/CaneKit/Audio/BeaconEngine.swift`, `ios/CaneKit/Audio/HeadPoseTracker.swift`, `ios/CaneKit/Audio/SoundWatcher.swift` — optional microphone sound recognition, `ios/CaneKit/Scene/CameraControlInteraction.swift`, `ios/CaneKit/Scene/HazardScanner.swift` (Step 11) (+10 more)

### Community 77 - ".directions"
Cohesion: 0.31
Nodes (9): CLLocation, CLLocationCoordinate2D, PlannedRoute, RouteDestination, place, query, RouteSource, Double (+1 more)

### Community 78 - "Text"
Cohesion: 0.12
Nodes (24): FamilyContactsEditor, .addressList, .body, .canAdd, .entryRow, .errorLine, .header, .saveRow (+16 more)

### Community 80 - "LaneGrid"
Cohesion: 0.38
Nodes (4): LaneGrid, LaneMath, Float, Int

### Community 81 - "Team handoff: read this first after you pull"
Cohesion: 0.10
Nodes (21): 0. Start here (5 minutes), 10.1 Read order, 10.2 Measure first, 10.3 The per-step bar, 10.4 Traps that already produced a false green or a lost hour, 10. How an agent resumes (and how we work), 11. Known risks going into the walk, 1. The one-paragraph version (+13 more)

### Community 82 - "pitch_model.py"
Cohesion: 0.27
Nodes (11): clearance(), convex_hull(), ground_hit(), outside(), pitch_table(), Where the cane shaft (toward the tip) appears in the wide camera's portrait…, z-depth and range where a ray alpha deg above the optical axis meets the ground., Smallest gap (mm) between the cradle box and the cane / collar / ear over phi =… (+3 more)

### Community 83 - "SpeechResume"
Cohesion: 0.16
Nodes (8): Character, SpeechResume, Bool, Int, Set, TimeInterval, Substring, UInt16

### Community 84 - "AlertContext"
Cohesion: 0.13
Nodes (20): .familyContext, AlertContext, AlertContextPrompt, Bool, Data, Double, Int, TextRequest (+12 more)

### Community 85 - "CaneKit changelog"
Cohesion: 0.04
Nodes (49): CaneKit changelog, Fix — Both cameras: the back feed was sideways again; rotation is now chosen per camera (Sat Sep 12), Step 0 — phone-only reset (Thu Sep 10), Step 10 — Two adversarial review rounds, AirPods/Watch presence, XCUITests (Fri Sep 11, pre-device), Step 11 — Hazards the maps don't know, on-device vision, stress harness (Fri Sep 11, pre-device), Step 12 — Google Street View mock of ISR → CIF: what failed and the fixes (Fri Sep 11, pre-device), Step 13 — Voice control, live camera view, natural voice, nearest-result search (Fri Sep 11, on device), Step 15 — Front-inset tilt, second attempt (Sat Sep 12, compiled + installed) (+41 more)

### Community 86 - "NSObject"
Cohesion: 0.20
Nodes (9): ARCamera, ARSessionDelegate, SessionObserver, ARAnchor, ARFrame, ARSession, Error, Task (+1 more)

### Community 87 - "AGENTS.md — rules for anyone (human or AI) editing OpenCane / CaneKit"
Cohesion: 0.20
Nodes (10): AGENTS.md — rules for anyone (human or AI) editing OpenCane / CaneKit, Commands, Hardware / OpenSCAD — traps that have already cost us a night, How we engineer (the bar for every change, human or AI), Layout, Steps 34–37 and the rotation fix (Sat 2026-09-12) — do not "simplify" these, The name split — OpenCane to a human, CaneKit in the code (deliberate, do not "fix"), Things that look wrong but are deliberate (+2 more)

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
Cohesion: 0.18
Nodes (11): 1. Day-0 checklist, 2. Verified spec deviations (don't "fix" these back), 3. Build, install, launch, 4.1 Family alerts (Grok Bot), 4. Secrets and permissions, 5. Testing, 6. Gotchas, Automation environment variables (+3 more)

### Community 92 - "FamilyContactsTests.swift"
Cohesion: 0.13
Nodes (17): Encoder, FamilyContacts, Bool, Data, normalizeCapsTheList(), normalizeDropsInvalidEntries(), normalizeIsIdempotent(), normalizeRemovesDuplicates() (+9 more)

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
Cohesion: 0.11
Nodes (22): SoundAlertPolicy, alternatingKindsDoNotAccumulate(), anEmergencySirenIsNotShadowedByTheAmbientTrafficClass(), aNonFiniteConfidenceIsIgnoredNotRanked(), aSirenJustUnderTheNewGateIsSilent(), aSubGateSirenDoesNotDisplaceAConfidentVehicle(), aWindowWithNoDangerLabelsSelectsNothing(), aWindowWithNoDangerSoundBreaksTheRun() (+14 more)

### Community 98 - "hardware/: phone-to-cane mount"
Cohesion: 0.40
Nodes (5): Bill of materials, Files, hardware/: phone-to-cane mount, Quick start (Sagar), Who does what

### Community 99 - "streetview/README.md"
Cohesion: 0.50
Nodes (3): Step 12 findings (2026-09-11, afternoon) and fixes, Street View route frames (local test input), What the first 2026-09-11 run showed

### Community 100 - "ConversationLogicTests"
Cohesion: 0.13
Nodes (7): ConversationPrompt, ConversationResponseParser, ParsedConversationResponse, WireFormat, FastPathIntentClassifier, Bool, ConversationLogicTests

### Community 101 - "DepthSnapshot"
Cohesion: 0.19
Nodes (15): DepthSnapshot, .isEmpty, Bool, ClosedRange, Float, Int, UInt8, UnsafeRawPointer (+7 more)

### Community 102 - "SpokenPhrases"
Cohesion: 0.14
Nodes (14): .spokenLine, SpokenPhrases, Float, Int, Float, aNonFiniteObstacleDistanceHasNoDistanceClause(), bucketSamplesReturnOneDistancePerDistinctPhrase(), everyGroundHazardLineIsPrefetched() (+6 more)

### Community 103 - "CampusPlacesTests.swift"
Cohesion: 0.10
Nodes (25): CampusPlaces, DestinationPicker, PlaceCandidate, Double, Int, Set, WalkingIntro, .voiceOverLabel (+17 more)

### Community 106 - "CodingKeys"
Cohesion: 0.09
Nodes (22): CodingKeys, accuracyM, batteryPct, caneID, direction, distanceM, emails, heading (+14 more)

### Community 107 - "LocationService"
Cohesion: 0.15
Nodes (12): CLBackgroundActivitySession, CLHeading, CLLocationManager, CLLocationManagerDelegate, LocationService, .authorizationDenied, Bool, Double (+4 more)

### Community 108 - "SightingKind"
Cohesion: 0.11
Nodes (22): Group, Group, PeopleAhead, SightingBearing, ahead, left, .order, right (+14 more)

### Community 109 - "CueDecider"
Cohesion: 0.23
Nodes (22): CueDecider, Bool, LaneReport, TimeInterval, centerApproachFiresThenUpdatesDistance(), centerDistanceIsClampedToNearFloor(), centerLoopIsExemptFromTheFloor(), cueChangeNeeds400ms() (+14 more)

### Community 110 - ".handle"
Cohesion: 0.24
Nodes (4): CGFloat, Data, LaneReport, TimeInterval

### Community 111 - "Codable"
Cohesion: 0.15
Nodes (14): Codable, CKMedicalProfile, Bool, NavCue, arrived, crossing, obstacle, turnLeft (+6 more)

### Community 112 - "SceneVocabularyTests.swift"
Cohesion: 0.14
Nodes (18): Float, Int, detectedPeopleAreFaithfulWithoutSceneLabels(), blankWallsTeensAndMisreadsAreHandled(), crossingInformationComesFirst(), decimalsInTheFactsStayWhole(), factWordsAreAllowedAndDistanceIsANumber(), faithfulnessUnderstandsSynonymsAndSpelledNumbers() (+10 more)

### Community 113 - "StatusFacts"
Cohesion: 0.28
Nodes (5): StatusFacts, StatusSummary, Bool, Double, Int

### Community 114 - "TorchSwitch"
Cohesion: 0.15
Nodes (13): Configuration, Outcome, changedByDevice, confirmed, failed, none, .queueSeconds, .spokenLine (+5 more)

### Community 115 - "PeopleAheadTests.swift"
Cohesion: 0.12
Nodes (29): NormalizedBox, .midX, .midY, Sighting, animalAloneIsSpoken(), animalsComeAfterPeople(), aRealDistanceIsNeverDropped(), bearingBands() (+21 more)

### Community 116 - "ConversationCoordinator"
Cohesion: 0.14
Nodes (10): ConversationCoordinator, .markers, AppModel, Bool, PostStore, .fileURL, Bool, URL (+2 more)

### Community 117 - "SoundWatcher"
Cohesion: 0.24
Nodes (10): SoundWatcher, .ownsMicrophoneSession, Any, AVAudioSession, Bool, Int, Never, NSObjectProtocol (+2 more)

### Community 118 - "DangerSound"
Cohesion: 0.13
Nodes (18): CaseIterable, DangerSound, horn, .minimumConfidence, .repeatInterval, .requiredWindows, .selectionRank, siren (+10 more)

### Community 119 - "DepthReadiness"
Cohesion: 0.21
Nodes (14): Configuration, DepthReadiness, DepthReadinessState, idle, ready, timedOut, warming, Bool (+6 more)

### Community 120 - "CueRules"
Cohesion: 0.09
Nodes (19): .cueRules, CueLevel, detailed, quiet, .spokenLine, standard, .title, CuePlace (+11 more)

### Community 121 - "Printing the screwless mount — operator runbook"
Cohesion: 0.09
Nodes (20): Calibration, Fitting it together, Getting files onto a machine, Print list — read this if you are standing at a printer, Print order, Printing the screwless mount — operator runbook, Reading the bore rings, Reading the dovetail pair (+12 more)

### Community 122 - "RootTab"
Cohesion: 0.10
Nodes (20): Animation, CaneKitApp, .body, Scene, ContentView, .body, .navigationTitleText, TimeInterval (+12 more)

### Community 123 - "SensorProbe"
Cohesion: 0.19
Nodes (9): SensorProbe, .applicationStateName, .isEnabled, .thermalName, Any, ARConfiguration, ARWorldTrackingConfiguration, AVAudioSession (+1 more)

### Community 124 - "DualCameraSession"
Cohesion: 0.15
Nodes (14): AVCaptureDeviceInput, AVCaptureMultiCamSession, CaptureHandoff, DualCameraSession, .diagnostics, Any, AVCaptureDevice, AVCaptureSession (+6 more)

### Community 125 - "WatchModel.swift"
Cohesion: 0.18
Nodes (7): CoreImage, CoreMotion, CoreVideo, HealthKit, ImageIO, WatchConnectivity, WatchKit

### Community 126 - ".resumeOffset"
Cohesion: 0.24
Nodes (3): Double, SpeechResumeTests, Int

### Community 127 - "ProfilePage"
Cohesion: 0.23
Nodes (8): Font, EditMedicalIDSheet, .body, ProfilePage, .body, .medicalIDCard, .mobilityFitnessCard, CKFont

### Community 128 - "TripLogger"
Cohesion: 0.16
Nodes (12): FileHandle, Double, Float, Int, LaneReport, Never, Task, TimeInterval (+4 more)

### Community 129 - "ElevenLabsVoice"
Cohesion: 0.13
Nodes (18): RouteError, destinationNotFound, .errorDescription, missingBundledRoute, noRoute, ElevenLabsVoice, Failure, Bool (+10 more)

### Community 130 - "CallbackBox"
Cohesion: 0.19
Nodes (9): AVSpeechSynthesisVoice, AVSpeechSynthesizer, AVSpeechSynthesizerDelegate, MKPolyline, .coordinates, CallbackBox, DelegateRelay, NSRange (+1 more)

### Community 131 - "ProbeSessionWatcher"
Cohesion: 0.21
Nodes (8): Counts, ProbeSessionWatcher, ARAnchor, ARFrame, ARSession, Double, Error, Float

### Community 132 - "sign_probe.swift"
Cohesion: 0.15
Nodes (15): AppKit, CGImage, CoreText, far, composite(), Entry, metres(), normalize() (+7 more)

### Community 133 - ".probeCapture"
Cohesion: 0.23
Nodes (6): ProbeCaptureCounter, ProbeCaptureNotes, AVCaptureDevice, AVCaptureSession, Int, NSObjectProtocol

### Community 134 - "CloudSceneGateTests.swift"
Cohesion: 0.21
Nodes (15): clockFaceDirectionsAreRefused(), countsOfHazardsLoseTheirNumeral(), distancesMustBeTheLidarNumber(), groundedNumbersPredicateIsShared(), namesTheCameraDidReadSurvive(), nothingTrustworthyLeftReturnsNil(), numeralsThatAreNotCountsAreNotSnippedOut(), ordinaryDescriptionsReachTheWalkerUntouched() (+7 more)

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

### Community 139 - "ConversationTurn"
Cohesion: 0.23
Nodes (11): ConversationContext, ConversationHistory, ConversationTurn, HazardFact, ObstacleFact, Bool, Double, Float (+3 more)

### Community 140 - "OpenCane cue design v2: what blind travellers need, and how to make the cane calmer"
Cohesion: 0.14
Nodes (14): 1. What blind travellers actually need, 2. Where OpenCane violates them today, 3.1 Design rules, 3.2 Head height: much calmer, never suppressed, 3.3 Everything else, by verbosity level, 3.4 Speech budget (`SpeechBudget`, generalising `SpeechLoadPolicy`), 3.5 Indoor and outdoor, 3.6 What the cane tip already covers, so we drop it (+6 more)

### Community 141 - "LiveViewTests.swift"
Cohesion: 0.07
Nodes (42): BothCameras, blockedByRoute, live, off, unsupported, BothCamerasLayout, CameraRate, DualCameraRotation (+34 more)

### Community 142 - ".make"
Cohesion: 0.25
Nodes (6): Any, Double, Set, TripLogRecord, fieldsNeverOverwriteTheRecordTimeOrKind(), ordinaryFieldsPassThrough()

### Community 143 - ".queue"
Cohesion: 0.21
Nodes (8): Bool, Int, VoicePrefetch, aCancelledWarmUpResumesInsteadOfStartingOver(), aBadKeyStopsThePrefetchInsteadOfRepeatingItselfTwentyTimes(), prefetchDropsRepeatsAndAlreadyCachedLinesButKeepsTheRest(), prefetchIgnoresBlankLines(), prefetchKeepsSpeakingOrderSoTheFirstCueIsReadyFirst()

### Community 144 - "SoundAnalysisPump"
Cohesion: 0.24
Nodes (8): AVAudioFramePosition, DispatchQueue, SoundAnalysisPump, SoundBufferBox, AVAudioFormat, AVAudioNode, AVAudioPCMBuffer, SNAudioStreamAnalyzer

### Community 145 - "HapticCue"
Cohesion: 0.11
Nodes (17): .logicPackageOK, CueOutput, fire, stop, updateCenter, CueThresholds, GeigerRate, HapticCue (+9 more)

### Community 146 - "LiveCameraView"
Cohesion: 0.07
Nodes (25): ARSCNView, ARSCNViewDelegate, AVCaptureEventInteraction, CGRect, CameraControlInteraction, Coordinator, Context, Coordinator (+17 more)

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

### Community 153 - "healthy"
Cohesion: 0.21
Nodes (16): aRunningDepthSessionWithNoFramesIsNotReportedAsOn(), everyStatusClauseIsOneFinishedSentence(), gpsClauseSeparatesDeniedFromNoFix(), gpsWeakThresholdMatchesTheGeofenceGate(), healthy(), healthyStatusStillNamesEveryChannel(), losingHeadphonesSaysWhatStoppedWorking(), lowBatteryIsWordedAndUnknownBatteryIsOmitted() (+8 more)

### Community 154 - "Global Constraints"
Cohesion: 0.25
Nodes (7): Global Constraints, OpenCane Speech Load Implementation Plan, Task 1: Add the pure optional-speech admission policy, Task 2: Apply the policy at the speech boundary, Task 3: Make scene narration select useful facts, Task 4: Fix the known persistence honesty bug, Task 5: Safety regression and independent review

### Community 155 - "LaneCell"
Cohesion: 0.24
Nodes (10): LaneCell, .background, .body, LaneFormat, LaneGrid, .body, Bool, Color (+2 more)

### Community 156 - "SoundRecognitionFailure"
Cohesion: 0.25
Nodes (8): SoundRecognitionFailure, analyzerFailed, inputRouteDegraded, inputUnavailable, interrupted, outputRouteChanged, permissionDenied, permissionRevoked

### Community 157 - "LiveActivitySnapshot"
Cohesion: 0.26
Nodes (7): LiveActivityCoalescer, LiveActivitySnapshot, Bool, Decoder, Double, Int, LiveActivityCoalescerTests

### Community 158 - "3D print files — the screwless phone mount"
Cohesion: 0.29
Nodes (6): 3D print files — the screwless phone mount, Files, Not settled yet, Print in this order, Putting it together, Reading step 1

### Community 159 - "CaneKitLogic"
Cohesion: 0.15
Nodes (6): CaneKitLogic, CryptoKit, nodToTalkSwitchesByVoice(), nodToTalkWithoutAVerbIsNotASetting(), os, Testing

### Community 160 - "WorkoutRelay"
Cohesion: 0.20
Nodes (9): HKWorkoutSessionDelegate, Any, Bool, Void, WCSession, WCSessionActivationState, WatchSessionRelay, WorkoutRelay (+1 more)

### Community 161 - "DestinationSearch"
Cohesion: 0.19
Nodes (10): CompleterRelay, DestinationSearch, Bool, Error, Never, Sendable, Task, Void (+2 more)

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

### Community 166 - ".setMicrophoneEnabled"
Cohesion: 0.17
Nodes (8): MicrophoneOwner, soundRecognition, voiceInput, MicrophoneSessionResult, failed, granted, revertedRouteChanged, AVAudioSession

### Community 171 - "CodingKeys"
Cohesion: 0.11
Nodes (18): CodingKeys, accuracy, direction, distanceM, headingDeg, heightM, instruction, kind (+10 more)

### Community 172 - "ConversationTool"
Cohesion: 0.20
Nodes (9): ConversationTool, dropMarker, navigateTo, queryHistory, queryScene, queryStatus, setCaneSilenced, setSetting (+1 more)

### Community 173 - "CodingKeys"
Cohesion: 0.12
Nodes (17): CodingKey, CodingKeys, distanceM, headClearanceM, instruction, kind, obstacleDistanceM, obstacleStatus (+9 more)

### Community 174 - "VLMError"
Cohesion: 0.11
Nodes (25): Drafts (iOS 18, pre-hackathon), ScenePrompt, SpokenDistance, Data, Int, VLMError, emptyResponse, .errorDescription (+17 more)

### Community 175 - "PlayerRelay"
Cohesion: 0.29
Nodes (5): AVAudioPlayer, AVAudioPlayerDelegate, PlayerRelay, Error, Void

### Community 176 - "ProbeOutputDelegate"
Cohesion: 0.25
Nodes (6): AVCaptureVideoDataOutputSampleBufferDelegate, ProbeOutputDelegate, AVCaptureConnection, AVCaptureOutput, CMSampleBuffer, Void

### Community 177 - "LiveActivityObstacleGlance"
Cohesion: 0.16
Nodes (15): Hashable, LiveActivityObstacleStatus, clear, dropOff, head, warning, ContentState, LiveActivityObstacleGlance (+7 more)

### Community 178 - "HazardWatchPolicy"
Cohesion: 0.17
Nodes (11): HazardWatchPolicy, Double, Set, TimeInterval, aCloserUpdateIsNotADuplicate(), aLateReplyLosesItsDistance(), hazardReplyKeepsDecimals(), hazardWatchAsksOnlyWhileWalkingAndRarely() (+3 more)

### Community 179 - "ActionRateLimit"
Cohesion: 0.24
Nodes (8): ActionRateLimit, Bool, Int, TimeInterval, actionsAreIndependent(), refusedAttemptsDoNotExtendTheWait(), repeatsAreSpacedByTheInterval(), secondsRemainingCountsDown()

### Community 180 - "String"
Cohesion: 0.17
Nodes (10): String, .sentenceCased, CloudSceneGate, Int, Set, Verdict, Group, SceneVocabulary (+2 more)

### Community 181 - "Module `family-alerts` — cane events → the Grok Bot routine (Step 39)"
Cohesion: 0.15
Nodes (13): Call sites, `ios/CaneKit/Alerts/AlertSummarizer.swift` — the cheap model, `ios/CaneKit/Alerts/FallWatcher.swift` — CoreMotion → FallDetector (Step 43), `ios/CaneKit/Alerts/FamilyAlerts.swift` — the main-actor relay, `ios/CaneKit/Alerts/GrokBotClient.swift` — transport only, `Logic/Sources/CaneKitLogic/ActionRateLimit.swift` — webhook button spam guard (Step 43), `Logic/Sources/CaneKitLogic/AlertContext.swift` — what the phone knew, and the model's prompt, `Logic/Sources/CaneKitLogic/FallDetector.swift` — the cane went over (Step 43) (+5 more)

### Community 182 - "RouteSource.swift"
Cohesion: 0.20
Nodes (6): ARKit, CoreLocation, MeshClassifier, Bool, MapKit, simd

### Community 184 - ".sighting"
Cohesion: 0.21
Nodes (13): Double, ThreatSighting, ThreatWatch, aContrastResetsTheNegation(), aNegationCoversTheWholeList(), aWeaponIsReported(), benignCollocationsDoNotAlert(), emptyTextIsNotASighting() (+5 more)

### Community 185 - "GrokBotClient"
Cohesion: 0.09
Nodes (22): AlertSummarizer, Provider, anthropic, .name, openAICompatible, Data, TimeInterval, URL (+14 more)

### Community 186 - "AudioRouteMonitor"
Cohesion: 0.27
Nodes (7): AudioRouteMonitor, .isAirPods, Bool, Never, NSObjectProtocol, Task, Void

### Community 187 - ".isUsableInputFormat"
Cohesion: 0.28
Nodes (7): MicrophoneStart, Bool, Double, UInt32, onlyAFullySettledInputFormatIsUsable(), theInputFormatIsRetriedExactlyOnce(), theRetryLoopReadsTheFormatExactlyFormatAttemptsTimes()

### Community 188 - "HandsFreeIntents.swift"
Cohesion: 0.23
Nodes (10): AppIntents, AskSceneIntent, RecenterIntent, SetOptionIntent, SilenceHapticsIntent, StatusIntent, IntentModes, IntentResult (+2 more)

### Community 189 - "DepthSnapshotTests.swift"
Cohesion: 0.35
Nodes (12): box(), boxDepthClampsBoxesOffTheEdge(), boxDepthFlipsVisionsBottomLeftOrigin(), boxDepthFollowsTheBoxAcrossTheFrame(), boxDepthIgnoresEdgeSpikes(), boxDepthIsNilWhenUnknown(), boxDepthIsTheMedianOfItsMiddle(), boxDepthRefusesANonFiniteBox() (+4 more)

### Community 190 - "AppIntent"
Cohesion: 0.37
Nodes (14): AppIntent, AppShortcut, AppShortcutsProvider, CaneKitShortcuts, .appShortcuts, NavigateToCIFIntent, NextWaypointIntent, RepeatInstructionIntent (+6 more)

### Community 191 - ".model"
Cohesion: 0.21
Nodes (7): CustomLocalizedStringResourceConvertible, Error, IntentSupport, NotReady, .localizedStringResource, AppModel, IntentResult

### Community 192 - "View"
Cohesion: 0.17
Nodes (15): ArrivalCardView, .body, Double, TimeInterval, .page, dismissKeyboard(), GuidePage, .body (+7 more)

### Community 193 - "SensorProbe.swift"
Cohesion: 0.20
Nodes (6): FoundationModels, normalize(), ObjectiveC, SoundAnalysis, Synchronization, Vision

### Community 194 - "streetview_stim.py"
Cohesion: 0.43
Nodes (6): haversine(), main(), Generate Sundar Pichai / Astra-style natural multimodal narration., Run swift vision probe to extract on-device Vision labels and OCR texts., run_vision_on_frames(), synthesize_astra_commentary()

### Community 195 - "FrameReplay"
Cohesion: 0.31
Nodes (7): Frame, FrameReplay, .currentName, State, Bool, Data, URL

### Community 196 - "HazardsCard"
Cohesion: 0.46
Nodes (6): HazardsCard, .body, .bothCameras, .frontCameraReadout, .liveView, .soundStatus

### Community 197 - "CampusDestination"
Cohesion: 0.20
Nodes (10): CampusDestination, arc, cif, grainger, illiniUnion, isr, mainLibrary, siebel (+2 more)

### Community 199 - "Module `depth-haptics` — `ios/CaneKit/Depth/*.swift`, `ios/CaneKit/Haptics/HapticPlayer.swift`"
Cohesion: 0.25
Nodes (8): `ios/CaneKit/Depth/DepthEngine.swift`, `ios/CaneKit/Depth/DepthFrameProcessor.swift`, `ios/CaneKit/Depth/DualCameraSession.swift` — both cameras at once (Step 14, off by default), `ios/CaneKit/Depth/FrameReplay.swift` (Step 11, simulator-only), `ios/CaneKit/Depth/GroundSampler.swift` (Step 11), `ios/CaneKit/Depth/MeshClassifier.swift`, `ios/CaneKit/Haptics/HapticPlayer.swift`, Module `depth-haptics` — `ios/CaneKit/Depth/*.swift`, `ios/CaneKit/Haptics/HapticPlayer.swift`

### Community 200 - "CueKind"
Cohesion: 0.33
Nodes (6): CueKind, center, clear, head, left, right

### Community 202 - "Step 14 — The night before: what was broken and what is new (Fri Sep 11, simulator only)"
Cohesion: 0.67
Nodes (3): Found broken, fixed, New, all off by default, Step 14 — The night before: what was broken and what is new (Fri Sep 11, simulator only)

## Ambiguous Edges - Review These
- `AGENTS.md` → `drafts/README.md`  [AMBIGUOUS]
  ios/drafts/README.md · relation: conceptually_related_to

## Knowledge Gaps
- **908 isolated node(s):** `.name`, `.isSupported`, `.isConfigured`, `.canSummarize`, `.summarizerName` (+903 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **9 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **What is the exact relationship between `AGENTS.md` and `drafts/README.md`?**
  _Edge tagged AMBIGUOUS (relation: conceptually_related_to) - confidence is low._
- **Why does `String` connect `String` to `AppModel`, `Foundation`, `CaneKitUITests`, `DepthEngine`, `NavSupportTests.swift`, `BeaconEngine`, `HandsFreeOption`, `CaneBLE`, `LiveActivityController`, `Waypoint`, `CKBigButton`, `HapticPlayer`, `LaneTile`, `NavigationEngine`, `VLMClient`, `VoiceInputEngine`, `AppModel`, `WKBigButton`, `NavLiveActivity`, `WatchModel`, `SpeechQueue`, `DepthEngine`, `Coordinate`, `.say`, `.describe`, `Decodable`, `WatchToPhone`, `DestinationField`, `HazardScanner`, `.scenePhaseChanged`, `FaceYawTracker`, `HapticLogic`, `FamilyAlerts`, `TripTracker`, `SupabaseClient`, `Float`, `ConversationAction`, `FamilyAlertPolicy`, `PhoneWatchLink`, `CKStatusPill`, `OpenCaneEvent`, `CodingKeys`, `LaneReport`, `GroundHazard`, `ObstacleClass`, `HazardRecord`, `MultiCamDepthFindings`, `HeadNodDetector`, `CompletionLine`, `Sendable`, `SignPolicy`, `LaunchMode`, `.directions`, `Text`, `SpeechResume`, `AlertContext`, `SoundRecognitionGuard`, `FamilyContactsTests.swift`, `RuntimeRelay`, `SoundAlertsTests.swift`, `ConversationLogicTests`, `SpokenPhrases`, `CampusPlacesTests.swift`, `CodingKeys`, `LocationService`, `SightingKind`, `.handle`, `Codable`, `SceneVocabularyTests.swift`, `StatusFacts`, `TorchSwitch`, `PeopleAheadTests.swift`, `ConversationCoordinator`, `SoundWatcher`, `DangerSound`, `DepthReadiness`, `CueRules`, `RootTab`, `SensorProbe`, `DualCameraSession`, `.resumeOffset`, `ProfilePage`, `TripLogger`, `ElevenLabsVoice`, `ProbeSessionWatcher`, `sign_probe.swift`, `.probeCapture`, `CloudSceneGateTests.swift`, `DualCameraFrameRelay`, `ConversationTurn`, `.make`, `.queue`, `SoundResultsRelay`, `QuestionPromptTests.swift`, `healthy`, `LaneCell`, `SoundRecognitionFailure`, `LiveActivitySnapshot`, `WorkoutRelay`, `DestinationSearch`, `ProbeIntrospection`, `.setMicrophoneEnabled`, `CodingKeys`, `ConversationTool`, `CodingKeys`, `VLMError`, `LiveActivityObstacleGlance`, `HazardWatchPolicy`, `ActionRateLimit`, `.invalidateReadiness`, `.sighting`, `GrokBotClient`, `AudioRouteMonitor`, `HandsFreeIntents.swift`, `AppIntent`, `View`, `SensorProbe.swift`, `FrameReplay`, `HazardsCard`, `CampusDestination`, `Settings`, `CueKind`, `.portDescription`?**
  _High betweenness centrality (0.517) - this node is a cross-community bridge._
- **Why does `AppModel` connect `AppModel` to `TripLogger`, `NavSupportTests.swift`, `BeaconEngine`, `FallDetector`, `LiveActivityController`, `docs/README.md`, `HapticPlayer`, `NavigationEngine`, `VoiceInputEngine`, `SpeechQueue`, `DepthEngine`, `.say`, `.describe`, `HazardScanner`, `.scenePhaseChanged`, `FaceYawTracker`, `FamilyAlerts`, `TripTracker`, `SupabaseClient`, `ActionRateLimit`, `String`, `PhoneWatchLink`, `RouteSource.swift`, `AudioRouteMonitor`, `ObstacleClass`, `HazardRecord`, `HeadNodDetector`, `Settings`, `CueKind`, `SignPolicy`, `AlertContext`, `FamilyContactsTests.swift`, `LocationService`, `CueDecider`, `.handle`, `TorchSwitch`, `ConversationCoordinator`, `SoundWatcher`, `CueRules`, `DualCameraSession`?**
  _High betweenness centrality (0.179) - this node is a cross-community bridge._
- **Why does `CaneKit code reference` connect `CaneKit code reference` to `Module: ui-tests-build — Phone UI, XCUITests, XcodeGen build, CI`, `Module `depth-haptics` — `ios/CaneKit/Depth/*.swift`, `ios/CaneKit/Haptics/HapticPlayer.swift``, `Module `navigation-trip` — GPS, waypoint engine, turn settling, route sources, trip log/tracker, Live Activity`, `docs/README.md`, `Module: speech-audio-scene (`ios/CaneKit/Speech`, `ios/CaneKit/Audio`, `ios/CaneKit/Scene`)`, `Module `family-alerts` — cane events → the Grok Bot routine (Step 39)`, `Module: logic — `ios/Logic` (SwiftPM package `CaneKitLogic`)`, `Module `watch-widget-shared``?**
  _High betweenness centrality (0.076) - this node is a cross-community bridge._
- **Are the 24 inferred relationships involving `AppModel` (e.g. with `FallWatcher` and `FamilyAlerts`) actually correct?**
  _`AppModel` has 24 INFERRED edges - model-reasoned connections that need verification._
- **What connects `.name`, `.isSupported`, `.isConfigured` to the rest of the system?**
  _908 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `AppModel` be split into smaller, more focused modules?**
  _Cohesion score 0.1111111111111111 - nodes in this community are weakly interconnected._