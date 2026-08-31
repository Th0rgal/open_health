import SwiftUI

// Activity type → a clean SF Symbol. Keyword-matched so the ~40 AAD behaviour labels all
// resolve to a sensible figure.* glyph; unknowns fall back to a neutral cardio symbol.
func activitySymbol(_ label: String) -> String {
    let l = label.lowercased()
    switch true {
    case l.contains("run"): return "figure.run"
    case l.contains("walk"): return "figure.walk"
    case l.contains("hik"): return "figure.hiking"
    case l.contains("cycl"), l.contains("bik"): return "figure.outdoor.cycle"
    case l.contains("swim"): return "figure.pool.swim"
    case l.contains("row"): return "figure.rower"
    case l.contains("core"): return "figure.core.training"
    case l.contains("strength"): return "figure.strengthtraining.traditional"
    case l.contains("cross train"): return "figure.cross.training"
    case l.contains("yoga"): return "figure.yoga"
    case l.contains("pilates"): return "figure.pilates"
    case l.contains("hiit"), l.contains("interval"): return "figure.highintensity.intervaltraining"
    case l.contains("elliptical"): return "figure.elliptical"
    case l.contains("box"): return "figure.boxing"
    case l.contains("martial"): return "figure.martial.arts"
    case l.contains("danc"): return "figure.dance"
    case l.contains("basketball"): return "figure.basketball"
    case l.contains("soccer"): return "figure.soccer"
    case l.contains("football"): return "figure.american.football"
    case l.contains("baseball"): return "figure.baseball"
    case l.contains("volleyball"): return "figure.volleyball"
    case l.contains("tennis"), l.contains("padel"), l.contains("badminton"): return "figure.tennis"
    case l.contains("hockey"): return "figure.hockey"
    case l.contains("surf"): return "figure.surfing"
    case l.contains("snowboard"): return "figure.snowboarding"
    case l.contains("ski"): return "figure.skiing.crosscountry"
    case l.contains("horse"): return "figure.equestrian.sports"
    case l.contains("stretch"): return "figure.flexibility"
    case l.contains("climb"): return "figure.climbing"
    case l.contains("golf"): return "figure.golf"
    case l.contains("meditat"): return "figure.mind.and.body"
    case l.contains("fitness"): return "figure.strengthtraining.functional"
    default: return "figure.mixed.cardio"
    }
}

// Capitalise an activity label's first letter for display.
func actLabel(_ s: String) -> String { s.isEmpty ? s : s.prefix(1).uppercased() + s.dropFirst() }

// A labelled activity/workout row: clean SF Symbol + name, duration + start time.
struct SessionRow: View {
    let label: String
    let durationMin: Int
    let startHM: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: activitySymbol(label)).font(.system(size: 14))
                .foregroundStyle(Obs.ink2).frame(width: 20)
            Text(actLabel(label)).font(Obs.mono(13, .medium)).foregroundStyle(Obs.ink)
            Spacer()
            Text("\(durationMin) min").font(Obs.mono(12)).foregroundStyle(Obs.ink2)
            Text(startHM).font(Obs.mono(11)).foregroundStyle(Obs.muted)
        }
    }
}

// ── reusable readout + chart components ───────────────────────────────────────
struct Sparkline: View {
    let series: [Double]
    var accent: Color = Obs.chart
    var baseline: Double? = nil

