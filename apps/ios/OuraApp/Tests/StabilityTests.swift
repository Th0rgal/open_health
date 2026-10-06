import XCTest
import SQLite3
@testable import OuraApp

final class StabilityTests: XCTestCase {
    func testSummaryCachePreservesAnalysisIdentity() throws {
        var summary = Summary()
        summary.analysis_digest = "10:20:2:15"
        summary.analysis_version = 6
        let restored = try JSONDecoder().decode(Summary.self, from: JSONEncoder().encode(summary))
        XCTAssertEqual(restored.analysis_digest, summary.analysis_digest)
        XCTAssertEqual(restored.analysis_version, summary.analysis_version)
    }

    func testRebootedRingDoesNotReuseSleepCacheKey() {
        var first = NightRow(start_ds: 100)
        first.start_unix = 1000
        var second = first
        second.start_unix = 87400
        XCTAssertNotEqual(first.stagingKey, second.stagingKey)
    }

    func testSleepNetOutputKeepsItsOwnTimestamps() {
        XCTAssertEqual(Sleep.alignedStages(timestamps: [90000, 120000], stages: [2, 3], startMs: 0, endMs: 120000), [0, 0, 2, 3])
        XCTAssertEqual(Sleep.alignedStages(timestamps: [0, 30000, 60000], stages: [4, 1, 2], startMs: 0, endMs: 60000), [1, 2])
        // SleepNet's real grid (epoch END times): a full night covers every cell,
        // including a final partial epoch.
        XCTAssertEqual(Sleep.alignedStages(timestamps: [30000, 60000, 90000, 120000], stages: [1, 2, 3, 4],
                                           startMs: 0, endMs: 120000), [1, 2, 3, 4])
        XCTAssertEqual(Sleep.alignedStages(timestamps: [30000, 60000, 90000, 120000], stages: [1, 2, 3, 4],
                                           startMs: 0, endMs: 100000), [1, 2, 3, 4])
        XCTAssertNil(Sleep.alignedStages(timestamps: [30000, 0], stages: [1, 2], startMs: 0, endMs: 60000))
        XCTAssertNil(Sleep.alignedStages(timestamps: [0], stages: [8], startMs: 0, endMs: 60000))
    }

    func testUnknownStagesStayUnknownAndDoNotProduceSleepMetrics() {
        let stages = Array(repeating: 0, count: 480) + Array(repeating: 2, count: 480)
        let smoothed = Sleep.smooth(stages, 5)
        XCTAssertEqual(Array(smoothed.prefix(480)), Array(repeating: 0, count: 480))
        XCTAssertNil(Sleep.metrics(smoothed, inBedS: 8 * 3600))
        XCTAssertEqual(Sleep.asleepS(smoothed, inBedS: 8 * 3600), 0)
        XCTAssertEqual(Sleep.metrics(Array(repeating: 4, count: 120) + Array(repeating: 2, count: 840),
                                    inBedS: 8 * 3600)?.solMin, 60)
    }

    func testPartialMainSleepDoesNotTurnCompleteNapIntoDailySleepDebt() {
        var partial = NightRow(ymd: "2026-09-26", start: "00:07", end: "08:55", in_bed_h: 8.8)
        partial.wake_ymd = "2026-09-26"; partial.stages_full = [0, 0, 2, 3]
        var nap = NightRow(ymd: "2026-09-26", start: "14:00", end: "15:00", in_bed_h: 1)
        nap.wake_ymd = "2026-09-26"; nap.stages_full = [2, 2, 2, 2]
        XCTAssertNil(Summary(nights: [partial, nap]).stagedSleepDebt())
    }

