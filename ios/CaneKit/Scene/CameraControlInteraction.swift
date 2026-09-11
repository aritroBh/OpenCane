//
//  CameraControlInteraction.swift
//  CaneKit
//
//  Camera Control button (iPhone 16+) and volume buttons via AVCaptureEventInteraction.
//  Apple only delivers these events to apps "actively performing capture"; whether an
//  ARKit-owned camera counts is unverified, so step 2 is a spike: the handler records the
//  event so the debug view can show whether it ever fires. If it never does, delete this file
//  and rely on the Action button, the watch, and the on-screen button.
//

import AVKit
import SwiftUI
import UIKit

/// Attach once anywhere in the view tree: `.background(CameraControlInteraction { … })`.
struct CameraControlInteraction: UIViewRepresentable {
    /// Called on the main actor on a press (`.began`); releases are ignored.
    var onPress: () -> Void

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

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onPress = onPress
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPress: onPress) }

    @MainActor
    final class Coordinator {
        var onPress: () -> Void
        var interaction: AVCaptureEventInteraction?
        init(onPress: @escaping () -> Void) { self.onPress = onPress }
    }
}
