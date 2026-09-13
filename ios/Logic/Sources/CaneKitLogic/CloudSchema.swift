//
//  CloudSchema.swift
//  CaneKitLogic
//
//  The wire schema for OpenCane's Supabase mirror, and every number that decides when a row
//  leaves the phone. Pure: no URLSession, no UserDefaults, no clock of its own.
//
//  What this is for. Until Step 45 everything the app knew lived on the phone: settings in
//  `UserDefaults`, the walk in `Documents/canekit-*.jsonl`, the hazard map in
//  `Documents/hazards/*.geojson`, posts in `Documents/posts/posts.json`, the Medical ID in a
//  `UserDefaults` blob. All of it died with the phone and none of it was shareable — a family
//  could not see the walk, a city could not see the potholes, and a reinstall erased the lot.
//  These row types are the same data, shaped for Postgres.
//
//  ⚠ **The phone stays the source of truth.** Every local writer (`TripLogger`, `HazardLog`,
//  `PostStore`, `MedicalProfileStore`, `Settings`) still writes exactly what it wrote before, and
//  the cloud is a mirror fed from the same call sites. A walk with no signal is a complete walk.
//  Nothing in the cue path may ever await an upload.
//
//  ⚠ **Step 60 reduced what the app actually writes to seven tables** — `walkers`, `devices`,
//  `medical_profiles`, `family_contacts`, `trips`, `hazards` (plus the `hazard-photos` bucket) and
//  `family_alerts`. The detail tables were dropped from the live project by migration
//  `reduce_to_mvp_cloud_schema`, and `CloudSync`'s writers for them are documented no-op seams.
//  The row types for them stay HERE, with their tests, because the wire shape is the contract with
//  the migrations and the reduction is a product decision that can be reversed. Read every row
//  type's own doc comment for whether the app writes it today: `TripEventRow`, `DeviceSettingsRow`,
//  `PostRow`, `ConversationTurnRow`, `MobilityDayRow`, `AppLaunchRow`, `RouteRow` and
//  `RouteWaypointRow` are **not written by the shipped app**. `family_alert_recipients` never had a
//  row type here at all (`CloudSync.linkRecipients` built it inline); that method is gone.
//
//  Key invariants:
//    · **Uniform keys.** PostgREST rejects a bulk insert whose objects do not all carry the same
//      key set ("All object keys must match", PGRST102, measured against the live project on
//      2026-09-13). `TripEventRow` therefore encodes every column on every row, writing an
//      explicit JSON null rather than omitting the key. Never make one of its fields "omit when
//      nil" — it silently 400s a whole batch, and the batch is a walk.
//    · ⚠ A new persisted setting still needs a case in `DeviceSettingsRow` and a line in
//      `AppModel.cloudSettings`, and would need a `device_settings` column to sync at all.
//      `Settings.onChange` means it needs no new *wiring*, which is exactly what makes the drift
//      invisible: everything keeps working and the new key simply never leaves the phone.
//      `settingsColumnsCoverEveryPersistedKey` asserts the exact key set and is what catches it
//      (it caught `autoTorchInDark`). Since Step 60 no settings snapshot is uploaded at all.
//    · Column names are the contract (`t_seconds`, `text_spoken`, `walker_id`); for the seven live
//      tables they match migrations `opencane_01`…`opencane_07` as narrowed by
//      `reduce_to_mvp_cloud_schema`. Renaming one here without a migration drops that field on the
//      floor with a 400.
//    · Timestamps are ISO-8601 UTC via `OpenCaneEvent.iso8601` — the format Postgres `timestamptz`
//      accepts and the same one the alert bot already receives.
//    · `CloudBatchPolicy` holds every number (batch size, flush interval, queue ceiling, backoff).
//      A rule with a number in it belongs here with a test (AGENTS.md hard rule 3).
//  Tests: CloudSchemaTests.swift.
//

import Foundation

// MARK: - Batching policy

/// When a row leaves the phone, and what happens when it cannot.
///
/// The shape of the problem: a walk produces a few hundred log lines a minute, the phone is on
/// campus Wi-Fi that comes and goes, and the depth pipeline must never wait for any of it. So rows
/// go into an in-memory queue, leave in batches, and a failed batch goes back to the front rather
/// than being lost.
///
/// ⚠ Since Step 60 the shipped app uses only `flushInterval` (the maintenance loop, which retries
/// registration and a deferred `trips` insert) and `maxPhotoUploads` (the hazard-photo cap). The
/// batching members — `maxBatchSize`, `maxQueuedRows`, `maxAttempts`, `backoff`, `split`, `trim` —
/// describe the `trip_events` queue that the MVP reduction deleted; they are kept with their tests
/// because they are the tuned answer if a detailed mirror comes back. Do not read a value here as
/// evidence that something is being uploaded today.
public struct CloudBatchPolicy: Sendable, Equatable {

