import SwiftUI

// The three home tabs. Each is a composition of the marks in Viz.swift over the shared
// summary: Today (one day, scores down to contributors and the day's sleep, activity and
// body), Vitals (every metric as a tile with its recent series), Trends (a period of
// scores and contributors). Everything opens a deeper view through `Route`.
// SIBLING CLIENT: the web dashboard renders the same JSON (docs/clients-web-and-ios.md).

enum Route {
    case score(ScoreKind)
    case metric(MetricID)
    case vital(VitalKind)
    case debt, radar, allDays, activities, vo2
    case day(String, sleep: Bool)
}

enum AppTab: String { case today, vitals, trends }

func fmtMinutes(_ m: Double) -> String {
    let t = Int(m.rounded())
    return t >= 60 ? "\(t / 60)h \(String(format: "%02d", t % 60))m" : "\(t)m"
}

private let tileColumns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

// ── shared pieces ────────────────────────────────────────────────────────────

/// Scrollable strip of recent days; each shows the selected score's ring.
struct DayStrip: View {
    let s: Summary
    let kind: ScoreKind
    let selected: String
    var onSelect: (String) -> Void
    /// A tap on a chip must not scroll the strip; only a change from outside (a swipe of the
    /// panels, History) brings the selected chip into view.
    @State private var tapped = false
    var body: some View {
        let days = Array(s.days.prefix(45).reversed())
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(days, id: \.self) { d in
                        let v = kind.value(s, d)
                        Button { if d != selected { tapped = true }; onSelect(d) } label: {
                            VStack(spacing: 5) {
                                HStack(alignment: .firstTextBaseline, spacing: 2) {
                                    Text(DayFmt.letter(d)).font(Obs.sans(11, .medium)).foregroundStyle(Obs.ink2)
                                    Text(DayFmt.dayNumber(d)).font(Obs.sans(10)).foregroundStyle(Obs.muted)
                                }
                                ZStack {
                                    RingGauge(value: v, color: v.map { ScoreBand($0).color } ?? Obs.rule, lineWidth: 3.5)
                                    Text(v.map { String(format: "%.0f", $0) } ?? "–")
                                        .font(Obs.sans(12, d == selected ? .medium : .regular)).monospacedDigit()
                                        .foregroundStyle(v == nil ? Obs.muted : Obs.ink)
                                }
                                .frame(width: 38, height: 38)
                            }
                            .padding(.vertical, 6).padding(.horizontal, 5)
                            .background(d == selected ? Obs.raised : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain).id(d)
                    }
                }
                .padding(.horizontal, 20)
            }
            .onAppear { proxy.scrollTo(selected, anchor: .center) }
            .onChange(of: selected) { _, d in
                if tapped { tapped = false; return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(d, anchor: .center) }
            }
        }
        .padding(.horizontal, -20)
    }
}

/// A MetricTile for one `MetricID`, with its last 14 days, as a button into the detail.
struct MetricTileButton: View {
    let s: Summary
    let id: MetricID
    let day: String
    let open: (Route) -> Void
    @Environment(\.openRingCapture) private var openRingCapture
    var body: some View {
        let m = s.metric(id, upTo: day, count: 14)
        let latest = m.latest
        let values = m.series.map(\.value)
        let need: CaptureNeed? = latest != nil ? nil : (id == .spo2 ? .bloodOxygen : (id == .restingHR ? .restingHR : nil))
        Button {
            if need != nil { openRingCapture() } else { open(id == .restingHR ? .vital(.heartRate) : .metric(id)) }
        } label: {
            MetricTile(title: m.title, value: latest.map { m.text($0.value) } ?? "–", unit: m.unit,
                       icon: m.icon, tint: m.score?.tint ?? Obs.muted,
                       status: latest.flatMap { $0.date == day ? nil : DayFmt.short($0.date) },
                       delta: Stats.delta(m.series).map {
                           DeltaBadge(delta: $0, decimals: m.decimals, higherIsBetter: m.higherIsBetter,
                                      reference: Stats.mean(values))
                       },
                       series: values, baseline: m.baseline, missing: need)
        }
        .buttonStyle(.plain)
    }
}

