//
//  MeshClassifier.swift
//  CaneKit
//
//  Names what is straight ahead: takes the centre-window depth, projects it into world space
//  along the camera's forward axis, then finds the nearest classified face across the
//  ARMeshAnchors within reach. Runs on the depth queue, throttled to ~4 Hz by the processor.
//
//  Step 2 ships the geometry; step 4 wires the result into speech ("door ahead, two meters").
//

import ARKit
import CaneKitLogic
import simd

nonisolated enum MeshClassifier {

    /// Max distance (m) from the projected point to a face centroid to count as a hit.
    static let maxFaceDistance: Float = 0.25
    /// Anchors whose origin is farther than this from the point are skipped without scanning faces.
    static let anchorReach: Float = 2.5
    /// Hard cap on faces visited per lookup so a dense mesh can never stall the depth queue.
    static let faceBudget = 30_000

    /// `ObstacleClass` mirrors `ARMeshClassification` by raw value (0 none … 7 door). Checked once
    /// at runtime in debug builds so an SDK reorder cannot silently mislabel doors as seats.
    static let mappingVerified: Bool = {
        let pairs: [(ARMeshClassification, ObstacleClass)] = [
            (.none, .none), (.wall, .wall), (.floor, .floor), (.ceiling, .ceiling),
            (.table, .table), (.seat, .seat), (.window, .window), (.door, .door),
        ]
        let ok = pairs.allSatisfy { $0.rawValue == $1.rawValue }
        assert(ok, "ARMeshClassification raw values no longer match ObstacleClass")
        return ok
    }()

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
                    let v = vertPtr.advanced(by: vi * verts.stride).assumingMemoryBound(to: SIMD3<Float>.self).pointee
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