    /// Rows per POST. 200 keeps a batch body well under a megabyte even for `lanes` records (the
    /// fattest kind) while still emptying a busy minute in two round trips.
    public var maxBatchSize: Int = 200

    /// Seconds between flushes while a walk is running. Matches `TripLogger`'s own 2 s disk flush
    /// times a small factor: the disk copy is the durable one, so the network may lag it.
    public var flushInterval: TimeInterval = 5

    /// Hard ceiling on queued rows (~10 minutes of a busy walk). Past it the OLDEST rows are
    /// dropped, not the newest: in an outage the recent minute is what a family or a debugger
    /// needs, and unbounded growth on a phone guiding a blind walker is not an option.
    public var maxQueuedRows: Int = 5_000

    /// Attempts per batch before the rows are put back and the next tick tries again.
    public var maxAttempts: Int = 3

    /// Seconds to wait before attempt n (1-based). Doubles from 2 s, capped at 30 s.
    public var backoffBase: TimeInterval = 2
    /// Longest backoff, so a long outage still retries twice a minute.
    public var backoffCeiling: TimeInterval = 30

    /// Hazard photos uploaded per session. Mirrors `HazardLog.maxPhotos` so the cloud copy and the
    /// on-phone copy contain the same set — a hazard past the cap is still recorded, without a photo.
    public var maxPhotoUploads: Int = 200

    public init() {}

    /// Seconds to wait before attempt `n` (1-based). Attempt 1 is immediate.
    ///
    /// 1 → 0, 2 → 2, 3 → 4, 4 → 8 … capped at `backoffCeiling`. Non-positive `n` is treated as
    /// the first attempt rather than trapping: a retry counter is not worth a crash mid-walk.
    public func backoff(attempt n: Int) -> TimeInterval {
        guard n > 1 else { return 0 }
        let doublings = min(n - 2, 16)                    // 2^16 · base is far past the ceiling
        let delay = backoffBase * pow(2, Double(doublings))
        return min(delay, backoffCeiling)
    }

    /// The rows to send now and the rows that stay queued, given everything waiting.
    /// Takes from the front (oldest first) so a walk replays in order.
    public func split(_ queued: [TripEventRow]) -> (send: [TripEventRow], keep: [TripEventRow]) {
        guard queued.count > maxBatchSize else { return (queued, []) }
        return (Array(queued.prefix(maxBatchSize)), Array(queued.dropFirst(maxBatchSize)))
    }

    /// `queued` trimmed to `maxQueuedRows` by dropping the OLDEST rows.
    /// Returns the kept rows and how many were dropped (the caller logs the number, because a
    /// silent drop would make a gap in the cloud walk look like a gap in the real one).
    public func trim(_ queued: [TripEventRow]) -> (kept: [TripEventRow], dropped: Int) {
        guard queued.count > maxQueuedRows else { return (queued, 0) }
        let dropped = queued.count - maxQueuedRows
        return (Array(queued.suffix(maxQueuedRows)), dropped)
    }
}

// MARK: - Rows

/// One line of the JSONL trip log, as a Postgres row.
///
/// ⚠ **Not written by the shipped app.** Step 60 dropped `trip_events` from the live project and
/// made `CloudSync.logEvent` a no-op seam: the detailed log is `Documents/canekit-*.jsonl` on the
/// phone and nowhere else. Kept with its tests as the wire contract if the mirror returns.
///
/// ⚠ Every property is encoded on every row, `nil` included (see the file header: PostgREST
/// requires uniform keys across a bulk insert). `lat`, `lon` and `textSpoken` are lifted out of
/// the payload so the common demo queries are plain columns; the payload keeps the full line.
public struct TripEventRow: Sendable, Equatable, Encodable {
    /// The walker this line belongs to (`walkers.id`).
    public var walkerID: String
    /// The walk, or nil for lines logged outside a route (launch, settings changes, idle GPS).
    public var tripID: String?
    /// Seconds since the logger started — the JSONL line's `t`, unchanged.
    public var tSeconds: Double
    /// The record kind: `gps`, `speech`, `cue`, `lanes`, `route`, `hazard`, `session`, …
    public var kind: String
    /// The rest of the line, verbatim. Kind-specific by design.
    public var payload: [String: OpenCaneJSON]
    /// Lifted from the payload when the line had a position.
    public var lat: Double?
    /// Lifted from the payload when the line had a position.
    public var lon: Double?
    /// Lifted from the payload for `speech` lines: what the walker actually heard.
    public var textSpoken: String?

