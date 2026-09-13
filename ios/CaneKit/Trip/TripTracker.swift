//
//  TripTracker.swift
//  CaneKit
//
//  The arrival card's numbers: elapsed time, distance walked (integrated GPS path, gated on
//  accuracy), and steps since the route started via HealthKit (which merges the watch's count —
//  far better than a phone clamped to a sweeping cane). CMPedometer is the fallback when
//  HealthKit is unavailable or refused.
//
//  Owner: `AppModel.trip` (one instance). `start()` from `AppModel.startRouteNow` (Motion and
//  HealthKit permission prompts appear here, by design), `ingest` on every fix (idle fixes too,
//  since GPS runs from launch — the `isTracking` guard drops them), `await stop()` on arrival
//  before the spoken summary, fire-and-forget `stop()` from `stopRoute`, `cancel()` from
//  `endRouteQuietly` (restart). ArrivalCardView reads the published values;
//  `ConversationCoordinator` reads `steps` / `distanceM` / `elapsed` for "how far have I walked".
//  Module `navigation-trip` in docs/CODE_REFERENCE.md.
//
//  Threading / isolation: `@MainActor @Observable`. HealthKit and CMPedometer call back on
//  their own queues; those closures extract Sendable values and hop with
//  `Task { @MainActor … }` (AGENTS.md hard rule 1).
//
//  Key invariants:
//    · The 20 m accuracy / 0.5 m/s gates match NavigationEngine / GeofenceTracker / TurnSettle;
//      keep them aligned so stationary drift does not dominate the arrival distance.
//    · HealthKit wins over the pedometer whenever it reports a count (it merges the watch).
//    · ⚠ The pedometer handler must stay explicitly `@Sendable`: an inferred `@MainActor` closure
//      called on CoreMotion's queue trapped the app (crash 2026-09-11 21:50). The HealthKit
//      handlers only extract values and hop (or resume a continuation); keep them that way.
//  Tests: none (app target: HealthKit / CoreMotion). The summary wording has no test either;
//  verify with the arrival card ("CIF … meters, minutes, steps") on a device walk.
//

import CaneKitLogic
import CoreMotion
import Foundation
import HealthKit
import Observation

/// Elapsed time, GPS distance and step count for the current route (or the last one, after it
/// ended — the values are kept for the arrival card until the next `start()`).
@MainActor
@Observable
final class TripTracker {

    /// True between `start()` and `stop()` / `cancel()`; gates `ingest` and makes `start()` a no-op.
    private(set) var isTracking = false
    /// Wall-clock route start; the HealthKit query window starts here. Kept after `stop()`.
    private(set) var startedAt: Date?
    /// Seconds since `startedAt`, updated each second and frozen by `stop()`. (`cancel()` leaves the
    /// last 1 s tick.) Spoken rounded to minutes.
    private(set) var elapsed: TimeInterval = 0
    /// Metres walked along good, moving fixes (a straight-line sum of fix-to-fix segments, so it
    /// under-reads a curved path between sparse fixes).
    private(set) var distanceM: Double = 0
    /// Steps since `startedAt`; nil until a source reports. Not reset by `stop()`.
    private(set) var steps: Int?
    /// Where `steps` came from: "HealthKit" / "Pedometer" / "none". ArrivalCardView words its
    /// caption from these exact strings. Not reset by `start()`: once HealthKit has reported, a
    /// later route's pedometer updates stay ignored until HealthKit reports again.
    private(set) var stepSource = "none"
    /// Last HealthKit / pedometer error message; shown under the arrival card's stats. Never cleared.
    private(set) var lastError: String?

    /// Read-only step-count access (no data is written).
    @ObservationIgnored private let health = HKHealthStore()
    /// Fallback step counter (phone motion; over-counts on a sweeping cane).
    @ObservationIgnored private let pedometer = CMPedometer()
    /// Previous accepted fix (inside the accuracy gate, moving or not), the start of the next
    /// distance segment. Reset by `start()`.
    @ObservationIgnored private var lastFix: GeoFix?
    /// 1 s elapsed-time loop (main-actor Task); re-queries HealthKit every 10 ticks.
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// Currently unused (reserved for a live HealthKit observer query; never assigned).
    @ObservationIgnored private var stepQuery: HKObserverQuery?
    /// Fences HealthKit reads that can finish after a route is replaced or cancelled.
    @ObservationIgnored private var refreshGeneration = TripRefreshGeneration()

    /// Idle until `start()`; asks for no permission.
    init() {}

    // MARK: Control

    /// Resets the counters and starts time, distance and step tracking. Idempotent: a call while
    /// tracking is ignored, which is why a restart must `cancel()` first.
    /// Triggers the Motion (pedometer) and HealthKit permission prompts on first use — at route
    /// start by design, so they do not pile onto the launch-time Location prompt.
    func start() {
        guard !isTracking else { return }
        let generation = refreshGeneration.begin()
        isTracking = true
        let now = Date()
        startedAt = now
        elapsed = 0
        distanceM = 0
        steps = nil
        lastFix = nil
        startSteps(from: now, generation: generation)
        ticker = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let s = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(s)
                tick += 1
                if tick % 10 == 0 { self.refreshHealthKitSteps(generation: generation) }   // HealthKit is not a live feed
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
        await refreshHealthKitStepsNow(generation: refreshGeneration.current)
    }

