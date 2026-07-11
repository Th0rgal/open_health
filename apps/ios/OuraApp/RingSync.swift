import Foundation
import Security
import os
import CryptoKit
import UIKit

// Shared debug logger for the connect + auth + sync path. View live in Console.app
// (filter subsystem `md.thomas.openoura`) or `xcrun simctl spawn booted log stream
// --predicate 'subsystem == "md.thomas.openoura"'`. Control frames are logged as hex;
// bulk history is summarized by frame/byte count. The auth KEY is never logged.
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
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func log(_ tag: String, _ msg: String) {
        let line = "\(Self.clock.string(from: Date())) [\(tag)] \(msg)"
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
        let droppedNote = dropped > 0 ? "\n(oldest \(dropped) lines dropped — buffer cap \(Self.cap))" : ""
        lock.unlock()
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let v = Bundle.main.infoDictionary
        let app = "\(v?["CFBundleShortVersionString"] ?? "?") (\(v?["CFBundleVersion"] ?? "?"))"
        return "open_oura \(app) — iOS \(os) — \(Date())\(droppedNote)\n\(body)"
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
    RingDiag.shared.log(tag, msg)
    ringLog.info("[\(tag, privacy: .public)] \(msg, privacy: .public)")
}

@MainActor
enum IdleTimerLock {
    private static var reasons = Set<String>()
    private static var observers: [NSObjectProtocol] = []
    private static var heartbeat: Task<Void, Never>?

    static func acquire(_ reason: String) {
        let wasEmpty = reasons.isEmpty
        reasons.insert(reason)
        if wasEmpty {
            startMonitoring()
        }
        apply()
        dlog("idle", "screen lock disabled (\(reason)); holders=\(reasons.sorted().joined(separator: ","))")
    }

    static func release(_ reason: String) {
        reasons.remove(reason)
        apply()
        if reasons.isEmpty {
            stopMonitoring()
        }
        dlog("idle", "screen lock \(reasons.isEmpty ? "enabled" : "still disabled") after releasing \(reason)")
    }

    static func refreshIfHeld(_ reason: String) {
        if reasons.contains(reason) {
            apply()
            dlog("idle", "screen lock disabled refreshed (\(reason))")
        }
    }

    private static func apply() {
        UIApplication.shared.isIdleTimerDisabled = !reasons.isEmpty
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
        guard FileManager.default.fileExists(atPath: p.path) else { return }
        try FileManager.default.removeItem(at: p)
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
                dlog("write", "FAILED (\(error)) — aborting inbound stream so the sync errors out")
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
    @Published var lastReport: SyncReport?

    private var transport: BLETransport?
    private var session: RingSession?
    private var pump: Task<Void, Never>?
    private var lastProgressBytes: UInt64?
    private var lastProgressAt: Date?
    private var smoothedBytesPerSecond: Double?

    func resetLocalDatabase() {
        do {
            try DB.resetWritableStore()
            lastReport = nil
            status = "local sync database reset — run Connect & Sync again"
            dlog("db", "writable sync database reset")
        } catch {
            status = "reset failed: \(error.localizedDescription)"
            dlog("db", "reset failed: \(error)")
        }
    }

    /// Connect, wire the inbound-frame pump, and run a full sync into the writable DB.
    func run(keyHex: String) async {
        lastReport = nil   // clear any prior success so a failed retry isn't read as one
        lastProgressBytes = nil
        lastProgressAt = nil
        smoothedBytesPerSecond = nil
        // one attempt = one transcript, so a copied log is unambiguous about which run
        // it describes.
        RingDiag.shared.clear()
        let key = keyHex.trimmingCharacters(in: .whitespacesAndNewlines)
        // A SHA-256-derived fingerprint confirms the *right* key arrived intact without
        // exposing any key bytes (a raw slice would leak key material).
        let fp = SHA256.hash(data: Data(key.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        let hexOk = key.allSatisfy(\.isHexDigit)
        dlog("sync", "run — key len=\(key.count), hex=\(hexOk), fp(sha256)=\(fp)")
        guard key.count == 32, key.allSatisfy(\.isHexDigit) else {
            dlog("sync", "rejected key: len=\(key.count) (need 32 hex chars)")
            status = "key must be 32 hex characters"
            return
        }
        busy = true
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
        let maxAttempts = 6
        for attempt in 1...maxAttempts {
            if attempt > 1 {
                dlog("sync", "attempt \(attempt)/\(maxAttempts) — resuming from the checkpointed cursor in 3 s")
                status = "connection lost — resuming (attempt \(attempt)/\(maxAttempts))…"
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }

            status = attempt == 1 ? "connecting to ring…" : "reconnecting to ring…"
            dlog("sync", "connecting — scanning for the Oura service (name filter 'Oura')…")
            // fresh transport + session per attempt: the previous link is dead and
            // BLETransport's notification stream is per-connection.
            let t = BLETransport(nameContains: "Oura")
            transport = t
            do {
                try await t.connect()
            } catch {
                dlog("sync", "BLE connect FAILED: \(error)")
                // the ring advertises reliably only ON its charger (low-power adv when
                // worn), and it has a single BLE link — a phone running the official
                // app holds it, leaving nothing to discover.
                status = "couldn't connect (\(error)) — put the ring on its charger and " +
                    "turn off Bluetooth on the phone with the official Oura app"
                continue
            }
            dlog("sync", "BLE link ready — creating RingSession + inbound-frame pump")

            let s = RingSession(writer: RingWriter(t))
            session = s
            pump?.cancel()
            pump = Task { for await frame in t.notifications { s.pushFrame(data: frame) } }

            status = "syncing…"
            dlog("sync", "starting FFI sync() — authenticate, app stream, then event drain")
            do {
                let progress = SyncProgressBridge { [weak self] stage, bytesLeft, events in
                    self?.showProgress(stage: stage, bytesLeft: bytesLeft, events: events)
                }
                let report = try await s.sync(dbPath: DB.url.path, keyHex: key, progress: progress)
                Keychain.saveKey(key)
                lastReport = report
                dlog("sync", "OK — serial=\(report.serial) inserted=\(report.inserted) events=\(report.eventsSynced) cursor=\(report.nextCursor)")
                status = "synced — \(report.inserted) new events from \(report.serial)"
                return
            } catch {
                // the Rust layer packs the diagnostic detail (auth state, missing
                // summary, cursor) into this message — log it verbatim.
                dlog("sync", "attempt \(attempt) FAILED: \(error)")
                pump?.cancel()
                pump = nil
                t.disconnect() // release the (possibly half-dead) link before retrying
                if Self.isAuthenticationFailure(error) {
                    status = "auth failed — this key was rejected by the ring; paste the key exported from the phone that onboarded this exact ring"
                    dlog("sync", "not retrying: auth rejection is deterministic")
                    return
                }
                status = "sync interrupted: \(error)"
            }
        }
        status = "sync failed after \(maxAttempts) attempts — progress is saved, " +
            "run sync again to resume (\(status))"
        dlog("sync", "giving up after \(maxAttempts) attempts — cursor is checkpointed, next sync resumes")
    }

    /// Render Rust-side progress into the status line.
    private func showProgress(stage: String, bytesLeft: UInt64, events: UInt32) {
        dlog("progress", "stage=\(stage) bytesLeft=\(bytesLeft) events=\(events)")
        switch stage {
        case "auth":
            status = "authenticating…"
        case "setup":
            status = "configuring ring…"
        case "rebase":
            status = "ring clock reset detected — recovering history…"
            dlog("sync", "saved cursor is absent on ring — rebasing to the new boot epoch")
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
                status = "syncing…"
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
