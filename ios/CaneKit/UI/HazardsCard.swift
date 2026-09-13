//
//  HazardsCard.swift
//  CaneKit
//
//  "Hazards" card: the camera's second job made visible. Toggles for the hazard sources
//  (LiDAR drop-offs / potholes / curbs, sign reading, hazard watch, naming people), the last thing
//  each one said, which backend the hazard watch uses, the hazard-map count with a share button,
//  and an optional live camera view for the sighted spotter and the demo video: `LiveCameraView`,
//  ARKit's own frames on the GPU at up to 30 fps (it replaced a ~3 Hz JPEG refresh loop).
//
//  "Both cameras (pauses obstacle detection)" (step 14) is the one control in the app that
//  switches the safety channel off: it shows the front and back cameras together through
//  `AVCaptureMultiCamSession`, which means ARKit — and therefore depth, the obstacle lanes, ground
//  hazards and sign reading — is paused. It is off by default, never persisted, refused while a
//  route is guiding, spoken out loud on the way in and on the way out, and its caption stays
//  visible to VoiceOver. ⚠ Never make this quieter.
//
//  Three more sensor switches live here, all **off by default** (the first two from step 14):
//    · "Listen for sirens and horns" — the microphone, through Apple's built-in sound classifier
//      (`SoundWatcher`). It is the only feature that moves the app off its single `.playback`
//      audio session, so its status rows say out loud when it refused to run.
//    · "Head tracking without AirPods" — the **front** camera's face anchor, running beside the
//      back camera's LiDAR. Not persisted, and refused while a route guides or starts
//      (`FaceTrackingChange`: switching it re-runs the AR session, ~1–2 s with no obstacle
//      frames). The row under the live view reports what the front camera is
//      *detecting* (face found, head yaw) and states in as many words that there is no front
//      camera picture: ARKit delivers one camera image per frame and it is the rear camera's.
//      Never re-word that row into something a reader could take for a selfie preview.
//    · "Nod to talk" (nod plan, step 3) — a double head nod on the AirPods starts voice input
//      (`HeadPoseTracker` → `HeadNodDetector` → `AppModel.startVoiceInput`). Off by default and
//      not persisted: the detector's thresholds are untuned placeholders.
//
//  Two debug buttons ("Both cameras self test", "Front camera self test") appear at the bottom of
//  the card **only** under `AppModel.selfTestControlsVisible` (a launch flag). They used to run by
//  themselves at launch, which stopped ARKit for ~13 s before the walker had touched anything; see
//  `selfTests` below.
//
//  Implements docs/design.md (cards, pills, toggles, big buttons). Accessibility: every toggle is
//  a labelled switch ("Detect drop-offs", "Read signs", "Hazard watch", "Name people ahead",
//  "Listen for sirens and horns", "Nod to talk", "Head tracking without AirPods", "Live camera
//  view", "Both cameras (pauses obstacle detection)", "Flashlight"); the live view and the two-camera picture are hidden from
//  VoiceOver (they carry nothing a blind user needs) but the front-camera readout is not — it is
//  the only proof a blind walker has that their head direction is being followed.
//
//  Owner / caller: `SensePage` in ContentView.swift (last card, after the obstacle grid).
//  Tests: the view decisions are pure — `LiveViewTests` (`LiveView.state`, `BothCameras.state`,
//  `FaceTrackingChange`, `BothCamerasLayout`), `HazardTests` (signs, hazard watch),
//  `SoundAlertsTests`, `HeadNodDetectorTests`. No XCUITest queries this card's strings yet, so
//  none is a test contract — keep them stable for VoiceOver users anyway.
//

import CaneKitLogic
import SwiftUI

/// "Hazards" card on the Sense page: every camera / microphone / head-motion hazard switch, the
/// last line each source spoke, the hazard map, and the two optional camera views. Reads and
/// binds `AppModel`; owns no state except the scene phase it observes.
struct HazardsCard: View {
    /// Source of every switch binding (`@Bindable` in `body`) and every status line shown here.
    @Environment(AppModel.self) private var model
    /// Backgrounded or locked: ARKit is paused, so the preview must not show a frozen frame.
    @Environment(\.scenePhase) private var scenePhase

