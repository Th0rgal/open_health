import SwiftUI
import UIKit

// Reusable data-display pieces for the home screens: gauges, bars, trend charts,
// heatmaps and tiles. They take plain values and carry no screen logic, so each screen
// reads as a composition of the same few marks.

// ── surfaces and labels ──────────────────────────────────────────────────────

struct Surface: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Obs.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
extension View {
    func surface(padding: CGFloat = 16) -> some View { modifier(Surface(padding: padding)) }
}

/// Section title: icon, name, optional trailing value, optional chevron.
struct SectionLabel: View {
    let title: String
    var icon: String? = nil
    var tint: Color = Obs.muted
    var trailing: String? = nil
    var chevron = false
    var body: some View {
        HStack(spacing: 7) {
            if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint) }
            Text(title).font(Obs.sans(11, .medium)).foregroundStyle(Obs.muted)
            Spacer(minLength: 8)
            if let trailing { Text(trailing).font(Obs.sans(11)).foregroundStyle(Obs.ink2) }
            if chevron { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Obs.muted) }
        }
    }
}

/// A figure with its unit: the basic readout.
struct Figure: View {
    let value: String
    var unit: String = ""
    var size: CGFloat = 28
    var color: Color = Obs.ink
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(Obs.sans(size, .medium)).foregroundStyle(color).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            if !unit.isEmpty { Text(unit).font(Obs.sans(max(10, size * 0.4))).foregroundStyle(Obs.ink2) }
        }
    }
}

/// Signed change with an arrow. Colored only when the direction has a good side and the
/// change is at least `threshold` of the reference level.
struct DeltaBadge: View {
    let delta: Double
    var unit: String = ""
    var decimals: Int = 0
    var higherIsBetter: Bool? = nil
    var reference: Double? = nil
    var threshold: Double = 0.05
    private var color: Color {
        guard let better = higherIsBetter, let reference, reference != 0,
              abs(delta) / abs(reference) >= threshold else { return Obs.muted }
        return (delta >= 0) == better ? Obs.good : Obs.bad
    }
    var body: some View {
        let rounded = (delta * pow(10, Double(decimals))).rounded() / pow(10, Double(decimals))
        HStack(spacing: 3) {
            Image(systemName: rounded == 0 ? "equal" : (delta > 0 ? "arrow.up" : "arrow.down"))
                .font(.system(size: 8, weight: .bold))
            Text("\(String(format: "%.\(decimals)f", abs(delta)))\(unit.isEmpty ? "" : " \(unit)")")
                .font(Obs.sans(11, .medium)).monospacedDigit()
        }
        .foregroundStyle(color)
    }
}

// ── gauges and bars ──────────────────────────────────────────────────────────

/// A 0-100 ring. The ring is a full circle starting at 12 o'clock.
struct RingGauge: View {
    let value: Double?
    var color: Color
    var lineWidth: CGFloat = 8
    var body: some View {
        ZStack {
            Circle().stroke(Obs.rule, lineWidth: lineWidth)
            if let value {
                Circle()
                    .trim(from: 0, to: max(0.004, min(1, value / 100)))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(lineWidth / 2)
    }
}

/// Horizontal 0-100 bar with ticks at the band edges (60, 70, 85).
struct BandBar: View {
    let value: Double
    var color: Color
    var height: CGFloat = 6
    var ticks = true
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Obs.rule)
                Capsule().fill(color).frame(width: max(height, geo.size.width * min(1, max(0, value / 100))))
                if ticks {
                    ForEach([60.0, 70.0, 85.0], id: \.self) { t in
                        Rectangle().fill(Obs.raised.opacity(0.9)).frame(width: 1)
                            .offset(x: geo.size.width * t / 100)
                    }
                }
            }
        }
        .frame(height: height)
    }
}

