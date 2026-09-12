//
//  DestinationSearch.swift
//  CaneKit
//
//  Live "as you type" destination suggestions for the Guide card's search box — the thing Apple
//  Maps and Google Maps give you and CaneKit did not. Owns one `MKLocalSearchCompleter` biased to
//  the walker's surroundings and merges its rows with the campus gazetteer through
//  `CaneKitLogic.DestinationSuggestions` (campus places first: MKLocalSearch answers "Grainger"
//  with an industrial supply store, and a blind walker cannot see that the list is wrong).
//
//  Owner: `DestinationField` (ios/CaneKit/UI/DestinationField.swift) holds one as `@State` while
//  the idle Guide card is on screen. Starting a route is NOT this class's job: the field calls
//  `AppModel.navigate(to:)` / `navigate(to place:)`, the same path Siri uses.
//
//  Threading / isolation: `@MainActor @Observable`. `MKLocalSearchCompleterDelegate` is not
//  main-actor, so the delegate is a `nonisolated` relay (`CompleterRelay`, AGENTS.md hard rule 1)
//  that extracts Sendable strings from the non-Sendable `MKLocalSearchCompletion`s and hops back
//  with `Task { @MainActor in … }`. Nothing else touches the completer off main.
//
//  Key invariants:
//    · ⚠ The keystroke debounce is `DestinationSuggestions.debounceSeconds` (0.25 s, pinned by
//      `debounceIsAQuarterOfASecond`); never write the number here.
//    · A completer reply is accepted only while its `queryFragment` is still what the walker has
//      typed, so a slow reply for "gra" cannot repopulate the list under "grainger".
//    · Region: the fix passed with the keystroke when there is one, else `CampusPlaces.center`.
//      (This used to say GPS only runs during a route; since bf03253 GPS runs for the whole
//      foreground session, so the idle field normally has a fix. The centre now covers the
//      seconds before a first fix, a denied permission, and indoors.) The campus centre biases
//      the search; it is never used as a distance origin (that would be a made-up number).
//    · The search radius is `RouteSource.searchRadiusM`, the same 3 km the route builder accepts.
//
//  Tests: the ranking, debounce and minimum length are pure and pinned in CaneKitLogic
//  (`DestinationSuggestionsTests`); this class (completer, relay, stale-reply fence) has no unit
//  test — `CaneKitUITests.testTypingOffersCampusSuggestionsAndClearsTheError` types "Grainger"
//  and asserts the campus row is offered above every map row.
//

import CaneKitLogic
import CoreLocation
import Foundation
import MapKit
import Observation

/// The destination search box's data source: debounced completer queries merged with the campus
/// gazetteer, published as a ready-to-draw list of `DestinationSuggestion`s.
@MainActor
@Observable
final class DestinationSearch {

    /// The list to draw, campus places first (≤ `DestinationSuggestions.maxSuggestions` = 6, of which
    /// ≤ 3 campus). Empty for a query shorter than `DestinationSuggestions.minimumQueryLength` (2)
    /// and after `clear()`. Drawn by `DestinationField`; a tapped row calls `AppModel.navigate`.
    private(set) var suggestions: [DestinationSuggestion] = []

    /// Set when MapKit's completer failed (usually no network) and there is nothing else to show;
    /// nil otherwise. Shown as a quiet secondary line, never as an error block: the campus
    /// gazetteer still works offline. `DestinationField` also announces it instead of the row
    /// count when the list is empty. Cleared by every keystroke and by any accepted reply.
    private(set) var lastError: String?

    /// Bumped by every *answer that changed the list*, never by `clear()`.
    /// `DestinationField` announces the row count off this counter, so (a) emptying the list
    /// because a route just started cannot make VoiceOver say "No matching places" over
    /// "Walking to Grainger Engineering Library, 400 meters." (Muse review) and (b) a keystroke
    /// that does not change the list announces nothing (adversarial review, Step 14).
    private(set) var revision = 0

