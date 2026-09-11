//
//  TripLogger.swift
//  CaneKit
//
//  JSONL log of everything that matters for reproducing a walk: lane depths, trust, the cue that
//  fired, GPS, heading, thermal, battery, speech. One file per session in the app's Documents
//  folder (visible in the Files app; AirDrop it after a test). Buffered on the main actor and
//  flushed every 2 s so it never touches the depth queue.
//

import CaneKitLogic
import Foundation
import Observation

@MainActor
@Observable
final class TripLogger {

    /// Master switch (settings). Off by default outdoors to save battery? No — logs are cheap;
    /// default on so no test walk is ever lost.
    var enabled = true {
        didSet { if !enabled { flush() } }
    }
    private(set) var fileName = ""
    private(set) var linesWritten = 0

    @ObservationIgnored private var handle: FileHandle?
    @ObservationIgnored private var buffer = ""
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var lastLaneLog: TimeInterval = 0
    @ObservationIgnored private let t0 = Date()

    /// Lane reports are logged at most this often (Hz); cues and events are always logged.
    var laneRate: Double = 2

    init() {}

    // MARK: Session

    func start() {
        guard handle == nil else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        fileName = "canekit-\(stamp).jsonl"
        let url = URL.documentsDirectory.appendingPathComponent(fileName)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        event("session", ["file": fileName, "device": ProcessInfo.processInfo.hostName])
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.flush()
            }
        }
    }

    func stop() {
        flushTask?.cancel()
        flush()
        try? handle?.close()
        handle = nil
    }

    // MARK: Writers

    /// Throttled lane snapshot.
    func lanes(_ r: LaneReport, cue: CueKind, thermal: String, battery: Int) {
        guard enabled, r.timestamp - lastLaneLog >= 1.0 / laneRate else { return }
        lastLaneLog = r.timestamp
        event("lanes", [
            "ar_t": Self.num(r.timestamp),          // ARKit's monotonic clock, for cue correlation
            "head": r.head.map(Self.num), "torso": r.torso.map(Self.num),
            "trusted": r.isTrusted, "omega": Self.num(r.rotationRate),
            "cue": cue.rawValue, "thermal": thermal, "battery": battery,
            "mesh": r.centerHit.map { "\($0.classification)" } ?? "",
        ])
    }

    /// Any discrete happening: cue fired, waypoint reached, speech line, error…
    func event(_ kind: String, _ fields: [String: Any] = [:]) {
        guard enabled else { return }
        var obj: [String: Any] = ["t": Self.num(Date().timeIntervalSince(t0)), "kind": kind]
        for (k, v) in fields { obj[k] = v }
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let line = String(data: data, encoding: .utf8) else { return }
        buffer += line + "\n"
        linesWritten += 1
        if buffer.count > 16_384 { flush() }
    }

    /// Write buffered lines now (called on background/suspend so nothing is lost).
    func flush() {
        guard !buffer.isEmpty, let handle else { return }
        if let data = buffer.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
        buffer.removeAll(keepingCapacity: true)
    }

    /// Finite numbers only; JSON has no infinity.
    private static func num(_ f: Float) -> Double { f.isFinite ? Double((f * 100).rounded() / 100) : -1 }
    private static func num(_ d: Double) -> Double { d.isFinite ? (d * 1000).rounded() / 1000 : -1 }
}
