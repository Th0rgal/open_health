import Foundation
import SwiftUI

/// Hourly heart-rate bars — the day-shaped HR view behind the dashboard's heart
/// rate cell.
///
/// The nightly RHR trend says how the last few weeks of sleep went; it says nothing
/// about the day you are in. One bar per local-clock hour does: it spans that hour's
/// 5th-to-95th percentile band, with a tick at the median. Percentiles, not raw
/// extremes — a single misdetected beat is not "your peak heart rate", and the ring's
/// beat streams do emit them. The true min/max ride along for the touch readout. No
/// open/close — that is a stock-chart habit, and a heart rate has no opening price.
/// Aggregation happens in Rust (`oura-summary::hourly_hr`) because it walks the whole
/// event table — the same read the summary does, not a second decoding of the
/// database in Swift.
enum HourlyHR {
    struct Bar: Identifiable {
        let unix: Double        // UTC start of the local hour
        let ymd: String
        let hour: Int
        let low: Double         // 5th percentile of the hour's beats
        let high: Double        // 95th percentile
        let median: Double
        let min: Double         // true extremes, for the readout only
        let max: Double
        let count: Int
        var id: Double { unix }
    }

    struct Reading {
        let bpm: Double
        let unix: Double
    }

    struct Result {
        var bars: [Bar] = []
        var latest: Reading?
        var error: String?
    }

    /// Whole hours from UTC — the offset the whole stack (web `--tz-offset`, the model
    /// runners, this FFI) speaks. Matches `Core.base()`.
    static var tzOffset: Int64 {
        Int64((Double(TimeZone.current.secondsFromGMT()) / 3600).rounded())
    }

    static func load(days: UInt32) -> Result {
        let json = hourlyHrJson(dbPath: DB.readPath(), tzOffset: tzOffset, days: days)
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return Result(error: "unreadable response") }
        if let err = root["error"] as? String { return Result(error: err) }

        let bars = (root["hours"] as? [[String: Any]] ?? []).compactMap { row -> Bar? in
            guard let unix = (row["unix"] as? NSNumber)?.doubleValue,
                  let low = (row["low"] as? NSNumber)?.doubleValue,
                  let high = (row["high"] as? NSNumber)?.doubleValue
            else { return nil }
            return Bar(unix: unix,
                       ymd: row["ymd"] as? String ?? "",
                       hour: (row["hour"] as? NSNumber)?.intValue ?? 0,
                       low: low, high: high,
                       median: (row["median"] as? NSNumber)?.doubleValue ?? (low + high) / 2,
                       min: (row["min"] as? NSNumber)?.doubleValue ?? low,
                       max: (row["max"] as? NSNumber)?.doubleValue ?? high,
                       count: (row["count"] as? NSNumber)?.intValue ?? 0)
        }
        let latest = (root["latest"] as? [String: Any]).flatMap { l -> Reading? in
            guard let bpm = (l["bpm"] as? NSNumber)?.doubleValue,
                  let unix = (l["unix"] as? NSNumber)?.doubleValue else { return nil }
            return Reading(bpm: bpm, unix: unix)
        }
        return Result(bars: bars, latest: latest)
    }
}

enum HourlyWindow: String, CaseIterable {
    case h24 = "24h", h48 = "48h", d7 = "7d"
    /// Hour slots drawn, gaps included — the axis is real time, so a night the ring
    /// spent on the charger reads as a gap, not as a shorter chart.
    var hours: Int {
        switch self {
        case .h24: return 24
        case .h48: return 48
        case .d7: return 24 * 7
        }
    }
    /// What to ask the FFI for — one extra day so switching windows never refetches.
    var days: UInt32 { self == .d7 ? 8 : 2 }
}

/// The hourly panel: current reading, the range bars, and the window's extremes.
struct HourlyHeartRateSection: View {
    @State private var window: HourlyWindow = .h24
    @State private var result = HourlyHR.Result()
    @State private var loading = true
    @State private var selected: HourlyHR.Bar?