    func testNightUsesFullStagesAndExactDurationInsteadOfRoundedPreview() throws {
        let data = Data(#"{"stages":[4,2],"stages_full":[4,1,2,3],"start_unix":100,"end_unix":220,"in_bed_h":0.1}"#.utf8)
        let night = try JSONDecoder().decode(NightRow.self, from: data)
        XCTAssertEqual(night.hypnogram, [4, 1, 2, 3])
        XCTAssertEqual(night.durationS, 120)
    }

    func testAnalysisDeadlineCancelsCooperativeWork() {
        let run = AnalysisRun(timeout: -1)
        run.perform {
            do { try AnalysisRun.check(); XCTFail("expired run accepted") } catch {}
        }
    }

    func testOperationFailureSummaryKeepsCauseBeforeStackTrace() {
        let cause = "2026-09-09 error [models] activity day=2026-07-06 failed: select index out of range"
        let trace = (0..<24).map { "frame #\($0): libtorch_cpu" }.joined(separator: "\n")
        let preview = DiagStore.incidentPreview("[diag] omitted 2 queued records\n" + cause + "\n" + trace,
                                                kind: "operation-failure")
        XCTAssertTrue(preview.hasPrefix(cause))
        XCTAssertFalse(preview.contains("frame #23"))
        XCTAssertEqual(DiagStore.incidentPreview("", kind: "operation-failure"), "")
    }

    func testLeftoverSessionIsNotACrash() {
        XCTAssertEqual(DiagStore.classify("[models] complete"), "interrupted-session-cause-unknown")
        XCTAssertEqual(DiagStore.classify("[lifecycle] state=background"), "backgrounded-session")
        XCTAssertEqual(DiagStore.classify("[lifecycle] state=background\n[lifecycle] state=active"), "interrupted-session-cause-unknown")
        XCTAssertEqual(DiagStore.classify("[lifecycle] state=background\n*** CRASH ***\nsignal=11"), "confirmed-crash")
    }

    func testRotationIsBoundedAndDetailedExportIncludesNewestRecord() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiagStore(directory: directory, segmentLimit: 2048, totalLimit: 8192)
        for i in 0..<100 {
            store.append("record=\(i) " + String(repeating: "x", count: 512))
            store.flush()
        }
        let text = store.exportAll()
        XCTAssertTrue(text.contains("record=99"))
        XCTAssertFalse(text.contains("record=0 "))
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey])!
        var bytes = 0
        for case let url as URL in enumerator { bytes += (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 }
        XCTAssertLessThanOrEqual(bytes, 10240) // total limit plus the currently filling segment
    }

    func testCancelledGenerationStaysCancelledAcrossWorkerHop() {
        let run = AnalysisRun()
        run.cancel()
        run.perform { XCTAssertTrue(AnalysisRun.cancelled); do { try AnalysisRun.check(); XCTFail("cancelled run accepted") } catch {} }
        XCTAssertNil(AnalysisRun.current)
    }

    func testWorkGateSerializesOwners() async {
        let gate = WorkGate()
        actor Counter {
            var active = 0
            var peak = 0
            func enter() { active += 1; peak = max(peak, active) }
            func leave() { active -= 1 }
        }
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await gate.acquire()
                    await counter.enter()
                    await Task.yield()
                    await counter.leave()
                    await gate.release()
                }
            }
        }
        let peak = await counter.peak
        XCTAssertEqual(peak, 1)
    }

    func testRawDataChartThinsLongSeriesButKeepsExtremes() {
        let values: [Double] = (0..<10_000).map { Double($0 % 100) } + [500, -500]
        let event = RawData.Event(name: "x", tag: 1, ringTimestamp: 0, capturedUnix: 0, unix: 1_000,
                                  bodyLen: 0, decoded: ["v": values])
        let points = RawData.points([event], field: "v")
        XCTAssertLessThanOrEqual(points.count, 2_000)
        XCTAssertEqual(points.map(\.v).max(), 500)
        XCTAssertEqual(points.map(\.v).min(), -500)
        XCTAssertEqual(points.map(\.t), points.map(\.t).sorted())
        XCTAssertEqual(RawData.points([event], field: "v", maxPoints: 20_000).count, values.count)
    }

    #if TORCH
    func testAutomaticSleepOnlyFillsLatestMissingNight() {
        let latest = NightRow(ymd: "2026-09-09", start_ds: 200, end_ds: 300, start: "23:00", end: "07:00")
        let older = NightRow(ymd: "2026-09-08", start_ds: 100, end_ds: 190, start: "23:00", end: "07:00")
        var savedLatest = latest
        savedLatest.stages = [1, 2, 3, 4]
        savedLatest.staging_source = "sleepnet"
        var savedOlder = older
        savedOlder.stages = [2, 3, 2, 1]
        savedOlder.staging_source = "sleepnet"
        let nights = [latest, older]

        let firstLaunch = Core.automaticSleepPlan(nights: nights, previous: nil)
        XCTAssertEqual(firstLaunch.pending.map(\.start_ds), [200])
        let missingLatest = Core.automaticSleepPlan(nights: nights, previous: Summary(nights: [savedOlder]))
        XCTAssertEqual(missingLatest.pending.map(\.start_ds), [200])
        XCTAssertEqual(missingLatest.saved[older.stagingKey], savedOlder.stages)
        let missingOlder = Core.automaticSleepPlan(nights: nights, previous: Summary(nights: [savedLatest]))
        XCTAssertTrue(missingOlder.pending.isEmpty)
        let reopen = Core.automaticSleepPlan(nights: nights, previous: Summary(nights: [savedLatest, savedOlder]))
        XCTAssertTrue(reopen.pending.isEmpty)
        let newInputs = Core.automaticSleepPlan(nights: nights, previous: Summary(nights: [savedLatest, savedOlder]), revalidateLatest: true)
        XCTAssertEqual(newInputs.pending.map(\.start_ds), [200])
        XCTAssertEqual(reopen.saved.count, 2)

        var changed = latest
        changed.end_ds = 310
        XCTAssertEqual(Core.automaticSleepPlan(nights: [changed, older], previous: Summary(nights: [savedLatest])).pending.count, 1)
        XCTAssertTrue(Core.automaticSleepPlan(nights: [], previous: nil).pending.isEmpty)
    }

    func testAutomaticSleepPicksTheNightWokenFromMostRecently() {
        // List order is not trusted: a misdated older night could sort first.
        var real = NightRow(ymd: "2026-09-10", start_ds: 900, end_ds: 990, start: "23:00", end: "08:00")
        real.wake_ymd = "2026-09-11"; real.end_unix = 1_789_020_000
        var older = NightRow(ymd: "2026-09-09", start_ds: 500, end_ds: 590, start: "23:30", end: "07:30")
        older.wake_ymd = "2026-09-10"; older.end_unix = 1_788_933_600
        XCTAssertEqual(Core.automaticSleepPlan(nights: [older, real], previous: nil).pending.map(\.start_ds), [900])
        // Without absolute bounds (older cached summary) the wake date decides.
        real.end_unix = nil; older.end_unix = nil
        XCTAssertEqual(Core.automaticSleepPlan(nights: [older, real], previous: nil).pending.map(\.start_ds), [900])
    }

    func testWakeDateComesFromTheSharedBrainWhenPresent() {
        var night = NightRow(ymd: "2026-09-10", start_ds: 1, end_ds: 2, start: "07:11", end: "15:33")
        XCTAssertEqual(Summary().wakeYmd(night), "2026-09-10")   // legacy heuristic: no midnight crossing
        night.wake_ymd = "2026-09-11"
        XCTAssertEqual(Summary().wakeYmd(night), "2026-09-11")
    }

    func testHistoricalActivityRefreshBypassesCacheAndPreservesOtherDays() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = "test-activity-\(UUID().uuidString).json"
        let cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(file)
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let calendar = Calendar.current
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 7, day: 6))!
        let next = calendar.date(byAdding: .day, value: 1, to: midnight)!
        let unix = Int64(midnight.timeIntervalSince1970)
        let nextUnix = Int64(next.timeIntervalSince1970)
        let met = String(data: try JSONSerialization.data(withJSONObject: ["met": Array(repeating: 1.2, count: 720)]), encoding: .utf8)!
        let sql = """
        DELETE FROM events;
        INSERT INTO events VALUES (1,5000000,66,'{"unix_time":\(unix)}',\(unix),NULL);
        INSERT INTO events VALUES (2,5000000,80,'\(met)',\(unix),NULL);
        INSERT INTO events VALUES (3,\(5000000 + (nextUnix - unix) * 10),80,'\(met)',\(nextUnix),NULL);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let events = try EventStore.decodedEvents(dbPath: url.path)
        let clock = EventStore.RingClock(events: events)
        let key = ModelCacheStore.globalKey(profile: nil)
        let unrelated = ActivityDayEntry(fp: "preserve-this-day", sessions: [])
        ModelCacheStore.save(file, globalKey: key, entries: ["2026-07-07": unrelated])

        let first = ActivityModel.run(profile: nil, events: events, clock: clock,
                                      onlyDay: "2026-07-06", force: true, cacheFile: file)
        XCTAssertNil(first.error)
        var cache: [String: ActivityDayEntry] = ModelCacheStore.load(file, globalKey: key)
        XCTAssertEqual(cache["2026-07-07"]?.fp, unrelated.fp)
        var old = try XCTUnwrap(cache["2026-07-06"])
        old.sessions = [WorkoutSession(start: "2026-07-06 01:00", end: "01:10", durationMin: 10,
                                       label: "stale cached result", isWorkout: 1)]
        cache["2026-07-06"] = old
        ModelCacheStore.save(file, globalKey: key, entries: cache)
        let cached = ActivityModel.run(profile: nil, events: events, clock: clock,
                                       onlyDay: "2026-07-06", cacheFile: file)
        XCTAssertEqual(cached.sessions.first?.label, "stale cached result")
        let refreshed = ActivityModel.run(profile: nil, events: events, clock: clock,
                                          onlyDay: "2026-07-06", force: true, cacheFile: file)
        XCTAssertNil(refreshed.error)
        XCTAssertTrue(refreshed.sessions.isEmpty)
        cache = ModelCacheStore.load(file, globalKey: key)
        XCTAssertTrue(try XCTUnwrap(cache["2026-07-06"]).sessions.isEmpty)
        XCTAssertEqual(cache["2026-07-07"]?.fp, unrelated.fp)
        let missing = ActivityModel.run(profile: nil, events: events, clock: clock,
                                        onlyDay: "2026-07-05", force: true, cacheFile: file)
        XCTAssertNotNil(missing.error)
    }

    func testActivitySparseDayReturnsNoWorkouts() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "automatic_activity_detection_3_1_11", ofType: "ptl"))
        let nan = Float.nan
        var context: [Float] = [2026, 9, 8, 1]
        var user: [Float] = [30, 1, 1.78, 75] + Array(repeating: nan, count: 10)
        var step: [Float] = [0] + Array(repeating: nan, count: 11) + [719] + Array(repeating: nan, count: 11)
        var motion: [Float] = [0] + Array(repeating: nan, count: 8)
        var temp: [Float] = [0, nan]
        var hr: [Float] = [0, nan]
        for duplicate in [false, true] {
            var met: [Float] = []
            for minute in 0..<720 {
                met += [Float(minute), 1.2]
                if duplicate && minute < 60 { met += [Float(minute), 1.2] }
            }
            let rows = Int32(met.count / 2)
            var output = [Float](repeating: 0, count: 512 * 9)
            let result = oura_activity(path, &context, &user, &met, rows, &step, 2,
                                       &motion, 1, &temp, 1, &hr, 1, 0.5, 10, &output, 512)
            XCTAssertEqual(result, 0, "Sparse day should produce no workouts, not fail: \(String(cString: oura_activity_last_error()))")
        }
    }

    /// The three shapes seen in real ring history that used to abort the whole pass:
    /// a channel with no sample inside the MET span, a wear window that collapses to
    /// minute 0, and duplicate MET minutes. The first two run through the guards in
    /// ActivityModel; here the FFI itself is pinned on the placeholder position.
    func testActivityPlaceholderInsideMetWindowRuns() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "automatic_activity_detection_3_1_11", ofType: "ptl"))
        let nan = Float.nan
        var context: [Float] = [2026, 7, 6, 0]
        var user: [Float] = [30, 1, 1.78, 75] + Array(repeating: nan, count: 10)
        // MET from 10:00 for 60 minutes, motion and temperature present, no heart rate.
        var met: [Float] = [], motion: [Float] = [], temp: [Float] = []
        for minute in 600..<660 {
            let t = Float(minute)
            met += [t, 1.2]; motion += [t, 0, 30, 0, 0, 0, nan, 10, 1]; temp += [t, 33]
        }
        var step: [Float] = [600] + Array(repeating: nan, count: 11) + [659] + Array(repeating: nan, count: 11)
        var output = [Float](repeating: 0, count: 512 * 9)
        // Placeholder at minute 0 falls outside the valid window: the model throws.
        var hrAtZero: [Float] = [0, nan]
        let rejected = oura_activity(path, &context, &user, &met, 60, &step, 2, &motion, 60,
                                     &temp, 60, &hrAtZero, 1, 0.5, 10, &output, 512)
        XCTAssertLessThan(rejected, 0, "expected the empty-tensor failure this test documents")
        // Placeholder on the first MET minute keeps the channel present.
        var hrAtStart: [Float] = [600, nan]
        let accepted = oura_activity(path, &context, &user, &met, 60, &step, 2, &motion, 60,
                                     &temp, 60, &hrAtStart, 1, 0.5, 10, &output, 512)
        XCTAssertEqual(accepted, 0, String(cString: oura_activity_last_error()))
    }

    func testActivityDegenerateDayIsSkippedNotFatal() throws {
        let url = try fixture()
        let file = "test-activity-\(UUID().uuidString).json"
        let cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(file)
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let calendar = Calendar.current
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 7, day: 6))!
        let unix = Int64(midnight.timeIntervalSince1970)
        // Day 1 (07-06): 13 MET minutes at 17:22 and two motion samples → no wear window.
        // Day 2 (07-07): a normal 12-hour day. Both must be cached; neither may abort.
        let sparseMet = String(data: try JSONSerialization.data(withJSONObject: ["met": Array(repeating: 1.2, count: 13)]), encoding: .utf8)!
        let fullMet = String(data: try JSONSerialization.data(withJSONObject: ["met": Array(repeating: 1.2, count: 720)]), encoding: .utf8)!
        let motion = "{\"orientation\":0,\"motion_seconds\":5,\"avg_x\":0,\"avg_y\":0,\"avg_z\":0,\"low_intensity\":1,\"high_intensity\":0}"
        let day1 = unix + 17 * 3600 + 22 * 60
        let day2 = unix + 86400
        let sql = """
        DELETE FROM events;
        INSERT INTO events VALUES (1,5000000,66,'{"unix_time":\(unix)}',\(unix),NULL);
        INSERT INTO events VALUES (2,\(5000000 + (day1 - unix) * 10),80,'\(sparseMet)',\(day1),NULL);
        INSERT INTO events VALUES (3,\(5000000 + (day1 - unix) * 10),71,'\(motion)',\(day1),NULL);
        INSERT INTO events VALUES (4,\(5000000 + (day1 - unix) * 10 + 600),71,'\(motion)',\(day1 + 60),NULL);
        INSERT INTO events VALUES (5,\(5000000 + (day2 - unix) * 10),80,'\(fullMet)',\(day2),NULL);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let events = try EventStore.decodedEvents(dbPath: url.path)
        let clock = EventStore.RingClock(events: events)
        let result = ActivityModel.run(profile: nil, events: events, clock: clock, force: true, cacheFile: file)
        XCTAssertNil(result.error, result.error ?? "")
        let cache: [String: ActivityDayEntry] = ModelCacheStore.load(file, globalKey: ModelCacheStore.globalKey(profile: nil))
        XCTAssertNotNil(cache["2026-07-06"]); XCTAssertNotNil(cache["2026-07-07"])
        XCTAssertNil(cache["2026-07-06"]?.failed)
        XCTAssertEqual(ActivityModel.failureMessage(["2026-07-06", "2026-05-01"]),
                       "Activity analysis failed for 2026-07-06 (+1 more). See diagnostics for details.")
    }

    func testIllnessAndCvaCacheFilesSurviveNewInputs() throws {
        // The file key is the stable global key; the input fingerprint lives in the entry.
        let file = "test-fp-\(UUID().uuidString).json"
        let cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(file)
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let key = ModelCacheStore.globalKey(profile: nil)
        let first = FingerprintedEntry(fp: "day-1", value: CvaModel.Result(vascularAge: 30, pwv: 6, segments: 10))
        ModelCacheStore.save(file, globalKey: key, entries: ["result": first])
        let reloaded: [String: FingerprintedEntry<CvaModel.Result>] = ModelCacheStore.load(file, globalKey: key)
        XCTAssertEqual(reloaded["result"]?.fp, "day-1")
        XCTAssertNotEqual(reloaded["result"]?.fp, "day-2")   // a miss is a compare, not a discard
    }

    func testModelCacheRestoresAnEarlierGlobalKey() {
        // Travelling out of a timezone and back must not recompute the history twice.
        let file = "test-gen-\(UUID().uuidString).json"
        let cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(file)
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        func entry(_ fp: String) -> [String: FingerprintedEntry<CvaModel.Result>] {
            ["result": FingerprintedEntry(fp: fp, value: CvaModel.Result(vascularAge: 30, pwv: 6, segments: 10))]
        }
        ModelCacheStore.save(file, globalKey: "home", entries: entry("home"), digest: "home-digest",
                             keepGenerations: true)
        ModelCacheStore.save(file, globalKey: "away", entries: entry("away"), keepGenerations: true)
        var loaded: [String: FingerprintedEntry<CvaModel.Result>] = ModelCacheStore.load(file, globalKey: "home")
        XCTAssertEqual(loaded["result"]?.fp, "home")
        // The restored generation keeps its digest, so the fast path still applies.
        XCTAssertEqual(ModelCacheStore.loadDigest(file, globalKey: "home"), "home-digest")
        XCTAssertNil(ModelCacheStore.loadDigest(file, globalKey: "away"))
        loaded = ModelCacheStore.load(file, globalKey: "away")
        XCTAssertEqual(loaded["result"]?.fp, "away")
        // Only the most recent generations are kept.
        for key in ["a", "b", "c"] {
            ModelCacheStore.save(file, globalKey: key, entries: entry(key), keepGenerations: true)
        }
        loaded = ModelCacheStore.load(file, globalKey: "home")
        XCTAssertTrue(loaded.isEmpty)
        loaded = ModelCacheStore.load(file, globalKey: "a")
        XCTAssertEqual(loaded["result"]?.fp, "a")
        // Files saved without generations (timezone-free keys) keep only the current one.
        ModelCacheStore.save(file, globalKey: "d", entries: entry("d"))
        loaded = ModelCacheStore.load(file, globalKey: "c")
        XCTAssertTrue(loaded.isEmpty)
        XCTAssertNotEqual(ModelCacheStore.globalKey(profile: nil),
                          ModelCacheStore.globalKey(profile: nil, timezone: false))
    }

    /// Parity harness: with `OURA_DUMP_DAY=YYYY-MM-DD` and `OURA_DUMP_PATH` set, writes the
    /// bundled seed DB's exact model inputs for that day so tools/ can diff them against
    /// the Python runner. Skipped otherwise.
    func testDumpActivityInputsForParity() throws {
        // xcodebuild does not forward TEST_RUNNER_ variables to app-hosted tests, so the
        // request is a JSON file {"day": "...", "path": "..."} named by OURA_DUMP_REQUEST
        // or at /tmp/oura-dump-request.json (the simulator shares the host file system).
        let env = ProcessInfo.processInfo.environment
        let request = env["OURA_DUMP_REQUEST"] ?? "/tmp/oura-dump-request.json"
        guard let data = FileManager.default.contents(atPath: request),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let day = object["day"], let path = object["path"] else {
            throw XCTSkip("write \(request) with day and path to dump a day")
        }
        let events = try EventStore.decodedEvents(dbPath: DB.readPath())
        let clock = EventStore.RingClock(events: events)
        let inputs = try XCTUnwrap(ActivityModel.debugInputs(profile: nil, events: events, clock: clock, day: day))
        func sanitized(_ value: Any) -> Any {
            if let floats = value as? [Float] { return floats.map { $0.isNaN ? "nan" : Double($0) as Any } }
            if let rows = value as? [[Double]] { return rows.map { $0.map { $0.isNaN ? "nan" : $0 as Any } } }
            return value
        }
        let json = try JSONSerialization.data(withJSONObject: inputs.mapValues(sanitized), options: [.sortedKeys])
        try json.write(to: URL(fileURLWithPath: path))
    }

    /// Mirror of the Rust ring_time tests: a counter that ran faster than wall time
    /// between two anchors is undated; a counter that stalled picks the anchor side
    /// the download time allows.
    func testErraticCounterIsUndatedAndStalledCounterPicksAnchorSide() throws {
        let url = try fixture()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let sql = """
        DELETE FROM events;
        INSERT INTO events VALUES (1,20000,1,'{}',1783000000,NULL);
        INSERT INTO events VALUES (2,20928,66,'{"unix_time":1782939604}',1783000000,NULL);
        INSERT INTO events VALUES (3,500000,1,'{}',1783000000,NULL);
        INSERT INTO events VALUES (4,1032193,133,'{"unix_time":1782943316}',1783000000,NULL);
        INSERT INTO events VALUES (5,1100000,1,'{}',1783000000,NULL);
        INSERT INTO events VALUES (6,1133000,133,'{"unix_time":1782953397}',1783000000,NULL);
        INSERT INTO events VALUES (7,1200000,1,'{}',1783000000,NULL);
        INSERT INTO events VALUES (8,47893458,66,'{"unix_time":1787733180}',1787733240,NULL);
        INSERT INTO events VALUES (9,52000000,1,'{}',1788100000,NULL);
        INSERT INTO events VALUES (10,61076535,66,'{"unix_time":1789195380}',1789195440,NULL);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let events = try EventStore.decodedEvents(dbPath: url.path)
        let clock = EventStore.RingClock(events: events)
        XCTAssertEqual(clock.resolve(500_000, capturedUnix: 1_783_000_000).source, .undated)
        XCTAssertNil(clock.datedUnixSeconds(500_000, capturedUnix: 1_783_000_000))
        let pocket = clock.resolve(1_100_000, capturedUnix: 1_783_000_000)
        XCTAssertEqual(pocket.source, .anchor)
        XCTAssertEqual(pocket.unix, 1_782_953_397 - 3_300, accuracy: 0.01)
        XCTAssertEqual(clock.resolve(1_200_000, capturedUnix: 1_783_000_000).source, .anchor)
        // Stalled counter (40 h lost between the last two anchors of the same boot).
        let early = clock.resolve(52_000_000, capturedUnix: 1_788_100_000)
        XCTAssertEqual(early.source, .anchor)
        XCTAssertEqual(early.unix, 1_787_733_180 + Double(52_000_000 - 47_893_458) / 10, accuracy: 0.01)
        let late = clock.resolve(52_000_000, capturedUnix: 1_789_195_440)
        XCTAssertEqual(late.unix, 1_789_195_380 - Double(61_076_535 - 52_000_000) / 10, accuracy: 0.01)
    }

    func testActivityCompleteDayRunsInMobileRuntime() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "automatic_activity_detection_3_1_11", ofType: "ptl"))
        let nan = Float.nan
        var context: [Float] = [2026, 9, 8, 1]
        var user: [Float] = [30, 1, 1.78, 75] + Array(repeating: nan, count: 10)
        var step: [Float] = [0] + Array(repeating: nan, count: 11) + [719] + Array(repeating: nan, count: 11)
        var met: [Float] = [], motion: [Float] = [], temp: [Float] = [], hr: [Float] = []
        for minute in 0..<720 {
            let t = Float(minute)
            met += [t, (300..<360).contains(minute) ? 5 : 1.2]
            motion += [t, 0, 30, 0, 0, 0, nan, 10, 1]
            temp += [t, 33]
            hr += [t, 70]
        }
        var output = [Float](repeating: 0, count: 512 * 9)
        let result = oura_activity(path, &context, &user, &met, 720, &step, 2,
                                   &motion, 720, &temp, 720, &hr, 720, 0.5, 10, &output, 512)
        // Golden result from the unmodified full TorchScript model on these inputs.
        let expected: [Float] = [300, 360, 0.8837792, 14, 0.5082318, 6, 0.4652145, 21, 0.4478024]
        XCTAssertEqual(result, 1, String(cString: oura_activity_last_error()))
        for (actual, reference) in zip(output.prefix(9), expected) {
            XCTAssertEqual(actual, reference, accuracy: 0.0001)
        }
    }

    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE events(id INTEGER PRIMARY KEY, ring_timestamp INTEGER, tag INTEGER, decoded_json TEXT, captured_unix INTEGER, body BLOB);
        INSERT INTO events VALUES (1,5000000,66,'{"unix_time":1700000000}',1700000000,NULL);
        INSERT INTO events VALUES (2,5000010,96,'{"ibi_ms":[800,900]}',1700000001,NULL);
        INSERT INTO events VALUES (3,10,66,'{"unix_time":1700100000}',1700100000,NULL);
        INSERT INTO events VALUES (4,20,96,'{"ibi_ms":[700,800]}',1700100001,NULL);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        return url
    }
    func testIllnessWorkspacePreservesCaptureOrderAndInclusiveWindows() throws {
        let workspace = try IllnessModel.IBIWorkspace()
        defer { workspace.close() }
        try workspace.append(time: 11, value: 800)
        try workspace.append(time: 5, value: 900)
        try workspace.append(time: 11, value: 700)
        try workspace.append(time: 30, value: 600)
        try workspace.finish()
        let values = try workspace.values(start: 5, end: 11)
        XCTAssertEqual(values.times, [11,5,11])
        XCTAssertEqual(values.values, [800,900,700])
        XCTAssertTrue(try workspace.values(start: 12, end: 20).times.isEmpty)
    }

    func testCvaRetainsExactlyLast4000Segments() throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "BEGIN;", nil, nil, nil), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO events(ring_timestamp,tag,body) VALUES (?,129,?)", -1, &statement, nil), SQLITE_OK)
        let bytes = [UInt8](repeating: 1, count: 1500)
        for i in 0..<4002 {
            sqlite3_bind_int64(statement, 1, Int64(i * 10))
            _ = bytes.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, 1500, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_reset(statement)
        }
        sqlite3_finalize(statement)
        XCTAssertEqual(sqlite3_exec(db, "COMMIT;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let result = CvaModel.selectedSegments(dbPath: url.path)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.segments?.count, 4000 * 1500)
        XCTAssertEqual(result.segments?.first, 3001)
        XCTAssertEqual(result.segments?.last, Float(4002 * 1500))
    }

    func testRtcBeaconDatesSleepIndependentlyOfDownloadTime() throws {
        for previousBoot in [false, true] {
            let url = try fixture()
            defer { try? FileManager.default.removeItem(at: url) }
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
            let sql = """
            DELETE FROM events;
            \(previousBoot ? "INSERT INTO events VALUES (1,5000000,66,'{\"unix_time\":1788800000}',1788800000,NULL);" : "")
            INSERT INTO events VALUES (2,672400,1,'{}',1789056420,NULL);
            INSERT INTO events VALUES (3,1000000,133,'{"unix_time":1789020420}',1789056420,NULL);
            """
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
            sqlite3_close(db)
            let events = try EventStore.decodedEvents(dbPath: url.path)
            let clock = EventStore.RingClock(events: events)
            // UTC+1: Sep 9 22:01 -> Sep 10 07:07, downloaded at 17:07.
            XCTAssertEqual(clock.unixSeconds(672400, capturedUnix: 1789056420), 1788987660)
            XCTAssertEqual(clock.unixSeconds(1000000, capturedUnix: 1789056420), 1789020420)
            XCTAssertEqual(clock.latestUnix, 1789020420)
            if previousBoot {
                XCTAssertEqual(clock.unixSeconds(5000000, capturedUnix: 1788800000), 1788800000)
            }
            try events.validate()
        }
    }

    func testUnanchoredBootIsUndatedInsteadOfDatedToDownloadTime() throws {
        // A rebooted ring drained in one go with no time_sync/rtc_beacon: dating the
        // night to the download would show 07:11→15:33 instead of 23:00→08:00, and
        // projecting it through the previous boot's clock would land it days earlier.
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let sql = """
        DELETE FROM events;
        INSERT INTO events VALUES (1,5000000,66,'{"unix_time":1788800000}',1788800000,NULL);
        INSERT INTO events VALUES (2,5100000,1,'{}',1788800000,NULL);
        INSERT INTO events VALUES (3,10,1,'{}',1789056420,NULL);
        INSERT INTO events VALUES (4,300000,118,'{"bedtime_start_ds":300000}',1789056420,NULL);
        INSERT INTO events VALUES (5,700000,1,'{}',1789056420,NULL);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let events = try EventStore.decodedEvents(dbPath: url.path)
        let clock = EventStore.RingClock(events: events)
        let resolved = clock.resolve(300000, capturedUnix: 1789056420)
        XCTAssertEqual(resolved.source, .undated)
        XCTAssertFalse(resolved.source.isDated)
        XCTAssertNotEqual(resolved.unix, 1788800000 + Double(300000 - 5000000) / 10)
        XCTAssertEqual(clock.resolve(5100000, capturedUnix: 1788800000).source, .anchor)
        try events.validate()
    }

    func testMultipleRebootsLeaveMiddleUndated() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let sql = """
        DELETE FROM events;
        INSERT INTO events VALUES (1,1000,66,'{"unix_time":1700000000}',1700000000,NULL);
        INSERT INTO events VALUES (2,2000,65,'{}',1700100000,NULL);
        INSERT INTO events VALUES (3,8000,65,'{}',1700100000,NULL);
        INSERT INTO events VALUES (4,10000,66,'{"unix_time":1700100000}',1700100000,NULL);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let clock = EventStore.RingClock(events: try EventStore.decodedEvents(dbPath: url.path))
        XCTAssertEqual(clock.resolve(5000, capturedUnix: 1700100000).source, .undated)
        XCTAssertEqual(clock.resolve(1500, capturedUnix: 1700100000).unix, 1700000050)
        XCTAssertEqual(clock.resolve(9000, capturedUnix: 1700100000).unix, 1700099900)
    }

    func testUndecodedRawRingStartParticipatesInMultiRebootStallAmbiguity() throws {
        // Audited stall interval: anchor 47893458 (1787733221) -> anchor 61076535 (1789195418)
        // with undecoded raw ring_start at 49912254 and decoded ring_start at 57660709.
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let sql = """
        DELETE FROM events;
        INSERT INTO events VALUES (1,47893458,133,'{"unix_time":1787733221}',1789200000,NULL);
        INSERT INTO events VALUES (2,49912254,65,NULL,1789200000,X'0400000038020114010001020100');
        INSERT INTO events VALUES (3,53000000,118,'{"bedtime_start_ds":52700000}',1789200000,NULL);
        INSERT INTO events VALUES (4,57660709,65,'{"firmware":"2.1.20"}',1789200000,X'0400000038020114010001020100');
        INSERT INTO events VALUES (5,61076535,133,'{"unix_time":1789195418}',1789200000,NULL);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let events = try EventStore.decodedEvents(dbPath: url.path)
        let clock = EventStore.RingClock(events: events)
        // Middle epoch [49912254..57660709] is isolated by both reboots and withheld as undated.
        XCTAssertEqual(clock.resolve(53_000_000, capturedUnix: 1_789_200_000).source, .undated)
        XCTAssertNil(clock.datedUnixSeconds(53_000_000, capturedUnix: 1_789_200_000))
        // Before first reboot and after second reboot remain anchored.
        XCTAssertEqual(clock.resolve(48_000_000, capturedUnix: 1_789_200_000).source, .anchor)
        XCTAssertEqual(clock.resolve(58_000_000, capturedUnix: 1_789_200_000).source, .anchor)
    }

    func testPhoneAnchorDatesANewBoot() throws {
        // The sync wrote a phone-time anchor at the newest drained ds: 23:00→08:00 UTC+2.
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let sql = """
        DELETE FROM events;
        INSERT INTO events VALUES (1,5000000,66,'{"unix_time":1788800000}',1788800000,NULL);
        INSERT INTO events VALUES (2,10,1,'{}',1789056420,NULL);
        INSERT INTO events VALUES (3,705000,66,'{"unix_time":1789056420,"source":"phone"}',1789056420,NULL);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let events = try EventStore.decodedEvents(dbPath: url.path)
        let clock = EventStore.RingClock(events: events)
        let startDs: Int64 = 705000 - (1789056420 - 1789002000) * 10
        let endDs: Int64 = 705000 - (1789056420 - 1789020000) * 10
        XCTAssertEqual(clock.resolve(startDs, capturedUnix: 1789056420).source, .anchor)
        XCTAssertEqual(clock.unixSeconds(startDs, capturedUnix: 1789056420), 1789002000)
        XCTAssertEqual(clock.unixSeconds(endDs, capturedUnix: 1789056420), 1789020000)
        try events.validate()
    }

    func testStreamIsRepeatableAndKeepsRebootOrder() throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let events = try EventStore.decodedEvents(dbPath: url.path)
        XCTAssertEqual(events.map(\.ds), [5000000,5000010,10,20])
        XCTAssertEqual(events.restricted("tag=96").map(\.ds), [5000010,20])
        let clock = EventStore.RingClock(events: events)
        XCTAssertEqual(clock.unixSeconds(20, capturedUnix: 1700100001), 1700100001)
        XCTAssertEqual(events.map(\.ds).count, 4)
        try events.validate()
    }
    func testStreamCancellationAndReadFailureAreNotEmptySuccess() throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let events = try EventStore.decodedEvents(dbPath: url.path)
        let run = AnalysisRun()
        run.perform {
            let iterator = events.makeIterator()
            XCTAssertNotNil(iterator.next())
            run.cancel()
            XCTAssertNil(iterator.next())
            do { try events.validate(); XCTFail("partial stream accepted") } catch {}
        }
        XCTAssertThrowsError(try EventStore.decodedEvents(dbPath: url.path + ".missing"))
    }
    #endif

    func testTimestampedSignalsPreserveDelayedStartGapsAndStageAutonomicParity() throws {
        let startUnix: Int64 = 1_791_068_400
        let endUnix: Int64 = startUnix + 8 * 3600 // 28,800s night
        let firstOffset = 47.23 * 60.0 // 2833.8s after bedtime
        let rawHR: [[Double]] = [
            [Double(startUnix) + firstOffset, 60],
            [Double(startUnix) + firstOffset + 300, 62],
            // >15m missing interval (> laneGapSeconds), followed by another 5m pair
            [Double(startUnix) + 6 * 3600, 50],
            [Double(startUnix) + 6 * 3600 + 300, 52],
        ]
        let rawHRV: [[Double]] = [
            [Double(startUnix) + firstOffset, 40],
            [Double(startUnix) + firstOffset + 300, 44],
            [Double(startUnix) + 6 * 3600, 80],
            [Double(startUnix) + 6 * 3600 + 300, 84],
        ]
        let samples = try XCTUnwrap(Sleep.timedSamples(rawHR, startUnix: startUnix, endUnix: endUnix))
        XCTAssertEqual(samples.count, 4)
        // First sample is at 47.23 min (~0.0984 of the night), never at bedtime (0.0).
        XCTAssertEqual(samples[0].fraction, firstOffset / 28_800.0, accuracy: 1e-6)
        XCTAssertGreaterThan(samples[0].fraction, 0.09)
        // Scrubbing at bedtime (f = 0) or in the middle of the 45m gap returns nil.
        XCTAssertNil(Sleep.sampleAt(fraction: 0.0, in: samples, durationSeconds: 28_800))
        XCTAssertNil(Sleep.sampleAt(fraction: 0.4, in: samples, durationSeconds: 28_800))
        XCTAssertEqual(Sleep.sampleAt(fraction: samples[0].fraction, in: samples, durationSeconds: 28_800), 60)
        // Contiguous segments split across the >15m gap.
        let segments = Sleep.contiguousSegments(samples)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].map(\.value), [60, 62])
        XCTAssertEqual(segments[1].map(\.value), [50, 52])

        // Stage-specific averages assign samples by actual timestamp:
        // First half (0..<4h): Light (2); second half (4..<8h): REM (3).
        // Under index-fraction (0, 1/3, 2/3, 1), sample[2] at 6h sits at 2/3 (REM),
        // but if 4 samples all occurred in the second half (e.g. after a 4h gap), index-fraction
        // would falsely assign the first two to Light (2). Timestamped autonomic assigns all to REM (3).
        let stages = [2, 2, 3, 3]
        let lateHR: [[Double]] = [
            [Double(startUnix) + 5 * 3600, 50],
            [Double(startUnix) + 5.5 * 3600, 52],
            [Double(startUnix) + 6.5 * 3600, 54],
            [Double(startUnix) + 7.5 * 3600, 56],
        ]
        let lateHRV: [[Double]] = [
            [Double(startUnix) + 5 * 3600, 70],
            [Double(startUnix) + 5.5 * 3600, 74],
            [Double(startUnix) + 6.5 * 3600, 78],
            [Double(startUnix) + 7.5 * 3600, 82],
        ]
        var night = NightRow(start_unix: startUnix, end_unix: endUnix)
        night.series = NightSeries(hr: [50, 52, 54, 56], hrv: [70, 74, 78, 82])
        night.series_t = NightTimedSeries(hr: lateHR, hrv: lateHRV)
        let auto = Sleep.autonomic(night: night, stages: stages)
        XCTAssertNil(auto.hrLight)
        XCTAssertNil(auto.hrvLight)
        XCTAssertEqual(auto.hrRem, 53)
        XCTAssertEqual(auto.hrvRem, 76)
    }

    func testRefineDeepStagesAndEstimateStagesAndBedtimeOverrides() throws {
        let startUnix: Int64 = 1_791_151_863
        let endUnix: Int64 = 1_791_181_563
        let epochs = Int((endUnix - startUnix) / 30)
        var rawStages = Array(repeating: 2, count: epochs)
        for i in 0..<24 { rawStages[i] = 4 }
        for i in 220..<260 { rawStages[i] = 3 }
        for i in 480..<520 { rawStages[i] = 3 }
        for i in (epochs - 16)..<epochs { rawStages[i] = 4 }

        var hrTimed: [[Double]] = []
        var hrvTimed: [[Double]] = []
        var t = startUnix + 300
        while t <= endUnix {
            let frac = Double(t - startUnix) / Double(endUnix - startUnix)
            let quiet = (0.06...0.18).contains(frac) || (0.28...0.38).contains(frac)
            hrTimed.append([Double(t), quiet ? 54.0 : 62.0])
            hrvTimed.append([Double(t), quiet ? 42.0 : 32.0])
            t += 300
        }
        var night = NightRow(date: "2026-10-05", start: "00:11", end: "08:26",
                             start_unix: startUnix, end_unix: endUnix, in_bed_h: 8.2)
        night.series_t = NightTimedSeries(hr: hrTimed, hrv: hrvTimed,
                                          motion: [[Double(startUnix + 60), 18.0], [Double(endUnix - 60), 15.0]])

        let refined = Sleep.refineDeepStages(stages: rawStages, night: night)
        XCTAssertEqual(refined.count, rawStages.count)
        let deepCount = refined.filter { $0 == 1 }.count
        XCTAssertGreaterThanOrEqual(deepCount, 20)

        let estimated = try XCTUnwrap(Sleep.estimateStages(night: night))
        XCTAssertEqual(estimated.count, epochs)
        XCTAssertTrue(estimated.allSatisfy { (1...4).contains($0) })
        XCTAssertGreaterThan(estimated.filter { $0 == 1 }.count, 0)
        XCTAssertGreaterThan(estimated.filter { $0 == 2 }.count, 0)

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("oura-bedtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dbPath = tmpDir.appendingPathComponent("oura.db").path
        try BedtimeOverrideStore.set(startHM: "23:45", endHM: "08:15", forNightKey: "2026-10-05", dbPath: dbPath)
        let loaded = BedtimeOverrideStore.load(dbPath: dbPath)
        XCTAssertEqual(loaded["2026-10-05"]?.start, "23:45")
        XCTAssertEqual(loaded["2026-10-05"]?.end, "08:15")
        try BedtimeOverrideStore.clear(forNightKey: "2026-10-05", dbPath: dbPath)
        XCTAssertNil(BedtimeOverrideStore.load(dbPath: dbPath)["2026-10-05"])
    }
}

