//
//  LiveCameraView.swift
//  CaneKit
//
//  The Hazards card's "Live camera view": ARKit's own camera frames drawn on the GPU at the
//  camera's frame rate (30 fps, or 60 with the Mount card's "60 fps camera" switch), for a sighted
//  helper and the demo video. Replaces a ~3 Hz JPEG refresh loop that looked choppy and cost a
//  CPU encode per frame.
//
//  How: a `UIViewRepresentable` around `ARSCNView` whose `session` is the app's single ARSession,
//  owned by `DepthEngine` (`depth.arSession`). The view only *displays* that session: it never
//  runs or pauses it and never touches `session.delegate` / `delegateQueue` — `DepthEngine` owns
//  the lifecycle and its `SessionObserver` must stay the delegate (frames feed the obstacle lanes).
//  Evidence (headless probes in the iOS 27 simulator, 2026-09-11): assigning an ARSession whose
//  delegate and delegateQueue were set to `ARSCNView.session` left both identical, also after the
//  view was deallocated; a fresh ARSCNView's own session has a nil delegate (the view is not a
//  session delegate, it observes the session internally); and an `ARSession` subclass saw no
//  `run` / `pause` call while the view was created, shown in a window, removed and freed.
//
//  No scene content and no lighting work: only the camera background. Automatic lighting, camera
//  grain and motion blur are off, and the coordinator returns nil for every anchor, so the
//  hundreds of mesh anchors from scene reconstruction get no SceneKit nodes.
//
//  Threading / isolation: the struct is main-actor (module default). `Coordinator` is
//  `nonisolated` because SceneKit calls `ARSCNViewDelegate` on its render thread; it holds no
//  state, so it is trivially safe there.
//
//  Built only while the switch is on and the phone is cool and ARKit is running
//  (`LiveView.state`, CaneKitLogic, pinned by LiveViewTests); hidden from VoiceOver (it carries
//  nothing a blind user needs). Caller: `HazardsCard.liveView`.
//

import ARKit
import SceneKit
import SwiftUI
import UIKit

/// GPU camera preview of an externally owned `ARSession`. Used only by `HazardsCard` while
/// "Live camera view" is on; SwiftUI builds the `ARSCNView` when this appears and frees it when
/// the switch goes off, the phone gets hot, or ARKit stops (backgrounding).
struct LiveCameraView: UIViewRepresentable {
    /// The app's one session (`DepthEngine.arSession`). Displayed only; never run, paused or
    /// delegated from here.
    let session: ARSession
    /// Render rate, equal to the camera's frame rate (`LiveView.live(fps:)`): drawing faster than
    /// the camera delivers frames would only add heat.
    let framesPerSecond: Int

    /// Builds the `ARSCNView`: attaches the shared session, turns off every optional render effect,
    /// installs the anchor-ignoring coordinator, and hides it from touches and VoiceOver.
    /// `ARSCNView.init` allocates a default `ARSession` object of its own; it is never run (no
    /// camera, nil delegate) and the view's strong reference to it is replaced by the shared one.
    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero, options: nil)
        view.session = session                       // display only: delegate + queue untouched
        view.delegate = context.coordinator          // weak; ignores every anchor (no nodes)
        view.automaticallyUpdatesLighting = false    // no light nodes from light estimates
        view.rendersCameraGrain = false              // no content to add grain to
        view.rendersMotionBlur = false               // default, stated for the reader
        view.preferredFramesPerSecond = framesPerSecond
        view.isUserInteractionEnabled = false        // a preview, not a control
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true      // HazardsCard also sets accessibilityHidden
        return view
    }

    /// SwiftUI re-render: follow the camera rate when the Mount card's 60 fps switch flips
    /// (`DepthEngine.setHighFrameRate` re-runs the session; the view keeps drawing it).
    func updateUIView(_ uiView: ARSCNView, context: Context) {
        if uiView.preferredFramesPerSecond != framesPerSecond {
            uiView.preferredFramesPerSecond = framesPerSecond
        }
    }

    /// View torn down (switch off, hot, backgrounded): drop the delegate so the render thread
    /// never calls a released coordinator. The session is left exactly as it was (not paused).
    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        // Stop rendering and let go of the shared session *before* the view dies, so SceneKit's
        // render thread cannot touch it mid-frame (Muse review: a teardown with live mesh anchers
        // risked a render-thread crash or an interrupted session, which would silence the lanes).
        // `isPlaying = false` stops the view's rendering only; the ARSession keeps running for the
        // depth pipeline. The throwaway session is never run.
        uiView.isPlaying = false
        uiView.scene = SCNScene()
        uiView.session = ARSession()
        uiView.delegate = nil
    }

    /// One stateless coordinator per view, used as the `ARSCNViewDelegate`.
    func makeCoordinator() -> Coordinator { Coordinator() }

    /// `ARSCNViewDelegate` that returns nil for every anchor: "If nil is returned the anchor will
    /// be ignored" (ARSCNView.h), so mesh / world anchors add no SceneKit nodes and the view draws
    /// only the camera background. `nonisolated` because SceneKit calls it on its render thread;
    /// stateless, so nothing crosses threads. It is the *view's* delegate, not the session's.
    nonisolated final class Coordinator: NSObject, ARSCNViewDelegate {
        /// No node for any anchor (keeps the scene empty). Called by SceneKit's render thread.
        func renderer(_ renderer: any SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? { nil }
    }
}
