import Foundation
import Security
import os
import Darwin
import UIKit

// Shared debug logger for the connect + auth + sync path. View live in Console.app
// (filter subsystem `md.thomas.openoura`). Stage/progress records replace raw
// frames; authentication traffic and device identities are excluded.
let ringLog = Logger(subsystem: "md.thomas.openoura", category: "ring")
extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

/// In-app diagnostics for the connect/auth/sync pipeline. Every `dlog` line is kept
/// in a bounded in-memory transcript that the sync screen shows live and can copy to
/// the pasteboard — so a failure in the field can be pasted into a bug report as-is,
/// with no tethered Mac, no Console.app, and no rebuild with more logging.
final class RingDiag: ObservableObject, @unchecked Sendable {
    static let shared = RingDiag()

    /// Coalesced UI mirror (the last `tailCount` lines) + total, updated ≤4×/s so a
    /// chatty sync drain doesn't hammer SwiftUI from the BLE queue.
    @Published private(set) var tail: [String] = []
    @Published private(set) var totalLines = 0

    private let lock = NSLock()
    private var lines: [String] = []
    private var total = 0
    private var dropped = 0
    private var uiUpdateQueued = false
    private static let cap = 4000      // ring buffer: newest lines win
    private static let tailCount = 30

    // DateFormatter is documented thread-safe on modern OSes.
    private static let started = ProcessInfo.processInfo.systemUptime
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    func log(_ tag: String, _ msg: String) {
        let elapsed = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - Self.started)
        let level = msg.lowercased().contains("fail") ? "error" : "info"
        let line = "\(Self.clock.string(from: Date())) +\(elapsed)s \(level) [\(tag)] \(msg)"
        lock.lock()
        lines.append(line)
        total += 1
        if lines.count > Self.cap {
            dropped += lines.count - Self.cap
            lines.removeFirst(lines.count - Self.cap)
        }
        let alreadyQueued = uiUpdateQueued
        uiUpdateQueued = true
        lock.unlock()
        DiagStore.shared.append(line)
        if !alreadyQueued {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.uiUpdateQueued = false
                let t = Array(self.lines.suffix(Self.tailCount))
                let n = self.total
                self.lock.unlock()
                self.tail = t
                self.totalLines = n
            }
        }
    }

    /// The full transcript, prefixed with enough environment to make it self-contained.
    func dump() -> String {
        lock.lock()
        let body = lines.joined(separator: "\n")
        let droppedNote = dropped > 0 ? "\n(oldest \(dropped) lines dropped; buffer cap \(Self.cap))" : ""
        lock.unlock()
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let v = Bundle.main.infoDictionary
        let app = "\(v?["CFBundleShortVersionString"] ?? "?") (\(v?["CFBundleVersion"] ?? "?"))"
        return "Open Oura \(app); iOS \(os); \(Date())\(droppedNote)\n\(body)"
    }

    func summary() -> String {
        lock.lock(); defer { lock.unlock() }
        return "Open Oura diagnostics · session=\(DiagStore.shared.sessionID)\n"
            + lines.suffix(80).joined(separator: "\n")
    }

    func clear() {
        lock.lock()
        lines = []; total = 0; dropped = 0
        lock.unlock()
        DispatchQueue.main.async { self.tail = []; self.totalLines = 0 }
    }
}

/// One call, two sinks: the in-app transcript (copy-pasteable) and os.log. The
/// `.public` privacy is deliberate — without it, os.log redacts interpolated strings
/// as `<private>` on an untethered device, which is exactly when we need them.
func dlog(_ tag: String, _ msg: String) {
    // Low-level transport chatter is summarized by stage/progress records.
    if ["send", "recv", "scan", "idle"].contains(tag) { return }
    RingDiag.shared.log(tag, msg)
    ringLog.info("[\(tag, privacy: .public)] \(msg, privacy: .public)")
}

