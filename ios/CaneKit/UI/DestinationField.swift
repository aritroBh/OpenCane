//
//  DestinationField.swift
//  CaneKit
//
//  The destination search box on the idle Guide card: a proper search field (magnifying glass,
//  clear button, 60 pt tall, design-system fill and hairline), a live suggestion list as the
//  walker types, and the "Go" button. Replaces the bare `TextField` + "Go" pair that shipped
//  through Step 13, which offered no suggestions and no way off the keyboard.
//
//  Implements docs/design.md §6.3 (route choice: gazetteer first, then MapKit) and §3 (touch
//  targets, radius) with the tokens in Theme.swift. Suggestions come from
//  `DestinationSearch` (MKLocalSearchCompleter, debounced) merged with the campus gazetteer by
//  `CaneKitLogic.DestinationSuggestions`; the ranking, the caps and the debounce are pure logic
//  with tests, not decisions made here.
//
//  Accessibility contract — this view is used by people who never see it (AGENTS.md rule 9):
//    ⚠ test contract: the button labelled "Go" (testDestinationFieldRejectsEmptyQuery) and the
//      text field labelled "Destination" (placeholder "Or type a destination").
//    · every suggestion row is one VoiceOver button labelled "<place>, campus place, 400 meters
//      away, <address>" with the hint "Starts walking guidance to this place".
//    · the row count is posted as a VoiceOver announcement whenever the list changes, because a
//      blind walker has no way to notice that a list appeared under the field. This is the one
//      `AccessibilityNotification.Announcement` in the app (design.md §5.5): it is UI state, not
//      a cue, so it cannot double-speak anything `SpeechQueue` says. It is deliberately silent
//      when the list is torn down (a route starting) and when a keystroke changes nothing.
//    · nothing here has a fixed height: at accessibility text sizes the field and every row grow,
//      and the "Campus" badge (one line by definition) gives way to the words "On campus".
//    · every tappable thing is at least `CKMetrics.touchTarget` (60 pt) in both directions,
//      including the clear (x): it sits beside Go, where a miss would start a route.
//
//  Starting a route always goes through `AppModel.navigate(to:)` / `navigate(to place:)` — the
//  same two entry points Siri uses — so "Walking to <place>, N meters." is still spoken before
//  guidance and Stop still abandons a search in flight. There is no second route-start path.
//

import CaneKitLogic
import SwiftUI

/// Destination search box + suggestion list + "Go", shown on the idle Guide card.
///
/// Owns the `DestinationSearch` (one completer) for as long as the idle card is on screen; the
/// typed text itself lives in `AppModel.destinationQuery`, so Siri and the field stay in step.
struct DestinationField: View {
    /// App-wide owner of navigation, location and the route error line.
    @Environment(AppModel.self) private var model
    /// Live suggestions: campus gazetteer + debounced `MKLocalSearchCompleter`.
    @State private var search = DestinationSearch()
    /// Keyboard focus, so Done / submit / a tap outside can give the keyboard back.
    @FocusState private var focused: Bool
    /// The last sentence announced to VoiceOver, so the same count is not repeated per keystroke.
    /// Reset whenever the list is torn down, or a re-typed query with the same count would be silent.
    @State private var lastAnnouncement: String?
    /// The text `AppModel.navigate(to:)` wrote back into `destinationQuery` when a route started.
    /// The field must not treat its own write-back as a keystroke (adversarial review, Step 14).
    @State private var mirroredText: String?
    /// Scrolls the field to the top of the screen when the keyboard appears, so the card is not
    /// hidden behind it and the suggestions have room. Passed down from `ContentView`.
    let scroller: ScrollViewProxy?

