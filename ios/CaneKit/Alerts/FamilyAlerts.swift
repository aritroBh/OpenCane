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

    /// Let a cheap model add one family-facing sentence (`extra.ai_context`). Default on, but it
    /// is a switch because the summary costs a request per alert and adds up to
    /// `AlertSummarizer.requestTimeout` to how long an alert takes to leave the phone; on a flaky
    /// network a walker may prefer the facts immediately.
    var aiContextEnabled = true

    /// True when a text model is configured at all (Anthropic / custom / OpenAI key).
    var canSummarize: Bool { summarizer != nil }

    /// Name of the model writing `ai_context`, for the Settings row.
    var summarizerName: String? { summarizer?.provider.name }

    /// What the phone knew when the event fired. Set by `AppModel` in `start()`; without it the
    /// events still go, carrying only what the detection itself knew.
    @ObservationIgnored var contextProvider: (@MainActor () -> AlertContext)?

    /// Every number lives here (CaneKitLogic).
    @ObservationIgnored private var policy = FamilyAlertPolicy()
    /// nil when unconfigured; resolved once at init.
    @ObservationIgnored private let client: GrokBotClient?
    /// nil when no text-model key is present; then alerts carry facts and no `ai_context`.
    @ObservationIgnored private let summarizer: AlertSummarizer?

    init(client: GrokBotClient? = GrokBotClient.fromSecrets(),
         summarizer: AlertSummarizer? = AlertSummarizer.fromSecrets()) {
        self.client = client
        self.summarizer = summarizer
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

    /// The vision model described a weapon or an attacker ahead (`critical`, one per two minutes).
    func threat(_ sighting: ThreatSighting, lat: Double?, lng: Double?, now: TimeInterval) {
        guard enabled else { return }
        guard let event = policy.threat(sighting, lat: lat, lng: lng, now: now) else { return }
        send(event)
    }

    /// A walk began (`warn`, so the bot emails — see `FamilyAlertPolicy.tripStarted`).
    func tripStarted(destination: String?, lat: Double?, lng: Double?) {
        guard enabled else { return }
        send(FamilyAlertPolicy.tripStarted(destination: destination, lat: lat, lng: lng))
    }

    /// A walk ended, by arriving or by being stopped.
    func tripEnded(destination: String?, arrived: Bool, lat: Double?, lng: Double?) {
        guard enabled else { return }
        send(FamilyAlertPolicy.tripEnded(destination: destination, arrived: arrived,
                                         lat: lat, lng: lng))
    }

    /// Suspected fall (`critical`, never rate-limited).
    ///
    /// Called by `AppModel` from `FallWatcher` (CoreMotion → `FallDetector`). ⚠ Those thresholds
    /// are unvalidated guesses; see FallDetector.swift.
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

    /// Records a tap that the 10 s spam guard refused, so the Settings row explains the silence.
    func noteThrottled(secondsRemaining: Int) {
        lastStatus = "Too quick — try again in \(secondsRemaining) second\(secondsRemaining == 1 ? "" : "s")."
    }

    // MARK: Family contacts

    /// Registers the family email list with the bot (`type: "family_contacts"`). The bot stores it
    /// and Gmails whoever is on it when a later `fall` / `sos` / `warn` event arrives.
    ///
    /// ⚠ Three deliberate differences from every other send here, each worth keeping:
    ///   1. **It ignores `enabled`.** Registering is setup: the walker fills in the list *before*
    ///      switching alerts on, and a Save that silently did nothing would be the worst outcome.
    ///   2. **No context, and no summarizer.** `prepare(_:)` and `deliver(…)` are skipped entirely.
    ///      A registration is bookkeeping, not an alert, so there is nothing to summarise — and it
    ///      means a family's email addresses are never put in front of a language model.
    ///   3. **No rate limit.** The walker pressed Save; the list has to leave the phone.
    ///
    /// - Parameter sendTest: asks the bot to email each address a short confirmation. The app
    ///   itself sends no email, ever.
    /// - Returns: a line for the UI to show and speak.
    @discardableResult
    func registerContacts(_ emails: [String], sendTest: Bool) async -> GrokBotResult {
        guard let client else {
            lastStatus = GrokBotResult.notConfigured.summary
            return .notConfigured
        }
        let event = FamilyContacts.registration(emails: emails, sendTest: sendTest)
            .taggedWith(user: user, caneID: caneID)
        let result = await client.send(event)
        lastStatus = result.summary
        return result
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
        let (event, prompt) = prepare(FamilyAlertPolicy.fall(lat: lat, lng: lng,
                                                             note: "Test event from OpenCane"))
        let line = await deliver(event, prompt: prompt, client: client).summary
        lastStatus = line
        return line
    }

    // MARK: Sending

    /// Fire-and-forget: a cue must never wait on a POST, nor on the summary. The result only
    /// updates `lastStatus`.
    private func send(_ event: OpenCaneEvent) {
        guard let client else {
            lastStatus = GrokBotResult.notConfigured.summary
            return
        }
        // Context is read here, synchronously on the main actor, so it describes the moment the
        // event fired rather than whenever the Task happens to run.
        let (enriched, prompt) = prepare(event)
        Task { [weak self] in
            let result = await self?.deliver(enriched, prompt: prompt, client: client)
            self?.lastStatus = result?.summary
        }
    }

    /// Attaches who / which cane and everything the phone knew, and builds the model's prompt.
    /// Main-actor and synchronous on purpose (see `send`).
    private func prepare(_ event: OpenCaneEvent) -> (OpenCaneEvent, String) {
        let context = contextProvider?() ?? AlertContext()
        var out = event.taggedWith(user: user, caneID: caneID)
        // Caller-set keys win: a detector that already described something knows better than the
        // generic snapshot.
        var extra = context.extraFields()
        for (key, value) in out.extra ?? [:] { extra[key] = value }
        out.extra = extra
        let prompt = AlertContextPrompt.text(eventType: out.type.rawValue,
                                             severity: out.severity?.rawValue,
                                             note: out.note, lat: out.lat, lng: out.lng,
                                             context: context)
        return (out, prompt)
    }

    private func deliver(_ event: OpenCaneEvent, prompt: String,
                         client: GrokBotClient) async -> GrokBotResult {
        var toSend = event
        if aiContextEnabled, let summarizer, let line = await summarizer.summarize(prompt: prompt) {
            toSend.extra?["ai_context"] = .string(line)
        }
        let result = await client.send(toSend)
        Task { [toSend, result] in
            let statusStr: String
            let code: Int?
            let err: String?
            switch result {
            case .accepted:
                statusStr = "posted"
                code = 200
                err = nil
            case .rejected(let status, let body):
                statusStr = "rejected"
                code = status
                err = body
            case .failed(let message):
                statusStr = "failed"
                code = nil
                err = message
            case .notConfigured:
                statusStr = "not_configured"
                code = nil
                err = nil
            }
            await SupabaseClient.shared.recordFamilyAlert(
                event: toSend,
                deliveryStatus: statusStr,
                statusCode: code,
                errorMessage: err
            )
        }
        return result
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
