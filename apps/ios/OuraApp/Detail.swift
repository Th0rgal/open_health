import SwiftUI

// Drill-down pages. A score opens to its history and contributors; a contributor or a
// metric opens to its daily series; a day in that series opens the day report.

struct ScoreDetailView: View {
    let s: Summary
    let kind: ScoreKind
    let day: String
    var onOpenDay: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var period = 30
    @State private var selection: Int?
    @State private var focus: String?

    private var all: [DatedValue] { s.scoreSeries(kind, upTo: day) }
    private var windowDays: [String] { s.calendarDays(upTo: day, count: period) }
    private func inWindow(_ v: [DatedValue]) -> [DatedValue] {
        let set = Set(windowDays)
        return v.filter { set.contains($0.date) }
    }
    private var window: [DatedValue] {
        guard let focus else { return inWindow(all) }
        return inWindow(s.contributorSeries(kind, key: focus, upTo: day))
    }
    private var focusDay: String { all.last?.date ?? day }
    private var contributors: [Contributor] { kind.contributors(s, focusDay) }
    private var focusLabel: String { contributors.first { $0.key == focus }?.label ?? kind.title }

    var body: some View {
        NavigationStack {
            ZStack {
                Obs.canvas
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        PeriodPicker(days: $period)
                        readout
                        TrendChart(points: window, style: .line, tint: kind.tint, domain: 0...100,
                                   reference: Stats.mean(window.map(\.value)), bandColors: true,
                                   height: 170, axis: windowDays, selection: $selection)
                        BandLegend()
                        stats
                        if !contributors.isEmpty { contributorSection }
                    }
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 32)
                }
            }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .onChange(of: period) { _, _ in selection = nil }
        .onChange(of: focus) { _, _ in selection = nil }
    }

    private var shown: DatedValue? {
        if let i = selection, window.indices.contains(i) { return window[i] }
        return window.last
    }

    private var readout: some View {
        HStack(alignment: .firstTextBaseline) {
            if let p = shown {
                Figure(value: String(format: "%.0f", p.value), size: 46, color: ScoreBand(p.value).color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ScoreBand(p.value).title).font(Obs.sans(11, .medium))
                        .foregroundStyle(ScoreBand(p.value).color)
                    Text("\(focus == nil ? kind.title : focusLabel) · \(DayFmt.relative(p.date))")
                        .font(Obs.sans(11)).foregroundStyle(Obs.ink2)
                }
                Spacer()
                Button { onOpenDay(p.date) } label: {
                    HStack(spacing: 4) { Text("Day"); Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)) }
                        .font(Obs.sans(12, .medium)).foregroundStyle(Obs.ink)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Obs.raised, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Text("No \(kind.title.lowercased()) scores yet").font(Obs.sans(13)).foregroundStyle(Obs.ink2)
            }
        }
        .frame(minHeight: 52)
    }

    private var stats: some View {
        let means = Stats.periodMeans(all, end: day, days: period)
        let hi = window.max { $0.value < $1.value }, lo = window.min { $0.value < $1.value }
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                StatCell(label: "Average", value: means.now.map { String(format: "%.0f", $0) } ?? "–")
                if focus == nil, let n = means.now, let b = means.before {
                    DeltaBadge(delta: n - b, unit: "vs prior \(period)d", higherIsBetter: true, reference: b, threshold: 0.03)
                }
            }
            StatCell(label: "Scored", value: "\(window.count)", unit: "/ \(windowDays.count) days")
            StatCell(label: "Highest", value: hi.map { String(format: "%.0f", $0.value) } ?? "–", sub: hi.map { DayFmt.short($0.date) })
            StatCell(label: "Lowest", value: lo.map { String(format: "%.0f", $0.value) } ?? "–", sub: lo.map { DayFmt.short($0.date) })
        }
        .surface()
    }

    private var contributorSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(title: "Contributors", icon: kind.icon, tint: kind.tint, trailing: DayFmt.short(focusDay))
            VStack(spacing: 12) {
                ForEach(contributors) { c in
                    Button { focus = focus == c.key ? nil : c.key } label: {
                        ContributorRow(contributor: c, tint: ScoreBand(c.value).color, highlighted: focus == c.key,
                                       average: Stats.mean(inWindow(s.contributorSeries(kind, key: c.key, upTo: day)).map(\.value)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .surface()
            SectionLabel(title: "History by contributor")
            Heatmap(rows: contributors.map { c in
                        Heatmap.Row(id: c.key, label: c.label,
                                    values: Dictionary(uniqueKeysWithValues: s.contributorSeries(kind, key: c.key, upTo: day)
                                        .map { ($0.date, $0.value) }))
                    },
                    days: windowDays, selectedRow: focus, onTap: { focus = focus == $0 ? nil : $0 })
                .surface()
        }
    }
}

/// One contributor on one line: label, weight, bar, optional period average, value.
struct ContributorRow: View {
    let contributor: Contributor
    var tint: Color
    var highlighted = false
    var average: Double? = nil
    var body: some View {
        HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(contributor.label).font(Obs.sans(11, highlighted ? .medium : .regular)).foregroundStyle(Obs.ink)
                    .lineLimit(1).minimumScaleFactor(0.75)
                if let w = contributor.weight {
                    Text("\(Int((w * 100).rounded()))").font(Obs.sans(10)).foregroundStyle(Obs.muted)
                }
            }
            .frame(width: 138, alignment: .leading)
            BandBar(value: contributor.value, color: tint, height: 6, ticks: false)
            if let average {
                Text("\(Int(average.rounded()))").font(Obs.sans(11)).foregroundStyle(Obs.muted)
                    .frame(width: 24, alignment: .trailing)
            }
            Text("\(Int(contributor.value.rounded()))").font(Obs.sans(13, .medium)).foregroundStyle(Obs.ink)
                .monospacedDigit().frame(width: 28, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .background(highlighted ? tint.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

/// Contributors as one row of columns: width is the weight in the score, fill height is the
/// value. Labels sit below on two staggered rows, each centered on its bar with a tick to the
/// bar's center. A label may be as wide as twice the distance to the nearest neighbor center,
/// which keeps it clear of the ticks on the other row and of the labels on its own row.
struct ContributorStrip: View {
    let contributors: [Contributor]

    private func weight(_ c: Contributor) -> Double { c.weight ?? 0.08 }
    private let barH: CGFloat = 34, valueH: CGFloat = 14, gap: CGFloat = 3
    @State private var twoLines = false
    private var lines: Int { twoLines ? 2 : 1 }
    private var rowH: CGFloat { twoLines ? 22 : 12 }

    var body: some View {
        let n = contributors.count
        let total = contributors.map(weight).reduce(0, +)
        GeometryReader { geo in
            let usable = geo.size.width - gap * CGFloat(n - 1)
            let widths = contributors.map { max(18, usable * weight($0) / total) }
            let xs: [CGFloat] = widths.indices.map { i in widths[..<i].reduce(0, +) + gap * CGFloat(i) }
            let centers: [CGFloat] = widths.indices.map { xs[$0] + widths[$0] / 2 }
            let barBottom = valueH + 2 + barH
            let labelWs: [CGFloat] = centers.indices.map { i in
                // the card's padding lets the end labels overhang the bars by 14 pt
                let nearest = min(i > 0 ? centers[i] - centers[i - 1] : .infinity,
                                  i < n - 1 ? centers[i + 1] - centers[i] : .infinity,
                                  centers[i] + 14, geo.size.width - centers[i] + 14)
                return 2 * nearest - 6
            }
            // a second text line only when some label does not fit on one (9 pt mono is ~5.4 pt a character)
            let needsTwo = contributors.indices.contains { CGFloat(contributors[$0].label.count) * 5.4 > labelWs[$0] }
            ZStack(alignment: .topLeading) {
                Color.clear.onAppear { twoLines = needsTwo }.onChange(of: needsTwo) { twoLines = $0 }
                ForEach(Array(contributors.enumerated()), id: \.element.id) { i, c in
                    let lower = i % 2 == 1
                    let labelW = labelWs[i]
                    Text("\(Int(c.value.rounded()))").font(Obs.sans(11, .medium)).monospacedDigit()
                        .foregroundStyle(Obs.ink)
                        .frame(width: widths[i], height: valueH)
                        .offset(x: xs[i])
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Obs.rule)
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(ScoreGradient.color(c.value))
                            .frame(height: max(3, barH * min(1, c.value / 100)))
                    }
                    .frame(width: widths[i], height: barH)
                    .offset(x: xs[i], y: valueH + 2)
                    Rectangle().fill(Obs.muted.opacity(0.6))
                        .frame(width: 1, height: lower ? rowH + 7 : 4)
                        .offset(x: centers[i] - 0.5, y: barBottom + 1)
                    Text(c.label).font(Obs.sans(11)).foregroundStyle(Obs.ink2)
                        .lineLimit(lines).minimumScaleFactor(0.7).multilineTextAlignment(.center)
                        .frame(width: labelW, height: rowH, alignment: .top)
                        .offset(x: centers[i] - labelW / 2, y: barBottom + 5 + (lower ? rowH + 4 : 0))
                }
            }
        }
        .frame(height: valueH + 2 + barH + 5 + rowH + 4 + rowH)
    }
}

// ── metric detail ────────────────────────────────────────────────────────────

struct MetricDetailView: View {
    let s: Summary
    let id: MetricID
    let day: String
    var onOpenDay: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var period = 30
    @State private var selection: Int?

    private var metric: Metric { s.metric(id, upTo: day) }
    private var windowDays: [String] { s.calendarDays(upTo: day, count: period) }
    private var window: [DatedValue] { let set = Set(windowDays); return metric.series.filter { set.contains($0.date) } }
    private var tint: Color { metric.score?.tint ?? Obs.chart }

    var body: some View {
        let m = metric
        NavigationStack {
            ZStack {
                Obs.canvas
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        PeriodPicker(days: $period)
                        readout(m)
                        if window.count > 1 {
                            TrendChart(points: window, style: .line, tint: tint,
                                       reference: m.baseline ?? Stats.mean(window.map(\.value)),
                                       height: 170, decimals: m.decimals, axis: windowDays, selection: $selection)
                            if m.baseline != nil {
                                Text("Dashed line: personal baseline").font(Obs.sans(11)).foregroundStyle(Obs.muted)
                            } else {
                                Text("Dashed line: period average").font(Obs.sans(11)).foregroundStyle(Obs.muted)
                            }
                        }
                        stats(m)
                        table(m)
                    }
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 32)
                }
            }
            .navigationTitle(m.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .onChange(of: period) { _, _ in selection = nil }
    }

    private func readout(_ m: Metric) -> some View {
        let p = selection.flatMap { window.indices.contains($0) ? window[$0] : nil } ?? window.last
        return HStack(alignment: .firstTextBaseline) {
            if let p {
                Figure(value: m.text(p.value), unit: m.unit, size: 46)
                Text(DayFmt.relative(p.date)).font(Obs.sans(11)).foregroundStyle(Obs.ink2)
                Spacer()
                Button { onOpenDay(p.date) } label: {
                    HStack(spacing: 4) { Text("Day"); Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)) }
                        .font(Obs.sans(12, .medium)).foregroundStyle(Obs.ink)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Obs.raised, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Text("No data yet").font(Obs.sans(13)).foregroundStyle(Obs.ink2)
            }
        }
        .frame(minHeight: 52)
    }

    private func stats(_ m: Metric) -> some View {
        let v = window.map(\.value)
        let means = Stats.periodMeans(metric.series, end: day, days: period)
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                StatCell(label: "Average", value: means.now.map(m.text) ?? "–", unit: m.unit)
                if let n = means.now, let b = means.before {
                    DeltaBadge(delta: n - b, unit: "vs prior \(period)d", decimals: m.decimals,
                               higherIsBetter: m.higherIsBetter, reference: b)
                }
            }
            StatCell(label: "Days", value: "\(v.count)", unit: "of \(windowDays.count)")
            StatCell(label: "Lowest", value: v.min().map(m.text) ?? "–", unit: m.unit,
                     sub: window.min { $0.value < $1.value }.map { DayFmt.short($0.date) })
            StatCell(label: "Highest", value: v.max().map(m.text) ?? "–", unit: m.unit,
                     sub: window.max { $0.value < $1.value }.map { DayFmt.short($0.date) })
        }
        .surface()
    }

    /// Every day in the window, newest first; a row opens that day.
    private func table(_ m: Metric) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Daily values")
            VStack(spacing: 0) {
                ForEach(Array(window.reversed().enumerated()), id: \.element.id) { i, p in
                    Button { onOpenDay(p.date) } label: {
                        HStack {
                            Text(DayFmt.relative(p.date)).font(Obs.sans(12)).foregroundStyle(Obs.ink2)
                            Spacer()
                            Text(m.text(p.value)).font(Obs.sans(13, .medium)).foregroundStyle(Obs.ink).monospacedDigit()
                            Text(m.unit).font(Obs.sans(11)).foregroundStyle(Obs.muted).frame(width: 40, alignment: .leading)
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Obs.muted)
                        }
                        .padding(.vertical, 10).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if i < window.count - 1 { Rectangle().fill(Obs.rule).frame(height: 0.6) }
                }
            }
            .surface(padding: 14)
        }
    }
}

