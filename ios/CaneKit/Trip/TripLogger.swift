//
//  TripLogger.swift
//  CaneKit
//
//  JSONL log of everything that matters for reproducing a walk: lane depths, trust, the cue that
//  fired, GPS, heading, thermal, battery, speech. One file per session in the app's Documents
//  folder (visible in the Files app; AirDrop it after a test). Buffered on the main actor and
//  flushed every 2 s so it never touches the depth queue.
//
//  Owner: `AppModel.logger` (one instance); `start()` once from `AppModel.start()`, events from
//  AppModel's cue router, navigation wiring, route start/stop and watch commands. Module
//  `navigation-trip` in docs/CODE_REFERENCE.md (record kinds and fields are tabled there).
//
//  Threading / isolation: `@MainActor @Observable`. All writes happen on main; file I/O is a
//  small buffered append every 2 s (or at 16 K characters, or on background / disable).
//
//  Key invariants:
//    · Every line is one JSON object with `t` (seconds since logger creation, wall clock) and
//      `kind`. `ar_t` fields are the ARKit clock — a different clock; correlate lane/cue records
//      via `ar_t` and nav records via `t`.
//    · JSON has no NaN/infinity: numbers go through `num`, and invalid objects are dropped.
//    · `lanes` records stay throttled (`laneRate`); the depth pipeline reports at ~15 Hz.
//  ⚠ Do not rename `kind` values or fields without updating any log-analysis tooling; no test
//  covers the logger — verify by AirDropping a file after a device walk.
//

import CaneKitLogic
import Foundation
import Observation

/// Buffered JSONL writer for the per-session trip log.
@MainActor
@Observable
final class TripLogger {

    /// Master switch (settings). Off by default outdoors to save battery? No — logs are cheap;
    /// default on so no test walk is ever lost.
    /// Mirrors `AppModel.loggingEnabled`; turning it off flushes what is buffered.
    var enabled = true {
        didSet { if !enabled { flush() } }
    }
    /// `canekit-<ISO 8601, ':' → '-'>.jsonl` in Documents; empty until `start()`.
    private(set) var fileName = ""
    /// Lines appended this session (buffered or written), for the debug UI.
    private(set) var linesWritten = 0

    /// Open write handle; nil before `start()` / after `stop()` (events then only buffer).
    @ObservationIgnored private var handle: FileHandle?
    /// Pending JSONL text not yet written to disk.
    @ObservationIgnored private var buffer = ""
    /// The 2 s periodic flush loop.
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// AR-clock timestamp of the last `lanes` record (throttle baseline).
    @ObservationIgnored private var lastLaneLog: TimeInterval = 0
    /// Logger creation time; every record's `t` is seconds since this.
    @ObservationIgnored private let t0 = Date()

    /// Lane reports are logged at most this often (Hz); cues and events are always logged.
    var laneRate: Double = 2

    /// Opens nothing; the file is created in `start()`.
    init() {}

    // MARK: Session

    /// Creates this session's file, writes a `session` record and starts the 2 s flush loop.
    /// Idempotent (`guard handle == nil`). If the file cannot be opened, events still buffer but
    /// are never written.
    func start() {
        guard handle == nil else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        fileName = "canekit-\(stamp).jsonl"
        let url = URL.documentsDirectory.appendingPathComponent(fileName)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        // (`hostName` does a blocking reverse-DNS lookup on the main thread — never use it here.)
        event("session", ["file": fileName, "os": ProcessInfo.processInfo.operatingSystemVersionString])
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.flush()
            }
        }
    }

    /// Stops the flush loop, writes what is buffered and closes the file.
    func stop() {
        flushTask?.cancel()
        flush()
        try? handle?.close()
        handle = nil
    }

    // MARK: Writers

    /// Throttled lane snapshot.
    /// Called for every depth report by `AppModel.handle(_:)`; writes at most `laneRate` per second
    /// of AR clock. Depths in metres (2 dp, −1 = invalid), `omega` in rad/s, `cue` = active kind.
    func lanes(_ r: LaneReport, cue: CueKind, thermal: String, battery: Int, fps: Double = 0) {
        guard enabled, r.timestamp - lastLaneLog >= 1.0 / laneRate else { return }
        lastLaneLog = r.timestamp
        event("lanes", [
            "ar_t": Self.num(r.timestamp),          // ARKit's monotonic clock, for cue correlation
            "head": r.head.map(Self.num), "torso": r.torso.map(Self.num),
            "trusted": r.isTrusted, "omega": Self.num(r.rotationRate),
            "cue": cue.rawValue, "thermal": thermal, "battery": battery,
            "mesh": r.centerHit.map { "\($0.classification)" } ?? "",
            // Mount aim (deg below horizon, MountTilt) and published depth rate, for tuning
            // from the log now that there is no on-screen debug footer.
            "tilt": r.cameraTiltDownDeg.map { Self.num(Double($0)) } ?? NSNull(),
            "fps": Self.num(fps),
        ])
    }

    /// Any discrete happening: cue fired, waypoint reached, speech line, error…
    /// Appends `{"t", "kind", …fields}` to the buffer (a field named `t` or `kind` would win);
    /// flushes early past 16 K characters. Silently drops objects `JSONSerialization` rejects
    /// (e.g. a NaN passed without `num`). No-op while disabled.
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
    /// Also called by the 2 s loop, `stop()` and when logging is disabled. Keeps the buffer when
    /// there is no open handle.
    func flush() {
        guard !buffer.isEmpty, let handle else { return }
        if let data = buffer.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
        buffer.removeAll(keepingCapacity: true)
    }

    /// Finite numbers only; JSON has no infinity.
    /// `Float` → 2 decimal places (depths), `Double` → 3 (times, rates); non-finite → −1.
    private static func num(_ f: Float) -> Double { f.isFinite ? Double((f * 100).rounded() / 100) : -1 }
    /// See `num(_: Float)`: 3 decimal places, non-finite → −1.
    private static func num(_ d: Double) -> Double { d.isFinite ? (d * 1000).rounded() / 1000 : -1 }
}
