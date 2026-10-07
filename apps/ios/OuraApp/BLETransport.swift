import CoreBluetooth
import Foundation

// Native CoreBluetooth implementation of the ring link — the iOS counterpart to
// `oura-link::ble` (btleplug), conforming to the same shape as the Rust
// `Transport` trait: write a request frame, and receive the merged stream of
// inbound notification frames. The auth handshake + sync drain stay in Rust
// (oura-link `OuraClient`); this just moves bytes.
//
// Wiring: oura-core exposes `Transport` as a UniFFI callback interface and a
// `sync(transport, db_path)` entry; `RingTransport` below is what we hand across
// the FFI. (BLE needs a real ring + the simulator has no Bluetooth, so this runs
// on device only.) Requires `NSBluetoothAlwaysUsageDescription` in Info.plist.

enum RingUUID {
    static let service = CBUUID(string: "98ED0001-A541-11E4-B6A0-0002A5D5C51B")
    static let chargingCaseService = CBUUID(string: "8BC5888F-C577-4F5D-857F-377354093F13")
    static let write = CBUUID(string: "98ED0002-A541-11E4-B6A0-0002A5D5C51B")
    // notify/indicate chars: gen-4 uses …0003; Ring 5 adds …0004/0005/0006.
    static let notify: Set<String> = [
        "98ED0003-A541-11E4-B6A0-0002A5D5C51B",
        "98ED0004-A541-11E4-B6A0-0002A5D5C51B",
        "98ED0005-A541-11E4-B6A0-0002A5D5C51B",
        "98ED0006-A541-11E4-B6A0-0002A5D5C51B",
    ]
}

/// The contract Rust drives over FFI: write a frame; observe inbound frames.
protocol RingTransport: AnyObject {
    func write(_ data: Data) async throws
    /// Every notify/indicate characteristic merged into one stream of raw frames.
    var notifications: AsyncStream<Data> { get }
}

enum BLEError: Error, CustomStringConvertible {
    case poweredOff, notFound, noWriteCharacteristic, disconnected, busy
    case ringNotAdvertising(otherDevices: Int)
    /// carries the stage the attempt was in, so "timed out" says *what* never happened
    /// (no advertisement seen vs GATT connect stalled vs subscriptions pending).
    case timedOut(stage: String)

    var description: String {
        switch self {
        case .ringNotAdvertising(let count): return "no ring advertisement found (\(count) other Bluetooth devices detected)"
        case .poweredOff: return "Bluetooth is off or not authorized"
        case .notFound: return "ring service/characteristics not found"
        case .noWriteCharacteristic: return "no write characteristic (98ED0002)"
        case .disconnected: return "ring disconnected"
        case .busy: return "another BLE operation is in flight"
        case .timedOut(let stage): return "timed out while \(stage)"
        }
    }
}

