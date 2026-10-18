import Foundation
import CoreLocation
import CoreMotion

// VO2 max from 6-minute walks (open_oura `vo2max_ukk_6min`). Distance comes from GPS for walks the
// user starts in the app, and from the phone's step counter for walks the ring detected. Routes and
// readings stay in files beside the database; nothing leaves the phone.

// MARK: - routes (GPS, only while an exercise started in the app is running)

@MainActor
final class RouteRecorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = RouteRecorder()

    @Published private(set) var recording = false
    /// Location permission was refused, so the exercise has no route.
    @Published private(set) var denied = false

    private let manager = CLLocationManager()
    private var id: String?
    private var points: [RoutePoint] = []
    private var unsaved = 0

    /// Exercise types whose distance is recorded with GPS.
    static let tracked: Set<String> = ["walking", "running"]

    private static var directory: URL { DB.url.deletingLastPathComponent().appendingPathComponent("routes") }
    private static func file(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }

    /// Starts (or resumes, after a relaunch) recording the route of exercise `id`. Asks for
    /// location access the first time. Fixes arrive every few meters, not on a timer, so a
    /// stationary phone costs nothing.
    func start(id: String) {
        guard self.id != id else { return }
        self.id = id
        points = Self.load(id)
        unsaved = 0
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: denied = true; return
        default: begin()
        }
    }

    private func begin() {
        denied = false
        manager.startUpdatingLocation()
        recording = true
    }

    /// Stops recording and returns the saved route.
    @discardableResult
    func stop() -> [RoutePoint] {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        recording = false
        let route = points
        if let id { save(id) }
        id = nil; points = []
        return route
    }

    static func load(_ id: String) -> [RoutePoint] {
        (try? JSONDecoder().decode([RoutePoint].self, from: Data(contentsOf: file(id)))) ?? []
    }

    private func save(_ id: String) {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(points) else { return }
        try? data.write(to: Self.file(id), options: .atomic)
        unsaved = 0
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.map {
            RoutePoint(t: $0.timestamp.timeIntervalSince1970, lat: $0.coordinate.latitude,
                       lon: $0.coordinate.longitude, acc: $0.horizontalAccuracy)
        }
        Task { @MainActor in
            guard let id = self.id else { return }
            self.points.append(contentsOf: fixes)
            self.unsaved += fixes.count
            if self.unsaved >= 10 { self.save(id) }   // a killed app keeps most of the route
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.id != nil else { return }
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: self.begin()
            case .denied, .restricted: self.denied = true
            default: break
            }
        }
    }
}

// MARK: - phone step counter distance (no GPS: detected walks, after the fact)

enum PhoneDistance {
    /// Whether the phone can report walking distance. The first query asks for Motion & Fitness
    /// access.
    static var available: Bool {
        CMPedometer.isDistanceAvailable() && CMPedometer.authorizationStatus() != .denied
            && CMPedometer.authorizationStatus() != .restricted
    }

    /// Walking and running distance in each of `minutes` consecutive minutes from `start`, meters.
    /// An entry is nil when the phone has no data for that minute. The phone keeps about seven
    /// days.
    static func perMinute(from start: Date, minutes: Int) async -> [Double?] {
        guard available, start > Date().addingTimeInterval(-6.5 * 86_400) else { return [] }
        let pedometer = CMPedometer()
        var out: [Double?] = []
        for m in 0..<minutes {
            let a = start.addingTimeInterval(Double(m) * 60), b = a.addingTimeInterval(60)
            let meters: Double? = await withCheckedContinuation { done in
                pedometer.queryPedometerData(from: a, to: b) { data, error in
                    done.resume(returning: error == nil ? data?.distance?.doubleValue : nil)
                }
            }
            out.append(meters)
        }
        return out
    }
}

// MARK: - readings

struct Vo2Reading: Codable, Identifiable, Equatable {
    var id: String            // the activity the window came from
    var atUnix: Double        // end of the 6-minute window
    var vo2: Double           // ml/kg/min
    var distanceM: Double
    var hrBpm: Double
    var source: String        // "gps" or "phone"
    var activity: String
}

struct Vo2File: Codable, Equatable {
    var readings: [Vo2Reading] = []
    /// Detected walks that were looked at and decided (too slow, too short, or used), so the
    /// phone is not queried again for them.
    var checked: [String] = []
}

@MainActor
final class Vo2Store: ObservableObject {
    static let shared = Vo2Store()
    @Published private(set) var file = Vo2File()

