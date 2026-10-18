import Foundation

/// Sleep staging on the phone. Both stagers run open_oura's Rust feature pipeline in process and
/// produce per-30s stage arrays:
/// - `official`: the vendor classifier (extracted by tools/extract_nssa_classifier.py) in place of
///   the community-trained trees. Needs `sleepstaging_2_6_0_classifier.bin` in the bundle.
/// - `xgb`: the compiled-in community-trained tree ensemble. Always available.
/// The shared brain (oura-summary `sleep_stager`) resolves which one runs from the profile choice
/// and the registered classifier; each stager keeps its own cache file so switching never mixes
/// results.
enum SleepStaging {
    enum Kind {
        static let official = "official"
        static let xgb = "xgb"
    }
    static let officialModelId = "official-forest-r1"
    static let xgbModelId = "stager-2.6.0-rust"

    struct Staged { let stages: [Int]; let source: String; let t0Unix: Double? }

    /// The stager in use: "official" or "xgb".
    static var stager: String {
        _ = ModelFiles.officialSleepStager   // registers the bundled files with the brain
        return effectiveSleepStager(dbPath: DB.readPath())
    }

    /// `StagedNightEntry.source` of a night the active stager staged.
    static var source: String { stager == Kind.official ? "nssa" : "xgb" }

    /// Load already-cached sleep stage arrays keyed by `NightRow.stagingKey`.
    static func cachedStages(nights: [NightRow]) -> [String: [Int]] {
        cachedEntries(nights: nights).mapValues(\.stages)
    }

    static func cachedEntries(nights: [NightRow]) -> [String: StagedNightEntry] {
        let globalKey = ModelCacheStore.globalKey(profile: nil, timezone: false)
        let cache: [String: StagedNightEntry] = ModelCacheStore.load(ModelCacheStore.stagingFile(for: stager),
                                                                     globalKey: globalKey)
        var out: [String: StagedNightEntry] = [:]
        for night in nights where night.start_ds != nil {
            if let entry = cache[night.stagingKey], !entry.stages.isEmpty { out[night.stagingKey] = entry }
        }
        return out
    }

    /// Stages `nights` with the stager the brain resolved. Returns date-key to stage codes, plus a
    /// non-nil `error` only for a failure.
    static func run(nights: [NightRow], events: EventStore.Events, clock: EventStore.RingClock,
                    profile: Profile? = nil, force: Bool = false, pruneCache: Bool = true,
                    progress: @escaping @Sendable (String) -> Void = { _ in }) -> (staged: [String: [Int]], error: String?) {
        return runRust(stager: stager, nights: nights, events: events, clock: clock, profile: profile,
                       force: force, pruneCache: pruneCache, progress: progress)
    }