    /// Stop immediately without the final HealthKit refresh (a route restarted mid-walk: the old
    /// trip must be closed before the new `start()` or that start is ignored). Synchronous, unlike
    /// `stop()`. Caller: `AppModel.endRouteQuietly()`.
    func cancel() {
        guard isTracking else { return }
        isTracking = false
        ticker?.cancel()
        ticker = nil
        pedometer.stopUpdates()
        refreshGeneration.invalidate()
    }

    /// Integrate distance along good fixes while actually moving (a stationary fix wanders a
    /// metre or two; CoreLocation's speed is the cheapest stationary gate).
    /// Called on every `location.onFix`, navigating or not (the `isTracking` guard decides).
    /// Gates: accuracy in [0, 20] m, speed > 0.5 m/s, segment < 100 m. A good but stationary fix
    /// still becomes the next segment's start, so standing drift is never added later.
    func ingest(_ fix: GeoFix) {
        guard isTracking, fix.accuracy >= 0, fix.accuracy <= 20 else { return }
        defer { lastFix = fix }
        guard let prev = lastFix, fix.speed > 0.5 else { return }
        let d = GeoMath.distanceMeters(prev.coordinate, fix.coordinate)
        if d < 100 { distanceM += d }                 // > 100 m between fixes = a teleport, skip
    }

    /// "CIF east entrance. 1.0 kilometers, 14 minutes, 1,300 steps."
    /// Kilometres (1 dp) from 950 m up, else whole metres; minutes rounded; steps only if known.
    /// Spoken on arrival (`AppModel` `onArrived`, `.nav`, ttl 30, and appended to Repeat) and used
    /// as the arrival card's accessibility label (with "Arrived" / "So far" as the destination).
    /// - Parameter destination: the last waypoint's `say` line; trailing "." and spaces trimmed.
    /// Steps are not thousands-separated ("1300 steps"), unlike the example above.
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
    /// Requests read access to `.stepCount` (prompts once) and refreshes when the request returns.
    /// - Parameter start: the route start; both sources count from here.
    private func startSteps(from start: Date, generation: UInt64) {
        startPedometer(from: start, generation: generation)
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let type = HKQuantityType(.stepCount)
        health.requestAuthorization(toShare: [], read: [type]) { [weak self] _, error in
            let message = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.refreshGeneration.accepts(generation) else { return }
                if let message { self.lastError = message }
                self.refreshHealthKitSteps(generation: generation)
            }
        }
    }

    /// Fire-and-forget wrapper around `refreshHealthKitStepsNow()` (ticker, auth callback). The
    /// generation token is captured before the query and checked after it returns, so a result
    /// from a replaced/cancelled trip cannot write into the current card.
    private func refreshHealthKitSteps(generation: UInt64? = nil) {
        let token = generation ?? refreshGeneration.current
        Task { [weak self] in await self?.refreshHealthKitStepsNow(generation: token) }
    }

    /// Cumulative step sum from `startedAt` (strict start) to now. Only a count > 0 replaces
    /// `steps` (a denied read returns nothing, which must not overwrite the pedometer's count).
    /// Query errors are ignored (nil count). HealthKit is not a live feed (hence the ticker's 10 s
    /// re-query); `stop()` awaits one last query so the arrival line has the freshest sum.
    private func refreshHealthKitStepsNow(generation: UInt64) async {
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
        guard refreshGeneration.accepts(generation) else { return }
        if let count, count > 0 {
            steps = Int(count)
            stepSource = "HealthKit"
        }
    }

    /// Live pedometer updates from `start`; they only set `steps` until HealthKit has reported.
    /// ⚠ The handler must stay `@Sendable`: `CMPedometerHandler` is not `NS_SWIFT_SENDABLE`
    /// (CMPedometer.h), so without it the closure is inferred `@MainActor` under the module's
    /// default isolation and the runtime traps (`swift_task_isCurrentExecutor` →
    /// `_dispatch_assert_queue_fail`) when CoreMotion calls it on `CMPedometerUpdateQueue`
    /// (crash 2026-09-11 21:50). The body only extracts Sendable values before hopping to main.
    private func startPedometer(from start: Date, generation: UInt64) {
        guard CMPedometer.isStepCountingAvailable() else { return }
        pedometer.startUpdates(from: start) { @Sendable [weak self] data, error in
            let count = data?.numberOfSteps.intValue
            let message = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.refreshGeneration.accepts(generation) else { return }
                if let count, self.stepSource != "HealthKit" {
                    self.steps = count
                    self.stepSource = "Pedometer"
                }
                if let message { self.lastError = message }
            }
        }
    }
}
