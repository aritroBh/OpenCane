//
//  TripLogger.swift
//  CaneKit
//
//  JSONL log of everything that matters for reproducing a walk: lane depths, trust, the cue that
//  fired, GPS, heading, thermal, battery, speech. One file per session in the app's Documents
//  folder (visible in the Files app; AirDrop it after a test). Buffered on the main actor and
//  flushed every 2 s so it never touches the depth queue.
//
//  Owner: `AppModel.logger` (one instance); `start()` once from `AppModel.start()`, `flush()` on
//  `scenePhaseChanged(.background)`, events from almost every AppModel wiring (cue router,
//  navigation, route start/stop, watch commands, speech queue callbacks, describer, hazards,
//  sound watcher, torch, both cameras) and, through `onEvent` closures, from `VoiceInputEngine`
//  and `ConversationCoordinator`. Module `navigation-trip` in docs/CODE_REFERENCE.md (record
//  kinds and fields are tabled there). Readers: `ios/scripts/e2e.py` (asserts on it, and fails a
//  run that contains `field_kind`) and `ios/scripts/cue_audit.py` (Step 35 cue-load audit).
//  `stop()` has no caller today: the file stays open for the life of the process, and the 2 s
//  loop plus the background flush are what get lines onto disk.
//
//  Threading / isolation: `@MainActor @Observable`. All writes happen on main; file I/O is a
//  small buffered append every 2 s (or at 16 K characters, or on background / disable).
//
//  Key invariants:
//    · Every line is one JSON object with `t` (seconds since logger creation, wall clock) and
//      `kind`; no field can replace either (`TripLogRecord`, tested in CaneKitLogic). `ar_t`
//      fields are the ARKit clock — a different clock; correlate lane/cue records via `ar_t` and
//      nav records via `t`.
//    · JSON has no NaN/infinity: numbers go through `num`, and invalid objects are dropped.
//    · `lanes` records stay throttled (`laneRate`); the depth pipeline reports at ~30 Hz normal / up to 60 Hz high-rate.
//  Tests: ⚠ only the record assembly is unit-tested (`TripLogRecordTests`,
//  `fieldsNeverOverwriteTheRecordTimeOrKind`). Do not rename `kind` values or fields without
//  updating the log-analysis tooling (`ios/scripts/e2e.py`, `ios/scripts/cue_audit.py`) — verify the
//  file itself by AirDropping it after a device walk.
//

import CaneKitLogic
import Foundation
import Observation

/// Buffered JSONL writer for the per-session trip log.
@MainActor
@Observable
final class TripLogger {

    /// Master switch (settings "Write trip log"). Default on even though it costs a little
    /// battery: logs are cheap, and a test walk with no log cannot be analysed afterwards.
    /// Mirrors `AppModel.loggingEnabled` (set in `AppModel.init` and on every toggle); turning it
    /// off flushes what is buffered. While off, `event` and `lanes` drop records (not buffered).
    var enabled = true {
        didSet { if !enabled { flush() } }
    }
    /// `canekit-<ISO 8601, ':' → '-'>.jsonl` in Documents; empty until `start()`. Written into the
    /// `session` record; no view reads it today.
    private(set) var fileName = ""
    /// Lines appended this session (buffered or written; counted even if the handle never opened).
    /// No view reads it today (the on-screen debug footer that showed it is gone).
    private(set) var linesWritten = 0

    /// Open write handle; nil before `start()` / after `stop()` (events then only buffer).
    @ObservationIgnored private var handle: FileHandle?
    /// Pending JSONL text not yet written to disk (one `\n`-terminated line per record). Lost if the
    /// process is killed between flushes — at most ~2 s of records.
    @ObservationIgnored private var buffer = ""
    /// The 2 s periodic flush loop (main-actor Task); cancelled by `stop()`.
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// AR-clock timestamp of the last `lanes` record (throttle baseline). Starts at 0, so the first
    /// report after launch is always logged. Assumes a monotonic report clock: a timestamp lower
    /// than this value would silence `lanes` until the clock passes it again.
    @ObservationIgnored private var lastLaneLog: TimeInterval = 0
    /// Logger creation time (`AppModel` init, i.e. app launch); every record's `t` is seconds since this.
    @ObservationIgnored private let t0 = Date()

    /// Called for every record that reaches the file, so the cloud copy holds the same lines as
    /// the JSONL (`CloudSync.logEvent`). Set once by `AppModel.init`; nil means no mirror.
    ///
    /// ⚠ Must stay a cheap, synchronous append — it runs inside `event(_:_:)`, which runs on the
    /// cue path. `CloudSync` queues and flushes on its own 5 s loop for exactly that reason.
    /// A record dropped by the `enabled` guard or by invalid JSON is not handed over either: the
    /// hook sees what the file sees.
    @ObservationIgnored var onRecord: ((_ kind: String, _ t: Double, _ fields: [String: Any]) -> Void)?

    /// Lane reports are logged at most this often (Hz); cues and events are always logged.
    /// The throttle is `1 / laneRate` seconds (0.5 s), so 0 would stop `lanes` records entirely.
    /// No caller changes it.
    var laneRate: Double = 2