    /// The bars inside the chosen window, anchored on the newest hour that has
    /// data — a ring that last synced yesterday still fills the chart.
    private var visible: [HourlyHR.Bar] {
        guard let newest = result.bars.last?.unix else { return [] }
        let cut = newest - Double((window.hours - 1) * 3600)
        return result.bars.filter { $0.unix >= cut }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                ObsTag("hourly", icon: "chart.bar.fill")
                Spacer()
                if loading { ProgressView().controlSize(.mini).tint(Obs.ink) }
            }
            Picker("Window", selection: $window) {
                ForEach(HourlyWindow.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: window) { _, _ in selected = nil; reload() }

            if let error = result.error {
                Text(error).font(Obs.sans(12)).foregroundStyle(Obs.bad)
                    .fixedSize(horizontal: false, vertical: true)
            } else if visible.isEmpty {
                Text(loading ? "Reading the ring database…"
                             : "No beats stored for this window yet. Sync the ring.")
                    .font(Obs.sans(12)).foregroundStyle(Obs.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                readout
                HourlyRangeChart(bars: visible, window: window, selected: $selected)
                    .frame(height: 210)
                axis
                stats
            }
        }
        .obsCard()
        .task { reload() }
    }

    /// Either the hour you are touching, or the latest reading when nothing is held.
    @ViewBuilder private var readout: some View {
        if let bar = selected {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int(bar.low.rounded()))–\(Int(bar.high.rounded()))")
                        .font(Obs.sans(30, .medium)).foregroundStyle(Obs.ink).monospacedDigit()
                    Text("bpm").font(Obs.sans(13)).foregroundStyle(Obs.ink2)
                }
                Text("\(Self.dayLabel(bar)) · \(String(format: "%02d:00", bar.hour)) · median \(Int(bar.median.rounded())) · range \(Int(bar.min.rounded()))–\(Int(bar.max.rounded())) · \(bar.count) beats")
                    .font(Obs.sans(11)).foregroundStyle(Obs.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let latest = result.latest {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int(latest.bpm.rounded()))")
                        .font(Obs.sans(30, .medium)).foregroundStyle(Obs.ink).monospacedDigit()
                    Text("bpm").font(Obs.sans(13)).foregroundStyle(Obs.ink2)
                    Text("latest").font(Obs.sans(11)).foregroundStyle(Obs.muted)
                }
                Text(Self.stamp(latest.unix)).font(Obs.sans(11)).foregroundStyle(Obs.muted)
            }
        }
    }

    private var axis: some View {
        HStack {
            if let first = visible.first {
                Text(Self.dayLabel(first) + " " + String(format: "%02d:00", first.hour))
                    .font(Obs.sans(11)).foregroundStyle(Obs.ink2)
            }
            Spacer()
            Text("touch a bar for that hour").font(Obs.sans(11)).foregroundStyle(Obs.muted)
            Spacer()
            if let last = visible.last {
                Text(Self.dayLabel(last) + " " + String(format: "%02d:00", last.hour))
                    .font(Obs.sans(11)).foregroundStyle(Obs.ink2)
            }
        }
    }

    private var stats: some View {
        let lows = visible.map(\.low), highs = visible.map(\.high)
        let beats = visible.reduce(0) { $0 + $1.count }
        let weighted = visible.reduce(0.0) { $0 + $1.median * Double($1.count) }
        return VStack(spacing: 10) {
            if let lo = lows.min() { ObsStat(label: "quietest hour", value: "\(Int(lo.rounded())) bpm") }
            if let hi = highs.max() { ObsStat(label: "busiest hour", value: "\(Int(hi.rounded())) bpm") }
            if beats > 0 { ObsStat(label: "typical", value: "\(Int((weighted / Double(beats)).rounded())) bpm") }
            ObsStat(label: "hours with data", value: "\(visible.count)/\(window.hours)")
        }
        .padding(.top, 2)
    }

    private func reload() {
        loading = true
        let days = window.days
        Task.detached(priority: .userInitiated) {
            let out = HourlyHR.load(days: days)
            await MainActor.run { result = out; loading = false }
        }
    }

    private static let stampFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d HH:mm"; return f
    }()
    static func stamp(_ unix: Double) -> String {
        stampFmt.string(from: Date(timeIntervalSince1970: unix))
    }
    static func dayLabel(_ bar: HourlyHR.Bar) -> String { String(bar.ymd.suffix(5)) }
}

/// Range bars on a real-time axis: every hour of the window gets a slot, so a gap in
/// the data is a gap in the chart. Each bar spans that hour's 5th–95th percentile band,
/// with a tick at the median — where the hour actually sat, undisturbed by one bad beat.
private struct HourlyRangeChart: View {
    let bars: [HourlyHR.Bar]
    let window: HourlyWindow
    @Binding var selected: HourlyHR.Bar?

