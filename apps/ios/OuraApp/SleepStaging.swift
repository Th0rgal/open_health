import Foundation

// Pure NSSA input builders — line-by-line twins of tools/nssa_inputs.py and the grid
// mapping of tools/run_sleep_model.py. Not TORCH-gated so the unit tests run them
// against Tests/NssaParityFixture.json in every build.
enum NssaInputs {
    static let tagBedtime = 0x76, tagAcm = 0x72, tagIbi = 0x60, tagTemp = 0x75
    static let tempSampleMs: Int64 = 30_000
    static let epochMs: Int64 = 30_000

    /// `parse_api_sleep_acm_period`: finger angles (tmean, max, iqr) = int + frac/255,
    /// MAD (tmean, max, iqr) = 12-bit/4095 + high nibble, all Float. Returned in the
    /// model's order [madIqr, madMax, madTmean, faIqr, faMax, faMean].
    static func decodeAcmPeriod(_ body: [UInt8]?) -> [Float]? {
        guard let b = body, b.count == 12 else { return nil }
        var angle: [Float] = []
        for i in 0..<3 { angle.append(Float(b[2 * i]) / Float(255.0) + Float(b[2 * i + 1])) }
        var mad: [Float] = []
        for i in 0..<3 {
            let lo = Int(b[6 + 2 * i]), hi = Int(b[7 + 2 * i])
            mad.append(Float(lo | ((hi & 0x0F) << 8)) / Float(4095.0) + Float(hi >> 4))
        }
        return [mad[2], mad[1], mad[0], angle[2], angle[1], angle[0]]
    }

    /// `parse_api_sleep_temp_event`: LE centi-degrees, sample i of n at event-(n-1-i)*30 s.
    static func expandTempEvent(_ body: [UInt8]?, _ eventMs: Int64) -> [(Int64, Float)] {
        guard let b = body, b.count >= 2, b.count <= 15, b.count % 2 == 0 else { return [] }
        let n = b.count / 2
        return (0..<n).map { i in
            let raw = Int(b[2 * i]) | (Int(b[2 * i + 1]) << 8)
            return (eventMs - Int64(n - 1 - i) * tempSampleMs, Float(raw) / Float(100.0))
        }
    }

    /// `parse_api_ibi_and_amplitude_event`: beat k starts at event - ibi[k...5],
    /// clamped to the previous stamp. Returns (beats, newLast).
    static func expandIbiEvent(_ ibis: [Int], _ amps: [Int], _ eventMs: Int64, _ last0: Int64)
        -> ([(Int64, Int, Int)], Int64) {
        var last = last0
        var beats: [(Int64, Int, Int)] = []
        var stamp = eventMs - Int64(ibis.reduce(0, +))
        for (i, ibi) in ibis.enumerated() {
            let clamped = stamp > last ? stamp : last
            beats.append((clamped, ibi, i < amps.count ? amps[i] : 0))
            last = clamped
            stamp += Int64(ibi)
        }
        return (beats, last)
    }

    /// indexOfFirstAndLastOrNull + subListInclusive over item timestamps.
    static func inclusiveWindow<T>(_ items: [T], _ start: Int64, _ end: Int64, ts: (T) -> Int64) -> [T] {
        guard let first = items.firstIndex(where: { start <= ts($0) && ts($0) <= end }),
              let last = items.lastIndex(where: { start <= ts($0) && ts($0) <= end }) else { return [] }
        return Array(items[first...last])
    }

    struct Row { let ds: Int64; let tag: Int; let json: [String: Any]; let cu: Int64; let body: [UInt8]? }

    struct Inputs {
        var bedtime: (Int64, Int64)
        var acm: [(Int64, [Float])]
        var ibi: [(Int64, Int, Int, Int)]
        var temp: [(Int64, Float)]
    }

    /// Stable sort by timestamp (Python's sort is stable).
    private static func stableSorted<T>(_ a: [T], _ key: (T) -> Int64) -> [T] {
        a.enumerated().sorted { (key($0.element), $0.offset) < (key($1.element), $1.offset) }.map(\.element)
    }