    /// Which walk this line belongs to, before that walk has a `trips` row to point at.
    ///
    /// ⚠ **Never encoded** — it is not a column, it is bookkeeping meant to ride along with the row
    /// in a queue, so that when a deferred `trips` insert finally returns an id, every row carrying
    /// the matching token can be given it.
    ///
    /// ⚠ **Nothing sets it today.** It was designed to replace an *index* into `CloudSync`'s queue,
    /// which was wrong three ways at once: a flush took rows off the front and shifted every later
    /// row down, `trim` did the same when the queue hit its ceiling, and a new walk could overwrite
    /// the index while a flush was suspended mid-await — all three silently left a walk's first
    /// lines with a null `trip_id`. Step 60 then deleted the queue outright, so the bug and its fix
    /// are both moot. The field and `theWalkTokenNeverReachesTheWire` stay so that a returning
    /// mirror is built on a token that travels with the row, never on an index into a live queue.
    public var walkToken: Int?

    /// The column names in `public.trip_events`.
    public enum CodingKeys: String, CodingKey {
        case walkerID = "walker_id"
        case tripID = "trip_id"
        case tSeconds = "t_seconds"
        case kind, payload, lat, lon
        case textSpoken = "text_spoken"
    }

    public init(walkerID: String, tripID: String?, tSeconds: Double, kind: String,
                payload: [String: OpenCaneJSON] = [:], lat: Double? = nil, lon: Double? = nil,
                textSpoken: String? = nil, walkToken: Int? = nil) {
        self.walkerID = walkerID
        self.tripID = tripID
        self.tSeconds = tSeconds
        self.kind = kind
        self.payload = payload
        self.lat = lat
        self.lon = lon
        self.textSpoken = textSpoken
        self.walkToken = walkToken
    }

    /// ⚠ Hand-written so a nil becomes an explicit `null` instead of a missing key. Codable's
    /// synthesised version omits nil optionals, which makes rows disagree on their key set and
    /// costs the whole batch a 400 (PGRST102). Pinned by `tripEventRowsAlwaysCarryEveryKey`.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(walkerID, forKey: .walkerID)
        try c.encode(tripID, forKey: .tripID)                    // encode, not encodeIfPresent
        try c.encode(tSeconds.isFinite ? tSeconds : 0, forKey: .tSeconds)
        try c.encode(kind, forKey: .kind)
        try c.encode(payload, forKey: .payload)
        try c.encode(lat.flatMap { $0.isFinite ? $0 : nil }, forKey: .lat)
        try c.encode(lon.flatMap { $0.isFinite ? $0 : nil }, forKey: .lon)
        try c.encode(textSpoken, forKey: .textSpoken)
    }

    /// Build a row from a trip-log record, lifting the position and the spoken line out of the
    /// fields the app already logs.
    ///
    /// The lifted keys are the ones `TripLogger` actually writes: `lat` / `lon` on `gps`,
    /// `hazard` and `marker_dropped` records, and `text` on `speech` records. They stay in the
    /// payload as well — the cloud copy of a line is the whole line.
    public static func from(walkerID: String, tripID: String?, tSeconds: Double, kind: String,
                            fields: [String: OpenCaneJSON]) -> TripEventRow {
        func number(_ key: String) -> Double? {
            if case .number(let v)? = fields[key], v.isFinite { return v }
            return nil
        }
        func text(_ key: String) -> String? {
            if case .string(let v)? = fields[key], !v.isEmpty { return v }
            return nil
        }
        return TripEventRow(walkerID: walkerID, tripID: tripID, tSeconds: tSeconds, kind: kind,
                            payload: fields,
                            lat: number("lat"), lon: number("lon"),
                            textSpoken: kind == "speech" ? text("text") : nil)
    }
}

/// A walk, as it opens. Closing it is `TripClosePatch`.
public struct TripOpenRow: Sendable, Equatable, Encodable {
    public var walkerID: String
    public var deviceID: String?
    public var destinationName: String?
    public var startedAt: String                 // ISO-8601 UTC
    public var cueLevel: String?
    public var cuePlace: String?
    public var batteryStartPct: Int?
    public var logFileName: String?
    public var startLat: Double?
    public var startLon: Double?

    public enum CodingKeys: String, CodingKey {
        case walkerID = "walker_id"
        case deviceID = "device_id"
        case destinationName = "destination_name"
        case startedAt = "started_at"
        case cueLevel = "cue_level"
        case cuePlace = "cue_place"
        case batteryStartPct = "battery_start_pct"
        case logFileName = "log_file_name"
        case startLat = "start_lat"
        case startLon = "start_lon"
    }

    public init(walkerID: String, deviceID: String?, destinationName: String?, startedAt: String,
                cueLevel: String?, cuePlace: String?, batteryStartPct: Int?, logFileName: String?,
                startLat: Double?, startLon: Double?) {
        self.walkerID = walkerID
        self.deviceID = deviceID
        self.destinationName = destinationName
        self.startedAt = startedAt
        self.cueLevel = cueLevel
        self.cuePlace = cuePlace
        self.batteryStartPct = batteryStartPct
        self.logFileName = logFileName
        self.startLat = startLat
        self.startLon = startLon
    }
}

