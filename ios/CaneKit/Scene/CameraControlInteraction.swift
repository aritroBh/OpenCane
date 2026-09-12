//
//  CameraControlInteraction.swift
//  CaneKit
//
//  Camera Control button (iPhone 16+) and volume buttons via AVCaptureEventInteraction.
//  Apple only delivers these events to apps "actively performing capture"; whether an
//  ARKit-owned camera counts is unverified, so step 2 is a spike: every press is logged by
//  `AppModel.cameraControlPressed()` as a trip-log `describe {source: cameraControl}` record and
//  then treated as "Where am I". (The debug footer that used to count presses on screen was
//  removed in Step 11; the trip log is the only readout now.) If a device log never shows that
//  record, delete this file and rely on the Action button, the watch, and the on-screen button.
//
//  Owner / caller: `ContentView.body` attaches it once as a `.background` of the root
//  `NavigationStack`, so it is installed for as long as the app's UI is on screen.
//  Tests: none automated — the simulator has no Camera Control and no capture events; the only
//  evidence is a device trip log (grep `cameraControl`).
//
//  Threading / isolation: main actor throughout (module default; a `UIViewRepresentable` and its
//  coordinator live on main). `AVCaptureEventInteraction` calls its handler on the main thread,
//  so the handler reads the coordinator directly with no hop. The coordinator indirection lets
//  SwiftUI refresh `onPress` in `updateUIView` without rebuilding the interaction.
//
//  Side effect to know about: while enabled, the interaction also claims the volume buttons'
//  capture events, which may stop them changing volume while this view is on screen (i.e. the
//  whole foreground session, since it hangs off the root view) — part of what the spike has to
//  evaluate.
//

import AVKit
import SwiftUI
import UIKit

/// Attach once anywhere in the view tree: `.background(CameraControlInteraction { … })`.
/// Used by `ContentView`, which forwards presses to `AppModel.cameraControlPressed()`
/// (logs `describe {source: cameraControl}`, then `describeScene()`).
struct CameraControlInteraction: UIViewRepresentable {
    /// Called on the main actor on a press (`.began`); releases are ignored.
    var onPress: () -> Void

    /// Builds an invisible, non-interactive host view carrying the capture-event interaction.
    /// The handler reaches the latest `onPress` through the coordinator.
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        let interaction = AVCaptureEventInteraction { event in
            // AVCaptureEvent phases: .began / .ended / .cancelled. We act on the press.
            guard event.phase == .began else { return }
            context.coordinator.onPress()
        }
        interaction.isEnabled = true
        view.addInteraction(interaction)
        context.coordinator.interaction = interaction
        return view
    }

    /// SwiftUI re-render: swap in the new closure; the interaction is untouched.
    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onPress = onPress
    }

    /// One coordinator per representable instance, seeded with the initial closure.
    func makeCoordinator() -> Coordinator { Coordinator(onPress: onPress) }

    /// Holds the current press handler and keeps a reference to the interaction.
    @MainActor
    final class Coordinator {
        /// Latest press handler from SwiftUI; called from the interaction's handler on main.
        var onPress: () -> Void
        /// The installed interaction (retained here for its lifetime / future toggling). Set once by
        /// `makeUIView`; nothing reads it today.
        var interaction: AVCaptureEventInteraction?
        /// Seeds the coordinator with the closure from the first `makeCoordinator` call.
        /// - Parameter onPress: the press handler; replaced on every `updateUIView`.
        init(onPress: @escaping () -> Void) { self.onPress = onPress }
    }
}
