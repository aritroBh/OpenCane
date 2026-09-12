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
//  Owner: `AppModel.hazardLog`. `record(...)` from AppModel's hazard wiring. The GeoJSON is
//  rewritten whole on each record (a walk produces tens of hazards, not thousands).
//
//  Threading / isolation: `@MainActor @Observable`; file writes are small and infrequent.
//  Encoding lives in CaneKitLogic (HazardGeoJSON, tested in HazardTests).
//

import CaneKitLogic
import Foundation
import Observation

@MainActor
@Observable
final class HazardLog {

    /// Hazards recorded this session, newest last.
    private(set) var records: [HazardRecord] = []
    private(set) var lastError: String?
    /// Photos are capped so a long walk cannot fill the phone.
    var maxPhotos = 200

    @ObservationIgnored private let directory = URL.documentsDirectory.appendingPathComponent("hazards", isDirectory: true)
    @ObservationIgnored private let session: String = {
        ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }()

    init() {}

    /// The GeoJSON file for this session (for a share sheet).
    var fileURL: URL { directory.appendingPathComponent("hazards-\(session).geojson") }
    /// True once the GeoJSON has actually been written (the share button only appears then).
    private(set) var fileWritten = false

    /// Record one hazard. No fix → still recorded at (0, 0) with accuracy −1 so nothing is lost;
    /// map tools drop those, the JSONL trip log keeps the context.
    func record(kind: String, text: String, fix: GeoFix?, jpeg: Data?) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var photo: String?
            if let jpeg, records.filter({ $0.photo != nil }).count < maxPhotos {
                let name = "hazard-\(session)-\(records.count + 1).jpg"
                // A failed photo must not cost the hazard itself.
                if (try? jpeg.write(to: directory.appendingPathComponent(name))) != nil { photo = name }
            }
            records.append(HazardRecord(kind: kind, text: text,
                                        latitude: fix?.coordinate.latitude ?? 0,
                                        longitude: fix?.coordinate.longitude ?? 0,
                                        accuracy: fix?.accuracy ?? -1,
                                        time: Date().timeIntervalSince1970, photo: photo))
            try HazardGeoJSON.encode(records).write(to: fileURL, options: .atomic)
            fileWritten = true
            lastError = nil
        } catch {
            lastError = "Hazard log: \(error.localizedDescription)"
        }
    }
}
