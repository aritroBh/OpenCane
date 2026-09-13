//
//  SupabaseClient.swift
//  CaneKit
//
//  Supabase backend client for OpenCane walker telemetry, Emergency Medical ID, mobility days,
//  hazard mapping, trips, and family alert feeds.
//
//  Hard rule 4 (AGENTS.md): secrets live only in Secrets.plist (git-ignored).
//  Hard rule 2 (AGENTS.md): native URLSession, no third-party SDKs, Swift 6 concurrency safe.
//
//  Tables accessed via PostgREST:
//    - walkers: identity, cane_id, install_id, last_seen_at
//    - medical_profiles: emergency medical ID cards (upsert via merge-duplicates)
//    - mobility_days: daily step and distance totals (upsert via merge-duplicates)
//    - hazards: obstacle sightings (drop-offs, signs, caution obstacles) for the hazard map
//    - trips: walk lifecycle (start, arrived, stopped, distance, steps, summaries)
//    - devices: hardware metadata (iPhone model, iOS version, LiDAR, Watch/AirPods status)
//    - family_alerts: alert delivery records
//

import CaneKitLogic
import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

/// Thread-safe client for OpenCane's Supabase backend.
public final class SupabaseClient: Sendable {
    public static let shared = SupabaseClient()

    private static let log = Logger(subsystem: "com.aritro.canekit", category: "supabase")
    private static let requestTimeout: TimeInterval = 10

    /// In-memory cache for resolved walker UUID to avoid redundant lookups.
    private let cachedWalkerID = OSAllocatedUnfairLock<String?>(initialState: nil)

    public init() {
        // Hydrate from UserDefaults if previously resolved
        let stored = UserDefaults.standard.string(forKey: "opencane_supabase_walker_id")
        cachedWalkerID.withLock { $0 = stored }
    }

    /// Whether Supabase configuration keys are present.
    public var isConfigured: Bool {
        baseURL != nil && apiKey != nil
    }

    private var baseURL: URL? {
        let env = ProcessInfo.processInfo.environment
        let raw = env["SUPABASE_URL"] ?? Secrets.string("SUPABASE_URL")
        guard let raw, let url = URL(string: raw), url.scheme == "https" else { return nil }
        return url
    }

    private var apiKey: String? {
        let env = ProcessInfo.processInfo.environment
        return env["SUPABASE_PUBLISHABLE_KEY"] ?? Secrets.string("SUPABASE_PUBLISHABLE_KEY")
    }

    // MARK: - PostgREST Helper

