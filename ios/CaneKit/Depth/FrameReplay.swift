//
//  FrameReplay.swift
//  CaneKit
//
//  Simulator-only camera stand-in for end-to-end tests: when the app is launched with
//  `CANEKIT_FRAME_DIR=<folder>`, the "camera frame" the sign reader, hazard watch, "Where am I"
//  and the live view receive is the image in that folder taken nearest to the current simulated
//  GPS fix. Feed it Google Street View captures of the route (ios/scripts/streetview/) and the
//  GPS replay (`make e2e SCENARIO=streetview`: the clean path with these frames as the camera)
//  walks the real app past the real corners.
//
//  Folder layout: `frames.json` = [{"file": "wp3_approach.jpg", "lat": 40.10905, "lon": -88.22372,
//  "heading": 267}, …] next to the images.
//
//  Compiled into every build but inert outside the simulator (`isActive` is false on a device, so
//  the real ARKit camera is always used on the phone). Threading: `nonisolated`, state behind a
//  Mutex; `update` is called from the main actor on each fix, `jpeg()` from the depth-processor /
//  `@concurrent` snapshot paths.
//

import CaneKitLogic
import Foundation
import Synchronization

nonisolated final class FrameReplay: Sendable {

    static let shared = FrameReplay()

    private struct Frame: Sendable { let url: URL; let at: Coordinate }
    private struct State: Sendable {
        var frames: [Frame] = []
        var position: Coordinate?
        var cache: [URL: Data] = [:]
    }
    private let state = Mutex(State())
    /// True only in the simulator with `CANEKIT_FRAME_DIR` set and a readable frames.json.
    let isActive: Bool

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

    /// Current simulated position (AppModel, every fix).
    func update(position: Coordinate) {
        guard isActive else { return }
        state.withLock { $0.position = position }
    }

    /// File name of the frame nearest to the current position (trip-log diagnostics), or nil
    /// when replay is off.
    var currentName: String? {
        guard isActive else { return nil }
        return state.withLock { s in
            guard let p = s.position else { return nil }
            return s.frames.min(by: { GeoMath.distanceMeters($0.at, p) < GeoMath.distanceMeters($1.at, p) })?
                .url.lastPathComponent
        }
    }

    /// JPEG bytes of the frame nearest to the current position (cached after the first read).
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
