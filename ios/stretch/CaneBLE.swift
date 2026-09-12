//
//  CaneBLE.swift
//  CaneKit
//
//  CoreBluetooth central for the cane's Nordic UART Service (NUS).
//    - scans for NUS, connects to the peripheral named "CANE"
//    - writes ASCII commands to RX (withoutResponse when the char supports it)
//    - subscribes to TX notifications, parses lines like "D:<mm>,B:<pct>"
//    - auto-reconnects
//
//  Threading: all CoreBluetooth work happens on `queue`; published properties
//  are written on main.
//
//  STATUS: stretch / history only — NOT in any target (AGENTS.md Layout: "Leave alone"). It was
//  `ios/CaneKit/CaneBLE.swift` until Step 0 (2026-09-10) moved it out when the project went
//  phone-only: no ESP32, no grip motors, no external sensors. Nothing in the shipping app imports
//  or calls it; the phone's own Taptic Engine (`HapticPlayer`) and LiDAR replaced the grip's
//  motors and ToF sensor. Kept so the grip in `firmware/canekit_grip/` can be revived — this is
//  the only client ever written for that firmware, and it speaks its exact protocol
//  (`firmware/README.md` "Protocol"): RX commands `H:<L|R|B>:<1-4>:<ms>`, `P:<n>`, `S:<0|1>`;
//  TX telemetry `D:<mm>,B:<pct>\n` every 100 ms, `-1` = unknown.
//
//  Owner / callers: nobody today. Its original caller was the iOS 18 draft `AppModel`
//  (`ios/drafts/CaneKitApp.swift`, `let ble = CaneBLE()`, fed by `drafts/HapticLogic.swift`).
//  Tests: none; it has never been compiled under the current project settings.
//
//  ⚠ Before putting it back in a target: it predates Swift 6 strict concurrency and the
//  `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` default in `ios/project.yml`. As written it is a
//  non-isolated `@Observable` class whose delegate callbacks run on `queue` while its published
//  state is written through `DispatchQueue.main.async`, and `wantConnection` / `targetName` /
//  `requireName` are written on the caller's thread but read on `queue` (a data race). Rework it
//  into the relay pattern of AGENTS.md hard rule 1 (a `nonisolated` delegate relay that hops to
//  `@MainActor`), and add `NSBluetoothAlwaysUsageDescription` to the app's Info.plist in
//  `ios/project.yml` — creating the central without it terminates the app.
//

import CoreBluetooth
import Foundation
import Observation

