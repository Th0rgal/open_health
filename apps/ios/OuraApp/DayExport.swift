import Foundation
import UIKit

// One day of the report as JSON — what the Sleep / Activity tabs of DayReportView show,
// in the same snake_case keys as the shared brain's summary so a file can be diffed
// against `oura dashboard`'s /api/summary. The web dashboard offers the same export
// (app.js `exportDayJson`). Only the selected tab's section is included, plus a header.
struct DayExport: Encodable {
    struct SleepSection: Encodable {
        var night: NightRow
        var metrics: Metrics?
        var autonomic: Autonomic?
        var sleep_debt: SleepDebtDay?
    }
    struct Metrics: Encodable {
        var asleep_min: Double; var sol_min: Double; var rem_latency_min: Double?
        var waso_min: Double; var awakenings: Int; var cycles: Int; var frag_index: Double
        var deep_first_half_pct: Double?; var rem_first_half_pct: Double?
        init(_ m: SleepMetrics) {
            asleep_min = m.asleepMin; sol_min = m.solMin; rem_latency_min = m.remLatencyMin
            waso_min = m.wasoMin; awakenings = m.awakenings; cycles = m.cycles; frag_index = m.fragIndex
            deep_first_half_pct = m.deepFirstHalfPct; rem_first_half_pct = m.remFirstHalfPct
        }
    }
    struct Autonomic: Encodable {
        var hrv_deep: Double?; var hrv_light: Double?; var hrv_rem: Double?
        var hr_deep: Double?; var hr_light: Double?; var hr_rem: Double?
        init(_ a: StageAutonomic) {
            hrv_deep = a.hrvDeep; hrv_light = a.hrvLight; hrv_rem = a.hrvRem
            hr_deep = a.hrDeep; hr_light = a.hrLight; hr_rem = a.hrRem
        }
    }
    struct ActivitySection: Encodable {
        var daily: DailyStat?
        var profile_met: [Double]        // 96 × 15-min mean MET above rest
        var timeline: Timeline
        var workouts: [WorkoutSession]
        var model_errors: [String]
    }
    struct Timeline: Encodable {
        struct Point: Encodable { var hour: Double; var met: Double }
        var start_hour: Double; var end_hour: Double
        var start_caption: String; var end_caption: String
        var points: [Point]
        init(_ t: WakingActivityTimeline) {
            start_hour = t.startHour; end_hour = t.endHour
            start_caption = t.startCaption; end_caption = t.endCaption
            points = t.points.map { Point(hour: $0.hour, met: $0.met) }
        }
    }

    var day: String
    var kind: String
    var generated_at: String
    var timezone: String
    var app_version: String
    var profile: Profile?
    var sleep: SleepSection?
    var activity: ActivitySection?

    init(summary s: Summary, day: String, kind: DayAnalysisKind) {
        self.day = day
        self.kind = kind.rawValue.lowercased()
        generated_at = ISO8601DateFormatter().string(from: Date())
        timezone = TimeZone.current.identifier
        let info = Bundle.main.infoDictionary
        app_version = "\(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))"
        profile = s.profile
        switch kind {
        case .sleep:
            guard let n = s.night(forDay: day) else { return }
            let metrics = n.hypnogram.flatMap { st in
                Sleep.metrics(Sleep.smooth(st, 5), inBedS: n.durationS)
            }
            var autonomic: Autonomic?
            if let st = n.hypnogram {
                let a = Sleep.autonomic(night: n, stages: Sleep.smooth(st, 5))
                if a.any { autonomic = Autonomic(a) }
            }
            sleep = SleepSection(night: n, metrics: metrics.map(Metrics.init),
                          autonomic: autonomic,
                          sleep_debt: s.sleepDebt?.days.first { $0.date == day })
        case .activity:
            activity = ActivitySection(daily: s.activity_daily[day],
                                profile_met: s.activity_profile[day] ?? [],
                                timeline: Timeline(s.wakingActivityTimeline(for: day)),
                                workouts: s.workoutsOn(day),
                                model_errors: s.modelErrors.filter { $0.contains(day) })
        }
    }

    var isEmpty: Bool { sleep == nil && activity == nil }

    func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    var fileName: String { "oura-\(day)-\(kind).json" }

    /// Writes the JSON next to the diagnostics export so the share sheet can hand it out.
    func writeTemporaryFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try json().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func copyToPasteboard(_ text: String) { UIPasteboard.general.string = text }
}
