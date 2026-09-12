//
//  MultiCamDepthProbe.swift
//  CaneKit
//
//  Answers one question and writes the answer into the trip log: **could a future CaneKit show the
//  front and the back camera at once and still have a depth stream?**
//
//  Why it matters. The shipped "Both cameras" mode pauses ARKit, and it has to: ARKit can never
//  deliver two camera images (Apple DTS, developer forums thread 677731 — "there is no
//  ARConfiguration that will enable you to receive both the front and rear camera image"; `ARFrame`
//  has one `capturedImage`). That means the walker loses obstacle detection while the spotter view
//  is on, which is a bad trade to leave permanent. The escape route, if it exists, is AVFoundation
//  rather than ARKit: Apple DTS (forums thread 702875) blesses `builtInLiDARDepthCamera` inside an
//  `AVCaptureMultiCamSession`, and WWDC22 session 110429 says AVFoundation streams LiDAR depth up
//  to 320×240 — higher than ARKit's 256×192 `sceneDepth`. Both are claims about other people's
//  devices, and AGENTS.md ("How we engineer", rule 1) does not allow acting on those, so this file
//  measures it on the phone in hand.
//
//  What it does **not** do: it does not run a session, does not touch a camera, and changes
//  nothing at run time. It reads `AVCaptureDevice.DiscoverySession.supportedMultiCamDeviceSets`
//  and the devices' format lists — pure capability introspection, a few milliseconds, no camera
//  permission needed — and hands `AppModel` a record. The depth pipeline is untouched: the answer
//  is for the next design decision, not for this build.
//
//  Trip log: one `multicam_depth` record. ⚠ Its field names avoid `kind` and `t`, which belong to
//  the record itself (`TripLogRecord` renames a colliding field to `field_kind` / `field_t`, and
//  `ios/scripts/e2e.py` fails a run that contains one).
//
//  Threading / isolation: `nonisolated`, because the module default is main-actor and this must
//  run off it — `supportedMultiCamDeviceSets` enumerates every camera on the device and has no
//  business on the main thread at launch. It returns Sendable values only; the verdict itself is
//  `MultiCamDepth` in CaneKitLogic, with tests.
//
//  Caller: `AppModel.start()`, in a detached task, once per launch.
//

import AVFoundation
import CaneKitLogic
import CoreMedia
import Foundation

