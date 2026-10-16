import SwiftUI

// Live heart rate: the widget on Today that asks the ring for beats for a minute or so,
// plots them as they arrive and summarizes the measurement. The ring has one BLE link,
// so `RingSync` owns the connection and refuses to start during a sync.
// SIBLING CLIENT: the web dashboard has the same measurement (`POST /api/live-hr`).

struct LiveBeat: Identifiable {
    let id: Int
    let t: Double       // seconds since streaming began
    let bpm: Int
    let ibiMs: Int
}

@MainActor
final class LiveHeartRate: ObservableObject {
    enum Phase: Equatable { case idle, connecting, streaming, done, failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var beats: [LiveBeat] = []
    @Published private(set) var elapsed: Double = 0
    @Published var duration: Int = 60
    @Published private(set) var stopped = false

    private var startedAt: Date?
    private var ticker: Task<Void, Never>?

    var isRunning: Bool { phase == .connecting || phase == .streaming }

    /// Median of the last five beats: steadier than one inter-beat interval.
    var current: Int? {
        let recent = beats.suffix(5).map(\.bpm).sorted()
        return recent.isEmpty ? nil : recent[recent.count / 2]
    }

    struct Summary {
        let average: Int, low: Int, high: Int, count: Int
        /// RMSSD over the measurement's inter-beat intervals (ms), when there are enough.
        let rmssd: Double?
    }

    var summary: Summary? {
        guard beats.count >= 3 else { return nil }
        let ibis = beats.map(\.ibiMs)
        let meanIBI = Double(ibis.reduce(0, +)) / Double(ibis.count)
        // beats the ring flags valid can still be ectopic; the extremes use the 5-beat median
        let smooth = beats.indices.map { i -> Int in
            let w = beats[max(0, i - 4)...i].map(\.bpm).sorted()
            return w[w.count / 2]
        }
        return Summary(average: Int((60_000 / meanIBI).rounded()), low: smooth.min() ?? 0, high: smooth.max() ?? 0,
                       count: beats.count,
                       rmssd: ibis.count >= 10 ? rmssd(ibiMs: ibis.map { UInt16(clamping: $0) }) : nil)
    }

    func start(ring: RingSync) {
        guard !isRunning else { return }
        beats = []; elapsed = 0; stopped = false; startedAt = nil
        phase = .connecting
        let seconds = UInt32(duration)
        Task {
            let outcome = await ring.liveHeartRate(seconds: seconds, onStage: { [weak self] stage in
                guard let self, stage == "streaming" else { return }
                self.startedAt = Date()
                self.phase = .streaming
                self.startTicker()
            }, onSample: { [weak self] bpm, ibi in
                guard let self, let started = self.startedAt else { return }
                self.beats.append(LiveBeat(id: self.beats.count, t: Date().timeIntervalSince(started), bpm: bpm, ibiMs: ibi))
            })
            ticker?.cancel()
            switch outcome {
            case .finished: phase = .done
            case .stopped: stopped = true; phase = .done
            case .failed(let message): phase = .failed(message)
            }
        }
    }

    func stop(ring: RingSync) { ring.stopLiveHeartRate() }

    /// QA hook for `-liveDemo`: a finished measurement of synthetic beats, so the widget
    /// can be captured without a ring.
    func demo() {
        var t = 0.0
        beats = (0..<60).map { i in
            let ibi = Int(850 + 90 * sin(Double(i) / 6) + Double((i * 37) % 23))
            t += Double(ibi) / 1000
            return LiveBeat(id: i, t: t, bpm: 60_000 / ibi, ibiMs: ibi)
        }
        duration = 60; stopped = false; phase = .done
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let started = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(started)
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }
}

struct LiveHeartRateCard: View {
    @ObservedObject var live: LiveHeartRate
    @ObservedObject var ring: RingSync