    /// The completer. Configured once; `queryFragment` is rewritten on every debounced keystroke.
    @ObservationIgnored private let completer = MKLocalSearchCompleter()
    /// The `nonisolated` delegate; held because `MKLocalSearchCompleter.delegate` is weak.
    @ObservationIgnored private var relay: CompleterRelay?
    /// What the walker has typed (untrimmed), used to check a reply is still relevant.
    @ObservationIgnored private var query = ""
    /// The fix the current list was built from; nil means no distances are shown and the completer
    /// region falls back to `CampusPlaces.center`.
    @ObservationIgnored private var origin: Coordinate?
    /// The last completer rows accepted for `query`, kept so a fix or a re-rank does not need a
    /// new network round trip.
    @ObservationIgnored private var completions: [CompletionLine] = []
    /// The pending debounce; cancelled by the next keystroke and by `clear()`.
    @ObservationIgnored private var debounce: Task<Void, Never>?

    /// Wires the completer to points of interest and addresses (the same result types
    /// `RouteSource.mapKit(to:from:)` searches) and installs the nonisolated delegate relay.
    init() {
        completer.resultTypes = [.pointOfInterest, .address]
        let relay = CompleterRelay(
            onResults: { [weak self] fragment, lines in
                Task { @MainActor in self?.accept(lines, for: fragment) }
            },
            onFailure: { [weak self] fragment, noResults in
                Task { @MainActor in self?.fail(noResults: noResults, for: fragment) }
            })
        self.relay = relay
        completer.delegate = relay
    }

    // MARK: Input

    /// New text in the field; call on every keystroke.
    ///
    /// Campus matches are published immediately — they are local, so the walker hears "2 results"
    /// while the network is still thinking — and MapKit is asked once the typing pauses for
    /// `DestinationSuggestions.debounceSeconds`.
    /// - Parameters:
    ///   - text: exactly what is in the field.
    ///   - fix: the fix as of this keystroke (`DestinationField` passes `model.location.fix`), or
    ///     nil. Used for the region bias and, when present, for the distance shown on campus rows.
    ///     Nothing re-ranks on a *new* fix between keystrokes: the next keystroke picks it up. (The
    ///     old reason — "GPS does not run while the idle card is on screen" — stopped being true in
    ///     bf03253; re-ranking on every fix would also re-announce the row count, see `revision`.)
    ///     The fix's accuracy is not checked: a poor fix still biases and measures.
    func update(text: String, fix: GeoFix?) {
        query = text
        origin = fix?.coordinate
        debounce?.cancel()
        guard CampusPlaces.normalize(text).count >= DestinationSuggestions.minimumQueryLength else {
            completer.cancel()
            completions = []
            lastError = nil
            suggestions = []
            return
        }
        // Local answers first: the gazetteer needs no network and no waiting. The completer's rows
        // are dropped, not kept: they answer the *previous* fragment, and a blind walker tapping
        // row 2 must never reach a place that matched what they typed a keystroke ago.
        completions = []
        lastError = nil                      // a past failure must not caption a fresh query
        republish()
        // `@MainActor` is explicit rather than inherited: this task touches the completer.
        debounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(DestinationSuggestions.debounceSeconds))
            // `query == text` as well as the cancellation check: belt and braces, so a debounce
            // that somehow outlives its keystroke cannot search for text that is no longer typed.
            guard !Task.isCancelled, let self, self.query == text else { return }
            self.ask(text)
        }
    }

    /// Drops the list and any in-flight query (the field was cleared, submitted, or a route
    /// started). Leaves the completer configured for the next time the field is used.
    /// ⚠ Must not bump `revision` (Muse review, Step 14): it runs the moment a route starts, and an
    /// announcement then would say "No matching places" over "Walking to …".
    func clear() {
        debounce?.cancel()
        debounce = nil
        completer.cancel()
        query = ""
        completions = []
        lastError = nil
        suggestions = []
    }

    // MARK: MapKit

    /// Points the completer at `text` inside a square of `2 × RouteSource.searchRadiusM` around
    /// the fix (or the campus centre). Runs after the debounce, on the main actor.
    private func ask(_ text: String) {
        let centre = origin ?? CampusPlaces.center
        completer.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centre.latitude, longitude: centre.longitude),
            latitudinalMeters: 2 * RouteSource.searchRadiusM,
            longitudinalMeters: 2 * RouteSource.searchRadiusM)
        completer.regionPriority = .required     // nearby places, not the most famous match anywhere
        completer.queryFragment = text
    }

    /// A completer reply. Ignored unless its fragment is still what the walker typed.
    /// Reached through a `Task { @MainActor }` hop, not `MainActor.assumeIsolated`: MapKit does not
    /// promise the delivery thread, and a trap there is worse than one momentarily stale list for
    /// the same query (Step 14 review proposal, rejected — see docs/CODE_REFERENCE.md).
    private func accept(_ lines: [CompletionLine], for fragment: String) {
        guard fragment == query else { return }
        completions = lines
        lastError = nil
        republish()
    }

    /// A completer failure. MapKit reports "nothing matched" as an error too, and that is not a
    /// fault worth a line on screen — `noResults` separates the two, so the app never claims a
    /// network problem it did not observe. MapKit's own message is deliberately not shown (it is
    /// developer wording). The campus gazetteer still answers offline, so a real failure only
    /// becomes visible when there is nothing else to show.
    private func fail(noResults: Bool, for fragment: String) {
        guard fragment == query else { return }
        completions = []
        republish()
        lastError = (!noResults && suggestions.isEmpty) ? "Place search is unavailable right now" : nil
    }

    /// Re-runs the pure ranking (`CaneKitLogic`) over the current query, rows and fix. `revision`
    /// is bumped only when the list really changed, so typing another letter that narrows nothing
    /// does not make VoiceOver repeat the row count.
    private func republish() {
        let next = DestinationSuggestions.suggestions(query: query, completions: completions, from: origin)
        guard next.map(\.id) != suggestions.map(\.id) else { return }
        suggestions = next
        revision += 1
    }
}