    var body: some View {
        Canvas { ctx, size in
            let values = series.filter(\.isFinite)
            guard values.count > 1 else { return }
            let lo = values.min()!, hi = values.max()!
            let observedSpan = hi - lo
            let padding = max(observedSpan, 1e-6) * 0.12
            let domainLo = lo - padding
            let domainSpan = max(observedSpan + padding * 2, 1e-6)
            let inset: CGFloat = 2.5
            let chartHeight = max(1, size.height - inset * 2)
            let points = values.enumerated().map { index, value in
                let normalized = observedSpan <= 1e-6 ? 0.5 : (value - domainLo) / domainSpan
                return CGPoint(
                    x: inset + (size.width - inset * 2) * CGFloat(index) / CGFloat(values.count - 1),
                    y: inset + chartHeight * (1 - CGFloat(normalized))
                )
            }

            // A reference line is useful when the summary has a real baseline. Keep it
            // inside the observed domain rather than stretching the chart to manufacture
            // visual movement around an off-screen reference.
            if let baseline, baseline.isFinite, baseline >= lo, baseline <= hi {
                let y = inset + chartHeight * (1 - CGFloat((baseline - domainLo) / domainSpan))
                var reference = Path()
                reference.move(to: CGPoint(x: inset, y: y))
                reference.addLine(to: CGPoint(x: size.width - inset, y: y))
                ctx.stroke(reference, with: .color(Obs.trace.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 0.65, dash: [2.5, 3]))
            }

            // Monotone cubic interpolation rounds the joins without overshooting the
            // measured points. It is smoother than a polyline but does not invent peaks.
            let path = monotonePath(points)
            ctx.stroke(path, with: .color(accent.opacity(0.10)),
                       style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            ctx.stroke(path, with: .color(accent.opacity(0.86)),
                       style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))

            for (index, point) in points.enumerated() {
                let isLatest = index == points.count - 1
                let radius: CGFloat = isLatest ? 2.2 : 1.7
                let dot = CGRect(x: point.x - radius, y: point.y - radius,
                                 width: radius * 2, height: radius * 2)
                // Real samples remain visible as quiet solid marks; the smooth path is
                // only interpolation between them. The latest point is slightly stronger
                // so the direction of time stays clear without a separate axis label.
                ctx.fill(Path(ellipseIn: dot),
                         with: .color(accent.opacity(isLatest ? 0.90 : 0.52)))
            }
        }
        .frame(height: 30)
        .accessibilityHidden(true)
    }
}

/// Fritsch-Carlson-style tangents. Sign changes flatten the tangent, and the
/// slope limiter keeps each Bézier segment inside its data interval.
private func monotonePath(_ points: [CGPoint]) -> Path {
    guard points.count > 1 else { return Path() }
    let deltas = (0..<(points.count - 1)).compactMap { index -> CGFloat? in
        let dx = points[index + 1].x - points[index].x
        guard abs(dx) > 1e-6 else { return nil }
        return (points[index + 1].y - points[index].y) / dx
    }
    guard deltas.count == points.count - 1 else {
        var path = Path()
        path.move(to: points[0])
        for p in points.dropFirst() { path.addLine(to: p) }
        return path
    }
    var tangents = Array(repeating: CGFloat.zero, count: points.count)
    tangents[0] = deltas[0]
    tangents[points.count - 1] = deltas[deltas.count - 1]
    if points.count > 2 {
        for index in 1..<(points.count - 1) {
            tangents[index] = deltas[index - 1] * deltas[index] <= 0
                ? 0
                : (deltas[index - 1] + deltas[index]) / 2
        }
    }
    for index in deltas.indices {
        if deltas[index] == 0 {
            tangents[index] = 0
            tangents[index + 1] = 0
            continue
        }
        let a = tangents[index] / deltas[index]
        let b = tangents[index + 1] / deltas[index]
        let magnitude = a * a + b * b
        if magnitude > 9 {
            let scale = 3 / sqrt(magnitude)
            tangents[index] = scale * a * deltas[index]
            tangents[index + 1] = scale * b * deltas[index]
        }
    }

    var path = Path()
    path.move(to: points[0])
    for index in 0..<(points.count - 1) {
        let width = points[index + 1].x - points[index].x
        path.addCurve(
            to: points[index + 1],
            control1: CGPoint(x: points[index].x + width / 3,
                              y: points[index].y + tangents[index] * width / 3),
            control2: CGPoint(x: points[index + 1].x - width / 3,
                              y: points[index + 1].y - tangents[index + 1] * width / 3)
        )
    }
    return path
}

