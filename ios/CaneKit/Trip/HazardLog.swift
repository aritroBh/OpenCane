//
//  HazardLog.swift
//  CaneKit
//
//  The hazard map: every hazard the app announces (LiDAR drop-offs / potholes / curbs, signs,
//  vision-model cautions) is written with the current GPS fix — and the camera frame, when there
//  is one — to Documents/hazards/. `hazards-<session>.geojson` opens in geojson.io, QGIS, Google
//  My Maps or the Files preview; the JPEGs sit next to it. The pitch: every cane is a sidewalk
//  sensor, and these are the potholes and closures the maps have not caught up with.
//
//  Owner: `AppModel.hazardLog`. `record(...)` only from `AppModel.recordHazard` (LiDAR ground
//  hazards from `groundHazardFound` with a 768 px frame; sign and vision hazards from
//  `hazards.onHazard` with the scanner's frame). Read by `HazardsCard` (count, error line, share
//  button). The GeoJSON is rewritten whole on each record (a walk produces tens of hazards, not
//  thousands). Files are visible in Files → On My iPhone → OpenCane (`UIFileSharingEnabled`).
//
//  Threading / isolation: `@MainActor @Observable`; file writes are small and infrequent, so they
//  run synchronously on main.
//  Tests: encoding lives in CaneKitLogic (`HazardGeoJSON`, ⚠ `HazardTests.hazardMapIsValidGeoJSON`
//  pins the [lon, lat] order and property names). This class has no unit test — share the map
//  after a device walk and open it in geojson.io.
//

import CaneKitLogic
import Foundation
import Observation

/// Per-session hazard map writer: in-memory `HazardRecord`s mirrored to one GeoJSON file plus
/// JPEG snapshots under Documents/hazards/. One instance for the app's lifetime.
@MainActor
@Observable
final class HazardLog {

    /// Hazards recorded this session (this app launch), newest last. A record stays here even when
    /// the GeoJSON write that followed it failed. `HazardsCard` shows the count.
    private(set) var records: [HazardRecord] = []
    /// Last directory / encode / write failure, prefixed "Hazard log: "; nil after a successful
    /// record. A failed *photo* write is not an error (the hazard is still recorded).
    private(set) var lastError: String?
    /// Photos are capped so a long walk cannot fill the phone. Counted over records that actually
    /// got a photo; past the cap, hazards are still recorded without one.
    var maxPhotos = 200

    /// Documents/hazards/ (created on the first record).
    @ObservationIgnored private let directory = URL.documentsDirectory.appendingPathComponent("hazards", isDirectory: true)
    /// Launch time, ISO 8601 with ':' → '-' (file-name safe); names this session's GeoJSON and JPEGs.
    @ObservationIgnored private let session: String = {
        ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }()

    /// Touches no files; the directory is created by the first `record`.
    init() {}

    /// The GeoJSON file for this session (`hazards-<session>.geojson`). Shared by `HazardsCard`'s
    /// `ShareLink` once `fileWritten` is true.
    var fileURL: URL { directory.appendingPathComponent("hazards-\(session).geojson") }
    /// True once the GeoJSON has actually been written (the share button only appears then).
    private(set) var fileWritten = false