    private static func runRust(stager: String, nights: [NightRow], events: EventStore.Events, clock: EventStore.RingClock,
                                profile: Profile?, force: Bool, pruneCache: Bool,
                               progress: @escaping @Sendable (String) -> Void) -> (staged: [String: [Int]], error: String?) {
        guard !events.isEmpty else { return ([:], nil) }
        let beds = nights.compactMap { night -> (night: NightRow, start: Int64, end: Int64, cu: Int64, key: String)? in
            guard let start = night.start_ds, let end = night.end_ds else { return nil }
            let captured = night.captured_unix ?? events.restricted("tag IN (118,78)").first { event in
                (event.tag == 0x76 && (event.json["bedtime_start_ds"] as? NSNumber)?.int64Value == start)
                    || (event.tag == 0x4e && (event.json["bedtime_start"] as? NSNumber)?.int64Value == start)
            }?.cu
            return (night, start, end, captured ?? events.last?.cu ?? 0, night.stagingKey)
        }
        guard !beds.isEmpty else { return ([:], nil) }
        progress("Reading sleep signals")
        let records = stagerInputsBatch(
            dbPath: DB.readPath(),
            windows: beds.map { StagerWindow(startDs: $0.start, endDs: $0.end, capturedUnix: $0.cu) },
            // placeholder defaults, replaced by the profile
            age: profile?.age ?? 30, heightM: profile?.height_m ?? 1.78,
            weightKg: profile?.weight_kg ?? 75, sex: profile?.sex ?? "M")
        guard records.count == beds.count else { return ([:], "sleep inputs could not be read") }

        func fingerprint(_ r: StagerInputsRecord) -> String {
            var h = FNV64()
            h.combine(stager == Kind.official ? officialModelId : xgbModelId)
            h.combine(r.startMs); h.combine(r.endMs)
            h.combine(r.beatTs); h.combine(r.beats)
            h.combine(r.acmTs); h.combine(r.acm)
            h.combine(r.tempTs); h.combine(r.temp)
            h.combine(r.scalars)
            return h.hex
        }
        let file = ModelCacheStore.stagingFile(for: stager)
        let globalKey = ModelCacheStore.globalKey(profile: nil, timezone: false)
        var cache: [String: StagedNightEntry] = ModelCacheStore.load(file, globalKey: globalKey)
        var result: [String: [Int]] = [:]
        var currentKeys = Set<String>()
        var pending: [(night: NightRow, key: String, fp: String, record: StagerInputsRecord?)] = []
        for (bed, record) in zip(beds, records) {
            guard !AnalysisRun.cancelled else { return ([:], "analysis paused") }
            currentKeys.insert(bed.key)
            if record.error == nil {
                let fp = fingerprint(record)
                if !force, let entry = cache[bed.key], entry.fp == fp, !entry.stages.isEmpty {
                    result[bed.key] = entry.stages
                } else {
                    pending.append((bed.night, bed.key, fp, record))
                }
            } else if bed.night.hasSignals {
                let fp = "signals:\(bed.start):\(bed.end):\(bed.cu)"
                if !force, let entry = cache[bed.key], entry.fp == fp, !entry.stages.isEmpty {
                    result[bed.key] = entry.stages
                } else {
                    pending.append((bed.night, bed.key, fp, nil))
                }
                dlog("models", "stager skipped night=\(bed.key): \(record.error ?? "")")
            }
        }
        var failures = 0, recomputed = 0
        for (index, item) in pending.enumerated() {
            progress(pending.count > 1 ? "Analyzing sleep \(index + 1)/\(pending.count)" : "Analyzing sleep")
            guard !AnalysisRun.cancelled else { return ([:], "analysis paused") }
            var source = stager == Kind.official ? "nssa" : "xgb"
            var t0: Double? = nil
            let stages: [Int]? = {
                if let record = item.record, let s = stageWithStager(record, stager: stager) {
                    t0 = s.t0Unix
                    return s.stages
                }
                source = "signals"
                return Sleep.estimateStages(night: item.night)
            }()
            guard let stages, !stages.isEmpty else { failures += 1; continue }
            result[item.key] = stages
            cache[item.key] = StagedNightEntry(fp: item.fp, stages: stages, source: source, t0Unix: t0)
            ModelCacheStore.save(file, globalKey: globalKey, entries: cache)
            recomputed += 1
        }
        guard events.error == nil, !AnalysisRun.cancelled else { return ([:], "analysis interrupted") }
        dlog("models", "sleep(stager) recomputed=\(recomputed) total=\(currentKeys.count) failures=\(failures)")
        let pruned = cache.filter { currentKeys.contains($0.key) }
        if pruneCache && pruned.count != cache.count {
            ModelCacheStore.save(file, globalKey: globalKey, entries: pruned)
        }
        if result.isEmpty && failures > 0 && !pending.isEmpty { return (result, "sleep inference failed") }
        return (result, nil)
    }

    /// One stager inference. Epoch k of the output starts at floor_30s(bedtime
    /// start) + 30 s k, so the stage array needs no re-alignment. `t0Unix` is reported for the
    /// official stager only, as before.
    private static func stageWithStager(_ r: StagerInputsRecord, stager: String) -> (stages: [Int], t0Unix: Double?)? {
        let out: [Int]
        var t0: Double? = nil
        if stager == Kind.official {
            let staged = stageNightOfficial(record: r)
            out = staged.stages.map(Int.init)
            t0 = staged.t0Unix
        } else {
            out = stageNightRust(record: r).map(Int.init)
        }
        guard !out.isEmpty, out.allSatisfy({ (1...4).contains($0) }) else {
            dlog("models", "stager \(stager) failed: rust port returned \(out.count) epochs")
            return nil
        }
        return (out, t0)
    }

}
