//
//  AppModel+Indoor.swift
//  CaneKit
//
//  The AppModel side of the indoor leg (Step 62): the voice actions ("take me from ISR to CIF",
//  "I'm outside"), and the hooks that make next / repeat / Stop route / Simulate walk / status act on
//  the indoor script while one is walked. Kept in an extension so AppModel.swift carries only one
//  hook line per entry point (another step edits AppModel's Live Activity regions in parallel).
//
//  Hook lines in AppModel.swift (each calls into this file or `indoor` directly):
//    · `let indoor = IndoorGuide()` (engines) and `indoor.attach(self)` in `start()`;
//    · `location.onFix` → `indoor.ingest(fix)`;
//    · `voiceInput.onTranscriptionFinalized` → `indoor.takeTranscript` (the landmark hook);
//    · `nextWaypoint` → `indoorHandlesNext()`, `repeatInstruction` → `indoorHandlesRepeat()`,
//      `startSimulatedWalk` → `indoorHandlesSimulate()`, `stopSimulatedWalk` → `indoor.stopSimulation()`,
//      `stopRoute` → `indoor.stop(reason:)`.
//  `speakStatus` (HandsFreeIntents.swift) and `ConversationCoordinator.currentStatusFacts` set
//  `StatusFacts.indoorClause` from `indoor.statusClause`.
//
//  Callers: `ConversationCoordinator.executeAction` (`.routeFromTo`, `.indoorOutside`), the
//  Settings "Start indoor route" button. Tests: the decisions are `IndoorScriptCatalog` /
//  `IndoorHandover` in CaneKitLogic (IndoorRouteTests); this glue has none (app target).
//

import CaneKitLogic
import Foundation

extension AppModel {

    /// "take me from A to B" (`.routeFromTo`). An indoor script whose `fromAliases` match `from`
    /// (`IndoorScriptCatalog.script(forOrigin:)`) is walked, with `to` as the outdoor leg after the
    /// handover; otherwise it is a plain `navigate(to:)`. Both paths speak for themselves.
    /// Logs `indoor {action: no_script, origin, destination}` for the fallback.
    /// - Parameters:
    ///   - from: the spoken origin.
    ///   - to: the spoken destination.
    /// - Returns: the line recorded as the conversation turn (already spoken by the effect).
    func routeFromTo(from: String, to: String) -> String {
        guard let script = IndoorScriptCatalog.script(forOrigin: from, in: indoor.scripts) else {
            logger.event("indoor", ["action": "no_script", "origin": from, "destination": to])
            navigate(to: to)
            return "Routing to \(to)."
        }
        startIndoor(script, destination: to, source: "voice")
        return "Indoors: \(script.name), then \(to)."
    }

    /// Settings "Start indoor route" (testing): the catalog's ISR script (`defaultRecordingID`), else
    /// the first one, to the CIF demo route. Says "No indoor route saved." with an empty catalog.
    func startIndoorRouteForTesting() {
        guard let script = indoor.scripts.first(where: { $0.id == IndoorScriptCatalog.defaultRecordingID })
                ?? indoor.scripts.first else {
            speech.say("No indoor route saved.", .nav, ttl: 6)
            return
        }
        startIndoor(script, destination: nil, source: "settings")
    }

    /// Starts an indoor walk. An outdoor route running, queued or being built is stopped first (the
    /// newest request wins; that path says "Route stopped.").
    private func startIndoor(_ script: IndoorScript, destination: String?, source: String) {
        if nav.isNavigating || routeStartWaiting || isBuildingRoute { stopRoute() }
        indoor.start(script: script, destination: destination, source: source)
    }

    /// "I'm outside" (`.indoorOutside`): `IndoorGuide.walkerIsOutside()`. Speaks "Waiting for GPS
    /// outside." when it arms the wait; nothing when it hands over at once, because the outdoor leg
    /// already speaks on every path ("Obstacle detection warming up…" from `queueRouteStart`, the
    /// route intro from `NavigationEngine.start` on the degraded path, "Finding a route to …" from
    /// `buildRoute`, or its refusal line) — so `alreadySpoken: true` is correct (Muse M6 rejected:
    /// a second "Starting the outdoor route." would queue on top of it); "No indoor route running."
    /// is left for the coordinator to speak.
    /// - Returns: the conversation turn's line and whether it was already spoken.
    func indoorOutside() -> (response: String, alreadySpoken: Bool) {
        switch indoor.walkerIsOutside() {
        case .notActive:
            return ("No indoor route running.", false)
        case .waiting:
            speech.say("Waiting for GPS outside.", .nav, ttl: 20)
            return ("Waiting for GPS outside.", true)
        case .handedOver:
            return ("Starting the outdoor route.", true)
        }
    }

    /// Hook at the top of `nextWaypoint()`: while indoors, advance the indoor step instead.
    /// - Returns: true when handled.
    func indoorHandlesNext() -> Bool {
        guard indoor.isActive else { return false }
        indoor.next()
        return true
    }

    /// Hook at the top of `repeatInstruction()`: while indoors, say the current step again.
    /// `IndoorGuide.repeatLine` logs `indoor {action: repeat}` (the duplicate outdoor-style `repeat`
    /// record was removed in the review round, 9e).
    /// - Returns: true when handled.
    func indoorHandlesRepeat() -> Bool {
        guard indoor.isActive else { return false }
        indoor.repeatLine()
        return true
    }

    /// Hook at the top of `startSimulatedWalk(speedMps:)`: while indoors, simulate steps instead of
    /// GPS fixes (`IndoorGuide.simulate`).
    /// - Returns: true when handled.
    func indoorHandlesSimulate() -> Bool {
        guard indoor.isActive else { return false }
        indoor.simulate()
        return true
    }
}
