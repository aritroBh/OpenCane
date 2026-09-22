//
//  StressTests.swift
//  CaneKitLogicTests
//
//  Purpose (Step 66 — stress campaign): seeded pseudo-random property tests over the decisions a
//  walk depends on. Each test generates thousands of hostile inputs from a fixed seed, asserts the
//  invariants the app's safety rules promise, and runs the same seed twice to prove the output is
//  bit-for-bit the same. The owner's complaint was "whenever you do it, it's always different": the
//  Logic layer is the first suspect to clear, so every test also prints a `STRESS-DIGEST <name>
//  <hex>` line; `ios/scripts/stress/README.md` runs the suite in separate processes (Swift's hash
//  seed changes per process) and diffs those lines to catch nondeterminism a single process cannot.
//
//  What each suite stresses:
//    · `geofenceSurvivesHostileGps` — `GeofenceTracker` over walks along route_isr_cif.json with
//      correlated Gaussian noise (σ 3–25 m, honest accuracy ≈ 1.5 σ), 5 % dropouts, 20 s gaps,
//      backwards jumps, 65–100 m outlier blobs, invalid speeds, 0.5–2 m/s, a dwell at the door.
//      Invariants: reached indices strictly increase, arrival only on the last waypoint and never
//      more than 25 m (true position) from it, nothing after arrival, arrival whenever σ ≤ 8 m.
//    · `cueDeciderSurvivesRandomLaneStreams` — `CueDecider` + `CueSpeechPolicy` over 30 Hz lane
//      streams with overhangs, walls, torso obstacles, coverage flips, dropouts and sweeps (incl.
//      sweeps longer than the 2 s episode clock). Invariants: a covered head candidate never waits
//      beyond the 400 ms change gate for its onset (hard rule 8), no head fire without a covered
//      candidate (or the documented point-blank dropout latch), "Head height." lines ≥ 1.5 s apart,
//      onset lines ≥ 4 s after the previous line, ≤ 2 lines in any 4 s.
//    · `indoorScriptSurvivesPedometerChaos` — `IndoorProgress` + `IndoorHandover` driven like
//      `IndoorGuide`: pedometer jumps and regressions, "next" spam, fixes inside / near / outside,
//      "I'm outside". Invariants: never backwards, ≤ 2 lines per update, one exit, one handover,
//      every handover justified by the rules in IndoorRoute.swift, and a handover always follows.
//    · `islandNeverClaimsClearWithoutLiveSensing` / `islandAlertThrottleHoldsUnderChurn`.
//    · `fastPathFuzz` — 5,000 generated utterances through `FastPathIntentClassifier`.
//  Pinned regressions found by this campaign live at the bottom (`Regressions`).
//
//  Callers of the pinned code: `NavigationEngine` (GeofenceTracker), `AppModel.handle`
//  (CueDecider, CueSpeechPolicy), `IndoorGuide` (IndoorProgress / IndoorHandover),
//  `LiveActivityController` (IslandPhasePolicy / IslandAlertThrottle), `ConversationCoordinator`
//  (FastPathIntentClassifier). Pure Foundation; runs on Linux CI. No clock, no global RNG: the only
//  randomness is `SplitMix64` below, seeded per test.
//

import Foundation
import Testing
@testable import CaneKitLogic

// MARK: - Deterministic generator and digest