/// BLE link to the "CANE" grip: owns one `CBCentralManager`, finds and connects the NUS
/// peripheral, reconnects on its own, writes command lines to RX and publishes the parsed TX
/// telemetry. Create one, call `start()`, observe `state` / `caneDistanceMM` / `batteryPercent`.
@Observable
final class CaneBLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    /// Link state; the raw value is the short human-readable status line the draft UI showed.
    enum ConnectionState: String {
        /// Before the central reports a state, and for `.resetting` / `.unsupported` /
        /// `.unknown` (an unsupported device therefore still reads "Bluetooth starting").
        case unknown      = "Bluetooth starting"
        /// The radio is off in Control Center / Settings.
        case poweredOff   = "Bluetooth off"
        /// The user denied Bluetooth permission.
        case unauthorized = "Bluetooth not allowed"
        /// Scanning for a peripheral advertising the NUS service.
        case scanning     = "Scanning for CANE"
        /// `connect` issued (first time, or re-connecting after a drop).
        case connecting   = "Connecting"
        /// Connected; discovering the NUS service and its RX / TX characteristics.
        case discovering  = "Setting up"
        /// RX characteristic found: commands can be written.
        case connected    = "Connected"
        /// Link dropped, connect failed, or `stop()` was called.
        case disconnected = "Disconnected"
    }

    /// Nordic UART Service UUID (the standard NUS value, also used by the firmware).
    static let nusService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    /// NUS RX characteristic: phone → cane command lines (write / write-without-response).
    static let nusRX      = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")   // phone → cane (write)
    /// NUS TX characteristic: cane → phone telemetry lines (notify).
    static let nusTX      = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")   // cane → phone (notify)

    // Config
    /// Advertised-name prefix to accept, compared case-insensitively ("CANE", the firmware's
    /// `NimBLEDevice::init` name). Read on `queue` during discovery.
    var targetName = "CANE"
    /// If false, connect to the first NUS peripheral regardless of name (handy when the
    /// advertised name isn't in the first scan packet).
    var requireName = true

    // Published (main thread)
    /// Current link state (written on main via `setState`; repeated values are not re-set).
    private(set) var state: ConnectionState = .unknown
    /// Advertised name of the chosen peripheral, or "(unnamed NUS device)" when it had none.
    private(set) var peripheralName: String?
    /// Signal strength in dBm at discovery time only (not refreshed while connected).
    private(set) var rssi: Int?
    /// Last `D:` telemetry value: ToF ground distance in millimetres; -1 when the grip has no
    /// reading (the sentinel is stored as-is, not mapped to nil). nil until the first line.
    private(set) var caneDistanceMM: Int?
    /// Last `B:` telemetry value: grip battery percent; -1 when the board has no battery sense
    /// wired (the firmware default). nil until the first line.
    private(set) var batteryPercent: Int?
    /// The last complete, trimmed telemetry line received (debug).
    private(set) var lastLine = ""
    /// Bytes of commands written (debug, approximate: a write that had to be buffered for
    /// write-without-response flow control counts only the part sent from the buffer later).
    private(set) var bytesSent = 0
    /// Last CoreBluetooth or protocol error text; never cleared once set.
    private(set) var lastError: String?

    // Private (BLE queue)
    /// The central, created lazily by the first `start()` so the permission prompt appears only
    /// once the UI is up. Its delegate callbacks arrive on `queue`.
    @ObservationIgnored private var central: CBCentralManager?
    /// Serial queue for every CoreBluetooth call and callback.
    @ObservationIgnored private let queue = DispatchQueue(label: "canekit.ble")
    /// The chosen peripheral; kept across drops so a pending `connect` resumes it without a rescan.
    @ObservationIgnored private var peripheral: CBPeripheral?
    /// NUS RX characteristic once discovered; nil while disconnected.
    @ObservationIgnored private var rxChar: CBCharacteristic?
    /// NUS TX characteristic once discovered; nil while disconnected.
    @ObservationIgnored private var txChar: CBCharacteristic?
    /// Partial telemetry text awaiting a line terminator; emptied on connect and if it grows past
    /// 512 characters without one.
    @ObservationIgnored private var rxBuffer = ""
    /// True between `start()` and `stop()`: gates scanning and auto-reconnect.
    @ObservationIgnored private var wantConnection = false
    /// Command bytes waiting for write-without-response flow control
    /// (`peripheralIsReady(toSendWriteWithoutResponse:)`); dropped on disconnect.
    @ObservationIgnored private var pendingWrites: [Data] = []

    // MARK: Public API

    /// Idempotent. First call creates the central (triggers the Bluetooth permission prompt).
    /// Later calls just re-arm scanning / reconnecting on `queue`.
    func start() {
        wantConnection = true
        if central == nil {
            // Creating it lazily so the permission dialog appears once the UI is up.
            central = CBCentralManager(delegate: self, queue: queue)
        } else {
            queue.async { [weak self] in self?.scanIfNeeded() }
        }
    }

    /// Stops scanning, cancels the connection, forgets the peripheral and publishes
    /// `.disconnected`. Auto-reconnect stays off until the next `start()`.
    func stop() {
        wantConnection = false
        queue.async { [weak self] in
            guard let self, let central = self.central else { return }
            central.stopScan()
            if let p = self.peripheral { central.cancelPeripheralConnection(p) }
            self.peripheral = nil
            self.setState(.disconnected)
        }
    }

    /// Send one command line, e.g. "H:B:4:250\n". Safe from any thread.
    /// The caller supplies the terminator (the firmware also parses an unterminated write after
    /// 150 ms). Silently dropped when not connected — commands are not queued across a drop.
    func send(_ command: String) {
        guard let data = command.data(using: .utf8) else { return }
        queue.async { [weak self] in self?.write(data) }
    }

    // MARK: Scanning / connecting (BLE queue)

    /// Radio on and a connection wanted: re-connects a known peripheral that is disconnected,
    /// otherwise starts a NUS-filtered scan (duplicates off) unless one is already running.
    private func scanIfNeeded() {
        guard let central, central.state == .poweredOn, wantConnection else { return }
        if let p = peripheral {
            // We already know the device; make sure a connect is pending.
            if p.state == .disconnected {
                setState(.connecting)
                central.connect(p, options: nil)
            }
            return
        }
        guard !central.isScanning else { return }
        setState(.scanning)
        central.scanForPeripherals(
            withServices: [Self.nusService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    /// Radio state changed: powered on → scan / reconnect; otherwise publish why not.
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            scanIfNeeded()
        case .poweredOff:
            setState(.poweredOff)
        case .unauthorized:
            setState(.unauthorized)
        default:
            setState(.unknown)
        }
    }

    /// Scan result: takes the first NUS peripheral whose advertised (or cached) name starts with
    /// `targetName` — or any, when `requireName` is false — stops scanning and connects.
    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? ""
        if requireName && !name.uppercased().hasPrefix(targetName.uppercased()) {
            return
        }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        let rssiValue = RSSI.intValue
        DispatchQueue.main.async { [weak self] in
            self?.peripheralName = name.isEmpty ? "(unnamed NUS device)" : name
            self?.rssi = rssiValue
        }
        setState(.connecting)
        central.connect(peripheral, options: nil)
    }

    /// Connected: clear any stale partial line and discover the NUS service.
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        setState(.discovering)
        rxBuffer = ""
        peripheral.discoverServices([Self.nusService])
    }

    /// Connect failed: forget the peripheral and rescan after 1 s.
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        report(error)
        self.peripheral = nil
        rxChar = nil; txChar = nil
        setState(.disconnected)
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.scanIfNeeded() }
    }

    /// Link dropped: drop characteristics and buffered writes; if a connection is still wanted,
    /// issue a direct re-connect to the same peripheral (see the inline note), else forget it.
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        report(error)
        rxChar = nil; txChar = nil
        pendingWrites.removeAll()
        setState(.disconnected)
        guard wantConnection else { self.peripheral = nil; return }
        // Reconnect directly: a pending connect() never times out and completes as soon
        // as the cane is back in range. No need to rescan.
        setState(.connecting)
        central.connect(peripheral, options: nil)
    }

    // MARK: CBPeripheralDelegate (BLE queue)

    /// Services discovered: find NUS and discover RX / TX; a peripheral without NUS is an error
    /// and the connection is cancelled — which runs the disconnect path, and while a connection
    /// is wanted that re-connects to the same peripheral, so a non-NUS match can loop.
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { report(error); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.nusService }) else {
            report(NSError(domain: "CaneBLE", code: 1, userInfo: [NSLocalizedDescriptionKey: "NUS service not found"]))
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.nusRX, Self.nusTX], for: service)
    }

    /// Characteristics discovered: subscribe to TX, and declare `.connected` (flushing any
    /// buffered writes) once RX exists. A missing TX only means no telemetry; a missing RX is
    /// reported and the state stays `.discovering`.
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { report(error); return }
        for c in service.characteristics ?? [] {
            if c.uuid == Self.nusRX { rxChar = c }
            if c.uuid == Self.nusTX { txChar = c }
        }
        if let txChar {
            peripheral.setNotifyValue(true, for: txChar)
        }
        if rxChar != nil {
            setState(.connected)
            flushPending()
        } else {
            report(NSError(domain: "CaneBLE", code: 2, userInfo: [NSLocalizedDescriptionKey: "NUS RX characteristic missing"]))
        }
    }

    /// TX subscription result; only an error is recorded.
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { report(error) }
    }

    /// TX notification: append to `rxBuffer`, parse every complete line (`\n` or `\r`; the empty
    /// line a `\r\n` pair leaves is skipped), keep the partial tail.
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { report(error); return }
        guard characteristic.uuid == Self.nusTX, let data = characteristic.value else { return }
        rxBuffer += String(decoding: data, as: UTF8.self)
        // Consume complete lines; keep any partial tail.
        while let nl = rxBuffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rxBuffer[..<nl]).trimmingCharacters(in: .whitespacesAndNewlines)
            rxBuffer.removeSubrange(...nl)
            if !line.isEmpty { parse(line: line) }
        }
        if rxBuffer.count > 512 { rxBuffer = "" }     // garbage guard
    }

    /// Result of a with-response write; only an error is recorded.
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { report(error) }
    }

    /// Write-without-response flow control opened again: send what `write` buffered.
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        flushPending()
    }

    // MARK: Writing (BLE queue)

    /// Writes `data` to RX in chunks of the peripheral's maximum write length (at least 20
    /// bytes), without response when RX supports it. If write-without-response flow control
    /// closes mid-way, the unsent remainder goes to `pendingWrites`. No-op unless connected.
    private func write(_ data: Data) {
        guard let p = peripheral, let rx = rxChar, p.state == .connected else { return }
        let type: CBCharacteristicWriteType = rx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let mtu = max(20, p.maximumWriteValueLength(for: type))

        var offset = 0
        while offset < data.count {
            if type == .withoutResponse && !p.canSendWriteWithoutResponse {
                // Buffer the rest; peripheralIsReady(toSendWriteWithoutResponse:) will flush.
                pendingWrites.append(data.subdata(in: offset..<data.count))
                return
            }
            let end = min(offset + mtu, data.count)
            p.writeValue(data.subdata(in: offset..<end), for: rx, type: type)
            offset = end
        }
        let n = data.count
        DispatchQueue.main.async { [weak self] in self?.bytesSent += n }
    }

    /// Re-sends every buffered chunk in order; a chunk that hits closed flow control again is
    /// re-buffered by `write`.
    private func flushPending() {
        guard !pendingWrites.isEmpty else { return }
        let queued = pendingWrites
        pendingWrites.removeAll()
        for d in queued { write(d) }
    }

    // MARK: Parsing

    /// Telemetry line from the cane: "D:<mm>,B:<pct>" (order-insensitive, unknown keys ignored).
    /// A field whose value is not an integer is skipped; keys are case-insensitive. Publishes on
    /// main: `lastLine` always, `caneDistanceMM` / `batteryPercent` only for keys present.
    private func parse(line: String) {
        var distance: Int?
        var battery: Int?
        for field in line.split(separator: ",") {
            let kv = field.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, let value = Int(kv[1]) else { continue }
            switch kv[0].uppercased() {
            case "D": distance = value
            case "B": battery = value
            default: break
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastLine = line
            if let distance { self.caneDistanceMM = distance }
            if let battery { self.batteryPercent = battery }
        }
    }

    // MARK: Helpers

    /// Publishes a state change on main, skipping a repeat of the current value (avoids
    /// needless observation updates).
    private func setState(_ s: ConnectionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state != s else { return }
            self.state = s
        }
    }

    /// Publishes a non-nil error's description to `lastError` on main; nil is ignored.
    private func report(_ error: Error?) {
        guard let error else { return }
        let msg = error.localizedDescription
        DispatchQueue.main.async { [weak self] in self?.lastError = msg }
    }
}
