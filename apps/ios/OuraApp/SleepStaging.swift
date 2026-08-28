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

    // Returns date-key → stage codes, plus a non-nil `error` only for genuine failures
    // (bundled model missing). An empty map with `error == nil` just means no sleep data.
    static func run(nights: [NightRow], events: [EventStore.Ev], clock: EventStore.RingClock,
                    progress: @escaping @Sendable (String) -> Void = { _ in }) -> (staged: [String: [Int]], error: String?) {
        guard let modelPath = Bundle.main.path(forResource: "sleepnet_moonstone_1_2_0", ofType: "ptl")
        else { return ([:], "sleep model file missing from the app bundle") }
        guard !events.isEmpty else { return ([:], nil) }

        // The shared Rust summary canonicalizes brief wake splits and premature
        // bedtime ends. Consume those exact windows so the model cannot reintroduce
        // the raw ring boundary that the UI already corrected.
        // `nights` arrive newest-first from the summary; keep that order so the
        // night the user is looking at stages first.
        let beds = nights.compactMap { night -> (start: Int64, end: Int64, cu: Int64)? in
            guard let start = night.start_ds, let end = night.end_ds else { return nil }
            let captured = events.first { event in
                event.tag == 0x76
                    && (event.json["bedtime_start_ds"] as? NSNumber)?.int64Value == start
            }?.cu
            return (start, end, captured ?? events.last?.cu ?? 0)
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
        let globalKey = ModelCacheStore.globalKey(profile: nil)
        var cache: [String: StagedNightEntry] = ModelCacheStore.load(ModelCacheStore.stagingFile,
                                                                     globalKey: globalKey)

        // key by the exact bedtime start_ds (matches the summary's night.start_ds)
        // so two sleeps on one calendar day stay distinct.
        var result: [String: [Int]] = [:]
        var dirty: [(key: String, inputs: NightInputs, fp: String)] = []
        var currentKeys = Set<String>()
        for bed in beds {
            guard let inputs = nightInputs(start: bed.start, end: bed.end, cu: bed.cu,
                                           events: events, clock: clock) else { continue }
            let key = String(bed.start)
            let fp = fingerprint(inputs)
            currentKeys.insert(key)
            if let entry = cache[key], entry.fp == fp {
                if !entry.stages.isEmpty { result[key] = entry.stages }
            } else {
                dirty.append((key, inputs, fp))
            }
        }
        dlog("models", "staging: \(dirty.count)/\(currentKeys.count) nights to recompute")
        for (index, night) in dirty.enumerated() {
            progress("staging sleep · night \(index + 1)/\(dirty.count)")
            // Empty stages are cached too: a night the model can't stage shouldn't
            // be retried on every reload until its inputs change.
            let stages = stageNight(night.inputs, modelPath: modelPath) ?? []
            if !stages.isEmpty { result[night.key] = stages }
            cache[night.key] = StagedNightEntry(fp: night.fp, stages: stages)
            ModelCacheStore.save(ModelCacheStore.stagingFile, globalKey: globalKey, entries: cache)
        }
        let pruned = cache.filter { currentKeys.contains($0.key) }
        if pruned.count != cache.count {
            ModelCacheStore.save(ModelCacheStore.stagingFile, globalKey: globalKey, entries: pruned)
        }
        return (result, nil)
    }

    /// Gather one night's raw model inputs; nil when there's no usable beat data.
    static func nightInputs(start startDs: Int64, end endDs: Int64, cu bedCu: Int64,
                            events: [EventStore.Ev], clock: EventStore.RingClock) -> NightInputs? {
        // ms(ds) → absolute epoch ms, epoch-aware (ds resets on ring reboot; see EventStore)
        func ms(_ ds: Int64, _ cu: Int64) -> Int64 {
            Int64(clock.unixSeconds(ds, capturedUnix: cu) * 1000)
        }
        let lo = startDs - 6000, hi = endDs + 6000
        var beats: [(Int64, Float, Float, Float)] = []
        var acm: [(Int64, Float)] = [], temp: [(Int64, Float)] = []
        for e in events where e.ds >= lo && e.ds <= hi {
            switch e.tag {
            case 0x60, 0x80:
                guard let ibi = e.json["ibi_ms"] as? [NSNumber] else { continue }
                let amp = (e.json["amplitude"] as? [NSNumber]) ?? []
                let t = ms(e.ds, e.cu); var acc: Int64 = 0
                for (i, xn) in ibi.enumerated() {
                    let x = xn.int64Value
                    if x <= 0 { continue }
                    acc += x
                    let valid: Float = (x >= 300 && x <= 2000) ? 1 : 0
                    beats.append((t + acc, Float(x), i < amp.count ? amp[i].floatValue : 0, valid))
                }
            case 0x47:
                if let mo = (e.json["motion_seconds"] as? NSNumber)?.floatValue { acm.append((ms(e.ds, e.cu), mo)) }
            case 0x46:
                if let temps = e.json["temps_c"] as? [NSNumber], let c = temps.first?.floatValue { temp.append((ms(e.ds, e.cu), c)) }
            default: break
            }
        }
        beats.sort { $0.0 < $1.0 }; acm.sort { $0.0 < $1.0 }; temp.sort { $0.0 < $1.0 }
        guard !beats.isEmpty, beats.contains(where: { $0.3 == 1 }) else { return nil }
        return NightInputs(startDs: startDs, endDs: endDs,
                           startMs: ms(startDs, bedCu), endMs: ms(endDs, bedCu),
                           beats: beats, acm: acm, temp: temp)
    }

    /// One SleepNet inference over one night's inputs.
    private static func stageNight(_ inputs: NightInputs, modelPath: String) -> [Int]? {
        var ibiTs = inputs.beats.map { $0.0 }
        var ibiVal = inputs.beats.flatMap { [$0.1, $0.2, $0.3] }
        var acmTs = inputs.acm.map { $0.0 }, acmVal = inputs.acm.map { $0.1 }
        var tempTs = inputs.temp.map { $0.0 }, tempVal = inputs.temp.map { $0.1 }
        var out = [Int32](repeating: 0, count: 8192)
        let n = oura_sleepnet(modelPath,
                              &ibiTs, &ibiVal, Int32(inputs.beats.count),
                              &acmTs, &acmVal, Int32(inputs.acm.count),
                              &tempTs, &tempVal, Int32(inputs.temp.count),
                              inputs.startMs, inputs.endMs, &out, 8192)
        guard n > 0 else { return nil }
        return out.prefix(Int(n)).map(Int.init)
    }
}
#endif
