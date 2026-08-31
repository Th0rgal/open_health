import Foundation

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

    static func load() -> Summary? {
        guard let data = try? Data(contentsOf: url),
              let summary = try? JSONDecoder().decode(Summary.self, from: data),
              summary.error == nil else { return nil }
        return summary
    }

    static func save(_ summary: Summary) {
        guard summary.error == nil else { return }
        queue.async {
            guard let data = try? JSONEncoder().encode(summary) else { return }
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
        guard let data = json.data(using: .utf8),
              let s = try? JSONDecoder().decode(Summary.self, from: data)
        else { return Summary(error: "decode failed") }
        return s
    }

    #if TORCH
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

        var staged: [String: [Int]] = [:]
        var cva: CvaModel.Result?
        var workouts: [WorkoutSession] = []
        var illness: IllnessResult?
        var sleepErr: String?, cvaErr: String?, actErr: String?, illErr: String?

        // One shared read: one failure point, one lock-contention window, and the
        // RingClock epoch recovery is paid once instead of once per model.
        progress("reading ring data…")
        var events: [EventStore.Ev] = []
        var readErr: String?
        do {
            events = try EventStore.decodedEvents(dbPath: DB.readPath())
        } catch {
            readErr = "\(error)"
        }
        memLog("read \(events.count) events")

        if readErr == nil, !events.isEmpty {
            let clock = EventStore.RingClock(events: events)
            let rSleep = SleepStaging.run(nights: base.nights, events: events, clock: clock, progress: progress)
            staged = rSleep.staged
            sleepErr = rSleep.error
            memLog("after sleep")
            let rAct = ActivityModel.run(profile: profile, events: events, clock: clock, progress: progress)
            workouts = rAct.sessions; actErr = rAct.error
            memLog("after activity")
            let rIll = IllnessModel.run(profile: profile, events: events, clock: clock)
            illness = rIll.result; illErr = rIll.error
            memLog("after illness")
        } else if let readErr {
            // The shared read failed: every event-fed model is unavailable this
            // pass. Surface one error; the publish below falls back to `previous`.
            sleepErr = readErr; actErr = readErr; illErr = readErr
        }
        let rCva = CvaModel.run(sex: profile?.sex ?? "M", age: profile?.age ?? 30,
                                heightM: profile?.height_m ?? 1.78, weightKg: profile?.weight_kg ?? 75,
                                ringSize: profile?.ring_size ?? 10)
        cva = rCva.result; cvaErr = rCva.error
        memLog("after cva")

        // If staging failed outright, refill from the last published summary so a
        // transient read failure can't strip hypnograms that were already on screen.
        if sleepErr != nil, staged.isEmpty, let previous {
            for night in previous.nights {
                if let sds = night.start_ds, let stages = night.stages, !stages.isEmpty {
                    staged[String(sds)] = stages
                }
            }
        }
        // fold SleepNet's hypnogram + stage breakdown into each night, keyed by the exact
        // bedtime start_ds so two sleeps on one calendar day don't collide.
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
        if let cva {
            s.cardio = Cardio(vascular_age: cva.vascularAge, chronological_age: profile?.age ?? 30,
                              pwv_ms: cva.pwv, segments: cva.segments)
        } else if cvaErr != nil {
            s.cardio = previous?.cardio
        }
        // Never let a failed run replace real results with emptiness (the same
        // principle as the staged-sleep-debt coverage guard above).
        s.workouts = (actErr == nil || !workouts.isEmpty) ? workouts : (previous?.workouts ?? [])
        s.illness = (illErr == nil || illness != nil) ? illness : previous?.illness
        // Deduplicated: a failed shared read sets the same message on three models.
        var seen = Set<String>()
        s.modelErrors = [sleepErr, cvaErr, actErr, illErr].compactMap { $0 }
            .filter { seen.insert($0).inserted }
        return s
    }
    #endif
}
