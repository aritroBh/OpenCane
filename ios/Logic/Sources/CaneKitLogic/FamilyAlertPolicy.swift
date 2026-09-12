//
//  FamilyAlertPolicy.swift
//  CaneKitLogic
//
//  When a cane detection is worth waking the Grok Bot routine, and the event it becomes.
//  Split from the transport (`GrokBotClient`, app) because every number here — how often a
//  breadcrumb goes out, how close an obstacle has to be, what counts as a low battery — is a
//  tuning decision and AGENTS.md hard rule 3 puts those in CaneKitLogic with a test.
//
//  Why rate limits exist at all: the depth path runs at ~30 Hz and `LocationService` delivers a
//  fix roughly every second. Forwarding either one straight to the webhook would burn the bot's
//  run quota in a minute and bury the one event that mattered. The bot texts family for
//  warn/critical, so a chatty `warn` is not just noise — it is a phone buzzing in a family
//  member's pocket.
//
//  Owner: `FamilyAlerts` (app, main actor) holds one instance and calls it from the cue router,
//  the location callback and the battery observer.
//
//  Key invariants:
//    · Single-owner mutable state, `nonisolated`, not Sendable — same shape as `CueDecider`.
//    · `now` is always the caller's monotonic clock in seconds (ARKit / trip-log clock), never
//      wall time, so replay and tests are deterministic.
//    · fall and sos are NEVER rate-limited. Everything else is.
//    · Low battery re-arms only after a real recharge (hysteresis), so a phone hovering at the
//      threshold cannot text family repeatedly.
//  Tests: FamilyAlertPolicyTests.swift.
//

import Foundation

/// Rate limits and thresholds for family alerts. Defaults are deliberately conservative: this
/// feature ships off by default (`familyAlertsEnabled`) and an alert that cries wolf is worse
/// than no alert.
public struct FamilyAlertLimits: Sendable, Equatable {
    /// Seconds between `location` breadcrumbs. 120 s ≈ 30 events on a 1-hour walk: enough for a
    /// family member to follow along, far below anything that looks like a flood.
    public var locationInterval: TimeInterval = 120
    /// Seconds between `obstacle` events, regardless of how many the walker passes.
    public var obstacleInterval: TimeInterval = 60
    /// Metres. Closer than this and an obstacle is worth a `warn`; further is ordinary walking
    /// the cane and the haptics already handle. 1.2 m is inside `ObstacleNamer`'s naming range,
    /// so an event always corresponds to something the walker was also told about out loud.
    public var obstacleMaxDistanceM: Double = 1.2
    /// Percent at or below which the phone is "low". The phone is the only computer on this cane
    /// (AGENTS.md), so a flat battery ends guidance outright.
    public var lowBatteryPct: Int = 20
    /// Percent the battery must climb back above before another low-battery alert can fire.
    /// Above `lowBatteryPct` so that discharge noise around the threshold cannot re-trigger.
    public var lowBatteryRearmPct: Int = 30

    public init() {}
}

/// Decides which detections become events. Stateful (last-sent times, battery arming) and
/// single-owner: create one per app run, call it from the main actor.
public struct FamilyAlertPolicy {
    public var limits: FamilyAlertLimits

    /// `now` of the last sent event of each rate-limited type. Absent = never sent.
    private var lastSent: [OpenCaneEventType: TimeInterval] = [:]
    /// False once a low-battery alert has fired; true again after a recharge past the re-arm
    /// percent. Starts true so the first low reading is reported.
    private var batteryArmed = true

    public init(limits: FamilyAlertLimits = FamilyAlertLimits()) {
        self.limits = limits
    }

    /// Forgets every rate limit (route start / stop). Battery arming is deliberately NOT reset:
    /// the battery does not recharge because a new route began.
    public mutating func reset() {
        lastSent = [:]
    }