// ── history ──────────────────────────────────────────────────────────────────

/// Every day as a table row: the three scores, time asleep and steps. Choosing a row
/// makes it the day shown on Today and Vitals.
struct HistoryView: View {
    let s: Summary
    let selected: String
    var onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private static let month: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate("MMMM yyyy"); return f
    }()

    private var groups: [(title: String, days: [String])] {
        var out: [(String, [String])] = []
        for day in s.days {
            let title = DayFmt.date(day).map { Self.month.string(from: $0) } ?? "Undated"
            if let last = out.last, last.0 == title { out[out.count - 1].1.append(day) } else { out.append((title, [day])) }
        }
        return out.map { (title: $0.0, days: $0.1) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Obs.canvas
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups, id: \.title) { group in
                            Section {
                                ForEach(group.days, id: \.self) { day in
                                    Button { onSelect(day); dismiss() } label: { row(day) }
                                        .buttonStyle(.plain)
                                    Rectangle().fill(Obs.rule).frame(height: 0.6)
                                }
                            } header: {
                                HStack(spacing: 0) {
                                    Text(group.title).font(Obs.sans(11, .medium))
                                    Spacer()
                                    ForEach(ScoreKind.allCases) {
                                        Text($0.short).font(Obs.sans(10)).frame(width: 34)
                                    }
                                    Text("Asleep").font(Obs.sans(10)).frame(width: 62, alignment: .trailing)
                                    Text("Steps").font(Obs.sans(10)).frame(width: 46, alignment: .trailing)
                                }
                                .foregroundStyle(Obs.muted)
                                .padding(.vertical, 8).padding(.horizontal, 20)
                                .background(Obs.paper)
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private func row(_ day: String) -> some View {
        let asleep = s.night(forDay: day)?.asleepH
        let steps = s.activity_daily[day]?.steps
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(DayFmt.weekday(day)).font(Obs.sans(11)).foregroundStyle(Obs.muted)
                Text(DayFmt.dayNumber(day)).font(Obs.sans(16, .medium)).foregroundStyle(Obs.ink).monospacedDigit()
            }
            .frame(width: 44, alignment: .leading)
            Spacer(minLength: 0)
            ForEach(ScoreKind.allCases) { k in
                let v = k.value(s, day)
                ZStack {
                    RingGauge(value: v, color: v.map { ScoreBand($0).color } ?? Obs.rule, lineWidth: 3)
                    Text(v.map { String(format: "%.0f", $0) } ?? "–").font(Obs.sans(11, .medium))
                        .foregroundStyle(v == nil ? Obs.muted : Obs.ink).monospacedDigit()
                }
                .frame(width: 30, height: 30).frame(width: 34)
            }
            Text(asleep.map { fmtMinutes($0 * 60) } ?? "–").font(Obs.sans(11)).foregroundStyle(asleep == nil ? Obs.muted : Obs.ink)
                .frame(width: 62, alignment: .trailing)
            Text(steps.map { String(format: "%.1fk", $0 / 1000) } ?? "–").font(Obs.sans(11))
                .foregroundStyle(steps == nil ? Obs.muted : Obs.ink).frame(width: 46, alignment: .trailing)
        }
        .padding(.vertical, 8).padding(.horizontal, 20)
        .background(day == selected ? Obs.raised : Color.clear)
        .contentShape(Rectangle())
    }
}