/// A walk, as it ends: the arrival card's numbers plus how it ended.
public struct TripClosePatch: Sendable, Equatable, Encodable {
    public var endedAt: String
    public var durationS: Double
    public var distanceM: Double
    public var steps: Int?
    public var stepSource: String?
    /// `arrived` | `stopped` | `abandoned` — the `trips_outcome` check constraint.
    public var outcome: String
    public var waypointsReached: Int
    public var batteryEndPct: Int?
    public var spokenSummary: String?
    public var endLat: Double?
    public var endLon: Double?

    public enum CodingKeys: String, CodingKey {
        case endedAt = "ended_at"
        case durationS = "duration_s"
        case distanceM = "distance_m"
        case steps
        case stepSource = "step_source"
        case outcome
        case waypointsReached = "waypoints_reached"
        case batteryEndPct = "battery_end_pct"
        case spokenSummary = "spoken_summary"
        case endLat = "end_lat"
        case endLon = "end_lon"
    }

    public init(endedAt: String, durationS: Double, distanceM: Double, steps: Int?,
                stepSource: String?, outcome: String, waypointsReached: Int, batteryEndPct: Int?,
                spokenSummary: String?, endLat: Double?, endLon: Double?) {
        self.endedAt = endedAt
        self.durationS = durationS
        self.distanceM = distanceM
        self.steps = steps
        self.stepSource = stepSource
        self.outcome = outcome
        self.waypointsReached = waypointsReached
        self.batteryEndPct = batteryEndPct
        self.spokenSummary = spokenSummary
        self.endLat = endLat
        self.endLon = endLon
    }
}

/// One hazard, mirrored from `HazardRecord`.
public struct HazardRow: Sendable, Equatable, Encodable {
    public var walkerID: String
    public var tripID: String?
    public var kind: String
    public var source: String?
    public var severity: String?
    public var spokenText: String
    public var whatItSaw: String?
    public var lat: Double
    public var lon: Double
    public var accuracyM: Double?
    public var distanceM: Double?
    public var heightM: Double?
    public var direction: String?
    public var headingDeg: Double?
    public var speedMps: Double?
    public var routeName: String?
    public var instruction: String?
    /// Object path inside the `hazard-photos` bucket, once the JPEG has uploaded.
    public var photoPath: String?
    public var detectedAt: String

    public enum CodingKeys: String, CodingKey {
        case walkerID = "walker_id"
        case tripID = "trip_id"
        case kind, source, severity
        case spokenText = "spoken_text"
        case whatItSaw = "what_it_saw"
        case lat, lon
        case accuracyM = "accuracy_m"
        case distanceM = "distance_m"
        case heightM = "height_m"
        case direction
        case headingDeg = "heading_deg"
        case speedMps = "speed_mps"
        case routeName = "route_name"
        case instruction
        case photoPath = "photo_path"
        case detectedAt = "detected_at"
    }

    /// The cloud row for a hazard the phone just wrote to its GeoJSON.
    /// - Parameters:
    ///   - record: the record `HazardLog` appended.
    ///   - walkerID: `walkers.id`.
    ///   - tripID: the active walk, or nil when the hazard was found off-route.
    ///   - photoPath: the bucket path, when the JPEG uploaded; the row is written either way.
    public init(record: HazardRecord, walkerID: String, tripID: String?, photoPath: String?) {
        self.walkerID = walkerID
        self.tripID = tripID
        self.kind = record.kind
        self.source = record.source
        self.severity = record.severity
        self.spokenText = record.text
        self.whatItSaw = record.whatItSaw
        self.lat = record.latitude
        self.lon = record.longitude
        self.accuracyM = record.accuracy
        self.distanceM = record.distanceM
        self.heightM = record.heightM
        self.direction = record.direction
        self.headingDeg = record.headingDeg
        self.speedMps = record.speedMps
        self.routeName = record.routeName
        self.instruction = record.instruction
        self.photoPath = photoPath
        self.detectedAt = OpenCaneEvent.iso8601(Date(timeIntervalSince1970: record.time))
    }
}

/// One named place, mirrored from `WalkMarker`. The phone's UUID is the primary key, so a
/// re-upload after an outage updates rather than duplicates.
///
/// ⚠ **Not written by the shipped app** (Step 60): posts live in `Documents/posts/posts.json` and
/// `CloudSync.recordPost` is a no-op seam. Kept with its tests as the wire contract.
public struct PostRow: Sendable, Equatable, Encodable {
    public var id: String
    public var walkerID: String
    public var tripID: String?
    public var name: String
    public var lat: Double
    public var lon: Double
    public var droppedAt: String

