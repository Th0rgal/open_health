import Foundation
import Combine
import Darwin
import MetricKit
import os
import UIKit

@_silgen_name("crashcatch_install")
func crashcatch_install(_ fd: Int32)

/// On-disk diagnostics that survive a crash: the live `dlog` transcript is
/// appended to a session file, leftover files from a killed launch become
/// crash reports, and uncaught exceptions / abort signals write a backtrace
/// into that same file. The sync screen lists previous incidents.
final class DiagStore: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = DiagStore()

    struct Incident: Identifiable {
        let id: URL
        let date: Date
        let kind: String
        let title: String
        let preview: String
        var body: String { (try? String(contentsOf: id, encoding: .utf8)) ?? "" }
    }

    @Published private(set) var incidents: [Incident] = []
    @Published private(set) var sessions: [Incident] = []

    private let queue = DispatchQueue(label: "md.thomas.openoura.diag", qos: .utility)
    private var file: FileHandle?
    private var sessionURL: URL?
    private let maxSessionBytes = 2 * 1024 * 1024
    private let keepCrashes = 16
    private let keepSessions = 8
    private var bootstrapped = false

    private override init() { super.init() }

    private var root: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("crashes"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        return dir
    }

    /// Call once at process start, before any `dlog`.
    func bootstrap() {
        queue.sync {
            guard !bootstrapped else { return }
            bootstrapped = true
            let fm = FileManager.default
            let live = root.appendingPathComponent("session.log")
            if fm.fileExists(atPath: live.path) {
                let dest = root.appendingPathComponent("crashes")
                    .appendingPathComponent("abnormal-\(Self.stamp()).log")
                try? fm.moveItem(at: live, to: dest)
                let note = """
                Previous Open Oura launch ended without a clean shutdown.
                Typical causes: crash, jetsam (memory), force-quit, or the screen \
                locking mid-sync / mid-analysis. The leftover log is attached below.

                """
                if let existing = try? String(contentsOf: dest, encoding: .utf8) {
                    try? (note + existing).write(to: dest, atomically: true, encoding: .utf8)
                }
            }
            fm.createFile(atPath: live.path, contents: nil)
            sessionURL = live
            file = try? FileHandle(forWritingTo: live)
            file?.seekToEndOfFile()
            if let fd = file?.fileDescriptor {
                crashcatch_install(fd)
            }
            let header = Self.environmentHeader()
            file?.write(Data(header.utf8))
        }
        NSSetUncaughtExceptionHandler { exception in
            var lines = ["\n*** EXCEPTION ***",
                         "name: \(exception.name.rawValue)",
                         "reason: \(exception.reason ?? "")"]
            lines.append(contentsOf: exception.callStackSymbols)
            DiagStore.shared.writeCrash("exception", lines.joined(separator: "\n"))
        }
        MXMetricManager.shared.add(self)
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification,
                                               object: nil, queue: .main) { _ in
            DiagStore.shared.markCleanExit()
        }
        refreshLists()
        dlog("diag", "session started — previous crashes \(incidents.count), older sessions \(sessions.count)")
    }

    func append(_ line: String) {
        queue.async { [weak self] in
            guard let self, let file = self.file else { return }
            file.write(Data((line + "\n").utf8))
            if file.offsetInFile > UInt64(self.maxSessionBytes) {
                file.write(Data("\n(session log truncated at 2 MB)\n".utf8))
                try? file.synchronize()
            }
        }
    }

    func writeCrash(_ kind: String, _ body: String) {
        queue.sync {
            let header = "\(kind) \(Self.stamp())\n\(Self.environmentHeader())\n"
            if let file {
                file.write(Data("\n*** \(kind.uppercased()) ***\n\(body)\n".utf8))
                try? file.synchronize()
            }
            let dest = root.appendingPathComponent("crashes")
                .appendingPathComponent("\(kind)-\(Self.stamp()).log")
            try? (header + body).write(to: dest, atomically: true, encoding: .utf8)
            prune(root.appendingPathComponent("crashes"), keep: keepCrashes)
        }
        refreshLists()
    }

    func markCleanExit() {
        queue.sync {
            try? file?.synchronize()
            try? file?.close()
            file = nil
            crashcatch_install(-1)
            if let live = sessionURL {
                let dest = root.appendingPathComponent("sessions")
                    .appendingPathComponent("session-\(Self.stamp()).log")
                try? FileManager.default.moveItem(at: live, to: dest)
                prune(root.appendingPathComponent("sessions"), keep: keepSessions)
            }
            sessionURL = nil
        }
        refreshLists()
    }

    func exportAll() -> String {
        var parts = [RingDiag.shared.dump()]
        let crashes = incidents
        if !crashes.isEmpty {
            parts.append("\n\n===== previous crashes / abnormal exits (\(crashes.count)) =====")
            for item in crashes.prefix(8) {
                parts.append("\n--- \(item.title) ---\n\(item.body)")
            }
        }
        if !sessions.isEmpty {
            parts.append("\n\n===== older sessions (\(sessions.count)) =====")
            for item in sessions.prefix(3) {
                parts.append("\n--- \(item.title) ---\n\(item.body)")
            }
        }
        return parts.joined(separator: "\n")
    }

    private func refreshLists() {
        let crashes = loadFolder(root.appendingPathComponent("crashes"), kind: "crash")
        let older = loadFolder(root.appendingPathComponent("sessions"), kind: "session")
        DispatchQueue.main.async {
            self.incidents = crashes
            self.sessions = older
        }
    }

    private func loadFolder(_ dir: URL, kind: String) -> [Incident] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                 options: .skipsHiddenFiles)) ?? []
        return files.compactMap { url -> Incident? in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let preview = text.split(separator: "\n").prefix(6).joined(separator: "\n")
            let name = url.deletingPathExtension().lastPathComponent
            return Incident(id: url, date: date, kind: kind, title: name, preview: preview)
        }
        .sorted { $0.date > $1.date }
    }

    private func prune(_ dir: URL, keep: Int) {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                  options: .skipsHiddenFiles)) ?? [])
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
        for extra in files.dropFirst(keep) {
            try? fm.removeItem(at: extra)
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }

    private static func environmentHeader() -> String {
        let v = Bundle.main.infoDictionary
        let app = "\(v?["CFBundleShortVersionString"] ?? "?") (\(v?["CFBundleVersion"] ?? "?"))"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let mem = os_proc_available_memory() / 1_048_576
        return """
        Open Oura \(app)
        iOS \(os)
        launched \(Date())
        available memory \(mem) MB

        """
    }
}

extension DiagStore: MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXMetricPayload]) {}

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            if let crashes = payload.crashDiagnostics {
                for crash in crashes {
                    let text = String(data: crash.jsonRepresentation(), encoding: .utf8) ?? crash.description
                    writeCrash("metrickit-crash", text)
                }
            }
            if let hangs = payload.hangDiagnostics {
                for hang in hangs {
                    let text = String(data: hang.jsonRepresentation(), encoding: .utf8) ?? hang.description
                    writeCrash("metrickit-hang", text)
                }
            }
            if let disks = payload.diskWriteExceptionDiagnostics {
                for disk in disks {
                    let text = String(data: disk.jsonRepresentation(), encoding: .utf8) ?? disk.description
                    writeCrash("metrickit-disk", text)
                }
            }
        }
    }
}