/// Scans for an Oura ring advertising the service (filtered by case-insensitive
/// name), connects, discovers the write + notify characteristics, and bridges them
/// to `RingTransport`. Mirrors `oura-link::ble::Connection`.
// @unchecked Sendable: continuations are taken/resumed under `lock`, and the rest of
// the mutable CB state is only touched on the central manager's callback queue.
final class BLETransport: NSObject, RingTransport, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    private let bleQueue = DispatchQueue(label: "md.thomas.openoura.ble", qos: .userInitiated)
    private var closed = false
    private var writeTimeout: DispatchWorkItem?
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var _connectedPeripheralID: UUID?
    var connectedPeripheralID: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return _connectedPeripheralID
    }
    private var writeChar: CBCharacteristic?
    private let nameContains: String
    private let preferredPeripheralID: UUID?
    private let excludedPeripheralIDs: Set<UUID>
    private var scanStartedAt: Date?


    private var notifyContinuation: AsyncStream<Data>.Continuation?
    // recreated per connect() so a reconnect gets a fresh, live stream — the previous
    // one is finished on disconnect, and a single lazy stream would stay terminated,
    // silently dropping all frames after the first link loss.
    private(set) var notifications: AsyncStream<Data> = AsyncStream { _ in }

    // Ring 5 history arrives as thousands of tiny CoreBluetooth notifications. Passing
    // every one through AsyncStream + UniFFI separately (and hex-logging it) costs more
    // than parsing it. Coalesce only history payload packets; command replies and the
    // terminal batch summary remain immediate. Rust's Packet::parse_many already
    // accepts concatenated packets, so this does not change protocol semantics.
    private var historyBuffer = Data()
    private var historyFrames = 0
    private var historyBytes = 0
    private static let historyFlushBytes = 32 * 1024

    private var connectCont: CheckedContinuation<Void, Error>?
    private var writeCont: CheckedContinuation<Void, Error>?
    private var connectTimeout: DispatchWorkItem?
    private var pendingNotify = 0 // notify subscriptions still awaiting confirmation
    private var poweredOn = false
    // where the in-flight connect currently is, for the timeout error message.
    private var stage = "waiting for Bluetooth to power on"
    // advertisement reports already logged (id|name) — allow-duplicates re-reports the
    // same ring many times a second; log each device once, and again when its name
    // first arrives via scan response. Only touched on the (serial) CB queue.
    private var loggedAds = Set<String>()
    // distinct non-ring devices seen this scan: proves the radio works when the ring
    // itself never shows up (written on the CB queue, read under `lock` at timeout).
    private var otherDevices = Set<UUID>()
    // delegate callbacks land on a concurrent queue; this serialises take-and-resume
    // of the continuations so a success and a timeout can't both resume one (a crash).
    private let lock = NSLock()

    init(nameContains: String = "Oura",
         preferredPeripheralID: UUID? = nil,
         excludedPeripheralIDs: Set<UUID> = []) {
        self.nameContains = nameContains
        self.preferredPeripheralID = preferredPeripheralID
        self.excludedPeripheralIDs = excludedPeripheralIDs
        super.init()
        // CoreBluetooth requires a SERIAL queue for delegate callbacks; a concurrent
        // global queue can deliver them out of order (e.g. a notify confirmation
        // racing service discovery).
        central = CBCentralManager(
            delegate: self,
            queue: bleQueue)
    }

    /// Scan → connect → discover. Resolves once the write characteristic is ready
    /// and notifications are subscribed.
    ///
    /// The default budget mirrors the desktop client, which allows 25 s of scanning
    /// plus 30 s for connect + discovery: a worn ring advertises in low-power mode
    /// only intermittently, so 20 s of scan alone was routinely not enough.
    func connect(timeout: TimeInterval = 50) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                bleQueue.async { [self] in
                    guard !closed else { c.resume(throwing: BLEError.disconnected); return }
                    guard connectCont == nil, writeChar == nil else { c.resume(throwing: BLEError.busy); return }
                    connectCont = c
                    stage = "initializing Bluetooth"
                    notifications = AsyncStream(bufferingPolicy: .bufferingOldest(256)) { self.notifyContinuation = $0 }
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, self.connectCont != nil else { return }
                        dlog("ble", "timeout stage=\(self.stage) budget=\(timeout)s otherDevices=\(self.otherDevices.count)")
                        let error: BLEError = self.central.isScanning && self.peripheral == nil
                            ? .ringNotAdvertising(otherDevices: self.otherDevices.count)
                            : .timedOut(stage: self.stage)
                        self.finishConnect(.failure(error))
                        self.closeOnQueue()
                    }
                    connectTimeout = work
                    bleQueue.asyncAfter(deadline: .now() + timeout, execute: work)
                    if central.state == .poweredOn { startScan() }
                    else if [.poweredOff, .unauthorized, .unsupported].contains(central.state) {
                        finishConnect(.failure(BLEError.poweredOff))
                    }
                }
            }
        } onCancel: { self.abort() }
    }

    private static func name(of state: CBManagerState) -> String {
        switch state {
        case .poweredOn: return "poweredOn"
        case .poweredOff: return "poweredOff"
        case .unauthorized: return "unauthorized (check Settings > Privacy > Bluetooth)"
        case .unsupported: return "unsupported"
        case .resetting: return "resetting"
        case .unknown: return "unknown (still initializing)"
        @unknown default: return "state \(state.rawValue)"
        }
    }

    private func startScan() {
        scanStartedAt = Date()
        lock.lock(); stage = "scanning; no ring advertisement seen yet"; lock.unlock()
        dlog("ble", "scanning (unfiltered, allow duplicates); matching service \(RingUUID.service)")
        // UNFILTERED scan, matching done in didDiscover: an OS-side service filter
        // reports nothing when the ring isn't advertising, which is indistinguishable
        // from broken Bluetooth. Seeing (and counting) other devices' advertisements
        // proves the radio works and pins the failure on the ring itself.
        // Allow duplicate discovery reports: the ring's ADV packet is full (flags +
        // 128-bit service UUID + manufacturer data), so its name only arrives in the
        // scan response, which a worn ring in low-power mode answers lazily. Without
        // duplicates iOS may coalesce the ring into a single early, name-less report.
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    /// Finish the inbound frame stream so a Rust drain blocked on `recv` returns at once
    /// (instead of waiting out the quiet-window) — used when a write fails so the sync
    /// surfaces the error promptly rather than proceeding as if the frame was sent.
    func abort() { bleQueue.async { self.closeOnQueue() } }
    func disconnect() { abort() }
    private func closeOnQueue() {
        guard !closed else { return }
        closed = true
        central.stopScan()
        finishWrite(.failure(BLEError.disconnected))
        finishConnect(.failure(BLEError.disconnected))
        notifyContinuation?.finish()
        historyBuffer.removeAll()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil; writeChar = nil
    }

    func write(_ data: Data) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                bleQueue.async { [self] in
                    guard !closed, let p = peripheral, let wc = writeChar else {
                        c.resume(throwing: BLEError.disconnected); return
                    }
                    guard writeCont == nil else { c.resume(throwing: BLEError.busy); return }
                    writeCont = c
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, self.writeCont != nil else { return }
                        dlog("ble", "write failed: GATT acknowledgement timeout budget=10s")
                        self.closeOnQueue()
                    }
                    writeTimeout = work
                    bleQueue.asyncAfter(deadline: .now() + 10, execute: work)
                    p.writeValue(data, for: wc, type: .withResponse)
                }
            }
        } onCancel: { self.abort() }
    }
    // ── CBCentralManagerDelegate ──
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !closed else { return }
        dlog("ble", "central state → \(Self.name(of: central.state))")
        switch central.state {
        case .poweredOn:
            poweredOn = true
            if connectCont != nil { startScan() }
        case .poweredOff, .unauthorized, .unsupported:
            finishConnect(.failure(BLEError.poweredOff))
            closeOnQueue()
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // ignore a discovery that arrives after the attempt already resolved (e.g. a
        // callback queued just past the timeout) — don't start a stray connection.
        lock.lock(); let active = connectCont != nil; lock.unlock()
        guard active, !closed, self.peripheral == nil else { return }
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? ""
        let advServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        // Ring 5 also has a charging case advertising an Oura-looking name and its own
        // charger service. Do not connect to it: it can win the scan race, expose a
        // confusing GATT surface, and then reject the ring auth key.
        let lowerName = advName.lowercased()
        let isChargingCase = lowerName.contains("charging case")
            || advServices.contains(RingUUID.chargingCaseService)
        if isChargingCase {
            let adKey = "\(peripheral.identifier.uuidString)|case|\(advName)"
            if loggedAds.insert(adKey).inserted {
                let svc = advServices.map(\.uuidString).joined(separator: ",")
                let mfr = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)?.hexString ?? "–"
                let conn = advertisementData[CBAdvertisementDataIsConnectable] as? Bool
                dlog("scan", "saw charging case '\(advName.isEmpty ? "<no name>" : advName)' id=\(peripheral.identifier.uuidString.suffix(12)) rssi=\(RSSI) services=[\(svc)] mfr=\(mfr) connectable=\(conn.map(String.init) ?? "?"); waiting for the ring")
            }
            return
        }

        // A ring advertises the proprietary Oura service UUID; accept on that even
        // when the name is missing (the name lives in the scan response, which a worn
        // ring may not have answered yet). Name match covers factory-reset shapes.
        let isRing = advServices.contains(RingUUID.service)
            || (!advName.isEmpty && lowerName.contains(nameContains.lowercased()))
        if !isRing {
            // count distinct non-ring devices as radio liveness proof; log the first
            // few so the transcript shows what the scan IS seeing.
            lock.lock()
            let inserted = otherDevices.insert(peripheral.identifier).inserted
            let count = otherDevices.count
            lock.unlock()
            if inserted && count <= 5 {
                dlog("scan", "other device '\(advName.isEmpty ? "<no name>" : advName)' rssi=\(RSSI); not a ring (\(count) distinct so far)")
            }
            return
        }
        // full advertisement dump, once per (device, name) so allow-duplicates doesn't
        // flood the transcript but a late-arriving scan-response name still shows up.
        let adKey = "\(peripheral.identifier.uuidString)|\(advName)"
        if loggedAds.insert(adKey).inserted {
            let svc = advServices.map(\.uuidString).joined(separator: ",")
            let mfr = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)?.hexString ?? "–"
            let conn = advertisementData[CBAdvertisementDataIsConnectable] as? Bool
            dlog("scan", "saw '\(advName.isEmpty ? "<no name>" : advName)' id=\(peripheral.identifier.uuidString.suffix(12)) rssi=\(RSSI) services=[\(svc)] mfr=\(mfr) connectable=\(conn.map(String.init) ?? "?")")
        }
        if excludedPeripheralIDs.contains(peripheral.identifier) {
            let skipKey = "\(peripheral.identifier.uuidString)|excluded"
            if loggedAds.insert(skipKey).inserted {
                dlog("scan", "skipping excluded ring id=\(peripheral.identifier.uuidString.suffix(12)) (rejected auth key earlier this run)")
            }
            return
        }
        if let preferred = preferredPeripheralID,
           peripheral.identifier != preferred,
           !excludedPeripheralIDs.contains(preferred),
           let started = scanStartedAt,
           Date().timeIntervalSince(started) < 4.0 {
            let waitKey = "\(peripheral.identifier.uuidString)|wait-preferred"
            if loggedAds.insert(waitKey).inserted {
                dlog("scan", "deferring non-preferred ring id=\(peripheral.identifier.uuidString.suffix(12)) briefly to let preferred ring \(preferred.uuidString.suffix(12)) answer")
            }
            return
        }
        guard self.peripheral == nil else { return }
        central.stopScan()
        dlog("ble", "ring matched id=\(peripheral.identifier.uuidString.suffix(12)) rssi=\(RSSI) otherDevices=\(otherDevices.count); connecting")
        lock.lock()
        stage = "GATT-connecting to the discovered ring"
        _connectedPeripheralID = peripheral.identifier
        lock.unlock()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard !closed, self.peripheral === peripheral else { return }
        let mtu = peripheral.maximumWriteValueLength(for: .withResponse)
        dlog("ble", "GATT connected (maxWrite=\(mtu)B); discovering the Oura service")
        lock.lock(); stage = "discovering services/characteristics"; lock.unlock()
        peripheral.discoverServices([RingUUID.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        guard !closed, self.peripheral === peripheral else { return }
        dlog("ble", "GATT connect FAILED: \(error.map { String(describing: $0) } ?? "no error info")")
        finishConnect(.failure(error ?? BLEError.notFound))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        guard !closed, self.peripheral === peripheral else { return }
        dlog("ble", "peripheral disconnected: \(error.map { String(describing: $0) } ?? "clean")")
        notifyContinuation?.finish()
        closed = true
        // don't strand a caller awaiting a connect or write when the link drops.
        finishWrite(.failure(BLEError.disconnected))
        finishConnect(.failure(BLEError.disconnected))
    }

    // ── CBPeripheralDelegate ──
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard !closed, self.peripheral === peripheral else { return }
        if let error {
            dlog("ble", "service discovery FAILED: \(error)")
            return finishConnect(.failure(error))
        }
        let found = (peripheral.services ?? []).map(\.uuid.uuidString).joined(separator: ",")
        dlog("ble", "services: [\(found)]")
        guard let svc = peripheral.services?.first(where: { $0.uuid == RingUUID.service }) else {
            dlog("ble", "Oura service 98ED0001 NOT among them; wrong device?")
            return finishConnect(.failure(BLEError.notFound))
        }
        peripheral.discoverCharacteristics(nil, for: svc)
    }

    private static func props(_ c: CBCharacteristic) -> String {
        var p: [String] = []
        if c.properties.contains(.read) { p.append("read") }
        if c.properties.contains(.write) { p.append("write") }
        if c.properties.contains(.writeWithoutResponse) { p.append("writeNR") }
        if c.properties.contains(.notify) { p.append("notify") }
        if c.properties.contains(.indicate) { p.append("indicate") }
        return p.joined(separator: "+")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard !closed, self.peripheral === peripheral else { return }
        if let error {
            dlog("ble", "characteristic discovery FAILED: \(error)")
            return finishConnect(.failure(error))
        }
        var notifyChars: [CBCharacteristic] = []
        for c in service.characteristics ?? [] {
            dlog("ble", "char …\(c.uuid.uuidString.prefix(8).lowercased()) [\(Self.props(c))]")
            if c.uuid == RingUUID.write { writeChar = c }
            if RingUUID.notify.contains(c.uuid.uuidString.uppercased()) { notifyChars.append(c) }
        }
        dlog("ble", "characteristics discovered; write=\(writeChar != nil), notify=\(notifyChars.count)")
        guard writeChar != nil else {
            dlog("ble", "no write characteristic (98ED0002); wrong device?")
            return finishConnect(.failure(BLEError.noWriteCharacteristic))
        }
        guard !notifyChars.isEmpty else {
            dlog("ble", "no notify characteristics (98ED0003..0006)")
            return finishConnect(.failure(BLEError.notFound))
        }
        // don't report "connected" until every notify subscription is confirmed —
        // otherwise Rust can start syncing before inbound frames flow and miss the
        // ring's early responses. didUpdateNotificationStateFor finishes the connect.
        lock.lock()
        pendingNotify = notifyChars.count
        stage = "subscribing to notify characteristics"
        lock.unlock()
        for c in notifyChars { peripheral.setNotifyValue(true, for: c) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard !closed, self.peripheral === peripheral else { return }
        if let error {
            // a pairing/encryption demand surfaces here (e.g. "Authentication is
            // insufficient") — the single most diagnostic error on a keyed ring.
            dlog("ble", "subscribe FAILED on …\(characteristic.uuid.uuidString.prefix(8).lowercased()): \(error)")
            return finishConnect(.failure(error))
        }
        dlog("ble", "subscribed …\(characteristic.uuid.uuidString.prefix(8).lowercased())")
        lock.lock(); pendingNotify -= 1; let ready = pendingNotify <= 0; lock.unlock()
        if ready {
            dlog("ble", "all notify subscriptions confirmed; BLE link ready, handing to Rust auth")
            finishConnect(.success(()))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard !closed, self.peripheral === peripheral else { return }
        // drop the callback on a read/notify error — a stale payload must not be fed
        // into the frame stream Rust drains as protocol responses.
        guard error == nil, let v = characteristic.value else {
            if let error { dlog("ble", "notify ERROR on \(characteristic.uuid): \(error)"); closeOnQueue() }
            return
        }
        if Self.isHistoryPayload(v) {
            historyBuffer.append(v)
            historyFrames += 1
            historyBytes += v.count
            if historyBuffer.count >= Self.historyFlushBytes {
                flushHistoryPayload()
            }
            return
        }

        // A command response / 0x42 batch summary terminates the preceding history
        // burst. Deliver buffered packets first to preserve byte order, then retain one
        // compact diagnostic line instead of tens of thousands of raw payload lines.
        flushHistoryPayload()
        if historyFrames > 0 {
            dlog("recv", "history payload omitted; \(historyFrames) BLE frames, \(historyBytes)B")
            historyFrames = 0
            historyBytes = 0
        }
        dlog("recv", "\(v.count)B [\(characteristic.uuid.uuidString.prefix(8).lowercased())] \(v.hexString)")
        deliver(v)
    }

    /// Extended history data is `0x2f … 0x43`; legacy history packets use event
    /// tags >= 0x41. Walk every length-prefixed packet because one BLE notification
    /// can contain several packets. If even one is a summary/control packet, deliver
    /// the notification immediately so a trailing terminator can never sit buffered.
    private static func isHistoryPayload(_ data: Data) -> Bool {
        var offset = 0
        while offset < data.count {
            guard offset + 2 <= data.count else { return false }
            let tag = data[offset]
            let length = Int(data[offset + 1])
            let end = offset + 2 + length
            guard end <= data.count else { return false }
            let isHistory = tag >= 0x41
                || (tag == 0x2f && length >= 1 && data[offset + 2] == 0x43)
            guard isHistory else { return false }
            offset = end
        }
        return offset > 0
    }

    private func deliver(_ data: Data) {
        if case .dropped = notifyContinuation?.yield(data) {
            dlog("ble", "receive queue overflow; replay from committed checkpoint")
            closeOnQueue()
        }
    }

    private func flushHistoryPayload() {
        guard !historyBuffer.isEmpty else { return }
        let payload = historyBuffer
        historyBuffer.removeAll(keepingCapacity: true)
        deliver(payload)
    }

    /// GATT write-with-response acknowledgement (or error) for the in-flight `write`.
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard !closed, self.peripheral === peripheral else { return }
        if let error { dlog("ble", "write NAK: \(error)") }
        finishWrite(error.map { .failure($0) } ?? .success(()))
    }

    private func finishConnect(_ result: Result<Void, Error>) {
        lock.lock()
        let c = connectCont; connectCont = nil
        let timer = connectTimeout; connectTimeout = nil
        lock.unlock()
        timer?.cancel() // stop a still-pending timeout from firing on a finished attempt
        if case .failure = result {
            // tear down an abandoned/failed attempt: cancel the peripheral so iOS stops
            // delivering its callbacks, and reset the per-attempt state so a stray late
            // didUpdateNotificationStateFor can't bleed into a later connect's counter.
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            peripheral = nil
            writeChar = nil
            lock.lock(); pendingNotify = 0; lock.unlock()
        }
        c?.resume(with: result)
    }

    private func finishWrite(_ result: Result<Void, Error>) {
        writeTimeout?.cancel(); writeTimeout = nil
        lock.lock(); let c = writeCont; writeCont = nil; lock.unlock()
        c?.resume(with: result)
    }
}