/// A MetricTile for a score: value, band, and the last 14 days as bars.
struct ScoreTileButton: View {
    let s: Summary
    let kind: ScoreKind
    let day: String
    let open: (Route) -> Void
    var body: some View {
        let series = s.scoreSeries(kind, upTo: day, count: 14)
        let v = series.last
        Button { open(.score(kind)) } label: {
            MetricTile(title: kind.title, value: v.map { String(format: "%.0f", $0.value) } ?? "–",
                       icon: kind.icon, tint: kind.tint,
                       status: v.map { $0.date == day ? ScoreBand($0.value).title : DayFmt.short($0.date) },
                       statusColor: v.map { ScoreBand($0.value).color } ?? Obs.muted,
                       series: series.map(\.value), scored: true)
        }
        .buttonStyle(.plain)
    }
}


/// Day pages side by side, oldest on the left, swiped horizontally; each page scrolls
/// vertically on its own. `selection` follows the page and moves it when set elsewhere.
struct DayPages<Page: View>: View {
    let days: [String]               // newest first
    let selection: String
    var onSelect: (String) -> Void
    @ViewBuilder let page: (String) -> Page
    @State private var position: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(Array(days.reversed()), id: \.self) { d in
                    page(d)
                        .containerRelativeFrame(.horizontal)
                        .id(d)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $position, anchor: .leading)
        .onAppear { position = selection }
        .onChange(of: position) { _, new in
            if let new, new != selection { onSelect(new) }
        }
        .onChange(of: selection) { _, new in
            // chosen in the strip or History: switch panels in place, no slide through the days between
            if new != position {
                var t = Transaction(animation: nil)
                t.disablesAnimations = true
                withTransaction(t) { position = new }
            }
        }
    }
}

// ── Today ────────────────────────────────────────────────────────────────────