func memLog(_ tag: String) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    let free = (try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
    dlog("mem", "\(tag) footprint=\(result == KERN_SUCCESS ? info.phys_footprint / 1_048_576 : 0)MB avail=\(os_proc_available_memory() / 1_048_576)MB diskFree=\(free / 1_048_576)MB thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
}

@MainActor
enum IdleTimerLock {
    // Match SweetBlue's Android wake-lock semantics: each acquisition owns one
    // reference and the idle timer is restored only after the final release.
    private static var reasons: [String: Int] = [:]
    private static var observers: [NSObjectProtocol] = []
    private static var heartbeat: Task<Void, Never>?

    static func acquire(_ reason: String) {
        let wasEmpty = reasons.isEmpty
        reasons[reason, default: 0] += 1
        if wasEmpty {
            startMonitoring()
        }
        apply()
        dlog("idle", "screen lock disabled (\(reason)); holders=\(holderSummary)")
    }

    static func release(_ reason: String) {
        if let count = reasons[reason] {
            if count > 1 {
                reasons[reason] = count - 1
            } else {
                reasons.removeValue(forKey: reason)
            }
        }
        apply()
        if reasons.isEmpty {
            stopMonitoring()
        }
        dlog("idle", "screen lock \(reasons.isEmpty ? "enabled" : "still disabled") after releasing \(reason)")
    }

    static func refreshIfHeld(_ reason: String) {
        if reasons[reason] != nil {
            apply()
            dlog("idle", "screen lock disabled refreshed (\(reason))")
        }
    }

    private static func apply() {
        UIApplication.shared.isIdleTimerDisabled = !reasons.isEmpty
    }

    private static var holderSummary: String {
        reasons.keys.sorted().map { reason in
            let count = reasons[reason] ?? 0
            return count == 1 ? reason : "\(reason)×\(count)"
        }.joined(separator: ",")
    }

    private static func reassertIfNeeded(_ source: String) {
        guard !reasons.isEmpty, !UIApplication.shared.isIdleTimerDisabled else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        dlog("idle", "screen lock was reset by iOS; disabled again (\(source))")
    }

    private static func startMonitoring() {
        let center = NotificationCenter.default
        observers = [
            UIApplication.didBecomeActiveNotification,
            UIApplication.willEnterForegroundNotification,
            UIApplication.protectedDataDidBecomeAvailableNotification,
        ].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in reassertIfNeeded(name.rawValue) }
            }
        }
        heartbeat?.cancel()
        heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { break }
                reassertIfNeeded("heartbeat")
            }
        }
    }

    private static func stopMonitoring() {
        heartbeat?.cancel()
        heartbeat = nil
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }
}

// On-device BLE sync: connect to the ring over CoreBluetooth (BLETransport), then
// drive the SAME Rust client over FFI (RingSession) to authenticate + drain history
// events into a writable SQLite DB. Mirrors `oura sync` on desktop. The actual BLE
// round-trip only works on a physical device (no Bluetooth in the simulator).

/// Where the app reads/writes its SQLite DB. The synced DB lives in Application
/// Support (writable); until a sync has happened we fall back to the bundled seed.
enum DB {
    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("oura.db")
    }
    /// Absolute path of the DB to READ from (synced if present, else bundled seed).
    static func readPath() -> String {
        let p = url.path
        if FileManager.default.fileExists(atPath: p) { return p }
        return Bundle.main.path(forResource: "oura", ofType: "db") ?? p
    }

    /// Drop the writable synced DB. The bundled seed remains intact; the next sync
    /// starts from an empty local store and drains the ring from cursor 0.
    static func resetWritableStore() throws {
        let p = url
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: p.path + suffix)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }
}

/// The ring auth key (exported from the desktop client) kept in the Keychain.
enum Keychain {
    private static let account = "ring-auth-key"
    static func saveKey(_ hex: String) {
        let data = Data(hex.utf8)
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }
    static func clearKey() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
    static func loadKey() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }
}

/// Bridges the Rust BleWriter callback onto BLETransport's async write. The callback is
/// synchronous (Rust's transact then waits for the response via push_frame), but a GATT
/// write-with-response must complete before the next one or CoreBluetooth rejects it as
/// busy. So writes are chained into a FIFO: each awaits the previous one's completion,
/// guaranteeing strictly sequential, non-overlapping writes.
final class RingWriter: BleWriter, @unchecked Sendable {
    private let transport: BLETransport
    private let lock = NSLock()
    private var tail: Task<Void, Never> = Task {}
    init(_ t: BLETransport) { transport = t }
    func write(data: Data) {
        let t = transport
        lock.lock()
        let prev = tail
        tail = Task {
            _ = await prev.value          // wait for the prior write to finish…
            do {
                try await t.write(data)   // …then perform (and await) this one
            } catch {
                // a failed write means the ring never got the frame — close the inbound
                // stream so the Rust drain stops waiting and the sync fails loudly
                // instead of proceeding as if the request was sent.
                dlog("write", "FAILED (\(error)); aborting inbound stream so the sync errors out")
                t.abort()
            }
        }
        lock.unlock()
    }
}