    /// True when `type` has not been sent inside `interval`. Records the send when it returns true.
    private mutating func allow(_ type: OpenCaneEventType, interval: TimeInterval,
                                now: TimeInterval) -> Bool {
        if let last = lastSent[type], now - last < interval { return false }
        lastSent[type] = now
        return true
    }

    // MARK: Detections → events

    /// Periodic GPS breadcrumb, throttled to `locationInterval`. `info`: chat-only on the bot side.
    /// nil means "too soon, say nothing".
    public mutating func location(lat: Double, lng: Double, accuracyM: Double?,
                                  headingDegrees: Double?, speedMps: Double?,
                                  now: TimeInterval) -> OpenCaneEvent? {
        guard allow(.location, interval: limits.locationInterval, now: now) else { return nil }
        return OpenCaneEvent(type: .location, severity: .info,
                             lat: lat, lng: lng,
                             accuracyM: accuracyM.flatMap { $0 >= 0 ? $0 : nil },
                             heading: headingDegrees,
                             speedMps: speedMps.flatMap { $0 >= 0 ? $0 : nil })
    }

    /// A close obstacle the cane cannot find. nil when it is further than
    /// `obstacleMaxDistanceM` or inside `obstacleInterval` of the last one.
    /// - Parameter kind: classifier label ("door", "wall", "pole"); nil when only depth is known.
    /// - Parameter direction: "left" / "center" / "right" / "head".
    public mutating func obstacle(kind: String?, distanceM: Double?, direction: String?,
                                  lat: Double?, lng: Double?, note: String?,
                                  now: TimeInterval) -> OpenCaneEvent? {
        // Unknown distance is not assumed dangerous: the haptics already fired, and a warn texts
        // family. Only a measured, close obstacle qualifies.
        guard let distanceM, distanceM.isFinite, distanceM <= limits.obstacleMaxDistanceM else { return nil }
        guard allow(.obstacle, interval: limits.obstacleInterval, now: now) else { return nil }
        return OpenCaneEvent(type: .obstacle, severity: .warn,
                             lat: lat, lng: lng, note: note,
                             obstacle: OpenCaneObstacle(kind: kind, distanceM: distanceM,
                                                        direction: direction))
    }

    /// Low phone battery. Fires once per discharge: nil while already fired, until the battery
    /// climbs back above `lowBatteryRearmPct`.
    /// - Parameter pct: 0–100, or negative when unknown (the simulator reports −1).
    public mutating func lowBattery(pct: Int) -> OpenCaneEvent? {
        guard pct >= 0 else { return nil }                      // unknown: never alert
        if pct >= limits.lowBatteryRearmPct { batteryArmed = true }
        guard pct <= limits.lowBatteryPct, batteryArmed else { return nil }
        batteryArmed = false
        return OpenCaneEvent(type: .lowBattery, severity: .warn,
                             note: "Phone battery at \(pct) percent. OpenCane guidance stops when it dies.",
                             batteryPct: pct)
    }

    /// Suspected fall. Never rate-limited and always `critical` — a second fall report while the
    /// first is still being handled is information, not noise.
    /// - Note: **OpenCane has no fall detector yet.** This builds the event; nothing in the app
    ///   calls it except the debug test-send. See docs/todo.md.
    public static func fall(lat: Double?, lng: Double?, note: String?) -> OpenCaneEvent {
        OpenCaneEvent(type: .fall, severity: .critical, lat: lat, lng: lng,
                      note: note ?? "Possible fall detected")
    }

    /// Walker asked for help. Never rate-limited, always `critical`.
    public static func sos(lat: Double?, lng: Double?, note: String?) -> OpenCaneEvent {
        OpenCaneEvent(type: .sos, severity: .critical, lat: lat, lng: lng,
                      note: note ?? "SOS from the cane")
    }

    /// Quiet state change (route started, arrived). `info`: chat-only, no SMS.
    public static func status(_ note: String, lat: Double? = nil, lng: Double? = nil) -> OpenCaneEvent {
        OpenCaneEvent(type: .status, severity: .info, lat: lat, lng: lng, note: note)
    }
}