/// SplitMix64 (Steele, Lea, Flood 2014): a 64-bit state, one multiply-xorshift per draw. Chosen
/// because it is tiny, has no platform dependence (unlike `SystemRandomNumberGenerator`) and the
/// same seed gives the same stream on macOS and Linux.
struct SplitMix64 {
    /// The whole generator state.
    private(set) var state: UInt64
    /// - Parameter seed: any value; 0 is fine (the increment runs first).
    init(seed: UInt64) { state = seed }
    /// Next raw 64-bit value.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1) with 53 bits.
    mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
    /// Uniform in [a, b).
    mutating func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
    /// Uniform integer in the closed range.
    mutating func int(_ r: ClosedRange<Int>) -> Int { r.lowerBound + Int(next() % UInt64(r.count)) }
    /// True with probability `p`.
    mutating func chance(_ p: Double) -> Bool { unit() < p }
    /// Standard normal (Box–Muller, one of the pair).
    mutating func gaussian() -> Double {
        let u1 = max(unit(), 1e-12), u2 = unit()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
    /// A random element (the array must not be empty).
    mutating func pick<T>(_ xs: [T]) -> T { xs[int(0...(xs.count - 1))] }
}

/// FNV-1a 64 over the lines (newline-separated), as 16 hex digits. Printed as `STRESS-DIGEST`.
private func digest(_ lines: [String]) -> String {
    var h: UInt64 = 0xCBF2_9CE4_8422_2325
    for line in lines {
        for b in line.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
        h = (h ^ 10) &* 0x0000_0100_0000_01B3
    }
    return String(h, radix: 16)
}

/// Prints the digest line the cross-process check in ios/scripts/stress/README.md diffs.
private func emitDigest(_ name: String, _ lines: [String]) {
    print("STRESS-DIGEST \(name) \(digest(lines)) lines=\(lines.count)")
}

/// Fixed-precision number for logs (so a digest never depends on float formatting of noise).
private func f(_ x: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", x) }

/// The shipped demo route (same path trick as `RouteTests.shippedRouteFileIsConsistent`).
private func shippedRoute() throws -> Route {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("../CaneKit/Resources/route_isr_cif.json").standardized
    return try Route.load(from: Data(contentsOf: url))
}

// MARK: - A. GeofenceTracker over hostile GPS

/// One simulated walk's outcome.
private struct WalkResult: Equatable {
    /// Every event and perturbation, in order (the determinism evidence).
    var log: [String] = []
    /// Invariant breaks, human-readable.
    var violations: [String] = []
    /// Per-axis noise σ of this walk, metres.
    var sigma = 0.0
    /// The route finished with an arrival event.
    var arrived = false
    /// True distance from the walker to the last waypoint when arrival fired, metres.
    var arrivalTrueDistance: Double?
}

/// Walks `route` once from `seed` and feeds `GeofenceTracker` one fix per second.
/// Model: position along the waypoint polyline at 0.5–2 m/s (±20 % per second); AR(1) noise
/// (ρ 0.7) with per-axis σ 3–25 m; accuracy reported honestly as ≈ 1.5 σ (the 68 % radius of a 2-D
/// Gaussian); then a 60-fix dwell at the door with speed −1 or < 0.3 m/s. Perturbations: 5 %
/// dropouts, 0.3 %/s chance of a 20 s gap, 1 % backwards jumps of 20–60 m (multipath with an honest
/// accuracy), 1 % outliers 40–100 m accuracy, 5 % invalid speed.
private func simulateWalk(route: Route, seed: UInt64, arrivalHits: Int = 2, rho: Double = 0.7) -> WalkResult {
    var rng = SplitMix64(seed: seed)
    let wps = route.waypoints
    let origin = wps[0].coordinate
    let mPerDeg = 111_195.0
    let cosLat = cos(origin.latitude * .pi / 180)
    func xy(_ c: Coordinate) -> (Double, Double) {
        ((c.longitude - origin.longitude) * mPerDeg * cosLat, (c.latitude - origin.latitude) * mPerDeg)
    }
    func coord(_ x: Double, _ y: Double) -> Coordinate {
        Coordinate(latitude: origin.latitude + y / mPerDeg, longitude: origin.longitude + x / (mPerDeg * cosLat))
    }
    let pts = wps.map { xy($0.coordinate) }
    var cum = [0.0]
    for i in 1..<pts.count { cum.append(cum[i - 1] + hypot(pts[i].0 - pts[i - 1].0, pts[i].1 - pts[i - 1].1)) }
    let total = cum[cum.count - 1]
    func pos(_ s: Double) -> (Double, Double) {
        let s = min(max(0, s), total)
        var i = 1
        while i < cum.count - 1 && cum[i] < s { i += 1 }
        let seg = cum[i] - cum[i - 1]
        let u = seg > 0 ? (s - cum[i - 1]) / seg : 0
        return (pts[i - 1].0 + (pts[i].0 - pts[i - 1].0) * u, pts[i - 1].1 + (pts[i].1 - pts[i - 1].1) * u)
    }

    var r = WalkResult()
    r.sigma = rng.uniform(3, 25)
    let speed = rng.uniform(0.5, 2)
    r.log.append("walk sigma=\(f(r.sigma)) speed=\(f(speed))")
    let tracker = GeofenceTracker(waypoints: wps)
    tracker.arrivalHits = arrivalHits
    var nx = 0.0, ny = 0.0, s = 0.0, t = 0.0
    var dwell = 0, gapLeft = 0, lastReached = -1
    while dwell < 60 {
        t += 1
        if s < total { s = min(total, s + speed * rng.uniform(0.8, 1.2)) } else { dwell += 1 }
        let standing = s >= total
        nx = rho * nx + sqrt(1 - rho * rho) * r.sigma * rng.gaussian()
        ny = rho * ny + sqrt(1 - rho * rho) * r.sigma * rng.gaussian()
        if gapLeft > 0 { gapLeft -= 1; continue }
        if rng.chance(0.003) { gapLeft = 20; r.log.append("gap t=\(Int(t))"); continue }
        if rng.chance(0.05) { continue }
        var (x, y) = pos(s)
        var acc = r.sigma * 1.5 * rng.uniform(0.8, 1.2)
        if rng.chance(0.01) {
            let back = rng.uniform(20, 60)
            (x, y) = pos(s - back)
            r.log.append("back t=\(Int(t)) m=\(f(back, 0))")
        }
        x += nx
        y += ny
        if rng.chance(0.01) {
            x += rng.uniform(-80, 80)
            y += rng.uniform(-80, 80)
            acc = rng.uniform(40, 100)
        }
        var spd = standing ? (rng.chance(0.5) ? -1 : rng.uniform(0, 0.3)) : max(0, speed + rng.gaussian() * 0.2)
        if rng.chance(0.05) { spd = -1 }
        let before = tracker.index
        let event = tracker.update(GeoFix(coordinate: coord(x, y), accuracy: acc, speed: spd, timestamp: t))
        if tracker.index < before { r.violations.append("index went backwards \(before) → \(tracker.index) at t=\(t)") }
        guard case .reached(let index, _, let isLast, let skipped, let passedBy)? = event else { continue }
        r.log.append("reached t=\(Int(t)) i=\(index) last=\(isLast) skipped=\(skipped.map(\.id)) passed=\(passedBy)")
        if r.arrived { r.violations.append("event after arrival: index \(index) at t=\(t)") }
        if index <= lastReached { r.violations.append("reached index \(index) after \(lastReached) at t=\(t)") }
        lastReached = index
        if isLast {
            if index != wps.count - 1 { r.violations.append("isLast on index \(index)") }
            r.arrived = true
            let (px, py) = pos(s)
            let d = hypot(px - pts[pts.count - 1].0, py - pts[pts.count - 1].1)
            r.arrivalTrueDistance = d
            if d > 25 { r.violations.append("arrived \(f(d, 1)) m from the door (σ \(f(r.sigma, 1)), t=\(t))") }
        } else if index == wps.count - 1 {
            r.violations.append("last waypoint reached without isLast")
        }
    }
    if !r.arrived && r.sigma <= 8 { r.violations.append("no arrival at σ \(f(r.sigma, 1)) m after a 60 s dwell") }
    r.log.append("end arrived=\(r.arrived) d=\(r.arrivalTrueDistance.map { f($0, 1) } ?? "-")")
    return r
}

/// 1,000 walks along the demo route; same seeds twice → identical logs.
@Test func geofenceSurvivesHostileGps() throws {
    let route = try shippedRoute()
    var all: [String] = []
    var violations: [String] = []
    var buckets: [(n: Int, arrived: Int, worst: Double)] = Array(repeating: (0, 0, 0), count: 3)  // σ ≤8, ≤16, ≤25
    for seed in UInt64(1)...1_000 {
        let a = simulateWalk(route: route, seed: seed)
        let b = simulateWalk(route: route, seed: seed)
        if a != b { violations.append("seed \(seed): two runs differ") }
        violations += a.violations.map { "seed \(seed): \($0)" }
        all += a.log
        let k = a.sigma <= 8 ? 0 : a.sigma <= 16 ? 1 : 2
        buckets[k].n += 1
        if a.arrived { buckets[k].arrived += 1 }
        buckets[k].worst = max(buckets[k].worst, a.arrivalTrueDistance ?? 0)
    }
    for (k, b) in buckets.enumerated() {
        print("STRESS-STAT geofence sigma<=\([8, 16, 25][k]) walks=\(b.n) arrived=\(b.arrived) worst_arrival_m=\(f(b.worst, 1))")
    }
    for v in violations.prefix(40) { print("STRESS-VIOLATION geofence \(v)") }
    // Measurement only (not asserted): the same walks with three consecutive arrival hits.
    for (hits, rho) in [(2, 0.95), (3, 0.7), (3, 0.95), (4, 0.7)] {
        var early = 0, arrivedSmall = 0, small = 0, arrivedAll = 0, worst = 0.0
        for seed in UInt64(1)...1_000 {
            let w = simulateWalk(route: route, seed: seed, arrivalHits: hits, rho: rho)
            if w.arrived { arrivedAll += 1 }
            if w.sigma <= 8 { small += 1; if w.arrived { arrivedSmall += 1 } }
            if let d = w.arrivalTrueDistance { worst = max(worst, d); if d > 25 { early += 1 } }
        }
        print("STRESS-STAT geofence arrivalHits=\(hits) rho=\(rho) arrived=\(arrivedAll) sigma<=8 arrived=\(arrivedSmall)/\(small) early>25m=\(early) worst_m=\(f(worst, 1))")
    }
    emitDigest("geofence", all)
    let early = violations.filter { $0.contains("from the door") }
    let hard = violations.filter { !$0.contains("from the door") }
    #expect(hard.isEmpty, "\(hard.count) violations, first: \(hard.prefix(8))")
    // Arrival is safety-critical and must stay a hard invariant: the tracker may fail to finish a
    // very noisy walk, but it must never stop the beacon and claim the door tens of metres early.
    #expect(early.isEmpty, "\(early.count) early arrivals: \(early.prefix(4))")
}

// MARK: - A. CueDecider + CueSpeechPolicy over random lane streams

/// One stream's outcome.
private struct CueRun: Equatable {
    var log: [String] = []
    var violations: [String] = []
    var headLines = 0
    var headFires = 0
}

/// A 30 s, ~30 Hz lane stream from `seed`, fed to a fresh `CueDecider` and `CueSpeechPolicy` as
/// `AppModel.handle` does. Segments of 0.2–4 s: clear, an overhang closing from 0.4–2.2 m (torso
/// clear, 0.5–3 m farther, or no return), a wall (head ≈ torso), torso-only obstacles, or per-frame
/// chaos. Per segment: head coverage all / none / per lane, torso coverage, the head lane, whether
/// the phone can buzz. Per frame: 3 % head dropout, 2 % torso dropout, ±5 cm jitter, 0.5 %
/// `depthAvailable == false`. Sweeps (untrusted frames) arrive as bursts of 0.05–0.8 s, and 8 % of
/// bursts last 2–3 s — longer than the 2 s head-episode clock. Frame gaps 23–43 ms, 1 % 0.2 s stalls.
private func simulateCues(seed: UInt64) -> CueRun {
    var rng = SplitMix64(seed: seed)
    let decider = CueDecider()
    var speech = CueSpeechPolicy()
    var run = CueRun()
    let enter = decider.thresholds.head
    let hyst = decider.thresholds.hysteresis
    let gap = decider.thresholds.overhangGapM
    let latchS = decider.thresholds.nearDropoutHoldSeconds
    let latchBelow = decider.thresholds.centerNear + 0.2

    var t = 0.0
    var sweepUntil = -1.0
    var lastCovered: (t: Double, d: Float)?
    var lastHeadLine: Double?
    var headLineTimes: [Double] = []
    while t < 30 {
        let kind = rng.int(0...4)
        let dur = rng.uniform(0.2, 4)
        let segEnd = t + dur
        let headLane = rng.int(0...2)
        let coverMode = rng.int(0...9)
        let torsoCovered = !rng.chance(0.1)
        let cannotBuzz = rng.chance(0.1)
        let h0 = Float(rng.uniform(0.4, 2.2)), h1 = Float(rng.uniform(0.2, Double(h0)))
        let torsoMode = rng.int(0...2)
        let torsoExtra = Float(rng.uniform(0.5, 3))
        run.log.append("seg k=\(kind) dur=\(f(dur)) lane=\(headLane) cover=\(coverMode)")
        while t < segEnd && t < 30 {
            t += rng.chance(0.01) ? 0.2 : rng.uniform(0.023, 0.043)
            if t > sweepUntil, rng.chance(1.0 / 40) {
                sweepUntil = t + (rng.chance(0.08) ? rng.uniform(2, 3) : rng.uniform(0.05, 0.8))
            }
            let trusted = t >= sweepUntil
            let u = Float(min(1, max(0, (t - (segEnd - dur)) / dur)))
            var head: [Float] = [.infinity, .infinity, .infinity]
            var torso: [Float] = [.infinity, .infinity, .infinity]
            switch kind {
            case 1:                                        // overhang closing in
                let d = h0 + (h1 - h0) * u
                head[headLane] = d
                torso[headLane] = torsoMode == 0 ? .infinity : torsoMode == 1 ? d + torsoExtra : Float(rng.uniform(3, 6))
            case 2:                                        // wall: near in both bands
                let d = h0 + (h1 - h0) * u
                head[headLane] = d
                torso[headLane] = d + Float(rng.uniform(-0.2, 0.2))
            case 3:                                        // torso obstacles only
                for l in 0...2 where rng.chance(0.5) { torso[l] = Float(rng.uniform(0.3, 2.5)) }
            case 4:                                        // chaos
                for l in 0...2 {
                    if rng.chance(0.4) { head[l] = Float(rng.uniform(0.1, 3)) }
                    if rng.chance(0.4) { torso[l] = Float(rng.uniform(0.1, 3)) }
                }
            default: break                                 // clear
            }
            for l in 0...2 {
                if head[l].isFinite { head[l] = max(0.05, head[l] + Float(rng.uniform(-0.05, 0.05))) }
                if torso[l].isFinite { torso[l] = max(0.05, torso[l] + Float(rng.uniform(-0.05, 0.05))) }
                if rng.chance(0.03) { head[l] = .infinity }
                if rng.chance(0.02) { torso[l] = .infinity }
            }
            let headCoverage: [Bool] = coverMode == 0 ? [false, false, false]
                : coverMode == 1 ? (0...2).map { _ in rng.chance(0.5) } : [true, true, true]
            let grid = LaneGrid(head: head, torso: torso, centerDepth: .infinity, headCoverage: headCoverage,
                                torsoCoverage: [torsoCovered, torsoCovered, torsoCovered], bandMode: .metric)
            let available = !rng.chance(0.005)
            let report = LaneReport(grid: grid, isTrusted: trusted, timestamp: t, depthAvailable: available)

            let lastChangeBefore = decider.lastChange
            let out = decider.update(report, now: t)
            let judged = trusted && available
            let cand15 = judged ? HeadGate.candidate(in: grid, enter: enter, overhangGap: gap) : nil
            let candHyst = judged ? HeadGate.candidate(in: grid, enter: enter + hyst, overhangGap: gap) : nil
            if let c = candHyst { lastCovered = (t, c.distance) }
            // Hard rule 8: a covered head candidate with no live episode may only wait for the
            // 400 ms change gate — never for anything else.
            if cand15 != nil, !decider.headEpisodeActive, t - lastChangeBefore >= decider.thresholds.minChangeInterval {
                run.violations.append("t=\(f(t, 3)): covered head candidate \(f(Double(cand15!.distance))) m, gate open "
                                      + "(last change \(f(t - lastChangeBefore, 3)) s ago), but no onset / episode; out=\(String(describing: out))")
            }
            guard let out else { continue }
            run.log.append("t=\(f(t, 3)) tr=\(trusted) out=\(String(describing: out))")
            guard case .fire(let cue) = out else { continue }
            if case .head(let d, let onset) = cue {
                run.headFires += 1
                let latched = lastCovered.map { t - $0.t <= latchS && $0.d < latchBelow } ?? false
                if candHyst == nil && !latched {
                    run.violations.append("t=\(f(t, 3)): head fire (onset \(onset), d \(d)) with no covered candidate and no latch")
                }
                if !d.isFinite { run.violations.append("t=\(f(t, 3)): head fire with non-finite distance (onset \(onset))") }
            }
            if let line = speech.line(for: cue, phoneCannotBuzz: cannotBuzz, now: t) {
                run.log.append("say t=\(f(t, 3)) \(line.text)")
                if line.text == "Head height." {
                    run.headLines += 1
                    let isOnset: Bool = { if case .head(_, let o) = cue { return o } else { return false } }()
                    if let last = lastHeadLine {
                        if t - last < 1.5 - 1e-9 { run.violations.append("t=\(f(t, 3)): Head height. \(f(t - last, 3)) s after the previous") }
                        if isOnset && t - last < 4 - 1e-9 { run.violations.append("t=\(f(t, 3)): onset line \(f(t - last, 3)) s after the previous") }
                    }
                    lastHeadLine = t
                    headLineTimes.append(t)
                    if headLineTimes.filter({ t - $0 < 4 - 1e-9 }).count > 2 {
                        run.violations.append("t=\(f(t, 3)): more than 2 Head height. lines within 4 s")
                    }
                }
            }
        }
    }
    return run
}

/// 400 streams (≈ 360,000 frames); same seeds twice → identical outputs.
@Test func cueDeciderSurvivesRandomLaneStreams() {
    var all: [String] = []
    var violations: [String] = []
    var lines = 0, fires = 0
    for seed in UInt64(1)...400 {
        let a = simulateCues(seed: seed)
        let b = simulateCues(seed: seed)
        if a != b { violations.append("seed \(seed): two runs differ") }
        violations += a.violations.map { "seed \(seed): \($0)" }
        all += a.log
        lines += a.headLines
        fires += a.headFires
    }
    print("STRESS-STAT cues streams=400 head_fires=\(fires) head_lines=\(lines) violations=\(violations.count)")
    for v in violations { print("STRESS-VIOLATION cues \(v)") }
    emitDigest("cues", all)
    #expect(violations.isEmpty, "\(violations.count) violations, first: \(violations.prefix(6))")
}

// MARK: - A. IndoorProgress + IndoorHandover

/// One indoor walk's outcome.
private struct IndoorRun: Equatable {
    var log: [String] = []
    var violations: [String] = []
    var handedOver = false
}

/// A random script (1–6 steps; 20 % "next"-only; random landmarks; draft or walked; radius 10–60 m)
/// driven like `IndoorGuide` for 300 operations: pedometer (mostly +0–4, 5 % jumps of +10–60, 5 %
/// regressions), `next()` spam (bursts of 1–5), GPS fixes (indoor blobs 30–65 m, near the door 3–15 m
/// within 0–40 m, far 3–20 m at 50–300 m, 2 % invalid), and "I'm outside" (2 %). Time advances 0.2–3 s
/// per operation. Afterwards: if the exit was reached, three 5 m fixes at the door must hand over.
private func simulateIndoor(seed: UInt64) -> IndoorRun {
    var rng = SplitMix64(seed: seed)
    let exitPoint = Coordinate(latitude: 40.10949, longitude: -88.22135)
    let stepCount = rng.int(1...6)
    let steps: [IndoorStep] = (0..<stepCount).map { i in
        IndoorStep(say: "Step \(i) line.", steps: rng.chance(0.2) ? nil : rng.int(1...30),
                   turn: .none, landmark: rng.chance(0.4) ? "Landmark \(i)." : nil)
    }
    let radius = rng.uniform(10, 60)
    let script = IndoorScript(id: "stress", name: "stress", fromAliases: ["x"], outdoorPlaceID: "isr",
                              walked: rng.chance(0.5), recordedAt: nil, strideM: nil, steps: steps,
                              exit: IndoorExit(say: "Exit line.", lat: exitPoint.latitude, lon: exitPoint.longitude,
                                               radiusM: radius))
    var progress = IndoorProgress(script: script)
    var handover = IndoorHandover(exit: script.exit)
    var run = IndoorRun()
    run.log.append("script steps=\(steps.map { $0.steps ?? -1 }) radius=\(f(radius))")

    // Oracle state, mirroring what the rules in IndoorRoute.swift allow.
    struct Fix { var t: Double; var acc: Double; var d: Double; var armed: Bool }
    var fixes: [Fix] = []
    var armed = false, forcedWaiting = false, exits = 0
    var lastIndex = 0
    var t = 0.0
    var count = 0

    func point(north: Double, east: Double) -> Coordinate {
        Coordinate(latitude: exitPoint.latitude + north / 111_195,
                   longitude: exitPoint.longitude + east / (111_195 * cos(exitPoint.latitude * .pi / 180)))
    }
    func perform(_ events: [IndoorEvent], _ label: String) {
        let says = events.filter { if case .say = $0 { return true } else { return false } }.count
        if says > IndoorProgress.maxJumpLines { run.violations.append("\(label): \(says) lines in one call") }
        for e in events {
            run.log.append("\(label) \(e)")
            if case .advanced(let i) = e {
                if i <= lastIndex { run.violations.append("\(label): advanced to \(i) after \(lastIndex)") }
                lastIndex = i
            }
            if case .reachedExit = e {
                exits += 1
                if exits > 1 { run.violations.append("\(label): second reachedExit") }
                handover.reachedExit()
                armed = true
            }
        }
        if progress.index < lastIndex { run.violations.append("\(label): index \(progress.index) < \(lastIndex)") }
    }
    func feed(_ c: Coordinate, acc: Double) {
        let d = GeoMath.distanceMeters(c, exitPoint)
        let wasArmed = armed
        let wasWaiting = forcedWaiting
        let done = handover.fix(lat: c.latitude, lon: c.longitude, accuracyM: acc, now: t)
        if acc.isFinite && acc >= 0 && !run.handedOver { fixes.append(Fix(t: t, acc: acc, d: d, armed: wasArmed)) }
        run.log.append("fix t=\(f(t)) acc=\(f(acc)) d=\(f(d)) done=\(done)")
        guard done else { return }
        if run.handedOver { run.violations.append("second handover by fix at t=\(f(t))") }
        run.handedOver = true
        let waitingOK = wasWaiting && acc <= IndoorHandover.waitingAccuracyM && d <= radius
        let armedGood = fixes.filter { $0.armed && $0.acc <= IndoorHandover.goodAccuracyM }.suffix(3)
        let armedOK = wasArmed && armedGood.count == 3 && armedGood.allSatisfy { $0.d <= radius }
        let loose = fixes.filter { !$0.armed }.suffix(3)
        let gpsOnlyOK = !wasArmed && loose.count == 3 && fixes.suffix(3).allSatisfy {
            !$0.armed && $0.acc <= IndoorHandover.gpsOnlyAccuracyM && $0.d <= IndoorHandover.gpsOnlyRadiusM
        }
        if !(waitingOK || armedOK || gpsOnlyOK) {
            run.violations.append("unjustified handover by fix at t=\(f(t)) acc=\(f(acc)) d=\(f(d)) armed=\(wasArmed)")
        }
    }

    perform(progress.start(), "start")
    for _ in 0..<300 {
        t += rng.uniform(0.2, 3)
        switch rng.int(0...99) {
        case 0..<45:
            if rng.chance(0.05) { count = max(0, count - rng.int(1...10)) }
            else if rng.chance(0.05) { count += rng.int(10...60) }
            else { count += rng.int(0...4) }
            perform(progress.update(stepsWalked: count), "steps=\(count)")
        case 45..<55:
            for _ in 0..<rng.int(1...5) { perform(progress.next(), "next") }
        case 55..<93:
            let mode = rng.int(0...9)
            let acc: Double, c: Coordinate
            if mode < 3 { acc = rng.uniform(30, 65); c = point(north: rng.uniform(-40, 40), east: rng.uniform(-40, 40)) }
            else if mode < 8 { acc = rng.uniform(3, 15); c = point(north: rng.uniform(-40, 40), east: rng.uniform(-40, 40)) }
            else if mode < 9 { acc = rng.uniform(3, 20); c = point(north: rng.uniform(50, 300), east: 0) }
            else { acc = rng.pick([-1, .nan, .infinity]); c = exitPoint }
            feed(c, acc: acc)
        default:
            let wasHanded = run.handedOver
            let recentOK = fixes.contains { t - $0.t >= 0 && t - $0.t <= IndoorHandover.forcedRecentWindowS
                && $0.acc <= IndoorHandover.forcedRecentAccuracyM && $0.d <= radius }
            let done = handover.forced(now: t)
            armed = true
            run.log.append("forced t=\(f(t)) done=\(done)")
            if done {
                if wasHanded { run.violations.append("second handover by forced at t=\(f(t))") }
                if !recentOK { run.violations.append("forced handover at t=\(f(t)) without a recent fix in the radius") }
                run.handedOver = true
            } else if !wasHanded {
                if recentOK { run.violations.append("forced at t=\(f(t)) had a usable recent fix but did not hand over") }
                forcedWaiting = true
            }
        }
        if run.handedOver { forcedWaiting = false }
    }
    // Liveness: at the exit (or told "I'm outside"), three good fixes at the door always hand over.
    if (progress.atExit || armed) && !run.handedOver {
        for _ in 0..<3 {
            t += 1
            feed(exitPoint, acc: 5)
        }
        if !run.handedOver { run.violations.append("no handover after three 5 m fixes at the door") }
    }
    if progress.atExit != (exits == 1) { run.violations.append("atExit \(progress.atExit) but \(exits) reachedExit events") }
    return run
}

/// 2,000 indoor walks; same seeds twice → identical outputs.
@Test func indoorScriptSurvivesPedometerChaos() {
    var all: [String] = []
    var violations: [String] = []
    var handovers = 0
    for seed in UInt64(1)...2_000 {
        let a = simulateIndoor(seed: seed)
        let b = simulateIndoor(seed: seed)
        if a != b { violations.append("seed \(seed): two runs differ") }
        violations += a.violations.map { "seed \(seed): \($0)" }
        all += a.log
        if a.handedOver { handovers += 1 }
    }
    print("STRESS-STAT indoor walks=2000 handovers=\(handovers)")
    emitDigest("indoor", all)
    #expect(violations.isEmpty, "\(violations.count) violations, first: \(violations.prefix(6))")
}

// MARK: - A. Island policy and alert throttle

/// 20,000 random island inputs: "Path clear" only with live sensing, which needs LiDAR, the app not
/// backgrounded, no warm-up and trusted depth; `paused` only in the background.
@Test func islandNeverClaimsClearWithoutLiveSensing() {
    var rng = SplitMix64(seed: 66)
    var log: [String] = []
    var violations: [String] = []
    for i in 0..<20_000 {
        let count = rng.int(0...6)
        let inputs = IslandInputs(navigating: rng.chance(0.5), routeStartWaiting: rng.chance(0.3),
                                  voiceListening: rng.chance(0.2), voiceThinking: rng.chance(0.2),
                                  indoorStepIndex: rng.chance(0.4) ? rng.int(-2...7) : nil, indoorStepCount: count,
                                  appActive: rng.chance(0.5), depthTrusted: rng.chance(0.5), hasLiDAR: rng.chance(0.8))
        let stale = rng.chance(0.2)
        let state = IslandPhasePolicy.decide(inputs)
        let clear = IslandPhasePolicy.showsClear(sensing: state.sensing, isStale: stale)
        log.append("\(i) \(state.phase.rawValue) \(state.sensing.rawValue) \(clear)")
        if clear && !(inputs.hasLiDAR && inputs.appActive && inputs.depthTrusted && !inputs.routeStartWaiting && !stale) {
            violations.append("\(i): clear with \(inputs) stale=\(stale)")
        }
        if state.sensing == .paused && inputs.appActive { violations.append("\(i): paused in the foreground") }
        if state.sensing == .live && !inputs.hasLiDAR { violations.append("\(i): live without LiDAR") }
    }
    emitDigest("island", log)
    #expect(violations.isEmpty, "\(violations.prefix(5))")
}

/// 200 routes × 300 level changes 0–40 s apart: never an alert in the foreground, never two alerts of
/// one level within 30 s, and an escalation in the background with its window open always alerts.
@Test func islandAlertThrottleHoldsUnderChurn() {
    var log: [String] = []
    var violations: [String] = []
    for seed in UInt64(1)...200 {
        var rng = SplitMix64(seed: seed)
        var throttle = IslandAlertThrottle()
        var lastAlert: [IslandAlertLevel: Double] = [:]
        var t = 0.0
        for _ in 0..<300 {
            t += rng.chance(0.3) ? rng.uniform(0, 1) : rng.uniform(0, 40)
            let level = rng.pick(IslandAlertLevel.allCases)
            let active = rng.chance(0.3)
            let previous = throttle.lastLevel
            let alert = throttle.shouldAlert(level: level, appActive: active, now: t)
            log.append("\(seed) \(f(t)) \(level.rawValue) \(active) \(alert)")
            let windowOpen = lastAlert[level].map { t - $0 >= IslandAlertThrottle.perLevelInterval } ?? true
            if alert {
                if active { violations.append("seed \(seed) t=\(f(t)): alert in the foreground") }
                if !windowOpen { violations.append("seed \(seed) t=\(f(t)): \(level) alerted within 30 s") }
                if level.rank <= previous.rank { violations.append("seed \(seed) t=\(f(t)): alert without escalation") }
                lastAlert[level] = t
            } else if !active && level.rank > previous.rank && windowOpen {
                violations.append("seed \(seed) t=\(f(t)): background escalation \(previous) → \(level) did not alert")
            }
        }
    }
    emitDigest("throttle", log)
    #expect(violations.isEmpty, "\(violations.prefix(5))")
}

// MARK: - A. FastPathIntentClassifier fuzz

/// The action's case name without its payload ("startRoute" from `startRoute(destination: "Cif")`).
private func caseName(_ a: ConversationAction?) -> String {
    guard let a else { return "nil" }
    let s = String(describing: a)
    return String(s.prefix { $0 != "(" })
}

/// Random decoration a recogniser or a keyboard might add: casing, edge whitespace, edge ASCII
/// punctuation (the set the classifier documents it trims).
private func decorate(_ text: String, _ rng: inout SplitMix64) -> String {
    var s: String
    switch rng.int(0...3) {
    case 0: s = text.lowercased()
    case 1: s = text.uppercased()
    case 2: s = text.capitalized
    default: s = String(text.map { rng.chance(0.5) ? Character($0.uppercased()) : Character($0.lowercased()) })
    }
    let punct = [".", "?", "!", ",", "\"", "'", ";", ":"]
    let ws = [" ", "  ", "\t", "\n", ""]
    for _ in 0..<rng.int(0...2) { s += rng.pick(punct) }
    for _ in 0..<rng.int(0...1) { s = rng.pick(punct) + s }
    return rng.pick(ws) + s + rng.pick(ws)
}

/// 5,000 utterances: menu words / digits / verbs, stop phrases, yes / no, "from A to B" in every
/// supported shape, destination prefixes, and noise salads. Invariants: no crash; a decorated stop
/// phrase is always `.stopRoute`; a decorated yes form is always `.confirm(true)` and never a route;
/// classify is a pure function (twice → equal); surrounding whitespace, a trailing period and
/// letter case never change which rule fires.
@Test func fastPathFuzz() {
    var rng = SplitMix64(seed: 5_000)
    let stops = ["stop", "stop route", "stop navigating", "stop navigation", "cancel route", "end route"]
    let yeses = ["yes", "yeah", "yep", "yes please", "confirm", "yes call", "call", "do it"]
    let menu = ["route", "where am I", "describe", "status", "repeat", "quiet", "help", "emergency",
                "one", "two", "three", "four", "five", "six", "seven", "eight", "1", "2", "3", "8",
                "next", "standard", "detailed", "no", "never mind", "I'm outside", "we are outside"]
    let places = ["CIF", "ISR", "Grainger", "the Illini Union", "Siebel", "Main Library", "ARC", "Townsend Hall",
                  "the lab", "here", "my location", "Target", "the bus stop", "Green Street"]
    let prefixes = FastPathIntentClassifier.destinationPrefixes.map { $0.trimmingCharacters(in: .whitespaces) }
    let noise = ["please", "um", "uh", "okay", "route", "to", "from", "stop", "outside", "yes", "the", "battery",
                 "how", "far", "set", "a", "post", "called", "home", "beacon", "on", "off", "7", "42", "hazard",
                 "watch", "turn", "nod", "talk", "is", "it", "cold", "go", "take", "me", "cancel", "call"]
    var log: [String] = []
    var violations: [String] = []
    let routeCases: Set<String> = ["startRoute", "routeFromTo", "startDefaultRoute"]
    for i in 0..<5_000 {
        let family = rng.int(0...5)
        var base: String
        switch family {
        case 0: base = rng.pick(stops)
        case 1: base = rng.pick(yeses)
        case 2: base = rng.pick(menu)
        case 3:
            let a = rng.pick(places), b = rng.pick(places)
            switch rng.int(0...3) {
            case 0: base = "take me from \(a) to \(b)"
            case 1: base = "from \(a) to \(b)"
            case 2: base = "\(rng.pick(prefixes)) \(b) from \(a)"
            default: base = "\(rng.pick(["go from", "navigate from"])) \(a) to \(b)"
            }
        case 4: base = "\(rng.pick(prefixes)) \(rng.pick(places))"
        default: base = (0..<rng.int(1...7)).map { _ in rng.pick(noise) }.joined(separator: " ")
        }
        let text = decorate(base, &rng)
        let action = FastPathIntentClassifier.classify(query: text)
        let again = FastPathIntentClassifier.classify(query: text)
        log.append("\(i) \(text.debugDescription) → \(String(describing: action))")
        if action != again { violations.append("\(i): not a pure function for \(text.debugDescription)") }
        if family == 0 && action != .stopRoute { violations.append("\(i): stop phrase \(text.debugDescription) → \(caseName(action))") }
        if family == 1 {
            if action != .confirm(true) { violations.append("\(i): yes form \(text.debugDescription) → \(caseName(action))") }
            if routeCases.contains(caseName(action)) { violations.append("\(i): yes form classified as a route") }
        }
        let name = caseName(action)
        let variants = [" \(text) ", text.trimmingCharacters(in: .whitespacesAndNewlines) + ".", text.uppercased(), text.lowercased()]
        for v in variants where caseName(FastPathIntentClassifier.classify(query: v)) != name {
            violations.append("\(i): \(text.debugDescription) → \(name) but \(v.debugDescription) → \(caseName(FastPathIntentClassifier.classify(query: v)))")
        }
    }
    emitDigest("fastpath", log)
    #expect(violations.isEmpty, "\(violations.count) violations, first: \(violations.prefix(8))")
}

// MARK: - Regressions found by the campaign (minimal reproductions)

/// A trusted `LaneReport` (or a sweep frame with `trusted: false`), coverage all true.
private func lanes(head: [Float] = [.infinity, .infinity, .infinity],
                   torso: [Float] = [.infinity, .infinity, .infinity],
                   trusted: Bool = true) -> LaneReport {
    LaneReport(grid: LaneGrid(head: head, torso: torso, centerDepth: .infinity), isTrusted: trusted, depthAvailable: true)
}

/// Found by `cueDeciderSurvivesRandomLaneStreams` (82 hits in 400 streams). A head onset, the head
/// reading gone 0.1 s later while a post sits in the centre lane (the 400 ms change gate holds the
/// centre loop, so `active` stays `.head`), then a sweep longer than the 2 s episode clock: the
/// episode ended but `active` was still `.head`, so the returning overhang took the "same cue still
/// active" branch and was silent — no haptic, no "Head height." — for as long as it stayed in view.
@Test func headOnsetFiresAfterAGatedHandoffAndALongSweep() {
    let d = CueDecider()
    #expect(d.update(lanes(head: [.infinity, 1.2, .infinity]), now: 0) == .fire(.head(distance: 1.2, onset: true)))
    #expect(d.update(lanes(torso: [.infinity, 1.5, .infinity]), now: 0.1) == nil)      // centre held by the gate
    for i in 1...25 { _ = d.update(lanes(torso: [.infinity, 1.5, .infinity], trusted: false), now: 0.1 + Double(i) * 0.1) }
    let back = d.update(lanes(head: [.infinity, 1.1, .infinity]), now: 2.7)
    #expect(back == .fire(.head(distance: 1.1, onset: true)))
    #expect(d.headEpisodeActive)
}

/// Found by the same stream test (116 hits). An overhang at 0.6 m appears while the change gate is
/// closed; 0.1 s later the torso of that lane reads 0.5 m (near in both bands: the overhang signature
/// now says "wall", `HeadGate` returns nil). The point-blank dropout latch kept the head zone active
/// on the non-finite distance, and when the gate opened the decider fired a head *onset* with
/// distance ∞ — "Head height." for something the gate rejected on every frame since.
@Test func noHeadOnsetOnANonFiniteDistance() {
    let d = CueDecider()
    #expect(d.update(lanes(torso: [.infinity, 1.5, .infinity]), now: 0) == .fire(.centerApproach(distance: 1.5)))
    #expect(d.update(lanes(head: [.infinity, 0.6, .infinity], torso: [.infinity, 1.5, .infinity]), now: 0.1) == nil)
    let wall = lanes(head: [.infinity, 0.6, .infinity], torso: [.infinity, 0.5, .infinity])
    _ = d.update(wall, now: 0.2)
    let out = d.update(wall, now: 0.45)
    if case .fire(.head)? = out { Issue.record("head fired on a frame with no head candidate: \(String(describing: out))") }
    #expect(!d.headEpisodeActive)
}