    /// Record one hazard. No fix → still recorded at (0, 0) with accuracy −1 so nothing is lost;
    /// `HazardGeoJSON` writes a null geometry for it (valid RFC 7946), and the JSONL `hazard`
    /// trip-log record keeps the context.
    /// - Parameters:
    ///   - kind: `GroundHazardKind` raw value, "sign" or "vision".
    ///   - text: the line that was spoken.
    ///   - fix: chosen by `AppModel.recordHazard` — the live fix or the nav engine's last fix, only
    ///     if < 120 s old; nil otherwise.
    ///   - jpeg: the camera frame, or nil; saved as `hazard-<session>-<n>.jpg` (n = record number).
    ///   - distanceM: distance ahead in metres to the hazard.
    ///   - heightM: elevation change delta in metres.
    ///   - direction: "center", "left", "right", "head".
    ///   - headingDeg: walker course/heading in degrees.
    ///   - speedMps: walker speed in m/s.
    ///   - routeName: active route/destination name.
    ///   - instruction: current nav instruction.
    ///   - source: "ground", "sign", "vision".
    ///   - whatItSaw: detailed classifier findings.
    ///   - severity: "info", "warn", "critical".
    /// - Returns: the record that was appended, or **nil** when the 3 s debounce refused this
    ///   detection as jitter. ⚠ Callers that mirror the hazard elsewhere must use the return value
    ///   rather than reading `records.last`: after a refusal `records.last` is the *previous*
    ///   hazard, and re-sending it inserts a duplicate row in the cloud.
    @discardableResult
    func record(kind: String, text: String, fix: GeoFix?, jpeg: Data?,
                distanceM: Double? = nil, heightM: Double? = nil,
                direction: String? = nil, headingDeg: Double? = nil,
                speedMps: Double? = nil, routeName: String? = nil,
                instruction: String? = nil, source: String? = nil,
                whatItSaw: String? = nil, severity: String? = nil) -> HazardRecord? {
        let now = Date().timeIntervalSince1970
        // Temporal/spatial debounce: suppress rapid sensor jitter (< 3.0s between records of the
        // same kind or same feature family at the same physical fix).
        if let last = records.last, now - last.time < 3.0 {
            let sameKindOrText = last.kind == kind || (last.text == text)
            let lastFamily = GroundHazardKind(rawValue: last.kind)
            let thisFamily = GroundHazardKind(rawValue: kind)
            let sameFamily = (lastFamily != nil && thisFamily != nil && lastFamily!.isSameFamily(as: thisFamily!))

            let bothHaveFix = last.accuracy >= 0 && (fix?.accuracy ?? -1) >= 0
            let sameCoord = bothHaveFix &&
                abs(last.latitude - (fix?.coordinate.latitude ?? 0)) < 0.00005 &&
                abs(last.longitude - (fix?.coordinate.longitude ?? 0)) < 0.00005

            // Suppress if exact same kind/text within 3s, OR same feature family at the same GPS fix
            if sameKindOrText || (sameFamily && sameCoord) {
                return nil
            }
        }
        // ⚠ The record that was actually appended, so the return value can never be a *previous*
        // hazard. `records.last` is not good enough: `createDirectory` throwing means nothing was
        // appended at all, and returning the one before it would mirror a duplicate to the cloud.
        var appended: HazardRecord?
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var photo: String?
            if let jpeg, records.filter({ $0.photo != nil }).count < maxPhotos {
                let name = "hazard-\(session)-\(records.count + 1).jpg"
                // A failed photo must not cost the hazard itself.
                if (try? jpeg.write(to: directory.appendingPathComponent(name))) != nil { photo = name }
            }
            let record = HazardRecord(kind: kind, text: text,
                                      latitude: fix?.coordinate.latitude ?? 0,
                                      longitude: fix?.coordinate.longitude ?? 0,
                                      accuracy: fix?.accuracy ?? -1,
                                      time: now, photo: photo,
                                      distanceM: distanceM,
                                      heightM: heightM,
                                      direction: direction,
                                      headingDeg: headingDeg,
                                      speedMps: speedMps,
                                      routeName: routeName,
                                      instruction: instruction,
                                      source: source,
                                      whatItSaw: whatItSaw,
                                      severity: severity)
            records.append(record)
            appended = record        // set BEFORE the write, so a failed write still returns it
            try HazardGeoJSON.encode(records).write(to: fileURL, options: .atomic)
            fileWritten = true
            lastError = nil
        } catch {
            lastError = "Hazard log: \(error.localizedDescription)"
        }
        // Returned even when the GeoJSON write failed: the hazard was announced to the walker and
        // is in `records`, so the cloud copy should have it too.
        return appended
    }
}
