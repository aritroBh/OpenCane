//
//  AppIntents.swift
//  CaneKit
//
//  Voice control for a walker who cannot see the screen: Siri phrases (and the Action button /
//  Shortcuts) for everything the Guide card's buttons do. "Hey Siri, take me to Grainger in
//  OpenCane", "Next waypoint in OpenCane", "Stop the route in OpenCane".
//
//  Purpose: seven App Intents — Where am I / Start route to CIF / Navigate to CIF from here /
//  Take me to <place> / Repeat / Next waypoint / Stop route — plus the `AppShortcutsProvider`
//  they share with the hands-free intents (`HandsFreeIntents.swift`). Each intent only forwards
//  to a public `AppModel` method, so Siri, the Action button, the watch and the on-screen
//  buttons share one code path.
//
//  Owner: module `app-core` (docs/CODE_REFERENCE.md). The system instantiates the intents; they
//  reach the live model through `AppModel.shared` (intents run inside the app process).
//
//  Threading / isolation: `perform()` is `@MainActor` (AppModel is main-actor). The intent structs
//  themselves are value types with only static metadata and parameters.
//
//  Key invariants:
//    · ⚠ `supportedModes` must stay `.foreground(.immediate)` on every intent — ARKit (obstacle
//      warnings, "Where am I") only runs while the app is frontmost, and guidance without the
//      obstacle channel must never start silently in the background.
//    · Every shortcut phrase must contain `\(.applicationName)` (App Shortcuts requirement), and
//      an app may register at most 10 App Shortcuts. All ten are registered in this file's
//      `CaneKitShortcuts`: six use intents defined here, four use the hands-free intents defined in
//      `HandsFreeIntents.swift` (Talk to OpenCane, Status, Ask, Cane haptics).
//    · ⚠ `\(.applicationName)` is resolved by the system from the bundle's **display name**
//      (`CFBundleDisplayName`, set in `ios/project.yml` → OpenCane), never from the target or
//      module name. That is why the phrases below need no edit when the product is renamed:
//      the spoken word follows the home-screen name automatically. The *code* is still called
//      CaneKit on purpose (AGENTS.md → "The name split"), so do not "fix" the mismatch here.
//      What the walker must actually say today: "… in OpenCane".
//    · Phrases can only interpolate AppEnum / AppEntity parameters, never a String: "Take me to
//      Grainger" uses the `CampusDestination` enum; any other place goes through "Take me
//      somewhere in OpenCane", where Siri asks "Where do you want to go?" for the String.
//    · ⚠ `CampusDestination` raw values are `CampusPlaces` ids (CaneKitLogic,
//      `campusPlaceIdsArePinned`): add a gazetteer place in both, same id.
//
//  Tests: no automated test runs an intent (Siri and the Action button cannot be driven from
//  XCUITest). What is pinned: the gazetteer ids behind `CampusDestination`
//  (`CampusPlacesTests.campusPlaceIdsArePinned`) and the model methods the intents forward to,
//  through the on-screen buttons that share them (`ios/CaneKitUITests/CaneKitUITests.swift`).
//  After editing phrases, verify on the phone (Shortcuts app re-index; say the phrase).
//

import AppIntents
import CaneKitLogic
import Foundation

/// Action button / Siri "Where am I": one-sentence scene description via `AppModel.describeScene()`.
struct WhereAmIIntent: AppIntent {
    /// Shown in Shortcuts and the Action button picker.
    static let title: LocalizedStringResource = "Where am I"
    /// Subtitle in Shortcuts.
    static let description = IntentDescription("Describes the scene ahead in one sentence.")
    /// ⚠ Foreground only: ARKit (and therefore the describer) needs the app frontmost.
    static let supportedModes: IntentModes = .foreground(.immediate)

    /// Waits for the model (cold launch) and triggers a scene description.
    /// Throws `IntentSupport.NotReady` if the model never appears within 2 s.
    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentSupport.model()
        model.describeScene()
        return .result()
    }
}

/// Siri / Shortcuts "Start route to CIF" (the legacy "Start the demo route" phrase is still
/// accepted): starts the bundled ISR Townsend Hall → CIF route.
struct StartDemoRouteIntent: AppIntent {
    /// Shown in Shortcuts.
    static let title: LocalizedStringResource = "Start OpenCane route"
    /// Subtitle in Shortcuts.
    static let description = IntentDescription("Starts the recorded ISR Townsend Hall to CIF route.")
    /// Foreground: guidance needs ARKit, the audio session and the screen kept awake.
    static let supportedModes: IntentModes = .foreground(.immediate)

