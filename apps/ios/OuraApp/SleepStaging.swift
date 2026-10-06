#if TORCH
import Foundation
// sqlite3 comes from the bridging header (TorchBridge.h includes <sqlite3.h>)

// On-device sleep staging: read the synced DB, assemble the raw SleepNet inputs
// (a faithful port of tools/run_sleep_model.py — the model bakes in its own
// preprocessing), and run sleepnet_moonstone via the LibTorch lite bridge. Returns
// date-label → per-30s stage codes, matching the web dashboard's `nights[].stages`.
enum SleepStaging {
    /// Everything SleepNet receives for one night — also the exact material the
    /// incremental cache fingerprints.
    struct NightInputs {
        let startDs: Int64, endDs: Int64
        let startMs: Int64, endMs: Int64
        let beats: [(Int64, Float, Float, Float)]
        let acm: [(Int64, Float)]
        let temp: [(Int64, Float)]
    }

    /// Load already-cached sleep stage arrays keyed by `NightRow.stagingKey`.
    static func cachedStages(nights: [NightRow]) -> [String: [Int]] {
        let globalKey = ModelCacheStore.globalKey(profile: nil, timezone: false)
        let cache: [String: StagedNightEntry] = ModelCacheStore.load(ModelCacheStore.stagingFile,
                                                                     globalKey: globalKey)
        var out: [String: [Int]] = [:]
        for night in nights where night.start_ds != nil {
            let key = night.stagingKey
            if let entry = cache[key], !entry.stages.isEmpty {
                out[key] = entry.stages
            }
        }
        return out
    }

    // Returns date-key → stage codes, plus a non-nil `error` only for genuine failures
    // (bundled model missing). An empty map with `error == nil` just means no sleep data.
    static func run(nights: [NightRow], events: EventStore.Events, clock: EventStore.RingClock,
                    force: Bool = false, pruneCache: Bool = true,
                    progress: @escaping @Sendable (String) -> Void = { _ in }) -> (staged: [String: [Int]], error: String?) {
        guard let modelPath = Bundle.main.path(forResource: "sleepnet_moonstone_1_2_0", ofType: "ptl")
        else { return ([:], "sleep model file missing from the app bundle") }
        guard !events.isEmpty else { return ([:], nil) }

        // The shared Rust summary canonicalizes brief wake splits and premature
        // bedtime ends. Consume those exact windows so the model cannot reintroduce
        // the raw ring boundary that the UI already corrected.
        // `nights` arrive newest-first from the summary; keep that order so the
        // night the user is looking at stages first.
        let beds = nights.compactMap { night -> (night: NightRow, start: Int64, end: Int64, cu: Int64, key: String)? in
            guard let start = night.start_ds, let end = night.end_ds else { return nil }
            let captured = night.captured_unix ?? events.restricted("tag IN (118,78)").first { event in
                (event.tag == 0x76 && (event.json["bedtime_start_ds"] as? NSNumber)?.int64Value == start)
                    || (event.tag == 0x4e && (event.json["bedtime_start"] as? NSNumber)?.int64Value == start)
            }?.cu
            return (night, start, end, captured ?? events.last?.cu ?? 0, night.stagingKey)
        }

        // A night's fingerprint covers its exact model inputs; a hit is by
        // construction the hypnogram the model would have produced.
        func fingerprint(_ inputs: NightInputs) -> String {
            var h = FNV64()
            h.combine(inputs.startDs); h.combine(inputs.endDs)
            h.combine(inputs.startMs); h.combine(inputs.endMs)  // RingClock re-dating backstop
            h.combine(inputs.beats.count)
            for b in inputs.beats { h.combine(b.0); h.combine(b.1); h.combine(b.2); h.combine(b.3) }
            h.combine(inputs.acm.count)
            for a in inputs.acm { h.combine(a.0); h.combine(a.1) }
            h.combine(inputs.temp.count)
            for t in inputs.temp { h.combine(t.0); h.combine(t.1) }
            return h.hex
        }
        let globalKey = ModelCacheStore.globalKey(profile: nil, timezone: false)
        var cache: [String: StagedNightEntry] = ModelCacheStore.load(ModelCacheStore.stagingFile,
                                                                     globalKey: globalKey)

        // Key by bedtime start and absolute epoch, since ds resets after a reboot.
        var result: [String: [Int]] = [:]
        var currentKeys = Set<String>()
        var recomputed = 0
        // Count only the nights that actually need the model, so the progress pill
        // reads "night 1 of 1" on a normal launch instead of the whole history.
        var pending: [(night: NightRow, key: String, fp: String, inputs: NightInputs?)] = []
        for bed in beds {
            guard !AnalysisRun.cancelled, events.error == nil else { return ([:], "analysis interrupted") }
            let inputs = nightInputs(start: bed.start, end: bed.end, cu: bed.cu,
                                     events: events, clock: clock)
            guard events.error == nil else { return ([:], "event read failed") }
            let key = bed.key
            if let inputs {
                let fp = fingerprint(inputs)
                currentKeys.insert(key)
                if !force, let entry = cache[key], entry.fp == fp {
                    if !entry.stages.isEmpty { result[key] = entry.stages }
                } else {
                    pending.append((bed.night, key, fp, inputs))
                }
            } else if bed.night.hasSignals {
                let fp = "signals:\(bed.start):\(bed.end):\(bed.cu)"
                currentKeys.insert(key)
                if !force, let entry = cache[key], entry.fp == fp, !entry.stages.isEmpty {
                    result[key] = entry.stages
                } else {
                    pending.append((bed.night, key, fp, nil))
                }
            }
        }
        var inferenceFailures = 0
        for (index, item) in pending.enumerated() {
            let key = item.key, fp = item.fp
            progress(pending.count > 1 ? "Analyzing sleep \(index + 1)/\(pending.count)" : "Analyzing sleep")
            guard !AnalysisRun.cancelled else { return ([:], "analysis paused") }
            let stages: [Int]? = {
                if let inputs = item.inputs, let s = stageNight(inputs, modelPath: modelPath), !s.isEmpty {
                    return s
                }
                return Sleep.estimateStages(night: item.night)
            }()
            guard let stages, !stages.isEmpty else {
                inferenceFailures += 1
                continue
            }
            result[key] = stages
            cache[key] = StagedNightEntry(fp: fp, stages: stages)
            ModelCacheStore.save(ModelCacheStore.stagingFile, globalKey: globalKey, entries: cache)
            recomputed += 1
        }
        guard events.error == nil, !AnalysisRun.cancelled else { return ([:], "analysis interrupted") }
        dlog("models", "sleep recomputed=\(recomputed) total=\(currentKeys.count) failures=\(inferenceFailures)")
        let pruned = cache.filter { currentKeys.contains($0.key) }
        if pruneCache && pruned.count != cache.count {
            ModelCacheStore.save(ModelCacheStore.stagingFile, globalKey: globalKey, entries: pruned)
        }
        if result.isEmpty && inferenceFailures > 0 && !pending.isEmpty {
            return (result, "sleep inference failed")
        }
        return (result, nil)
    }