    public enum CodingKeys: String, CodingKey {
        case id
        case walkerID = "walker_id"
        case tripID = "trip_id"
        case name, lat, lon
        case droppedAt = "dropped_at"
    }

    public init(marker: WalkMarker, walkerID: String, tripID: String?) {
        self.id = marker.id.uuidString.lowercased()
        self.walkerID = walkerID
        self.tripID = tripID
        self.name = marker.name
        self.lat = marker.coordinate.latitude
        self.lon = marker.coordinate.longitude
        self.droppedAt = OpenCaneEvent.iso8601(Date(timeIntervalSince1970: marker.timestamp))
    }
}

/// One family alert, mirrored from the `OpenCaneEvent` the phone POSTed to the bot.
///
/// ⚠ `emails` and `send_test` are deliberately NOT carried over. A `family_contacts` registration
/// is not an alert, and a family's addresses belong in `family_contacts` (written by
/// `save_family_contacts`), never duplicated into an event feed. `CloudSync` refuses to build a
/// row for `.familyContacts` for that reason.
public struct FamilyAlertRow: Sendable, Equatable, Encodable {
    public var walkerID: String
    public var tripID: String?
    public var eventType: String
    public var severity: String?
    public var occurredAt: String
    public var lat: Double?
    public var lng: Double?
    public var accuracyM: Double?
    public var headingDeg: Double?
    public var speedMps: Double?
    public var note: String?
    public var label: String?
    public var caneID: String?
    public var batteryPct: Int?
    public var obstacle: OpenCaneObstacle?
    /// The one family-facing sentence a cheap model wrote, lifted out of `extra.ai_context`.
    public var aiContext: String?
    public var extra: [String: OpenCaneJSON]
    /// `pending` | `posted` | `failed` — the `family_alerts_delivery` check constraint.
    public var deliveryStatus: String
    public var webhookStatusCode: Int?
    public var postedAt: String?
    public var errorMessage: String?

    public enum CodingKeys: String, CodingKey {
        case walkerID = "walker_id"
        case tripID = "trip_id"
        case eventType = "event_type"
        case severity
        case occurredAt = "occurred_at"
        case lat, lng
        case accuracyM = "accuracy_m"
        case headingDeg = "heading_deg"
        case speedMps = "speed_mps"
        case note, label
        case caneID = "cane_id"
        case batteryPct = "battery_pct"
        case obstacle
        case aiContext = "ai_context"
        case extra
        case deliveryStatus = "delivery_status"
        case webhookStatusCode = "webhook_status_code"
        case postedAt = "posted_at"
        case errorMessage = "error_message"
    }

    /// Build the row for an event the phone is about to send (or just sent).
    /// - Returns: nil for `family_contacts`, which is a registration and not an alert.
    public init?(event: OpenCaneEvent, walkerID: String, tripID: String?, now: Date,
                 deliveryStatus: String = "pending", webhookStatusCode: Int? = nil,
                 errorMessage: String? = nil) {
        guard event.type != .familyContacts else { return nil }
        self.walkerID = walkerID
        self.tripID = tripID
        self.eventType = event.type.rawValue
        self.severity = event.severity?.rawValue
        self.occurredAt = event.timestamp ?? OpenCaneEvent.iso8601(now)
        self.lat = event.lat ?? event.location?.lat
        self.lng = event.lng ?? event.location?.lng
        self.accuracyM = event.accuracyM
        self.headingDeg = event.heading
        self.speedMps = event.speedMps
        self.note = event.note ?? event.message
        self.label = event.label
        self.caneID = event.caneID
        self.batteryPct = event.batteryPct
        self.obstacle = event.obstacle
        var bag = event.extra ?? [:]
        if case .string(let sentence)? = bag["ai_context"] {
            self.aiContext = sentence
            bag["ai_context"] = nil          // promoted to its own column; do not store it twice
        } else {
            self.aiContext = nil
        }
        self.extra = bag
        self.deliveryStatus = deliveryStatus
        self.webhookStatusCode = webhookStatusCode
        self.postedAt = deliveryStatus == "posted" ? OpenCaneEvent.iso8601(now) : nil
        self.errorMessage = errorMessage
    }
}

/// How the delivery of an already-written alert turned out.
public struct FamilyAlertDeliveryPatch: Sendable, Equatable, Encodable {
    public var deliveryStatus: String
    public var webhookStatusCode: Int?
    public var postedAt: String?
    public var errorMessage: String?

    public enum CodingKeys: String, CodingKey {
        case deliveryStatus = "delivery_status"
        case webhookStatusCode = "webhook_status_code"
        case postedAt = "posted_at"
        case errorMessage = "error_message"
    }

    public init(deliveryStatus: String, webhookStatusCode: Int?, postedAt: String?,
                errorMessage: String?) {
        self.deliveryStatus = deliveryStatus
        self.webhookStatusCode = webhookStatusCode
        self.postedAt = postedAt
        self.errorMessage = errorMessage
    }
}

