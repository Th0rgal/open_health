import SwiftUI

// Score and metric data for the home screens. Everything here is derived from the
// shared summary JSON (`Summary`); no new fields are computed on the client.
// SIBLING CLIENT: the web dashboard renders the same JSON (docs/clients-web-and-ios.md).

/// The three daily scores. `scores[day]` holds each value; contributors come from the
/// night (sleep, readiness) or the activity day.
enum ScoreKind: String, CaseIterable, Identifiable {
    case sleep, readiness, activity
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// Column label where space is tight.
    var short: String {
        switch self { case .sleep: return "Sleep"; case .readiness: return "Ready"; case .activity: return "Act" }
    }
    var icon: String {
        switch self {
        case .readiness: return "leaf.fill"
        case .sleep: return "moon.fill"
        case .activity: return "flame.fill"
        }
    }
    var tint: Color {
        switch self {
        case .readiness: return Obs.readyTint
        case .sleep: return Obs.sleepTint
        case .activity: return Obs.activityTint
        }
    }
    func value(_ s: Summary, _ day: String) -> Double? {
        let d = s.scores[day]
        switch self {
        case .readiness: return d?.readiness
        case .sleep: return d?.sleep
        case .activity: return d?.activity
        }
    }
}

/// Oura's score bands: 85+ optimal, 70-84 good, 60-69 fair, below 60 needs attention.
enum ScoreBand: Int {
    case optimal, good, fair, attention
    init(_ v: Double) {
        switch v {
        case 85...: self = .optimal
        case 70..<85: self = .good
        case 60..<70: self = .fair
        default: self = .attention
        }
    }
    var title: String {
        switch self {
        case .optimal: return "Optimal"
        case .good: return "Good"
        case .fair: return "Fair"
        case .attention: return "Attention"
        }
    }
    var color: Color {
        switch self {
        case .optimal: return Obs.good
        case .good: return Obs.goodSoft
        case .fair: return Obs.caution
        case .attention: return Obs.bad
        }
    }
}

/// One sub-score of a daily score.
struct Contributor: Identifiable {
    let key: String
    let label: String
    let value: Double
    /// Share of the score (0-1) when the combiner has a fixed weight for it.
    let weight: Double?
    var id: String { key }
}

private struct ContributorSpec {
    let key: String, label: String, weight: Double?
}

private let readinessSpecs: [ContributorSpec] = [
    .init(key: "last_night", label: "Previous night", weight: 0.15),
    .init(key: "sleep_balance", label: "Sleep balance", weight: 0.15),
    .init(key: "last_day_activity", label: "Previous day activity", weight: 0.10),
    .init(key: "activity_balance", label: "Activity balance", weight: 0.10),
    .init(key: "resting_hr", label: "Resting heart rate", weight: 0.15),
    .init(key: "recovery_index", label: "Recovery index", weight: 0.10),
    .init(key: "hrv_balance", label: "HRV balance", weight: 0.15),
    .init(key: "sleep_regularity", label: "Sleep regularity", weight: 0.10),
    .init(key: "temperature", label: "Body temperature", weight: nil),
]
private let sleepSpecs: [ContributorSpec] = [
    .init(key: "total", label: "Total sleep", weight: 0.35),
    .init(key: "restfulness", label: "Restfulness", weight: 0.15),
    .init(key: "efficiency", label: "Efficiency", weight: 0.10),
    .init(key: "rem", label: "REM sleep", weight: 0.10),
    .init(key: "deep", label: "Deep sleep", weight: 0.10),
    .init(key: "latency", label: "Latency", weight: 0.10),
    .init(key: "timing", label: "Timing", weight: 0.10),
]
private let activitySpecs: [ContributorSpec] = [
    .init(key: "targets", label: "Meet daily targets", weight: 0.25),
    .init(key: "stay_active", label: "Stay active", weight: 0.15),
    .init(key: "move_hourly", label: "Move every hour", weight: 0.10),
    .init(key: "frequency", label: "Training frequency", weight: 0.10),
    .init(key: "volume", label: "Training volume", weight: 0.15),
    .init(key: "recovery", label: "Recovery time", weight: 0.25),
]

struct DatedValue: Identifiable, Equatable {
    let date: String
    let value: Double
    var id: String { date }
}