/// Bridges Rust sync-progress callbacks (arriving on a tokio thread) onto the
/// main actor for the UI. Weakly captured so a dead RingSync just drops updates.
final class SyncProgressBridge: SyncProgressListener, @unchecked Sendable {
    private let update: @MainActor (String, UInt64, UInt32) -> Void
    init(_ update: @escaping @MainActor (String, UInt64, UInt32) -> Void) {
        self.update = update
    }
    func onProgress(stage: String, bytesLeft: UInt64, eventsSynced: UInt32) {
        Task { @MainActor in self.update(stage, bytesLeft, eventsSynced) }
    }
}

/// Orchestrates a sync and exposes progress to the UI.
@MainActor
final class RingSync: ObservableObject {
    @Published var status: String = ""
    @Published var busy = false
    @Published private(set) var exportStatus: String?
    @Published var connectionIssue: String?
    @Published var lastReport: SyncReport?
    @Published private(set) var lastSuccessfulSyncAt: Date?
    /// Serial of the ring this phone last talked to — used to confirm a factory reset
    /// targets THIS ring and not one that merely won the scan.
    @Published private(set) var knownSerial: String? = UserDefaults.standard.string(forKey: "ring.serial")

    /// A launch/foreground refresh is useful, but reconnecting twice while someone
    /// briefly switches apps is not. Manual sync remains available at any time.
    static let automaticSyncCooldown: TimeInterval = 3 * 60
    private static let lastSuccessfulSyncKey = "ring.last-successful-sync-at"
    // Set the moment a drain reports real progress, cleared only on a completed
    // sync — so it survives an app kill mid-drain and distinguishes "interrupted
    // with data on the ring" (resume eagerly) from "never reached the ring".
    private static let syncIncompleteKey = "ring.sync-incomplete"

    private var transport: BLETransport?
    private var session: RingSession?
    private var pump: Task<Void, Never>?
    private var lastProgressBytes: UInt64?
    private var lastProgressAt: Date?
    private var smoothedBytesPerSecond: Double?
    private var lastAutomaticAttemptAt: Date?
    private var markedIncompleteThisRun = false
    private var paused = false
    private var runID = ""
    private var attemptID = ""
    private var progressLogAt = 0.0
    private var progressStage = ""
    private var lifecycleObservers: [NSObjectProtocol] = []

    func pause() {
        paused = true
        session?.cancel(reason: "paused")
        transport?.abort()
        status = "Sync paused. Return to the app to resume."
    }


    var hasIncompleteSync: Bool {
        UserDefaults.standard.bool(forKey: Self.syncIncompleteKey)
    }

    private func clearIncompleteSync() {
        UserDefaults.standard.removeObject(forKey: Self.syncIncompleteKey)
    }