/// The full persisted settings snapshot for one phone. Column per `UserDefaults` key, so the
/// table reads like the Settings screen.
///
/// ⚠ **Not written by the shipped app** (Step 60): settings stay in `UserDefaults` and
/// `CloudSync.saveSettings` is a no-op seam. `AppModel.cloudSettings` still builds this row, and
/// `settingsColumnsCoverEveryPersistedKey` still asserts its exact key set, so the snapshot cannot
/// quietly fall behind the Settings screen while the table is away.
public struct DeviceSettingsRow: Sendable, Equatable, Encodable {
    public var portraitMode: Bool
    public var mirrorLeftRight: Bool
    public var cueLevel: String
    public var cuePlace: String
    public var obstacleNamesEnabled: Bool
    public var hapticsSilenced: Bool
    public var beaconEnabled: Bool
    public var fallbackToWatch: Bool
    public var groundHazardsEnabled: Bool
    public var signsEnabled: Bool
    public var hazardWatchEnabled: Bool
    public var namePeopleEnabled: Bool
    public var highFrameRateCamera: Bool
    /// Turn the flashlight on by itself when the scene is too dark for the camera (Steps 48–49).
    public var autoTorchInDark: Bool
    public var familyAlertsEnabled: Bool
    public var familyAlertsAIContext: Bool
    public var fallDetectionEnabled: Bool
    public var familyContactsRegistered: Bool
    public var loggingEnabled: Bool
    /// Keys the phone persists that this table has no column for yet.
    public var extraSettings: [String: OpenCaneJSON]

    public enum CodingKeys: String, CodingKey {
        case portraitMode = "portrait_mode"
        case mirrorLeftRight = "mirror_left_right"
        case cueLevel = "cue_level"
        case cuePlace = "cue_place"
        case obstacleNamesEnabled = "obstacle_names_enabled"
        case hapticsSilenced = "haptics_silenced"
        case beaconEnabled = "beacon_enabled"
        case fallbackToWatch = "fallback_to_watch"
        case groundHazardsEnabled = "ground_hazards_enabled"
        case signsEnabled = "signs_enabled"
        case hazardWatchEnabled = "hazard_watch_enabled"
        case namePeopleEnabled = "name_people_enabled"
        case highFrameRateCamera = "high_frame_rate_camera"
        case autoTorchInDark = "auto_torch_in_dark"
        case familyAlertsEnabled = "family_alerts_enabled"
        case familyAlertsAIContext = "family_alerts_ai_context"
        case fallDetectionEnabled = "fall_detection_enabled"
        case familyContactsRegistered = "family_contacts_registered"
        case loggingEnabled = "logging_enabled"
        case extraSettings = "extra_settings"
    }

    public init(portraitMode: Bool, mirrorLeftRight: Bool, cueLevel: String, cuePlace: String,
                obstacleNamesEnabled: Bool, hapticsSilenced: Bool, beaconEnabled: Bool,
                fallbackToWatch: Bool, groundHazardsEnabled: Bool, signsEnabled: Bool,
                hazardWatchEnabled: Bool, namePeopleEnabled: Bool, highFrameRateCamera: Bool,
                autoTorchInDark: Bool,
                familyAlertsEnabled: Bool, familyAlertsAIContext: Bool, fallDetectionEnabled: Bool,
                familyContactsRegistered: Bool, loggingEnabled: Bool,
                extraSettings: [String: OpenCaneJSON] = [:]) {
        self.portraitMode = portraitMode
        self.mirrorLeftRight = mirrorLeftRight
        self.cueLevel = cueLevel
        self.cuePlace = cuePlace
        self.obstacleNamesEnabled = obstacleNamesEnabled
        self.hapticsSilenced = hapticsSilenced
        self.beaconEnabled = beaconEnabled
        self.fallbackToWatch = fallbackToWatch
        self.groundHazardsEnabled = groundHazardsEnabled
        self.signsEnabled = signsEnabled
        self.hazardWatchEnabled = hazardWatchEnabled
        self.namePeopleEnabled = namePeopleEnabled
        self.highFrameRateCamera = highFrameRateCamera
        self.autoTorchInDark = autoTorchInDark
        self.familyAlertsEnabled = familyAlertsEnabled
        self.familyAlertsAIContext = familyAlertsAIContext
        self.fallDetectionEnabled = fallDetectionEnabled
        self.familyContactsRegistered = familyContactsRegistered
        self.loggingEnabled = loggingEnabled
        self.extraSettings = extraSettings
    }
}

