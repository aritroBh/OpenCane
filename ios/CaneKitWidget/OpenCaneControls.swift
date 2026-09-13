//
//  OpenCaneControls.swift
//  CaneKitWidget
//
//  Step 64 extras: the brand when no route runs.
//    · `TalkControl` — a Control Center / Lock Screen / Action button control, "Talk to OpenCane",
//      that opens the app listening (`TalkControlIntent`, ios/Shared/Intents).
//    · `OpenCaneAccessoryWidget` — a lock-screen accessory widget (circular + rectangular) showing
//      the contour-ring mark; tapping opens the app to talk (`opencane://talk`, handled by
//      `CaneKitApp.onOpenURL`).
//
//  Why: the Step 64 audit ruled out an idle "OpenCane ready — guarding" Live Activity (depth and
//  GPS are off in the background, so "guarding" would be false, and Live Activities are for tasks
//  with an end). These carry the brand honestly: they start something, they claim nothing.
//
//  Owner / callers: registered in `CaneKitWidgetBundle`. Module `watch-widget-shared`.
//  Tests: none automated (no XCUITest reaches Control Center / the lock screen); device check in
//  CHANGELOG Step 64.
//

import AppIntents
import SwiftUI
import WidgetKit

/// Control Center / Lock Screen / Action button: "Talk to OpenCane".
struct TalkControl: ControlWidget {
    /// Stable kind string (a rename orphans every placed control).
    static let kind = "com.aritro.canekit.widget.talk"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: TalkControlIntent()) {
                Label("Talk to OpenCane", systemImage: "waveform.circle")
            }
        }
        .displayName("Talk to OpenCane")
        .description("Open OpenCane listening for a question or a destination.")
    }
}

/// One static entry: the widget never changes.
struct OpenCaneAccessoryEntry: TimelineEntry {
    let date: Date
}

/// Timeline with a single entry and no reloads.
struct OpenCaneAccessoryProvider: TimelineProvider {
    func placeholder(in context: Context) -> OpenCaneAccessoryEntry { .init(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (OpenCaneAccessoryEntry) -> Void) {
        completion(.init(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<OpenCaneAccessoryEntry>) -> Void) {
        completion(Timeline(entries: [.init(date: .now)], policy: .never))
    }
}

/// Lock-screen accessory: the mark (circular) or mark + "OpenCane / Tap to talk" (rectangular).
struct OpenCaneAccessoryWidget: Widget {
    static let kind = "com.aritro.canekit.widget.accessory"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: OpenCaneAccessoryProvider()) { _ in
            OpenCaneAccessoryView()
                .containerBackground(for: .widget) { AccessoryWidgetBackground() }
                .widgetURL(OpenCaneLinks.talk)
        }
        .configurationDisplayName("OpenCane")
        .description("The OpenCane mark. Tap to open OpenCane and talk.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

/// The accessory's two layouts.
private struct OpenCaneAccessoryView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryRectangular:
            HStack(spacing: 8) {
                OpenCaneMark().stroke(lineWidth: 1.5).frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("OpenCane").font(.headline).widgetAccentable()
                    Text("Tap to talk").font(.caption)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("OpenCane. Tap to talk.")
        default:
            OpenCaneMark().stroke(lineWidth: 1.6)
                .padding(6)
                .widgetAccentable()
                .accessibilityLabel("OpenCane. Tap to talk.")
        }
    }
}
