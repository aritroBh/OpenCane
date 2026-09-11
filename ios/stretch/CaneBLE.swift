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

import CoreBluetooth
import Foundation
import Observation

@Observable
final class CaneBLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    enum ConnectionState: String {
        case unknown      = "Bluetooth starting"
        case poweredOff   = "Bluetooth off"
        case unauthorized = "Bluetooth not allowed"
        case scanning     = "Scanning for CANE"
        case connecting   = "Connecting"
        case discovering  = "Setting up"
        case connected    = "Connected"
        case disconnected = "Disconnected"
    }

    static let nusService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let nusRX      = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")   // phone → cane (write)
    static let nusTX      = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")   // cane → phone (notify)

    // Config
    var targetName = "CANE"
    /// If false, connect to the first NUS peripheral regardless of name (handy when the
    /// advertised name isn't in the first scan packet).
    var requireName = true

    // Published (main thread)
    private(set) var state: ConnectionState = .unknown
    private(set) var peripheralName: String?
    private(set) var rssi: Int?
    private(set) var caneDistanceMM: Int?
    private(set) var batteryPercent: Int?
    private(set) var lastLine = ""
    private(set) var bytesSent = 0
    private(set) var lastError: String?

    // Private (BLE queue)
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private let queue = DispatchQueue(label: "canekit.ble")
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var rxChar: CBCharacteristic?
    @ObservationIgnored private var txChar: CBCharacteristic?
    @ObservationIgnored private var rxBuffer = ""
    @ObservationIgnored private var wantConnection = false
    @ObservationIgnored private var pendingWrites: [Data] = []

    // MARK: Public API

    /// Idempotent. First call creates the central (triggers the Bluetooth permission prompt).
    func start() {
        wantConnection = true
        if central == nil {
            // Creating it lazily so the permission dialog appears once the UI is up.
            central = CBCentralManager(delegate: self, queue: queue)
        } else {
            queue.async { [weak self] in self?.scanIfNeeded() }
        }
    }

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
    func send(_ command: String) {
        guard let data = command.data(using: .utf8) else { return }
        queue.async { [weak self] in self?.write(data) }
    }

    // MARK: Scanning / connecting (BLE queue)

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

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        setState(.discovering)
        rxBuffer = ""
        peripheral.discoverServices([Self.nusService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        report(error)
        self.peripheral = nil
        rxChar = nil; txChar = nil
        setState(.disconnected)
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.scanIfNeeded() }
    }

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

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { report(error); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.nusService }) else {
            report(NSError(domain: "CaneBLE", code: 1, userInfo: [NSLocalizedDescriptionKey: "NUS service not found"]))
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.nusRX, Self.nusTX], for: service)
    }

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

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { report(error) }
    }

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

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { report(error) }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        flushPending()
    }

    // MARK: Writing (BLE queue)

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

    private func flushPending() {
        guard !pendingWrites.isEmpty else { return }
        let queued = pendingWrites
        pendingWrites.removeAll()
        for d in queued { write(d) }
    }

    // MARK: Parsing

    /// Telemetry line from the cane: "D:<mm>,B:<pct>" (order-insensitive, unknown keys ignored).
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

    private func setState(_ s: ConnectionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state != s else { return }
            self.state = s
        }
    }

    private func report(_ error: Error?) {
        guard let error else { return }
        let msg = error.localizedDescription
        DispatchQueue.main.async { [weak self] in self?.lastError = msg }
    }
}