    private var canStart: Bool { !ring.busy && !ring.liveActive }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: "heart.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Obs.alert)
                Text("Live heart rate").font(Obs.sans(11, .medium)).foregroundStyle(Obs.muted)
                Spacer()
                actionButton
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Figure(value: live.current.map(String.init) ?? "–", unit: "bpm", size: 38,
                       color: live.phase == .streaming ? Obs.ink : Obs.ink2)
                Spacer()
                Text(statusLine).font(Obs.sans(11)).foregroundStyle(statusColor).multilineTextAlignment(.trailing)
            }
            if !live.isRunning {
                HStack(spacing: 6) {
                    ForEach([30, 60, 120], id: \.self) { s in
                        Button { live.duration = s } label: {
                            Text(s < 60 ? "\(s)s" : "\(s / 60)m").font(Obs.sans(11, live.duration == s ? .medium : .regular))
                                .foregroundStyle(live.duration == s ? Obs.paper : Obs.ink2)
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .background(live.duration == s ? Obs.ink : Obs.paper.opacity(0.7), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
            }
            if live.beats.count > 1 {
                LiveChart(beats: live.beats, duration: Double(live.duration), running: live.phase == .streaming)
                    .frame(height: 96)
            }
            if live.phase == .streaming {
                ProgressView(value: min(live.elapsed, Double(live.duration)), total: Double(live.duration))
                    .tint(Obs.alert)
            }
            if live.phase == .done, let s = live.summary {
                HStack(alignment: .top, spacing: 8) {
                    StatCell(label: "Average", value: "\(s.average)", unit: "bpm")
                    StatCell(label: "Low", value: "\(s.low)")
                    StatCell(label: "High", value: "\(s.high)")
                    StatCell(label: "HRV", value: s.rmssd.map { String(format: "%.0f", $0) } ?? "–", unit: s.rmssd == nil ? "" : "ms")
                }
            }
        }
        .surface()
    }

    @ViewBuilder private var actionButton: some View {
        if live.isRunning {
            Button { live.stop(ring: ring) } label: {
                Label("Stop", systemImage: "stop.fill").font(Obs.sans(12, .medium))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Obs.alert, in: Capsule()).foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        } else {
            Button { live.start(ring: ring) } label: {
                Label(live.phase == .done || live.phase != .idle ? "Again" : "Start", systemImage: "play.fill")
                    .font(Obs.sans(12, .medium))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Obs.ink, in: Capsule()).foregroundStyle(Obs.paper)
                    .opacity(canStart ? 1 : 0.35)
            }
            .buttonStyle(.plain).disabled(!canStart)
        }
    }

    private var statusLine: String {
        switch live.phase {
        case .idle: return ring.busy ? "Ring is syncing" : "Ring on finger"
        case .connecting: return "Connecting…"
        case .streaming:
            let left = max(0, Int((Double(live.duration) - live.elapsed).rounded(.up)))
            return live.beats.isEmpty && live.elapsed > 8 ? "No beats yet. Wear the ring snugly." : "\(left) s left"
        case .done: return live.stopped ? "Stopped · \(live.beats.count) beats" : "\(live.beats.count) beats"
        case .failed(let message): return message
        }
    }
    private var statusColor: Color {
        if case .failed = live.phase { return Obs.bad }
        return Obs.muted
    }
}

/// Beats against time, auto-scaled, with the 5-beat median as the line.
private struct LiveChart: View {
    let beats: [LiveBeat]
    let duration: Double
    let running: Bool
    var body: some View {
        Canvas { ctx, size in
            let smooth = beats.indices.map { i -> Double in
                let w = beats[max(0, i - 4)...i].map(\.bpm).sorted()
                return Double(w[w.count / 2])
            }
            guard let lo = smooth.min(), let hi = smooth.max() else { return }
            let pad = max(4, (hi - lo) * 0.2)
            let (yLo, yHi) = (lo - pad, hi + pad)
            let plotW = size.width - 28
            let t1 = running ? max(duration, beats.last?.t ?? 0) : max(beats.last?.t ?? 1, 1)
            func pt(_ i: Int) -> CGPoint {
                CGPoint(x: plotW * CGFloat(beats[i].t / t1),
                        y: size.height * (1 - CGFloat((smooth[i] - yLo) / (yHi - yLo))))
            }
            for v in [yHi, yLo] {
                ctx.draw(Text(String(format: "%.0f", v)).font(Obs.sans(11)).foregroundColor(Obs.muted),
                         at: CGPoint(x: size.width, y: size.height * (1 - CGFloat((v - yLo) / (yHi - yLo)))),
                         anchor: v == yHi ? .topTrailing : .bottomTrailing)
            }
            ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: size.height - 0.5)); $0.addLine(to: CGPoint(x: plotW, y: size.height - 0.5)) },
                       with: .color(Obs.rule), lineWidth: 0.6)
            var line = Path()
            for i in beats.indices { i == 0 ? line.move(to: pt(0)) : line.addLine(to: pt(i)) }
            var area = line
            area.addLine(to: CGPoint(x: pt(beats.count - 1).x, y: size.height)); area.addLine(to: CGPoint(x: pt(0).x, y: size.height))
            ctx.fill(area, with: .linearGradient(Gradient(colors: [Obs.alert.opacity(0.22), Obs.alert.opacity(0)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(Obs.alert), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            let last = pt(beats.count - 1)
            ctx.fill(Path(ellipseIn: CGRect(x: last.x - 3.5, y: last.y - 3.5, width: 7, height: 7)), with: .color(Obs.alert))
        }
        .accessibilityLabel("Live heart rate, \(beats.count) beats")
    }
}
