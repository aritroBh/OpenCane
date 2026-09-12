//
//  FamilyAlerts.swift
//  CaneKit
//
//  Turns cane detections into Grok Bot events. Owns one `FamilyAlertPolicy` (CaneKitLogic — every
//  threshold and rate limit, unit-tested) and one `GrokBotClient` (transport). AppModel calls the
//  methods here from the cue router, the location callback and the battery observer; nothing here
//  decides a number and nothing here touches the network directly.
//
//  ⚠ A 200 from the webhook means the bot started a run, NOT that family was texted. `lastStatus`
//  is worded that way and the UI must not "improve" it into "family notified" — the bot decides
//  who to text, from `severity` and `type`, after we are gone.
//
//  Off by default (`familyAlertsEnabled`, AGENTS.md → new untuned features ship off): it sends the
//  walker's position off the phone, so it is opt-in, and it is in `LaunchRecovery.optionalFeatureKeys`
//  so a crash loop clears it.
//
//  Threading / isolation: main actor (target default). Sends are fire-and-forget `Task`s so a slow
//  POST can never delay a cue; the only shared state is `lastStatus` for the UI.
//
//  ⚠ Two different clocks reach the policy, and that is safe only because each event type has its
//  own rate-limit slot: `location(…)` is called with `GeoFix.timestamp` (reference-date seconds)
//  and `obstacle(…)` with `LaneReport.timestamp` (ARKit's monotonic seconds). They are not
//  comparable to each other. If a limit is ever shared across types, one clock has to win first.
//
//  Owner: `AppModel.family`. Tests: FamilyAlertPolicyTests / GrokBotEventTests cover the decisions
//  and the wire format; this file is the thin effectful shell around them.
//

import CaneKitLogic
import Foundation
import Observation

/// Sends cane events to the Grok Bot routine. One instance, owned by `AppModel`.
@Observable
final class FamilyAlerts {

    /// Opt-in. While false nothing is sent, including the periodic breadcrumb.
    var enabled = false

    /// Last thing that happened, for the Settings row. Never claims an SMS was sent.
    private(set) var lastStatus: String?

    /// True when a webhook URL + key are configured; false makes the Settings row explain why the
    /// feature cannot work rather than failing silently.
    var isConfigured: Bool { client != nil }

    /// Who is walking / which cane, attached to every event so the bot's text can name them.
    /// `nil` simply omits the field.
    var user: String?
    var caneID: String? = "opencane-01"

    /// Every number lives here (CaneKitLogic).
    @ObservationIgnored private var policy = FamilyAlertPolicy()
    /// nil when unconfigured; resolved once at init.
    @ObservationIgnored private let client: GrokBotClient?

    init(client: GrokBotClient? = GrokBotClient.fromSecrets()) {
        self.client = client
    }

    /// Route start / stop: forget the rate limits so the first fix of a new walk goes out.
    func reset() {
        policy.reset()
    }

    // MARK: Detections

    /// Periodic GPS breadcrumb (`info`, chat-only). `now` is the caller's monotonic clock.
    func location(lat: Double, lng: Double, accuracyM: Double?, heading: Double?,
                  speedMps: Double?, now: TimeInterval) {
        guard enabled else { return }
        guard let event = policy.location(lat: lat, lng: lng, accuracyM: accuracyM,
                                          headingDegrees: heading, speedMps: speedMps, now: now)
        else { return }
        send(event)
    }

    /// A close obstacle the cane cannot find (`warn` — this one can text family).
    func obstacle(kind: String?, distanceM: Double?, direction: String?, lat: Double?, lng: Double?,
                  note: String?, now: TimeInterval) {
        guard enabled else { return }
        guard let event = policy.obstacle(kind: kind, distanceM: distanceM, direction: direction,
                                          lat: lat, lng: lng, note: note, now: now)
        else { return }
        send(event)
    }

    /// Phone battery low enough to end guidance (`warn`, once per discharge).
    func lowBattery(pct: Int) {
        guard enabled else { return }
        guard let event = policy.lowBattery(pct: pct) else { return }
        send(event)
    }

    /// Suspected fall (`critical`, never rate-limited).
    ///
    /// ⚠ **Nothing calls this yet — OpenCane has no fall detector.** It exists so the detector,
    /// when it is written, has one obvious place to report to. `sendTestEvent()` exercises the
    /// same path end to end.
    func fall(lat: Double?, lng: Double?, note: String? = nil) {
        guard enabled else { return }
        send(FamilyAlertPolicy.fall(lat: lat, lng: lng, note: note))
    }

    /// Walker asked for help (`critical`, never rate-limited).
    ///
    /// ⚠ **Nothing calls this yet — there is no SOS control in the UI.** Same reason as `fall`.
    func sos(lat: Double?, lng: Double?, note: String? = nil) {
        guard enabled else { return }
        send(FamilyAlertPolicy.sos(lat: lat, lng: lng, note: note))
    }

    /// Quiet state change (`info`): route started, arrived.
    func status(_ note: String, lat: Double? = nil, lng: Double? = nil) {
        guard enabled else { return }
        send(FamilyAlertPolicy.status(note, lat: lat, lng: lng))
    }

    // MARK: Debug

    /// Posts the sample `fall` event from the README's curl, bypassing `enabled` and every rate
    /// limit, and reports what came back. This is the "Send test event" button: it is how the
    /// walker's family checks the whole chain before a walk, so it must work even while the
    /// feature is switched off.
    /// - Returns: a line for the UI to show and speak. Never claims an SMS was sent.
    @discardableResult
    func sendTestEvent(lat: Double? = nil, lng: Double? = nil) async -> String {
        guard let client else {
            let line = GrokBotResult.notConfigured.summary
            lastStatus = line
            return line
        }
        let event = FamilyAlertPolicy.fall(lat: lat, lng: lng, note: "Test event from OpenCane")
            .taggedWith(user: user, caneID: caneID)
        let line = await client.send(event).summary
        lastStatus = line
        return line
    }

    // MARK: Sending

    /// Fire-and-forget: a cue must never wait on a POST. The result only updates `lastStatus`.
    private func send(_ event: OpenCaneEvent) {
        guard let client else {
            lastStatus = GrokBotResult.notConfigured.summary
            return
        }
        let tagged = event.taggedWith(user: user, caneID: caneID)
        Task { [weak self] in
            let result = await client.send(tagged)
            self?.lastStatus = result.summary
        }
    }
}

private extension OpenCaneEvent {
    /// Adds who / which cane without overwriting a value the caller already set.
    func taggedWith(user: String?, caneID: String?) -> OpenCaneEvent {
        var copy = self
        if copy.user == nil { copy.user = user }
        if copy.caneID == nil { copy.caneID = caneID }
        return copy
    }
}
