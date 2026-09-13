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

    public static let standardDefault = CKMedicalProfile(
        name: "Aritro Bhattacharjee",
        emergencyNotes: "OpenCane White Cane User · Legally Blind · Severe Visual Field Loss",
        dateOfBirth: "May 14, 2002",
        bloodType: "O+",
        height: "5' 11\" (180 cm)",
        weight: "165 lbs (75 kg)",
        allergies: "No known drug allergies (NKDA)",
        medications: "None",
        homeAddress: "Urbana, IL",
        emergencyContactName: "Emergency Contact",
        emergencyContactPhone: "+1 (555) 234-5678",
        emergencyContactRelation: "Family",
        caneType: "130 cm · Rolling Ball Tip",
        organDonor: true
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

    public var profile: CKMedicalProfile {
        didSet {
            save()
        }
    }

    public var mobilityStats = CKMobilityStats()
    public private(set) var isFetchingPedometer = false

    @ObservationIgnored private let pedometer = CMPedometer()

    public init() {
        if let data = UserDefaults.standard.data(forKey: Self.profileKey),
           let decoded = try? JSONDecoder().decode(CKMedicalProfile.self, from: data) {
            self.profile = decoded
        } else {
            self.profile = .standardDefault
        }
        let trips = UserDefaults.standard.integer(forKey: Self.tripsKey)
        self.mobilityStats.completedTrips = max(trips, 0)
        refreshMobilityStats()
    }

    /// Saves the medical profile to UserDefaults.
    public func save() {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: Self.profileKey)
        }
    }

    /// Increments the count of completed walks.
    public func recordCompletedTrip() {
        mobilityStats.completedTrips += 1
        UserDefaults.standard.set(mobilityStats.completedTrips, forKey: Self.tripsKey)
    }

    /// Queries CMPedometer for today's steps and walking distance from midnight to now.
    public func refreshMobilityStats() {
        guard CMPedometer.isStepCountingAvailable() else { return }
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)

        isFetchingPedometer = true
        pedometer.queryPedometerData(from: startOfDay, to: now) { [weak self] data, error in
            Task { @MainActor in
                guard let self else { return }
                self.isFetchingPedometer = false
                guard let data, error == nil else { return }
                let steps = data.numberOfSteps.intValue
                let dist = data.distance?.doubleValue ?? 0.0
                let pace = data.currentPace?.doubleValue ?? 0.0
                self.mobilityStats.todaySteps = steps
                self.mobilityStats.todayDistanceMeters = dist
                if pace > 0 {
                    self.mobilityStats.averagePaceMps = 1.0 / pace
                } else if dist > 0 {
                    let seconds = now.timeIntervalSince(startOfDay)
                    self.mobilityStats.averagePaceMps = min(2.0, dist / max(60, seconds))
                }
                self.mobilityStats.lastUpdated = now
            }
        }
    }
}