    private var url: URL { DB.url.deletingLastPathComponent().appendingPathComponent("vo2.json") }
    private init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(Vo2File.self, from: data) else { return }
        file = f
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func add(_ r: Vo2Reading) {
        file.readings.removeAll { $0.id == r.id }
        file.readings.append(r)
        file.readings.sort { $0.atUnix < $1.atUnix }
        if !file.checked.contains(r.id) { file.checked.append(r.id) }
        save()
    }

    func markChecked(_ id: String) {
        guard !file.checked.contains(id) else { return }
        file.checked.append(id)
        save()
    }

    func isChecked(_ id: String) -> Bool { file.checked.contains(id) }
}

// MARK: - the estimate

enum Vo2Walk {
    /// A window shorter than this is not a brisk walk (4.8 km/h). The formula comes from a
    /// 6-minute walk at a quick pace, so slower windows read too low and are not used.
    static let minDistanceM = 480.0

    enum Outcome { case reading(Vo2Reading), tooSlow, noHeartRate, missingProfile }

    /// The estimate for the 6-minute window starting at `windowStart` that covered `distanceM`.
    /// The heart rate is the median of the ring's per-minute heart rate over the last 70 s of the
    /// window (the minutes that overlap it), read from the beats saved on this phone, so the ring
    /// must have synced after the walk.
    static func evaluate(id: String, activity: String, windowStart: Double, distanceM: Double,
                         source: String, profile: Profile?) -> Outcome {
        guard let age = profile?.age, let weight = profile?.weight_kg, let height = profile?.height_m,
              let sex = profile?.sex, sex == "M" || sex == "F" else { return .missingProfile }
        guard distanceM >= minDistanceM else { return .tooSlow }
        let end = windowStart + WalkMath.windowS
        let beats = ExerciseMetrics.series(startUnix: end - 130, endUnix: end).hr.map(\.v).filter { (40...210).contains($0) }
        guard let hr = WalkMath.median(beats) else { return .noHeartRate }
        let vo2 = vo2maxWalk6min(ageYears: age, weightKg: weight, sex: sex, distanceM: distanceM,
                                 heightCm: height * 100, hrBpm: hr)
        guard vo2 > 0 else { return .tooSlow }
        return .reading(Vo2Reading(id: id, atUnix: end, vo2: vo2, distanceM: (distanceM * 10).rounded() / 10,
                                   hrBpm: hr.rounded(), source: source, activity: activity))
    }

    /// Estimate from a recorded route of an exercise the user started.
    @MainActor
    static func fromRoute(_ route: [RoutePoint], id: String, activity: String, profile: Profile?) async {
        guard activity == "walking", let window = WalkMath.bestWindow(route) else { return }
        let outcome = await Task.detached {
            evaluate(id: id, activity: activity, windowStart: window.startUnix, distanceM: window.distanceM,
                     source: "gps", profile: profile)
        }.value
        switch outcome {
        case .reading(let r): Vo2Store.shared.add(r)
        case .tooSlow: Vo2Store.shared.markChecked(id)
        case .noHeartRate, .missingProfile: break
        }
    }

    /// Estimates from walks the ring detected in the last week, from the phone's step counter.
    /// Walks already looked at, and walks the user logged themselves, are skipped.
    @MainActor
    static func scan(_ s: Summary) async {
        guard PhoneDistance.available else { return }
        let logged = ActivityLogStore.shared.log.activities
        for w in s.workouts where w.isWorkout >= 0.5 && w.label.lowercased().contains("walk") && w.durationMin >= 6 {
            let id = "det-\(w.id)"
            guard !Vo2Store.shared.isChecked(id), let start = DayTimeline.timeFormat.date(from: w.start) else { continue }
            let a = start.timeIntervalSince1970, b = a + Double(w.durationMin) * 60
            if logged.contains(where: { $0.startUnix < b && $0.endUnix > a }) { continue }
            let minutes = await PhoneDistance.perMinute(from: start, minutes: w.durationMin)
            guard minutes.count == w.durationMin else { continue }
            guard let window = WalkMath.bestMinuteWindow(minutes) else { Vo2Store.shared.markChecked(id); continue }
            let profile = s.profile
            let outcome = await Task.detached {
                evaluate(id: id, activity: "walking", windowStart: a + Double(window.start) * 60,
                         distanceM: window.distanceM, source: "phone", profile: profile)
            }.value
            switch outcome {
            case .reading(let r): Vo2Store.shared.add(r)
            case .tooSlow: Vo2Store.shared.markChecked(id)
            case .noHeartRate, .missingProfile: break
            }
        }
    }
}
