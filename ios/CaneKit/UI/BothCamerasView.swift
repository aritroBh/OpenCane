//
//  BothCamerasView.swift
//  CaneKit
//
//  The two-up picture: the back camera filling the frame with the **front** (selfie) camera in a
//  corner inset, both live at once. This is the only place in CaneKit where two camera images are
//  on screen, and it exists because `AVCaptureMultiCamSession` — not ARKit — is the API that can
//  do it (see DualCameraSession.swift for the measurements that settled that).
//
//  How: a plain `UIView` whose layer hosts the two `AVSampleBufferDisplayLayer`s owned by
//  `DualCameraSession`, which enqueues `AVCaptureVideoDataOutput` buffers into them. No SwiftUI
//  redraw is involved in the video path and no pixel is copied on the CPU — the renderer takes
//  each sample buffer straight to the GPU, the same spirit as `LiveCameraView` for ARKit's own
//  frames. `layoutSubviews` places them from `BothCamerasLayout` (CaneKitLogic), so the inset
//  geometry is pinned by tests instead of being magic numbers in a view.
//
//  ⚠ Deliberately **not** `AVCaptureVideoPreviewLayer`: Apple Developer Forums thread 742501
//  reports LiDAR depth delivery going unreliable once a preview layer joins a session that also
//  produces depth, and depth is this app's safety channel. See DualCameraSession.swift.
//
//  It is a spotter / demo feature: while it is on, ARKit is paused and the obstacle lanes, depth
//  and hazard detection are off. `AppModel` says that out loud when the mode starts and again when
//  it ends. This view is hidden from VoiceOver (a picture carries nothing for a blind walker); the
//  spoken warning and the switch's own label carry the meaning.
//
//  Threading / isolation: the struct and the coordinator-free `UIView` subclass are main-actor
//  (module default). `AVSampleBufferDisplayLayer` is a `CALayer`, so all of this is main-actor
//  work; nothing here touches the capture queues.
//
//  Caller: `HazardsCard.bothCameras`.
//

import AVFoundation
import CaneKitLogic
import SwiftUI
import UIKit

/// Hosts `DualCameraSession`'s two preview layers: back camera full-frame, front camera inset.
struct BothCamerasView: UIViewRepresentable {

    /// The live two-camera session (`AppModel.bothCameras`). Displayed only: this view never
    /// starts or stops it — `AppModel` does, together with pausing and resuming ARKit.
    let session: DualCameraSession

    /// Builds the hosting view and hands it the two layers.
    func makeUIView(context: Context) -> DualPreviewHostView {
        let view = DualPreviewHostView()
        view.attach(back: session.backLayer, front: session.frontLayer)
        view.isUserInteractionEnabled = false        // a preview, not a control
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        return view
    }

    /// Nothing to push on a SwiftUI re-render: the layers are the same objects for the life of the
    /// session, and their contents come from the capture pipeline.
    func updateUIView(_ uiView: DualPreviewHostView, context: Context) {}

    /// Detach the layers so the session can be reused if the switch goes off and on again without
    /// leaving a dead view holding them.
    static func dismantleUIView(_ uiView: DualPreviewHostView, coordinator: ()) {
        uiView.detach()
    }
}

/// `UIView` that lays out two video layers: one filling it, one inset in a corner.
///
/// A `UIView` subclass rather than layout in SwiftUI because `AVSampleBufferDisplayLayer` is a
/// `CALayer` and must be positioned in `layoutSubviews`; SwiftUI has no frame to give it.
@MainActor
final class DualPreviewHostView: UIView {

    /// The full-frame layer (back camera), or nil before `attach`.
    private var back: AVSampleBufferDisplayLayer?
    /// The inset layer (front camera), or nil before `attach`.
    private var front: AVSampleBufferDisplayLayer?

    /// Put both layers into this view's layer tree. The front layer goes on top, with a rounded
    /// corner and a hairline border so the inset reads as a second camera and not as an artefact.
    func attach(back: AVSampleBufferDisplayLayer, front: AVSampleBufferDisplayLayer) {
        self.back = back
        self.front = front
        layer.addSublayer(back)
        front.cornerRadius = CGFloat(BothCamerasLayout.insetCornerRadius)
        front.masksToBounds = true
        front.borderWidth = 1
        front.borderColor = UIColor.white.withAlphaComponent(0.7).cgColor
        layer.addSublayer(front)
        setNeedsLayout()
    }

    /// Remove both layers from this view (the session keeps owning them).
    func detach() {
        back?.removeFromSuperlayer()
        front?.removeFromSuperlayer()
        back = nil
        front = nil
    }

    /// Back camera fills the view; front camera sits in the bottom-trailing corner at
    /// `BothCamerasLayout.insetWidthFraction` of the width, in the camera's 3:4 portrait shape.
    override func layoutSubviews() {
        super.layoutSubviews()
        back?.frame = bounds
        let rect = BothCamerasLayout.insetRect(width: bounds.width, height: bounds.height)
        front?.frame = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }
}