// ── symptom radar ────────────────────────────────────────────────────────────

private let radarOrder = ["AverageBreath", "LowestHeartRate", "AverageHrv", "TemperatureDeviation"]

enum RadarStyle {
    static func status(_ r: IllnessResult) -> (word: String, color: Color) {
        switch r.trafficLight {
        case "NO_SIGNS": return ("No signs", Obs.good)
        case "MINOR_SIGNS": return ("Minor signs", Obs.bad)
        case "MAJOR_SIGNS": return ("Major signs", Obs.alert)
        default: return ("No result", Obs.muted)
        }
    }
    static func name(_ type: String) -> String {
        ["AverageBreath": "Breathing rate", "LowestHeartRate": "Lowest heart rate",
         "AverageHrv": "HRV", "TemperatureDeviation": "Temperature"][type] ?? type
    }
    static func unit(_ type: String) -> String {
        ["AverageBreath": "br/min", "LowestHeartRate": "bpm", "AverageHrv": "ms", "TemperatureDeviation": "°C"][type] ?? ""
    }
    static func decimals(_ type: String) -> Int { type == "AverageBreath" || type == "TemperatureDeviation" ? 1 : 0 }
}

/// Today's compact radar card: the status and the four overnight measurements against
/// their personal ranges.
struct RadarCard: View {
    let illness: IllnessResult
    var action: () -> Void
    @Environment(\.radarAnalyzing) private var analyzing
    var body: some View {
        let st = RadarStyle.status(illness)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(title: "Symptom radar", icon: "cross.case.fill", tint: Obs.readyTint,
                             trailing: analyzing ? "updating…" : (illness.date.isEmpty ? nil : DayFmt.short(illness.date)), chevron: true)
                Figure(value: illness.available ? st.word : "Learning your baseline", size: 24, color: illness.available ? st.color : Obs.ink2)
                if illness.available {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(radarOrder, id: \.self) { type in
                            if let b = illness.biomarkers.first(where: { $0.type == type }) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 4) {
                                        Circle().fill(b.indicatesSymptoms ? Obs.alert : Obs.good).frame(width: 6, height: 6)
                                        Text(RadarStyle.name(type)).font(Obs.sans(10)).foregroundStyle(Obs.muted)
                                            .lineLimit(1).minimumScaleFactor(0.7)
                                    }
                                    Text(String(format: "%.\(RadarStyle.decimals(type))f", b.value))
                                        .font(Obs.sans(15, .medium)).foregroundStyle(Obs.ink).monospacedDigit()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .surface()
    }
}

/// Today's card while the radar is being computed and there is no earlier result.
struct RadarPendingCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title: "Symptom radar", icon: "cross.case.fill", tint: Obs.readyTint)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(Obs.ink)
                Text("Analyzing your nights").font(Obs.sans(12)).foregroundStyle(Obs.ink2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
    }
}