extension ScoreKind {
    fileprivate var specs: [ContributorSpec] {
        switch self {
        case .readiness: return readinessSpecs
        case .sleep: return sleepSpecs
        case .activity: return activitySpecs
        }
    }
    /// Contributors keyed by spec key for one day, from whichever source the kind uses.
    fileprivate func raw(_ s: Summary, _ day: String) -> [String: Double] {
        switch self {
        case .readiness: return s.night(forDay: day)?.oura_readiness?.contributors ?? [:]
        case .sleep: return s.night(forDay: day)?.oura_sleep_score?.contributors ?? [:]
        case .activity:
            // seven values: targets, stay active, move hourly, frequency, volume, then the
            // two recovery paths (weights 10 and 15), shown as one row
            guard let c = s.activity_daily[day]?.contributors, c.count == 7 else { return [:] }
            return ["targets": c[0], "stay_active": c[1], "move_hourly": c[2], "frequency": c[3],
                    "volume": c[4], "recovery": (10 * c[5] + 15 * c[6]) / 25]
        }
    }
    func contributors(_ s: Summary, _ day: String) -> [Contributor] {
        let raw = raw(s, day)
        return specs.compactMap { spec in
            raw[spec.key].map { Contributor(key: spec.key, label: spec.label, value: $0, weight: spec.weight) }
        }
    }
}

/// A named measurement with a daily history, the unit the tiles, trend charts and
/// detail pages all share.
struct Metric: Identifiable {
    let id: String
    var title: String
    var unit: String
    var decimals: Int = 0
    var series: [DatedValue]
    /// Personal baseline drawn as a reference line, in the metric's own unit.
    var baseline: Double? = nil
    /// nil when neither direction is better (shown without good/bad color).
    var higherIsBetter: Bool? = nil
    var score: ScoreKind? = nil
    var icon: String = "waveform.path.ecg"

    var latest: DatedValue? { series.last }
    func text(_ v: Double) -> String { String(format: "%.\(decimals)f", v) }
    func value(on day: String) -> Double? { series.last(where: { $0.date <= day })?.value }
}

enum MetricID: String, Identifiable {
    var id: String { rawValue }
    case hrv, restingHR, temp, spo2, breath, asleep, efficiency, regularity, steps, activeKcal, totalKcal
}

extension NightRow {
    /// Hours asleep from the staged hypnogram (30 s epochs, any non-wake stage).
    var asleepH: Double? {
        guard let h = hypnogram, h.count > 1, stagingComplete else { return nil }
        return Double(h.filter { (1...3).contains($0) }.count) / 120
    }
}

extension Summary {
    /// Daily values for `days` newest-first up to `day`, oldest first.
    func daily(upTo day: String, count: Int = 90, _ pick: (String) -> Double?) -> [DatedValue] {
        days.filter { $0 <= day }.prefix(count).reversed().compactMap { d in
            pick(d).flatMap { $0.isFinite ? DatedValue(date: d, value: $0) : nil }
        }
    }

    /// Consecutive calendar days ending at `day`, oldest first, not reaching before the
    /// earliest day with data. The shared x-axis of every chart over a period.
    func calendarDays(upTo day: String, count: Int) -> [String] {
        let earliest = days.last ?? day
        var out: [String] = []
        for k in 0..<count {
            guard let d = DayFmt.offset(day, -k), d >= earliest else { break }
            out.append(d)
        }
        return out.reversed()
    }

    func scoreSeries(_ kind: ScoreKind, upTo day: String, count: Int = 90) -> [DatedValue] {
        daily(upTo: day, count: count) { kind.value(self, $0) }
    }

    /// One contributor's history, the columns of a heatmap row.
    func contributorSeries(_ kind: ScoreKind, key: String, upTo day: String, count: Int = 90) -> [DatedValue] {
        daily(upTo: day, count: count) { kind.raw(self, $0)[key] }
    }

