import Foundation

enum DayAnalysisKind: String, CaseIterable {
    case sleep = "Sleep", activity = "Activity"
}

struct DayAnalysisRequest: Equatable {
    let day: String
    let kind: DayAnalysisKind
}

/// Last successfully rendered summary. It is display-only: the SQLite store remains
/// the source of truth and a fresh summary always replaces this after launch. Keeping
/// it out of UserDefaults avoids loading a potentially large signal payload there.
enum SummaryCache {
    private static let queue = DispatchQueue(label: "md.thomas.openoura.summary-cache", qos: .utility)
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("summary-cache.json")
    }

    private struct CachedSummary: Codable {
        var summary: Summary
        var workouts: [WorkoutSession]
        var illness: IllnessResult?
    }
    static func load() -> Summary? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let cached = try? JSONDecoder().decode(CachedSummary.self, from: data), cached.summary.error == nil {
            var result = cached.summary
            result.workouts = cached.workouts; result.illness = cached.illness
            return result
        }
        guard let legacy = try? JSONDecoder().decode(Summary.self, from: data), legacy.error == nil else { return nil }
        return legacy
    }

    static func save(_ summary: Summary) {
        guard summary.error == nil else { return }
        queue.async {
            guard let data = try? JSONEncoder().encode(CachedSummary(summary: summary, workouts: summary.workouts, illness: summary.illness)) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    static func clear() {
        queue.sync { try? FileManager.default.removeItem(at: url) }
    }
}

enum Core {
    /// Fast, model-free summary (vitals, activity ridges, device) straight from the
    /// shared-core JSON — safe to compute on a background queue and show immediately.
    static func base() -> Summary {
        let path = DB.readPath()   // synced DB if present, else the bundled seed
        // the phone's actual UTC offset, so night labels / sleep windows / digest
        // timing match the wearer's local clock — not a hardcoded constant. The whole
        // stack (web --tz-offset, the Python model runners, this FFI) takes whole
        // hours, so round to the nearest hour (best representable value for the rare
        // sub-hour zones like IST +5:30).
        let secs = TimeZone.current.secondsFromGMT()
        let tzOffset = Int64((Double(secs) / 3600).rounded())
        let json = summaryJson(dbPath: path, tzOffset: tzOffset)
        guard let data = json.data(using: .utf8) else { return Summary(error: "decode failed") }
        do { return try JSONDecoder().decode(Summary.self, from: data) }
        catch {
            dlog("core", "summary decode failed: \(error) json=\(json.prefix(300))")
            return Summary(error: "decode failed")
        }
    }

    #if TORCH
    /// Launch and sync only fill the latest night's missing analysis. Historical
    /// results stay visible, and older missing nights are refreshed on demand.
    static func automaticSleepPlan(nights: [NightRow], previous: Summary?) -> (saved: [String: [Int]], pending: [NightRow]) {
        var saved: [String: [Int]] = [:]
        for night in nights {
            guard let start = night.start_ds else { continue }
            if let old = previous?.nights.first(where: {
                $0.start_ds == start && $0.end_ds == night.end_ds
                    && $0.ymd == night.ymd && $0.start == night.start && $0.end == night.end
            }), let stages = old.stages, !stages.isEmpty {
                saved[String(start)] = stages
            }
        }
        // Pick the night you woke from most recently (absolute end time, falling
        // back to wake date, then list order). Do not backfill an older missing
        // night when the newest one already has a result.
        let latest = nights.enumerated().max { lhs, rhs in
            let l = lhs.element, r = rhs.element
            if let le = l.end_unix, let re = r.end_unix, le != re { return le < re }
            let lw = l.wake_ymd ?? l.ymd ?? "", rw = r.wake_ymd ?? r.ymd ?? ""
            if lw != rw { return lw < rw }
            return lhs.offset > rhs.offset
        }?.element
        guard let latest, let start = latest.start_ds,
              latest.end_ds != nil, saved[String(start)] == nil else { return (saved, []) }
        return (saved, [latest])
    }

    /// Refresh one report without running unrelated models or discarding other days.
    static func refreshAnalysis(_ previous: Summary, request: DayAnalysisRequest,
                                progress: @escaping @Sendable (String) -> Void = { _ in }) -> (summary: Summary, error: String?) {
        let base = Core.base()
        guard base.error == nil else { return (previous, "Couldn’t read saved data. Try again.") }
        do {
            let events = try EventStore.decodedEvents(dbPath: DB.readPath())
            let clock = EventStore.RingClock(events: events)
            try events.validate()
            try AnalysisRun.check()
            var updated = previous
            switch request.kind {
            case .sleep:
                guard let night = base.night(forDay: request.day), let start = night.start_ds else {
                    return (previous, "No sleep data is saved for this day.")
                }
                let result = SleepStaging.run(nights: [night], events: events, clock: clock,
                                             force: true, pruneCache: false, progress: progress)
                if let error = result.error { throw AnalysisRefreshFailure(error) }
                guard let stages = result.staged[String(start)], !stages.isEmpty else {
                    return (previous, "Not enough saved sleep data to refresh this night.")
                }
                let previousStart = previous.night(forDay: request.day)?.start_ds
                if let index = updated.nights.firstIndex(where: {
                    $0.start_ds == start || (previousStart != nil && $0.start_ds == previousStart)
                }) {
                    updated.nights[index] = night
                } else { updated.nights.append(night) }
                applySleepStages(result.staged, to: &updated)
            case .activity:
                guard base.activity_profile[request.day] != nil else {
                    return (previous, "No activity data is saved for this day.")
                }
                let result = ActivityModel.run(profile: base.profile, events: events, clock: clock,
                                               onlyDay: request.day, force: true, progress: progress)
                if let error = result.error { throw AnalysisRefreshFailure(error) }
                updated.workouts.removeAll { $0.dayLabel == request.day }
                updated.workouts.append(contentsOf: result.sessions)
                updated.workouts.sort { $0.start < $1.start }
                // The aggregate message names only the first failed day; a successful
                // rerun of that day means the list is stale either way.
                updated.modelErrors.removeAll { $0.hasPrefix("Activity analysis failed for") }
            }
            try events.validate()
            try AnalysisRun.check()
            return (updated, nil)
        } catch {
            if AnalysisRun.cancelled { return (previous, "Refresh paused. Keep the app open and try again.") }
            dlog("models", "refresh day=\(request.day) kind=\(request.kind.rawValue) failed: \(error)")
            return (previous, "Couldn’t refresh \(request.kind.rawValue.lowercased()) analysis. Your previous results are still available. See Help & diagnostics for details.")
        }
    }

    private struct AnalysisRefreshFailure: Error, CustomStringConvertible {
        let description: String
        init(_ message: String) { description = message }
    }

    /// The slow part: run the three on-device torch models and fold their results into
    /// the summary. Call off the main thread (see RootView.load); never on launch.
    ///
    /// Models share one LibTorch runtime, so they run one after another (TorchBridge
    /// also serializes `forward()`). Concurrent inference raced the interpreter and
    /// peaked RAM on hiking-heavy histories. Each reports a per-model error for
    /// genuine failures; those surface in `modelErrors`.
    static func withModels(_ base: Summary, previous: Summary?,
                           progress: @escaping @Sendable (String) -> Void = { _ in }) -> Summary {
        var s = base
        let profile = base.profile

        let sleepPlan = automaticSleepPlan(nights: base.nights, previous: previous)
        var staged = sleepPlan.saved
        var cva: CvaModel.Result?
        var workouts: [WorkoutSession] = []
        var illness: IllnessResult?
        var sleepErr: String?, cvaErr: String?, actErr: String?, illErr: String?

        // One shared read: one failure point, one lock-contention window, and the
        // RingClock epoch recovery is paid once instead of once per model.
        progress("Reading ring data")
        var events = EventStore.Events(path: DB.readPath())
        var readErr: String?
        do {
            events = try EventStore.decodedEvents(dbPath: DB.readPath())
        } catch {
            readErr = "\(error)"
        }
        memLog("streaming events")
        var stageStarted = ProcessInfo.processInfo.systemUptime
        func stageFinished(_ stage: String) {
            dlog("models", "stage=\(stage) duration=\(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - stageStarted))s")
            stageStarted = ProcessInfo.processInfo.systemUptime
            memLog(stage)
        }

        if readErr == nil, !events.isEmpty {
            let clock = EventStore.RingClock(events: events)
            if events.error != nil || AnalysisRun.cancelled { return previous ?? base }
            let rSleep = sleepPlan.pending.isEmpty
                ? (staged: [String: [Int]](), error: Optional<String>.none)
                : SleepStaging.run(nights: sleepPlan.pending, events: events, clock: clock,
                                   pruneCache: false, progress: progress)
            staged.merge(rSleep.staged) { _, fresh in fresh }
            sleepErr = rSleep.error
            dlog("models", "sleep automatic saved=\(sleepPlan.saved.count) pending=\(sleepPlan.pending.count)")
            stageFinished("sleep")
            if AnalysisRun.cancelled { return previous ?? base }
            let rAct = ActivityModel.run(profile: profile, events: events, clock: clock, progress: progress)
            workouts = rAct.sessions; actErr = rAct.error
            stageFinished("activity")
            if AnalysisRun.cancelled { return previous ?? base }
            let rIll = IllnessModel.run(profile: profile, events: events, clock: clock)
            illness = rIll.result; illErr = rIll.error
            stageFinished("illness")
        } else if let readErr {
            // The shared read failed: every event-fed model is unavailable this
            // pass. Surface one error; the publish below falls back to `previous`.
            sleepErr = readErr; actErr = readErr; illErr = readErr
        }
        if AnalysisRun.cancelled { return previous ?? base }
        let rCva = CvaModel.run(sex: profile?.sex ?? "M", age: profile?.age ?? 30,
                                heightM: profile?.height_m ?? 1.78, weightKg: profile?.weight_kg ?? 75,
                                ringSize: profile?.ring_size ?? 10)
        cva = rCva.result; cvaErr = rCva.error
        stageFinished("cva")

        // If staging failed outright, refill from the last published summary so a
        // transient read failure can't strip hypnograms that were already on screen.
        if sleepErr != nil, let previous {
            for night in previous.nights {
                if let sds = night.start_ds, staged[String(sds)] == nil, let stages = night.stages, !stages.isEmpty {
                    staged[String(sds)] = stages
                }
            }
        }
        // fold SleepNet's hypnogram + stage breakdown into each night, keyed by the exact
        // bedtime start_ds so two sleeps on one calendar day don't collide.
        applySleepStages(staged, to: &s)
        if let cva {
            s.cardio = Cardio(vascular_age: cva.vascularAge, chronological_age: profile?.age ?? 30,
                              pwv_ms: cva.pwv, segments: cva.segments)
        } else if cvaErr != nil {
            s.cardio = previous?.cardio
        }
        // Per-day failures leave every other day's sessions valid; only a pass that
        // produced nothing (interrupted, model missing) falls back to the last result.
        s.workouts = (actErr == nil || !workouts.isEmpty) ? workouts : (previous?.workouts ?? workouts)
        s.illness = (illErr == nil || illness != nil) ? illness : previous?.illness
        var seen = Set<String>()
        s.modelErrors = [sleepErr, cvaErr, actErr, illErr].compactMap { $0 }
            .filter { seen.insert($0).inserted }
        for error in s.modelErrors { dlog("models", "failed: \(error)") }
        return s
    }

    private static func applySleepStages(_ staged: [String: [Int]], to s: inout Summary) {
        for i in s.nights.indices {
            guard let sds = s.nights[i].start_ds, let stages = staged[String(sds)], !stages.isEmpty else { continue }
            s.nights[i].stages = stages
            let total = Double(stages.count)
            let pct = { (code: Int) in (Double(stages.filter { $0 == code }.count) / total * 100).rounded() }
            s.nights[i].deep_pct = pct(1); s.nights[i].light_pct = pct(2)
            s.nights[i].rem_pct = pct(3); s.nights[i].wake_pct = pct(4)
            let asleep = total - Double(stages.filter { $0 == 4 }.count)
            s.nights[i].efficiency = (asleep / total * 100).rounded()
        }
        // Staging can be partial while model inputs are still arriving. Never replace
        // a more complete model-free debt window with a transient "0 of 5" result;
        // prefer staged sleep only when it covers at least as many distinct days.
        if let stagedDebt = s.stagedSleepDebt(),
           stagedDebt.valid_days >= (s.sleepDebt?.valid_days ?? 0) {
            s.sleepDebt = stagedDebt
        }
    }
    #endif
}
