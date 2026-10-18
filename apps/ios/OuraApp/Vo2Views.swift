import SwiftUI

/// VO2 max over time: the estimates from 6-minute walks, with the formula estimate from age, sex and
/// weight as the reference.
struct Vo2DetailView: View {
    let s: Summary
    @ObservedObject private var store = Vo2Store.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int?

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current; return f
    }()
    private static let shortFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM, HH:mm"; f.timeZone = .current; return f
    }()

    private var readings: [Vo2Reading] { store.file.readings }
    private var points: [DatedValue] {
        // one point per day: the day's highest reading
        var best: [String: Double] = [:]
        for r in readings {
            let day = Self.dayFormat.string(from: Date(timeIntervalSince1970: r.atUnix))
            best[day] = max(best[day] ?? 0, r.vo2)
        }
        return best.keys.sorted().map { DatedValue(date: $0, value: best[$0]!) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Obs.canvas
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        if points.count > 1 {
                            TrendChart(points: points, style: .line, tint: Obs.activityTint,
                                       reference: s.fitness?.vo2max, height: 170, decimals: 0,
                                       axis: points.map(\.date), selection: $selection)
                            Text("Dashed line: the estimate from age, sex and weight, ml/kg/min")
                                .font(Obs.sans(11)).foregroundStyle(Obs.muted)
                        }
                        if !readings.isEmpty { list }
                        explanation
                    }
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 32)
                }
            }
            .navigationTitle("VO₂ max")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    @ViewBuilder private var header: some View {
        if let latest = readings.last {
            VStack(alignment: .leading, spacing: 4) {
                Figure(value: String(format: "%.0f", latest.vo2), unit: "ml/kg/min", size: 34)
                Text("From a 6-minute walk, \(Self.shortFormat.string(from: Date(timeIntervalSince1970: latest.atUnix - 360)))")
                    .font(Obs.sans(11)).foregroundStyle(Obs.muted)
            }
        } else if let formula = s.fitness?.vo2max {
            VStack(alignment: .leading, spacing: 4) {
                Figure(value: String(format: "%.1f", formula), unit: "ml/kg/min", size: 34)
                Text("Estimated from age, sex and weight. No walk has measured it yet.")
                    .font(Obs.sans(11)).foregroundStyle(Obs.muted)
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Walks", icon: "figure.walk", tint: Obs.activityTint)
            VStack(spacing: 0) {
                ForEach(Array(readings.reversed().enumerated()), id: \.element.id) { i, r in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.shortFormat.string(from: Date(timeIntervalSince1970: r.atUnix - 360)))
                                .font(Obs.sans(12)).foregroundStyle(Obs.ink)
                            Text("\(Int(r.distanceM)) m in 6 min, heart rate \(Int(r.hrBpm)), \(r.source == "gps" ? "GPS route" : "phone step counter")")
                                .font(Obs.sans(11)).foregroundStyle(Obs.muted)
                        }
                        Spacer(minLength: 12)
                        Text(String(format: "%.0f", r.vo2)).font(Obs.sans(15, .medium)).foregroundStyle(Obs.ink).monospacedDigit()
                    }
                    .padding(.vertical, 9)
                    if i < readings.count - 1 { Rectangle().fill(Obs.rule).frame(height: 0.6) }
                }
            }
            .surface(padding: 14)
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How it is measured").font(Obs.sans(12, .medium)).foregroundStyle(Obs.ink)
            Text("The estimate comes from the distance of a 6-minute walk and your heart rate in its last minute. Start a walk under Activities and walk briskly for six minutes: the phone records the route with GPS while the exercise runs. Brisk walks the ring detected on their own count too, using the distance the iPhone counted for them, when the best six minutes cover at least 480 m. Slower walks are skipped because they would read too low.")
                .font(Obs.sans(11)).foregroundStyle(Obs.muted).fixedSize(horizontal: false, vertical: true)
            Text("Heart rate comes from the ring, so a reading appears after the next sync. It needs sex set to female or male, and age, height and weight, in Profile.")
                .font(Obs.sans(11)).foregroundStyle(Obs.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}
