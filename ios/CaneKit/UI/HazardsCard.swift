//
//  HazardsCard.swift
//  CaneKit
//
//  "Hazards" card: the camera's second job made visible. Toggles for the hazard sources
//  (LiDAR drop-offs / potholes / curbs, sign reading, hazard watch, naming people), the last thing
//  each one said, which backend the hazard watch uses, the hazard-map count with a share button,
//  and an optional live camera view for the sighted spotter and the demo video: `LiveCameraView`,
//  ARKit's own frames on the GPU at the camera's frame rate (it replaced a ~3 Hz JPEG refresh loop).
//
//  "Both cameras (pauses obstacle detection)" (step 14) is the one control in the app that
//  switches the safety channel off: it shows the front and back cameras together through
//  `AVCaptureMultiCamSession`, which means ARKit — and therefore depth, the obstacle lanes, ground
//  hazards and sign reading — is paused. It is off by default, never persisted, refused while a
//  route is guiding, spoken out loud on the way in and on the way out, and its caption stays
//  visible to VoiceOver. ⚠ Never make this quieter.
//
//  Two more sensors live here (step 14), both **off by default**:
//    · "Listen for sirens and horns" — the microphone, through Apple's built-in sound classifier
//      (`SoundWatcher`). It is the only feature that moves the app off its single `.playback`
//      audio session, so its status rows say out loud when it refused to run.
//    · "Head tracking without AirPods" — the **front** camera's face anchor, running beside the
//      back camera's LiDAR. The row under the live view reports what the front camera is
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

import CaneKitLogic
import SwiftUI

struct HazardsCard: View {
    @Environment(AppModel.self) private var model
    /// Backgrounded or locked: ARKit is paused, so the preview must not show a frozen frame.
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        CKCard(title: "Hazards") {
            Toggle("Detect drop-offs", isOn: $model.groundHazardsEnabled)
                .font(CKFont.body).foregroundStyle(CKColor.textPrimary)
                .accessibilityHint("LiDAR warns about curbs, holes and drop-offs 1.5 to 3.5 meters ahead")
            Toggle("Read signs", isOn: $model.signsEnabled)
                .font(CKFont.body).foregroundStyle(CKColor.textPrimary)
                .accessibilityHint("Reads signs like sidewalk closed or detour, on the phone, offline")
            Toggle("Hazard watch", isOn: $model.hazardWatchEnabled)
                .font(CKFont.body).foregroundStyle(CKColor.textPrimary)
                .accessibilityHint("While walking a route, checks the path for cones, barriers and scooters every 8 seconds")
            Toggle("Name people ahead", isOn: $model.namePeopleEnabled)
                .font(CKFont.body).foregroundStyle(CKColor.textPrimary)
                .accessibilityHint("When you ask where am I, says how many people are ahead, which way and how far")

            HStack(spacing: CKSpacing.sm) {
                CKStatusPill(text: model.hazards.watchProvider, tone: .neutral, systemImage: "eye",
                             spoken: "Hazard watch uses \(model.hazards.watchProvider)")
                CKStatusPill(text: "\(model.hazardLog.records.count) mapped", tone: .neutral,
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
                .accessibilityHint("Shares a GeoJSON map of every hazard found on this walk")
            }

            Toggle("Listen for sirens and horns", isOn: $model.dangerSoundsEnabled)
                .font(CKFont.body).foregroundStyle(CKColor.textPrimary)
                .disabled(!SoundWatcher.isAvailable)
                .accessibilityHint("Uses the microphone to warn about sirens, horns and vehicle sounds. Needs the microphone, so it is off by default.")
            soundStatus

            // Off by default and not persisted (`AppModel.nodToTalkEnabled`): the gesture is untuned.
            // Disabled without headphone motion support — the nod comes from the AirPods.
            Toggle("Nod to talk", isOn: $model.nodToTalkEnabled)
                .font(CKFont.body).foregroundStyle(CKColor.textPrimary)
                .disabled(!model.head.isAvailable)
                .accessibilityHint("Nod twice with AirPods on while walking a route to start talking to OpenCane. Off by default.")

            Toggle("Head tracking without AirPods", isOn: $model.faceHeadTrackingEnabled)
                .font(CKFont.body).foregroundStyle(CKColor.textPrimary)
                .disabled(!DepthEngine.supportsFrontCameraWithLiDAR)
                .accessibilityHint("Uses the front camera to follow your head direction, so the beacon works without AirPods")

            Toggle("Live camera view", isOn: $model.liveViewEnabled)
                .font(CKFont.body).foregroundStyle(CKColor.textPrimary)
                .accessibilityHint("Shows what the camera sees, for a sighted helper")
            liveView
            frontCameraReadout

            Toggle("Both cameras (pauses obstacle detection)", isOn: $model.bothCamerasEnabled)
                .font(CKFont.body).foregroundStyle(CKColor.textPrimary)
                .disabled(!DualCameraSession.isSupported || model.routeStartWaiting)
                .accessibilityHint("Shows the front and back cameras at the same time for a sighted helper. While it is on, obstacle warnings, depth and hazard detection stop. It cannot be used while a route is guiding you.")
            bothCameras
            Toggle("Flashlight", isOn: Binding(get: { model.torchEnabled },
                                               set: { model.setTorch($0) }))
                .font(CKFont.body).foregroundStyle(CKColor.textPrimary)
                .accessibilityHint("Turns the back-camera flashlight on or off. Works while a route guides and while both cameras are on. Off at every launch.")
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
            .disabled(model.selfTestRunning || model.routeStartWaiting)
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
            liveCaption("Both cameras cannot run while a route is guiding you.")
        case .unsupported:
            // No picture on this path, and the caption says exactly that: the app has no
            // single-camera fallback, and `AppModel.setBothCameras` refuses before pausing
            // anything, so obstacle detection keeps running. (The `.unsupported` case was called
            // `backOnly` and was documented as showing the back camera; nothing ever did.)
            liveCaption("This phone cannot show two cameras at once, so the two-camera view is not available.")
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
                Text("Head direction only — ARKit gives one camera picture at a time, and it is the back camera's.")
                    .font(CKFont.secondary).foregroundStyle(CKColor.textSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Front camera is detecting \(model.faceHead.readout). Head direction only; no front camera picture.")
        }
    }

    /// Under the "Live camera view" switch: nothing when off; a caption while the phone is hot
    /// (the view is optional, the lanes are not) or while ARKit is not running; else the GPU
    /// `LiveCameraView` of the app's own ARSession at the camera's frame rate (30, or 60 with the
    /// Mount card switch), in the camera's 3:4 portrait shape so the whole frame shows. The
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

    /// Small grey line standing in for the live view (hot / camera off); hidden from VoiceOver
    /// like the view itself. Called only by `liveView`.
    private func liveCaption(_ text: String) -> some View {
        Text(text).font(CKFont.secondary).foregroundStyle(CKColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(text)   // a paused view or a dead camera must be spoken (Muse review)
    }

    /// One detection row: a small caption and the spoken line.
    private func detection(_ source: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CKSpacing.sm) {
            Text(source.uppercased()).font(CKFont.pill).foregroundStyle(CKColor.textSecondary)
            Text(text).font(CKFont.body).foregroundStyle(CKColor.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}