    /// Gather one night's raw model inputs; nil when there's no usable beat data.
    static func nightInputs(start startDs: Int64, end endDs: Int64, cu bedCu: Int64,
                            events: EventStore.Events, clock: EventStore.RingClock) -> NightInputs? {
        // ms(ds) → absolute epoch ms, epoch-aware (ds resets on ring reboot; see EventStore)
        func ms(_ ds: Int64, _ cu: Int64) -> Int64 {
            Int64(clock.unixSeconds(ds, capturedUnix: cu) * 1000)
        }
        let startMs = ms(startDs, bedCu), endMs = ms(endDs, bedCu)
        let lo = startDs - 6000, hi = endDs + 6000
        var beats60: [(Int64, Float, Float, Float)] = []
        var beats80: [(Int64, Float, Float, Float)] = []
        var hrvRows: [(Int64, [String: Any])] = []
        var acm: [(Int64, Float)] = [], temp46: [(Int64, Float)] = [], temp75: [(Int64, Float)] = []
        for e in events.restricted("ring_timestamp BETWEEN \(lo) AND \(hi) AND tag IN (96,128,93,71,70,117)") {
            let timestamp = ms(e.ds, e.cu)
            guard timestamp >= startMs - 600000, timestamp <= endMs + 600000,
                  abs(timestamp - (startMs + (e.ds - startDs) * 100)) <= 300000 else { continue }
            switch e.tag {
            case 0x60:
                guard let ibi = e.json["ibi_ms"] as? [NSNumber] else { continue }
                let amp = (e.json["amplitude"] as? [NSNumber]) ?? []
                let t = timestamp; var acc: Int64 = 0
                for (i, xn) in ibi.enumerated() {
                    let x = xn.int64Value
                    if x <= 0 { continue }
                    acc += x
                    let ampVal: Float = i < amp.count ? amp[i].floatValue : 0
                    let tailNoise = ibi.count >= 4 && i >= ibi.count - 2 && x < 600 && ampVal <= 0
                    let valid: Float = (x >= 300 && x <= 2000 && !tailNoise) ? 1 : 0
                    beats60.append((t + acc, Float(x), ampVal, valid))
                }
            case 0x80:
                guard let ibi = e.json["ibi_ms"] as? [NSNumber] else { continue }
                let amp = (e.json["amplitude"] as? [NSNumber]) ?? []
                let quality = (e.json["quality"] as? [NSNumber]) ?? []
                let t = timestamp; var acc: Int64 = 0
                for (i, xn) in ibi.enumerated() {
                    let x = xn.int64Value
                    if x <= 0 { continue }
                    acc += x
                    let valid: Float = (x >= 300 && x <= 2000 && i < quality.count && quality[i].intValue == 1) ? 1 : 0
                    let ampVal: Float = i < amp.count ? amp[i].floatValue : 0
                    beats80.append((t + acc, Float(x), ampVal, valid))
                }
            case 0x5d:
                hrvRows.append((timestamp, e.json))
            case 0x47:
                if let mo = (e.json["motion_seconds"] as? NSNumber)?.floatValue { acm.append((timestamp, mo)) }
            case 0x75:
                if let temps = e.json["temps_c"] as? [NSNumber] {
                    let vals = temps.map(\.floatValue).filter { $0 > 0 }
                    if !vals.isEmpty {
                        temp75.append((timestamp, vals.reduce(0, +) / Float(vals.count)))
                    }
                }
            case 0x46:
                if let temps = e.json["temps_c"] as? [NSNumber], let c = temps.first?.floatValue { temp46.append((timestamp, c)) }
            default: break
            }
        }
        var beats: [(Int64, Float, Float, Float)] = []
        if !beats60.isEmpty && !beats80.isEmpty {
            beats60.sort { $0.0 < $1.0 }
            let ts60 = beats60.map(\.0)
            let posAmps = beats60.map(\.2).filter { $0 > 0 }.sorted()
            let medAmp: Float = posAmps.isEmpty ? 1200.0 : posAmps[posAmps.count / 2]
            beats = beats60
            for b in beats80 {
                var loIdx = 0, hiIdx = ts60.count
                while loIdx < hiIdx {
                    let mid = (loIdx + hiIdx) / 2
                    if ts60[mid] < b.0 { loIdx = mid + 1 } else { hiIdx = mid }
                }
                var near = false
                if loIdx < ts60.count && abs(ts60[loIdx] - b.0) <= 15_000 { near = true }
                if loIdx > 0 && abs(ts60[loIdx - 1] - b.0) <= 15_000 { near = true }
                if !near {
                    beats.append((b.0, b.1, b.2 > 0 ? b.2 : medAmp, b.3))
                }
            }
        } else if !beats60.isEmpty {
            beats = beats60
        } else {
            beats = beats80.map { ($0.0, $0.1, $0.2 > 0 ? $0.2 : 1200.0, $0.3) }
        }
        if !beats.contains(where: { $0.3 == 1 }), !hrvRows.isEmpty {
            var synth: [(Int64, Float, Float, Float)] = []
            for (ts0, json) in hrvRows.sorted(by: { $0.0 < $1.0 }) {
                let stepMs = max(1, (json["interval_min"] as? NSNumber)?.int64Value ?? 5) * 60_000
                let hrs = (json["hr_bpm"] as? [NSNumber]) ?? []
                let rmssds = (json["rmssd_ms"] as? [NSNumber]) ?? []
                for (i, hrNum) in hrs.enumerated() {
                    let hr = hrNum.floatValue
                    guard hr > 0 else { continue }
                    let meanIbi = min(max(60_000.0 / hr, 350.0), 1800.0)
                    let rmssd = i < rmssds.count ? rmssds[i].floatValue : 30.0
                    let jitter = min(max(rmssd * 0.5, 4.0), 60.0)
                    let slotStart = ts0 + Int64(i) * stepMs
                    var tCur = Float(slotStart)
                    var k = 0
                    while Int64(tCur) < slotStart + stepMs {
                        let sign: Float = (k % 2 == 0) ? 1.0 : -1.0
                        let ibi = min(max((meanIbi + sign * jitter * 0.5).rounded(), 330.0), 1950.0)
                        tCur += ibi
                        synth.append((Int64(tCur), ibi, 1200.0, 1.0))
                        k += 1
                    }
                }
            }
            beats = synth
        }
        var temp = temp75.isEmpty ? temp46 : temp75
        beats.sort { $0.0 < $1.0 }; acm.sort { $0.0 < $1.0 }; temp.sort { $0.0 < $1.0 }
        guard !beats.isEmpty, beats.contains(where: { $0.3 == 1 }) else { return nil }
        return NightInputs(startDs: startDs, endDs: endDs,
                           startMs: startMs, endMs: endMs,
                           beats: beats, acm: acm, temp: temp)
    }

    /// One SleepNet inference over one night's inputs.
    private static func stageNight(_ inputs: NightInputs, modelPath: String) -> [Int]? {
        var ibiTs = inputs.beats.map { $0.0 }
        var ibiVal = inputs.beats.flatMap { [$0.1, $0.2, $0.3] }
        var acmTs = inputs.acm.map { $0.0 }, acmVal = inputs.acm.map { $0.1 }
        var tempTs = inputs.temp.map { $0.0 }, tempVal = inputs.temp.map { $0.1 }
        var out = [Int32](repeating: 0, count: 8192)
        var timestamps = [Int64](repeating: 0, count: 8192)
        let n = oura_sleepnet(modelPath,
                              &ibiTs, &ibiVal, Int32(inputs.beats.count),
                              &acmTs, &acmVal, Int32(inputs.acm.count),
                              &tempTs, &tempVal, Int32(inputs.temp.count),
                              inputs.startMs, inputs.endMs, &out, &timestamps, 8192)
        guard n > 0 else { return nil }
        return Sleep.alignedStages(timestamps: Array(timestamps.prefix(Int(n))),
                                   stages: out.prefix(Int(n)).map(Int.init),
                                   startMs: inputs.startMs, endMs: inputs.endMs)
    }
}
#endif

