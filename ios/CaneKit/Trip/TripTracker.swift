//
//  TripTracker.swift
//  CaneKit
//
//  The arrival card's numbers: elapsed time, distance walked (integrated GPS path, gated on
//  accuracy), and steps since the route started via HealthKit (which merges the watch's count —
//  far better than a phone clamped to a sweeping cane). CMPedometer is the fallback when
//  HealthKit is unavailable or refused.
//

import CaneKitLogic
import CoreMotion
import Foundation
import HealthKit
import Observation

@MainActor
@Observable
final class TripTracker {

    private(set) var isTracking = false
    private(set) var startedAt: Date?
    private(set) var elapsed: TimeInterval = 0
    private(set) var distanceM: Double = 0
    private(set) var steps: Int?
    /// "HealthKit" / "Pedometer" / "none"
    private(set) var stepSource = "none"
    private(set) var lastError: String?

    @ObservationIgnored private let health = HKHealthStore()
    @ObservationIgnored private let pedometer = CMPedometer()
    @ObservationIgnored private var lastFix: GeoFix?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var stepQuery: HKObserverQuery?

    init() {}

    // MARK: Control

    func start() {
        guard !isTracking else { return }
        isTracking = true
        let now = Date()
        startedAt = now
        elapsed = 0
        distanceM = 0
        steps = nil
        lastFix = nil
        startSteps(from: now)
        ticker = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let s = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(s)
                tick += 1
                if tick % 10 == 0 { self.refreshHealthKitSteps() }   // HealthKit is not a live feed
            }
        }
    }

    /// Stops tracking and refreshes the step count; callers that speak the summary should
    /// `await` this so the number is fresh.
    func stop() async {
        guard isTracking else { return }
        isTracking = false
        ticker?.cancel()
        ticker = nil
        pedometer.stopUpdates()
        if let s = startedAt { elapsed = Date().timeIntervalSince(s) }
        await refreshHealthKitStepsNow()
    }

    /// Integrate distance along good fixes while actually moving (a stationary fix wanders a
    /// metre or two; CoreLocation's speed is the cheapest stationary gate).
    func ingest(_ fix: GeoFix) {
        guard isTracking, fix.accuracy >= 0, fix.accuracy <= 20 else { return }
        defer { lastFix = fix }
        guard let prev = lastFix, fix.speed > 0.5 else { return }
        let d = GeoMath.distanceMeters(prev.coordinate, fix.coordinate)
        if d < 100 { distanceM += d }                 // > 100 m between fixes = a teleport, skip
    }

    /// "CIF east entrance. 1.0 kilometers, 14 minutes, 1,300 steps."
    func spokenSummary(destination: String) -> String {
        var parts: [String] = []
        if distanceM >= 950 { parts.append(String(format: "%.1f kilometers", distanceM / 1000)) }
        else { parts.append("\(Int(distanceM.rounded())) meters") }
        let minutes = Int((elapsed / 60).rounded())
        parts.append(minutes == 1 ? "1 minute" : "\(minutes) minutes")
        if let steps { parts.append("\(steps) steps") }
        return "\(destination). " + parts.joined(separator: ", ") + "."
    }

    // MARK: Steps

    /// HealthKit never reveals whether a *read* was denied (a denied query just returns nothing),
    /// so the pedometer always runs too; HealthKit wins whenever it reports a count.
    private func startSteps(from start: Date) {
        startPedometer(from: start)
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let type = HKQuantityType(.stepCount)
        health.requestAuthorization(toShare: [], read: [type]) { [weak self] _, error in
            let message = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let message { self.lastError = message }
                self.refreshHealthKitSteps()
            }
        }
    }

    private func refreshHealthKitSteps() {
        Task { [weak self] in await self?.refreshHealthKitStepsNow() }
    }

    private func refreshHealthKitStepsNow() async {
        guard HKHealthStore.isHealthDataAvailable(), let start = startedAt else { return }
        let type = HKQuantityType(.stepCount)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
        let count: Double? = await withCheckedContinuation { cont in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate,
                                          options: .cumulativeSum) { _, stats, _ in
                cont.resume(returning: stats?.sumQuantity()?.doubleValue(for: .count()))
            }
            health.execute(query)
        }
        if let count, count > 0 {
            steps = Int(count)
            stepSource = "HealthKit"
        }
    }

    private func startPedometer(from start: Date) {
        guard CMPedometer.isStepCountingAvailable() else { return }
        pedometer.startUpdates(from: start) { [weak self] data, error in
            let count = data?.numberOfSteps.intValue
            let message = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let count, self.stepSource != "HealthKit" {
                    self.steps = count
                    self.stepSource = "Pedometer"
                }
                if let message { self.lastError = message }
            }
        }
    }
}