/// Reads what this phone's cameras could do together, without starting anything.
nonisolated enum MultiCamDepthProbe {

    /// One measurement, ready for the trip log. Sendable so it can cross back to the main actor.
    struct Result: Sendable {
        /// The numbers the verdict is computed from (CaneKitLogic).
        let findings: MultiCamDepthFindings
        /// Human-readable summary of each supported multi-cam device set, e.g.
        /// "back:LiDAR(depth 320x240)+front:TrueDepth". Empty on a phone without multi-cam.
        let deviceSets: [String]
        /// The best depth-capable multi-cam video format on the back depth camera, as
        /// "video 1920x1440 depth 320x240", or "" when there is none.
        let bestFormat: String

        /// Trip-log fields. ⚠ No field may be called `kind` or `t` (see the file header).
        var logFields: [String: Any] {
            [
                "multicam_supported": findings.multiCamSupported,
                "front_plus_depth_sets": findings.frontPlusDepthDeviceSets,
                "depth_multicam_formats": findings.depthCapableMultiCamFormats,
                "best_depth_size": "\(findings.bestDepthWidth)x\(findings.bestDepthHeight)",
                "arkit_depth_size": "\(MultiCamDepth.arkitSceneDepthWidth)x\(MultiCamDepth.arkitSceneDepthHeight)",
                "verdict": MultiCamDepth.verdict(findings).rawValue,
                "keeps_depth": MultiCamDepth.verdict(findings).keepsDepth,
                "answer": MultiCamDepth.sentence(findings),
                "device_sets": deviceSets,
                "best_format": bestFormat,
            ]
        }
    }

    /// Camera types worth asking about: the LiDAR depth camera (the one that matters), the plain
    /// wide angles, and the TrueDepth front camera. Virtual devices (dual / triple) are included
    /// because a multi-cam device set may name them rather than their constituent cameras.
    private static let deviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInLiDARDepthCamera, .builtInTrueDepthCamera, .builtInWideAngleCamera,
        .builtInUltraWideCamera, .builtInDualCamera, .builtInDualWideCamera, .builtInTripleCamera,
    ]

    /// Measure. Safe to call at any time; does not start a session or ask for permission.
    /// - Returns: the findings, the device sets in words, and the best depth-capable format.
    static func measure() -> Result {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            return Result(findings: MultiCamDepthFindings(multiCamSupported: false,
                                                          frontPlusDepthDeviceSets: 0,
                                                          depthCapableMultiCamFormats: 0,
                                                          bestDepthWidth: 0, bestDepthHeight: 0),
                          deviceSets: [], bestFormat: "")
        }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video,
                                                        position: .unspecified)
        var setDescriptions: [String] = []
        var frontPlusDepthSets = 0
        for set in discovery.supportedMultiCamDeviceSets {
            var hasFront = false
            var hasDepthCapableBack = false
            var parts: [String] = []
            for device in set.sorted(by: { $0.uniqueID < $1.uniqueID }) {
                let best = bestDepthFormat(of: device)
                if device.position == .front { hasFront = true }
                if device.position == .back, best != nil { hasDepthCapableBack = true }
                let depth = best.map { " depth \(dimensionText($0.depth))" } ?? ""
                parts.append("\(positionName(device.position)):\(device.deviceType.rawValue)\(depth)")
            }
            if hasFront, hasDepthCapableBack { frontPlusDepthSets += 1 }
            setDescriptions.append(parts.joined(separator: "+"))
        }

        // The back depth camera itself: how many of its formats are multi-cam *and* depth capable,
        // and what the widest depth map among them measures.
        let backDepthDevice = discovery.devices.first { $0.position == .back && $0.deviceType == .builtInLiDARDepthCamera }
            ?? discovery.devices.first { $0.position == .back && bestDepthFormat(of: $0) != nil }
        var depthFormats = 0
        var bestWidth = 0
        var bestHeight = 0
        var bestFormat = ""
        if let backDepthDevice {
            for format in backDepthDevice.formats where format.isMultiCamSupported {
                guard let depth = largestDepthFormat(of: format) else { continue }
                depthFormats += 1
                let dimensions = CMVideoFormatDescriptionGetDimensions(depth.formatDescription)
                if Int(dimensions.width) * Int(dimensions.height) > bestWidth * bestHeight {
                    bestWidth = Int(dimensions.width)
                    bestHeight = Int(dimensions.height)
                    bestFormat = "video \(dimensionText(format)) depth \(dimensionText(depth))"
                }
            }
        }

        let findings = MultiCamDepthFindings(multiCamSupported: true,
                                             frontPlusDepthDeviceSets: frontPlusDepthSets,
                                             depthCapableMultiCamFormats: depthFormats,
                                             bestDepthWidth: bestWidth, bestDepthHeight: bestHeight)
        return Result(findings: findings, deviceSets: setDescriptions, bestFormat: bestFormat)
    }

    /// The device's best multi-cam-capable format that also carries depth, with the largest depth
    /// map that format offers — nil when the device has none.
    /// - Parameter device: any camera from the discovery session.
    private static func bestDepthFormat(of device: AVCaptureDevice)
        -> (video: AVCaptureDevice.Format, depth: AVCaptureDevice.Format)? {
        var best: (video: AVCaptureDevice.Format, depth: AVCaptureDevice.Format)?
        for format in device.formats where format.isMultiCamSupported {
            guard let depth = largestDepthFormat(of: format) else { continue }
            let candidate = CMVideoFormatDescriptionGetDimensions(depth.formatDescription)
            guard let current = best else { best = (format, depth); continue }
            let currentDimensions = CMVideoFormatDescriptionGetDimensions(current.depth.formatDescription)
            if Int(candidate.width) * Int(candidate.height)
                > Int(currentDimensions.width) * Int(currentDimensions.height) {
                best = (format, depth)
            }
        }
        return best
    }

    /// Largest `supportedDepthDataFormats` entry of one video format, or nil when it has none.
    /// A non-empty `supportedDepthDataFormats` is what "this format can stream depth" means.
    /// - Parameter format: one `AVCaptureDevice.Format`.
    private static func largestDepthFormat(of format: AVCaptureDevice.Format) -> AVCaptureDevice.Format? {
        format.supportedDepthDataFormats.max { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return Int(da.width) * Int(da.height) < Int(db.width) * Int(db.height)
        }
    }

    /// "1920x1440" for a format, for the log.
    private static func dimensionText(_ format: AVCaptureDevice.Format) -> String {
        let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return "\(d.width)x\(d.height)"
    }

    /// "front" / "back" / "unspecified".
    private static func positionName(_ position: AVCaptureDevice.Position) -> String {
        switch position {
        case .front: return "front"
        case .back: return "back"
        case .unspecified: return "unspecified"
        @unknown default: return "unknown"
        }
    }
}
