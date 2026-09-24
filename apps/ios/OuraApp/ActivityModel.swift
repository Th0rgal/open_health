#if TORCH
import Foundation

/// Android-parity runner for Oura's automatic_activity_detection 3.1.11 model.
/// The official app evaluates each local day separately and feeds the real decoded
/// step-motion channel. Both details materially affect the predicted sport.
enum ActivityModel {
    private static let behavior: [Int: String] = [
        -1: "nothing", 0: "–", 1: "badminton", 2: "boxing", 3: "cross-country skiing",
        4: "cross training", 5: "cycling", 6: "dance", 7: "elliptical", 8: "strength",
        9: "hockey", 10: "pilates", 11: "rowing", 12: "running", 13: "swimming", 14: "walking",
        15: "yoga", 16: "golf", 17: "tennis", 18: "climbing", 19: "downhill skiing",
        20: "snowboarding", 21: "hiking", 22: "horseback riding", 23: "volleyball", 24: "basketball",
        25: "football", 26: "soccer", 27: "baseball", 28: "core", 29: "cricket", 30: "HIIT",
        31: "diving", 32: "fitness class", 39: "martial arts", 41: "mountain biking",
        42: "nordic walking", 49: "stretching", 50: "surfing", 51: "water fitness",
        53: "padel", 65535: "other", 65536: "nap", 65537: "sleep", 65538: "pause",
        70937: "meditation", 71201: "eating", 71227: "relax", 71239: "transport",
    ]

    private struct InferenceFailure: Error, CustomStringConvertible {
        let description: String
        init(_ message: String) { description = message }
        static func bridge() -> Self {
            let detail = oura_activity_last_error().map { String(cString: $0) } ?? ""
            return Self(detail.isEmpty ? "model returned an error without details" : detail)
        }
    }

    private struct TimedRow {
        let unixMinute: Double
        let values: [Float]
    }

    /// Everything the AAD model receives for one local day — also the exact
    /// material the incremental cache fingerprints, so cache identity and model
    /// input can never disagree. `rawStep` is the undecoded 27-col gait packets;
    /// the decoder runs only on a cache miss so hiking days don't decode twice.
    private struct DayInputs {
        let dayStart: Date
        let context: [Float]
        let met: (flat: [Float], count: Int)
        let rawStep: [TimedRow]
        let motion: (flat: [Float], count: Int)
        let temp: (flat: [Float], count: Int)
        let hr: (flat: [Float], count: Int)
    }

    /// Bumped whenever the per-day preprocessing (dedup, placeholders, reject rule)
    /// changes, so cached results — cached failures above all — are recomputed once
    /// instead of being trusted for inputs the new pipeline would build differently.
    private static let pipelineVersion = 2

