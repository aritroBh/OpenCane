//
//  CaneKitApp.swift
//  CaneKit — smart-cane retrofit kit (hackathon starter)
//
//  App entry + ContentView + AppModel (wires DepthEngine → HapticLogic → CaneBLE).
//  iOS 18+, SwiftUI, @Observable throughout.
//
//  STATUS: draft, NOT in any target and never compiled by the current project (ios/project.yml
//  lists no `drafts/` path). The original pre-hackathon starter; kept as history only. Do not
//  edit or "fix" it (ios/drafts/README.md, AGENTS.md Layout) and do not copy code from it without
//  checking the live file — it predates Swift 6 strict concurrency, the MainActor default and
//  the phone-only reset (it drives an ESP32 grip through `CaneBLE`, now ios/stretch/).
//  Live successors: `ios/CaneKit/App/CaneKitApp.swift` (entry), `ios/CaneKit/App/AppModel.swift`
//  (owner of every engine), `ios/CaneKit/UI/ContentView.swift` + `LaneGridView.swift` (screens),
//  `SpeechQueue` (speech). Its warn / urgent distances became `CueDecider` thresholds in
//  CaneKitLogic (with tests). Tests: none.
//

import SwiftUI
import UIKit
import Observation

@main
struct CaneKitApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
    }
}

// MARK: - AppModel

/// Owns the four engines and the user settings. Lives on the main actor;
/// the engines hop to main before touching anything published.
@MainActor
@Observable
final class AppModel {
    let engine = DepthEngine()
    let haptics = HapticLogic()
    let ble = CaneBLE()
    let describer = SceneDescriber()

    var sceneText = ""
    var isDescribing = false
    var lastError: String?
    private(set) var started = false

    // MARK: Settings (persisted in UserDefaults; didSet pushes into the engines)

    private static let defaults = UserDefaults.standard

    /// ON  = warn 1.5 m / urgent 0.8 m  (default, open sidewalks)
    /// OFF = warn 1.0 m / urgent 0.5 m  (crowded spaces, fewer false alarms)
    var extendedRange: Bool = AppModel.defaults.object(forKey: "extendedRange") as? Bool ?? true {
        didSet { Self.defaults.set(extendedRange, forKey: "extendedRange"); applySettings() }
    }
    var hapticsEnabled: Bool = AppModel.defaults.object(forKey: "hapticsEnabled") as? Bool ?? true {
        didSet { Self.defaults.set(hapticsEnabled, forKey: "hapticsEnabled"); applySettings() }
    }
    var speechEnabled: Bool = AppModel.defaults.object(forKey: "speechEnabled") as? Bool ?? true {
        didSet { Self.defaults.set(speechEnabled, forKey: "speechEnabled"); applySettings() }
    }
    /// Phone mounted upright (portrait, camera at top). See README "depth map orientation".
    var portraitMode: Bool = AppModel.defaults.object(forKey: "portraitMode") as? Bool ?? true {
        didSet { Self.defaults.set(portraitMode, forKey: "portraitMode"); applySettings() }
    }
    /// Flip L/R if the phone is mounted facing the other way (e.g. upside-down portrait).
    var mirrorLeftRight: Bool = AppModel.defaults.object(forKey: "mirrorLeftRight") as? Bool ?? false {
        didSet { Self.defaults.set(mirrorLeftRight, forKey: "mirrorLeftRight"); applySettings() }
    }

    var warnDistance: Float { extendedRange ? 1.5 : 1.0 }
    var urgentDistance: Float { extendedRange ? 0.8 : 0.5 }

    init() {
        // DepthEngine delivers reports on the main queue, so this is main-thread safe.
        engine.onReport = { [weak self] report in
            self?.haptics.process(report)
        }
        haptics.sendCommand = { [weak self] command in
            self?.ble.send(command)
        }
        applySettings()
    }

    func applySettings() {
        haptics.warnDistance = warnDistance
        haptics.urgentDistance = urgentDistance
        haptics.hapticsEnabled = hapticsEnabled
        haptics.speechEnabled = speechEnabled
        engine.rotateForPortrait = portraitMode
        engine.mirrorLeftRight = mirrorLeftRight
    }

    func start() {
        guard !started else { return }
        started = true
        UIApplication.shared.isIdleTimerDisabled = true   // keep the screen (and ARKit) alive
        Speech.shared.configureAudioSession()
        engine.start()
        ble.start()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        guard started else { return }
        switch phase {
        case .active:
            engine.resume()
            ble.start()               // re-arms scanning/reconnect if needed
        case .background:
            engine.pause()            // ARKit would pause anyway; do it explicitly
        default:
            break
        }
    }

    // MARK: Actions

    func describeScene() {
        guard !isDescribing else { return }
        isDescribing = true
        lastError = nil
        Speech.shared.say("Describing", interrupt: true)

        Task {
            defer { isDescribing = false }
            let engine = self.engine
            // JPEG encode off the main thread (~30–80 ms on device).
            let jpeg = await Task.detached(priority: .userInitiated) {
                engine.jpegSnapshot()
            }.value
            guard let jpeg else {
                lastError = "No camera frame yet"
                Speech.shared.say("No camera image yet", interrupt: true)
                return
            }
            do {
                let text = try await describer.describe(jpeg: jpeg)
                sceneText = text
                Speech.shared.say(text, interrupt: true)
            } catch {
                lastError = error.localizedDescription
                Speech.shared.say("Scene description failed", interrupt: true)
            }
        }
    }

    func testBuzz(_ motor: Lane) {
        haptics.testBuzz(motor)
    }
}

// MARK: - Formatting helpers

enum LaneFormat {
    /// Anything beyond this is displayed/spoken as "clear".
    static let clearBeyond: Float = 4.5