struct TodayPage: View {
    @Environment(\.radarAnalyzing) private var radarAnalyzing
    let s: Summary
    let day: String
    let sync: ScrollSync
    let isActive: Bool
    @ObservedObject var live: LiveHeartRate
    @ObservedObject var ring: RingSync
    @Binding var kind: ScoreKind
    var open: (Route) -> Void
    let notes: AnyView

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                scoreRow
                contributorCard
                sleepCard
                activityCard
                ActivitiesCard(s: s, day: day, store: ActivityLogStore.shared) { open(.activities) }
                LiveHeartRateCard(live: live, ring: ring)
                bodyGrid
                if let debt = s.sleepDebt?.asOf(day) {
                    DebtCard(s: s, debt: debt, day: day) { open(.debt) }
                }
                if day == s.days.first, let radar = s.symptomRadar, radar.available {
                    RadarCard(illness: radar) { open(.radar) }
                } else if day == s.days.first, radarAnalyzing {
                    RadarPendingCard()
                }
                notes
            }
            .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 96)
        }
        .scrollIndicators(.hidden)
        .syncedScroll(sync, active: isActive)
    }

    // three scores, selecting which one the breakdown below shows
    private var scoreRow: some View {
        HStack(spacing: 10) {
            ForEach(ScoreKind.allCases) { k in
                let v = k.value(s, day)
                let band = v.map { ScoreBand($0) }
                Button { withAnimation(.easeOut(duration: 0.18)) { kind = k } } label: {
                    VStack(spacing: 8) {
                        ZStack {
                            RingGauge(value: v, color: band?.color ?? Obs.rule, lineWidth: 7)
                            Text(v.map { String(format: "%.0f", $0) } ?? "–")
                                .font(Obs.sans(24, .medium)).foregroundStyle(Obs.ink).monospacedDigit()
                        }
                        .frame(width: 78, height: 78)
                        HStack(spacing: 4) {
                            Image(systemName: k.icon).font(.system(size: 10)).foregroundStyle(k.tint)
                            Text(k.title).font(Obs.sans(11, kind == k ? .medium : .regular)).foregroundStyle(Obs.ink)
                        }
                        Text((band?.title ?? "No score")).font(Obs.sans(11, .medium))
                            .foregroundStyle(band?.color ?? Obs.muted)
                    }
                    .padding(.vertical, 12).frame(maxWidth: .infinity)
                    .background(Obs.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(kind == k ? k.tint : Color.clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // contributors of the selected score, with its change against the recent average
    @AppStorage("contributors.list") private var contributorList = false
    @AppStorage("contributors.collapsed") private var contributorsCollapsed = false

    private var contributorCard: some View {
        let list = kind.contributors(s, day)
        let series = s.scoreSeries(kind, upTo: day, count: 15)
        let todays = kind.value(s, day)
        let prior = series.filter { $0.date < day }.suffix(14).map(\.value)
        return VStack(alignment: .leading, spacing: 14) {
            Button { open(.score(kind)) } label: {
                SectionLabel(title: "\(kind.title) contributors", icon: kind.icon, tint: kind.tint,
                             trailing: "history", chevron: true)
            }
            .buttonStyle(.plain)
            HStack(spacing: 8) {
                if let v = todays, let avg = Stats.mean(prior) {
                    Text("14-day average \(Int(avg.rounded()))").font(Obs.sans(11)).foregroundStyle(Obs.ink2)
                    DeltaBadge(delta: v - avg, higherIsBetter: true, reference: avg, threshold: 0.03)
                }
                Spacer()
                if !list.isEmpty {
                    if !contributorsCollapsed {
                        iconButton(contributorList ? "chart.bar.fill" : "list.bullet",
                                   label: contributorList ? "Show columns" : "Show list") { contributorList.toggle() }
                    }
                    iconButton(contributorsCollapsed ? "chevron.down" : "chevron.up",
                               label: contributorsCollapsed ? "Expand contributors" : "Collapse contributors") {
                        contributorsCollapsed.toggle()
                    }
                }
            }
            if contributorsCollapsed {
                EmptyView()
            } else if list.isEmpty {
                Text(todays == nil ? "No \(kind.title.lowercased()) score for this day" : "No contributors for this day")
                    .font(Obs.sans(12)).foregroundStyle(Obs.muted)
            } else if contributorList {
                VStack(spacing: 12) {
                    ForEach(list) { c in
                        Button { open(.score(kind)) } label: {
                            ContributorRow(contributor: c, tint: ScoreBand(c.value).color)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                ContributorStrip(contributors: list)
            }
        }
        .surface()
    }

    private func iconButton(_ symbol: String, label: String, _ action: @escaping () -> Void) -> some View {
        Button { withAnimation(.easeOut(duration: 0.2)) { action() } } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Obs.ink2)
                .frame(width: 30, height: 26)
                .background(Obs.paper.opacity(0.7), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // last night
    @ViewBuilder private var sleepCard: some View {
        if let n = s.night(forDay: day) {
            Button { open(.day(day, sleep: true)) } label: {
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel(title: "Sleep", icon: "moon.fill", tint: Obs.sleepTint,
                                 trailing: "\(n.start ?? "–") → \(n.end ?? "–")", chevron: true)
                    if let h = n.hypnogram, n.hasHypnogram {
                        let mins = { (code: Double) in Double(h.filter { $0 == Int(code) }.count) / 2 }
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Figure(value: n.asleepH.map { fmtMinutes($0 * 60) } ?? fmtMinutes((n.in_bed_h ?? 0) * 60), size: 30)
                            Text(n.asleepH == nil ? "in bed" : "asleep").font(Obs.sans(11)).foregroundStyle(Obs.muted)
                        }
                        Hypnogram(stages: h, height: 46)
                        StackedBar(segments: [
                            .init(label: "Deep", value: mins(1), color: Obs.deep, text: fmtMinutes(mins(1))),
                            .init(label: "REM", value: mins(3), color: Obs.rem, text: fmtMinutes(mins(3))),
                            .init(label: "Light", value: mins(2), color: Obs.light, text: fmtMinutes(mins(2))),
                            .init(label: "Awake", value: mins(4), color: Obs.wake, text: fmtMinutes(mins(4))),
                        ])
                    } else {
                        Figure(value: fmtMinutes((n.in_bed_h ?? 0) * 60), size: 30)
                        Text("in bed").font(Obs.sans(11)).foregroundStyle(Obs.muted)
                    }
                    HStack(alignment: .top, spacing: 8) {
                        StatCell(label: "Efficiency", value: n.efficiency.map { String(format: "%.0f", $0) } ?? "–", unit: "%")
                        StatCell(label: "Resting HR", value: n.rhr.map { String(format: "%.0f", $0) } ?? "–", unit: "bpm")
                        StatCell(label: "HRV", value: n.hrv_ms.map { String(format: "%.0f", $0) } ?? "–", unit: "ms")
                        StatCell(label: "Breathing", value: n.breath_rate.map { String(format: "%.1f", $0) } ?? "–")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .surface()
        }
    }

    // that day's movement
    @ViewBuilder private var activityCard: some View {
        let st = s.activity_daily[day]
        let profile = s.activity_profile[day] ?? []
        if st != nil || !profile.isEmpty {
            Button { open(.day(day, sleep: false)) } label: {
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel(title: "Activity", icon: "flame.fill", tint: Obs.activityTint, chevron: true)
                    if let st {
                        progressRow("Steps", value: st.steps, target: st.target_steps, unit: "")
                        progressRow("Active energy", value: st.active_kcal, target: st.target_kcal, unit: "kcal")
                        if let c = st.class_min {
                            let m = { (k: String) in c[k] ?? 0 }
                            StackedBar(segments: [
                                .init(label: "Still", value: m("sedentary"), color: Obs.chart.opacity(0.5), text: fmtMinutes(m("sedentary"))),
                                .init(label: "Light", value: m("light"), color: Obs.activityTint.opacity(0.5), text: fmtMinutes(m("light"))),
                                .init(label: "Mod", value: m("moderate"), color: Obs.activityTint, text: fmtMinutes(m("moderate"))),
                                .init(label: "Vig", value: m("vigorous"), color: Obs.alert, text: fmtMinutes(m("vigorous"))),
                            ])
                        }
                    }
                    if profile.count > 1 {
                        MovementRidge(profile: profile, height: 44, nowHour: hourNow(on: day))
                    }
                    ForEach(Array(s.workoutsOn(day).prefix(3))) { w in
                        SessionRow(label: w.label, durationMin: w.durationMin, startHM: w.startHM)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .surface()
        }
    }

    private func progressRow(_ label: String, value: Double?, target: Double?, unit: String) -> some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(Obs.sans(12)).foregroundStyle(Obs.ink2)
                Spacer()
                Text(value.map { Int($0).formatted() } ?? "–").font(Obs.sans(16, .medium)).foregroundStyle(Obs.ink).monospacedDigit()
                if let target { Text("/ \(Int(target).formatted()) \(unit)").font(Obs.sans(11)).foregroundStyle(Obs.muted) }
            }
            if let value, let target, target > 0 {
                BandBar(value: min(100, value / target * 100), color: Obs.activityTint, height: 5, ticks: false)
            }
        }
    }

    private var bodyGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Body", icon: "waveform.path.ecg")
            LazyVGrid(columns: tileColumns, spacing: 12) {
                ForEach([MetricID.hrv, .restingHR, .temp, .spo2], id: \.rawValue) {
                    MetricTileButton(s: s, id: $0, day: day, open: open)
                }
            }
        }
    }
}


/// Header and day strip stay put; only the day's panels page and scroll.
struct TodayTab: View {
    let s: Summary
    let day: String
    @ObservedObject var live: LiveHeartRate
    @ObservedObject var ring: RingSync
    @Binding var kind: ScoreKind
    var onSelectDay: (String) -> Void
    var open: (Route) -> Void
    let header: AnyView
    let notes: AnyView
    @State private var sync = ScrollSync()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                header
                DayStrip(s: s, kind: kind, selected: day, onSelect: onSelectDay)
            }
            .padding(.horizontal, 20).padding(.top, 12)
            DayPages(days: s.days, selection: day, onSelect: onSelectDay) { d in
                TodayPage(s: s, day: d, sync: sync, isActive: d == day, live: live, ring: ring, kind: $kind, open: open, notes: notes)
            }
        }
    }
}

struct VitalsTab: View {
    let s: Summary
    let day: String
    @Binding var kind: ScoreKind
    var onSelectDay: (String) -> Void
    var open: (Route) -> Void
    let header: AnyView
    @State private var sync = ScrollSync()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                header
                DayStrip(s: s, kind: kind, selected: day, onSelect: onSelectDay)
            }
            .padding(.horizontal, 20).padding(.top, 12)
            DayPages(days: s.days, selection: day, onSelect: onSelectDay) { d in
                VitalsPage(s: s, day: d, sync: sync, isActive: d == day, open: open)
            }
        }
    }
}

// ── Vitals ───────────────────────────────────────────────────────────────────

struct VitalsPage: View {
    @Environment(\.radarAnalyzing) private var radarAnalyzing
    @Environment(\.openRingCapture) private var openRingCapture
    let s: Summary
    let day: String
    let sync: ScrollSync
    let isActive: Bool
    var open: (Route) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                group("Sleep", .sleep) {
                    ScoreTileButton(s: s, kind: .sleep, day: day, open: open)
                    debtTile
                    MetricTileButton(s: s, id: .asleep, day: day, open: open)
                    MetricTileButton(s: s, id: .efficiency, day: day, open: open)
                    MetricTileButton(s: s, id: .breath, day: day, open: open)
                    MetricTileButton(s: s, id: .spo2, day: day, open: open)
                }
                group("Readiness", .readiness) {
                    ScoreTileButton(s: s, kind: .readiness, day: day, open: open)
                    radarTile
                    MetricTileButton(s: s, id: .restingHR, day: day, open: open)
                    MetricTileButton(s: s, id: .hrv, day: day, open: open)
                    MetricTileButton(s: s, id: .temp, day: day, open: open)
                    MetricTileButton(s: s, id: .regularity, day: day, open: open)
                }
                group("Activity", .activity) {
                    ScoreTileButton(s: s, kind: .activity, day: day, open: open)
                    MetricTileButton(s: s, id: .steps, day: day, open: open)
                    MetricTileButton(s: s, id: .activeKcal, day: day, open: open)
                    MetricTileButton(s: s, id: .totalKcal, day: day, open: open)
                }
                cardio
                Text("Arrows compare the latest value with the average of the 14 days before it.")
                    .font(Obs.sans(11)).foregroundStyle(Obs.muted)
            }
            .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 96)
        }
        .scrollIndicators(.hidden)
        .syncedScroll(sync, active: isActive)
    }

    private func group<Content: View>(_ title: String, _ kind: ScoreKind, @ViewBuilder _ tiles: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: title, icon: kind.icon, tint: kind.tint)
            LazyVGrid(columns: tileColumns, spacing: 12) { tiles() }
        }
    }

    @ViewBuilder private var radarTile: some View {
        if let r = s.symptomRadar, r.available {
            let (word, color): (String, Color) = switch r.trafficLight {
            case "NO_SIGNS": ("No signs", Obs.good)
            case "MINOR_SIGNS": ("Minor signs", Obs.bad)
            case "MAJOR_SIGNS": ("Major signs", Obs.alert)
            default: ("No result", Obs.muted)
            }
            Button { open(.radar) } label: {
                MetricTile(title: "Symptom radar", value: word, icon: "cross.case.fill", tint: Obs.readyTint,
                           valueColor: color, status: radarAnalyzing ? "updating…" : "\(r.daysWithData) days of data")
            }
            .buttonStyle(.plain)
        } else if radarAnalyzing {
            MetricTile(title: "Symptom radar", value: "–", icon: "cross.case.fill", tint: Obs.readyTint,
                       status: "analyzing…")
        }
    }

    @ViewBuilder private var debtTile: some View {
        if let debt = s.sleepDebt?.asOf(day) {
            let series = (s.sleepDebt?.days ?? []).filter { $0.date <= day }.suffix(14).compactMap(\.cumulative_debt_min)
            Button { open(.debt) } label: {
                MetricTile(title: "Sleep debt", value: debt.valid ? fmtMinutes(debt.debt_min) : "–",
                           icon: "moon.zzz.fill", tint: Obs.sleepTint,
                           valueColor: debt.valid ? Obs.debt(debt.state) : Obs.ink,
                           status: debt.valid ? debt.state : "\(debt.valid_days) of 5 nights",
                           statusColor: debt.valid ? Obs.debt(debt.state) : Obs.muted,
                           series: series)
            }
            .buttonStyle(.plain)
        }
    }

    @ObservedObject private var vo2Store = Vo2Store.shared
    private static func ymd(_ unix: Double) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        return f.string(from: Date(timeIntervalSince1970: unix))
    }

    @ViewBuilder private var cardio: some View {
        let va = s.cardio?.vascular_age, vo2 = s.fitness?.vo2max
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Cardio", icon: "heart.fill")
            LazyVGrid(columns: tileColumns, spacing: 12) {
                if let va {
                    let diff = s.cardio?.chronological_age.map { va - $0 }
                    MetricTile(title: "Vascular age", value: String(format: "%.1f", va), unit: "yr",
                               icon: "heart.text.square.fill",
                               status: diff.map { abs($0) < 0.05 ? "In line" : String(format: "%.1f yr %@", abs($0), $0 < 0 ? "younger" : "older") },
                               statusColor: diff.map { $0 < -0.05 ? Obs.good : ($0 > 0.05 ? Obs.bad : Obs.muted) } ?? Obs.muted,
                               chevron: false)
                } else {
                    Button { openRingCapture() } label: {
                        MetricTile(title: "Vascular age", value: "–", unit: "yr", icon: "heart.text.square.fill",
                                   chevron: false, missing: .ppgSampler)
                    }
                    .buttonStyle(.plain)
                }
                if let latest = vo2Store.file.readings.last {
                    Button { open(.vo2) } label: {
                        MetricTile(title: "VO₂ max", value: String(format: "%.0f", latest.vo2), unit: "ml/kg/min",
                                   icon: "lungs.fill", status: "6-minute walk, \(DayFmt.short(Self.ymd(latest.atUnix)))")
                    }
                    .buttonStyle(.plain)
                } else if let vo2 {
                    Button { open(.vo2) } label: {
                        MetricTile(title: "VO₂ max", value: String(format: "%.1f", vo2), unit: "ml/kg/min",
                                   icon: "lungs.fill", status: "From age, sex and weight")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// ── Trends ───────────────────────────────────────────────────────────────────

struct TrendsTab: View {
    let s: Summary
    let day: String
    var open: (Route) -> Void
    let header: AnyView
    @State private var period = 30
    @State private var sync = ScrollSync()

    var body: some View {
        let latest = day
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                PeriodPicker(days: $period)
                ForEach(ScoreKind.allCases) { kind in
                    ScoreTrendCard(s: s, kind: kind, day: latest, period: period, open: open)
                }
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(title: "Body, \(period)-day average", icon: "waveform.path.ecg")
                    LazyVGrid(columns: tileColumns, spacing: 12) {
                        ForEach([MetricID.hrv, .restingHR, .temp, .spo2, .breath, .asleep], id: \.rawValue) {
                            PeriodTile(s: s, id: $0, day: latest, period: period, open: open)
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 96)
        }
        .scrollIndicators(.hidden)
        .syncedScroll(sync, active: true)
    }
}

/// A score over the period: average, change against the period before, daily bars, and
/// the contributor heatmap beneath.
struct ScoreTrendCard: View {
    let s: Summary
    let kind: ScoreKind
    let day: String
    let period: Int
    var open: (Route) -> Void
    @State private var selection: Int?

    var body: some View {
        let all = s.scoreSeries(kind, upTo: day)
        let days = s.calendarDays(upTo: day, count: period)
        let window = all.filter { days.contains($0.date) }
        let means = Stats.periodMeans(all, end: day, days: period)
        let focusDay = all.last?.date ?? day
        let shown = selection.flatMap { window.indices.contains($0) ? window[$0] : nil }
        VStack(alignment: .leading, spacing: 14) {
            Button { open(.score(kind)) } label: {
                SectionLabel(title: kind.title, icon: kind.icon, tint: kind.tint, chevron: true)
            }
            .buttonStyle(.plain)
            if window.isEmpty {
                Text("No \(kind.title.lowercased()) scores in this period").font(Obs.sans(12)).foregroundStyle(Obs.muted)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let shown {
                        Figure(value: String(format: "%.0f", shown.value), size: 34, color: ScoreBand(shown.value).color)
                        Text(DayFmt.relative(shown.date)).font(Obs.sans(11)).foregroundStyle(Obs.ink2)
                    } else {
                        Figure(value: means.now.map { String(format: "%.0f", $0) } ?? "–", size: 34)
                        Text("average").font(Obs.sans(11)).foregroundStyle(Obs.muted)
                        if let n = means.now, let b = means.before {
                            DeltaBadge(delta: n - b, higherIsBetter: true, reference: b, threshold: 0.03)
                        }
                    }
                    Spacer()
                    Text("\(window.count) / \(days.count) days").font(Obs.sans(11)).foregroundStyle(Obs.muted)
                }
                TrendChart(points: window, style: .line, tint: kind.tint, domain: 0...100,
                           reference: means.now, bandColors: true, height: 110, axis: days, selection: $selection)
                let rows = kind.contributors(s, focusDay)
                if !rows.isEmpty {
                    Heatmap(rows: rows.map { c in
                        Heatmap.Row(id: c.key, label: c.label,
                                    values: Dictionary(uniqueKeysWithValues: s.contributorSeries(kind, key: c.key, upTo: day)
                                        .map { ($0.date, $0.value) }))
                    }, days: days, onTap: { _ in open(.score(kind)) })
                }
            }
        }
        .surface()
    }
}

/// Period average of one metric with its change against the period before.
struct PeriodTile: View {
    let s: Summary
    let id: MetricID
    let day: String
    let period: Int
    var open: (Route) -> Void
    var body: some View {
        let m = s.metric(id, upTo: day, count: 2 * period)
        let means = Stats.periodMeans(m.series, end: day, days: period)
        let values = m.series.filter { $0.date > (DayFmt.offset(day, -period) ?? "") }.map(\.value)
        Button { open(id == .restingHR ? .vital(.heartRate) : .metric(id)) } label: {
            MetricTile(title: m.title, value: means.now.map(m.text) ?? "–", unit: m.unit, icon: m.icon,
                       tint: m.score?.tint ?? Obs.muted,
                       delta: zip2(means.now, means.before).map {
                           DeltaBadge(delta: $0 - $1, decimals: m.decimals, higherIsBetter: m.higherIsBetter, reference: $1)
                       },
                       series: values, baseline: m.baseline)
        }
        .buttonStyle(.plain)
    }
    private func zip2(_ a: Double?, _ b: Double?) -> (Double, Double)? {
        guard let a, let b else { return nil }
        return (a, b)
    }
}

/// Sleep debt as a figure, its state, and the cumulative debt over the window.
struct DebtCard: View {
    let s: Summary
    let debt: SleepDebtSummary
    let day: String
    var action: () -> Void
    var body: some View {
        let series = (s.sleepDebt?.days ?? []).filter { $0.date <= day }.compactMap { d in
            d.cumulative_debt_min.map { DatedValue(date: d.date, value: $0 / 60) }
        }
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(title: "Sleep debt", icon: "moon.zzz.fill", tint: Obs.sleepTint,
                             trailing: "\(debt.window_days) days", chevron: true)
                if debt.valid {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Figure(value: fmtMinutes(debt.debt_min), size: 30, color: Obs.debt(debt.state))
                        Text(debt.state).font(Obs.sans(11, .medium))
                            .foregroundStyle(Obs.debt(debt.state))
                        Spacer()
                        Text("need \(String(format: "%.1f", debt.need_h)) h").font(Obs.sans(11)).foregroundStyle(Obs.muted)
                    }
                    if series.count > 1 {
                        Sparkline(series: series.map(\.value), accent: Obs.debt(debt.state))
                    }
                } else {
                    Figure(value: "\(debt.valid_days) of 5", unit: "nights", size: 24, color: Obs.ink2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .surface()
    }
}
