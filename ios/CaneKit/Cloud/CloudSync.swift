//
//  CloudSync.swift
//  CaneKit
//
//  The mirror: everything OpenCane keeps on the phone, kept in Supabase too.
//
//  What moved (Step 45). Before this, each kind of state lived in exactly one place on one phone:
//
//    | On the phone                                  | Now also in Postgres        |
//    |-----------------------------------------------|-----------------------------|
//    | `UserDefaults` settings keys                   | `device_settings`           |
//    | `familyContactEmails` + `familyContactsRegistered` | `family_contacts`       |
//    | `MedicalProfileStore`'s profile blob           | `medical_profiles`          |
//    | `Documents/canekit-*.jsonl` (TripLogger)       | `trips` + `trip_events`     |
//    | `Documents/hazards/*.geojson` + JPEGs          | `hazards` + a storage bucket|
//    | `Documents/posts/posts.json` (PostStore)       | `posts`                     |
//    | `OpenCaneEvent`s POSTed to the alert bot       | `family_alerts`             |
//    | `ConversationHistory` (memory only)            | `conversation_turns`        |
//    | `MedicalProfileStore.mobilityStats`            | `mobility_days`            |
//    | `LaunchRecovery`'s marker outcome              | `app_launches`              |
//
//  ⚠ **The phone is still the source of truth.** Every local writer writes exactly what it wrote
//  before; this class is fed from the same call sites and never stands between a detection and a
//  cue. Uploads are queued and flushed on a 5 s loop, a failed batch goes back on the queue, and a
//  walk with no signal is still a complete walk on disk. Turning the cloud off (no keys in
//  `Secrets.plist`) restores the exact pre-Step-45 behaviour.
//
//  ⚠ **Nothing here may `await` on the cue path.** `logEvent`, `recordHazard`, `recordPost` and
//  `recordAlert` are synchronous appends to an in-memory queue. The only `async` work happens in
//  the flush loop and in `start()`.
//
//  Owner: `AppModel.cloud` (one instance). `start()` once from `AppModel.start()`; the writers are
//  called from `TripLogger`'s `onRecord` hook, `AppModel.recordHazard`,
//  `ConversationCoordinator.dropPost`, `FamilyAlerts.send`, the settings `didSet`s and
//  `saveFamilyContacts()`. Module `cloud` in docs/CODE_REFERENCE.md.
//
//  Threading / isolation: `@MainActor @Observable`. `SupabaseClient` is `nonisolated` and every
//  request runs off the main actor inside a detached-by-isolation `async` call.
//
//  Key invariants:
//    · Every table is keyed on `walkers.id`, so nothing can be written before `register_cane`
//      returns. Registration is idempotent and retried on the flush loop. What happens meanwhile
//      differs by writer, deliberately: trip-log lines **queue** and a walk's `trips` row is
//      **deferred** and opened the moment ids arrive (a route can start well inside the
//      registration round trip — measured 2026-09-13, an e2e walk produced 899 `trip_events` and
//      zero `trips` before this was fixed). The one-shot writers (hazard, post, alert,
//      conversation turn) drop instead, because they fire seconds into a launch at the earliest
//      and a stale replay is worse than a gap.
//    · The family email list goes through `save_family_contacts` ONLY. It is never put in a
//      `trip_events` payload, never in a `family_alerts` row, and never shown to the summarizer
//      model (`FamilyContacts`, `AlertSummarizer`). It is the most personal thing this app holds.
//    · Photo uploads are capped at `CloudBatchPolicy.maxPhotoUploads`, matching `HazardLog`.
//  Tests: the decisions live in `CloudBatchPolicy` / `CloudSchema` (CaneKitLogic,
//  `CloudSchemaTests`). This class is the effectful shell; verify it by walking with the phone and
//  watching `trip_summary` fill in.
//

import CaneKitLogic
import Foundation
import Observation
import UIKit

/// Mirrors the phone's state into Supabase. One instance, owned by `AppModel`.
@MainActor
@Observable
final class CloudSync {

    // MARK: Published state (the Settings row reads these)

    /// True when `Secrets.plist` carried a project URL and key. False = the whole class is inert.
    var isConfigured: Bool { client != nil }
    /// The project host, or nil. Never contains the key.
    var host: String? { client?.host }
    /// One line for the Settings row: "Synced 412 rows", "Offline — 88 queued", "Not configured".
    private(set) var status = "Not configured"
    /// Rows waiting to go. Shown so a demo can point at it draining.
    private(set) var queuedRows = 0
    /// Rows accepted by Postgres this session.
    private(set) var rowsUploaded = 0
    /// Last failure, one line. Cleared by the next success.
    private(set) var lastError: String?
    /// True once `register_cane` has returned ids — until then nothing but trip events can queue.
    var isRegistered: Bool { walkerID != nil }