/// The Medical ID a first responder reads. Upserted on `walker_id`.
public struct MedicalProfileRow: Sendable, Equatable, Encodable {
    public var walkerID: String
    public var fullName: String?
    public var dateOfBirth: String?
    public var emergencyNotes: String?
    public var bloodType: String?
    public var height: String?
    public var weight: String?
    public var allergies: String?
    public var medications: String?
    public var homeAddress: String?
    public var emergencyContactName: String?
    public var emergencyContactPhone: String?
    public var emergencyContactRelation: String?
    public var caneType: String?
    public var organDonor: Bool?

    public enum CodingKeys: String, CodingKey {
        case walkerID = "walker_id"
        case fullName = "full_name"
        case dateOfBirth = "date_of_birth"
        case emergencyNotes = "emergency_notes"
        case bloodType = "blood_type"
        case height, weight, allergies, medications
        case homeAddress = "home_address"
        case emergencyContactName = "emergency_contact_name"
        case emergencyContactPhone = "emergency_contact_phone"
        case emergencyContactRelation = "emergency_contact_relation"
        case caneType = "cane_type"
        case organDonor = "organ_donor"
    }

    public init(walkerID: String, fullName: String?, dateOfBirth: String?, emergencyNotes: String?,
                bloodType: String?, height: String?, weight: String?, allergies: String?,
                medications: String?, homeAddress: String?, emergencyContactName: String?,
                emergencyContactPhone: String?, emergencyContactRelation: String?,
                caneType: String?, organDonor: Bool?) {
        self.walkerID = walkerID
        self.fullName = fullName
        self.dateOfBirth = dateOfBirth
        self.emergencyNotes = emergencyNotes
        self.bloodType = bloodType
        self.height = height
        self.weight = weight
        self.allergies = allergies
        self.medications = medications
        self.homeAddress = homeAddress
        self.emergencyContactName = emergencyContactName
        self.emergencyContactPhone = emergencyContactPhone
        self.emergencyContactRelation = emergencyContactRelation
        self.caneType = caneType
        self.organDonor = organDonor
    }
}

/// One walker-day of mobility: steps, distance, time on foot, walks completed.
/// Upserted on (`walker_id`, `day`).
///
/// ⚠ **Not written by the shipped app** (Step 60): `MedicalProfileStore.mobilityStats` stays local
/// and `CloudSync.saveMobility` is a no-op seam. Kept with its tests as the wire contract.
public struct MobilityDayRow: Sendable, Equatable, Encodable {
    public var walkerID: String
    /// `yyyy-MM-dd` in the walker's own time zone — a "day" is the day they lived, not UTC's.
    public var day: String
    public var steps: Int
    public var distanceM: Double
    public var activeSeconds: Double
    public var completedTrips: Int
    public var averagePaceMps: Double?

    public enum CodingKeys: String, CodingKey {
        case walkerID = "walker_id"
        case day, steps
        case distanceM = "distance_m"
        case activeSeconds = "active_seconds"
        case completedTrips = "completed_trips"
        case averagePaceMps = "average_pace_mps"
    }

    public init(walkerID: String, day: String, steps: Int, distanceM: Double,
                activeSeconds: Double, completedTrips: Int, averagePaceMps: Double?) {
        self.walkerID = walkerID
        self.day = day
        self.steps = steps
        self.distanceM = distanceM
        self.activeSeconds = activeSeconds
        self.completedTrips = completedTrips
        self.averagePaceMps = averagePaceMps
    }

    /// `yyyy-MM-dd` for `date` in `zone`. Fixed POSIX locale and Gregorian calendar so a walker
    /// with a non-Gregorian regional setting still produces the key Postgres expects.
    public static func dayKey(_ date: Date, zone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let p = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", p.year ?? 1970, p.month ?? 1, p.day ?? 1)
    }
}

/// One spoken question and the answer OpenCane gave.
///
/// ⚠ **Not written by the shipped app** (Step 60): a transcript never leaves the phone and
/// `CloudSync.recordConversationTurn` is a no-op seam. Kept with its tests as the wire contract.
public struct ConversationTurnRow: Sendable, Equatable, Encodable {
    public var walkerID: String
    public var tripID: String?
    public var askedAt: String
    public var question: String?
    public var answer: String?
    /// `fast_path` (answered on device from state) or `model` (a request went out).
    public var route: String?
    public var toolUsed: String?
    public var latencyMs: Int?
    public var lat: Double?
    public var lon: Double?

    public enum CodingKeys: String, CodingKey {
        case walkerID = "walker_id"
        case tripID = "trip_id"
        case askedAt = "asked_at"
        case question, answer, route
        case toolUsed = "tool_used"
        case latencyMs = "latency_ms"
        case lat, lon
    }