/// Proportional segments in one bar, with each segment's label over its value underneath.
struct StackedBar: View {
    struct Segment: Identifiable {
        let label: String
        let value: Double
        let color: Color
        var text: String
        var id: String { label }
    }
    let segments: [Segment]
    var height: CGFloat = 10
    var body: some View {
        let total = max(segments.map(\.value).reduce(0, +), 1e-9)
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(segments.filter { $0.value > 0 }) { seg in
                        RoundedRectangle(cornerRadius: 2).fill(seg.color)
                            .frame(width: max(2, (geo.size.width - 6) * seg.value / total))
                    }
                }
            }
            .frame(height: height)
            // equal columns, so no value is cut off however long the label
            HStack(alignment: .top, spacing: 8) {
                ForEach(segments) { seg in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Circle().fill(seg.color).frame(width: 6, height: 6)
                            Text(seg.label).font(Obs.sans(11)).foregroundStyle(Obs.muted).lineLimit(1)
                        }
                        Text(seg.text).font(Obs.sans(13, .medium)).foregroundStyle(Obs.ink).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// Recent values as a small line, auto-scaled; each segment and dot is colored by score
/// band when `scored`, otherwise drawn in `tint`.
struct MiniLine: View {
    let values: [Double]
    var scored = true
    var tint: Color = Obs.chart
    var height: CGFloat = 28
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1, let lo = values.min(), let hi = values.max() else { return }
            let span = max(hi - lo, 1e-6)
            let inset: CGFloat = 4
            func yv(_ v: Double) -> CGFloat {
                hi == lo ? size.height / 2 : inset + (size.height - inset * 2) * (1 - CGFloat((v - lo) / span))
            }
            func pt(_ i: Int) -> CGPoint {
                CGPoint(x: inset + (size.width - inset * 2) * CGFloat(i) / CGFloat(values.count - 1), y: yv(values[i]))
            }
            let ink: GraphicsContext.Shading = scored ? ScoreGradient.shading(y: yv) : .color(tint)
            var line = Path()
            for i in values.indices { i == 0 ? line.move(to: pt(0)) : line.addLine(to: pt(i)) }
            var area = line
            area.addLine(to: CGPoint(x: pt(values.count - 1).x, y: size.height)); area.addLine(to: CGPoint(x: pt(0).x, y: size.height))
            area.closeSubpath()
            if scored {
                ScoreGradient.shadow(&ctx, area: area, points: values.indices.map { (pt($0).x, values[$0]) },
                                     bottomY: size.height, size: size, scheme: scheme, alpha: 0.38, y: yv)
            } else {
                ctx.fill(area, with: .linearGradient(Gradient(colors: [tint.opacity(0.22), tint.opacity(0)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            }
            ctx.stroke(line, with: ink, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            for i in values.indices {
                let r: CGFloat = i == values.count - 1 ? 3.6 : 2.2
                let dot = CGRect(x: pt(i).x - r, y: pt(i).y - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: dot.insetBy(dx: -1.4, dy: -1.4)), with: .color(Obs.raised))
                ctx.fill(Path(ellipseIn: dot), with: ink)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// One continuous color scale over 0-100 shared by every score mark: the hue at a given
/// height is the same for the line, its dots, the fill beneath and the background wash,
/// and it blends across the band edges instead of stepping.
enum ScoreGradient {
    /// Anchor colors on the 0-100 scale; everything between is blended in hue so amber to
    /// blue passes through green instead of through gray.
    private static let anchors: [(value: Double, color: Color)] = [
        (0, Obs.bad), (52, Obs.bad), (64, Obs.caution), (76, Obs.goodSoft), (90, Obs.good), (100, Obs.good),
    ]

    private static func blend(_ value: Double, _ trait: UITraitCollection) -> UIColor {
        func hsb(_ c: Color) -> (h: CGFloat, s: CGFloat, b: CGFloat) {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(c).resolvedColor(with: trait).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return (h, s, b)
        }
        let v = min(max(value, 0), 100)
        var lo = anchors[0], hi = anchors[anchors.count - 1]
        for i in 1..<anchors.count where v <= anchors[i].value { lo = anchors[i - 1]; hi = anchors[i]; break }
        let t = hi.value == lo.value ? 0 : CGFloat((v - lo.value) / (hi.value - lo.value))
        let (a, b) = (hsb(lo.color), hsb(hi.color))
        var dh = b.h - a.h
        if dh > 0.5 { dh -= 1 } else if dh < -0.5 { dh += 1 }
        let h = (a.h + dh * t + 1).truncatingRemainder(dividingBy: 1)
        // quieter in the middle of a blend, so the passage through green stays muted
        let calm = 1 - 0.38 * CGFloat(sin(Double(t) * .pi))
        return UIColor(hue: h, saturation: (a.s + (b.s - a.s) * t) * calm,
                       brightness: (a.b + (b.b - a.b) * t) * (1 - 0.06 * CGFloat(sin(Double(t) * .pi))), alpha: 1)
    }

    /// The scale's color at one value; adapts to light and dark.
    static func color(_ value: Double, scheme: ColorScheme = .light) -> Color {
        Color(uiColor: UIColor { blend(value, $0) })
    }

    /// The whole scale as a gradient, sampled densely so the hue blend carries through.
    static func gradient(alpha: Double = 1) -> Gradient {
        Gradient(stops: stride(from: 0.0, through: 100.0, by: 4.0).map {
            .init(color: color($0).opacity(alpha), location: $0 / 100)
        })
    }
    /// A vertical gradient shading where `y(v)` is the canvas height of score `v`.
    static func shading(alpha: Double = 1, y: (Double) -> CGFloat) -> GraphicsContext.Shading {
        .linearGradient(gradient(alpha: alpha), startPoint: CGPoint(x: 0, y: y(0)), endPoint: CGPoint(x: 0, y: y(100)))
    }
}

extension ScoreGradient {
    /// Fills `area` (the region under a line through `points`) with each point's own hue
    /// along x, fading to nothing at `bottomY`: the soft shadow under a score line.
    static func shadow(_ ctx: inout GraphicsContext, area: Path, points: [(x: CGFloat, value: Double)],
                       bottomY: CGFloat, size: CGSize, scheme: ColorScheme, alpha: Double = 0.42,
                       y: (Double) -> CGFloat) {
        guard let first = points.first, let last = points.last, last.x > first.x else { return }
        let span = last.x - first.x
        let hues = points.map {
            Gradient.Stop(color: color($0.value, scheme: scheme).opacity(alpha), location: min(1, max(0, ($0.x - first.x) / span)))
        }
        let topY = points.map { y($0.value) }.min() ?? 0
        ctx.drawLayer { layer in
            layer.fill(area, with: .linearGradient(Gradient(stops: hues),
                                                   startPoint: CGPoint(x: first.x, y: 0), endPoint: CGPoint(x: last.x, y: 0)))
            layer.blendMode = .destinationIn
            layer.fill(Path(CGRect(origin: .zero, size: size)),
                       with: .linearGradient(Gradient(colors: [.white, .white.opacity(0)]),
                                             startPoint: CGPoint(x: 0, y: topY), endPoint: CGPoint(x: 0, y: bottomY)))
        }
    }
}

// ── trend chart ──────────────────────────────────────────────────────────────

/// Daily series as bars or a line, with a dashed reference, y-axis extremes, first and
/// last dates, and a horizontal scrubber that reports the selected index.
struct TrendChart: View {
    enum Style { case bars, line }
    let points: [DatedValue]
    var style: Style = .line
    var tint: Color = Obs.chart
    /// Fixed y range; scores use 0...100. Otherwise the data range with padding.
    var domain: ClosedRange<Double>? = nil
    var reference: Double? = nil
    var bandColors = false
    var height: CGFloat = 150
    var decimals = 0
    /// Calendar days spanned by the x-axis; points are placed by date and missing days stay empty.
    var axis: [String]? = nil
    /// A personal range shaded behind the line; points outside it are drawn in the alert color.
    var band: ClosedRange<Double>? = nil
    @Binding var selection: Int?
    @Environment(\.colorScheme) private var scheme

    private let axisW: CGFloat = 30, footH: CGFloat = 16

    private var yRange: ClosedRange<Double> {
        if let domain { return domain }
        var v = points.map(\.value)
        if let band { v += [band.lowerBound, band.upperBound] }
        guard let lo = v.min(), let hi = v.max() else { return 0...1 }
        if style == .bars { return 0...max(hi * 1.08, 1) }
        let pad = max((hi - lo) * 0.15, abs(hi) * 0.01, 0.5)
        return (lo - pad)...(hi + pad)
    }

    var body: some View {
        Canvas { ctx, size in
            guard points.count > 0 else { return }
            let plot = CGRect(x: 0, y: 4, width: size.width - axisW, height: size.height - footH - 4)
            let r = yRange, span = max(r.upperBound - r.lowerBound, 1e-9)
            func y(_ v: Double) -> CGFloat { plot.maxY - plot.height * CGFloat((v - r.lowerBound) / span) }
            let n = axis?.count ?? points.count
            let slot = plot.width / CGFloat(max(n, 1))
            let slots = slotIndex()
            func x(_ i: Int) -> CGFloat { plot.minX + slot * (CGFloat(slots[i]) + 0.5) }

            // the score scale as a soft wash behind the series
            if bandColors {
                ctx.fill(Path(roundedRect: CGRect(x: 0, y: plot.minY, width: plot.width, height: plot.height), cornerRadius: 4),
                         with: ScoreGradient.shading(alpha: 0.05, y: y))
            }
            if let band {
                let top = y(min(max(band.upperBound, r.lowerBound), r.upperBound))
                let bottom = y(min(max(band.lowerBound, r.lowerBound), r.upperBound))
                ctx.fill(Path(roundedRect: CGRect(x: 0, y: top, width: plot.width, height: max(1, bottom - top)), cornerRadius: 4),
                         with: .color(tint.opacity(0.13)))
            }
            // grid: top, middle, bottom
            for frac in [0.0, 0.5, 1.0] {
                let gy = plot.minY + plot.height * CGFloat(frac)
                ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: gy)); $0.addLine(to: CGPoint(x: plot.maxX, y: gy)) },
                           with: .color(Obs.rule), lineWidth: 0.6)
            }
            let fmt = { (v: Double) in String(format: "%.\(decimals)f", v) }
            for (v, gy) in [(r.upperBound, plot.minY), (r.lowerBound, plot.maxY)] {
                ctx.draw(Text(fmt(v)).font(Obs.sans(11)).foregroundColor(Obs.muted),
                         at: CGPoint(x: size.width, y: gy), anchor: v == r.upperBound ? .topTrailing : .bottomTrailing)
            }
            if let reference, r.contains(reference) {
                ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y(reference))); $0.addLine(to: CGPoint(x: plot.maxX, y: y(reference))) },
                           with: .color(Obs.ink2.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }

            switch style {
            case .bars:
                let bw = max(1.5, slot * (n > 45 ? 0.8 : 0.66))
                for (i, p) in points.enumerated() {
                    let top = y(min(max(p.value, r.lowerBound), r.upperBound))
                    let rect = CGRect(x: x(i) - bw / 2, y: top, width: bw, height: plot.maxY - top)
                    let c = bandColors ? ScoreBand(p.value).color : tint
                    ctx.fill(Path(roundedRect: rect, cornerRadius: min(2.5, bw / 2)),
                             with: .color(c.opacity(selection == nil || selection == i ? 1 : 0.35)))
                }
            case .line:
                var line = Path()
                for (i, p) in points.enumerated() {
                    let pt = CGPoint(x: x(i), y: y(p.value))
                    if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
                }
                var area = line
                area.addLine(to: CGPoint(x: x(points.count - 1), y: plot.maxY)); area.addLine(to: CGPoint(x: x(0), y: plot.maxY))
                area.closeSubpath()
                // fill: the value scale where scored, otherwise the tint fading downward
                if bandColors, points.count > 1, x(points.count - 1) > x(0) {
                    ScoreGradient.shadow(&ctx, area: area, points: points.indices.map { (x($0), points[$0].value) },
                                         bottomY: plot.maxY, size: size, scheme: scheme, y: y)
                } else if bandColors {
                    ctx.fill(area, with: ScoreGradient.shading(alpha: 0.2, y: y))
                } else {
                    ctx.fill(area, with: .linearGradient(Gradient(colors: [tint.opacity(0.22), tint.opacity(0.02)]),
                                                         startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
                }
                let stroke = StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
                let ink: GraphicsContext.Shading = bandColors ? ScoreGradient.shading(y: y) : .color(tint)
                ctx.stroke(line, with: ink, style: stroke)
                if n <= 45 {
                    for (i, p) in points.enumerated() {
                        let last = i == points.count - 1
                        let rad: CGFloat = last ? 4.2 : 2.8
                        let dot = CGRect(x: x(i) - rad, y: y(p.value) - rad, width: rad * 2, height: rad * 2)
                        let outside = band.map { !$0.contains(p.value) } ?? false
                        // a halo in the card color separates each dot from the line it sits on
                        ctx.fill(Path(ellipseIn: dot.insetBy(dx: -1.6, dy: -1.6)), with: .color(Obs.raised))
                        ctx.fill(Path(ellipseIn: dot), with: bandColors ? ink : .color(outside ? Obs.alert : tint))
                    }
                }
            }

            if let s = selection, points.indices.contains(s) {
                ctx.stroke(Path { $0.move(to: CGPoint(x: x(s), y: plot.minY)); $0.addLine(to: CGPoint(x: x(s), y: plot.maxY)) },
                           with: .color(Obs.ink), lineWidth: 1)
                if style == .line {
                    ctx.fill(Path(ellipseIn: CGRect(x: x(s) - 4.5, y: y(points[s].value) - 4.5, width: 9, height: 9)),
                             with: .color(Obs.ink))
                }
            }
            // x labels: first and last date
            let firstDay = axis?.first ?? points[0].date, lastDay = axis?.last ?? points[points.count - 1].date
            ctx.draw(Text(DayFmt.short(firstDay)).font(Obs.sans(11)).foregroundColor(Obs.muted),
                     at: CGPoint(x: 0, y: size.height), anchor: .bottomLeading)
            if firstDay != lastDay {
                ctx.draw(Text(DayFmt.short(lastDay)).font(Obs.sans(11)).foregroundColor(Obs.muted),
                         at: CGPoint(x: plot.maxX, y: size.height), anchor: .bottomTrailing)
            }
        }
        .frame(height: height)
        .contentShape(Rectangle())
        .overlay(HorizontalScrub(onChange: { selection = index(at: $0) }, onEnd: { selection = nil }))
        .background(GeometryReader { geo in
            Color.clear.onAppear { width = geo.size.width }.onChange(of: geo.size.width) { _, w in width = w }
        })
        .accessibilityElement()
        .accessibilityLabel("Trend chart, \(points.count) days")
    }

    @State private var width: CGFloat = 1
    /// Slot (column) of each point: its position in `axis`, or its own index without one.
    private func slotIndex() -> [Int] {
        guard let axis else { return Array(points.indices) }
        let pos = Dictionary(uniqueKeysWithValues: axis.enumerated().map { ($1, $0) })
        return points.enumerated().map { pos[$1.date] ?? $0 }
    }
    private func index(at x: CGFloat) -> Int? {
        guard !points.isEmpty else { return nil }
        let n = axis?.count ?? points.count
        let plotW = max(1, width - axisW)
        let slot = min(n - 1, max(0, Int((x / plotW * CGFloat(n)).rounded(.down))))
        let slots = slotIndex()
        return points.indices.min { abs(slots[$0] - slot) < abs(slots[$1] - slot) }
    }
}

// ── heatmap ──────────────────────────────────────────────────────────────────

/// Rows of daily cells colored by band: the history of every contributor at once.
struct Heatmap: View {
    struct Row: Identifiable {
        let id: String
        let label: String
        let values: [String: Double]
    }
    let rows: [Row]
    let days: [String]
    var labelWidth: CGFloat = 124
    var selectedRow: String? = nil
    var onTap: ((String) -> Void)? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 5) {
            ForEach(rows) { row in
                Button { onTap?(row.id) } label: {
                    HStack(spacing: 8) {
                        Text(row.label).font(Obs.sans(11)).lineLimit(1).minimumScaleFactor(0.8)
                            .foregroundStyle(selectedRow == row.id ? Obs.ink : Obs.ink2)
                            .frame(width: labelWidth, alignment: .leading)
                        Canvas { ctx, size in
                            guard !days.isEmpty else { return }
                            let gap: CGFloat = days.count > 45 ? 0.6 : 1.5
                            let w = (size.width - gap * CGFloat(days.count - 1)) / CGFloat(days.count)
                            for (i, d) in days.enumerated() {
                                let rect = CGRect(x: CGFloat(i) * (w + gap), y: 0, width: max(1, w), height: size.height)
                                if let v = row.values[d] {
                                    ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(ScoreGradient.color(v, scheme: scheme)))
                                } else {
                                    ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(Obs.rule.opacity(0.6)))
                                }
                            }
                        }
                        .frame(height: 15)
                    }
                    .opacity(selectedRow == nil || selectedRow == row.id ? 1 : 0.45)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack {
                Spacer().frame(width: labelWidth + 8)
                if let first = days.first { Text(DayFmt.short(first)) }
                Spacer()
                if let last = days.last, days.count > 1 { Text(DayFmt.short(last)) }
            }
            .font(Obs.sans(11)).foregroundStyle(Obs.muted)
        }
    }
}

/// The score scale: the blended color bar with the band edges marked.
struct BandLegend: View {
    var body: some View {
        VStack(spacing: 5) {
            Capsule()
                .fill(LinearGradient(gradient: ScoreGradient.gradient(), startPoint: .leading, endPoint: .trailing))
                .frame(height: 6)
            GeometryReader { geo in
                ForEach([(0.0, "0"), (60, "60"), (70, "70"), (85, "85"), (100, "100")], id: \.0) { value, label in
                    Text(label).font(Obs.sans(10)).foregroundStyle(Obs.muted).fixedSize()
                        .position(x: min(max(geo.size.width * value / 100, 14), geo.size.width - 14), y: 6)
                }
            }
            .frame(height: 12)
        }
    }
}

// ── tiles ────────────────────────────────────────────────────────────────────

/// A grid tile: title, value, change against recent average, and the recent series.
struct MetricTile: View {
    let title: String
    let value: String
    var unit: String = ""
    var icon: String? = nil
    var tint: Color = Obs.muted
    var valueColor: Color = Obs.ink
    /// Short status next to the value (band word, state).
    var status: String? = nil
    var statusColor: Color = Obs.muted
    var delta: DeltaBadge? = nil
    var series: [Double] = []
    var baseline: Double? = nil
    /// Series are scores: draw them as a band-colored line.
    var scored: Bool = false
    var chevron = true
    /// The capture feature this measurement needs when there is no data: the tile dims and
    /// says where to turn it on.
    var missing: CaptureNeed? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: title, icon: icon, tint: tint, chevron: chevron && missing == nil)
            Figure(value: value, unit: unit, size: 28, color: valueColor)
            if let missing {
                Text(missing.hint).font(Obs.sans(11)).foregroundStyle(Obs.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) {
                    if let status { Text(status).font(Obs.sans(11, .medium)).foregroundStyle(statusColor) }
                    if let delta { delta }
                    if status == nil && delta == nil { Text(" ").font(Obs.sans(11)) }
                }
                if scored && series.count > 1 {
                    MiniLine(values: series, height: 26)
                } else if series.count > 1 {
                    Sparkline(series: series, accent: tint == Obs.muted ? Obs.chart : tint, baseline: baseline)
                } else {
                    Color.clear.frame(height: 22)
                }
            }
        }
        .opacity(missing == nil ? 1 : 0.6)
        .surface(padding: 14)
        .contentShape(Rectangle())
    }
}