/// The radar's four biomarkers over time, each against its personal range.
struct RadarDetailView: View {
    @Environment(\.radarAnalyzing) private var analyzing
    let s: Summary
    let illness: IllnessResult
    let day: String
    @Environment(\.dismiss) private var dismiss
    @State private var period = 30

    private func series(for type: String) -> [DatedValue] {
        switch type {
        case "AverageBreath": return s.metric(.breath, upTo: day).series
        case "LowestHeartRate": return s.metric(.restingHR, upTo: day).series
        case "AverageHrv": return s.metric(.hrv, upTo: day).series
        default:
            // skin temperature against the mean of the nights before it (up to 30)
            let raw = s.metric(.temp, upTo: day).series
            return raw.enumerated().compactMap { i, p in
                let prior = raw[max(0, i - 30)..<i].map(\.value)
                guard prior.count >= 3, let m = Stats.mean(prior) else { return nil }
                return DatedValue(date: p.date, value: p.value - m)
            }
        }
    }

    var body: some View {
        let st = RadarStyle.status(illness)
        let days = s.calendarDays(upTo: day, count: period)
        NavigationStack {
            ZStack {
                Obs.canvas
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Figure(value: illness.available ? st.word : "Learning", size: 32, color: illness.available ? st.color : Obs.ink2)
                            Spacer()
                            Text("\(illness.daysWithData) nights of data").font(Obs.sans(11)).foregroundStyle(Obs.muted)
                        }
                        if analyzing {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small).tint(Obs.ink)
                                Text("Updating with the latest night").font(Obs.sans(11)).foregroundStyle(Obs.ink2)
                            }
                        }
                        PeriodPicker(days: $period)
                        ForEach(radarOrder, id: \.self) { type in
                            let b = illness.biomarkers.first { $0.type == type }
                            BiomarkerCard(type: type, biomarker: b, days: days,
                                          points: series(for: type).filter { days.contains($0.date) })
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 32)
                }
            }
            .navigationTitle("Symptom radar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

private struct BiomarkerCard: View {
    let type: String
    let biomarker: IllnessBiomarker?
    let days: [String]
    let points: [DatedValue]
    @State private var selection: Int?

    var body: some View {
        let unit = RadarStyle.unit(type), dec = RadarStyle.decimals(type)
        let shown = selection.flatMap { points.indices.contains($0) ? points[$0] : nil } ?? points.last
        let flagged = biomarker?.indicatesSymptoms ?? false
        let band = biomarker.flatMap { b -> ClosedRange<Double>? in
            type != "TemperatureDeviation" && b.lower.isFinite && b.upper.isFinite && b.lower <= b.upper ? b.lower...b.upper : nil
        }
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title: RadarStyle.name(type), trailing: flagged ? (biomarker?.reason == "DECREASED" ? "below usual" : "above usual") : nil)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Figure(value: shown.map { String(format: "%.\(dec)f", $0.value) } ?? "–", unit: unit, size: 28,
                       color: flagged && selection == nil ? Obs.alert : Obs.ink)
                if let shown { Text(DayFmt.relative(shown.date)).font(Obs.sans(11)).foregroundStyle(Obs.ink2) }
                Spacer()
            }
            if points.count > 1 {
                TrendChart(points: points, style: .line, tint: Obs.readyTint, reference: type == "TemperatureDeviation" ? 0 : nil,
                           height: 120, decimals: dec, axis: days, band: band, selection: $selection)
            } else {
                Text("Not enough nights in this period").font(Obs.sans(11)).foregroundStyle(Obs.muted)
            }
            if let b = biomarker, let band {
                Text("Personal range \(String(format: "%.\(dec)f", b.lower)) to \(String(format: "%.\(dec)f", b.upper)) \(unit)")
                    .font(Obs.sans(11)).foregroundStyle(Obs.muted)
            } else if type == "TemperatureDeviation" {
                Text("Skin temperature minus the mean of the nights before").font(Obs.sans(11)).foregroundStyle(Obs.muted)
            }
        }
        .surface()
    }
}