// MARK: - Delegate relay

/// `MKLocalSearchCompleterDelegate` off the main actor (hard rule 1): it copies the two strings
/// out of each non-Sendable `MKLocalSearchCompletion` together with the fragment they answer, and
/// hands them to the closures, which hop to the main actor themselves. Holds no mutable state
/// (two `let` closures), so no `@unchecked Sendable` is needed or declared.
private nonisolated final class CompleterRelay: NSObject, MKLocalSearchCompleterDelegate {

    /// Called with (queryFragment, rows) on every update.
    private let onResults: @Sendable (String, [CompletionLine]) -> Void
    /// Called with (queryFragment, noResults) when MapKit refuses. `noResults` is true for
    /// `MKError.placemarkNotFound` — "nothing matched", which is an answer, not a failure.
    private let onFailure: @Sendable (String, Bool) -> Void

    /// Creates the relay with the two Sendable callbacks `DestinationSearch` installs.
    init(onResults: @escaping @Sendable (String, [CompletionLine]) -> Void,
         onFailure: @escaping @Sendable (String, Bool) -> Void) {
        self.onResults = onResults
        self.onFailure = onFailure
    }

    /// New rows: reduced to `CompletionLine`s (Sendable) before they cross the actor hop.
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        onResults(completer.queryFragment,
                  completer.results.map { CompletionLine(title: $0.title, subtitle: $0.subtitle) })
    }

    /// A failed completion round. Classified here (an `MKError` is not `Sendable`): only the
    /// fragment and one Bool cross the hop.
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        onFailure(completer.queryFragment, (error as? MKError)?.code == .placemarkNotFound)
    }
}