    /// Waits for the model and calls `AppModel.startDemoRoute()`.
    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentSupport.model()
        model.startDemoRoute()
        return .result()
    }
}

/// Siri "Navigate to CIF from here": Apple Maps walking directions from the live GPS fix to the
/// CIF east entrance (`AppModel.navigateToCIFFromHere()`), for when the walker is not at ISR.
///
/// ⚠ Plain `AppIntent`, not an App Shortcut: the ten shortcut slots are full and the Action
/// button needed "Talk to OpenCane" more (see `CaneKitShortcuts`). Still in the Shortcuts app
/// as an action (a one-step shortcut around it goes on the Action button), and the Guide card
/// button is unchanged. The Siri phrase for the same destination is now "Take me to CIF in
/// OpenCane" (`TakeMeToIntent` + the gazetteer, whose CIF entry is this same route-file
/// waypoint) — say that instead.
struct NavigateToCIFIntent: AppIntent {
    /// Shown in Shortcuts.
    static let title: LocalizedStringResource = "Navigate to CIF from here"
    /// Subtitle in Shortcuts.
    static let description = IntentDescription("Walking directions from where you are to the CIF east entrance.")
    /// Foreground, like every intent here (ARKit obstacle warnings need the app frontmost).
    static let supportedModes: IntentModes = .foreground(.immediate)

    /// Waits for the model and calls `AppModel.navigateToCIFFromHere()` (speaks its own progress).
    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentSupport.model()
        model.navigateToCIFFromHere()
        return .result()
    }
}

/// The campus places Siri can hear inside a phrase ("Take me to Grainger in OpenCane").
/// ⚠ Raw values are `CampusPlaces` ids (CaneKitLogic, pinned by `campusPlaceIdsArePinned`);
/// `CampusPlaces.place(id:)` turns a case into the entrance coordinate.
enum CampusDestination: String, AppEnum {
    // One case per gazetteer place (raw value = `CampusPlace.id`): `cif` the Campus Instructional
    // Facility east entrance (the bundled route's last waypoint), `isr` Townsend Hall / ISR (the
    // route's start), `grainger` Grainger Engineering Library, `illiniUnion` the Illini Union,
    // `siebel` Siebel Center, `mainLibrary` the Main Library, `arc` the Activities and Recreation
    // Center. Entrances other than CIF / ISR are OSM entrance nodes, not yet walked (AGENTS.md).
    case cif, isr, grainger, illiniUnion, siebel, mainLibrary, arc

    /// Parameter type name in Shortcuts.
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Campus place"
    /// What Siri matches: the title and the synonyms (the common spoken names; the gazetteer
    /// aliases cover the typed field).
    static let caseDisplayRepresentations: [CampusDestination: DisplayRepresentation] = [
        .cif: DisplayRepresentation(title: "CIF", synonyms: ["Campus Instructional Facility", "the CIF"]),
        .isr: DisplayRepresentation(title: "ISR", synonyms: ["Townsend Hall", "Townsend", "Illinois Street Residence Halls"]),
        .grainger: DisplayRepresentation(title: "Grainger", synonyms: ["Grainger Library", "Grainger Engineering Library"]),
        .illiniUnion: DisplayRepresentation(title: "the Illini Union", synonyms: ["Illini Union", "the Union"]),
        .siebel: DisplayRepresentation(title: "Siebel", synonyms: ["Siebel Center", "the Siebel Center"]),
        .mainLibrary: DisplayRepresentation(title: "the Main Library", synonyms: ["Main Library", "Main Stacks"]),
        .arc: DisplayRepresentation(title: "the ARC", synonyms: ["ARC", "Activities and Recreation Center"]),
    ]
}

/// Siri "Take me to <place>": a walking route from here. A campus place said in the phrase
/// ("Take me to Grainger in OpenCane") goes straight to its gazetteer entrance; anything else
/// ("Take me somewhere in OpenCane" → Siri asks "Where do you want to go?") is free text for
/// `AppModel.navigate(to:)` — the gazetteer, then the nearest reasonable Apple Maps result.
/// Either way the app says "Walking to <place>, N meters." before guidance starts.
struct TakeMeToIntent: AppIntent {
    /// Shown in Shortcuts.
    static let title: LocalizedStringResource = "Take me to a place"
    /// Subtitle in Shortcuts.
    static let description = IntentDescription("Walking directions from where you are to a campus building or any place nearby.")
    /// Foreground, like every intent here (ARKit obstacle warnings need the app frontmost).
    static let supportedModes: IntentModes = .foreground(.immediate)