    /// Twin of nssa_inputs.collect_nssa_inputs.
    static func collect(rows: [Row], startDs: Int64, endDs: Int64, capturedUnix: Int64,
                        unixMs: (Int64, Int64) -> Int64,
                        correct: ([(Int64, Int, Int)]) -> [(Int64, Int, Int, Int)] = IbiCorrection.correct) -> Inputs {
        let startMs = unixMs(startDs, capturedUnix), endMs = unixMs(endDs, capturedUnix)
        var acmEvents: [(Int64, [Float])] = [], tempEvents: [(Int64, [UInt8]?)] = []
        var ibiEvents: [(Int64, [Int], [Int])] = []
        for r in rows where r.tag == tagAcm || r.tag == tagIbi || r.tag == tagTemp {
            guard startDs - 6000 <= r.ds, r.ds <= endDs + 6000 else { continue }
            let eventMs = unixMs(r.ds, r.cu)
            if abs(eventMs - (startMs + (r.ds - startDs) * 100)) > 300_000 { continue }
            guard startMs <= eventMs, eventMs <= endMs else { continue }
            if r.tag == tagAcm {
                if let s = decodeAcmPeriod(r.body) { acmEvents.append((eventMs, s)) }
            } else if r.tag == tagTemp {
                tempEvents.append((eventMs, r.body))
            } else {
                let ibis = (r.json["ibi_ms"] as? [NSNumber])?.map(\.intValue) ?? []
                if ibis.count == 6 {
                    ibiEvents.append((eventMs, ibis, (r.json["amplitude"] as? [NSNumber])?.map(\.intValue) ?? []))
                }
            }
        }
        acmEvents = stableSorted(acmEvents) { $0.0 }
        tempEvents = stableSorted(tempEvents) { $0.0 }
        ibiEvents = stableSorted(ibiEvents) { $0.0 }
        let acm = inclusiveWindow(acmEvents, startMs, endMs) { $0.0 }
        var temp: [(Int64, Float)] = []
        for (t, b) in tempEvents { temp += expandTempEvent(b, t) }
        temp = inclusiveWindow(temp, startMs, endMs) { $0.0 }
        var beats: [(Int64, Int, Int)] = [], last: Int64 = 0
        for (t, ibis, amps) in ibiEvents {
            let (ex, l) = expandIbiEvent(ibis, amps, t, last)
            beats += ex; last = l
        }
        beats = inclusiveWindow(beats, startMs, endMs) { $0.0 }
        return Inputs(bedtime: (startMs, endMs), acm: acm, ibi: beats.isEmpty ? [] : correct(beats), temp: temp)
    }

    /// Twin of run_sleep_model.grid_stages: midpoint rule on the night's 30 s grid,
    /// cells outside every ring bedtime = 4, cells of a failed bedtime = 0.
    static func gridStages(periods: [(ts: [Int64], codes: [Int])], failed: [(Int64, Int64)],
                           startMs: Int64, endMs: Int64) -> [Int] {
        let n = max(1, Int((endMs - startMs + epochMs - 1) / epochMs))
        var out = Array(repeating: 4, count: n)
        for (bs, be) in failed {
            for idx in 0..<n {
                let mid = startMs + Int64(idx) * epochMs + epochMs / 2
                if bs <= mid && mid < be { out[idx] = 0 }
            }
        }
        for p in periods {
            for (t, code) in zip(p.ts, p.codes) {
                let num = t - startMs - epochMs / 2
                // ceil division matching Python's -(-a // b) for negative a too
                let q = num >= 0 ? (num + epochMs - 1) / epochMs : -((-num) / epochMs)
                let idx = Int(q)
                if idx >= 0 && idx < n && (1...4).contains(code) { out[idx] = code }
            }
        }
        return out
    }

    /// NssaPyTorchModel demographics [age, bmi, sex] (nssa_stager.demographics).
    static func demographics(age: Double, heightM: Double, weightKg: Double, sex: String) -> [Float] {
        let bmi = weightKg / (heightM * heightM)
        let s: Float = sex.uppercased().hasPrefix("F") ? -1 : (sex.uppercased().hasPrefix("M") ? 1 : 0)
        return [Float(Int(age)), Float(bmi), s]
    }
}

#if TORCH
// sqlite3 comes from the bridging header (TorchBridge.h includes <sqlite3.h>)

// On-device sleep staging with Oura's NSSA model (sleepstaging_2_6_0), exactly as
// the official app stages each ring bedtime — a twin of tools/run_sleep_model.py.
enum SleepStaging {
    static let modelId = "nssa-2.6.0-r1"

    struct Staged { let stages: [Int]; let source: String; let t0Unix: Double? }

    /// Load already-cached sleep stage arrays keyed by `NightRow.stagingKey`.
    static func cachedStages(nights: [NightRow], profile: Profile?,
                             cacheFile: String = ModelCacheStore.stagingFile) -> [String: [Int]] {
        cachedEntries(nights: nights, profile: profile, cacheFile: cacheFile).mapValues(\.stages)
    }

