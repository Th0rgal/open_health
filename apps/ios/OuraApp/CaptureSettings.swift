import SwiftUI

/// The ring's capture modes (which measurements it records on its own), read from the ring
/// and changeable here. Reading writes nothing; applying sets only the features whose switch
/// was changed. Needs the ring in range and no sync running.
struct CaptureSettingsCard: View {
    @ObservedObject var ring: RingSync
    @State private var features: [CaptureFeature] = []
    @State private var wanted: [UInt8: Bool] = [:]
    @State private var working = false
    @State private var message: String?

    private func isOn(_ f: CaptureFeature) -> Bool { (f.mode ?? 0) != 0 }

    /// Exercise heart rate depends on Step motion: the ring only accepts it once Step motion is
    /// on, so the switch stays locked until Step motion is applied and read back as on.
    private func blockedByStepMotion(_ f: CaptureFeature) -> Bool {
        guard f.id == CaptureNeed.exerciseHR.featureId, !isOn(f) else { return false }
        return !(features.first { $0.id == CaptureNeed.stepMotion.featureId }.map(isOn) ?? false)
    }

    private var changes: [CaptureChange] {
        features.compactMap { f in
            guard f.mode != nil, let want = wanted[f.id], want != isOn(f) else { return nil }
            return CaptureChange(id: f.id, mode: want ? 1 : 0)
        }
    }

    var body: some View {
        Card(title: "Ring capture", icon: "dot.radiowaves.left.and.right",
             note: "What the ring records on its own between syncs. Read the ring first, change the switches, then apply. Turning a measurement off stops the ring from recording it; data already saved stays.") {
            if features.isEmpty {
                row("Not read yet")
            }
            ForEach(features, id: \.id) { f in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.name).font(Obs.sans(13)).foregroundStyle(Obs.ink)
                        Text(blockedByStepMotion(f)
                             ? "\(CaptureNeed.stepMotion.featureName) needs to be activated and applied first."
                             : modeText(f))
                            .font(Obs.sans(11)).foregroundStyle(Obs.muted)
                    }
                    Spacer(minLength: 12)
                    Toggle("", isOn: Binding(
                        get: { wanted[f.id] ?? isOn(f) },
                        set: { wanted[f.id] = $0 }))
                        .labelsHidden()
                        .disabled(f.mode == nil || working || blockedByStepMotion(f))
                }
                .padding(.vertical, 10)
            }
            HStack(spacing: 12) {
                Button { Task { await run(nil) } } label: {
                    Text(features.isEmpty ? "Read from ring" : "Read again").font(Obs.sans(13)).foregroundStyle(Obs.ink)
                }
                .disabled(working)
                Spacer()
                Button { Task { await run(changes) } } label: {
                    Text("Apply\(changes.isEmpty ? "" : " (\(changes.count))")").font(Obs.sans(13, .semibold)).foregroundStyle(Obs.ink)
                }
                .disabled(working || changes.isEmpty)
                .opacity(changes.isEmpty ? 0.4 : 1)
            }
            .padding(.vertical, 12)
            if working {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("talking to the ring").font(Obs.sans(11)).foregroundStyle(Obs.ink2)
                }
                .padding(.bottom, 10)
            } else if let message {
                Text(message).font(Obs.sans(11)).foregroundStyle(Obs.ink2).padding(.bottom, 10)
            }
        }
    }

    private func row(_ text: String) -> some View {
        Text(text).font(Obs.sans(12)).foregroundStyle(Obs.ink2).padding(.vertical, 12)
    }

    private func modeText(_ f: CaptureFeature) -> String {
        switch f.mode {
        case .none: return "not reported"
        case .some(0): return "off"
        case .some(1): return "automatic"
        case .some(2): return "on request"
        case .some(3): return "live"
        case .some(let m): return "mode \(m)"
        }
    }

    private func run(_ apply: [CaptureChange]?) async {
        working = true
        message = nil
        let outcome = await ring.captureSettings(applying: apply)
        working = false
        switch outcome {
        case .features(let list):
            features = list
            wanted = [:]
            message = apply == nil ? "Read from the ring." : "Applied. The ring reports the modes above."
        case .failed(let text):
            message = text
        }
    }
}