    /// Free-text destination ("Starbucks on Green Street"); Siri asks for it when neither
    /// parameter was given.
    @Parameter(title: "Place", requestValueDialog: "Where do you want to go?")
    var place: String?

    /// A campus place named in the phrase itself; wins over `place`.
    @Parameter(title: "Campus place")
    var campusPlace: CampusDestination?

    /// Waits for the model, then `navigate(to: CampusPlace)` for a campus place, else
    /// `navigate(to: String)` for the free text. Neither → `needsValueError`, so Siri asks
    /// "Where do you want to go?" and runs the intent again with the answer.
    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentSupport.model()
        if let campusPlace, let known = CampusPlaces.place(id: campusPlace.rawValue) {
            model.navigate(to: known)
            return .result()
        }
        let text = (place ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw $place.needsValueError("Where do you want to go?") }
        model.navigate(to: text)
        return .result()
    }
}

/// Siri / Shortcuts "Repeat": says the last route line again (same path as the watch Repeat).
struct RepeatInstructionIntent: AppIntent {
    /// Shown in Shortcuts.
    static let title: LocalizedStringResource = "Repeat instruction"
    /// Subtitle in Shortcuts.
    static let description = IntentDescription("Says the current route instruction again.")
    /// Foreground, like the other intents, so it lands in the running guidance session.
    static let supportedModes: IntentModes = .foreground(.immediate)

    /// Waits for the model and calls `AppModel.repeatInstruction()`.
    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentSupport.model()
        model.repeatInstruction()
        return .result()
    }
}

/// Siri "Next waypoint": skips to the next instruction (same path as the watch Next / crown).
struct NextWaypointIntent: AppIntent {
    /// Shown in Shortcuts.
    static let title: LocalizedStringResource = "Next waypoint"
    /// Subtitle in Shortcuts.
    static let description = IntentDescription("Skips to the next route instruction.")
    /// Foreground, like the other intents, so it lands in the running guidance session.
    static let supportedModes: IntentModes = .foreground(.immediate)

    /// Waits for the model and calls `AppModel.nextWaypoint()` ("No route running." when idle).
    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentSupport.model()
        model.nextWaypoint()
        return .result()
    }
}

/// Siri "Stop the route": ends guidance, or abandons a route still being searched for (the
/// escape hatch after "Walking to <wrong place>…").
struct StopRouteIntent: AppIntent {
    /// Shown in Shortcuts.
    static let title: LocalizedStringResource = "Stop route"
    /// Subtitle in Shortcuts.
    static let description = IntentDescription("Stops guidance and any route search in progress.")
    /// Foreground, like the other intents, so it lands in the running guidance session.
    static let supportedModes: IntentModes = .foreground(.immediate)

    /// Waits for the model and calls `AppModel.stopRoute()` (says "Route stopped.").
    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentSupport.model()
        model.stopRoute()
        return .result()
    }
}

/// Shared helpers for the intents above (and the hands-free intents in `HandsFreeIntents.swift`).
/// Main actor by the target default; `model()` is explicitly `@MainActor`.
enum IntentSupport {
    /// Thrown when the SwiftUI scene has not created `AppModel` within the wait window; Siri
    /// speaks the localized message instead of silently doing nothing.
    struct NotReady: Error, CustomLocalizedStringResourceConvertible {
        /// Spoken / shown by the system when the intent fails.
        var localizedStringResource: LocalizedStringResource { "OpenCane is still starting. Try again." }
    }

    /// The app model, once it is actually ready to act on.
    ///
    /// On a cold launch from the lock screen the SwiftUI scene may not have created the model
    /// yet, so this polls 20 × 100 ms (2 s total). It waits for `started`, not merely for the
    /// object to exist: `AppModel.shared` is assigned at the end of `init()`, but every engine is
    /// wired in `start()`, which the root view's `.task` calls. A Siri phrase that won the race
    /// against that `.task` would act on a model with no `depth.onReport` (no obstacle warnings),
    /// no `nav.onSpeak` (the route's first instruction spoken to nobody), no audio session, and
    /// an `announceChannels()` that reports AirPods and haptics as missing because their monitors
    /// have not run — a walker told the wrong things about which safety channels are live.
    ///
    /// If the wait runs out with a model that exists but never started, it is started here rather
    /// than refused: `start()` is idempotent (`guard !started`), so the later `.task` is a no-op,
    /// and failing open keeps every voice phrase working in the one case where failing closed
    /// would make all seven of them answer "OpenCane is still starting."
    @MainActor
    static func model() async throws -> AppModel {
        for _ in 0..<20 {
            if let m = AppModel.shared, m.started { return m }
            try await Task.sleep(for: .milliseconds(100))
        }
        if let m = AppModel.shared {
            m.start()
            return m
        }
        throw NotReady()
    }
}

