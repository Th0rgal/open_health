import Foundation

/// Publishes the on-device models' per-unit progress ("detecting activity ·
/// day 3/33") for the header pill. Mirrors SyncProgressBridge's pattern: the
/// model runners report from background queues via `sink`, which hops to the
/// MainActor; a generation stamp drops reports from superseded loads (the same
/// discipline as RootView's loadGeneration guard).
@MainActor
final class ModelProgress: ObservableObject {
    @Published private(set) var label: String?
    private var generation = 0

    func begin(_ generation: Int) {
        self.generation = generation
        label = nil
    }

    func report(_ generation: Int, _ text: String?) {
        guard generation == self.generation else { return }
        label = text
    }

    /// A progress closure bound to one load generation, safe to call from any
    /// queue. Concurrent models write into one line last-writer-wins; each unit
    /// takes seconds, so the pill stays legible.
    nonisolated func sink(_ generation: Int) -> @Sendable (String) -> Void {
        { text in Task { @MainActor in self.report(generation, text) } }
    }
}