    private func makeRequest(endpoint: String, method: String = "GET", query: [URLQueryItem]? = nil, prefer: String? = nil, body: Data? = nil) -> URLRequest? {
        guard let base = baseURL, let key = apiKey else { return nil }
        var components = URLComponents(url: base.appendingPathComponent("rest/v1/\(endpoint)"), resolvingAgainstBaseURL: true)
        if let query, !query.isEmpty {
            components?.queryItems = query
        }
        guard let targetURL = components?.url else { return nil }

        var req = URLRequest(url: targetURL, timeoutInterval: Self.requestTimeout)
        req.httpMethod = method
        req.setValue(key, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let prefer {
            req.setValue(prefer, forHTTPHeaderField: "Prefer")
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    // MARK: - Walker Identity

    /// In-flight task memoization to prevent duplicate walker registration races (Finding C3)
    private let inFlightResolve = OSAllocatedUnfairLock<Task<String?, Never>?>(initialState: nil)

    /// Resolves the walker record for this phone. Queries by install ID or registers a new walker.
    public func resolveWalkerID(displayName: String = "Aritro Bhattacharjee", caneID: String = "opencane-01") async -> String? {
        if let cached = cachedWalkerID.withLock({ $0 }), !cached.isEmpty {
            return cached
        }

        if let existing = inFlightResolve.withLock({ $0 }) {
            return await existing.value
        }

        let task = Task<String?, Never> {
            await performResolveWalkerID(displayName: displayName, caneID: caneID)
        }
        inFlightResolve.withLock { $0 = task }
        let result = await task.value
        inFlightResolve.withLock { $0 = nil }
        return result
    }

    private func performResolveWalkerID(displayName: String, caneID: String) async -> String? {
        guard isConfigured else { return nil }

        let installID = UserDefaults.standard.string(forKey: "opencane_install_id") ?? {
            let newID = UUID().uuidString
            UserDefaults.standard.set(newID, forKey: "opencane_install_id")
            return newID
        }()

        // 1. Try to find walker specifically matching THIS device's install_id (Finding C2)
        let query = [
            URLQueryItem(name: "install_id", value: "eq.\(installID)"),
            URLQueryItem(name: "select", value: "id,install_id,display_name"),
            URLQueryItem(name: "limit", value: "1")
        ]
        if let req = makeRequest(endpoint: "walkers", method: "GET", query: query) {
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                   let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                   let first = list.first,
                   let id = first["id"] as? String {
                    cachedWalkerID.withLock { $0 = id }
                    UserDefaults.standard.set(id, forKey: "opencane_supabase_walker_id")
                    await touchWalker(id: id)
                    return id
                }
            } catch {
                Self.log.error("Walker lookup error: \(error.localizedDescription, privacy: .public)")
            }
        }

        // 2. Register walker if not found for this install_id
        let payload: [String: Any] = [
            "install_id": installID,
            "display_name": displayName,
            "cane_id": caneID
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }

        if let req = makeRequest(endpoint: "walkers", method: "POST", prefer: "return=representation", body: body) {
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                   let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                   let first = list.first,
                   let id = first["id"] as? String {
                    cachedWalkerID.withLock { $0 = id }
                    UserDefaults.standard.set(id, forKey: "opencane_supabase_walker_id")
                    return id
                }
            } catch {
                Self.log.error("Walker registration error: \(error.localizedDescription, privacy: .public)")
            }
        }

        return nil
    }

    private func touchWalker(id: String) async {
        let nowISO = OpenCaneEvent.iso8601(Date())
        let payload: [String: Any] = ["last_seen_at": nowISO]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let query = [URLQueryItem(name: "id", value: "eq.\(id)")]
        if let req = makeRequest(endpoint: "walkers", method: "PATCH", query: query, body: body) {
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    // MARK: - Medical Profile Sync

    /// Upserts the emergency medical ID card to Supabase `medical_profiles`.
    @discardableResult
    public func syncMedicalProfile(_ profile: CKMedicalProfile) async -> Bool {
        guard let walkerID = await resolveWalkerID(displayName: profile.name, caneID: "opencane-01") else {
            return false
        }

        let payload: [String: Any] = [
            "walker_id": walkerID,
            "full_name": profile.name,
            "date_of_birth": profile.dateOfBirth,
            "emergency_notes": profile.emergencyNotes,
            "blood_type": profile.bloodType,
            "height": profile.height,
            "weight": profile.weight,
            "allergies": profile.allergies,
            "medications": profile.medications,
            "home_address": profile.homeAddress,
            "emergency_contact_name": profile.emergencyContactName,
            "emergency_contact_phone": profile.emergencyContactPhone,
            "emergency_contact_relation": profile.emergencyContactRelation,
            "cane_type": profile.caneType,
            "organ_donor": profile.organDonor,
            "updated_at": OpenCaneEvent.iso8601(Date())
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        let query = [URLQueryItem(name: "on_conflict", value: "walker_id")]
        guard let req = makeRequest(endpoint: "medical_profiles", method: "POST", query: query, prefer: "resolution=merge-duplicates,return=representation", body: body) else {
            return false
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(status) {
                Self.log.info("Medical profile synchronized to Supabase successfully")
                return true
            }
            Self.log.error("Failed to sync medical profile: HTTP \(status)")
        } catch {
            Self.log.error("Medical profile sync error: \(error.localizedDescription, privacy: .public)")
        }
        return false
    }

    // MARK: - Mobility Stats Sync

    /// Upserts daily mobility totals to Supabase `mobility_days`.
    @discardableResult
    public func syncMobilityStats(_ stats: CKMobilityStats, date: Date = Date()) async -> Bool {
        guard let walkerID = await resolveWalkerID() else { return false }

        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let dayString = String(format: "%04d-%02d-%02d", comps.year ?? 2026, comps.month ?? 1, comps.day ?? 1)
        let payload: [String: Any] = [
            "walker_id": walkerID,
            "day": dayString,
            "steps": stats.todaySteps,
            "distance_m": Int(stats.todayDistanceMeters),
            "active_seconds": Int(stats.todayActiveSeconds),
            "completed_trips": stats.completedTrips,
            "average_pace_mps": stats.averagePaceMps,
            "updated_at": OpenCaneEvent.iso8601(date)
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        let query = [URLQueryItem(name: "on_conflict", value: "walker_id,day")]
        guard let req = makeRequest(endpoint: "mobility_days", method: "POST", query: query, prefer: "resolution=merge-duplicates,return=representation", body: body) else {
            return false
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(status) {
                Self.log.info("Mobility stats for \(dayString, privacy: .public) synced to Supabase")
                return true
            }
            Self.log.error("Failed to sync mobility stats: HTTP \(status)")
        } catch {
            Self.log.error("Mobility sync error: \(error.localizedDescription, privacy: .public)")
        }
        return false
    }

    // MARK: - Hazard Logging

    /// Posts an obstacle or ground hazard detection to Supabase `hazards` table.
    @discardableResult
    public func recordHazard(
        kind: String,
        source: String,
        severity: String = "warn",
        spokenText: String,
        whatItSaw: String? = nil,
        lat: Double? = nil,
        lon: Double? = nil,
        accuracyM: Double? = nil,
        distanceM: Double? = nil,
        heightM: Double? = nil,
        direction: String? = nil,
        headingDeg: Double? = nil,
        speedMps: Double? = nil,
        routeName: String? = nil,
        instruction: String? = nil,
        detectedAt: Date = Date()
    ) async -> Bool {
        guard let walkerID = await resolveWalkerID() else { return false }

        var payload: [String: Any] = [
            "walker_id": walkerID,
            "kind": kind,
            "source": source,
            "severity": severity,
            "spoken_text": spokenText,
            "detected_at": OpenCaneEvent.iso8601(detectedAt)
        ]

        if let whatItSaw { payload["what_it_saw"] = whatItSaw }
        if let lat { payload["lat"] = lat }
        if let lon { payload["lon"] = lon }
        if let accuracyM { payload["accuracy_m"] = accuracyM }
        if let distanceM { payload["distance_m"] = distanceM }
        if let heightM { payload["height_m"] = heightM }
        if let direction { payload["direction"] = direction }
        if let headingDeg { payload["heading_deg"] = headingDeg }
        if let speedMps { payload["speed_mps"] = speedMps }
        if let routeName { payload["route_name"] = routeName }
        if let instruction { payload["instruction"] = instruction }

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        guard let req = makeRequest(endpoint: "hazards", method: "POST", prefer: "return=representation", body: body) else {
            return false
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(status) {
                Self.log.info("Hazard '\(kind, privacy: .public)' logged to Supabase")
                return true
            }
            Self.log.error("Failed to log hazard: HTTP \(status)")
        } catch {
            Self.log.error("Hazard record error: \(error.localizedDescription, privacy: .public)")
        }
        return false
    }

    // MARK: - Family Alert Feed Logging

    /// Mirrors a family alert event to Supabase `family_alerts`.
    @discardableResult
    public func recordFamilyAlert(
        event: OpenCaneEvent,
        deliveryStatus: String = "posted",
        statusCode: Int? = 200,
        errorMessage: String? = nil,
        now: Date = Date()
    ) async -> Bool {
        guard let walkerID = await resolveWalkerID() else { return false }

        var payload: [String: Any] = [
            "walker_id": walkerID,
            "event_type": event.type.rawValue,
            "severity": event.severity?.rawValue ?? "info",
            "occurred_at": event.timestamp ?? OpenCaneEvent.iso8601(now),
            "delivery_status": deliveryStatus
        ]

        if let lat = event.lat { payload["lat"] = lat }
        if let lng = event.lng { payload["lng"] = lng }
        if let accuracy = event.accuracyM { payload["accuracy_m"] = accuracy }
        if let heading = event.heading { payload["heading_deg"] = heading }
        if let speed = event.speedMps { payload["speed_mps"] = speed }
        if let note = event.note { payload["note"] = note }
        if let label = event.label { payload["label"] = label }
        if let cane = event.caneID { payload["cane_id"] = cane }
        if let bat = event.batteryPct { payload["battery_pct"] = bat }
        if let sc = statusCode { payload["webhook_status_code"] = sc }
        if let err = errorMessage { payload["error_message"] = err }

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        guard let req = makeRequest(endpoint: "family_alerts", method: "POST", prefer: "return=representation", body: body) else {
            return false
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (200...299).contains(status)
        } catch {
            Self.log.error("Family alert sync error: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Hardware Metadata

    /// Upserts device capabilities into Supabase `devices`.
    @discardableResult
    public func recordDevice(
        hasLiDAR: Bool,
        watchPaired: Bool,
        airPodsPaired: Bool
    ) async -> Bool {
        guard let walkerID = await resolveWalkerID() else { return false }

        #if canImport(UIKit)
        let device = UIDevice.current
        let deviceName = device.name
        let systemVersion = "\(device.systemName) \(device.systemVersion)"
        let vendorID = device.identifierForVendor?.uuidString ?? "unknown-vendor"
        #else
        let deviceName = "Unknown"
        let systemVersion = "iOS 27.0"
        let vendorID = "unknown-vendor"
        #endif

        var sysInfo = utsname()
        uname(&sysInfo)
        let modelIdentifier = withUnsafeBytes(of: &sysInfo.machine) { raw in
            raw.split(separator: 0).first.flatMap { String(decoding: $0, as: UTF8.self) }
        } ?? "iPhone"

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"

        let payload: [String: Any] = [
            "walker_id": walkerID,
            "vendor_id": vendorID,
            "device_name": deviceName,
            "model": modelIdentifier,
            "system_version": systemVersion,
            "app_version": appVersion,
            "has_lidar": hasLiDAR,
            "watch_paired": watchPaired,
            "airpods_paired": airPodsPaired,
            "last_seen_at": OpenCaneEvent.iso8601(Date())
        ]

        let query = [URLQueryItem(name: "on_conflict", value: "vendor_id")]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        guard let req = makeRequest(endpoint: "devices", method: "POST", query: query, prefer: "resolution=merge-duplicates,return=representation", body: body) else {
            return false
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (200...299).contains(status)
        } catch {
            Self.log.error("Device sync error: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
