//
//  TripTracker.swift
//  CaneKit
//
//  The arrival card's numbers: elapsed time, distance walked (integrated GPS path, gated on
//  accuracy), and steps since the route started via HealthKit (which merges the watch's count —
//  far better than a phone clamped to a sweeping cane). CMPedometer is the fallback when
//  HealthKit is unavailable or refused.
//
//  Owner: `AppModel.trip` (one instance). `start()` from `AppModel.beginRoute()` (Motion and
//  HealthKit permission prompts appear here, by design), `ingest` on every fix, `await stop()`
//  on arrival before the spoken summary. ArrivalCardView reads the published values. Module
//  `navigation-trip` in docs/CODE_REFERENCE.md.
//
//  Threading / isolation: `@MainActor @Observable`. HealthKit and CMPedometer call back on
//  their own queues; those closures extract Sendable values and hop with
//  `Task { @MainActor … }` (AGENTS.md hard rule 1).
//
//  Key invariants:
//    · The 20 m accuracy / 0.5 m/s gates match NavigationEngine / GeofenceTracker / TurnSettle;
//      keep them aligned so stationary drift does not dominate the arrival distance.
//    · HealthKit wins over the pedometer whenever it reports a count (it merges the watch).
//  No unit test; verify with the arrival card on a device walk.
//

import CaneKitLogic
import CoreMotion
import Foundation
import HealthKit
import Observation

/// Elapsed time, GPS distance and step count for the current route.
@MainActor
@Observable
final class TripTracker {

    /// True between `start()` and `stop()`; gates `ingest`.
    private(set) var isTracking = false
    /// Wall-clock route start; the HealthKit query window starts here.
    private(set) var startedAt: Date?
    /// Seconds since `startedAt`, updated each second and frozen by `stop()`.
    private(set) var elapsed: TimeInterval = 0
    /// Metres walked along good, moving fixes.
    private(set) var distanceM: Double = 0
    /// Steps since `startedAt`; nil until a source reports.
    private(set) var steps: Int?
    /// "HealthKit" / "Pedometer" / "none"
    private(set) var stepSource = "none"
    /// Last HealthKit / pedometer error message, for the debug UI.
    private(set) var lastError: String?

    /// Read-only step-count access (no data is written).
    @ObservationIgnored private let health = HKHealthStore()
    /// Fallback step counter (phone motion; over-counts on a sweeping cane).
    @ObservationIgnored private let pedometer = CMPedometer()
    /// Previous accepted fix, the start of the next distance segment.
    @ObservationIgnored private var lastFix: GeoFix?
    /// 1 s elapsed-time loop; re-queries HealthKit every 10 ticks.
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// Currently unused (reserved for a live HealthKit observer query).
    @ObservationIgnored private var stepQuery: HKObserverQuery?

    /// Idle until `start()`.
    init() {}

    // MARK: Control

    /// Resets the counters and starts time, distance and step tracking. Idempotent.
    /// Triggers the Motion (pedometer) and HealthKit permission prompts on first use.
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
    /// (AppModel's `onArrived` awaits it; `stopRoute()` fires and forgets.) Keeps the values for
    /// the arrival card.
    func stop() async {
        guard isTracking else { return }
        isTracking = false
        ticker?.cancel()
        ticker = nil
        pedometer.stopUpdates()
        if let s = startedAt { elapsed = Date().timeIntervalSince(s) }
        await refreshHealthKitStepsNow()
    }

    /// Stop immediately without the final HealthKit refresh (a route restarted mid-walk: the old
    /// trip must be closed before the new `start()` or that start is ignored).
    func cancel() {
        guard isTracking else { return }
        isTracking = false
        ticker?.cancel()
        ticker = nil
        pedometer.stopUpdates()
    }

    /// Integrate distance along good fixes while actually moving (a stationary fix wanders a
    /// metre or two; CoreLocation's speed is the cheapest stationary gate).
    /// Called on every `location.onFix`, navigating or not (the `isTracking` guard decides).
    /// Gates: accuracy in [0, 20] m, speed > 0.5 m/s, segment < 100 m.
    func ingest(_ fix: GeoFix) {
        guard isTracking, fix.accuracy >= 0, fix.accuracy <= 20 else { return }
        defer { lastFix = fix }
        guard let prev = lastFix, fix.speed > 0.5 else { return }
        let d = GeoMath.distanceMeters(prev.coordinate, fix.coordinate)
        if d < 100 { distanceM += d }                 // > 100 m between fixes = a teleport, skip
    }

    /// "CIF east entrance. 1.0 kilometers, 14 minutes, 1,300 steps."
    /// Kilometres (1 dp) from 950 m up, else whole metres; minutes rounded; steps only if known.
    /// Spoken on arrival and used as the arrival card's accessibility label.
    func spokenSummary(destination: String) -> String {
        var parts: [String] = []
        if distanceM >= 950 { parts.append(String(format: "%.1f kilometers", distanceM / 1000)) }
        else { parts.append("\(Int(distanceM.rounded())) meters") }
        let minutes = Int((elapsed / 60).rounded())
        parts.append(minutes == 1 ? "1 minute" : "\(minutes) minutes")
        if let steps { parts.append("\(steps) steps") }
        // Waypoint lines already end in a full stop; avoid "entrance.. 1.0 kilometers".
        let name = destination.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return "\(name). " + parts.joined(separator: ", ") + "."
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

    /// Fire-and-forget wrapper around `refreshHealthKitStepsNow()` (ticker, auth callback).
    private func refreshHealthKitSteps() {
        Task { [weak self] in await self?.refreshHealthKitStepsNow() }
    }

    /// Cumulative step sum from `startedAt` (strict start) to now. Only a count > 0 replaces
    /// `steps` (a denied read returns nothing, which must not overwrite the pedometer's count).
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

    /// Live pedometer updates from `start`; they only set `steps` until HealthKit has reported.
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
