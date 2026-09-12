//
//  MeshClassifier.swift
//  CaneKit
//
//  Names what is straight ahead: takes the centre-window depth, projects it into world space
//  along the camera's forward axis, then finds the nearest classified face across the
//  ARMeshAnchors within reach. Runs on the depth queue, throttled by the processor to every 8th
//  published report (`ProcessorSettings.meshEveryNthFrame`: ≈ 3.75 Hz at 30 Hz, 7.5 Hz at 60 Hz).
//
//  Step 2 shipped the geometry; step 4 wired the result into speech ("Two meters ahead, door")
//  through `LaneReport.centerHit` → `ObstacleNamer` (trusted frames only). Since Step 36 the spoken
//  names are **off by default** (`AppModel.obstacleNamesEnabled`), but the lookup still runs while
//  mesh classification is on: the hit also feeds the on-device describer's LiDAR context line
//  ("The obstacle ahead looks like a door."). The thermal watchdog turns mesh (and this lookup)
//  off at `.serious` or worse.
//
//  Tests: none can build an `ARMeshAnchor`; `mappingVerified` asserts the class table in debug
//  builds, and the rest is verified on the phone with mesh on.
//
//  Threading / isolation: a `nonisolated` caseless enum of static, stateless functions. The only
//  caller is `DepthFrameProcessor.session(_:didUpdate:)` on the depth queue, so the `ARFrame` and
//  its mesh buffers are read on the thread ARKit delivered them on and never escape. Output is
//  a Sendable `MeshHit` value.
//
//  Invariants: the lookup is bounded (`faceBudget`) so a dense mesh cannot starve the queue;
//  the reported distance is the *depth* (`centerDepth`), not the face distance — the mesh only
//  names the thing, LiDAR depth says how far. The world is gravity-aligned (DepthEngine config).
//

import ARKit
import CaneKitLogic
import simd

/// Nearest classified mesh face to the point straight ahead of the camera. Namespace only.
nonisolated enum MeshClassifier {

    /// Max distance (m) from the projected point to a face centroid to count as a hit.
    static let maxFaceDistance: Float = 0.25
    /// Anchors whose origin is farther than this from the point are skipped without scanning faces.
    /// Metres; the actual test uses `anchorReach + 1.0`, slack for mesh chunks whose faces extend
    /// well past the anchor's origin.
    static let anchorReach: Float = 2.5
    /// Hard cap on faces visited per lookup so a dense mesh can never stall the depth queue.
    /// Counts sampled faces (every 3rd), across all anchors.
    static let faceBudget = 30_000

    /// `ObstacleClass` mirrors `ARMeshClassification` by raw value (0 none … 7 door). Checked once
    /// at runtime in debug builds so an SDK reorder cannot silently mislabel doors as seats.
    /// Lazily evaluated on the first `nearestFace` call (`_ = mappingVerified`); `assert` is
    /// compiled out in release, where the value is computed but unused.
    static let mappingVerified: Bool = {
        let pairs: [(ARMeshClassification, ObstacleClass)] = [
            (.none, .none), (.wall, .wall), (.floor, .floor), (.ceiling, .ceiling),
            (.table, .table), (.seat, .seat), (.window, .window), (.door, .door),
        ]
        let ok = pairs.allSatisfy { $0.rawValue == $1.rawValue }
        assert(ok, "ARMeshClassification raw values no longer match ObstacleClass")
        return ok
    }()

    /// Classify what is straight ahead: project `centerDepth` metres along the camera's forward
    /// axis into world space and return the class of the nearest sampled face centroid within
    /// `maxFaceDistance`, with `distance = centerDepth`.
    ///
    /// Returns nil when the depth is out of the 0.1–5 m window, no classified mesh anchor is near,
    /// or no sampled face centroid is within 25 cm. The winning face's class byte is read at
    /// `f * classification.stride`; an unknown raw value is skipped, and an `ObstacleClass` with no
    /// matching case becomes `.none`. Anchors are visited in `frame.anchors` order, so once
    /// `faceBudget` runs out the remaining anchors are not scanned at all. The camera's forward axis is
    /// used even in portrait (the lens axis does not rotate with the device). Runs on the depth
    /// queue; called every `meshEveryNthFrame`th published frame.
    /// - Parameters:
    ///   - centerDepth: median depth of the image-centre window (m); `.infinity` → nil.
    ///   - frame: the current ARFrame (anchors + camera).
    static func nearestFace(to centerDepth: Float, in frame: ARFrame) -> MeshHit? {
        guard centerDepth.isFinite, centerDepth > 0.1, centerDepth < 5 else { return nil }

        // World-space point `centerDepth` metres in front of the camera (camera looks down -Z).
        let cam = frame.camera.transform
        let forward = -simd_make_float3(cam.columns.2.x, cam.columns.2.y, cam.columns.2.z)
        let origin = simd_make_float3(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
        let p = origin + forward * centerDepth

        var best: (dist: Float, cls: ARMeshClassification)?
        var visited = 0
        _ = mappingVerified

        for anchor in frame.anchors {
            guard visited < faceBudget else { break }
            guard let mesh = anchor as? ARMeshAnchor else { continue }
            let a = mesh.transform
            let anchorOrigin = simd_make_float3(a.columns.3.x, a.columns.3.y, a.columns.3.z)
            guard simd_distance(anchorOrigin, p) < anchorReach + 1.0 else { continue }
            guard let classification = mesh.geometry.classification else { continue }

            let faces = mesh.geometry.faces
            let verts = mesh.geometry.vertices
            let faceCount = faces.count
            guard faces.indexCountPerPrimitive == 3, faceCount > 0 else { continue }

            let idxBytes = faces.bytesPerIndex
            let facePtr = faces.buffer.contents()
            let vertPtr = verts.buffer.contents().advanced(by: verts.offset)
            let clsPtr = classification.buffer.contents().advanced(by: classification.offset)

            // Sample every 3rd face: the mesh is dense and we only need a centroid within 25 cm.
            var f = 0
            while f < faceCount, visited < faceBudget {
                visited += 1
                var centroid = SIMD3<Float>(repeating: 0)
                for k in 0..<3 {
                    let off = (f * 3 + k) * idxBytes
                    let vi: Int = idxBytes == 4
                        ? Int(facePtr.load(fromByteOffset: off, as: UInt32.self))
                        : Int(facePtr.load(fromByteOffset: off, as: UInt16.self))
                    // Vertices are packed float3 (12-byte stride); SIMD3<Float> is 16 bytes, so
                    // read the three components individually to avoid a misaligned over-read.
                    let base = vertPtr.advanced(by: vi * verts.stride)
                    let v = SIMD3<Float>(base.load(fromByteOffset: 0, as: Float.self),
                                         base.load(fromByteOffset: 4, as: Float.self),
                                         base.load(fromByteOffset: 8, as: Float.self))
                    centroid += v
                }
                centroid /= 3
                let world4 = a * SIMD4<Float>(centroid, 1)
                let world = simd_make_float3(world4.x, world4.y, world4.z)
                let d = simd_distance(world, p)
                if d < maxFaceDistance, best == nil || d < best!.dist {
                    let raw = clsPtr.load(fromByteOffset: f * classification.stride, as: UInt8.self)
                    if let cls = ARMeshClassification(rawValue: Int(raw)) {
                        best = (d, cls)
                    }
                }
                f += 3
            }
        }

        guard let best else { return nil }
        return MeshHit(classification: ObstacleClass(rawValue: best.cls.rawValue) ?? .none,
                       distance: centerDepth)
    }
}