    func metric(_ id: MetricID, upTo day: String, count: Int = 90) -> Metric {
        func night(_ pick: @escaping (NightRow) -> Double?) -> [DatedValue] {
            nightlySeries(pick).filter { $0.date <= day }.suffix(count).map { DatedValue(date: $0.date, value: $0.value) }
        }
        switch id {
        case .hrv:
            return Metric(id: id.rawValue, title: "HRV", unit: "ms", series: night(\.hrv_ms),
                          baseline: vitals.hrv.baseline, higherIsBetter: true, icon: "waveform.path.ecg")
        case .restingHR:
            return Metric(id: id.rawValue, title: "Resting HR", unit: "bpm", series: night(\.rhr),
                          baseline: vitals.rhr.baseline, higherIsBetter: false, icon: "heart.fill")
        case .temp:
            return Metric(id: id.rawValue, title: "Skin temp", unit: "°C", decimals: 1, series: night(\.skin_temp),
                          icon: "thermometer.medium")
        case .spo2:
            return Metric(id: id.rawValue, title: "Blood O₂", unit: "%", series: night(\.spo2_mean),
                          higherIsBetter: true, icon: "lungs.fill")
        case .breath:
            return Metric(id: id.rawValue, title: "Breathing", unit: "br/min", decimals: 1,
                          series: night(\.breath_rate), icon: "wind")
        case .asleep:
            return Metric(id: id.rawValue, title: "Time asleep", unit: "h", decimals: 1,
                          series: night(\.asleepH), higherIsBetter: true, score: .sleep, icon: "bed.double.fill")
        case .efficiency:
            return Metric(id: id.rawValue, title: "Efficiency", unit: "%", series: night(\.efficiency),
                          higherIsBetter: true, score: .sleep, icon: "gauge.with.dots.needle.67percent")
        case .regularity:
            return Metric(id: id.rawValue, title: "Regularity", unit: "",
                          series: contributorSeries(.readiness, key: "sleep_regularity", upTo: day, count: count),
                          higherIsBetter: true, score: .readiness, icon: "calendar")
        case .steps:
            return Metric(id: id.rawValue, title: "Steps", unit: "",
                          series: daily(upTo: day, count: count) { activity_daily[$0]?.steps },
                          higherIsBetter: true, score: .activity, icon: "figure.walk")
        case .activeKcal:
            return Metric(id: id.rawValue, title: "Active kcal", unit: "",
                          series: daily(upTo: day, count: count) { activity_daily[$0]?.active_kcal },
                          higherIsBetter: true, score: .activity, icon: "flame.fill")
        case .totalKcal:
            return Metric(id: id.rawValue, title: "Total kcal", unit: "",
                          series: daily(upTo: day, count: count) { activity_daily[$0]?.total_kcal },
                          icon: "bolt.fill")
        }
    }
}

// ── series statistics ────────────────────────────────────────────────────────

enum Stats {
    static func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }

    /// Latest value against the mean of the values before it (up to `window`), as a
    /// signed difference in the metric's unit.
    static func delta(_ series: [DatedValue], window: Int = 14) -> Double? {
        guard let last = series.last, series.count > 2 else { return nil }
        let prior = series.dropLast().suffix(window).map(\.value)
        return mean(prior).map { last.value - $0 }
    }

    /// Mean over the `days` calendar days ending at `end`, and over the `days` before those.
    static func periodMeans(_ series: [DatedValue], end: String, days: Int) -> (now: Double?, before: Double?) {
        guard let start = DayFmt.offset(end, -days), let prior = DayFmt.offset(end, -2 * days) else { return (nil, nil) }
        let now = series.filter { $0.date > start && $0.date <= end }.map(\.value)
        let before = series.filter { $0.date > prior && $0.date <= start }.map(\.value)
        return (mean(now), mean(before))
    }
}

enum DayFmt {
    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    private static let parse: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static func make(_ format: String) -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US")
        f.timeZone = TimeZone(identifier: "UTC"); f.setLocalizedDateFormatFromTemplate(format); return f
    }
    private static let weekday = make("EEE"), letter = make("EEEEE"), short = make("MMMd"), dayNum = make("d")
    static func date(_ ymd: String) -> Date? { parse.date(from: ymd) }
    /// The date `n` days after `ymd` (negative for before).
    static func offset(_ ymd: String, _ n: Int) -> String? {
        date(ymd).flatMap { utc.date(byAdding: .day, value: n, to: $0) }.map(parse.string)
    }
    static func weekday(_ ymd: String) -> String { date(ymd).map(weekday.string) ?? "" }
    static func letter(_ ymd: String) -> String { date(ymd).map(letter.string) ?? "" }
    static func short(_ ymd: String) -> String { date(ymd).map(short.string) ?? ymd }
    static func dayNumber(_ ymd: String) -> String { date(ymd).map(dayNum.string) ?? "" }
    /// "Today", "Yesterday", or "Sat Oct 4".
    static func relative(_ ymd: String, now: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let today = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        if ymd == today { return "Today" }
        if let d = date(today), let y = utc.date(byAdding: .day, value: -1, to: d), parse.string(from: y) == ymd {
            return "Yesterday"
        }
        return "\(weekday(ymd)) \(short(ymd))"
    }
}