    /// The walk currently open in `trips`, or nil. Every queued row is stamped with it.
    private(set) var tripID: String?

    // MARK: Identity

    /// `walkers.id`, from `register_cane`. Every table is keyed on it.
    private(set) var walkerID: String?
    /// `devices.id`, from `register_cane`. Keys `device_settings`.
    private(set) var deviceID: String?

    /// The per-install UUID that survives relaunches (and is what `register_cane` upserts on), so
    /// a walker's history is one history. ⚠ A `UserDefaults` key, not a file: losing it after a
    /// reinstall is acceptable (a new walker row appears), losing the app is not.
    private static let installKey = "opencane_install_id"
    private let installID: String = {
        if let existing = UserDefaults.standard.string(forKey: installKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        UserDefaults.standard.set(fresh, forKey: installKey)
        return fresh
    }()

    // MARK: Machinery

    @ObservationIgnored private let client: SupabaseClient?
    @ObservationIgnored private let policy = CloudBatchPolicy()
    /// Trip-log lines waiting for a batch. Oldest first.
    @ObservationIgnored private var queue: [TripEventRow] = []
    /// The 5 s flush loop; cancelled by `stop()`.
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// True while a flush is in flight, so the loop never overlaps itself.
    @ObservationIgnored private var isFlushing = false
    /// Consecutive failed flushes, for the backoff.
    @ObservationIgnored private var failedAttempts = 0
    /// Photos uploaded this session (capped at `policy.maxPhotoUploads`).
    @ObservationIgnored private var photosUploaded = 0
    /// Set once the app has asked to register and the RPC is in flight or done, so the flush loop
    /// does not start a second registration.
    @ObservationIgnored private var registering = false
    /// Kept so a late `start()` can register with the right facts.
    @ObservationIgnored private var pendingRegistration: RegistrationFacts?

    init(client: SupabaseClient? = SupabaseClient.fromSecrets()) {
        self.client = client
        if client != nil { status = "Starting…" }
    }

    // MARK: Session

    /// What `register_cane` needs to know about this phone. Gathered by `AppModel.start()`.
    struct RegistrationFacts: Sendable {
        var displayName: String
        var caneID: String
        var hasLiDAR: Bool
        var watchPaired: Bool
        var airPodsPaired: Bool
    }

    /// Register the cane, push the current settings and start the flush loop.
    /// Idempotent — `register_cane` upserts, so calling it every launch is the design. Safe to
    /// call with no network: the registration is retried by the flush loop.
    /// Caller: `AppModel.start()`.
    func start(_ facts: RegistrationFacts) {
        guard client != nil else { return }
        pendingRegistration = facts
        registerIfNeeded()
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self?.tick()
            }
        }
    }

    /// Flush what is queued and stop the loop. Called from
    /// `AppModel.scenePhaseChanged(.background)` so a backgrounded walk still lands.
    func flushNow() {
        Task { [weak self] in await self?.tick() }
    }

    /// Stop the loop entirely. No caller today (the app keeps syncing for its lifetime, like
    /// `TripLogger`); here so a test or a future "pause sync" switch has one.
    func stop() {
        flushTask?.cancel()
        flushTask = nil
    }

    // MARK: Writers — called from the app, never awaited

    /// Mirror one trip-log line. Called from `TripLogger.onRecord` for every record the logger
    /// writes, so the cloud copy and the JSONL file hold the same lines.
    /// Queues even before registration: the rows are stamped with the walker id at flush time.
    func logEvent(kind: String, tSeconds: Double, fields: [String: Any]) {
        guard client != nil else { return }
        let payload = Self.json(fields)
        queue.append(TripEventRow.from(walkerID: walkerID ?? "", tripID: tripID,
                                       tSeconds: tSeconds, kind: kind, fields: payload))
        let (kept, dropped) = policy.trim(queue)
        if dropped > 0 {
            queue = kept
            // Said out loud in the status rather than swallowed: a gap in the cloud walk that
            // nobody knows about looks like a gap in the real one.
            lastError = "Dropped \(dropped) queued rows (offline too long)"
        }
        queuedRows = queue.count
    }

    /// Open a `trips` row. Everything queued afterwards is stamped with it.
    /// Caller: `AppModel.startRouteNow`, after the route is built.
    ///
    /// ⚠ A route can start before `register_cane` has returned — on a cold launch the walker can
    /// press Start in well under the round trip, and the e2e scenarios do it every run. Measured
    /// 2026-09-13: an e2e walk wrote 899 `trip_events` and **zero** `trips`, because this method
    /// used to `guard let walkerID` and give up, so a whole walk arrived as loose lines with a
    /// null `trip_id`. The open is therefore *deferred*, not dropped: it is held until
    /// registration lands and then sent with the start time it actually had.
    func beginTrip(destination: String?, cueLevel: String, cuePlace: String, batteryPct: Int,
                   logFileName: String?, start: GeoFix?) {
        guard client != nil else { return }
        let pending = PendingTrip(destination: destination,
                                  startedAt: OpenCaneEvent.iso8601(Date()),
                                  cueLevel: cueLevel, cuePlace: cuePlace,
                                  batteryStartPct: batteryPct >= 0 ? batteryPct : nil,
                                  logFileName: logFileName,
                                  startLat: start?.coordinate.latitude,
                                  startLon: start?.coordinate.longitude)
        // A new walk cannot inherit the previous one's pending close — that close belonged to a
        // row this one is not. (It is only ever set for a walk whose row never opened.)
        pendingClose = nil
        pendingTrip = pending
        // Where this walk's lines begin. Rows queued before Start belong to no trip and must stay
        // null; rows from here on are this walk's and get stamped when the row id arrives.
        tripQueueMark = queue.count
        openPendingTrip()
    }

    /// Index in `queue` at which the current walk's lines begin (see `beginTrip`).
    @ObservationIgnored private var tripQueueMark = 0

    /// A walk that began before the cane had ids. Held with its real start time.
    private struct PendingTrip: Sendable {
        var destination: String?
        var startedAt: String
        var cueLevel: String
        var cuePlace: String
        var batteryStartPct: Int?
        var logFileName: String?
        var startLat: Double?
        var startLon: Double?
    }

    /// The walk waiting for a `trips` row, or nil. Cleared once the row exists.
    @ObservationIgnored private var pendingTrip: PendingTrip?
    /// True while the insert is in flight, so `tick()` cannot start a second one.
    @ObservationIgnored private var openingTrip = false
    /// A close that arrived before its `trips` row did (a very short walk on a cold launch).
    @ObservationIgnored private var pendingClose: TripClosePatch?

    /// Insert the held `trips` row, once there is a walker to attach it to.
    /// Called from `beginTrip` and from every `tick()`, so a walk opened offline still lands.
    private func openPendingTrip() {
        guard let client, let walkerID, let pending = pendingTrip,
              tripID == nil, !openingTrip else { return }
        openingTrip = true
        let row = TripOpenRow(walkerID: walkerID, deviceID: deviceID,
                              destinationName: pending.destination,
                              startedAt: pending.startedAt,
                              cueLevel: pending.cueLevel, cuePlace: pending.cuePlace,
                              batteryStartPct: pending.batteryStartPct,
                              logFileName: pending.logFileName,
                              startLat: pending.startLat, startLon: pending.startLon)
        Task { [weak self] in
            do {
                let data = try await client.insert(into: "trips", row: row, returning: true)
                let id = Self.firstID(in: data)
                await MainActor.run {
                    guard let self else { return }
                    self.tripID = id
                    self.pendingTrip = nil
                    self.openingTrip = false
                    // Lines logged while the row was being created are this walk's lines.
                    if let id, self.tripQueueMark < self.queue.count {
                        for i in self.tripQueueMark..<self.queue.count
                        where self.queue[i].tripID == nil {
                            self.queue[i].tripID = id
                        }
                    }
                    // A walk short enough to have ended already: close it now.
                    if let close = self.pendingClose {
                        self.pendingClose = nil
                        self.applyClose(close)
                    }
                }
            } catch {
                await MainActor.run {
                    self?.openingTrip = false        // let the next tick try again
                    self?.note(error)
                }
            }
        }
    }

    /// Close the open `trips` row with the arrival card's numbers.
    /// - Parameter outcome: `arrived`, `stopped` or `abandoned` (the check constraint).
    /// Caller: `AppModel.onArrived` and `stopRoute`.
    func endTrip(outcome: String, elapsed: TimeInterval, distanceM: Double, steps: Int?,
                 stepSource: String?, waypointsReached: Int, batteryPct: Int,
                 spokenSummary: String?, end: GeoFix?) {
        guard client != nil else { return }
        let patch = TripClosePatch(endedAt: OpenCaneEvent.iso8601(Date()),
                                   durationS: elapsed, distanceM: distanceM, steps: steps,
                                   stepSource: stepSource, outcome: outcome,
                                   waypointsReached: waypointsReached,
                                   batteryEndPct: batteryPct >= 0 ? batteryPct : nil,
                                   spokenSummary: spokenSummary,
                                   endLat: end?.coordinate.latitude,
                                   endLon: end?.coordinate.longitude)
        // Flush the walk's remaining lines first so the log is complete before the row closes.
        flushNow()
        guard tripID != nil else {
            // The row is still being opened (see `beginTrip`); `openPendingTrip` applies this the
            // moment it exists. A walk shorter than one round trip is still a whole walk.
            pendingClose = patch
            return
        }
        applyClose(patch)
    }

    /// PATCH the open `trips` row and forget it. The trip id is cleared straight away so nothing
    /// logged after the walk is stamped with it, even if the request is slow.
    private func applyClose(_ patch: TripClosePatch) {
        guard let client, let id = tripID else { return }
        tripID = nil
        Task { [weak self] in
            do {
                try await client.patch("trips",
                                       filter: [URLQueryItem(name: "id", value: "eq.\(id)")],
                                       row: patch)
                await MainActor.run { self?.count(1) }
            } catch {
                await MainActor.run { self?.note(error) }
            }
        }
    }

    /// Mirror a hazard and, when there is one, its camera frame.
    /// The row is written even if the photo upload fails — a hazard without a picture is still a
    /// hazard, which is the same rule `HazardLog` follows on disk.
    /// Caller: `AppModel.recordHazard`, right after `hazardLog.record(...)`.
    func recordHazard(_ record: HazardRecord, jpeg: Data?) {
        guard let client, let walkerID else { return }
        let wantsPhoto = jpeg != nil && photosUploaded < policy.maxPhotoUploads
        if wantsPhoto { photosUploaded += 1 }
        let photoName = wantsPhoto ? "\(walkerID)/\(UUID().uuidString.lowercased()).jpg" : nil
        let trip = tripID

        Task { [weak self] in
            var uploaded: String?
            if let photoName, let jpeg {
                uploaded = try? await client.uploadObject(bucket: "hazard-photos",
                                                          path: photoName, data: jpeg)
            }
            let row = HazardRow(record: record, walkerID: walkerID, tripID: trip,
                                photoPath: uploaded)
            do {
                try await client.insert(into: "hazards", row: row)
                await MainActor.run { self?.count(1) }
            } catch {
                await MainActor.run { self?.note(error) }
            }
        }
    }

    /// Mirror one named place. The phone's marker UUID is the primary key, so a retry after an
    /// outage updates rather than duplicating.
    /// Caller: `ConversationCoordinator.dropPost(name:)` via `AppModel`.
    func recordPost(_ marker: WalkMarker) {
        guard let client, let walkerID else { return }
        let row = PostRow(marker: marker, walkerID: walkerID, tripID: tripID)
        Task { [weak self] in
            do {
                try await client.upsert(into: "posts", row: row, onConflict: "id")
                await MainActor.run { self?.count(1) }
            } catch {
                await MainActor.run { self?.note(error) }
            }
        }
    }

    /// Mirror a family alert and how its POST to the bot turned out.
    ///
    /// ⚠ A `family_contacts` registration is not an alert: `FamilyAlertRow` refuses to build one,
    /// so the family's addresses can never leak into the alert feed. Keep it that way.
    /// - Parameters:
    ///   - event: exactly what was POSTed to the bot.
    ///   - status: `posted` when the webhook returned 2xx (which means the bot STARTED a run, not
    ///     that anyone was emailed), `failed` otherwise.
    /// Caller: `FamilyAlerts.send`, after the POST settles.
    func recordAlert(_ event: OpenCaneEvent, status: String, httpStatus: Int?, error: String?) {
        guard let client, let walkerID else { return }
        guard let row = FamilyAlertRow(event: event, walkerID: walkerID, tripID: tripID,
                                       now: Date(), deliveryStatus: status,
                                       webhookStatusCode: httpStatus, errorMessage: error)
        else { return }
        Task { [weak self] in
            do {
                let data = try await client.insert(into: "family_alerts", row: row, returning: true)
                await MainActor.run { self?.count(1) }
                // Record who the alert was addressed to, so the feed reads "Mom and Sagar were
                // told" rather than "an alert fired".
                if let alertID = Self.firstID(in: data) {
                    await self?.linkRecipients(alertID: alertID, client: client, walkerID: walkerID)
                }
            } catch {
                await MainActor.run { self?.note(error) }
            }
        }
    }

    /// Mirror one spoken question and its answer.
    /// Caller: `ConversationCoordinator`, after an answer is spoken.
    func recordConversationTurn(question: String?, answer: String?, route: String?,
                                tool: String?, latencyMs: Int?, fix: GeoFix?) {
        guard let client, let walkerID else { return }
        let row = ConversationTurnRow(walkerID: walkerID, tripID: tripID,
                                      askedAt: OpenCaneEvent.iso8601(Date()),
                                      question: question, answer: answer, route: route,
                                      toolUsed: tool, latencyMs: latencyMs,
                                      lat: fix?.coordinate.latitude,
                                      lon: fix?.coordinate.longitude)
        Task { [weak self] in
            do {
                try await client.insert(into: "conversation_turns", row: row)
                await MainActor.run { self?.count(1) }
            } catch {
                await MainActor.run { self?.note(error) }
            }
        }
    }

    // MARK: Writers — configuration

    /// Push the full settings snapshot.
    ///
    /// Called from `Settings.onChange`, so it fires once per persisted write — and one user action
    /// can be several writes (changing the cue level writes `cueLevel` *and* `cuePlace`; a launch
    /// recovery clears a handful). Coalesced on a 0.4 s trailing debounce so a burst becomes one
    /// PATCH of the final state, which is the only state that was ever true.
    func saveSettings(_ row: DeviceSettingsRow) {
        guard client != nil else { return }
        pendingSettings = row
        settingsTask?.cancel()
        settingsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.pushSettings()
        }
    }

    /// The last settings snapshot handed to `saveSettings`, waiting for the debounce.
    @ObservationIgnored private var pendingSettings: DeviceSettingsRow?
    /// The trailing-debounce task; cancelled and replaced by each new write.
    @ObservationIgnored private var settingsTask: Task<Void, Never>?

    /// Send whatever `saveSettings` last staged. A snapshot that arrives before registration is
    /// kept, not dropped: the next write (or the post-registration push in
    /// `AppModel.startCloudMirror`) carries it.
    private func pushSettings() async {
        guard let client, let deviceID, let row = pendingSettings else { return }
        pendingSettings = nil
        do {
            try await client.patch("device_settings",
                                   filter: [URLQueryItem(name: "device_id",
                                                         value: "eq.\(deviceID)")],
                                   row: row)
            count(1)
        } catch {
            note(error)
        }
    }

    /// Replace the family alert list with exactly these addresses.
    ///
    /// ⚠ This is the ONLY path by which a family email address reaches the cloud. Addresses
    /// removed here stop being alerted; survivors keep their id and their alert history
    /// (`save_family_contacts`, migration `opencane_06`).
    /// - Parameters:
    ///   - emails: already normalised by `FamilyContacts.normalize` — the caller stores what it sends.
    ///   - registered: true once the alert bot has accepted the list.
    /// Caller: `AppModel.saveFamilyContacts()`.
    func saveFamilyContacts(_ emails: [String], registered: Bool) {
        guard let client, let walkerID else { return }
        struct Args: Encodable {
            let p_walker_id: String
            let p_emails: [String]
            let p_registered: Bool
        }
        let args = Args(p_walker_id: walkerID, p_emails: emails, p_registered: registered)
        Task { [weak self] in
            do {
                try await client.rpc("save_family_contacts", body: args)
                await MainActor.run { self?.count(emails.count) }
            } catch {
                await MainActor.run { self?.note(error) }
            }
        }
    }

    /// Push the Medical ID a first responder would read. Upserted on `walker_id`.
    /// Caller: `AppModel`, on `MedicalProfileStore`'s save.
    func saveMedicalProfile(_ profile: CKMedicalProfile) {
        guard let client, let walkerID else { return }
        let row = MedicalProfileRow(walkerID: walkerID,
                                    fullName: profile.name,
                                    dateOfBirth: profile.dateOfBirth,
                                    emergencyNotes: profile.emergencyNotes,
                                    bloodType: profile.bloodType,
                                    height: profile.height,
                                    weight: profile.weight,
                                    allergies: profile.allergies,
                                    medications: profile.medications,
                                    homeAddress: profile.homeAddress,
                                    emergencyContactName: profile.emergencyContactName,
                                    emergencyContactPhone: profile.emergencyContactPhone,
                                    emergencyContactRelation: profile.emergencyContactRelation,
                                    caneType: profile.caneType,
                                    organDonor: profile.organDonor)
        Task { [weak self] in
            do {
                try await client.upsert(into: "medical_profiles", row: row, onConflict: "walker_id")
                await MainActor.run { self?.count(1) }
            } catch {
                await MainActor.run { self?.note(error) }
            }
        }
    }

    /// Push today's mobility numbers. Upserted on (`walker_id`, `day`), so calling it repeatedly
    /// through the day just refreshes the row.
    func saveMobility(_ stats: CKMobilityStats) {
        guard let client, let walkerID else { return }
        let row = MobilityDayRow(walkerID: walkerID,
                                 day: MobilityDayRow.dayKey(Date()),
                                 steps: stats.todaySteps,
                                 distanceM: stats.todayDistanceMeters,
                                 activeSeconds: stats.todayActiveSeconds,
                                 completedTrips: stats.completedTrips,
                                 averagePaceMps: stats.averagePaceMps > 0 ? stats.averagePaceMps : nil)
        Task { [weak self] in
            do {
                try await client.upsert(into: "mobility_days", row: row,
                                        onConflict: "walker_id,day")
                await MainActor.run { self?.count(1) }
            } catch {
                await MainActor.run { self?.note(error) }
            }
        }
    }

    /// Record how this launch went — `recovered` means the previous one died before it was healthy
    /// and OpenCane cleared the optional features that could have been holding it hostage
    /// (`LaunchRecovery`). Evidence that the guard fired, kept where it can be looked at later.
    func recordLaunch(mode: LaunchMode, clearedKeys: [String]) {
        guard let client, let walkerID else { return }
        let row = AppLaunchRow(walkerID: walkerID, deviceID: deviceID,
                               launchMode: mode == .recovered ? "recovered" : "normal",
                               clearedKeys: mode == .recovered ? clearedKeys : [],
                               appVersion: Self.appVersion,
                               systemVersion: UIDevice.current.systemVersion,
                               reachedHealthy: false)
        Task { [weak self] in
            do {
                try await client.insert(into: "app_launches", row: row)
                await MainActor.run { self?.count(1) }
            } catch {
                await MainActor.run { self?.note(error) }
            }
        }
    }

    /// Upload the route being walked and its waypoints, then attach it to the open trip.
    /// Caller: `AppModel.startRouteNow`, after `beginTrip`.
    /// - Parameter source: `bundled` (the recorded campus route) or `mapkit`.
    func uploadRoute(_ route: Route, source: String) {
        guard client != nil else { return }
        // ⚠ Deferred for the same reason as `beginTrip`: a route is built and started well inside
        // the `register_cane` round trip on a cold launch, and giving up here left every walk with
        // no `routes` row and a null `trips.route_id` (measured 2026-09-13).
        pendingRoute = PendingRoute(route: route, source: source)
        uploadPendingRoute()
    }

    /// A route walked before the cane had ids.
    private struct PendingRoute: Sendable {
        var route: Route
        var source: String
    }

    /// The route waiting to be uploaded, or nil.
    @ObservationIgnored private var pendingRoute: PendingRoute?
    /// True while the upload is in flight, so `tick()` cannot start a second one.
    @ObservationIgnored private var uploadingRoute = false

    /// Upload the held route and link it to the walk, once there is a walker to attach it to.
    /// Called from `uploadRoute` and from every `tick()`.
    private func uploadPendingRoute() {
        guard let client, let walkerID, let pending = pendingRoute, !uploadingRoute else { return }
        uploadingRoute = true
        let route = pending.route
        let source = pending.source
        let header = RouteRow(walkerID: walkerID, name: route.name, source: source,
                              destinationName: route.waypoints.last?.placeName,
                              waypointCount: route.waypoints.count,
                              totalDistanceM: Self.routeLength(route))
        let waypoints = route.waypoints
        Task { [weak self] in
            do {
                let data = try await client.insert(into: "routes", row: header, returning: true)
                guard let routeID = Self.firstID(in: data) else { return }
                let rows = waypoints.map { RouteWaypointRow(routeID: routeID, waypoint: $0) }
                try await client.bulkInsert(into: "route_waypoints", rows: rows)
                // ⚠ Read the trip id HERE, not at call time: on a cold launch the `trips` row is
                // still being created when the route is uploaded, and capturing nil up front left
                // every walk unlinked from the route it walked.
                let trip = await MainActor.run { self?.tripID }
                if let trip {
                    struct Link: Encodable { let route_id: String }
                    try await client.patch("trips",
                                           filter: [URLQueryItem(name: "id", value: "eq.\(trip)")],
                                           row: Link(route_id: routeID))
                }
                await MainActor.run {
                    self?.pendingRoute = nil
                    self?.uploadingRoute = false
                    self?.count(rows.count + 1)
                }
            } catch {
                await MainActor.run {
                    self?.uploadingRoute = false      // let the next tick try again
                    self?.note(error)
                }
            }
        }
    }

    // MARK: Flush loop

    /// One pass: register if we still have not, then send a batch.
    private func tick() async {
        guard let client else { return }
        registerIfNeeded()
        openPendingTrip()          // a walk that began before the cane had ids
        uploadPendingRoute()       // and the route it is walking
        guard walkerID != nil, !isFlushing, !queue.isEmpty else {
            updateStatus()
            return
        }
        isFlushing = true
        defer { isFlushing = false }

        let (send, keep) = policy.split(queue)
        queue = keep
        // ⚠ `tripQueueMark` is an index INTO `queue`, and this just removed rows from its front.
        // Without shifting it by the same amount it points at the wrong rows, and the walk's first
        // lines never get stamped with the trip id when it lands (they stay `trip_id` null).
        tripQueueMark = policy.shiftMark(tripQueueMark, flushed: send.count)
        // Rows queued before registration carry an empty walker id; stamp them now.
        let stamped = send.map { row -> TripEventRow in
            guard row.walkerID.isEmpty else { return row }
            var copy = row
            copy.walkerID = walkerID ?? ""
            return copy
        }
        do {
            try await client.bulkInsert(into: "trip_events", rows: stamped)
            failedAttempts = 0
            count(stamped.count)
        } catch {
            // Back on the front of the queue, in order, and try again next tick.
            queue = stamped + queue
            tripQueueMark += stamped.count          // the rows came back; so does the mark
            failedAttempts += 1
            note(error)
            if failedAttempts >= policy.maxAttempts {
                try? await Task.sleep(for: .seconds(policy.backoff(attempt: failedAttempts)))
            }
        }
        queuedRows = queue.count
        updateStatus()
    }

    /// Re-run `register_cane` with fresh hardware facts, so the `devices` row keeps up when the
    /// watch or the AirPods connect or disconnect mid-session. Idempotent (the RPC upserts on
    /// `install_id` + `vendor_id`), and a no-op before the first registration has landed — that
    /// one is already on its way with whatever was true at launch.
    /// Callers: `AppModel.recordDeviceCapabilities()` (start, watch state change, audio route change).
    func updateDeviceFacts(_ facts: RegistrationFacts) {
        guard client != nil, walkerID != nil else { return }
        pendingRegistration = facts
        sendRegistration(facts)
    }

    /// Fire `register_cane` once and keep the ids. Retried by `tick()` until it succeeds.
    private func registerIfNeeded() {
        guard client != nil, walkerID == nil, !registering, let facts = pendingRegistration else { return }
        registering = true
        sendRegistration(facts)
    }

    /// The RPC itself. Shared by the first registration and every later device-facts refresh.
    private func sendRegistration(_ facts: RegistrationFacts) {
        guard let client else { return }
        struct Args: Encodable {
            let p_install_id: String
            let p_vendor_id: String
            let p_display_name: String
            let p_cane_id: String
            let p_device_name: String
            let p_model: String
            let p_system_version: String
            let p_app_version: String
            let p_has_lidar: Bool
            let p_watch_paired: Bool
            let p_airpods_paired: Bool
        }
        let device = UIDevice.current
        let args = Args(p_install_id: installID,
                        p_vendor_id: device.identifierForVendor?.uuidString.lowercased() ?? installID,
                        p_display_name: facts.displayName,
                        p_cane_id: facts.caneID,
                        p_device_name: device.name,
                        p_model: Self.hardwareModel,
                        p_system_version: "\(device.systemName) \(device.systemVersion)",
                        p_app_version: Self.appVersion,
                        p_has_lidar: facts.hasLiDAR,
                        p_watch_paired: facts.watchPaired,
                        p_airpods_paired: facts.airPodsPaired)
        Task { [weak self] in
            do {
                let data = try await client.rpc("register_cane", body: args)
                let ids = try? JSONDecoder().decode(RegisterResult.self, from: data)
                await MainActor.run {
                    guard let self else { return }
                    // ⚠ Only assign on a real answer. A refresh (`updateDeviceFacts`) whose body
                    // failed to decode must not wipe the ids the cane is already using — that
                    // would silently stop every later write.
                    if let ids {
                        let isFirst = self.walkerID == nil
                        self.walkerID = ids.walker_id
                        self.deviceID = ids.device_id
                        self.lastError = nil
                        // Only on the first registration, not on a device-facts refresh.
                        if isFirst { self.closeAbandonedTrips(walkerID: ids.walker_id, client: client) }
                    }
                    self.registering = false
                    self.updateStatus()
                }
            } catch {
                await MainActor.run {
                    self?.registering = false           // let the next tick try again
                    self?.note(error)
                }
            }
        }
    }

    /// Close any walk this walker left open, as `abandoned`.
    ///
    /// A `trips` row is closed by `endTrip`, which needs the app to still be alive. A process that
    /// is killed mid-walk — iOS reclaiming memory, a crash, the e2e harness terminating the app —
    /// never gets there, and the row sits for ever with a null `ended_at` and a null `outcome`,
    /// which makes `trip_summary` accumulate walks that look like they are still happening.
    /// `abandoned` is the third outcome in the schema's check constraint and this is the only
    /// thing that writes it.
    ///
    /// ⚠ Scoped to rows that started BEFORE this process did, so it can never close the walk this
    /// launch is about to open (or has just opened) — a route can start inside the registration
    /// round trip, which is the same race `beginTrip` already has to defer around.
    /// Called once, right after `register_cane` returns.
    private func closeAbandonedTrips(walkerID: String, client: SupabaseClient) {
        struct Abandon: Encodable {
            let ended_at: String
            let outcome = "abandoned"
        }
        let cutoff = OpenCaneEvent.iso8601(Self.processStart)
        Task { [weak self] in
            do {
                try await client.patch("trips", filter: [
                    URLQueryItem(name: "walker_id", value: "eq.\(walkerID)"),
                    URLQueryItem(name: "ended_at", value: "is.null"),
                    URLQueryItem(name: "started_at", value: "lt.\(cutoff)"),
                ], row: Abandon(ended_at: cutoff))
            } catch {
                await MainActor.run { self?.note(error) }
            }
        }
    }

    /// When this process launched. Every trip older than this is a previous launch's.
    @ObservationIgnored private static let processStart = Date()

    /// `register_cane`'s return value.
    private struct RegisterResult: Decodable {
        let walker_id: String
        let device_id: String
    }

    /// Attach an alert to every registered family address, so `family_alert_feed` can say who was
    /// told rather than only that something fired.
    ///
    /// Best effort in both directions: an alert with no recipients recorded is still an alert, and
    /// a contact whose `last_alerted_at` stamp fails to land has still been told. Only
    /// **registered** contacts are linked — an address the bot has not accepted yet is not on the
    /// list it delivers to, so claiming it was notified would be a lie in the demo's own table.
    private func linkRecipients(alertID: String, client: SupabaseClient, walkerID: String) async {
        struct Contact: Decodable { let id: String }
        struct Link: Encodable {
            let alert_id: String
            let contact_id: String
        }
        do {
            let data = try await client.select("family_contacts", query: [
                URLQueryItem(name: "select", value: "id"),
                URLQueryItem(name: "walker_id", value: "eq.\(walkerID)"),
                URLQueryItem(name: "is_registered", value: "is.true"),
            ])
            let contacts = (try? JSONDecoder().decode([Contact].self, from: data)) ?? []
            guard !contacts.isEmpty else { return }

            // `alerts_sent` and `last_alerted_at` on each contact are maintained by the
            // `family_alert_recipients_bump` trigger (migration `opencane_07`), from this insert.
            // The phone deliberately does not PATCH them: a counter the client maintains can
            // disagree with the join table that is the actual evidence.
            try await client.bulkInsert(into: "family_alert_recipients",
                                        rows: contacts.map {
                                            Link(alert_id: alertID, contact_id: $0.id)
                                        })
        } catch {
            await MainActor.run { self.note(error) }
        }
    }

    // MARK: Small helpers

    /// A successful write: count it and clear the error line.
    private func count(_ rows: Int) {
        rowsUploaded += rows
        lastError = nil
        updateStatus()
    }

    /// A failed write: one readable line, never the key.
    private func note(_ error: any Error) {
        lastError = "\(error)"
        updateStatus()
    }

    /// The Settings row's single line.
    private func updateStatus() {
        guard isConfigured else { status = "Not configured"; return }
        if walkerID == nil {
            status = lastError == nil ? "Registering…" : "Offline — will register when back"
        } else if !queue.isEmpty {
            status = "\(rowsUploaded) synced · \(queue.count) queued"
        } else {
            status = "\(rowsUploaded) rows synced"
        }
    }

    /// `[String: Any]` from `TripLogger` into the Sendable JSON the row type takes.
    /// Anything unrepresentable (an `NSNull`, an object `JSONSerialization` would reject) becomes
    /// `.null` rather than being dropped, so a line's shape survives the trip.
    private static func json(_ fields: [String: Any]) -> [String: OpenCaneJSON] {
        fields.reduce(into: [:]) { out, pair in out[pair.key] = value(pair.value) }
    }

    /// One `Any` from a log record as a JSON value.
    private static func value(_ any: Any) -> OpenCaneJSON {
        switch any {
        case let v as String: return .string(v)
        case let v as Bool: return .bool(v)
        case let v as Int: return .number(Double(v))
        case let v as Double: return v.isFinite ? .number(v) : .null
        case let v as Float: return v.isFinite ? .number(Double(v)) : .null
        case let v as [Any]: return .array(v.map(value))
        case let v as [String: Any]: return .object(json(v))
        default: return .null                       // NSNull and anything else
        }
    }

    /// The `id` of the first row in a PostgREST `return=representation` body.
    private static func firstID(in data: Data) -> String? {
        struct Row: Decodable { let id: String }
        if let rows = try? JSONDecoder().decode([Row].self, from: data) { return rows.first?.id }
        return (try? JSONDecoder().decode(Row.self, from: data))?.id
    }

    /// Straight-line length of a route, metres — enough for "how long is this walk" without
    /// asking MapKit again.
    private static func routeLength(_ route: Route) -> Double? {
        let points = route.waypoints.map(\.coordinate)
        guard points.count > 1 else { return nil }
        return zip(points, points.dropFirst()).reduce(0) { $0 + GeoMath.distanceMeters($1.0, $1.1) }
    }

    /// "0.1 (1)".
    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// "iPhone17,2" — the machine identifier, which is what tells an iPhone 17 Pro Max from a
    /// phone with no LiDAR when someone is reading the table months later.
    private static var hardwareModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}