// ── sleep debt ───────────────────────────────────────────────────────────────

/// Cumulative debt and nightly sleep against the personal need, with every day listed.
struct DebtDetailView: View {
    let s: Summary
    let day: String
    var onOpenDay: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0     // 0 cumulative debt, 1 total sleep
    @State private var selection: Int?

    private var debt: SleepDebtSummary? { s.sleepDebt?.asOf(day) }
    private var rows: [SleepDebtDay] { (s.sleepDebt?.days ?? []).filter { $0.date <= day } }
    private var points: [DatedValue] {
        rows.compactMap { r in
            (mode == 0 ? r.cumulative_debt_min : r.total_sleep_min).map { DatedValue(date: r.date, value: $0 / 60) }
        }
    }

    /// Why the need is what it is, and the days it moved.
    @ViewBuilder private var needCard: some View {
        if let all = s.sleepDebt, let note = all.need_note, !note.isEmpty {
            let changes = (all.need_changes ?? []).filter { $0.date <= day }
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(title: all.need_source == "manual" ? "Sleep need, set by you" : "Sleep need, estimated",
                             icon: "moon.zzz.fill", tint: Obs.sleepTint)
                Text(note).font(Obs.sans(12)).foregroundStyle(Obs.ink2).fixedSize(horizontal: false, vertical: true)
                if all.need_source != "manual" {
                    if changes.isEmpty {
                        Text("The need did not change in these 14 days.").font(Obs.sans(11)).foregroundStyle(Obs.muted)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(changes.reversed()) { c in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(DayFmt.relative(c.date)): \(fmtMinutes(c.from_min)) to \(fmtMinutes(c.to_min))")
                                        .font(Obs.sans(12, .medium)).foregroundStyle(Obs.ink).monospacedDigit()
                                    Text(c.reason.prefix(1).uppercased() + c.reason.dropFirst())
                                        .font(Obs.sans(11)).foregroundStyle(Obs.muted)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(padding: 14)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Obs.canvas
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let debt {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Figure(value: debt.valid ? fmtMinutes(debt.debt_min) : "\(debt.valid_days) of 5 nights", size: 34,
                                       color: debt.valid ? Obs.debt(debt.state) : Obs.ink2)
                                if debt.valid {
                                    Text(debt.state).font(Obs.sans(11, .medium)).foregroundStyle(Obs.debt(debt.state))
                                }
                                Spacer()
                                Text("need \(String(format: "%.1f", debt.need_h)) h").font(Obs.sans(11)).foregroundStyle(Obs.muted)
                            }
                        }
                        Picker("Series", selection: $mode) {
                            Text("Debt").tag(0)
                            Text("Total sleep").tag(1)
                        }.pickerStyle(.segmented)
                        if points.count > 1 {
                            TrendChart(points: points, style: .line, tint: Obs.sleepTint,
                                       reference: mode == 1 ? debt?.need_h : nil, height: 170, decimals: 1,
                                       axis: rows.map(\.date), selection: $selection)
                            Text(mode == 1 ? "Dashed line: sleep need, hours" : "Hours of cumulative debt")
                                .font(Obs.sans(11)).foregroundStyle(Obs.muted)
                        }
                        needCard
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("DAY").frame(maxWidth: .infinity, alignment: .leading)
                                Text("Sleep").frame(width: 56, alignment: .trailing)
                                Text("Short").frame(width: 56, alignment: .trailing)
                                Text("DEBT").frame(width: 62, alignment: .trailing)
                            }
                            .font(Obs.sans(11, .medium)).foregroundStyle(Obs.muted)
                            VStack(spacing: 0) {
                                ForEach(Array(rows.reversed().enumerated()), id: \.element.id) { i, r in
                                    Button { onOpenDay(r.date) } label: {
                                        HStack {
                                            Text(DayFmt.relative(r.date)).font(Obs.sans(12)).foregroundStyle(Obs.ink2)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            Text(r.total_sleep_min.map(fmtMinutes) ?? "–").frame(width: 56, alignment: .trailing)
                                            Text(r.shortfall_min.map { $0 > 0 ? fmtMinutes($0) : "–" } ?? "–").frame(width: 56, alignment: .trailing)
                                            Text(r.cumulative_debt_min.map(fmtMinutes) ?? "–").frame(width: 62, alignment: .trailing)
                                                .foregroundStyle(r.cumulative_debt_min == nil ? Obs.muted : (r.state.map(Obs.debt) ?? Obs.ink))
                                        }
                                        .font(Obs.sans(12)).foregroundStyle(Obs.ink).monospacedDigit()
                                        .padding(.vertical, 9).contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    if i < rows.count - 1 { Rectangle().fill(Obs.rule).frame(height: 0.6) }
                                }
                            }
                        }
                        .surface(padding: 14)
                    }
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 32)
                }
            }
            .navigationTitle("Sleep debt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
