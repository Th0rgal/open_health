import Foundation
import Combine
import HealthKit

/// Writes ring-derived samples to Apple Health and removes ones we previously
/// saved that no longer exist (a dropped false-positive hike, a restaged night).
/// Off unless the user turns it on in Profile. All samples are tagged with a
/// sync identifier so Health can replace them and we can find them to delete.
final class HealthExport: ObservableObject {
    static let shared = HealthExport()
    private static let enabledKey = "health.export.enabled"
    private static let fingerprintKey = "health.export.fp"
    private static let syncPrefix = "openoura."

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }
    @Published var status: String = ""

    private let store = HKHealthStore()
    private let queue = DispatchQueue(label: "md.thomas.openoura.health", qos: .utility)
    private var pushing = false

    private init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    private var shareTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = [HKObjectType.workoutType()]
        if let t = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .heartRate) { types.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) { types.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .restingHeartRate) { types.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .stepCount) { types.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) { types.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning) { types.insert(t) }
        return types
    }

    func setEnabled(_ on: Bool, summary: Summary?) {
        enabled = on
        guard on else {
            status = "Export paused. Samples already in Health are left in place."
            return
        }
        authorize { [weak self] ok, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async { self.status = error.localizedDescription }
                return
            }
            guard ok else {
                DispatchQueue.main.async { self.status = "Apple Health write access was not granted." }
                return
            }
            if let summary { self.push(summary, force: true) }
            else if let cached = SummaryCache.load() { self.push(cached, force: true) }
            else { DispatchQueue.main.async { self.status = "On. Data will export after the next analysis." } }
        }
    }

    func push(_ summary: Summary, force: Bool = false) {
        guard enabled, summary.error == nil else { return }
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let fp = fingerprint(summary)
        if !force, fp == UserDefaults.standard.string(forKey: Self.fingerprintKey) { return }
        queue.async { [weak self] in
            guard let self, !self.pushing else { return }
            self.pushing = true
            defer { self.pushing = false }
            self.authorizeAndWrite(summary, fingerprint: fp)
        }
    }

    func removeExportedSamples() {
        queue.async { [weak self] in
            guard let self else { return }
            let group = DispatchGroup()
            var errorText: String?
            for type in self.shareTypes {
                group.enter()
                self.allOurs(type) { samples, error in
                    if let error { errorText = error.localizedDescription; group.leave(); return }
                    guard !samples.isEmpty else { group.leave(); return }
                    self.store.delete(samples) { _, err in
                        if let err { errorText = err.localizedDescription }
                        group.leave()
                    }
                }
            }
            group.notify(queue: .main) {
                UserDefaults.standard.removeObject(forKey: Self.fingerprintKey)
                self.status = errorText ?? "Removed Open Oura samples from Apple Health."
                dlog("health", self.status)
            }
        }
    }

    private func authorize(completion: @escaping (Bool, Error?) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(false, NSError(domain: "open_oura", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "Apple Health is unavailable on this device."]))
            return
        }
        store.requestAuthorization(toShare: shareTypes, read: []) { ok, error in
            completion(ok, error)
        }
    }

    private func authorizeAndWrite(_ summary: Summary, fingerprint fp: String) {
        let group = DispatchGroup()
        var authError: Error?
        var authOK = false
        group.enter()
        authorize { ok, error in
            authOK = ok
            authError = error
            group.leave()
        }
        group.wait()
        if let authError {
            DispatchQueue.main.async { self.status = authError.localizedDescription }
            return
        }
        guard authOK else {
            DispatchQueue.main.async { self.status = "Apple Health write access was not granted." }
            return
        }

        let samples = buildSamples(summary)
        let workouts = plannedWorkouts(summary.workouts)
        dlog("health", "export \(samples.count) samples, \(workouts.count) workouts")
        if samples.isEmpty, workouts.isEmpty {
            DispatchQueue.main.async { self.status = "Nothing to export. Check Apple Health permissions for Open Oura." }
            return
        }
        let types = shareTypes
        let collect = DispatchGroup()
        var ours: [HKObject] = []
        var queryError: Error?
        for type in types {
            collect.enter()
            allOurs(type) { found, error in
                if let error { queryError = error }
                ours.append(contentsOf: found)
                collect.leave()
            }
        }
        collect.wait()
        if let queryError {
            DispatchQueue.main.async { self.status = queryError.localizedDescription }
            return
        }

        let wantedIDs = Set(samples.compactMap(Self.syncID) + workouts.map(\.syncID))
        let stale = ours.filter { sample in
            guard let id = Self.syncID(sample) else { return true }
            return !wantedIDs.contains(id)
        }
        let existingIDs = Set(ours.compactMap(Self.syncID))
        let freshSamples = samples.filter {
            guard let id = Self.syncID($0) else { return true }
            return !existingIDs.contains(id)
        }
        let freshWorkouts = workouts.filter { !existingIDs.contains($0.syncID) }

        let write = DispatchGroup()
        var writeError: Error?
        if !stale.isEmpty {
            write.enter()
            store.delete(stale) { _, error in
                if let error { writeError = error }
                write.leave()
            }
            write.wait()
        }
        if writeError == nil, !freshSamples.isEmpty {
            write.enter()
            store.save(freshSamples) { _, error in
                if let error { writeError = error }
                write.leave()
            }
            write.wait()
        }
        if writeError == nil {
            for workout in freshWorkouts {
                if let error = saveWorkout(workout) {
                    writeError = error
                    break
                }
            }
        }
        let added = freshSamples.count + freshWorkouts.count
        DispatchQueue.main.async {
            if let writeError {
                self.status = writeError.localizedDescription
                dlog("health", "export failed: \(writeError)")
            } else {
                UserDefaults.standard.set(fp, forKey: Self.fingerprintKey)
                self.status = "Exported \(added) new, removed \(stale.count) stale."
                dlog("health", self.status)
            }
        }
    }

    private func allOurs(_ type: HKSampleType, completion: @escaping ([HKObject], Error?) -> Void) {
        let pred = HKQuery.predicateForObjects(from: HKSource.default())
        let query = HKSampleQuery(sampleType: type, predicate: pred, limit: HKObjectQueryNoLimit,
                                  sortDescriptors: nil) { _, samples, error in
            completion(samples ?? [], error)
        }
        store.execute(query)
    }

    private func fingerprint(_ s: Summary) -> String {
        var parts: [String] = []
        parts.append(contentsOf: s.workouts.filter { $0.isWorkout >= 0.5 }.map(\.id).sorted())
        for n in s.nights {
            let st = n.stages ?? []
            parts.append("n\(n.start_ds ?? 0):\(st.count):\(st.reduce(0, +)):\(n.hrv_ms ?? 0):\(n.rhr ?? 0)")
        }
        for day in s.activity_daily.keys.sorted() {
            let st = s.activity_daily[day]!
            parts.append("d\(day):\(st.steps ?? 0):\(st.active_kcal ?? 0):\(st.distance_m ?? 0)")
        }
        return parts.joined(separator: "|")
    }

    private func buildSamples(_ s: Summary) -> [HKObject] {
        var out: [HKObject] = []
        for night in s.nights { out.append(contentsOf: sleepSamples(night)) }
        for night in s.nights { out.append(contentsOf: heartSamples(night)) }
        out.append(contentsOf: dailySamples(s.activity_daily))
        return out
    }

    private func meta(_ id: String) -> [String: Any] {
        [HKMetadataKeySyncIdentifier: Self.syncPrefix + id,
         HKMetadataKeySyncVersion: 1]
    }

    private static func syncID(_ sample: HKObject) -> String? {
        sample.metadata?[HKMetadataKeySyncIdentifier] as? String
    }

    private struct PlannedWorkout {
        let id: String
        let type: HKWorkoutActivityType
        let start: Date
        let end: Date
        var syncID: String { HealthExport.syncPrefix + "workout.\(id)" }
    }

    private func plannedWorkouts(_ workouts: [WorkoutSession]) -> [PlannedWorkout] {
        guard canShare(HKObjectType.workoutType()) else { return [] }
        var out: [PlannedWorkout] = []
        for w in workouts where w.isWorkout >= 0.5 {
            guard let (start, end) = Self.workoutDates(w) else { continue }
            out.append(PlannedWorkout(id: w.id, type: Self.activityType(w.label), start: start, end: end))
        }
        return out
    }

    /// Historical workouts must go through `HKWorkoutBuilder`; the old
    /// `HKWorkout(activityType:start:end:…)` initializers are deprecated.
    private func saveWorkout(_ plan: PlannedWorkout) -> Error? {
        let config = HKWorkoutConfiguration()
        config.activityType = plan.type
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        let group = DispatchGroup()
        var result: Error?
        func fail(_ error: Error?, fallback: String) {
            result = error ?? NSError(domain: "open_oura", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: fallback])
            group.leave()
        }
        group.enter()
        builder.beginCollection(withStart: plan.start) { success, error in
            guard success else { fail(error, fallback: "Could not start workout collection."); return }
            builder.addMetadata(self.meta("workout.\(plan.id)")) { success, error in
                guard success else { fail(error, fallback: "Could not tag workout."); return }
                builder.endCollection(withEnd: plan.end) { success, error in
                    guard success else { fail(error, fallback: "Could not end workout collection."); return }
                    builder.finishWorkout { _, error in
                        result = error
                        group.leave()
                    }
                }
            }
        }
        group.wait()
        return result
    }

    private func sleepSamples(_ night: NightRow) -> [HKObject] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
              canShare(type),
              let (start, end) = Self.nightInterval(night) else { return [] }
        var out: [HKObject] = []
        let key = "\(night.start_ds ?? 0)"
        out.append(HKCategorySample(type: type, value: HKCategoryValueSleepAnalysis.inBed.rawValue,
                                    start: start, end: end, metadata: meta("sleep.inbed.\(key)")))
        guard let stages = night.stages, stages.count > 1 else { return out }
        let epoch = end.timeIntervalSince(start) / Double(stages.count)
        var i = 0
        while i < stages.count {
            let code = stages[i]
            var j = i + 1
            while j < stages.count, stages[j] == code { j += 1 }
            let value: HKCategoryValueSleepAnalysis
            switch code {
            case 1: value = .asleepDeep
            case 2: value = .asleepCore
            case 3: value = .asleepREM
            default: value = .awake
            }
            let a = start.addingTimeInterval(Double(i) * epoch)
            let b = start.addingTimeInterval(Double(j) * epoch)
            out.append(HKCategorySample(type: type, value: value.rawValue, start: a, end: max(b, a.addingTimeInterval(1)),
                                        metadata: meta("sleep.\(key).\(i).\(j)")))
            i = j
        }
        return out
    }

    private func heartSamples(_ night: NightRow) -> [HKObject] {
        var out: [HKObject] = []
        guard let (start, end) = Self.nightInterval(night) else { return out }
        let key = "\(night.start_ds ?? 0)"
        if let type = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN),
           canShare(type), let hrv = night.hrv_ms, hrv > 0 {
            let q = HKQuantity(unit: .secondUnit(with: .milli), doubleValue: hrv)
            out.append(HKQuantitySample(type: type, quantity: q, start: end, end: end,
                                        metadata: meta("hrv.\(key)")))
        }
        if let type = HKObjectType.quantityType(forIdentifier: .restingHeartRate),
           canShare(type), let rhr = night.rhr, rhr > 0 {
            let q = HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: rhr)
            out.append(HKQuantitySample(type: type, quantity: q, start: end, end: end,
                                        metadata: meta("rhr.\(key)")))
        }
        if let type = HKObjectType.quantityType(forIdentifier: .heartRate), canShare(type),
           let series = night.series?.hr, series.count > 1 {
            let unit = HKUnit.count().unitDivided(by: .minute())
            let span = end.timeIntervalSince(start)
            let step = max(1, series.count / max(1, Int(span / 300)))
            var i = 0
            while i < series.count {
                let bpm = series[i]
                if bpm > 20, bpm < 220 {
                    let t = start.addingTimeInterval(span * Double(i) / Double(series.count - 1))
                    let q = HKQuantity(unit: unit, doubleValue: bpm)
                    out.append(HKQuantitySample(type: type, quantity: q, start: t, end: t,
                                                metadata: meta("hr.\(key).\(i)")))
                }
                i += step
            }
        }
        return out
    }

    private func dailySamples(_ daily: [String: DailyStat]) -> [HKObject] {
        var out: [HKObject] = []
        let cal = Calendar.current
        let dayFmt = DateFormatter()
        dayFmt.calendar = cal
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.dateFormat = "yyyy-MM-dd"
        for (day, st) in daily {
            guard let start = dayFmt.date(from: day),
                  let end = cal.date(byAdding: .day, value: 1, to: start) else { continue }
            if let type = HKObjectType.quantityType(forIdentifier: .stepCount), canShare(type),
               let steps = st.steps, steps > 0 {
                let q = HKQuantity(unit: .count(), doubleValue: steps)
                out.append(HKQuantitySample(type: type, quantity: q, start: start, end: end,
                                            metadata: meta("steps.\(day)")))
            }
            if let type = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned), canShare(type),
               let kcal = st.active_kcal, kcal > 0 {
                let q = HKQuantity(unit: .kilocalorie(), doubleValue: kcal)
                out.append(HKQuantitySample(type: type, quantity: q, start: start, end: end,
                                            metadata: meta("kcal.\(day)")))
            }
            if let type = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning), canShare(type),
               let metres = st.distance_m, metres > 0 {
                let q = HKQuantity(unit: .meter(), doubleValue: metres)
                out.append(HKQuantitySample(type: type, quantity: q, start: start, end: end,
                                            metadata: meta("dist.\(day)")))
            }
        }
        return out
    }

    private func canShare(_ type: HKSampleType) -> Bool {
        store.authorizationStatus(for: type) == .sharingAuthorized
    }

    private static func workoutDates(_ w: WorkoutSession) -> (Date, Date)? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        guard let start = f.date(from: w.start) else { return nil }
        let day = String(w.start.prefix(10))
        guard var end = f.date(from: "\(day) \(w.end)") else { return nil }
        if end <= start { end = Calendar.current.date(byAdding: .day, value: 1, to: end) ?? end }
        return (start, end)
    }

    private static func nightInterval(_ n: NightRow) -> (Date, Date)? {
        guard let ymd = n.ymd, let startHM = n.start, let endHM = n.end else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        guard let start = f.date(from: "\(ymd) \(startHM)") else { return nil }
        var end = f.date(from: "\(ymd) \(endHM)") ?? start
        if end <= start { end = Calendar.current.date(byAdding: .day, value: 1, to: end) ?? end }
        return (start, end)
    }

    private static func activityType(_ label: String) -> HKWorkoutActivityType {
        let l = label.lowercased()
        switch true {
        case l.contains("hik"): return .hiking
        case l.contains("walk"): return .walking
        case l.contains("run"): return .running
        case l.contains("cycl"), l.contains("bik"): return .cycling
        case l.contains("swim"): return .swimming
        case l.contains("row"): return .rowing
        case l.contains("strength"): return .traditionalStrengthTraining
        case l.contains("yoga"): return .yoga
        case l.contains("pilates"): return .pilates
        case l.contains("hiit"): return .highIntensityIntervalTraining
        case l.contains("elliptical"): return .elliptical
        case l.contains("ski"): return .crossCountrySkiing
        case l.contains("snowboard"): return .snowboarding
        case l.contains("climb"): return .climbing
        case l.contains("golf"): return .golf
        case l.contains("dance"): return .cardioDance
        case l.contains("box"): return .boxing
        case l.contains("martial"): return .martialArts
        default: return .other
        }
    }
}
