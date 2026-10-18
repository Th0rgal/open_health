import Foundation

// What the user says about their day, kept in `activities.json` beside the database (like
// profile.json): exercise sessions started in the app, the type the user gave a detected
// session, and the exercise that is running now. The ring database is never written.

/// The activity types the ring's workout parameters take (`ActivityType` ids in the official app,
/// open_oura `docs/workout-and-feature-modes.md`).
struct ExerciseType: Identifiable, Hashable {
    let id: UInt16
    let name: String
    static let all: [ExerciseType] = [
        .init(id: 14, name: "walking"), .init(id: 12, name: "running"), .init(id: 5, name: "cycling"),
        .init(id: 8, name: "strength training"), .init(id: 10, name: "pilates"), .init(id: 15, name: "yoga"),
        .init(id: 65535, name: "other"),
    ]
    static func named(_ name: String) -> ExerciseType { all.first { $0.name == name } ?? all[all.count - 1] }
}

/// Types a detected session can be tagged with. "not an activity" hides it.
enum ActivityTagChoice {
    static let notAnActivity = "not an activity"
    static let all: [String] = ExerciseType.all.map(\.name) + ["housework", "dance", "hiking", "swimming", "nap", notAnActivity]
}

struct LoggedActivity: Codable, Identifiable, Equatable {
    var id: String
    var startUnix: Double
    var endUnix: Double
    var type: String
    var hrAvg: Double?
    var hrMax: Double?
    var hrSamples: Int?
    /// Length of the recorded route, meters (walks, runs and rides started in the app).
    var distanceM: Double?
}

struct ActivityTag: Codable, Equatable {
    var key: String      // WorkoutSession.id
    var type: String
}

struct ActiveExercise: Codable, Equatable {
    var id: String
    var startUnix: Double
    var type: String
    var activityId: UInt16
    /// Exercise heart rate mode before the start (0 off, 1 automatic), restored at the end.
    var previousMode: UInt8
}

struct ActivityLogFile: Codable, Equatable {
    var activities: [LoggedActivity] = []
    var tags: [ActivityTag] = []
    var active: ActiveExercise?
}

@MainActor
final class ActivityLogStore: ObservableObject {
    static let shared = ActivityLogStore()
    @Published private(set) var log = ActivityLogFile()

    private var url: URL { DB.url.deletingLastPathComponent().appendingPathComponent("activities.json") }

    private init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ActivityLogFile.self, from: data) else { return }
        log = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(log) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func begin(_ active: ActiveExercise) { log.active = active; save() }
    func clearActive() { log.active = nil; save() }

    func add(_ activity: LoggedActivity) {
        log.activities.removeAll { $0.id == activity.id }
        log.activities.append(activity)
        log.activities.sort { $0.startUnix < $1.startUnix }
        save()
    }

    func update(_ id: String, hr: HeartRateWindow) {
        guard let i = log.activities.firstIndex(where: { $0.id == id }) else { return }
        log.activities[i].hrAvg = hr.avg; log.activities[i].hrMax = hr.max; log.activities[i].hrSamples = hr.count
        save()
    }

    func update(_ id: String, distanceM: Double) {
        guard let i = log.activities.firstIndex(where: { $0.id == id }) else { return }
        log.activities[i].distanceM = distanceM
        save()
    }

    func remove(_ id: String) { log.activities.removeAll { $0.id == id }; save() }

    func tag(_ key: String, as type: String?) {
        log.tags.removeAll { $0.key == key }
        if let type { log.tags.append(ActivityTag(key: key, type: type)) }
        save()
    }

    func tagged(_ key: String) -> String? { log.tags.first { $0.key == key }?.type }
}

struct HeartRateWindow { var avg: Double; var max: Double; var count: Int }

enum ExerciseMetrics {
    /// The heart-rate, MET and motion records saved on this phone between two instants (read from
    /// the database by open_oura's `window_series`; the ring is not contacted). Call off the main
    /// thread.
    static func series(startUnix: Double, endUnix: Double) -> ActivitySeries {
        let r = activitySeries(dbPath: DB.readPath(), startUnix: startUnix, endUnix: endUnix)
        func zip(_ t: [Double], _ v: [Double]) -> [(t: Double, v: Double)] { Array(Swift.zip(t, v)).map { (t: $0, v: $1) } }
        return ActivitySeries(hr: zip(r.hrT, r.hrV), met: zip(r.metT, r.metV), motion: zip(r.motionT, r.motionV))
    }

