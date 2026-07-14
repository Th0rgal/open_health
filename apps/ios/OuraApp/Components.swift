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
                .foregroundStyle(Obs.teal).frame(width: 20)
            Text(actLabel(label)).font(Obs.mono(13, .medium)).foregroundStyle(Obs.ink)
            Spacer()
            Text("\(durationMin) min").font(Obs.mono(12)).foregroundStyle(Obs.teal)
            Text(startHM).font(Obs.mono(11)).foregroundStyle(Obs.ink2)
        }
    }
}

// ── reusable readout + chart components ───────────────────────────────────────
struct Sparkline: View {
    let series: [Double]
    var accent: Color = Obs.teal
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

    /// Fritsch-Carlson-style tangents for equally spaced samples. Sign changes flatten
    /// the tangent, and the slope limiter prevents a Bézier segment leaving its data
    /// interval (the common visual lie in generic Catmull-Rom sparklines).
    private func monotonePath(_ points: [CGPoint]) -> Path {
        guard points.count > 1 else { return Path() }
        let deltas = (0..<(points.count - 1)).map { index in
            (points[index + 1].y - points[index].y) / (points[index + 1].x - points[index].x)
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
    var body: some View {
        let good = (delta ?? 0) >= 0 ? deltaGoodWhenPositive : !deltaGoodWhenPositive
        VStack(alignment: .leading, spacing: 6) {
            ObsTag(tag)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(Obs.mono(26, .medium)).foregroundStyle(Obs.ink).monospacedDigit()
                Text(unit).font(Obs.mono(11)).foregroundStyle(Obs.ink2)
            }
            if let d = delta {
                Text("\(d >= 0 ? "+" : "")\(d, specifier: "%.0f")% vs base")
                    .font(Obs.mono(10))
                    .foregroundStyle(good ? Obs.teal : Obs.yellow)
            }
            if let detail {
                Text(detail).font(Obs.mono(10)).foregroundStyle(Obs.ink2)
            }
            if series.count > 1 {
                Sparkline(series: series, accent: good ? Obs.teal : Obs.yellow, baseline: baseline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Sleep-stage hypnogram: a strip of colored segments over the night (1=deep …
// 4=wake), matching the web dashboard's `.hyp`. Renders whenever stage data exists.
struct Hypnogram: View {
    let stages: [Int]
    var height: CGFloat = 40
    var body: some View {
        Canvas { ctx, size in
            guard !stages.isEmpty else { return }
            let w = size.width / CGFloat(stages.count)
            for (i, s) in stages.enumerated() {
                let r = CGRect(x: CGFloat(i) * w, y: 0, width: w + 0.6, height: size.height)
                ctx.fill(Path(r), with: .color(Obs.stage(s).opacity(0.85)))
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
            ctx.fill(area, with: .color(Obs.teal.opacity(0.16)))
            var line = Path(); line.move(to: pt(0))
            for i in 1..<n { line.addLine(to: pt(i)) }
            ctx.stroke(line, with: .color(Obs.teal.opacity(0.8)), style: .init(lineWidth: 1.2, lineJoin: .round))
        }
        .frame(height: height)
    }
}