    /// Top to bottom: Detect drop-offs (off by default), Read signs (on), Hazard watch (off), Name
    /// people ahead (off until cane validation); provider + "N mapped" pills; the last LiDAR / sign / watch lines; error;
    /// Share hazard map (once a file exists); Listen for sirens and horns + its status; Nod to talk;
    /// Head tracking without AirPods (+ refusal caption during a route or route start); Live
    /// camera view + the view + the front-camera readout; Both cameras + its block; Flashlight
    /// (binds through `AppModel.setTorch`, never refused); and the debug self tests when the
    /// launch flag is set.
    ///
    /// UI audit 2026-09-13: one card with eleven switches became three focused cards — "Hazards"
    /// (what to warn about, what was found, the map), "Hands-free" (nod, head tracking) and
    /// "Camera" (live view, both cameras, flashlight) — each switch a `CKToggleRow` with a plain
    /// subtitle. Switch labels, bindings, disabling and every refusal caption are unchanged.
    var body: some View {
        VStack(alignment: .leading, spacing: CKSpacing.xl) {
            hazardsCard
            handsFreeCard
            cameraCard
        }
    }

    /// "Hazards": the four detection switches, the provider / map pills, the last line from each
    /// source, the map share button, and the siren listener with its status.
    private var hazardsCard: some View {
        @Bindable var model = model
        return CKCard(title: "Hazards", systemImage: "exclamationmark.triangle",
                      caption: "What OpenCane warns you about beyond obstacles.") {
            CKToggleRow(title: "Detect drop-offs", subtitle: "Curbs, holes and steps 1.5–3.5 m ahead",
                        isOn: $model.groundHazardsEnabled,
                        hint: "Warns about curbs, holes and drop-offs 1.5 to 3.5 meters ahead")
            CKToggleRow(title: "Read signs", subtitle: "Like “Sidewalk closed” or “Detour”",
                        isOn: $model.signsEnabled,
                        hint: "Reads signs like sidewalk closed or detour, on the phone, offline")
            CKToggleRow(title: "Hazard watch", subtitle: "Looks for cones, barriers and scooters on a route",
                        isOn: $model.hazardWatchEnabled,
                        hint: "While walking a route, checks the path for cones, barriers and scooters every 8 seconds")
            CKToggleRow(title: "Name people ahead", subtitle: "Experimental — counts people when you ask Where am I",
                        isOn: $model.namePeopleEnabled,
                        hint: "Experimental and not yet tested on the cane. When you ask where am I, says how many people are ahead, which way and how far")
            liveCaption(PeopleDetection.state(enabled: model.namePeopleEnabled).userFacingDescription)

            CKRowDivider()
            HStack(spacing: CKSpacing.sm) {
                CKStatusPill(text: model.hazards.watchProvider, tone: .neutral, systemImage: "eye",
                             spoken: "Hazard watch uses \(model.hazards.watchProvider)")
                CKStatusPill(text: "\(model.hazardLog.records.count) on map", tone: .neutral,
                             systemImage: "mappin.and.ellipse",
                             spoken: "\(model.hazardLog.records.count) hazards on the map")
                Spacer(minLength: 0)
            }
            if let g = model.lastGroundHazard { detection("LiDAR", g) }
            if let s = model.hazards.lastSign { detection("Sign", s) }
            if let c = model.hazards.lastCaution { detection("Watch", c) }
            if let err = model.hazards.lastError ?? model.hazardLog.lastError {
                Text(err).font(CKFont.secondary).foregroundStyle(CKColor.laneUrgent)
            }
            if model.hazardLog.fileWritten {
                ShareLink(item: model.hazardLog.fileURL) {
                    Label("Share hazard map", systemImage: "square.and.arrow.up")
                        .font(CKFont.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: CKMetrics.touchTarget)
                }
                .buttonStyle(CKBigButtonStyle(role: .secondary))
                .accessibilityHint("Shares a map file of every hazard found on this walk")
            }

            CKRowDivider()
            CKToggleRow(title: "Listen for sirens and horns", subtitle: "Uses the microphone",
                        isOn: $model.dangerSoundsEnabled,
                        hint: "Uses the microphone to warn about sirens, horns and vehicle sounds. Needs the microphone, so it is off by default.")
                .disabled(!SoundWatcher.isAvailable)
            if !SoundWatcher.isAvailable {
                liveCaption("Siren and horn alerts aren't available on this phone.")
            }
            soundStatus
        }
    }

