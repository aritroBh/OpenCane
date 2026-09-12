//
//  FrameReplay.swift
//  CaneKit
//
//  Simulator-only camera stand-in for end-to-end tests: when the app is launched with
//  `CANEKIT_FRAME_DIR=<folder>`, the "camera frame" the sign reader, hazard watch, "Where am I"
//  and the conversational assistant receive (everything that goes through
//  `DepthFrameProcessor.jpegSnapshot` / `jpegSnapshotWithDepth`) is the image in that folder taken
//  nearest to the current simulated GPS fix. The GPU "Live camera view" (`LiveCameraView`) draws
//  ARKit directly and never sees these frames. Feed it Google Street View captures of the route
//  (ios/scripts/streetview/) and the GPS replay (`make e2e SCENARIO=streetview`: the clean path
//  with these frames as the camera) walks the real app past the real corners.
//
//  Folder layout: `frames.json` = [{"file": "wp3_approach.jpg", "lat": 40.10905, "lon": -88.22372,
//  "heading": 267}, …] next to the images. `heading` is documentation only: the decoder reads
//  `file` / `lat` / `lon`, and the nearest frame wins whatever way the walker faces.
//
//  Compiled into every build but inert outside the simulator (`isActive` is false on a device, so
//  the real ARKit camera is always used on the phone). Threading: `nonisolated`, state behind a
//  Mutex; `update` is called from the main actor on each fix, `jpeg()` from the depth-processor /
//  `@concurrent` snapshot paths.
//
//  Replay frames carry no LiDAR: `jpegSnapshotWithDepth` pairs them with `DepthSnapshot.empty`, so
//  "Where am I" gives directions without distances. `hasCameraFrame` is always true while active.
//  Callers: `AppModel` (`location.onFix` → `update`), `DepthFrameProcessor` (`jpeg`,
//  `isActive`), `SceneDescriber` / `HazardScanner` (`currentName` → trip-log `frame`).
//  Tests: `make uitest-streetview` (`CaneKitUITests.testWhereAmIDescribesAStreetViewFrame`) and
//  `make e2e SCENARIO=streetview` (`ios/scripts/e2e.py`, `SIMCTL_CHILD_CANEKIT_FRAME_DIR`).
//

import CaneKitLogic
import Foundation
import Synchronization

/// Street View frames standing in for the camera in simulator runs; a no-op singleton everywhere
/// else. `Sendable` is real (not `@unchecked`): `isActive` is immutable and all mutable state lives
/// in one `Mutex`.
nonisolated final class FrameReplay: Sendable {

    /// The one instance, configured once from the environment on first use.
    static let shared = FrameReplay()

    /// One replay image: its file and the GPS coordinate it was captured at.
    private struct Frame: Sendable { let url: URL; let at: Coordinate }
    /// Everything that changes after init, guarded by `state`.
    private struct State: Sendable {
        /// Every frame from `frames.json`, in file order.
        var frames: [Frame] = []
        /// Latest simulated fix (`update`); starts at the first frame's coordinate.
        var position: Coordinate?
        /// JPEG bytes already read from disk, per file. Never evicted (a route's worth of frames);
        /// a failed read stores nil, which removes the key, so it is retried on the next call.
        var cache: [URL: Data] = [:]
    }
    /// The mutable state; every access (including the disk read in `jpeg()`) holds this lock.
    private let state = Mutex(State())
    /// True only in the simulator with `CANEKIT_FRAME_DIR` set and a readable frames.json.
    let isActive: Bool

    /// Reads `CANEKIT_FRAME_DIR` and `frames.json` once. Any missing piece (no variable, unreadable
    /// or empty JSON, or a device build) leaves the replay inactive rather than failing.
    private init() {
        #if targetEnvironment(simulator)
        guard let dir = ProcessInfo.processInfo.environment["CANEKIT_FRAME_DIR"] else { isActive = false; return }
        let base = URL(fileURLWithPath: dir, isDirectory: true)
        struct Entry: Decodable { let file: String; let lat: Double; let lon: Double }
        guard let data = try? Data(contentsOf: base.appendingPathComponent("frames.json")),
              let entries = try? JSONDecoder().decode([Entry].self, from: data), !entries.isEmpty else {
            isActive = false
            return
        }
        let frames = entries.map { Frame(url: base.appendingPathComponent($0.file),
                                         at: Coordinate(latitude: $0.lat, longitude: $0.lon)) }
        state.withLock { $0.frames = frames; $0.position = frames.first?.at }
        isActive = true
        #else
        isActive = false
        #endif
    }

    /// Current simulated position (AppModel's `location.onFix`, every fix, main actor). No-op
    /// while inactive, so the device pays one Bool check per fix.
    func update(position: Coordinate) {
        guard isActive else { return }
        state.withLock { $0.position = position }
    }

    /// File name of the frame nearest to the current position (trip-log diagnostics: the `frame`
    /// field of `scan`, `hazard_watch` and `describe_result`), or nil when replay is off.
    /// Nearest = minimum `GeoMath.distanceMeters`, ties to the earlier frame in the file.
    var currentName: String? {
        guard isActive else { return nil }
        return state.withLock { s in
            guard let p = s.position else { return nil }
            return s.frames.min(by: { GeoMath.distanceMeters($0.at, p) < GeoMath.distanceMeters($1.at, p) })?
                .url.lastPathComponent
        }
    }

    /// JPEG bytes of the frame nearest to the current position (cached after the first read), or
    /// nil when inactive or the file cannot be read. Returned as stored: no resize, no rotation, so
    /// callers' `maxDimension` / `quality` do not apply. Any thread.
    func jpeg() -> Data? {
        guard isActive else { return nil }
        return state.withLock { s -> Data? in
            guard let p = s.position,
                  let nearest = s.frames.min(by: { GeoMath.distanceMeters($0.at, p) < GeoMath.distanceMeters($1.at, p) })
            else { return nil }
            if let hit = s.cache[nearest.url] { return hit }
            let data = try? Data(contentsOf: nearest.url)
            s.cache[nearest.url] = data
            return data
        }
    }
}