/// Registered at install; phrases must include the app name. **All ten** App Shortcuts an app may
/// have: the six route shortcuts defined above, plus four hands-free ones whose intents live in
/// `HandsFreeIntents.swift` — the fourth, "Talk to OpenCane", is the Action button target.
/// `shortTitle` / `systemImageName` are what the Action button and Spotlight show. Phrases are
/// short and start with the verb a walker would say; no two shortcuts share one.
///
/// ⚠ This list is **full**. Anything new must either be a plain `AppIntent` — still listed as an
/// action in the Shortcuts app, and assignable to the Action button by building a one-step shortcut
/// around it — or replace one of these ten. `RecenterIntent`, `SetOptionIntent` and (since the
/// Talk-to-OpenCane swap) `NavigateToCIFIntent` are the worked examples of the first choice: the
/// Guide card button for the last one is unchanged, and "Take me to CIF in OpenCane" reaches the
/// same route-file waypoint by Siri.
struct CaneKitShortcuts: AppShortcutsProvider {
    /// The ten shortcuts, in display order.
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: WhereAmIIntent(),
                    phrases: ["Where am I in \(.applicationName)", "\(.applicationName) describe the scene"],
                    shortTitle: "Where am I",
                    systemImageName: "eye")
        AppShortcut(intent: TakeMeToIntent(),
                    phrases: ["Take me to \(\.$campusPlace) in \(.applicationName)",
                              "Take me to \(\.$campusPlace) with \(.applicationName)",
                              "\(.applicationName) take me to \(\.$campusPlace)",
                              "Take me somewhere in \(.applicationName)",
                              "Take me somewhere with \(.applicationName)"],
                    shortTitle: "Take me to…",
                    systemImageName: "mappin.and.ellipse")
        AppShortcut(intent: TalkToOpenCaneIntent(),
                    phrases: ["Talk to \(.applicationName)",
                              "Speak to \(.applicationName)",
                              "\(.applicationName) start listening"],
                    shortTitle: "Talk to OpenCane",
                    systemImageName: "mic")
        AppShortcut(intent: StartDemoRouteIntent(),
                    phrases: ["Start my route in \(.applicationName)",
                              "Start the demo route in \(.applicationName)",
                              "Start route to CIF in \(.applicationName)"],
                    shortTitle: "Start route",
                    systemImageName: "figure.walk")
        AppShortcut(intent: RepeatInstructionIntent(),
                    phrases: ["Repeat in \(.applicationName)", "\(.applicationName) say that again",
                              "Repeat the last instruction in \(.applicationName)"],
                    shortTitle: "Repeat",
                    systemImageName: "arrow.counterclockwise")
        AppShortcut(intent: NextWaypointIntent(),
                    phrases: ["Next waypoint in \(.applicationName)", "\(.applicationName) next waypoint",
                              "Skip to the next waypoint in \(.applicationName)"],
                    shortTitle: "Next waypoint",
                    systemImageName: "forward.fill")
        AppShortcut(intent: StopRouteIntent(),
                    phrases: ["Stop the route in \(.applicationName)", "\(.applicationName) stop the route",
                              "Stop navigating in \(.applicationName)"],
                    shortTitle: "Stop route",
                    systemImageName: "stop.fill")
        // The other three hands-free shortcuts (HandsFreeIntents.swift), which take this list
        // to the limit of ten. Why these four and not Recenter, the hazard switches or (now) the
        // CIF-from-here route shortcut: see that file's header.
        AppShortcut(intent: StatusIntent(),
                    phrases: ["How is \(.applicationName) doing",
                              "\(.applicationName) status",
                              "Is \(.applicationName) working",
                              "Check \(.applicationName)"],
                    shortTitle: "Status check",
                    systemImageName: "checkmark.seal")
        AppShortcut(intent: AskSceneIntent(),
                    phrases: ["Ask \(.applicationName) about the scene",
                              "Ask \(.applicationName) a question",
                              "\(.applicationName) answer a question"],
                    shortTitle: "Ask a question",
                    systemImageName: "questionmark.bubble")
        AppShortcut(intent: SilenceHapticsIntent(),
                    phrases: ["Silence the cane in \(.applicationName)",
                              "Silence haptics in \(.applicationName)",
                              "Turn cane haptics \(\.$state) in \(.applicationName)",
                              "\(.applicationName) turn cane haptics \(\.$state)"],
                    shortTitle: "Cane haptics",
                    systemImageName: "hand.raised")
    }
}