    /// "Hands-free": nod to talk and head tracking without AirPods, with their refusal captions.
    private var handsFreeCard: some View {
        @Bindable var model = model
        return CKCard(title: "Hands-free", systemImage: "hand.raised") {
            // Off by default and not persisted (`AppModel.nodToTalkEnabled`): the gesture is untuned.
            // Disabled without headphone motion support — the nod comes from the AirPods.
            CKToggleRow(title: "Nod to talk", subtitle: "Nod twice with AirPods in to start talking",
                        isOn: $model.nodToTalkEnabled,
                        hint: "Nod twice with AirPods on while walking a route to start talking to OpenCane. Off by default.")
                .disabled(!model.head.isAvailable)
            if !model.head.isAvailable {
                liveCaption("Connect AirPods that track head movement to use this.")
            }

            CKToggleRow(title: "Head tracking without AirPods", subtitle: "Uses the front camera to follow where you face",
                        isOn: $model.faceHeadTrackingEnabled,
                        hint: "Uses the front camera to follow your head direction, so the direction sound works without AirPods. Cannot change while a route is guiding you.")
                .disabled(!DepthEngine.supportsFrontCameraWithLiDAR)
            if !DepthEngine.supportsFrontCameraWithLiDAR {
                liveCaption("This phone can't use the front camera for head tracking.")
            } else if model.nav.isNavigating {
                liveCaption("Head tracking without AirPods can't change while a route is guiding you.")
            } else if model.routeStartWaiting {
                liveCaption("Head tracking without AirPods can't change while a route is starting.")
            }
            frontCameraReadout
        }
    }

    /// "Camera": live view, both cameras (with its safety caption), the flashlight, and the debug
    /// self tests when the launch flag is set.
    private var cameraCard: some View {
        @Bindable var model = model
        return CKCard(title: "Camera", systemImage: "camera") {
            CKToggleRow(title: "Live camera view", subtitle: "Shows what the camera sees, for a helper",
                        isOn: $model.liveViewEnabled,
                        hint: "Shows what the camera sees, for a sighted helper")
            liveView

            CKToggleRow(title: "Both cameras (pauses obstacle detection)",
                        subtitle: "For a helper. Obstacle warnings stop while it's on.",
                        isOn: $model.bothCamerasEnabled,
                        hint: "Shows the front and back cameras at the same time for a sighted helper. While it is on, obstacle warnings, depth and hazard detection stop. It cannot be used while a route is guiding you.")
                .disabled(!DualCameraSession.isSupported || model.routeStartWaiting)
            if !DualCameraSession.isSupported {
                liveCaption("This phone can't show two cameras at once.")
            }
            bothCameras
            CKToggleRow(title: "Flashlight", subtitle: "Off each time the app opens",
                        isOn: Binding(get: { model.torchEnabled }, set: { model.setTorch($0) }),
                        hint: "Turns the back-camera flashlight on or off. Works while a route guides and while both cameras are on. Off at every launch.")
            if AppModel.selfTestControlsVisible { selfTests }
        }
    }