    /// Scroll anchor for `scroller`; also the identity of the field in the scroll view.
    static let anchorID = "destination-field"

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: CKSpacing.sm) {
            HStack(spacing: CKSpacing.sm) {
                field($model.destinationQuery)
                // ⚠ test contract: "Go" (testDestinationFieldRejectsEmptyQuery taps it empty).
                Button(action: submit) {
                    // Explicit padding + fixedSize: the HStack must never squeeze this label.
                    Text("Go")
                        .font(CKFont.body.weight(.semibold))
                        .padding(.horizontal, CKSpacing.lg)
                        .frame(minWidth: 64, minHeight: CKMetrics.touchTarget)
                }
                .buttonStyle(CKBigButtonStyle(role: .secondary))
                .fixedSize(horizontal: true, vertical: false)
                .disabled(model.isBuildingRoute)
                .accessibilityLabel("Go")
                .accessibilityHint("Builds a walking route with Apple Maps to what you typed")
            }
            .id(Self.anchorID)

            if !search.suggestions.isEmpty {
                suggestionList
            } else if let err = search.lastError {
                // Not an error block: the gazetteer still answers offline, MapKit does not.
                Text(err)
                    .font(CKFont.secondary)
                    .foregroundStyle(CKColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Every keystroke: clear the stale error line and re-rank (the completer is debounced).
        // ⚠ Two things this must not react to, both found in review:
        //  · its own write-back — `AppModel.navigate(to:)` puts the chosen place (or the trimmed
        //    text) into `destinationQuery`; treating that as typing would re-open the list, fire a
        //    completer query for the place already being routed to, and announce "1 result" over
        //    the spoken "Finding a route to …";
        //  · anything at all while a route is being built (the belt to that braces).
        .onChange(of: model.destinationQuery) { _, text in
            if text == mirroredText { mirroredText = nil; return }
            mirroredText = nil
            guard !model.isBuildingRoute else { return }
            model.clearRouteError()
            // Below the minimum length the list is torn down without an answer, so let the next
            // real answer speak even if it has the same row count as the last one.
            if CampusPlaces.normalize(text).count < DestinationSuggestions.minimumQueryLength {
                lastAnnouncement = nil
            }
            search.update(text: text, fix: model.location.fix)
        }
        // A blind walker cannot see a list appear under the field, so say how many rows there are.
        // Driven by `search.revision` (bumped only by an *answer*), so emptying the list because a
        // route just started never announces "No matching places" over the route's own line.
        .onChange(of: search.revision) { _, _ in announceResults() }
        // Bring the whole box to the top of the screen so the keyboard cannot cover the list.
        // Deliberately unanimated: the big-button press is the only animation the app owns
        // (design.md §4), and an animation here would have to answer to Reduce Motion for nothing.
        .onChange(of: focused) { _, isFocused in
            guard isFocused, let scroller else { return }
            scroller.scrollTo(Self.anchorID, anchor: .top)
        }
        // One text field in the app, so an unconditional keyboard toolbar is unambiguous.
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = false }
                    .font(CKFont.body.weight(.semibold))
                    .accessibilityLabel("Done")
                    .accessibilityHint("Hides the keyboard")
            }
        }
    }

    // MARK: Pieces

    /// The search field itself: leading magnifying glass, the text, a clear button once there is
    /// something to clear. Fill, hairline and radius are the secondary-button treatment, so it
    /// reads as a control rather than a hole in the card, and it is `touchTarget` tall (60 pt,
    /// well over the 44 pt minimum) with no fixed height, so it grows with Dynamic Type.
    /// - Parameter text: binding to `AppModel.destinationQuery`.
    private func field(_ text: Binding<String>) -> some View {
        let shape = RoundedRectangle(cornerRadius: CKRadius.button, style: .continuous)
        return HStack(spacing: CKSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.semibold))
                .foregroundStyle(CKColor.textSecondary)
                .accessibilityHidden(true)
            // ⚠ test contract: label "Destination", placeholder "Or type a destination".
            TextField("Or type a destination", text: text)
                .textFieldStyle(.plain)
                .font(CKFont.body)
                .foregroundStyle(CKColor.textPrimary)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($focused)
                .onSubmit(submit)
                .accessibilityLabel("Destination")
                .accessibilityHint("Type a place name. Matching places appear below as you type.")
            if !text.wrappedValue.isEmpty {
                Button { clearText() } label: {
                    // A full `touchTarget` square: the clear button sits right next to Go, and a
                    // walker aiming by feel who misses it would start a route instead of emptying
                    // the box. 22 pt of glyph was not enough (adversarial review, Step 14).
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(CKColor.textSecondary)
                        .frame(minWidth: CKMetrics.touchTarget, minHeight: CKMetrics.touchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear destination")
                .accessibilityHint("Empties the destination box")
            }
        }
        .padding(.horizontal, CKSpacing.md)
        .padding(.vertical, CKSpacing.sm)
        .frame(minHeight: CKMetrics.touchTarget)
        .background(CKColor.surfaceRaised, in: shape)
        .overlay(shape.strokeBorder(CKColor.border, lineWidth: CKMetrics.border(for: contrast) + 1))
    }

    /// Increase Contrast thickens the field and row hairlines, like every other control.
    @Environment(\.colorSchemeContrast) private var contrast
    /// Accessibility text sizes drop the "Campus" badge (the word "On campus" carries it instead).
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The suggestion rows. Campus places come first (they are marked "Campus" and use a building
    /// glyph); a tap starts guidance at once — there is no second tap on Go.
    private var suggestionList: some View {
        VStack(spacing: CKSpacing.xs) {
            ForEach(search.suggestions) { suggestion in
                // The accessibility modifiers go on the row *inside* the button's label, not on
                // the button. On the button they raced: a `Button` already builds an element from
                // its label, so `children: .ignore` outside it left the composed children exposed
                // and VoiceOver read the row as "Grainger Engineering Library, On campus, Campus"
                // — the visible title, the detail line and the badge word, in that order — instead
                // of the sentence we wrote. Both labels were observed on the same row in one
                // XCUITest run, which is also what made the test flaky.
                Button { choose(suggestion) } label: {
                    row(suggestion)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(suggestion.voiceOverLabel)
                }
                    .buttonStyle(.plain)
                    .accessibilityHint(suggestion.voiceOverHint)
                    .accessibilityAddTraits(.isButton)
            }
        }
    }

    /// One suggestion row: glyph, name, detail line ("On campus · 400 m" or the address), and the
    /// "Campus" badge for a gazetteer place. Never truncated; it wraps and the row grows.
    /// - Parameter s: the row to draw.
    private func row(_ s: DestinationSuggestion) -> some View {
        let shape = RoundedRectangle(cornerRadius: CKRadius.button, style: .continuous)
        return HStack(spacing: CKSpacing.md) {
            Image(systemName: s.kind == .campus ? "building.columns.fill" : "mappin.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(CKColor.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: CKSpacing.xs / 2) {
                Text(s.title)
                    .font(CKFont.body.weight(.semibold))
                    .foregroundStyle(CKColor.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if !s.detailLine.isEmpty {
                    Text(s.detailLine)
                        .font(CKFont.secondary)
                        .foregroundStyle(CKColor.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            // The badge is dropped at accessibility text sizes: a pill is one line that scales to
            // 80 % (Theme.swift), so "CAMPUS" would clip *and* steal width from the wrapping
            // title. The row still says "On campus" in words and VoiceOver still says "campus
            // place" (adversarial review, Step 14).
            if s.kind == .campus, !typeSize.isAccessibilitySize {
                CKStatusPill(text: "Campus", tone: .accent)
            }
        }
        .padding(.horizontal, CKSpacing.md)
        .padding(.vertical, CKSpacing.sm)
        .frame(maxWidth: .infinity, minHeight: CKMetrics.touchTarget, alignment: .leading)
        .background(CKColor.surfaceRaised, in: shape)
        .overlay(shape.strokeBorder(CKColor.border, lineWidth: CKMetrics.border(for: contrast)))
        .contentShape(shape)
    }

    // MARK: Actions

    /// Posts the row count (or the offline line, when that is all there is) to VoiceOver, once per
    /// distinct sentence: typing eight letters must not read "6 results" eight times, and the
    /// two-stage answer — campus rows now, MapKit rows a moment later — is worth hearing twice.
    private func announceResults() {
        let line = search.suggestions.isEmpty && search.lastError != nil
            ? search.lastError!
            : DestinationSuggestions.announcement(count: search.suggestions.count)
        guard line != lastAnnouncement else { return }
        lastAnnouncement = line
        AccessibilityNotification.Announcement(line).post()
    }

    /// Go / the keyboard's Go key: hide the keyboard, drop the list, and hand the typed text to
    /// the shared route path. An empty box still sets "Type a destination first" in `AppModel`.
    private func submit() {
        focused = false
        search.clear()
        lastAnnouncement = nil
        model.startMapKitRoute()
        // `navigate(to:)` writes the trimmed text back; that is not a keystroke.
        mirroredText = model.destinationQuery
    }

    /// A tapped suggestion starts guidance immediately (no second tap on Go), through the same
    /// `AppModel` entry points Siri uses: the gazetteer path for a campus place (no search, so
    /// "Grainger" cannot become an industrial supply store), the text path for a MapKit row.
    /// - Parameter s: the row the walker chose.
    private func choose(_ s: DestinationSuggestion) {
        focused = false
        search.clear()
        lastAnnouncement = nil
        if let id = s.placeId, let place = CampusPlaces.place(id: id) {
            model.navigate(to: place)
        } else {
            model.navigate(to: s.searchQuery)
        }
        // `navigate` shows the chosen place in the field; that is not a keystroke.
        mirroredText = model.destinationQuery
    }

    /// The clear (x) button: empties the box and the list but keeps the keyboard up, so the next
    /// destination can be typed straight away.
    private func clearText() {
        model.destinationQuery = ""
        model.clearRouteError()
        search.clear()
        lastAnnouncement = nil
        mirroredText = nil
        focused = true
    }
}

/// Canvas preview of the idle field with a fresh model (no engines started, so no fix and no
/// distances on the campus rows).
#Preview("Destination field") {
    ScrollViewReader { proxy in
        ScrollView {
            CKCard(title: "Guide") { DestinationField(scroller: proxy) }
                .padding(CKSpacing.gutter)
        }
        .background(CKColor.background)
    }
    .environment(AppModel())
}
