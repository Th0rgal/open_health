import Foundation
import UIKit

/// One owner of the database at a time. No Swift actor blocks on SQLite or Torch.
actor WorkGate {
    static let shared = WorkGate()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if !held { held = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { held = false }
        else { waiters.removeFirst().resume() }
    }
}

/// A generation token follows work onto its serial worker thread and cache queue.
final class AnalysisRun: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    let id = UUID().uuidString
    private let deadline: TimeInterval
    init(timeout: TimeInterval = 180) {
        deadline = ProcessInfo.processInfo.systemUptime + timeout
    }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped || ProcessInfo.processInfo.systemUptime >= deadline }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    static var current: AnalysisRun? { Thread.current.threadDictionary["oura.analysis"] as? AnalysisRun }
    static var cancelled: Bool { current?.isCancelled ?? false }
    static func check() throws { if cancelled { throw CancellationError() } }
    func perform<T>(_ body: () -> T) -> T {
        Thread.current.threadDictionary["oura.analysis"] = self
        defer { Thread.current.threadDictionary.removeObject(forKey: "oura.analysis") }
        return body()
    }
}

@MainActor
final class WorkCoordinator {
    static let shared = WorkCoordinator()
    var available: Bool { UIApplication.shared.applicationState == .active && UIApplication.shared.isProtectedDataAvailable }
    private var analysis: AnalysisRun?
    private var observers: [NSObjectProtocol] = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private init() {
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.protectedDataWillBecomeUnavailableNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    guard let run = self.analysis else { return }
                    self.beginCleanup()
                    run.cancel()
                }
            })
        }
    }
    func finishAnalysis(_ run: AnalysisRun) {
        if analysis === run { analysis = nil }
        endCleanup()
    }
    func invalidateAnalysis() { analysis?.cancel() }
    func newAnalysis() -> AnalysisRun {
        analysis?.cancel()
        let run = AnalysisRun(); analysis = run
        return run
    }
    func beginCleanup() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "finish-ring-checkpoint") {
            Task { @MainActor in self.endCleanup() }
        }
    }
    func endCleanup() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid
        }
    }
}