    /// Debug-only measurement buttons, shown **only** when the app was launched with
    /// `--sensor-selftest` (or `CANEKIT_SENSOR_SELFTEST=1`) — never in the demo build.
    ///
    /// ⚠ These two self-tests used to run by themselves at the end of `AppModel.start()`, and the
    /// two-camera one pauses ARKit for 12 s. A tester who pressed "Where am I" during that window
    /// heard "Camera warming up. Try again." and concluded the app was broken. Nothing may take the
    /// safety channel away without the walker asking for it at that moment, so they are buttons
    /// now. Do not put them back on a launch path.
    @ViewBuilder private var selfTests: some View {
        VStack(alignment: .leading, spacing: CKSpacing.sm) {
            CKBigButton(title: "Both cameras self test", systemImage: "camera.on.rectangle",
                        role: .secondary,
                        hint: "Debug. Turns both cameras on for 12 seconds, which pauses obstacle detection, then turns them off and writes what happened to the trip log") {
                model.startBothCamerasSelfTest()
            }
            .disabled(model.selfTestRunning || model.nav.isNavigating || model.routeStartWaiting)
            CKBigButton(title: "Front camera self test", systemImage: "faceid", role: .secondary,
                        hint: "Debug. Runs the front camera head tracking for 15 seconds and writes what it saw to the trip log. Obstacle detection keeps running") {
                model.startFaceTrackingSelfTest()
            }
            .disabled(model.selfTestRunning || model.nav.isNavigating || model.routeStartWaiting)
            if !model.selfTestStatus.isEmpty {
                Text(model.selfTestStatus)
                    .font(CKFont.secondary).foregroundStyle(CKColor.textSecondary)
                    .accessibilityLabel(model.selfTestStatus)
            }
        }
    }

    /// The two-up picture and the warning that goes with it.
    ///
    /// The owner asked to *see* both cameras; ARKit cannot hand over two pictures (one
    /// `capturedImage` per frame, and it is the rear camera's), so this is an
    /// `AVCaptureMultiCamSession` and ARKit is paused while it runs. That is a real loss of the
    /// safety channel, so the state is spelled out in text next to the picture as well as spoken
    /// by `AppModel.setBothCameras` — and unlike the ARKit preview this block is **not** hidden
    /// from VoiceOver, because "your obstacle detection is off" is exactly what a blind user needs
    /// to hear. The decision is `BothCameras.state` (CaneKitLogic, pinned by LiveViewTests).
    @ViewBuilder private var bothCameras: some View {
        switch BothCameras.state(enabled: model.bothCamerasEnabled,
                                 supported: DualCameraSession.isSupported,
                                 navigating: model.nav.isNavigating,
                                 foreground: scenePhase == .active) {
        case .off:
            EmptyView()
        case .blockedByRoute:
            liveCaption("Both cameras cannot run while a route is guiding you. Stop the route on the Guide tab first.")
        case .unsupported:
            // No picture on this path, and the caption says exactly that: the app has no
            // single-camera fallback, and `AppModel.setBothCameras` refuses before pausing
            // anything, so obstacle detection keeps running. (The `.unsupported` case was called
            // `backOnly` and was documented as showing the back camera; nothing ever did.)
            liveCaption("This phone can't show two cameras at once, so this view isn't available.")
        case .live:
            VStack(alignment: .leading, spacing: CKSpacing.sm) {
                BothCamerasView(session: model.bothCameras)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)     // 4:3 sensor, portrait UI
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: CKRadius.button, style: .continuous))
                    .accessibilityHidden(true)                     // a picture, for a sighted helper
                Text(model.bothCameras.frontConnected
                     ? "Back camera with the front camera inset. Obstacle detection is paused."
                     : "Back camera only — the front camera could not be opened. Obstacle detection is paused.")
                    .font(CKFont.secondary).foregroundStyle(CKColor.laneUrgent)
                if let err = model.bothCameras.lastError {
                    Text(err).font(CKFont.secondary).foregroundStyle(CKColor.laneUrgent)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// Under the "Listen for sirens and horns" switch: the last sound announced, why the watch is
    /// not running, and how many of the labels this build looks for the phone's classifier has.
    /// All three are spoken rows (a blind walker must be able to hear that the feature is dead).
    @ViewBuilder private var soundStatus: some View {
        if let alert = model.sounds.lastAlert { detection("Sound", alert) }
        if let err = model.sounds.lastError {
            Text(err).font(CKFont.secondary).foregroundStyle(CKColor.laneUrgent)
                .accessibilityLabel(err)
        }
        if model.sounds.isRunning, !model.sounds.labelReport.isEmpty {
            Text(model.sounds.labelReport)
                .font(CKFont.secondary).foregroundStyle(CKColor.textSecondary)
                .accessibilityLabel("Sound watch: \(model.sounds.labelReport)")
        }
    }

    /// What the **front** camera is doing, in words — never a picture.
    ///
    /// ARKit hands the app exactly one camera image per frame and it is the rear camera's (Apple:
    /// "you still must choose one camera feed to show to the user at a time"; measured on this
    /// phone in `SensorProbe`, trip-log `probe_a_world_plus_face`). So the front camera cannot be
    /// shown next to the back camera — what it *can* do is detect the walker's face and head
    /// direction, and that is what this row reports, labelled "detecting" so nobody reads it as a
    /// selfie preview. Visible only while the front camera is actually enabled.
    @ViewBuilder private var frontCameraReadout: some View {
        if model.faceHeadTrackingEnabled, DepthEngine.supportsFrontCameraWithLiDAR {
            VStack(alignment: .leading, spacing: 2) {
                detection("Front camera", "detecting: \(model.faceHead.readout)")
                // Plain words, same meaning: it follows the head and shows no front picture.
                Text("Only follows where your head points — there is no front camera picture.")
                    .font(CKFont.secondary).foregroundStyle(CKColor.textSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Front camera is detecting \(model.faceHead.readout). Head direction only; no front camera picture.")
        }
    }

    /// Under the "Live camera view" switch: nothing when off; a caption while the phone is hot
    /// (the view is optional, the lanes are not) or while ARKit is not running or the app is not
    /// active; else the GPU `LiveCameraView` of the app's own ARSession at
    /// `CameraRate.previewFramesPerSecond` (30 — capped even when the Mount card's switch runs the
    /// camera at 60), in the camera's 3:4 portrait shape so the whole frame shows. The
    /// decision is `LiveView.state` (CaneKitLogic, pinned by LiveViewTests); the whole block is
    /// hidden from VoiceOver (it carries nothing a blind user needs).
    @ViewBuilder private var liveView: some View {
        switch LiveView.state(enabled: model.liveViewEnabled, hot: model.hazards.paused,
                              cameraRunning: model.depth.isRunning,
                              highFrameRate: model.highFrameRateCamera,
                              foreground: scenePhase == .active) {
        case .off:
            EmptyView()
        case .hot:
            liveCaption("Live view paused: phone is hot")
        case .cameraOff:
            liveCaption("Camera off")
        case .live(let fps):
            LiveCameraView(session: model.depth.arSession, framesPerSecond: fps)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)     // 4:3 sensor, portrait UI
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: CKRadius.button, style: .continuous))
                .accessibilityHidden(true)
        }
    }

