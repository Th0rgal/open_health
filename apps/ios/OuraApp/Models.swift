import Foundation

// ── the shared build_summary() JSON, decoded (same contract as the web client) ──
// SIBLING CLIENT: the web dashboard (dashboard/web/app.js) renders the SAME summary
// JSON. A user-facing change here usually belongs there too — see the feature map in
// docs/clients-web-and-ios.md. New computed fields go in crates/oura-summary; new
// models get an on-device path (TorchBridge.mm + *Model.swift) AND a Python runner.

struct Trend: Codable {
    var series: [Double] = []
    var latest: Double? = nil
    var baseline: Double? = nil
    var delta_pct: Double? = nil
}
struct LatestVital: Codable {
    var latest: Double?
    var date: String?
    var hm: String?
    var at_unix: Int64?
}
struct Vitals: Codable { var hrv = Trend(); var rhr = Trend(); var hr: LatestVital? }
// per-night raw signal series (from build_summary event accumulation — present in BOTH
// the model-free and on-device builds; each covers the whole night so index→time is a
// shared axis across lanes). Feeds the polysomnograph lanes.
struct NightSeries: Codable {
    var hr: [Double] = []
    var hrv: [Double] = []
    var spo2: [Double] = []
    var temp: [Double] = []
    var temp_span: [Double]? = nil
    var motion: [Double] = []
}
struct NightRow: Codable, Identifiable {
    var date: String?; var ymd: String?; var start_ds: Int64?; var end_ds: Int64?
    var raw_start_ds: Int64?; var raw_end_ds: Int64?; var bedtime_adjusted: Bool?
    var start: String?; var end: String?
    var in_bed_h: Double?; var hrv_ms: Double?; var rhr: Double?
    var skin_temp: Double?; var spo2_mean: Double?
    // model-derived (present once the hypnogram runner is wired): per-30s stage codes
    // 1=deep 2=light 3=rem 4=wake, the stage percentages, and efficiency.
    var deep_pct: Double?; var light_pct: Double?; var rem_pct: Double?
    var wake_pct: Double?; var efficiency: Double?
    var stages: [Int]? = nil
    var series: NightSeries? = nil
    var id: String { (date ?? "") + (start ?? "") }
    var hasHypnogram: Bool { (stages?.count ?? 0) > 1 }
}
struct DailyStat: Codable { var active_kcal: Double?; var total_kcal: Double?; var steps: Double?; var distance_m: Double? }
struct Profile: Codable { var sex: String?; var age: Double?; var height_m: Double?; var weight_kg: Double?; var ring_size: Double? }
// a detected activity session (on-device automatic_activity_detection)
struct WorkoutSession: Identifiable {
    let start: String; let end: String; let durationMin: Int; let label: String; let isWorkout: Double
    var id: String { start + label }
    var dayLabel: String { String(start.prefix(10)) }      // YYYY-MM-DD
    var startHM: String { String(start.suffix(5)) }        // HH:MM
}
struct Cardio: Codable { var vascular_age: Double?; var chronological_age: Double?; var pwv_ms: Double?; var segments: Int? }
struct Fitness: Codable { var vo2max: Double? }
struct SleepDebtDay: Codable, Identifiable {
    var date: String
    var total_sleep_min: Double?
    var sleep_need_min: Double
    var shortfall_min: Double?
    var cumulative_debt_min: Double?
    var valid_days: Int
    var id: String { date }
}
struct SleepDebtSummary: Codable {
    var debt_min: Double = 0
    var recent_shortfall_min: Double = 0
    var valid: Bool = false
    var need_h: Double = 8
    var valid_days: Int = 0
    var window_days: Int = 14
    var state: String = "none"
    var days: [SleepDebtDay] = []
}
struct Device: Codable {
    var serial: String?; var firmware: String?
    var battery_pct: Int?
    var days_of_data: Double?; var nights: Int?
    var synced: String?; var synced_hm: String?
}
struct Summary: Codable {
    var digest: String?
    var device: Device?
    var nights: [NightRow] = []
    var vitals = Vitals()
    var activity_profile: [String: [Double]] = [:]   // date → 96 × 15-min mean MET-above-rest
    var activity_daily: [String: DailyStat] = [:]     // date → steps / active-kcal / total-kcal
    var profile: Profile?
    var cardio: Cardio?
    var fitness: Fitness?
    var sleepDebt: SleepDebtSummary?
    var workouts: [WorkoutSession] = []   // on-device only (not in the JSON)
    var modelErrors: [String] = []        // on-device model failures (not in the JSON)
    var error: String?
    // `workouts`/`modelErrors` are filled on-device (not in the FFI JSON), so keep them
    // out of decoding.
    enum CodingKeys: String, CodingKey {
        case digest, device, nights, vitals, activity_profile, activity_daily, profile, cardio, fitness, error
        case sleepDebt = "sleep_debt"
    }
    /// recent days (newest first) that have a movement profile.
    var activeDays: [String] { activity_profile.keys.sorted(by: >) }
}

