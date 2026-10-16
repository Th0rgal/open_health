import SwiftUI

/// Publishes the on-device models' per-unit progress ("detecting activity ·
/// day 3/33") for the header pill. Mirrors SyncProgressBridge's pattern: the
/// model runners report from background queues via `sink`, which hops to the
/// MainActor; a generation stamp drops reports from superseded loads (the same
/// discipline as RootView's loadGeneration guard).
@MainActor
final class ModelProgress: ObservableObject {
    @Published private(set) var label: String?
    /// The symptom radar is being computed. It has its own widget and view and does not use `label`.
    @Published private(set) var radarActive = false
    static let radarLabel = "Analyzing symptom radar"
    private var generation = 0
    private var watchdog: Task<Void, Never>?

    func begin(_ generation: Int) {
        self.generation = generation
        label = nil
        radarActive = false
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 180_000_000_000) } catch { return }
            guard let self, self.generation == generation else { return }
            self.label = "Analysis is taking too long. Results already saved remain available."
        }
    }

    func report(_ generation: Int, _ text: String?) {
        guard generation == self.generation else { return }
        if text == Self.radarLabel { radarActive = true; label = nil; return }
        radarActive = false
        label = text
        if text == nil || text == "Analysis paused" { watchdog?.cancel(); watchdog = nil }
    }

    /// A progress closure bound to one load generation, safe to call from any
    /// queue. Concurrent models write into one line last-writer-wins; each unit
    /// takes seconds, so the pill stays legible.
    nonisolated func sink(_ generation: Int) -> @Sendable (String) -> Void {
        { text in Task { @MainActor in self.report(generation, text) } }
    }
}

private struct RadarAnalyzingKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var radarAnalyzing: Bool {
        get { self[RadarAnalyzingKey.self] }
        set { self[RadarAnalyzingKey.self] = newValue }
    }
}