    /// Small grey line explaining why a camera mode shows nothing: the live view while hot or with
    /// the camera off, the two-camera view while a route blocks it or the phone lacks multi-cam,
    /// and why head tracking without AirPods cannot change during a route. **Spoken** by VoiceOver
    /// (its `accessibilityLabel`) — a paused view or a refused mode is exactly what a blind user
    /// needs to hear. Callers: `liveView`, `bothCameras`, the head-tracking toggle row.
    private func liveCaption(_ text: String) -> some View {
        Text(text).font(CKFont.secondary).foregroundStyle(CKColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(text)   // a paused view or a dead camera must be spoken (Muse review)
    }

    /// One detection row: a small caption and the spoken line.
    /// Callers: the LiDAR / Sign / Watch rows in `body`, "Sound" in `soundStatus`, "Front camera"
    /// in `frontCameraReadout`. One combined VoiceOver element ("LIDAR, Two meters ahead, …").
    /// - Parameters:
    ///   - source: caption word, drawn uppercased in `CKFont.pill`.
    ///   - text: the line as it was spoken (or the readout).
    private func detection(_ source: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CKSpacing.sm) {
            Text(source.uppercased()).font(CKFont.pill).foregroundStyle(CKColor.textSecondary)
            Text(text).font(CKFont.body).foregroundStyle(CKColor.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}