extension Summary {
    // The calendar date you WOKE from a night. Nights are labelled by onset date (the
    // evening you went to bed), so an overnight sleep crossing midnight belongs to the
    // next day's morning. Pairing a day with the sleep you woke from — not the sleep you
    // started that evening — is what makes "night + activity of the day" one coherent
    // day. Kept identical to the web dashboard's wakeYmd().
    func wakeYmd(_ n: NightRow) -> String? {
        guard let ymd = n.ymd else { return nil }
        guard let s = n.start, let e = n.end, e < s else { return ymd }
        let p = ymd.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return ymd }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var comps = DateComponents(); comps.year = p[0]; comps.month = p[1]; comps.day = p[2]
        guard let base = cal.date(from: comps),
              let next = cal.date(byAdding: .day, value: 1, to: base) else { return ymd }
        let o = cal.dateComponents([.year, .month, .day], from: next)
        return String(format: "%04d-%02d-%02d", o.year ?? 0, o.month ?? 0, o.day ?? 0)
    }

    // every date with a night (by wake date) or activity — newest first; the unit both
    // the home hero and AllDaysView iterate.
    var days: [String] {
        var set = Set(activity_profile.keys)
        for n in nights { if let w = wakeYmd(n) { set.insert(w) } }
        return set.sorted(by: >)
    }

    // the primary sleep you woke from on the morning of `day` — the longest in-bed night
    // wins over same-morning naps. Falls back to a MM-DD match for older data lacking ymd.
    func night(forDay day: String) -> NightRow? {
        let cands = nights.filter { wakeYmd($0) == day }
        if let best = cands.max(by: { ($0.in_bed_h ?? 0) < ($1.in_bed_h ?? 0) }) { return best }
        return nights.first { $0.ymd == nil && ($0.date ?? "").hasSuffix(String(day.suffix(5))) }
    }
    func workoutsOn(_ day: String) -> [WorkoutSession] {
        workouts.filter { $0.isWorkout >= 0.5 && $0.dayLabel == day }
    }
}

// selects which day + which tab the full-page report opens on.
struct ReportSel: Identifiable { let day: String; let sleep: Bool; var id: String { day + (sleep ? "-s" : "-a") } }

// A calendar-day activity profile is convenient for storage, but people experience
// activity between waking and going back to bed. This view model joins the tail of
// the selected day to the next day's post-midnight buckets when necessary.
struct TimedActivityPoint: Identifiable {
    let hour: Double       // hours since the selected day's midnight; may exceed 24
    let met: Double
    var id: Double { hour }
}

struct WakingActivityTimeline {
    let startHour: Double
    let endHour: Double
    let points: [TimedActivityPoint]
    let startCaption: String
    let endCaption: String
}

extension Summary {
    func wakingActivityTimeline(for day: String, now: Date = Date()) -> WakingActivityTimeline {
        let recentMainSleeps = Array(nights.filter { ($0.in_bed_h ?? 0) >= 3 }.prefix(14))
        let wake = night(forDay: day)?.end.flatMap(clockHour)
            ?? median(recentMainSleeps.compactMap { $0.end.flatMap(clockHour) })
            ?? 6

        // Prefer the sleep that actually started after this waking day. On a current
        // day it does not exist yet, so use the recent median main-sleep onset.
        let sameDaySleeps = nights.filter { $0.ymd == day && ($0.in_bed_h ?? 0) >= 3 }
        let observedBed = sameDaySleeps.max { ($0.in_bed_h ?? 0) < ($1.in_bed_h ?? 0) }?
            .start.flatMap(clockHour).map { hourAfterWake($0, wake: wake) }
        let estimatedBed = median(recentMainSleeps.compactMap { n -> Double? in
            guard let start = n.start.flatMap(clockHour) else { return nil }
            return start < 12 ? start + 24 : start
        }) ?? 23

        let today = localDay(now)
        let nowHour: Double? = day == today ? {
            let c = Calendar.current.dateComponents([.hour, .minute], from: now)
            return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
        }() : nil
        let bed = observedBed ?? hourAfterWake(estimatedBed, wake: wake)
        let end = min(30, max(wake + 4, bed, nowHour ?? 0))
        let endIsNow = nowHour.map { $0 > bed } ?? false

        let profiles: [(offset: Double, values: [Double])] = [
            (0, activity_profile[day] ?? []),
            (24, nextDay(after: day).flatMap { activity_profile[$0] } ?? []),
        ]
        var points: [TimedActivityPoint] = []
        for profile in profiles where profile.values.count > 1 {
            let bucket = 24 / Double(profile.values.count)
            for (index, value) in profile.values.enumerated() {
                let hour = profile.offset + (Double(index) + 0.5) * bucket
                if hour >= wake - bucket && hour <= end + bucket {
                    points.append(TimedActivityPoint(hour: hour, met: value))
                }
            }
        }

        return WakingActivityTimeline(
            startHour: wake,
            endHour: end,
            points: points,
            startCaption: "wake \(clockLabel(wake))",
            endCaption: endIsNow
                ? "now \(clockLabel(end))"
                : "\(observedBed == nil ? "estimated bed" : "bed") \(clockLabel(end))"
        )
    }
}

private func clockHour(_ value: String) -> Double? {
    let parts = value.split(separator: ":").compactMap { Double($0) }
    guard parts.count >= 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
    return parts[0] + parts[1] / 60
}

private func hourAfterWake(_ hour: Double, wake: Double) -> Double {
    var result = hour
    while result <= wake { result += 24 }
    return result
}

private func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2)
        ? (sorted[middle - 1] + sorted[middle]) / 2
        : sorted[middle]
}

private func localDay(_ date: Date) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}

private func nextDay(after day: String) -> String? {
    let parts = day.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    var c = DateComponents(); c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
    guard let date = calendar.date(from: c), let next = calendar.date(byAdding: .day, value: 1, to: date) else { return nil }
    let n = calendar.dateComponents([.year, .month, .day], from: next)
    return String(format: "%04d-%02d-%02d", n.year ?? 0, n.month ?? 0, n.day ?? 0)
}

private func clockLabel(_ hour: Double) -> String {
    let totalMinutes = Int((hour * 60).rounded())
    return String(format: "%02d:%02d", (totalMinutes / 60) % 24, totalMinutes % 60)
}