    static func run(profile: Profile?, events: EventStore.Events, clock: EventStore.RingClock,
                    onlyDay: String? = nil, force: Bool = false,
                    cacheFile: String = ModelCacheStore.activityFile,
                    progress: @escaping @Sendable (String) -> Void = { _ in },
                    inputsSink: (([String: Any]) -> Void)? = nil) -> (sessions: [WorkoutSession], error: String?) {
        guard let aadPath = Bundle.main.path(forResource: "automatic_activity_detection_3_1_11", ofType: "ptl")
        else { return ([], "activity model file missing from the app bundle") }

        guard !events.isEmpty else { return ([], onlyDay == nil ? nil : "No activity data is saved for this day.") }
        let globalKey = ModelCacheStore.globalKey(profile: profile)
        // Nothing changed since the last complete pass (same rows, same clock
        // anchors): the cached days are the answer, without streaming the store.
        let storeDigest = events.digest().map { "v\(pipelineVersion):\($0)" }
        if onlyDay == nil, !force, let storeDigest,
           ModelCacheStore.loadDigest(cacheFile, globalKey: globalKey) == storeDigest {
            let cache: [String: ActivityDayEntry] = ModelCacheStore.load(cacheFile, globalKey: globalKey)
            let failed = cache.filter { $0.value.failed == true }.map(\.key).sorted(by: >)
            dlog("models", "activity cache=digest-hit days=\(cache.count) rejected=\(failed.count)")
            return (cache.values.flatMap(\.sessions).sorted { $0.start < $1.start }, failureMessage(failed))
        }
        let nan = Float.nan
        func number(_ value: Any?) -> Float { (value as? NSNumber)?.floatValue ?? 0 }

        var met: [TimedRow] = []
        var motion: [TimedRow] = []
        var temperature: [TimedRow] = []
        var heartRate: [TimedRow] = []
        for event in events.restricted("tag IN (80,71,70,128)") {
            // These are minute buckets; remove the few-second epoch-anchor jitter.
            // Undated data (an untrustworthy boot clock) has no day to belong to.
            guard let seconds = clock.datedUnixSeconds(event.ds, capturedUnix: event.cu) else { continue }
            let unixMinute = (seconds / 60).rounded()
            switch event.tag {
            case 0x50:
                if let values = event.json["met"] as? [NSNumber] {
                    for (index, value) in values.enumerated() {
                        met.append(TimedRow(unixMinute: unixMinute + Double(index), values: [value.floatValue]))
                    }
                }
            case 0x47:
                motion.append(TimedRow(unixMinute: unixMinute, values: [
                    number(event.json["orientation"]), number(event.json["motion_seconds"]),
                    number(event.json["avg_x"]), number(event.json["avg_y"]), number(event.json["avg_z"]),
                    nan, number(event.json["low_intensity"]), number(event.json["high_intensity"]),
                ]))
            case 0x46:
                if let value = (event.json["temps_c"] as? [NSNumber])?.first {
                    temperature.append(TimedRow(unixMinute: unixMinute, values: [value.floatValue]))
                }
            case 0x80:
                if let values = event.json["hr_bpm"] as? [NSNumber], !values.isEmpty {
                    let average = values.reduce(Float(0)) { $0 + $1.floatValue } / Float(values.count)
                    heartRate.append(TimedRow(unixMinute: unixMinute, values: [average]))
                }
            default:
                break
            }
        }
        guard events.error == nil, !AnalysisRun.cancelled else { return ([], "analysis interrupted") }
        guard !met.isEmpty else { return ([], onlyDay == nil ? nil : "No activity data is saved for this day.") }

        let stepPackets = collectStepPackets(events: events, clock: clock)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        // Newest first: today's card is the one the user is waiting on, and a
        // mid-run kill loses the least-relevant (oldest) days.
        let dayStarts = Set(met.map {
            calendar.startOfDay(for: Date(timeIntervalSince1970: $0.unixMinute * 60))
        }).sorted(by: >)

        let sex: Float = profile?.sex?.uppercased() == "M" ? 1 : 0
        let user: [Float] = [Float(profile?.age ?? 30), sex, Float(profile?.height_m ?? 1.78),
                             Float(profile?.weight_kg ?? 75)] + Array(repeating: nan, count: 10)

        func dayInputs(_ dayStart: Date) -> DayInputs? {
            let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart)!
            let lo = dayStart.timeIntervalSince1970 / 60
            let hi = nextDay.timeIntervalSince1970 / 60
            func rowsOfDay(_ rows: [TimedRow]) -> [TimedRow] {
                rows.filter { $0.unixMinute >= lo && $0.unixMinute < hi }.sorted { $0.unixMinute < $1.unixMinute }
            }
            // The ring may resend a MET minute; Android's Realm series keeps one value per
            // timestamp (last write wins). Duplicates make the model's resampler throw.
            var metByMinute: [Double: TimedRow] = [:]
            for row in rowsOfDay(met) { metByMinute[row.unixMinute.rounded()] = row }
            let metRows = metByMinute.keys.sorted().map { metByMinute[$0]! }
            guard let firstMet = metRows.first?.unixMinute, let lastMet = metRows.last?.unixMinute else { return nil }
            func flatten(_ rows: [TimedRow]) -> (flat: [Float], count: Int) {
                (rows.flatMap { [Float($0.unixMinute - lo)] + $0.values }, rows.count)
            }
            // A series with no sample inside the MET window is dropped entirely by the
            // model's valid-time clipping, and it then indexes the empty tensor. A NaN
            // placeholder at the first MET minute keeps the channel present (and is
            // ignored as missing data), exactly like tools/run_activity_model.py.
            func matrix(_ rows: [TimedRow], columns: Int) -> (flat: [Float], count: Int) {
                var selected = rowsOfDay(rows)
                if !selected.contains(where: { $0.unixMinute >= firstMet && $0.unixMinute <= lastMet }) {
                    selected.append(TimedRow(unixMinute: firstMet, values: Array(repeating: nan, count: columns - 1)))
                    selected.sort { $0.unixMinute < $1.unixMinute }
                }
                return flatten(selected)
            }
            let metDay = flatten(metRows)
            let motionDay = matrix(motion, columns: 9)
            let tempDay = matrix(temperature, columns: 2)
            let hrDay = matrix(heartRate, columns: 2)
            let rawStep = stepPackets.filter { $0.unixMinute >= lo && $0.unixMinute < hi }
                .sorted { $0.unixMinute < $1.unixMinute }
            let components = calendar.dateComponents([.year, .month, .day, .weekday], from: dayStart)
            let context: [Float] = [Float(components.year!), Float(components.month!), Float(components.day!),
                                    Float((components.weekday! + 5) % 7)]
            return DayInputs(dayStart: dayStart, context: context,
                             met: metDay, rawStep: rawStep,
                             motion: motionDay, temp: tempDay, hr: hrDay)
        }

