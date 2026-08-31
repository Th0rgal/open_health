#if TORCH
import Foundation

/// Android-parity runner for Oura's automatic_activity_detection 3.1.11 model.
/// The official app evaluates each local day separately and feeds the real decoded
/// step-motion channel. Both details materially affect the predicted sport.
enum ActivityModel {
    private static let behavior: [Int: String] = [
        -1: "nothing", 0: "—", 1: "badminton", 2: "boxing", 3: "cross-country skiing",
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

    static func run(profile: Profile?, events: [EventStore.Ev], clock: EventStore.RingClock,
                    progress: @escaping @Sendable (String) -> Void = { _ in }) -> (sessions: [WorkoutSession], error: String?) {
        guard let aadPath = Bundle.main.path(forResource: "automatic_activity_detection_3_1_11", ofType: "ptl")
        else { return ([], "activity model file missing from the app bundle") }

        guard !events.isEmpty else { return ([], nil) }
        let nan = Float.nan
        func number(_ value: Any?) -> Float { (value as? NSNumber)?.floatValue ?? 0 }

        var met: [TimedRow] = []
        var motion: [TimedRow] = []
        var temperature: [TimedRow] = []
        var heartRate: [TimedRow] = []
        for event in events {
            // These are minute buckets; remove the few-second epoch-anchor jitter.
            let unixMinute = (clock.unixSeconds(event.ds, capturedUnix: event.cu) / 60).rounded()
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
        guard !met.isEmpty else { return ([], nil) }

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
            func matrix(_ rows: [TimedRow], columns: Int, required: Bool = true) -> (flat: [Float], count: Int) {
                let selected = rows.filter { $0.unixMinute >= lo && $0.unixMinute < hi }
                    .sorted { $0.unixMinute < $1.unixMinute }
                if selected.isEmpty && required {
                    return ([0] + Array(repeating: nan, count: columns - 1), 1)
                }
                return (selected.flatMap { [Float($0.unixMinute - lo)] + $0.values }, selected.count)
            }
            let metDay = matrix(met, columns: 2)
            guard metDay.count > 0 else { return nil }
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
        let globalKey = ModelCacheStore.globalKey(profile: profile)
        var cache: [String: ActivityDayEntry] = ModelCacheStore.load(ModelCacheStore.activityFile,
                                                                     globalKey: globalKey)
        let dayKeyFmt = DateFormatter()
        dayKeyFmt.timeZone = .current
        dayKeyFmt.dateFormat = "yyyy-MM-dd"

        var sessions: [WorkoutSession] = []
        var dirty: [(key: String, inputs: DayInputs, fp: String)] = []
        var currentKeys = Set<String>()
        for dayStart in dayStarts {
            guard let inputs = dayInputs(dayStart) else { continue }
            let key = dayKeyFmt.string(from: dayStart)
            let fp = fingerprint(inputs)
            currentKeys.insert(key)
            if let entry = cache[key], entry.fp == fp {
                sessions.append(contentsOf: entry.sessions)
            } else {
                dirty.append((key, inputs, fp))
            }
        }
        dlog("models", "activity: \(dirty.count)/\(currentKeys.count) days to recompute")
        for (index, day) in dirty.enumerated() {
            progress("detecting activity · day \(index + 1)/\(dirty.count)")
            let daySessions = runDay(day.inputs, user: user, aadPath: aadPath, nan: nan)
            sessions.append(contentsOf: daySessions)
            cache[day.key] = ActivityDayEntry(fp: day.fp, sessions: daySessions)
            // Save after every completed day: a mid-run kill resumes here instead
            // of restarting the whole history.
            ModelCacheStore.save(ModelCacheStore.activityFile, globalKey: globalKey, entries: cache)
        }
        // Drop days the current data no longer produces (e.g. re-dated by a clock
        // re-anchor) so the file tracks the DB instead of growing stale keys.
        let pruned = cache.filter { currentKeys.contains($0.key) }
        if pruned.count != cache.count {
            ModelCacheStore.save(ModelCacheStore.activityFile, globalKey: globalKey, entries: pruned)
        }
        return (sessions.sorted { $0.start < $1.start }, nil)
    }

    /// One AAD inference over one local day's inputs.
    private static func runDay(_ inputs: DayInputs, user: [Float], aadPath: String, nan: Float) -> [WorkoutSession] {
        let decoded = decodeStepPackets(inputs.rawStep)
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

        var context = inputs.context, userVec = user
        var metFlat = inputs.met.flat
        var step = stepFlat
        var motionFlat = inputs.motion.flat, tempFlat = inputs.temp.flat, hrFlat = inputs.hr.flat
        var output = [Float](repeating: 0, count: 512 * 9)
        let count = oura_activity(aadPath, &context, &userVec,
                                  &metFlat, Int32(inputs.met.count), &step, Int32(stepCount),
                                  &motionFlat, Int32(inputs.motion.count), &tempFlat, Int32(inputs.temp.count),
                                  &hrFlat, Int32(inputs.hr.count), 0.5, 10.0, &output, 512)
        guard count > 0 else { return [] }
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

    private static func collectStepPackets(events: [EventStore.Ev], clock: EventStore.RingClock) -> [TimedRow] {
        var secondPackets: [Int64: Data] = [:]
        for event in events where event.tag == 0x7F {
            guard let body = event.body, body.count == 14 else { continue }
            let wallDecisecond = Int64((clock.unixSeconds(event.ds, capturedUnix: event.cu) * 10).rounded())
            secondPackets[wallDecisecond] = body
        }
        var rows: [TimedRow] = []
        for event in events where event.tag == 0x7E {
            guard let first = event.body, first.count == 14 else { continue }
            let wallDecisecond = Int64((clock.unixSeconds(event.ds, capturedUnix: event.cu) * 10).rounded())
            guard let second = secondPackets[wallDecisecond + 1] else { continue }
            let values = unpack(first: [UInt8](first), second: [UInt8](second)).map(Float.init)
            rows.append(TimedRow(unixMinute: Double(wallDecisecond) / 10.0 / 60.0, values: values))
        }
        return rows
    }

    /// Decode one day's (or a chunked slice of a day's) 27-col gait packets.
    /// Hiking days can be thousands of pairs; the old path fed the whole history
    /// as one tensor and jetsam-killed the app.
    private static func decodeStepPackets(_ packets: [TimedRow]) -> [TimedRow] {
        guard !packets.isEmpty,
              let modelPath = Bundle.main.path(forResource: "steps_motion_decoder_2_0_0", ofType: "ptl")
        else { return [] }
        let chunk = 4096
        let overlap = 24
        if packets.count <= chunk {
            return runStepDecoder(packets, modelPath: modelPath)
        }
        var out: [TimedRow] = []
        var seen = Set<Int64>()
        var i = 0
        while i < packets.count {
            let end = min(packets.count, i + chunk)
            for row in runStepDecoder(Array(packets[i..<end]), modelPath: modelPath) {
                let key = Int64((row.unixMinute * 60_000).rounded())
                if seen.insert(key).inserted { out.append(row) }
            }
            if end == packets.count { break }
            i = end - overlap
        }
        return out
    }

    private static func runStepDecoder(_ packets: [TimedRow], modelPath: String) -> [TimedRow] {
        var timestamps = packets.map { Int64(($0.unixMinute * 60_000).rounded()) }
        var raw = packets.flatMap(\.values)
        let capacity = packets.count * 3
        var outputTimestamps = [Int64](repeating: 0, count: capacity)
        var outputFeatures = [Float](repeating: 0, count: capacity * 11)
        let count = oura_stepmotion(modelPath, &timestamps, &raw, Int32(packets.count),
                                    &outputTimestamps, &outputFeatures, Int32(capacity))
        guard count > 0 else { return [] }
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
