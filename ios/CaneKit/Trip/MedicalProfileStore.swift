//
//  MedicalProfileStore.swift
//  CaneKit
//
//  Medical ID card and mobility fitness store. Provides Apple Health-style emergency
//  identification (visual impairment alert, blood type, allergies, medications, emergency
//  contacts, home address) and daily mobility fitness metrics (today's steps, distance, active time).
//
//  Owner: `AppModel.medicalProfile` (one instance).
//  Module `navigation-trip` in docs/CODE_REFERENCE.md.
//

import CoreMotion
import Foundation
import Observation

/// The persisted emergency Medical ID data.
public struct CKMedicalProfile: Codable, Sendable, Equatable {
    public var name: String
    public var emergencyNotes: String
    public var dateOfBirth: String
    public var bloodType: String
    public var height: String
    public var weight: String
    public var allergies: String
    public var medications: String
    public var homeAddress: String
    public var emergencyContactName: String
    public var emergencyContactPhone: String
    public var emergencyContactRelation: String
    public var caneType: String
    public var organDonor: Bool

    /// A privacy-safe first-run profile. Real identity, medical and contact values are entered by
    /// the walker (or a trusted helper) in the editor; no person's PII is shipped in the binary.
    /// Existing profiles remain on-device and are never overwritten by this default.
    public static let standardDefault = CKMedicalProfile(
        name: "Not set",
        emergencyNotes: "White cane user — add emergency notes",
        dateOfBirth: "Not set",
        bloodType: "Not set",
        height: "Not set",
        weight: "Not set",
        allergies: "Not set",
        medications: "Not set",
        homeAddress: "Not set",
        emergencyContactName: "Not set",
        emergencyContactPhone: "",
        emergencyContactRelation: "Not set",
        caneType: "Not set",
        organDonor: false
    )
}

/// Mobility and fitness metrics for daily cane use.
public struct CKMobilityStats: Sendable, Equatable {
    public var todaySteps: Int = 0
    public var todayDistanceMeters: Double = 0
    public var todayActiveSeconds: TimeInterval = 0
    public var completedTrips: Int = 0
    public var averagePaceMps: Double = 0
    public var lastUpdated: Date = Date()
}

@MainActor
@Observable
public final class MedicalProfileStore {
    private static let profileKey = "opencane_medical_profile"
    private static let tripsKey = "opencane_completed_trips_count"
    /// The fake number an earlier build shipped with; `init` clears it rather than copying a
    /// contact into a new binary. A number the walker typed is left untouched.
    private static let placeholderPhone = "+1 (555) 234-5678"

    public var profile: CKMedicalProfile {
        didSet {
            save()
            onProfileSaved?(profile)
        }
    }

    /// The Medical ID after every edit, for the cloud mirror (`CloudSync.saveMedicalProfile`).
    /// Set once by `AppModel.startCloudMirror()`; nil = no mirror, and the profile stays on the
    /// phone exactly as before.
    @ObservationIgnored public var onProfileSaved: ((CKMedicalProfile) -> Void)?

    /// Today's mobility numbers after every pedometer refresh.
    ///
    /// ⚠ Since Step 60 the far end is a no-op seam (`CloudSync.saveMobility`): `mobility_days` was
    /// dropped, so these numbers never leave the phone. The hook stays wired so the call site does
    /// not have to be found again if a mobility mirror returns.
    @ObservationIgnored public var onMobilityRefreshed: ((CKMobilityStats) -> Void)?

    public var mobilityStats = CKMobilityStats()
    public private(set) var isFetchingPedometer = false

    @ObservationIgnored private let pedometer = CMPedometer()

    public init() {
        if let data = UserDefaults.standard.data(forKey: Self.profileKey),
           var decoded = try? JSONDecoder().decode(CKMedicalProfile.self, from: data) {
            if decoded.bloodType == "O+" {
                decoded.bloodType = "A-"
            }
            if decoded.caneType.contains("Rolling Ball") {
                decoded.caneType = "130 cm · Standard Tip"
            }
            // Remove only the old seeded placeholder. A number the walker typed is kept.
            if decoded.emergencyContactPhone == Self.placeholderPhone {
                decoded.emergencyContactPhone = ""
            }
            self.profile = decoded
        } else {
            self.profile = .standardDefault
        }
        let trips = UserDefaults.standard.integer(forKey: Self.tripsKey)
        self.mobilityStats.completedTrips = max(trips, 0)
        refreshMobilityStats()
    }

    /// Saves the medical profile to UserDefaults, then hands it to the cloud mirror.
    public func save() {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: Self.profileKey)
        }
        onProfileSaved?(profile)
    }

    /// Increments the count of completed walks.
    public func recordCompletedTrip() {
        mobilityStats.completedTrips += 1
        UserDefaults.standard.set(mobilityStats.completedTrips, forKey: Self.tripsKey)
        onMobilityRefreshed?(mobilityStats)
    }

    /// Queries CMPedometer for today's steps and walking distance from midnight to now.
    /// ⚠ The handler must stay `@Sendable`: CMPedometerHandler is called on CoreMotion's background queue,
    /// so without `@Sendable` the closure is inferred `@MainActor` under default isolation and traps
    /// (`_dispatch_assert_queue_fail`, signal 5).
    public func refreshMobilityStats() {
        guard CMPedometer.isStepCountingAvailable() else { return }
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)

        isFetchingPedometer = true
        pedometer.queryPedometerData(from: startOfDay, to: now) { @Sendable [weak self] data, error in
            let steps = data?.numberOfSteps.intValue
            let dist = data?.distance?.doubleValue
            let pace = data?.currentPace?.doubleValue
            let isSuccess = (error == nil && data != nil)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isFetchingPedometer = false
                guard isSuccess else { return }
                if let steps { self.mobilityStats.todaySteps = steps }
                if let dist { self.mobilityStats.todayDistanceMeters = dist }
                if let pace, pace > 0 {
                    self.mobilityStats.averagePaceMps = 1.0 / pace
                } else if let dist, dist > 0 {
                    let seconds = now.timeIntervalSince(startOfDay)
                    self.mobilityStats.averagePaceMps = min(2.0, dist / max(60, seconds))
                }
                self.mobilityStats.lastUpdated = now
                self.onMobilityRefreshed?(self.mobilityStats)
            }
        }
    }
}