// A vitals readout: big mono value, unit, delta vs baseline, sparkline.
struct VitalCell: View {
    let tag: String
    let value: String
    let unit: String
    var delta: Double? = nil
    var series: [Double] = []
    var baseline: Double? = nil
    var deltaGoodWhenPositive = true
    var detail: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        let tone = Obs.tone(delta: delta, goodWhenPositive: deltaGoodWhenPositive)
        let stack = VStack(alignment: .leading, spacing: 6) {
            HStack {
                ObsTag(tag)
                if action != nil {
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Obs.trace)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(Obs.mono(26, .medium)).foregroundStyle(Obs.ink).monospacedDigit()
                Text(unit).font(Obs.mono(11)).foregroundStyle(Obs.ink2)
            }
            if let d = delta {
                Text("\(d >= 0 ? "+" : "")\(d, specifier: "%.0f")% vs base")
                    .font(Obs.mono(10))
                    .foregroundStyle(tone)
            }
            if let detail {
                Text(detail).font(Obs.mono(10)).foregroundStyle(Obs.ink2)
            }
            if series.count > 1 {
                Sparkline(series: series, accent: tone, baseline: baseline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if let action {
            Button(action: action) { stack.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel("\(tag) \(value) \(unit)")
                .accessibilityHint("Shows the trend over time")
                .accessibilityIdentifier("vital-\(tag)")
        } else {
            stack
        }
    }
}

enum VitalPeriod: String, CaseIterable {
    case d7 = "7d", d14 = "14d", d30 = "30d", d90 = "90d", all = "all"
    var days: Int? {
        switch self {
        case .d7: return 7
        case .d14: return 14
        case .d30: return 30
        case .d90: return 90
        case .all: return nil
        }
    }
}

private enum YMD {
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func date(_ s: String) -> Date? { fmt.date(from: s) }
    static func string(_ d: Date) -> String { fmt.string(from: d) }
    static func short(_ s: String) -> String { String(s.suffix(5)) }
}

struct VitalTrendView: View {
    let s: Summary
    let kind: VitalKind
    @Environment(\.dismiss) private var dismiss
    @State private var period: VitalPeriod = .d30

    private var all: [DatedVital] { kind.series(in: s) }

    /// Inclusive window ending on the latest sample, not wall-clock today — so a
    /// ring that last synced weeks ago still has a 7d/30d chart to look at.
    private var window: (start: String, end: String)? {
        guard let end = all.last?.date else { return nil }
        guard let days = period.days,
              let endDate = YMD.date(end),
              let startDate = YMD.utc.date(byAdding: .day, value: -(days - 1), to: endDate)
        else {
            return all.first.map { ($0.date, end) }
        }
        return (YMD.string(startDate), end)
    }

    private var points: [DatedVital] {
        guard let window else { return [] }
        return all.filter { $0.date >= window.start && $0.date <= window.end }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Obs.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(kind.caption).font(Obs.prose(14)).foregroundStyle(Obs.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                        Picker("Period", selection: $period) {
                            ForEach(VitalPeriod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        if let last = points.last {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(format(last.value)).font(Obs.mono(34, .medium)).foregroundStyle(Obs.ink)
                                Text(kind.unit).font(Obs.mono(14)).foregroundStyle(Obs.ink2)
                            }
                            HStack(spacing: 8) {
                                Text(last.date).font(Obs.mono(12)).foregroundStyle(Obs.muted)
                                if let d = deltaPct {
                                    Text("\(d >= 0 ? "+" : "")\(d, specifier: "%.0f")% vs base")
                                        .font(Obs.mono(12)).foregroundStyle(accent)
                                }
                            }
                        }
                        if points.count > 1, let window {
                            VitalTrendChart(points: points, start: window.start, end: window.end,
                                            baseline: kind.baseline(in: s),
                                            accent: accent, decimals: kind.decimals)
                            let values = points.map(\.value)
                            let avg = values.reduce(0, +) / Double(values.count)
                            VStack(spacing: 10) {
                                ObsStat(label: "average", value: "\(format(avg)) \(kind.unit)")
                                if let lo = values.min() { ObsStat(label: "low", value: "\(format(lo)) \(kind.unit)") }
                                if let hi = values.max() { ObsStat(label: "high", value: "\(format(hi)) \(kind.unit)") }
                                ObsStat(label: "nights", value: "\(points.count)")
                            }
                            .obsCard()
                        } else if all.isEmpty {
                            Text("No readings yet.")
                                .font(Obs.mono(12)).foregroundStyle(Obs.ink2)
                        } else {
                            Text("Not enough nights in this period yet.")
                                .font(Obs.mono(12)).foregroundStyle(Obs.ink2)
                        }
                    }
                    .padding(24)
                }
            }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private var deltaPct: Double? {
        guard let last = points.last, let base = kind.baseline(in: s), base > 0 else { return nil }
        return (last.value - base) / base * 100
    }

    private var accent: Color {
        Obs.tone(delta: deltaPct, goodWhenPositive: kind.goodWhenPositive)
    }

    private func format(_ v: Double) -> String {
        kind.decimals > 0 ? String(format: "%.\(kind.decimals)f", v) : "\(Int(v.rounded()))"
    }
}

private struct VitalTrendChart: View {
    let points: [DatedVital]
    let start: String
    let end: String
    let baseline: Double?
    let accent: Color
    let decimals: Int

    var body: some View {
        let values = points.map(\.value)
        let lo = values.min() ?? 0
        let hi = values.max() ?? 1
        let pad = max(hi - lo, 1e-6) * 0.12
        let domainLo = lo - pad
        let domainHi = hi + pad
        let span = max(domainHi - domainLo, 1e-6)
        let t0 = YMD.date(start)?.timeIntervalSince1970 ?? 0
        let t1 = YMD.date(end)?.timeIntervalSince1970 ?? t0
        let tSpan = max(t1 - t0, 1)
        func x(_ date: String, _ width: CGFloat) -> CGFloat {
            guard let t = YMD.date(date)?.timeIntervalSince1970 else { return 0 }
            return width * CGFloat((t - t0) / tSpan)
        }
        return VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(tick(domainHi)).font(Obs.mono(9)).foregroundStyle(Obs.muted)
                    Spacer()
                    Text(tick((domainLo + domainHi) / 2)).font(Obs.mono(9)).foregroundStyle(Obs.muted)
                    Spacer()
                    Text(tick(domainLo)).font(Obs.mono(9)).foregroundStyle(Obs.muted)
                }
                .frame(width: 36)
                Canvas { ctx, size in
                    for fraction in [0.0, 0.5, 1.0] {
                        let y = size.height * CGFloat(fraction)
                        var grid = Path()
                        grid.move(to: CGPoint(x: 0, y: y))
                        grid.addLine(to: CGPoint(x: size.width, y: y))
                        ctx.stroke(grid, with: .color(Obs.trace.opacity(0.4)), lineWidth: 0.5)
                    }
                    func pt(_ date: String, _ value: Double) -> CGPoint {
                        CGPoint(
                            x: x(date, size.width),
                            y: size.height * (1 - CGFloat((value - domainLo) / span))
                        )
                    }
                    if let baseline, baseline.isFinite {
                        let y = size.height * (1 - CGFloat((baseline - domainLo) / span))
                        if y >= 0, y <= size.height {
                            var reference = Path()
                            reference.move(to: CGPoint(x: 0, y: y))
                            reference.addLine(to: CGPoint(x: size.width, y: y))
                            ctx.stroke(reference, with: .color(Obs.ink.opacity(0.35)),
                                       style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        }
                    }
                    let dots = points.map { pt($0.date, $0.value) }
                    let line = monotonePath(dots)
                    ctx.stroke(line, with: .color(accent.opacity(0.12)),
                               style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    ctx.stroke(line, with: .color(accent),
                               style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    for (i, p) in dots.enumerated() {
                        let last = i == dots.count - 1
                        let r: CGFloat = last ? 3.2 : 2.1
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                                 with: .color(accent.opacity(last ? 1 : 0.7)))
                    }
                }
                .frame(height: 200)
                .accessibilityLabel("Trend from \(YMD.short(start)) to \(YMD.short(end))")
            }
            HStack {
                Text(YMD.short(start)).font(Obs.mono(10)).foregroundStyle(Obs.ink2)
                Spacer()
                if let mid = midpoint {
                    Text(YMD.short(mid)).font(Obs.mono(10)).foregroundStyle(Obs.muted)
                    Spacer()
                }
                Text(YMD.short(end)).font(Obs.mono(10)).foregroundStyle(Obs.ink2)
            }
            if baseline != nil {
                HStack(spacing: 5) {
                    Rectangle().fill(Obs.ink.opacity(0.35)).frame(width: 16, height: 1)
                    Text("baseline").font(Obs.mono(10)).foregroundStyle(Obs.ink2)
                }
            }
        }
    }

    private var midpoint: String? {
        guard let a = YMD.date(start), let b = YMD.date(end), b > a else { return nil }
        let mid = Date(timeIntervalSince1970: (a.timeIntervalSince1970 + b.timeIntervalSince1970) / 2)
        let s = YMD.string(mid)
        if s == start || s == end { return nil }
        return s
    }

    private func tick(_ v: Double) -> String {
        decimals > 0 ? String(format: "%.\(decimals)f", v) : "\(Int(v.rounded()))"
    }
}

// Sleep-stage hypnogram: one ink hue, height encoding the stage (deep full →
// wake short) so the night reads without a rainbow.
struct Hypnogram: View {
    let stages: [Int]
    var height: CGFloat = 40
    var body: some View {
        Canvas { ctx, size in
            guard !stages.isEmpty else { return }
            let w = size.width / CGFloat(stages.count)
            for (i, s) in stages.enumerated() {
                let frac: CGFloat = switch s { case 1: 1; case 2: 0.72; case 3: 0.48; default: 0.28 }
                let h = size.height * frac
                let r = CGRect(x: CGFloat(i) * w, y: size.height - h, width: w + 0.4, height: h)
                ctx.fill(Path(r), with: .color(Obs.stage(s)))
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// Continuous movement ridge from the 96 × 15-min MET-above-rest buckets — the web
// actogram's ridge, model-free (computed from raw MET). One day's profile.
struct MovementRidge: View {
    let profile: [Double]
    var height: CGFloat = 44
    var body: some View {
        Canvas { ctx, size in
            guard profile.count > 1 else { return }
            let peak = max(profile.max() ?? 1, 0.5)
            let n = profile.count
            func pt(_ i: Int) -> CGPoint {
                CGPoint(x: size.width * CGFloat(i) / CGFloat(n - 1),
                        y: size.height * (1 - CGFloat(min(1, profile[i] / peak))))
            }
            var area = Path(); area.move(to: CGPoint(x: 0, y: size.height))
            for i in 0..<n { area.addLine(to: pt(i)) }
            area.addLine(to: CGPoint(x: size.width, y: size.height)); area.closeSubpath()
            ctx.fill(area, with: .color(Obs.chart.opacity(0.14)))
            var line = Path(); line.move(to: pt(0))
            for i in 1..<n { line.addLine(to: pt(i)) }
            ctx.stroke(line, with: .color(Obs.chart.opacity(0.85)), style: .init(lineWidth: 1.2, lineJoin: .round))
        }
        .frame(height: height)
    }
}