/// A key/value pair in a stat grid.
struct StatCell: View {
    let label: String
    let value: String
    var unit: String = ""
    var sub: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Obs.sans(11, .medium)).foregroundStyle(Obs.muted)
            Figure(value: value, unit: unit, size: 20)
            if let sub { Text(sub).font(Obs.sans(11)).foregroundStyle(Obs.ink2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 7d / 14d / 30d / 90d selector.
struct PeriodPicker: View {
    @Binding var days: Int
    var options = [14, 30, 90]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { d in
                Button { days = d } label: {
                    Text("\(d)d").font(Obs.sans(12, days == d ? .medium : .regular))
                        .foregroundStyle(days == d ? Obs.paper : Obs.ink2)
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background(days == d ? Obs.ink : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Obs.raised, in: Capsule())
    }
}

/// The vertical scroll offset shared by the day pages of one tab. The visible page writes
/// it; a page that comes into view starts there, so swiping to another day keeps the same
/// depth. A plain reference: offsets change every frame and must not re-render the pages.
final class ScrollSync {
    var y: CGFloat = 0
}

/// Applies the shared offset (iOS 18 and later; earlier systems keep per-page offsets).
/// Also the QA hook: `-scrollY <points>` on launch scrolls the first page, so lower sections
/// can be captured with `simctl io screenshot`. Ignored in normal launches.
@available(iOS 18, *)
struct SyncedScroll: ViewModifier {
    let sync: ScrollSync
    let isActive: Bool
    @State private var position: ScrollPosition

    init(sync: ScrollSync, isActive: Bool) {
        self.sync = sync
        self.isActive = isActive
        _position = State(initialValue: ScrollPosition(y: sync.y))
    }

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, y in
                if isActive { sync.y = y }
            }
            .onAppear { if !isActive || sync.y > 0 { position.scrollTo(y: sync.y) } }
            .task {
                let args = CommandLine.arguments
                guard isActive, let i = args.firstIndex(of: "-scrollY"), i + 1 < args.count, let y = Double(args[i + 1]) else { return }
                try? await Task.sleep(nanoseconds: 800_000_000)
                sync.y = y
                position.scrollTo(y: y)
            }
    }
}

extension View {
    @ViewBuilder func syncedScroll(_ sync: ScrollSync, active: Bool) -> some View {
        if #available(iOS 18, *) { modifier(SyncedScroll(sync: sync, isActive: active)) } else { self }
    }
}

/// A horizontal scrubber that leaves vertical drags to the enclosing scroll view.
///
/// SwiftUI's `DragGesture(minimumDistance: 0)` claims every touch that starts on the
/// chart, so a chart inside a `ScrollView` cannot be scrolled past by dragging on it. This
/// overlay begins only for a horizontal-dominant pan or a tap and reports the x position in
/// its own coordinates; `onEnd` fires when the finger lifts.
struct HorizontalScrub: UIViewRepresentable {
    var onChange: (CGFloat) -> Void
    var onEnd: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.delegate = context.coordinator
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.parent = self }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: HorizontalScrub
        init(_ parent: HorizontalScrub) { self.parent = parent }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return true }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y)
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began, .changed: parent.onChange(g.location(in: g.view).x)
            case .ended, .cancelled, .failed: parent.onEnd()
            default: break
            }
        }

        @objc func tap(_ g: UITapGestureRecognizer) {
            parent.onChange(g.location(in: g.view).x)
            // a tap shows the readout briefly, then clears it
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [parent] in parent.onEnd() }
        }
    }
}