    /// Opens nothing; the file is created in `start()`.
    init() {}

    // MARK: Session

    /// Creates this session's file, writes a `session` record (`file`, `os`) and starts the 2 s
    /// flush loop. Idempotent (`guard handle == nil`) — but only once the handle opened: if the file
    /// cannot be opened, events still buffer (and grow) but are never written, and a second call
    /// would make a new file name and a second flush loop. Called once, from `AppModel.start()`.
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

    /// Stops the flush loop, writes what is buffered and closes the file. No caller today (see the
    /// file header); after it, events buffer in memory and a new `start()` opens a new file.
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
    /// - Parameters:
    ///   - r: the report (`timestamp` is the ARKit clock, logged as `ar_t`).
    ///   - cue: `AppModel.activeCue`.
    ///   - thermal: `ProcessInfo.ThermalState` name.
    ///   - battery: percent, −1 unknown.
    ///   - fps: `DepthEngine.fps`, the published depth rate.
    func lanes(_ r: LaneReport, cue: CueKind, thermal: String, battery: Int, fps: Double = 0) {
        guard enabled, r.timestamp - lastLaneLog >= 1.0 / laneRate else { return }
        lastLaneLog = r.timestamp
        event("lanes", [
            "ar_t": Self.num(r.timestamp),          // ARKit's monotonic clock, for cue correlation
            "head": r.head.map(Self.num), "torso": r.torso.map(Self.num),
            // Step 48 evidence for the point-blank hold: blind share per cell (0…1, 2 dp) and
            // how many cells the hold substituted this frame (a count, not which — the held cells
            // are the ones reading 0.1 / 0.8 m beside a high blind share; see NearHold.swift).
            "head_blind": r.grid.headBlind.map { Self.num(Double(($0 * 100).rounded() / 100)) },
            "torso_blind": r.grid.torsoBlind.map { Self.num(Double(($0 * 100).rounded() / 100)) },
            "held": r.grid.headHeld.filter { $0 }.count + r.grid.torsoHeld.filter { $0 }.count,
            "trusted": r.isTrusted, "depth": r.depthAvailable,
            "tracking_normal": r.trackingNormal, "omega": Self.num(r.rotationRate),
            "frame_seq": r.frameSequence,
            "cue": cue.rawValue, "thermal": thermal, "battery": battery,
            "mesh": r.centerHit.map { "\($0.classification)" } ?? "",
            // Mount aim (deg below horizon, MountTilt) and published depth rate, for tuning
            // from the log now that there is no on-screen debug footer.
            "tilt": r.cameraTiltDownDeg.map { Self.num(Double($0)) } ?? NSNull(),
            "fps": Self.num(fps),
            // Step 51: how the bands were cut ("rows" before ARKit has a pose, else "metric") and
            // whether the camera can see each band per lane (L/C/R) at the 150 cm cover range —
            // `cue_audit.py`'s `share_head_cover`. A NO COVER cell logs `head` −1 like a clear one.
            "bands": r.grid.bandMode.rawValue,
            "head_cover": r.grid.headCoverage,
            "torso_cover": r.grid.torsoCoverage,
        ])
    }

    /// Any discrete happening: cue fired, waypoint reached, speech line, error…
    /// Appends `{"t", "kind", …fields}` to the buffer. A field can never replace the record's
    /// `t` or `kind`: `TripLogRecord.make` (CaneKitLogic, `fieldsNeverOverwriteTheRecordTimeOrKind`)
    /// keeps a colliding field as `field_t` / `field_kind` (the 2026-09-11 phone log had hazard
    /// records turned into `"kind": "sign"` that way). Flushes early past 16 K characters.
    /// Silently drops objects `JSONSerialization` rejects (e.g. a NaN passed without `num`).
    /// No-op while disabled. `t` is wall-clock seconds since `t0` (3 dp).
    /// - Parameters:
    ///   - kind: the record type (`gps`, `speech`, `route`, … — tabled in docs/CODE_REFERENCE.md).
    ///   - fields: JSON-serialisable values only (String, numbers, Bool, NSNull, arrays and
    ///     dictionaries of those); never name one `t` or `kind` on purpose.
    func event(_ kind: String, _ fields: [String: Any] = [:]) {
        guard enabled else { return }
        let t = Self.num(Date().timeIntervalSince(t0))
        let obj = TripLogRecord.make(t: t, kind: kind, fields: fields)
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let line = String(data: data, encoding: .utf8) else { return }
        buffer += line + "\n"
        linesWritten += 1
        // The cloud mirror sees exactly the records the file does — after the `enabled` guard and
        // after the JSON validity check, never before.
        onRecord?(kind, t, fields)
        if buffer.count > 16_384 { flush() }
    }

    /// Write buffered lines now (called on background/suspend so nothing is lost).
    /// Also called by the 2 s loop, `stop()`, `event` past 16 K characters and when logging is
    /// disabled. Keeps the buffer when there is no open handle. A failed write is ignored (`try?`)
    /// and the buffer is cleared anyway, so those lines are lost rather than retried.
    /// Caller outside this class: `AppModel.scenePhaseChanged(.background)`.
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