    static func short(_ meters: Float) -> String {
        guard meters.isFinite, meters < clearBeyond else { return "clear" }
        return String(format: "%.1f m", meters)
    }

    static func spoken(_ meters: Float) -> String {
        guard meters.isFinite, meters < clearBeyond else { return "clear" }
        return String(format: "%.1f meters", meters)
    }
}

// MARK: - ContentView

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    statusHeader
                    LaneGrid(report: model.engine.report, haptics: model.haptics)
                    describeSection
                    buzzSection
                    settingsSection($model)
                    footer
                }
                .padding()
            }
            .navigationTitle("CaneKit")
        }
        .task { model.start() }
        .onChange(of: scenePhase) { _, phase in
            model.handleScenePhase(phase)
        }
    }

    // MARK: Status

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(model.ble.state == .connected ? Color.green : Color.orange)
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
                Text(model.ble.state.rawValue)
                    .font(.title3.weight(.semibold))
                Spacer()
                if model.ble.state != .connected {
                    Button("Reconnect") { model.ble.start() }
                        .buttonStyle(.bordered)
                        .accessibilityHint("Scans for the cane over Bluetooth")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Cane connection: \(model.ble.state.rawValue)")

            HStack(spacing: 16) {
                if let mm = model.ble.caneDistanceMM {
                    Label("Cane \(mm) mm", systemImage: "ruler")
                }
                if let pct = model.ble.batteryPercent {
                    Label("\(pct)%", systemImage: "battery.75percent")
                }
                if let name = model.ble.peripheralName {
                    Text(name).foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)

            HStack(spacing: 12) {
                Label(model.engine.statusMessage, systemImage: "camera.metering.matrix")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if model.engine.report.isSweeping {
                    Text("SWEEPING")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.yellow.opacity(0.4), in: Capsule())
                        .accessibilityLabel("Sweeping, warnings paused")
                }
            }

            if !model.haptics.lastCommand.isEmpty {
                Text("Last cmd: \(model.haptics.lastCommand)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Describe

    private var describeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                model.describeScene()
            } label: {
                Label(model.isDescribing ? "Describing…" : "Describe scene", systemImage: "eye")
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isDescribing)
            .accessibilityHint("Takes a photo and reads out hazards and landmarks ahead")

            if !model.sceneText.isEmpty {
                Text(model.sceneText)
                    .font(.body)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Scene description: \(model.sceneText)")
            }
            if let err = model.lastError {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Error: \(err)")
            }
        }
    }

    // MARK: Test buzz

    private var buzzSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Test buzz").font(.headline)
            HStack(spacing: 10) {
                buzzButton("Left", .left)
                buzzButton("Both", .center)
                buzzButton("Right", .right)
            }
        }
    }

    private func buzzButton(_ title: String, _ motor: Lane) -> some View {
        Button(title) { model.testBuzz(motor) }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, minHeight: 48)
            .disabled(model.ble.state != .connected)
            .accessibilityLabel("Test buzz \(title)")
            .accessibilityHint("Sends a 300 millisecond pulse to the \(title.lowercased()) motor")
    }

    // MARK: Settings

    private func settingsSection(_ model: Bindable<AppModel>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings").font(.headline)
            Toggle(isOn: model.extendedRange) {
                VStack(alignment: .leading) {
                    Text("Extended warn range")
                    Text("Warn \(LaneFormat.short(self.model.warnDistance)) · Urgent \(LaneFormat.short(self.model.urgentDistance))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityHint("On: warn at one and a half meters, urgent at point eight. Off: one meter and half a meter.")
            Toggle("Haptics", isOn: model.hapticsEnabled)
            Toggle("Spoken warnings", isOn: model.speechEnabled)
            Toggle("Phone held upright (portrait)", isOn: model.portraitMode)
                .accessibilityHint("Turn off if the phone is mounted sideways")
            Toggle("Mirror left / right", isOn: model.mirrorLeftRight)
                .accessibilityHint("Turn on if left and right warnings feel swapped")
        }
    }

    private var footer: some View {
        Text("Frames: \(model.engine.framesProcessed)  ·  Gyro: \(String(format: "%.2f", model.engine.report.rotationRate)) rad/s")
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

// MARK: - Lane grid

struct LaneGrid: View {
    let report: LaneReport
    let haptics: HapticLogic

    private let laneNames = ["Left", "Center", "Right"]

    var body: some View {
        VStack(spacing: 12) {
            laneRow(title: "Head", values: report.head)
            laneRow(title: "Torso", values: report.torso)
        }
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func laneRow(title: String, values: [Float]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { i in
                    LaneCell(
                        label: laneNames[i],
                        distance: values[i],
                        severity: haptics.severity(for: values[i]),
                        hasData: report.depthAvailable
                    )
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) row")
        .accessibilityValue(spokenValues(values))
    }

    private func spokenValues(_ values: [Float]) -> String {
        guard report.depthAvailable else { return "no depth data" }
        return zip(laneNames, values)
            .map { "\($0.lowercased()) \(LaneFormat.spoken($1))" }
            .joined(separator: ", ")
    }
}

struct LaneCell: View {
    let label: String
    let distance: Float
    let severity: Severity
    let hasData: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(hasData ? LaneFormat.short(distance) : "—")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(background, in: RoundedRectangle(cornerRadius: 12))
    }

    private var background: Color {
        guard hasData else { return Color.gray.opacity(0.2) }
        switch severity {
        case .clear:  return Color.green.opacity(0.25)
        case .warn:   return Color.yellow.opacity(0.55)
        case .urgent: return Color.red.opacity(0.7)
        }
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
}
