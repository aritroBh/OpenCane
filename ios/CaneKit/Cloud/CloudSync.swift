//
//  CloudSync.swift
//  CaneKit
//
//  The consent-gated MVP mirror: only durable safety records leave the phone after explicit
//  privacy opt-in. Cloud keys alone never authorize uploading identity, medical data or location.
//
//  What moved (Step 45). Before this, each kind of state lived in exactly one place on one phone:
//
//    | On the phone                                  | Also in Postgres             |
//    |-----------------------------------------------|------------------------------|
//    | cane / device identity                         | `walkers`, `devices`         |
//    | `familyContactEmails`                          | `family_contacts`            |
//    | `MedicalProfileStore`'s profile blob           | `medical_profiles`           |
//    | one completed guided walk                      | `trips`                      |
//    | `Documents/hazards/*.geojson` + JPEGs          | `hazards` + `hazard-photos`  |
//    | `OpenCaneEvent`s sent to the alert bot         | `family_alerts`              |
//
//  ⚠ **The phone is still the source of truth.** Every local writer writes exactly what it wrote
//  before; this class is fed from the same call sites and never stands between a detection and a
//  cue. The maintenance loop retries only registration and deferred trip summaries, and a walk
//  with no signal is still a complete walk on disk. Turning sharing off cancels future writes and
//  drops deferred work; existing remote rows are not implicitly deleted.
//
//  ⚠ **Nothing here may `await` on the cue path.** Effects run in detached tasks. Detailed logs,
//  posts, settings, mobility, conversations and launch recovery remain local-only in the MVP.
//
//  Owner: `AppModel.cloud` (one instance). `start()` once from `AppModel.start()`; the writers are
//  called from route start/end, `AppModel.recordHazard`, `FamilyAlerts.send`, Medical ID saves
//  and `saveFamilyContacts()`. Module `cloud` in docs/CODE_REFERENCE.md.
//
//  Threading / isolation: `@MainActor @Observable`. `SupabaseClient` is `nonisolated` and every
//  request runs off the main actor inside a detached-by-isolation `async` call.
//
//  Key invariants:
//    · Every table is keyed on `walkers.id`, so nothing can be written before `register_cane`
//      returns. Registration is idempotent and retried on the flush loop. What happens meanwhile
//      differs by writer, deliberately: a walk's `trips` row is **deferred** and opened the
//      moment ids arrive, while a stale hazard or alert is dropped rather than replayed.
//    · The family email list goes through `save_family_contacts` ONLY. It is never put in a
//      alert payload, never in a `family_alerts` row, and never shown to the summarizer
//      model (`FamilyContacts`, `AlertSummarizer`). It is the most personal thing this app holds.
//    · Photo uploads are capped at `CloudBatchPolicy.maxPhotoUploads`, matching `HazardLog`.
//  Tests: the retained wire rows live in `CloudSchema` / `CloudSchemaTests` (CaneKitLogic).
//  This class is the effectful shell; verify it by walking with the phone and checking a `trips`
//  row.
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
    /// One line for the Settings row: "Synced 12 rows" or "Not configured".
    private(set) var status = "Not configured"
    /// Always zero in the MVP: detailed event uploads remain on the phone.
    private(set) var queuedRows = 0
    /// Rows accepted by Postgres this session.
    private(set) var rowsUploaded = 0
    /// Last failure, one line. Cleared by the next success.
    private(set) var lastError: String?
    /// True once `register_cane` has returned ids.
    var isRegistered: Bool { walkerID != nil }
    /// Explicit privacy consent. False on a fresh install, even when cloud keys are present.
    private(set) var sharingEnabled = false

    /// The walk currently open in `trips`, or nil.
    private(set) var tripID: String?

    // MARK: Identity

    /// `walkers.id`, from `register_cane`. Every table is keyed on it.
    private(set) var walkerID: String?
    /// `devices.id`, from `register_cane`.
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
    /// The 5 s flush loop; cancelled by `stop()`.
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// Photos uploaded this session (capped at `policy.maxPhotoUploads`).
    @ObservationIgnored private var photosUploaded = 0
    /// Set once the app has asked to register and the RPC is in flight or done, so the flush loop
    /// does not start a second registration.
    @ObservationIgnored private var registering = false
    /// Kept so a late `start()` can register with the right facts.
    @ObservationIgnored private var pendingRegistration: RegistrationFacts?
    /// Changes whenever consent changes. Every asynchronous writer captures this value and
    /// re-checks it after an await, so opting out cannot let a queued continuation write later.
    @ObservationIgnored private var sharingGeneration: UInt64 = 0

    init(client: SupabaseClient? = SupabaseClient.fromSecrets()) {
        self.client = client
        if client != nil { status = "Cloud sharing is off" }
    }

    /// Enables or disables the MVP cloud mirror. Disabling cancels future writes and clears
    /// deferred registration/trip work so withdrawn consent cannot cause a delayed upload.
    func setSharingEnabled(_ enabled: Bool) {
        sharingGeneration &+= 1
        sharingEnabled = enabled
        guard !enabled else {
            updateStatus()
            return
        }
        flushTask?.cancel()
        flushTask = nil
        pendingTrip = nil
        pendingClose = nil
        pendingRegistration = nil
        tripID = nil
        walkerID = nil
        deviceID = nil
        registering = false
        openingTrip = false
        queuedRows = 0
        status = client == nil ? "Not configured" : "Cloud sharing is off"
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

    /// Register the cane and start the maintenance loop.
    /// Idempotent — `register_cane` upserts, so calling it every launch is the design. Safe to
    /// call with no network: the registration is retried by the flush loop.
    /// Caller: `AppModel.start()`.
    func start(_ facts: RegistrationFacts) {
        guard client != nil, sharingEnabled else { return }
        pendingRegistration = facts
        registerIfNeeded()
        guard flushTask == nil else { return }
        // ⚠ The interval comes from `CloudBatchPolicy`, never a literal here: it is a number that
        // decides when a row leaves the phone, so it lives in CaneKitLogic with a test (hard rule 3).
        let interval = policy.flushInterval
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                await self?.tick()
            }
        }
    }

    /// Prompt registration or a deferred trip-summary write. Called from
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

    /// The phone keeps its detailed JSONL log locally. The MVP cloud stores only the completed
    /// trip summary, never the high-volume `trip_events` stream.
    ///
    /// Caller: `TripLogger.onRecord`. Kept as a no-op compatibility seam so logging remains
    /// strictly local without adding a branch to the cue path.
    func logEvent(kind: String, tSeconds: Double, fields: [String: Any]) {
        _ = (kind, tSeconds, fields)
    }

    /// Open a `trips` summary row.
    /// Caller: `AppModel.startRouteNow`, after the route is built.
    ///
    /// ⚠ A route can start before `register_cane` has returned — on a cold launch the walker can
    /// press Start in well under the round trip, and the e2e scenarios do it every run. Measured
    /// 2026-09-13: an e2e walk wrote zero `trips`, because this method used to `guard let
    /// walkerID` and give up. The open is therefore *deferred*, not dropped: it is held until
    /// registration lands and then sent with the start time it actually had.
    func beginTrip(destination: String?, cueLevel: String, cuePlace: String, batteryPct: Int,
                   logFileName: String?, start: GeoFix?) {
        guard client != nil, sharingEnabled else { return }
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
        openPendingTrip()
    }

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
        guard let client, sharingEnabled, let walkerID, let pending = pendingTrip,
              tripID == nil, !openingTrip else { return }
        openingTrip = true
        let row = TripOpenRow(walkerID: walkerID, deviceID: deviceID,
                              destinationName: pending.destination,
                              startedAt: pending.startedAt,
                              cueLevel: pending.cueLevel, cuePlace: pending.cuePlace,
                              batteryStartPct: pending.batteryStartPct,
                              logFileName: pending.logFileName,
                              startLat: pending.startLat, startLon: pending.startLon)
        let generation = sharingGeneration
        Task { [weak self] in
            guard await MainActor.run(body: { [weak self] in self?.isCurrent(generation) ?? false }) else { return }
            do {
                let data = try await client.insert(into: "trips", row: row, returning: true)
                let id = Self.firstID(in: data)
                await MainActor.run {
                    guard let self, self.isCurrent(generation) else { return }
                    self.tripID = id
                    self.pendingTrip = nil
                    self.openingTrip = false
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
        guard client != nil, sharingEnabled else { return }
        let patch = TripClosePatch(endedAt: OpenCaneEvent.iso8601(Date()),
                                   durationS: elapsed, distanceM: distanceM, steps: steps,
                                   stepSource: stepSource, outcome: outcome,
                                   waypointsReached: waypointsReached,
                                   batteryEndPct: batteryPct >= 0 ? batteryPct : nil,
                                   spokenSummary: spokenSummary,
                                   endLat: end?.coordinate.latitude,
                                   endLon: end?.coordinate.longitude)
        // Prompt any deferred trip open before closing it.
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
        guard let client, sharingEnabled, let id = tripID else { return }
        tripID = nil
        let generation = sharingGeneration
        Task { [weak self] in
            guard await MainActor.run(body: { [weak self] in self?.isCurrent(generation) ?? false }) else { return }
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
        guard let client, sharingEnabled, let walkerID else { return }
        let wantsPhoto = jpeg != nil && photosUploaded < policy.maxPhotoUploads
        if wantsPhoto { photosUploaded += 1 }
        let photoName = wantsPhoto ? "\(walkerID)/\(UUID().uuidString.lowercased()).jpg" : nil
        let trip = tripID
        let generation = sharingGeneration

        Task { [weak self] in
            guard await MainActor.run(body: { [weak self] in self?.isCurrent(generation) ?? false }) else { return }
            var uploaded: String?
            if let photoName, let jpeg {
                uploaded = try? await client.uploadObject(bucket: "hazard-photos",
                                                          path: photoName, data: jpeg)
                // This object has no row if consent was withdrawn while the upload was in flight.
                // Remove the orphan rather than leaving a camera frame behind with no local owner.
                let stillCurrent = await MainActor.run(body: { [weak self] in self?.isCurrent(generation) ?? false })
                if !stillCurrent {
                    if uploaded != nil { try? await client.deleteObject(bucket: "hazard-photos", path: photoName) }
                    return
                }
            }
            guard await MainActor.run(body: { [weak self] in self?.isCurrent(generation) ?? false }) else { return }
            let row = HazardRow(record: record, walkerID: walkerID, tripID: trip,
                                photoPath: uploaded)
            do {
                try await client.insert(into: "hazards", row: row)
                await MainActor.run {
                    guard let self, self.isCurrent(generation) else { return }
                    self.count(1)
                }
            } catch {
                await MainActor.run { self?.note(error) }
            }
        }
    }

    /// Posts remain on the phone (`PostStore`); the MVP has no cloud `posts` table.
    /// Caller: `ConversationCoordinator.dropPost(name:)` via `AppModel`.
    func recordPost(_ marker: WalkMarker) {
        _ = marker
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
        guard let client, sharingEnabled, let walkerID else { return }
        guard let row = FamilyAlertRow(event: event, walkerID: walkerID, tripID: tripID,
                                       now: Date(), deliveryStatus: status,
                                       webhookStatusCode: httpStatus, errorMessage: error)
        else { return }
        let generation = sharingGeneration
        Task { [weak self] in
            guard await MainActor.run(body: { [weak self] in self?.isCurrent(generation) ?? false }) else { return }
            do {
                try await client.insert(into: "family_alerts", row: row)
                await MainActor.run {
                    guard let self, self.isCurrent(generation) else { return }
                    self.count(1)
                }
            } catch {
                await MainActor.run { self?.note(error) }
            }
        }
    }

    /// Conversation transcripts stay on the phone only; the MVP has no cloud history table.
    /// Caller: `ConversationCoordinator`, after an answer is spoken.
    func recordConversationTurn(question: String?, answer: String?, route: String?,
                                tool: String?, latencyMs: Int?, fix: GeoFix?) {
        _ = (question, answer, route, tool, latencyMs, fix)
    }

    // MARK: Writers — configuration

    /// Settings remain local (`UserDefaults`); the MVP has no cloud settings snapshot.
    func saveSettings(_ row: DeviceSettingsRow) {
        _ = row
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
        guard let client, sharingEnabled, let walkerID else { return }
        struct Args: Encodable {
            let p_walker_id: String
            let p_emails: [String]
            let p_registered: Bool
        }
        let args = Args(p_walker_id: walkerID, p_emails: emails, p_registered: registered)
        let generation = sharingGeneration
        Task { [weak self] in
            guard await MainActor.run(body: { [weak self] in self?.isCurrent(generation) ?? false }) else { return }
            do {
                try await client.rpc("save_family_contacts", body: args)
                await MainActor.run {
                    guard let self, self.isCurrent(generation) else { return }
                    self.count(emails.count)
                }
            } catch {
                await MainActor.run { self?.note(error) }
            }
        }
    }

    /// Push the Medical ID a first responder would read. Upserted on `walker_id`.
    /// Caller: `AppModel`, on `MedicalProfileStore`'s save.
    func saveMedicalProfile(_ profile: CKMedicalProfile) {
        guard let client, sharingEnabled, let walkerID else { return }
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
        let generation = sharingGeneration
        Task { [weak self] in
            guard await MainActor.run(body: { [weak self] in self?.isCurrent(generation) ?? false }) else { return }
            do {
                try await client.upsert(into: "medical_profiles", row: row, onConflict: "walker_id")
                await MainActor.run {
                    guard let self, self.isCurrent(generation) else { return }
                    self.count(1)
                }
            } catch {
                await MainActor.run { self?.note(error) }
            }
        }
    }

    /// Mobility statistics remain local; the MVP has no cloud day-by-day activity table.
    func saveMobility(_ stats: CKMobilityStats) {
        _ = stats
    }

    /// Launch recovery stays on the phone; the MVP has no cloud launch telemetry.
    func recordLaunch(mode: LaunchMode, clearedKeys: [String]) {
        _ = (mode, clearedKeys)
    }

    /// Route geometry remains in the bundled JSON or MapKit; the MVP cloud keeps only a trip's
    /// destination and summary.
    /// Caller: `AppModel.startRouteNow`, after `beginTrip`.
    func uploadRoute(_ route: Route, source: String) {
        _ = (route, source)
    }

    // MARK: Flush loop

    /// One pass: register if needed and open a deferred trip summary.
    private func tick() async {
        guard client != nil, sharingEnabled else { return }
        registerIfNeeded()
        openPendingTrip()
        updateStatus()
    }

    /// Re-run `register_cane` with fresh hardware facts, so the `devices` row keeps up when the
    /// watch or the AirPods connect or disconnect mid-session. Idempotent (the RPC upserts on
    /// `install_id` + `vendor_id`), and a no-op before the first registration has landed — that
    /// one is already on its way with whatever was true at launch.
    /// Callers: `AppModel.recordDeviceCapabilities()` (start, watch state change, audio route change).
    func updateDeviceFacts(_ facts: RegistrationFacts) {
        guard client != nil, sharingEnabled, walkerID != nil else { return }
        pendingRegistration = facts
        sendRegistration(facts)
    }

    /// Fire `register_cane` once and keep the ids. Retried by `tick()` until it succeeds.
    private func registerIfNeeded() {
        guard client != nil, sharingEnabled, walkerID == nil, !registering, let facts = pendingRegistration else { return }
        registering = true
        sendRegistration(facts)
    }

    /// The RPC itself. Shared by the first registration and every later device-facts refresh.
    private func sendRegistration(_ facts: RegistrationFacts) {
        guard let client, sharingEnabled else { return }
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
        let generation = sharingGeneration
        Task { [weak self] in
            guard await MainActor.run(body: { [weak self] in self?.isCurrent(generation) ?? false }) else { return }
            do {
                let data = try await client.rpc("register_cane", body: args)
                let ids = try? JSONDecoder().decode(RegisterResult.self, from: data)
                await MainActor.run {
                    guard let self, self.isCurrent(generation) else { return }
                    // ⚠ Only assign on a real answer. A refresh (`updateDeviceFacts`) whose body
                    // failed to decode must not wipe the ids the cane is already using — that
                    // would silently stop every later write.
                    if let ids {
                        let isFirst = self.walkerID == nil
                        self.walkerID = ids.walker_id
                        self.deviceID = ids.device_id
                        self.lastError = nil
                        // Only on the first registration, not on a device-facts refresh.
                        if isFirst {
                            self.closeAbandonedTrips(walkerID: ids.walker_id, client: client,
                                                     generation: generation)
                        }
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
    private func closeAbandonedTrips(walkerID: String, client: SupabaseClient,
                                     generation: UInt64) {
        struct Abandon: Encodable {
            let ended_at: String
            let outcome = "abandoned"
        }
        let cutoff = OpenCaneEvent.iso8601(Self.processStart)
        Task { [weak self] in
            guard await MainActor.run(body: { [weak self] in self?.isCurrent(generation) ?? false }) else { return }
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

    // MARK: Small helpers

    /// True only while the async writer that captured `generation` still has consent. This is
    /// checked before a request and after every await that could outlive an opt-out.
    private func isCurrent(_ generation: UInt64) -> Bool {
        client != nil && sharingEnabled && generation == sharingGeneration
    }

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
        } else {
            status = "\(rowsUploaded) rows synced"
        }
    }

    /// The `id` of the first row in a PostgREST `return=representation` body.
    private static func firstID(in data: Data) -> String? {
        struct Row: Decodable { let id: String }
        if let rows = try? JSONDecoder().decode([Row].self, from: data) { return rows.first?.id }
        return (try? JSONDecoder().decode(Row.self, from: data))?.id
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