    /// The cheap cache path must use the same demographics as `run`. Otherwise a
    /// profile edit can keep old nights without reaching their input fingerprint
    /// check. Ring size and display timezone are not NSSA inputs.
    static func cacheKey(profile: Profile?) -> String {
        var fp = FNV64()
        for byte in modelId.utf8 { fp.combine(Int(byte)) }
        for scalar in demographics(profile) { fp.combine(scalar) }
        return ModelCacheStore.globalKey(profile: nil, timezone: false) + "|" + fp.hex
    }

    static func windowKey(_ night: NightRow) -> String {
        "\(night.stagingKey)|\(night.end_ds.map(String.init) ?? "nil")"
            + "|\(night.end_unix.map(String.init) ?? "nil")|\(night.durationS.bitPattern)"
    }

    static func cachedEntries(nights: [NightRow], profile: Profile?,
                              cacheFile: String = ModelCacheStore.stagingFile) -> [String: StagedNightEntry] {
        let globalKey = cacheKey(profile: profile)
        let cache: [String: StagedNightEntry] = ModelCacheStore.load(cacheFile,
                                                                     globalKey: globalKey)
        var out: [String: StagedNightEntry] = [:]
        for night in nights where night.start_ds != nil {
            if let entry = cache[night.stagingKey], entry.windowKey == windowKey(night),
               !entry.stages.isEmpty { out[night.stagingKey] = entry }
        }
        return out
    }

    /// Same defaults as oura-summary Demographics / run_sleep_model.read_profile.
    static func demographics(_ p: Profile?) -> [Float] {
        NssaInputs.demographics(age: p?.age ?? 30, heightM: p?.height_m ?? 1.78,
                                weightKg: p?.weight_kg ?? 75, sex: p?.sex ?? "M")
    }