    /// Slot start times: the newest hour anchors the right edge and the window runs
    /// backwards from it, one slot per hour whether or not it has beats.
    private var slots: [Double] {
        guard let newest = bars.last?.unix else { return [] }
        return (0..<window.hours).map { newest - Double((window.hours - 1 - $0) * 3600) }.sorted()
    }

    var body: some View {
        let byHour = Dictionary(uniqueKeysWithValues: bars.map { ($0.unix, $0) })
        let lo = bars.map(\.low).min() ?? 40
        let hi = bars.map(\.high).max() ?? 120
        let pad = max(hi - lo, 1) * 0.1
        let domainLo = lo - pad, domainHi = hi + pad
        let span = max(domainHi - domainLo, 1e-6)
        let slots = slots

        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(Int(domainHi.rounded()))").font(Obs.sans(11)).foregroundStyle(Obs.muted)
                Spacer()
                Text("\(Int(((domainLo + domainHi) / 2).rounded()))").font(Obs.sans(11)).foregroundStyle(Obs.muted)
                Spacer()
                Text("\(Int(domainLo.rounded()))").font(Obs.sans(11)).foregroundStyle(Obs.muted)
            }
            .frame(width: 30)

            GeometryReader { geo in
                let width = geo.size.width
                let slotWidth = width / CGFloat(max(slots.count, 1))
                Canvas { ctx, size in
                    func y(_ v: Double) -> CGFloat {
                        size.height * (1 - CGFloat((v - domainLo) / span))
                    }
                    for fraction in [0.0, 0.5, 1.0] {
                        var grid = Path()
                        let gy = size.height * CGFloat(fraction)
                        grid.move(to: CGPoint(x: 0, y: gy))
                        grid.addLine(to: CGPoint(x: size.width, y: gy))
                        ctx.stroke(grid, with: .color(Obs.trace.opacity(0.4)), lineWidth: 0.5)
                    }
                    // midnight rules, so a multi-day window reads as days
                    for (i, start) in slots.enumerated() where Int(start.rounded()) % 86_400 == midnightOffset {
                        var rule = Path()
                        let x = slotWidth * CGFloat(i)
                        rule.move(to: CGPoint(x: x, y: 0))
                        rule.addLine(to: CGPoint(x: x, y: size.height))
                        ctx.stroke(rule, with: .color(Obs.trace), style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
                    }

                    let barWidth = max(1.5, slotWidth * 0.62)
                    for (i, start) in slots.enumerated() {
                        guard let bar = byHour[start] else { continue }
                        let cx = slotWidth * (CGFloat(i) + 0.5)
                        let isSelected = selected?.unix == start
                        let tint = isSelected ? Obs.ink : Obs.chart

                        let top = y(bar.high)
                        let bottom = y(bar.low)
                        let rect = CGRect(x: cx - barWidth / 2, y: top,
                                          width: barWidth, height: max(1.4, bottom - top))
                        let shape = Path(roundedRect: rect, cornerRadius: min(2.5, barWidth / 2))
                        ctx.fill(shape, with: .color(tint.opacity(isSelected ? 0.55 : 0.32)))

                        // the median, where an hour spent most of its beats
                        var tick = Path()
                        let my = y(bar.median)
                        tick.move(to: CGPoint(x: cx - barWidth / 2, y: my))
                        tick.addLine(to: CGPoint(x: cx + barWidth / 2, y: my))
                        ctx.stroke(tick, with: .color(tint), lineWidth: isSelected ? 2 : 1.4)
                    }
                }
                .contentShape(Rectangle())
                .overlay(HorizontalScrub(onChange: { x in
                    let i = Int(x / max(slotWidth, 0.001))
                    guard slots.indices.contains(i) else { return }
                    selected = byHour[slots[i]]
                }))
                .accessibilityLabel("Hourly heart rate band, \(bars.count) hours with data")
            }
        }
    }

    /// A local-clock midnight is an exact multiple of a day once the tz offset is
    /// removed; the FFI keys buckets in UTC, so shift before testing.
    private var midnightOffset: Int {
        let tz = Int(HourlyHR.tzOffset) * 3600
        return ((-tz) % 86_400 + 86_400) % 86_400
    }
}