    /// Average and maximum of the saved heart-rate minutes in a window, or nil when there are none.
    static func heartRate(startUnix: Double, endUnix: Double) -> HeartRateWindow? {
        let hr = series(startUnix: startUnix, endUnix: endUnix).hr.map(\.v)
        guard !hr.isEmpty else { return nil }
        return HeartRateWindow(avg: hr.reduce(0, +) / Double(hr.count), max: hr.max()!, count: hr.count)
    }
}

struct ActivitySeries {
    /// Heart rate per minute (average of the saved beats), MET per minute, motion seconds per
    /// motion record; each as (unix seconds, value) inside the window.
    var hr: [(t: Double, v: Double)] = []
    var met: [(t: Double, v: Double)] = []
    var motion: [(t: Double, v: Double)] = []
    var isEmpty: Bool { hr.isEmpty && met.isEmpty && motion.isEmpty }
}

// MARK: - the day's timeline

enum TimelineKind { case sleep, nap, detected, exercise }

struct TimelineItem: Identifiable {
    let id: String
    let kind: TimelineKind
    let label: String
    /// Minutes from local midnight of the shown day, clipped to 0...1440.
    let startMin: Double
    let endMin: Double
    let startUnix: Double
    let endUnix: Double
    var confidence: Double? = nil
    var detectedKey: String? = nil     // WorkoutSession.id for a detected session
    var tagged: Bool = false
    var logged: LoggedActivity? = nil

    var durationMin: Int { Int(((endUnix - startUnix) / 60).rounded()) }
}

enum DayTimeline {
    static let timeFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.timeZone = .current; return f
    }()
    private static let dayFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current; return f
    }()

    /// Everything that happened on `day` ("yyyy-MM-dd"): sleeps, detected activities with the
    /// user's tags applied, and the user's own exercise sessions, in time order.
    static func items(on day: String, summary s: Summary, log: ActivityLogFile) -> [TimelineItem] {
        guard let dayStart = dayFormat.date(from: day) else { return [] }
        let lo = dayStart.timeIntervalSince1970
        let hi = lo + 86_400
        func clip(_ a: Double, _ b: Double) -> (Double, Double)? {
            let x = max(a, lo), y = min(b, hi)
            return y > x ? ((x - lo) / 60, (y - lo) / 60) : nil
        }
        var out: [TimelineItem] = []
        let mainStart = s.night(forDay: day)?.start_unix
        for n in s.nights {
            guard let a = n.start_unix.map(Double.init), let b = n.end_unix.map(Double.init),
                  let (x, y) = clip(a, b) else { continue }
            let isMain = n.start_unix == mainStart
            out.append(TimelineItem(id: "sleep-\(Int(a))", kind: isMain ? .sleep : .nap, label: isMain ? "sleep" : "nap",
                                    startMin: x, endMin: y, startUnix: a, endUnix: b))
        }
        for w in s.workouts where w.isWorkout >= 0.5 {
            guard let start = timeFormat.date(from: w.start) else { continue }
            let a = start.timeIntervalSince1970, b = a + Double(w.durationMin) * 60
            guard let (x, y) = clip(a, b) else { continue }
            let tag = log.tags.first { $0.key == w.id }?.type
            if tag == ActivityTagChoice.notAnActivity { continue }
            out.append(TimelineItem(id: "det-\(w.id)", kind: tag == "nap" ? .nap : .detected, label: tag ?? w.label,
                                    startMin: x, endMin: y, startUnix: a, endUnix: b,
                                    confidence: w.isWorkout, detectedKey: w.id, tagged: tag != nil))
        }
        for e in log.activities {
            guard let (x, y) = clip(e.startUnix, e.endUnix) else { continue }
            out.append(TimelineItem(id: "log-\(e.id)", kind: .exercise, label: e.type, startMin: x, endMin: y,
                                    startUnix: e.startUnix, endUnix: e.endUnix, logged: e))
        }
        return out.sorted { $0.startUnix < $1.startUnix }
    }
}