    init() {
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.protectedDataWillBecomeUnavailableNotification] {
            lifecycleObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.busy else { return }
                    WorkCoordinator.shared.beginCleanup()
                    self.pause()
                }
            })
        }
        let timestamp = UserDefaults.standard.double(forKey: Self.lastSuccessfulSyncKey)
        lastSuccessfulSyncAt = timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    var wasRecentlySynced: Bool {
        lastSuccessfulSyncAt.map { Date().timeIntervalSince($0) < Self.automaticSyncCooldown } ?? false
    }

    /// Opportunistic refresh used at launch and when returning to the app. It never
    /// prompts for a key. Normally a timid single attempt behind a cooldown — but
    /// when the last sync was interrupted mid-drain, the checkpointed cursor means
    /// data is sitting half-transferred on the ring, so resume eagerly with the
    /// retry loop instead of silently giving up.
    func syncAutomaticallyIfNeeded(now: Date = Date()) async -> SyncReport? {
        guard WorkCoordinator.shared.available, !busy, let key = Keychain.loadKey() else { return nil }
        let resuming = hasIncompleteSync
        if !resuming,
           let successful = lastSuccessfulSyncAt,
           now.timeIntervalSince(successful) < Self.automaticSyncCooldown {
            return nil
        }
        // A failed scan should not immediately restart because scenePhase bounced.
        if !paused, let attempted = lastAutomaticAttemptAt, now.timeIntervalSince(attempted) < 60 {
            return nil
        }
        lastAutomaticAttemptAt = now
        if resuming { status = "Resuming sync…" }
        return await run(keyHex: key,
                         maxAttempts: resuming ? 3 : 1,
                         source: resuming ? "resume" : "automatic")
    }

    func resetLocalDatabase() async -> Bool {
        pause()
        WorkCoordinator.shared.invalidateAnalysis()
        await WorkGate.shared.acquire()
        defer { Task { await WorkGate.shared.release() } }
        guard WorkCoordinator.shared.available else { return false }
        do {
            try DB.resetWritableStore()
            lastReport = nil; lastSuccessfulSyncAt = nil
            UserDefaults.standard.removeObject(forKey: Self.lastSuccessfulSyncKey)
            clearIncompleteSync()
            SummaryCache.clear()
            #if TORCH
            ModelCacheStore.clearAll()
            #endif
            connectionIssue = nil
            status = "local sync data reset"
            dlog("db", status)
            return true
        } catch { status = "reset failed: \(error)"; dlog("db", status); return false }
    }

    func checkDatabase() async {
        await WorkGate.shared.acquire()
        defer { Task { await WorkGate.shared.release() } }
        guard WorkCoordinator.shared.available else { return }
        connectionIssue = nil
        let path = DB.readPath()
        status = await Task.detached {
            do { return "Database check: \(try databaseIntegrity(dbPath: path))" }
            catch { return "Database check failed: \(error)" }
        }.value
        dlog("db", status)
    }

    /// Write a self-contained copy of the saved ring database to a temporary file
    /// for sharing (AirDrop/Files). Contains raw ring records only; the auth key
    /// lives in the Keychain and is never included. Returns nil on failure.
    func exportRawDatabase() async -> URL? {
        guard exportStatus == nil else { return nil }
        let started = Date()
        exportStatus = "Waiting for sync and analysis…"
        defer { exportStatus = nil }
        await WorkGate.shared.acquire()
        defer { Task { await WorkGate.shared.release() } }
        guard WorkCoordinator.shared.available else { return nil }
        let waited = Date().timeIntervalSince(started)
        exportStatus = "Preparing database…"
        dlog("db", "export gate wait=\(String(format: "%.2f", waited))s")
        let source = DB.readPath()
        let stamp = { () -> String in
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"; return f.string(from: Date())
        }()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("oura-ring-\(stamp)-\(UUID().uuidString).db")
        let result: String? = await Task.detached {
            do { try exportDatabase(dbPath: source, outPath: out.path); return nil }
            catch { return "\(error)" }
        }.value
        if let result {
            try? FileManager.default.removeItem(at: out)
            status = "Export failed: \(result)"; dlog("db", status); return nil
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        dlog("db", "export copy=\(String(format: "%.2f", Date().timeIntervalSince(started) - waited))s")
        dlog("db", "exported \(out.lastPathComponent) (\(size) bytes) from \(source)")
        return out
    }

    /// Connect, wire the inbound-frame pump, and run a full sync into the writable DB.
    private func rememberSerial(_ serial: String) {
        guard !serial.isEmpty, serial != "unknown" else { return }
        knownSerial = serial
        UserDefaults.standard.set(serial, forKey: "ring.serial")
    }

    /// **DESTRUCTIVE.** Wipe the ring back to factory state. Erases its auth key, every
    /// Bluetooth bond, the events it still holds and the stored body profile. The saved
    /// key is dropped from the Keychain afterwards because it no longer opens anything.
    ///
    /// Only proceeds when the ring that answers reports `confirmSerial`, so this cannot
    /// wipe someone else's ring sitting on the same charger.
    func factoryReset(keyHex: String, confirmSerial: String) async -> Bool {
        guard !busy else { return false }
        guard WorkCoordinator.shared.available else { status = "paused — open the app to reset"; return false }
        connectionIssue = nil
        busy = true
        paused = false
        await WorkGate.shared.acquire()
        IdleTimerLock.acquire("ring-reset")
        defer {
            busy = false
            IdleTimerLock.release("ring-reset")
            Task { await WorkGate.shared.release() }
            WorkCoordinator.shared.endCleanup()
            pump?.cancel()
            pump = nil
            transport?.disconnect()
            transport = nil
            session = nil
        }

        dlog("reset", "start — target \(confirmSerial)")
        status = "looking for \(confirmSerial)…"
        let t = BLETransport(nameContains: "Oura")
        transport = t
        do {
            try await t.connect()
        } catch {
            dlog("reset", "BLE connect FAILED: \(error)")
            status = "couldn't connect (\(error)) — put the ring on its charger next to this iPhone"
            return false
        }

        let s = RingSession(writer: RingWriter(t))
        session = s
        let frames = t.notifications
        pump = Task {
            for await frame in frames { s.pushFrame(data: frame) }
            s.cancel(reason: "transport closed")
        }

        status = "erasing…"
        do {
            let serial = try await s.factoryReset(keyHex: keyHex, confirmSerial: confirmSerial)
            Keychain.clearKey()
            lastReport = nil
            dlog("reset", "wiped \(serial)")
            status = "\(serial) wiped. Its old key is gone — pair it again to start over."
            return true
        } catch {
            dlog("reset", "FAILED: \(error)")
            status = "reset failed: \(error)"
            return false
        }
    }

    /// Adopt a **factory-reset** ring from the phone alone: connect, install a freshly
    /// minted 16-byte auth key, and save it to the Keychain. Returns the key as 32 hex
    /// characters so the UI can offer a backup — it is the only copy, and a lost key
    /// costs another factory reset.
    ///
    /// `existingKeyHex` re-installs a key you already hold instead of minting one.
    /// A ring that still holds a key rejects this; reset it first.
    func pair(existingKeyHex: String? = nil) async -> String? {
        guard !busy else { return nil }
        guard WorkCoordinator.shared.available else { status = "paused — open the app to pair"; return nil }
        connectionIssue = nil
        busy = true
        paused = false
        await WorkGate.shared.acquire()
        IdleTimerLock.acquire("ring-pair")
        defer {
            busy = false
            IdleTimerLock.release("ring-pair")
            Task { await WorkGate.shared.release() }
            WorkCoordinator.shared.endCleanup()
            pump?.cancel()
            pump = nil
            // free the ring's single BLE link, exactly as a sync does
            transport?.disconnect()
            transport = nil
            session = nil
        }

        dlog("pair", "start — scanning for a reset ring")
        status = "looking for a ring on its charger…"
        let t = BLETransport(nameContains: "Oura")
        transport = t
        do {
            try await t.connect()
        } catch {
            dlog("pair", "BLE connect FAILED: \(error)")
            if case BLEError.poweredOff = error {
                status = "Bluetooth unavailable — check power and permission in Settings"
            } else {
                status = "couldn't connect (\(error)) — put the reset ring on its charger next to this iPhone"
            }
            return nil
        }

        let s = RingSession(writer: RingWriter(t))
        session = s
        let frames = t.notifications
        pump = Task {
            for await frame in frames { s.pushFrame(data: frame) }
            s.cancel(reason: "transport closed")
        }

        status = "installing a new key…"
        do {
            let report = try await s.pair(existingKeyHex: existingKeyHex)
            // Persist BEFORE anything else can fail: the ring now holds this key and
            // will not hand it back.
            Keychain.saveKey(report.keyHex)
            rememberSerial(report.serial)
            dlog("pair", "paired \(report.serial) minted=\(report.minted)")
            status = "paired with \(report.serial) — key saved to this iPhone. Back it up: it can't be read off the ring."
            return report.keyHex
        } catch {
            dlog("pair", "FAILED: \(error)")
            status = "pairing failed: \(error)"
            return nil
        }
    }

    @discardableResult
    func run(keyHex: String, maxAttempts: Int = 6, source: String = "manual") async -> SyncReport? {
        guard !busy else { return nil }
        connectionIssue = nil
        lastReport = nil   // clear any prior success so a failed retry isn't read as one
        lastProgressBytes = nil
        lastProgressAt = nil
        smoothedBytesPerSecond = nil
        let key = keyHex.trimmingCharacters(in: .whitespacesAndNewlines)
        runID = UUID().uuidString
        dlog("sync", "start run=\(runID) source=\(source)")
        guard key.utf8.count == 32, key.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            dlog("sync", "rejected key: len=\(key.count) (need 32 hex chars)")
            status = "key must be 32 hex characters"
            return nil
        }
        guard WorkCoordinator.shared.available else { status = "Sync paused. Open the app to resume."; return nil }
        busy = true
        paused = false
        WorkCoordinator.shared.invalidateAnalysis()
        await WorkGate.shared.acquire()
        defer { Task { await WorkGate.shared.release() }; WorkCoordinator.shared.endCleanup() }
        guard !paused, WorkCoordinator.shared.available else { busy = false; return nil }
        markedIncompleteThisRun = false
        // A multi-hour first sync must not die because the screen locked; SyncView
        // refreshes this when the app becomes active again.
        IdleTimerLock.acquire("ring-sync")
        defer {
            busy = false
            IdleTimerLock.release("ring-sync")
            pump?.cancel()
            pump = nil
            // release the ring's single BLE link — holding it after the sync would
            // stop the ring advertising for the official app, the Mac, AND our own
            // next scan (it would look like "no ring advertisement seen").
            transport?.disconnect()
            transport = nil
            session = nil
        }

        // The drain checkpoints its cursor after every batch, so each retry RESUMES
        // where the link dropped rather than starting over — reconnect-and-retry is
        // safe and cheap. Retries cover both connect failures and mid-sync drops.
        var connectedDuringRun = source == "resume"
        for attempt in 1...max(1, maxAttempts) {
            if paused || Task.isCancelled || !WorkCoordinator.shared.available { status = "Sync paused. Return to the app to resume."; return nil }
            attemptID = UUID().uuidString
            dlog("sync", "attempt=\(attempt) id=\(attemptID) run=\(runID)")
            if attempt > 1 {
                dlog("sync", "attempt \(attempt)/\(maxAttempts); resuming from the checkpointed cursor in 3 s")
                status = "Connection lost. Retrying (\(attempt) of \(maxAttempts))…"
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return nil }
                guard !paused, WorkCoordinator.shared.available else { return nil }
            }

            status = attempt == 1 ? "Looking for your ring nearby…" : "Looking for your ring again (attempt \(attempt)/\(maxAttempts))…"
            dlog("sync", "connecting; scanning for the Oura service (name filter 'Oura')…")
            // fresh transport + session per attempt: the previous link is dead and
            // BLETransport's notification stream is per-connection.
            let t = BLETransport(nameContains: "Oura")
            transport = t
            do {
                try await t.connect()
            } catch {
                if paused { status = "Sync paused. Return to the app to resume."; return nil }
                dlog("sync", "BLE connect FAILED: \(error)")
                // the ring advertises reliably only ON its charger (low-power adv when
                // worn), and it has a single BLE link — a phone running the official
                // app holds it, leaving nothing to discover.
                if case BLEError.poweredOff = error { status = "Bluetooth is unavailable. Check Bluetooth and app permissions in Settings."; return nil }
                t.disconnect()
                if case BLEError.ringNotAdvertising(let count) = error, !connectedDuringRun {
                    connectionIssue = "Your ring wasn’t found"
                    status = count > 0
                        ? "Place your ring on its charger nearby. Disconnect it from other phones, then try again."
                        : "Place your ring on its charger nearby. Check Bluetooth in Settings, then try again."
                    // An initial scan already waited 50 seconds. Repeating it six
                    // times hides the setup problem; retain retries for actual drops.
                    return nil
                }
                dlog("sync", "connection failed: \(error)")
                status = "Couldn’t connect. Place your ring on its charger and disconnect it from other phones."
                continue
            }
            connectedDuringRun = true
            dlog("sync", "BLE link ready; creating RingSession + inbound-frame pump")

            let s = RingSession(writer: RingWriter(t))
            session = s
            UserDefaults.standard.set(true, forKey: Self.syncIncompleteKey)
            pump?.cancel()
            let frames = t.notifications
            pump = Task {
                for await frame in frames { s.pushFrame(data: frame) }
                s.cancel(reason: "transport closed")
            }

            status = "Syncing…"
            dlog("sync", "starting FFI sync(); authenticate, app stream, then event drain")
            do {
                let expectedAttempt = attemptID
                let progress = SyncProgressBridge { [weak self] stage, bytesLeft, events in
                    guard self?.attemptID == expectedAttempt, self?.busy == true, self?.paused == false else { return }
                    if stage == "setup" { Keychain.saveKey(key) }
                    self?.showProgress(stage: stage, bytesLeft: bytesLeft, events: events)
                }
                let report = try await s.sync(dbPath: DB.url.path, keyHex: key, progress: progress)
                Keychain.saveKey(key)
                rememberSerial(report.serial)
                lastReport = report
                let completedAt = Date()
                lastSuccessfulSyncAt = completedAt
                UserDefaults.standard.set(completedAt.timeIntervalSince1970,
                                          forKey: Self.lastSuccessfulSyncKey)
                clearIncompleteSync()
                dlog("sync", "OK run=\(runID) inserted=\(report.inserted) events=\(report.eventsSynced) cursor=\(report.nextCursor)")
                status = "Sync complete."
                return report
            } catch {
                // the Rust layer packs the diagnostic detail (auth state, missing
                // summary, cursor) into this message — log it verbatim.
                if paused { status = "Sync paused. Return to the app to resume."; return nil }
                dlog("sync", "attempt \(attempt) FAILED: \(error)")
                if case SyncError.Storage(_, _, _, _, _, _) = error {
                    status = "Couldn’t save ring data. See Help & diagnostics for details."
                    memLog("storage failure")
                    return nil
                }
                pump?.cancel()
                pump = nil
                t.disconnect() // release the (possibly half-dead) link before retrying
                if Self.isAuthenticationFailure(error) {
                    status = "Your ring rejected this pairing key. Use the key from the phone that originally set up this ring."
                    dlog("sync", "not retrying: auth rejection is deterministic")
                    // Deterministic rejection — an eager resume would just re-fail.
                    clearIncompleteSync()
                    return nil
                }
                status = "Sync interrupted. Try connecting again."
            }
        }
        dlog("sync", "failed run=\(runID) attempts=\(maxAttempts) reason=\(status)")
        return nil
    }

    /// Render Rust-side progress into the status line.
    private func showProgress(stage: String, bytesLeft: UInt64, events: UInt32) {
        let now = ProcessInfo.processInfo.systemUptime
        if stage != progressStage || now - progressLogAt >= 10 || (bytesLeft == 0 && events > 0) {
            dlog("progress", "run=\(runID) stage=\(stage) bytesLeft=\(bytesLeft) committedEvents=\(events)")
            progressStage = stage; progressLogAt = now
        }
        // Real drain progress means data is mid-transfer: from here until the sync
        // completes, an interruption should resume eagerly on return to the app.
        if events > 0, !markedIncompleteThisRun {
            markedIncompleteThisRun = true
            UserDefaults.standard.set(true, forKey: Self.syncIncompleteKey)
        }
        switch stage {
        case "auth":
            status = "Checking pairing key…"
        case "setup":
            status = "Preparing your ring…"
        case "rebase":
            status = "Recovering ring history…"
            dlog("sync", "saved cursor is absent on ring; rebasing to the new boot epoch")
        default:
            if bytesLeft > 0 {
                let now = Date()
                if let previousBytes = lastProgressBytes,
                   let previousAt = lastProgressAt,
                   previousBytes > bytesLeft {
                    let elapsed = now.timeIntervalSince(previousAt)
                    if elapsed > 0.05 {
                        let instant = Double(previousBytes - bytesLeft) / elapsed
                        smoothedBytesPerSecond = smoothedBytesPerSecond
                            .map { $0 * 0.65 + instant * 0.35 } ?? instant
                    }
                } else if let previousBytes = lastProgressBytes, bytesLeft > previousBytes {
                    smoothedBytesPerSecond = nil // a rebase/new drain starts a new estimate
                }
                lastProgressBytes = bytesLeft
                lastProgressAt = now
                let eta = smoothedBytesPerSecond.flatMap { rate -> String? in
                    guard rate > 0 else { return nil }
                    return Self.fmtDuration(Double(bytesLeft) / rate)
                }
                status = "syncing… ~\(Self.fmtBytes(bytesLeft)) left · \(events) events"
                    + (eta.map { " · about \($0)" } ?? "")
            } else if events > 0 {
                status = "syncing… \(events) events · finishing up"
            } else {
                status = "Syncing…"
            }
        }
    }

    private static func fmtBytes(_ b: UInt64) -> String {
        b >= 1_048_576
            ? String(format: "%.1f MB", Double(b) / 1_048_576)
            : String(format: "%.0f KB", Double(b) / 1024)
    }

    private static func fmtDuration(_ seconds: Double) -> String {
        let s = max(1, Int(seconds.rounded()))
        if s < 60 { return "\(s)s" }
        let minutes = Int((Double(s) / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%.1f h", Double(minutes) / 60)
    }

    private static func isAuthenticationFailure(_ error: Error) -> Bool {
        let s = String(describing: error).lowercased()
        return s.contains("authentication failed") || s.contains("ring rejected auth")
    }
}