        // A day's fingerprint covers its exact model inputs; profile and timezone
        // live in the global key. A hit is therefore the result the model would
        // have produced for those inputs.
        func fingerprint(_ inputs: DayInputs) -> String {
            var h = FNV64()
            h.combine(pipelineVersion)
            h.combine(inputs.dayStart.timeIntervalSince1970)
            h.combine(inputs.context)
            h.combine(inputs.met.flat); h.combine(inputs.met.count)
            h.combine(inputs.rawStep.count)
            for row in inputs.rawStep { h.combine(row.unixMinute); h.combine(row.values) }
            h.combine(inputs.motion.flat); h.combine(inputs.motion.count)
            h.combine(inputs.temp.flat); h.combine(inputs.temp.count)
            h.combine(inputs.hr.flat); h.combine(inputs.hr.count)
            return h.hex
        }
        var cache: [String: ActivityDayEntry] = ModelCacheStore.load(cacheFile,
                                                                     globalKey: globalKey)
        let dayKeyFmt = DateFormatter()
        dayKeyFmt.timeZone = .current
        dayKeyFmt.dateFormat = "yyyy-MM-dd"

        // Pass 1: fingerprint every day and separate cache hits from the days that
        // actually need the model, so the progress pill counts real work ("day 2 of 3")
        // rather than the whole history.
        var sessions: [WorkoutSession] = []
        var currentKeys = Set<String>()
        var pending: [(key: String, fp: String, inputs: DayInputs)] = []
        var cachedFailures: [String] = []
        for dayStart in dayStarts {
            guard !AnalysisRun.cancelled, events.error == nil else { return ([], "analysis interrupted") }
            let key = dayKeyFmt.string(from: dayStart)
            if let onlyDay, key != onlyDay { continue }
            guard let inputs = dayInputs(dayStart) else { continue }
            let fp = fingerprint(inputs)
            currentKeys.insert(key)
            if !force, let entry = cache[key], entry.fp == fp {
                sessions.append(contentsOf: entry.sessions)
                if entry.failed == true { cachedFailures.append(key) }
            } else { pending.append((key, fp, inputs)) }
        }
        let staleKeys = pending.filter { cache[$0.key] != nil }.count
        if !pending.isEmpty {
            dlog("models", "activity pending=\(pending.count) of \(currentKeys.count) (inputs changed=\(staleKeys), new=\(pending.count - staleKeys), cached=\(cache.count))")
        }
        // Pass 2: run only the missing days; persist every few days and at the end so a
        // mid-run kill resumes instead of restarting. A day the model rejects is cached
        // as failed (under its fingerprint) and skipped, so one degenerate day can never
        // block the days behind it or be retried on every launch; a forced refresh reruns it.
        var recomputed = 0
        var failedDays: [String] = []
        for (index, day) in pending.enumerated() {
            guard !AnalysisRun.cancelled, events.error == nil else {
                if recomputed > 0 { ModelCacheStore.save(cacheFile, globalKey: globalKey, entries: cache) }
                return ([], "analysis interrupted")
            }
            progress(onlyDay != nil ? "Refreshing activity" : pending.count > 1 ? "Analyzing activity \(index + 1)/\(pending.count)" : "Analyzing activity")
            var daySessions: [WorkoutSession] = []
            var failed = false
            if isDegenerate(day.inputs) {
                dlog("models", "activity day=\(day.key) met=\(day.inputs.met.count) motion=\(day.inputs.motion.count) hr=\(day.inputs.hr.count): no valid wear window for the model, no sessions")
            } else {
                do { daySessions = try runDay(day.inputs, user: user, aadPath: aadPath, nan: nan, inputsSink: inputsSink) }
                catch {
                    guard !AnalysisRun.cancelled else {
                        if recomputed > 0 { ModelCacheStore.save(cacheFile, globalKey: globalKey, entries: cache) }
                        return ([], "analysis interrupted")
                    }
                    let inputs = day.inputs
                    dlog("models", "activity day=\(day.key) met=\(inputs.met.count) motion=\(inputs.motion.count) temperature=\(inputs.temp.count) hr=\(inputs.hr.count) stepPackets=\(inputs.rawStep.count) failed: \(error)")
                    failed = true
                    failedDays.append(day.key)
                }
            }
            sessions.append(contentsOf: daySessions)
            cache[day.key] = ActivityDayEntry(fp: day.fp, sessions: daySessions, failed: failed ? true : nil)
            recomputed += 1
            if recomputed % 5 == 0 { ModelCacheStore.save(cacheFile, globalKey: globalKey, entries: cache) }
        }
        if recomputed > 0 { ModelCacheStore.save(cacheFile, globalKey: globalKey, entries: cache) }
        guard !AnalysisRun.cancelled, events.error == nil else { return ([], "analysis interrupted") }
        if onlyDay != nil && currentKeys.isEmpty { return ([], "No activity data is saved for this day.") }
        dlog("models", "activity recomputed=\(recomputed) total=\(currentKeys.count) rejected=\(failedDays.count + cachedFailures.count)")
        // Drop days the current data no longer produces (e.g. re-dated by a clock
        // re-anchor) so the file tracks the DB instead of growing stale keys, and
        // stamp the complete pass with the store digest for the next early exit.
        let pruned = cache.filter { currentKeys.contains($0.key) }
        if onlyDay == nil {
            ModelCacheStore.save(cacheFile, globalKey: globalKey, entries: pruned, digest: storeDigest)
        }
        let allFailed = (failedDays + cachedFailures).sorted(by: >)
        return (sessions.sorted { $0.start < $1.start }, failureMessage(allFailed))
    }

    /// The user-facing error for days the model rejected; the same text for one day
    /// is what the refresh path removes from `modelErrors` when a rerun succeeds.
    static func failureMessage(_ failedDays: [String]) -> String? {
        guard let first = failedDays.first else { return nil }
        let more = failedDays.count - 1
        return "Activity analysis failed for \(first)\(more > 0 ? " (+\(more) more)" : ""). See diagnostics for details."
    }

    /// Mirror of the model's `get_last_valid_time`: with fewer than `minValidMets`
    /// worn MET minutes before the last motion sample the valid window collapses to
    /// minute 0, after which the graph indexes an empty MET tensor and throws. Such a
    /// day has no evaluable data, so it yields no sessions instead of an error.
    /// Kept identical to `model_would_reject` in tools/run_activity_model.py.
    private static let nonWearMetThreshold: Float = 0.2
    private static let minValidMets = 10
    private static let acceptableLastHrMissingMinutes: Float = 5
    private static func isDegenerate(_ inputs: DayInputs) -> Bool {
        func lastTime(_ series: (flat: [Float], count: Int), columns: Int) -> Float {
            series.count > 0 ? series.flat[(series.count - 1) * columns] : 0
        }
        let lastMotion = lastTime(inputs.motion, columns: 9).rounded(.up)
        var lastWornMet: Float?
        var worn = 0
        for row in 0..<inputs.met.count {
            let t = inputs.met.flat[row * 2], value = inputs.met.flat[row * 2 + 1]
            if value > nonWearMetThreshold && t <= lastMotion { worn += 1; lastWornMet = t }
        }
        guard worn >= minValidMets, let lastWornMet else { return inputs.met.flat[0] > 0 }
        let lastHr = lastTime(inputs.hr, columns: 2).rounded(.up) + acceptableLastHrMissingMinutes
        let lastTemp = lastTime(inputs.temp, columns: 2).rounded(.up)
        let lastStep = lastTime(inputs.met, columns: 2)   // the step boundary row sits on the last MET minute
        let lastValid = min(lastWornMet, lastMotion, lastHr, lastStep, lastTemp)
        return inputs.met.flat[0] > lastValid
    }

    /// The exact tensors one local day feeds the model (step packets decoded), for
    /// parity checks against tools/run_activity_model.py. Debug/test use only.
    static func debugInputs(profile: Profile?, events: EventStore.Events, clock: EventStore.RingClock,
                            day: String) -> [String: Any]? {
        var captured: [String: Any]?
        _ = run(profile: profile, events: events, clock: clock, onlyDay: day, force: true,
                cacheFile: "debug-activity-\(UUID().uuidString).json", inputsSink: { captured = $0 })
        return captured
    }

    /// One AAD inference over one local day's inputs.
    private static func runDay(_ inputs: DayInputs, user: [Float], aadPath: String, nan: Float,
                               inputsSink: (([String: Any]) -> Void)? = nil) throws -> [WorkoutSession] {
        let decoded = try decodeStepPackets(inputs.rawStep)
        let lo = inputs.dayStart.timeIntervalSince1970 / 60
        let firstMet = inputs.met.flat[0]
        let lastMet = inputs.met.flat[(inputs.met.count - 1) * 2]
        // Boundary rows keep the AAD valid-time window equal to the complete MET day.
        // unixMinute is absolute; column 0 of the tensor is minutes since local midnight.
        var stepRows = [TimedRow(unixMinute: lo + Double(firstMet), values: Array(repeating: nan, count: 11))]
        stepRows.append(contentsOf: decoded)
        stepRows.append(TimedRow(unixMinute: lo + Double(lastMet), values: Array(repeating: nan, count: 11)))
        let stepFlat = stepRows.flatMap { [Float($0.unixMinute - lo)] + $0.values }
        let stepCount = stepRows.count

        inputsSink?(["context": inputs.context, "user": user, "met": inputs.met.flat, "step": stepFlat,
                     "motion": inputs.motion.flat, "temp": inputs.temp.flat, "hr": inputs.hr.flat,
                     "rawStep": inputs.rawStep.map { [$0.unixMinute - lo] + $0.values.map(Double.init) }])
        var context = inputs.context, userVec = user
        var metFlat = inputs.met.flat
        var step = stepFlat
        var motionFlat = inputs.motion.flat, tempFlat = inputs.temp.flat, hrFlat = inputs.hr.flat
        var output = [Float](repeating: 0, count: 512 * 9)
        let count = oura_activity(aadPath, &context, &userVec,
                                  &metFlat, Int32(inputs.met.count), &step, Int32(stepCount),
                                  &motionFlat, Int32(inputs.motion.count), &tempFlat, Int32(inputs.temp.count),
                                  &hrFlat, Int32(inputs.hr.count), 0.5, 10.0, &output, 512)
        guard count >= 0 else { throw InferenceFailure.bridge() }
        if count == 0 { return [] }
        let stamp = DateFormatter(); stamp.timeZone = .current; stamp.dateFormat = "yyyy-MM-dd HH:mm"
        let time = DateFormatter(); time.timeZone = .current; time.dateFormat = "HH:mm"
        var sessions: [WorkoutSession] = []
        for row in 0..<Int(count) {
            let values = Array(output[row * 9..<row * 9 + 9])
            let start = inputs.dayStart.addingTimeInterval(Double(values[0]) * 60)
            let end = inputs.dayStart.addingTimeInterval(Double(values[1]) * 60)
            sessions.append(WorkoutSession(
                start: stamp.string(from: start), end: time.string(from: end),
                durationMin: Int((values[1] - values[0]).rounded()),
                label: behavior[Int(values[3])] ?? "activity", isWorkout: Double(values[2])
            ))
        }
        return sessions
    }

    private static func collectStepPackets(events: EventStore.Events, clock: EventStore.RingClock) -> [TimedRow] {
        var secondPackets: [Int64: Data] = [:]
        for event in events.restricted("tag=127") {
            guard let body = event.body, body.count == 14,
                  let seconds = clock.datedUnixSeconds(event.ds, capturedUnix: event.cu) else { continue }
            let wallDecisecond = Int64((seconds * 10).rounded())
            secondPackets[wallDecisecond] = body
        }
        var rows: [TimedRow] = []
        for event in events.restricted("tag=126") {
            guard let first = event.body, first.count == 14,
                  let seconds = clock.datedUnixSeconds(event.ds, capturedUnix: event.cu) else { continue }
            let wallDecisecond = Int64((seconds * 10).rounded())
            guard let second = secondPackets[wallDecisecond + 1] else { continue }
            let values = unpack(first: [UInt8](first), second: [UInt8](second)).map(Float.init)
            rows.append(TimedRow(unixMinute: Double(wallDecisecond) / 10.0 / 60.0, values: values))
        }
        return rows
    }

    /// Decode one day's (or a chunked slice of a day's) 27-col gait packets.
    /// Hiking days can be thousands of pairs; the old path fed the whole history
    /// as one tensor and jetsam-killed the app.
    private static func decodeStepPackets(_ packets: [TimedRow]) throws -> [TimedRow] {
        guard !packets.isEmpty else { return [] }
        guard let modelPath = Bundle.main.path(forResource: "steps_motion_decoder_2_0_0", ofType: "ptl")
        else { throw InferenceFailure("step decoder model file is missing from the app bundle") }
        let chunk = 4096
        let overlap = 24
        if packets.count <= chunk {
            return try runStepDecoder(packets, modelPath: modelPath)
        }
        var out: [TimedRow] = []
        var seen = Set<Int64>()
        var i = 0
        while i < packets.count {
            let end = min(packets.count, i + chunk)
            try AnalysisRun.check()
            let decoded = try runStepDecoder(Array(packets[i..<end]), modelPath: modelPath)
            for row in decoded {
                let key = Int64((row.unixMinute * 60_000).rounded())
                if seen.insert(key).inserted { out.append(row) }
            }
            if end == packets.count { break }
            i = end - overlap
        }
        return out
    }

    private static func runStepDecoder(_ packets: [TimedRow], modelPath: String) throws -> [TimedRow] {
        var timestamps = packets.map { Int64(($0.unixMinute * 60_000).rounded()) }
        var raw = packets.flatMap(\.values)
        let capacity = packets.count * 3
        var outputTimestamps = [Int64](repeating: 0, count: capacity)
        var outputFeatures = [Float](repeating: 0, count: capacity * 11)
        let count = oura_stepmotion(modelPath, &timestamps, &raw, Int32(packets.count),
                                    &outputTimestamps, &outputFeatures, Int32(capacity))
        guard count >= 0 else { throw InferenceFailure.bridge() }
        if count == 0 { return [] }
        let order = [6, 7, 9, 10, 8, 5, 4, 0, 3, 1, 2]
        return (0..<Int(count)).map { row in
            let decoded = Array(outputFeatures[row * 11..<row * 11 + 11])
            return TimedRow(unixMinute: Double(outputTimestamps[row]) / 60_000,
                            values: order.map { decoded[$0] })
        }
    }

    /// Native Ring 5 real-step packet layout, recovered from libringeventparser.so.
    private static func unpack(first p1: [UInt8], second p2: [UInt8]) -> [Int] {
        let c = Int(p2[13])
        return [
            Int(p2[10]) << 2 | c & 3, Int(p2[11]), Int(p2[12]),
            Int(p1[0]) << 1 | Int(p1[3]) >> 7, Int(p1[1]) << 1 | c >> 7 & 1,
            Int(p1[2]) << 1 | c >> 6 & 1, Int(p1[3]) & 127, Int(p1[4]), Int(p1[5]), Int(p1[6]), Int(p1[7]),
            Int(p1[8]) << 1 | Int(p1[11]) >> 7, Int(p1[9]) << 1 | c >> 5 & 1,
            Int(p1[10]) << 1 | c >> 4 & 1, Int(p1[11]) & 127, Int(p1[12]), Int(p1[13]), Int(p2[0]), Int(p2[1]),
            Int(p2[2]) << 1 | Int(p2[5]) >> 7, Int(p2[3]) << 1 | c >> 3 & 1,
            Int(p2[4]) << 1 | c >> 2 & 1, Int(p2[5]) & 127, Int(p2[6]), Int(p2[7]), Int(p2[8]), Int(p2[9]),
        ]
    }
}
#endif