    public init(walkerID: String, tripID: String?, askedAt: String, question: String?,
                answer: String?, route: String?, toolUsed: String?, latencyMs: Int?,
                lat: Double?, lon: Double?) {
        self.walkerID = walkerID
        self.tripID = tripID
        self.askedAt = askedAt
        self.question = question
        self.answer = answer
        self.route = route
        self.toolUsed = toolUsed
        self.latencyMs = latencyMs
        self.lat = lat
        self.lon = lon
    }
}

/// One launch, and whether it was a recovery. A `recovered` row is the evidence that a persisted
/// optional feature killed the previous launch (`LaunchRecovery`).
///
/// ⚠ **Not written by the shipped app** (Step 60): `CloudSync.recordLaunch` is a no-op seam, so the
/// recovery evidence is the trip log alone. Kept with its tests as the wire contract.
public struct AppLaunchRow: Sendable, Equatable, Encodable {
    public var walkerID: String
    public var deviceID: String?
    public var launchMode: String               // normal | recovered
    public var clearedKeys: [String]
    public var appVersion: String?
    public var systemVersion: String?
    public var reachedHealthy: Bool

    public enum CodingKeys: String, CodingKey {
        case walkerID = "walker_id"
        case deviceID = "device_id"
        case launchMode = "launch_mode"
        case clearedKeys = "cleared_keys"
        case appVersion = "app_version"
        case systemVersion = "system_version"
        case reachedHealthy = "reached_healthy"
    }

    public init(walkerID: String, deviceID: String?, launchMode: String, clearedKeys: [String],
                appVersion: String?, systemVersion: String?, reachedHealthy: Bool) {
        self.walkerID = walkerID
        self.deviceID = deviceID
        self.launchMode = launchMode
        self.clearedKeys = clearedKeys
        self.appVersion = appVersion
        self.systemVersion = systemVersion
        self.reachedHealthy = reachedHealthy
    }
}

/// A route and its waypoints, uploaded once when a walk starts.
///
/// ⚠ **Not written by the shipped app** (Step 60): route geometry stays in the bundled JSON or
/// MapKit and `CloudSync.uploadRoute` is a no-op seam — the cloud keeps only a walk's destination
/// name and summary on `trips`. Kept with its tests as the wire contract.
public struct RouteRow: Sendable, Equatable, Encodable {
    public var walkerID: String
    public var name: String
    /// `bundled` | `mapkit` | `recorded` — the `routes_source` check constraint.
    public var source: String
    public var destinationName: String?
    public var waypointCount: Int
    public var totalDistanceM: Double?

    public enum CodingKeys: String, CodingKey {
        case walkerID = "walker_id"
        case name, source
        case destinationName = "destination_name"
        case waypointCount = "waypoint_count"
        case totalDistanceM = "total_distance_m"
    }

    public init(walkerID: String, name: String, source: String, destinationName: String?,
                waypointCount: Int, totalDistanceM: Double?) {
        self.walkerID = walkerID
        self.name = name
        self.source = source
        self.destinationName = destinationName
        self.waypointCount = waypointCount
        self.totalDistanceM = totalDistanceM
    }
}

/// One waypoint of an uploaded route. ⚠ Bulk-inserted, so — like `TripEventRow` — every key is
/// written on every row, nil included.
///
/// ⚠ **Not written by the shipped app** (Step 60), for the same reason as `RouteRow`.
public struct RouteWaypointRow: Sendable, Equatable, Encodable {
    public var routeID: String
    public var seq: Int
    public var lat: Double
    public var lon: Double
    public var radiusM: Double
    public var say: String
    public var placeName: String?
    public var crossing: Bool
    public var curved: Bool
    public var bearingNextDeg: Double?

    public enum CodingKeys: String, CodingKey {
        case routeID = "route_id"
        case seq, lat, lon
        case radiusM = "radius_m"
        case say
        case placeName = "place_name"
        case crossing, curved
        case bearingNextDeg = "bearing_next_deg"
    }

    public init(routeID: String, waypoint: Waypoint) {
        self.routeID = routeID
        self.seq = waypoint.id
        self.lat = waypoint.lat
        self.lon = waypoint.lon
        self.radiusM = waypoint.radiusM
        self.say = waypoint.say
        self.placeName = waypoint.name
        self.crossing = waypoint.crossing
        self.curved = waypoint.curved
        self.bearingNextDeg = waypoint.bearingNextDeg
    }

    /// ⚠ Uniform keys for the bulk insert; see `TripEventRow.encode(to:)`.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(routeID, forKey: .routeID)
        try c.encode(seq, forKey: .seq)
        try c.encode(lat, forKey: .lat)
        try c.encode(lon, forKey: .lon)
        try c.encode(radiusM, forKey: .radiusM)
        try c.encode(say, forKey: .say)
        try c.encode(placeName, forKey: .placeName)
        try c.encode(crossing, forKey: .crossing)
        try c.encode(curved, forKey: .curved)
        try c.encode(bearingNextDeg, forKey: .bearingNextDeg)
    }
}