    static func run(nights: [NightRow], events: EventStore.Events, clock: EventStore.RingClock,
                    profile: Profile? = nil, force: Bool = false, pruneCache: Bool = true,
                    progress: @escaping @Sendable (String) -> Void = { _ in }) -> (staged: [String: [Int]], error: String?) {
        guard let modelPath = Bundle.main.path(forResource: "sleepstaging_2_6_0", ofType: "ptl"),
              let classifierPath = Bundle.main.path(forResource: "sleepstaging_2_6_0_classifier", ofType: "bin")
        else { return ([:], "sleep model file missing from the app bundle") }
        guard !events.isEmpty else { return ([:], nil) }
        oura_nssa_set_classifier_path(classifierPath)
        let demo = demographics(profile)

        func ms(_ ds: Int64, _ cu: Int64) -> Int64 {
            Int64((clock.unixSeconds(ds, capturedUnix: cu) * 1000).rounded(.toNearestOrEven))
        }
        // One read of the rows NSSA needs (bedtimes + its three streams).
        var rows: [NssaInputs.Row] = []
        var bedtimes: [NssaInputs.Row] = []
        for e in events.restricted("tag IN (96,114,117,118)") {
            let r = NssaInputs.Row(ds: e.ds, tag: e.tag, json: e.json, cu: e.cu, body: e.body.map { [UInt8]($0) })
            if e.tag == NssaInputs.tagBedtime { bedtimes.append(r) } else { rows.append(r) }
        }
        guard events.error == nil else { return ([:], "event read failed") }

        /// run_sleep_model.ring_bedtimes: latest 0x76 per start in the same boot.
        func ringBedtimes(_ startDs: Int64, _ endDs: Int64, _ captured: Int64) -> [(Int64, Int64, Int64)] {
            var latest: [Int64: (Int64, Int64, Int64)] = [:]
            for r in bedtimes {
                guard let s = (r.json["bedtime_start_ds"] as? NSNumber)?.int64Value,
                      let e = (r.json["bedtime_end_ds"] as? NSNumber)?.int64Value, e > s else { continue }
                if abs(ms(s, r.cu) - ms(s, captured)) > 300_000 { continue }
                if s < endDs && e > startDs { latest[s] = (s, e, r.cu) }
            }
            return latest.values.sorted { $0.0 < $1.0 }
        }

        let globalKey = cacheKey(profile: profile)
        var cache: [String: StagedNightEntry] = ModelCacheStore.load(ModelCacheStore.stagingFile, globalKey: globalKey)
        var result: [String: [Int]] = [:]
        var currentKeys = Set<String>()
        var failures = 0
        for (index, night) in nights.enumerated() {
            guard let startDs = night.start_ds, let endDs = night.end_ds else { continue }
            guard !AnalysisRun.cancelled, events.error == nil else { return ([:], "analysis interrupted") }
            progress(nights.count > 1 ? "Analyzing sleep \(index + 1)/\(nights.count)" : "Analyzing sleep")
            let cu = night.captured_unix ?? events.last?.cu ?? 0
            let key = night.stagingKey
            currentKeys.insert(key)
            if clock.datedUnixSeconds(startDs, capturedUnix: cu) == nil
                || clock.datedUnixSeconds(endDs, capturedUnix: cu) == nil { continue }
            var beds = ringBedtimes(startDs, endDs, cu)
            if beds.isEmpty { beds = [(startDs, endDs, cu)] }
            var periods: [(ts: [Int64], codes: [Int])] = [], failed: [(Int64, Int64)] = []
            var fp = FNV64()
            for b in modelId.utf8 { fp.combine(Int(b)) }; for d in demo { fp.combine(d) }
            fp.combine(startDs); fp.combine(endDs)
            var inputsList: [NssaInputs.Inputs] = []
            for (bs, be, _) in beds {
                let inp = NssaInputs.collect(rows: rows, startDs: bs, endDs: be, capturedUnix: cu, unixMs: ms)
                fp.combine(inp.bedtime.0); fp.combine(inp.bedtime.1)
                fp.combine(inp.acm.count); for a in inp.acm { fp.combine(a.0); for v in a.1 { fp.combine(v) } }
                fp.combine(inp.ibi.count); for b in inp.ibi { fp.combine(b.0); fp.combine(b.1); fp.combine(b.2); fp.combine(b.3) }
                fp.combine(inp.temp.count); for t in inp.temp { fp.combine(t.0); fp.combine(t.1) }
                inputsList.append(inp)
            }
            let fpHex = fp.hex
            if !force, let entry = cache[key], entry.fp == fpHex,
               entry.windowKey == windowKey(night), !entry.stages.isEmpty {
                result[key] = entry.stages
                continue
            }
            for inp in inputsList {
                if let staged = stage(inp, demo: demo, modelPath: modelPath) { periods.append(staged) }
                else { failed.append(inp.bedtime) }
            }
            var stages: [Int]? = nil, source = "nssa", t0: Double? = nil
            if !periods.isEmpty {
                stages = NssaInputs.gridStages(periods: periods, failed: failed,
                                               startMs: ms(startDs, cu), endMs: ms(endDs, cu))
                var main = periods[0]
                for p in periods.dropFirst() where p.codes.count > main.codes.count { main = p }
                t0 = main.ts.first.map { Double($0) / 1000 }
            } else if night.hasSignals, let est = Sleep.estimateStages(night: night) {
                stages = est; source = "signals"
            }
            guard let stages, !stages.isEmpty else { failures += 1; continue }
            result[key] = stages
            cache[key] = StagedNightEntry(fp: fpHex, stages: stages, windowKey: windowKey(night),
                                           source: source, t0Unix: t0)
            ModelCacheStore.save(ModelCacheStore.stagingFile, globalKey: globalKey, entries: cache)
        }
        guard events.error == nil, !AnalysisRun.cancelled else { return ([:], "analysis interrupted") }
        if pruneCache {
            let pruned = cache.filter { currentKeys.contains($0.key) }
            if pruned.count != cache.count { ModelCacheStore.save(ModelCacheStore.stagingFile, globalKey: globalKey, entries: pruned) }
        }
        if result.isEmpty && failures > 0 { return (result, "sleep inference failed") }
        return (result, nil)
    }

    /// One NSSA forward over one ring bedtime; nil when the model's validator would
    /// reject it (the official app then has no hypnogram either).
    private static func stage(_ inp: NssaInputs.Inputs, demo: [Float], modelPath: String) -> (ts: [Int64], codes: [Int])? {
        guard !inp.acm.isEmpty, !inp.ibi.isEmpty, !inp.temp.isEmpty else { return nil }
        var acmTs = inp.acm.map(\.0), acmVal = inp.acm.flatMap(\.1)
        var ibiTs = inp.ibi.map(\.0), ibiVal = inp.ibi.flatMap { [Float($0.1), Float($0.2), Float($0.3)] }
        var tempTs = inp.temp.map(\.0), tempVal = inp.temp.map(\.1)
        var demoV = demo
        let cap = 8192
        var out = [Int32](repeating: 0, count: cap)
        var ts = [Int64](repeating: 0, count: cap)
        let n = oura_nssa(modelPath, &acmTs, &acmVal, Int32(inp.acm.count),
                          &ibiTs, &ibiVal, Int32(inp.ibi.count),
                          &tempTs, &tempVal, Int32(inp.temp.count),
                          &demoV, inp.bedtime.0, inp.bedtime.1, &out, &ts, Int32(cap))
        guard n > 0 else { return nil }
        return (Array(ts.prefix(Int(n))), out.prefix(Int(n)).map(Int.init))
    }
}
#endif
