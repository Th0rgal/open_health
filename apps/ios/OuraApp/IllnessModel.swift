#if TORCH
import Foundation
// sqlite3 comes from the bridging header (TorchBridge.h includes <sqlite3.h>)

// On-device Symptom Radar: assemble the 30-day biometric matrix + long-term baselines
// the illness-detection model expects and run illness_detection_0_5_1 via the LibTorch
// lite bridge. A faithful port of tools/run_illness_model.py (which see, plus
// docs/algorithms/illness-detection.md for the full I/O contract). The model bakes in
// all normalization / calibration / thresholds — we feed raw physiological values.
//
// HR/HRV come from the ring's own hrv_event (5-min rmssd_ms + hr_bpm); breathing rate
// is reconstructed from the IBI stream (respiratory sinus arrhythmia), matching the
// Python runner's respiratory_rate.py.
enum IllnessModel {
    static let nDays = 30
    private static let ibiTags: Set<Int> = [0x44, 0x60, 0x71]
    private static let tempTags: Set<Int> = [0x46, 0x69, 0x75]
    private static let day = 86400.0

    struct Nightly { var breath, avgHr, lowHr, hrv, skinTemp, dur: Double }

    /// Disposable indexed workspace: parse historical IBI once, retain only one
    /// night's values in RAM. It is never a source of truth or a model result cache.
    final class IBIWorkspace {
        private var db: OpaquePointer?
        private var insert: OpaquePointer?
        private var closed = false
        private let url = FileManager.default.temporaryDirectory.appendingPathComponent("oura-illness-ibi.sqlite")
        init() throws {
            let fm = FileManager.default
            try? fm.removeItem(at: url) // remove an abandoned previous pass under WorkGate
            guard sqlite3_open(url.path, &db) == SQLITE_OK else { let e = failure(); close(); throw e }
            do {
                if let protection = try? fm.attributesOfItem(atPath: DB.readPath())[.protectionKey] {
                    try fm.setAttributes([.protectionKey: protection], ofItemAtPath: url.path)
                }
                sqlite3_progress_handler(db, 10000, { _ in AnalysisRun.cancelled ? 1 : 0 }, nil)
                try execute("PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; PRAGMA cache_size=-2048; PRAGMA temp_store=FILE; CREATE TABLE ibi(id INTEGER PRIMARY KEY,t REAL,v REAL); BEGIN;")
                guard sqlite3_prepare_v2(db, "INSERT INTO ibi(t,v) VALUES (?,?)", -1, &insert, nil) == SQLITE_OK else { throw failure() }
            } catch { close(); throw error }
        }
        deinit { close() }
        private func failure() -> Error {
            EventStore.ReadError.step("IBI workspace sqlite=\(sqlite3_errcode(db)) extended=\(sqlite3_extended_errcode(db))")
        }
        private func execute(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
        }
        func append(time: Double, value: Double) throws {
            sqlite3_bind_double(insert, 1, time); sqlite3_bind_double(insert, 2, value)
            guard sqlite3_step(insert) == SQLITE_DONE else { throw failure() }
            sqlite3_reset(insert)
        }
        func finish() throws {
            sqlite3_finalize(insert); insert = nil
            try execute("COMMIT; CREATE INDEX ibi_time ON ibi(t);")
        }
        func values(start: Double, end: Double) throws -> (times: [Double], values: [Double]) {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT t,v FROM ibi WHERE t>=? AND t<=? ORDER BY id", -1, &statement, nil) == SQLITE_OK else { throw failure() }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, start); sqlite3_bind_double(statement, 2, end)
            var times: [Double] = [], values: [Double] = []
            var rc = sqlite3_step(statement)
            while rc == SQLITE_ROW {
                try AnalysisRun.check()
                times.append(sqlite3_column_double(statement, 0)); values.append(sqlite3_column_double(statement, 1))
                rc = sqlite3_step(statement)
            }
            guard rc == SQLITE_DONE else { throw failure() }
            return (times, values)
        }
        func close() {
            guard !closed else { return }; closed = true
            sqlite3_finalize(insert); insert = nil
            sqlite3_close(db); db = nil
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Same rows and anchors as the last complete run: the answer cannot differ, so
    /// return it without the full-history IBI ingest (the slowest stage of a launch).
    static func cachedRun(profile: Profile?, storeDigest: String?) -> (result: IllnessResult?, error: String?)? {
        guard let storeDigest else { return nil }
        let cacheKey = ModelCacheStore.globalKey(profile: profile)
        guard ModelCacheStore.loadDigest(ModelCacheStore.illnessFile, globalKey: cacheKey) == storeDigest else { return nil }
        let cached: [String: FingerprintedEntry<IllnessResult>] = ModelCacheStore.load(ModelCacheStore.illnessFile, globalKey: cacheKey)
        guard let entry = cached["result"] else { return nil }
        dlog("models", "illness cache=digest-hit")
        return (entry.value, nil)
    }

    static func run(profile: Profile?, events: EventStore.Events,
                    clock: EventStore.RingClock, knownDigest: String? = nil) -> (result: IllnessResult?, error: String?) {
        guard let modelPath = Bundle.main.path(forResource: "illness_detection_0_5_1", ofType: "ptl")
        else { return (nil, "illness model file missing from the app bundle") }
        guard !events.isEmpty else { return (nil, nil) }
        let cacheKey = ModelCacheStore.globalKey(profile: profile)
        let storeDigest = knownDigest ?? events.digest()
        if let hit = cachedRun(profile: profile, storeDigest: storeDigest) { return hit }
        func u(_ ds: Int64, _ cu: Int64) -> Double { clock.unixSeconds(ds, capturedUnix: cu) }
        func dated(_ ds: Int64, _ cu: Int64) -> Bool { clock.datedUnixSeconds(ds, capturedUnix: cu) != nil }
        let tz = Double(TimeZone.current.secondsFromGMT())

        let ibi: IBIWorkspace
        do { ibi = try IBIWorkspace() } catch { return (nil, "\(error)") }
        defer { ibi.close() }
        // ── gather raw signals with absolute times ────────────────────────────
        var hrvT: [Double] = [], hrvR: [Double] = [], hrvH: [Double] = []
        var tempT: [Double] = [], tempV: [Double] = []
        var windows: [(start: Double, end: Double)] = []
        var sed: [Int: Double] = [:], rest: [Int: Double] = [:]

        // The model looks at the last 30 wake days. Find that window first from the
        // (few) bedtime markers so the full-history IBI stream — millions of beats —
        // is only ingested for the days that can matter.
        var latestWake: Int?
        for e in events.restricted("tag=118") where dated(e.ds, e.cu) {
            if let s = (e.json["bedtime_start_ds"] as? NSNumber)?.int64Value,
               let en = (e.json["bedtime_end_ds"] as? NSNumber)?.int64Value, en > s,
               u(en, e.cu) - u(s, e.cu) >= 3600 {
                latestWake = max(latestWake ?? .min, Int((u(en, e.cu) + tz) / self.day))
            }
        }
        guard let latestWake else { return (nil, nil) }
        let cutoff = Double(latestWake - nDays - 2) * self.day - tz  // one extra day: activity is lagged
        // Only the tags below feed the model; letting SQLite skip the rest avoids
        // decoding two million rows of unrelated JSON.
        let relevant = events.restricted("tag IN (68,96,113,93,70,105,117,118,80)")
        for e in relevant {
            // Undated data (an untrustworthy boot clock) belongs to no night or day,
            // and anything before the window cannot change the result.
            guard dated(e.ds, e.cu), u(e.ds, e.cu) >= cutoff else { continue }
            switch e.tag {
            case let t where ibiTags.contains(t):
                guard let values = e.json["ibi_ms"] as? [Any] else { continue }
                let base = u(e.ds, e.cu)
                var acc = 0.0
                for value in values {
                    let v = (value as? NSNumber)?.doubleValue ?? 0
                    if v > 0 {
                        acc += v / 1000
                        do { try ibi.append(time: base + acc, value: v) }
                        catch { return (nil, "\(error)") }
                    }
                }
            case 0x5D:  // hrv_event: 5-min avg RMSSD + HR
                guard let rm = e.json["rmssd_ms"] as? [Any] else { continue }
                let hb = e.json["hr_bpm"] as? [Any] ?? []
                let step = ((e.json["interval_min"] as? NSNumber)?.doubleValue ?? 5) * 60.0
                let base = u(e.ds, e.cu)
                for (i, x) in rm.enumerated() {
                    let r = (x as? NSNumber)?.doubleValue ?? 0
                    if r > 0 {
                        hrvT.append(base + Double(i) * step)
                        hrvR.append(r)
                        hrvH.append(i < hb.count ? ((hb[i] as? NSNumber)?.doubleValue ?? .nan) : .nan)
                    }
                }
            case let t where tempTags.contains(t):
                guard let arr = e.json["temps_c"] as? [Any] else { continue }
                let base = u(e.ds, e.cu)
                for x in arr {
                    let v = (x as? NSNumber)?.doubleValue ?? 0
                    if v > 20 { tempT.append(base); tempV.append(v) }
                }
            case 0x76:  // bedtime_period
                if let s = (e.json["bedtime_start_ds"] as? NSNumber)?.int64Value,
                   let en = (e.json["bedtime_end_ds"] as? NSNumber)?.int64Value, en > s {
                    windows.append((u(s, e.cu), u(en, e.cu)))
                }
            default:
                if let met = e.json["met"] as? [Any] {
                    let base = u(e.ds, e.cu)
                    for (i, x) in met.enumerated() {
                        let mv = (x as? NSNumber)?.doubleValue ?? 1.0
                        let d = Int((base + Double(i) * 60.0 + tz) / self.day)
                        if mv < 1.05 { rest[d, default: 0] += 60 }
                        else if mv < 2.0 { sed[d, default: 0] += 60 }
                    }
                }
            }
        }

        guard !AnalysisRun.cancelled, events.error == nil else { return (nil, "analysis interrupted") }

        do { try ibi.finish() } catch { return (nil, "\(error)") }

        // ── per wake-day nightly biometrics (longest sleep wins) ──────────────
        var perDay: [Int: Nightly] = [:]
        for w in windows {
            guard !AnalysisRun.cancelled else { return (nil, "analysis paused") }
            let dur = w.end - w.start
            if dur < 3600 { continue }
            let wakeDay = Int((w.end + tz) / self.day)
            let hIdx = indicesInRange(hrvT, w.start, w.end)
            if hIdx.count < 3 { continue }
            let rmssd = median(hIdx.map { hrvR[$0] })
            let hrs = hIdx.map { hrvH[$0] }.filter { $0.isFinite }
            if hrs.count < 3 { continue }
            let nightIBI: (times: [Double], values: [Double])
            do { nightIBI = try ibi.values(start: w.start, end: w.end) }
            catch { return (nil, "\(error)") }
            let ibiT = nightIBI.times, ibiV = nightIBI.values
            let iIdx = indicesInRange(ibiT, w.start, w.end)
            let breath = iIdx.count > 200
                ? respiratoryRate(iIdx.map { ibiT[$0] }, iIdx.map { ibiV[$0] })
                : Double.nan
            let tIdx = indicesInRange(tempT, w.start, w.end)
            let skin = tIdx.isEmpty ? Double.nan : median(tIdx.map { tempV[$0] })
            let n = Nightly(breath: breath, avgHr: median(hrs), lowHr: hrs.min() ?? .nan,
                            hrv: rmssd, skinTemp: skin, dur: dur)
            if perDay[wakeDay] == nil || dur > perDay[wakeDay]!.dur { perDay[wakeDay] = n }
        }
        guard let anchor = perDay.keys.max() else { return (nil, nil) }

        // ── 30-day columns (index 0 = today) ──────────────────────────────────
        func col(_ pick: (Nightly) -> Double) -> [Float] {
            (0..<nDays).map { i in perDay[anchor - i].map { Float(pick($0)) } ?? .nan }
        }
        let breath = col { $0.breath }, avgHr = col { $0.avgHr }, lowHr = col { $0.lowHr }
        let hrv = col { $0.hrv }
        let skin = (0..<nDays).map { i in perDay[anchor - i]?.skinTemp ?? Double.nan }
        let finiteSkin = skin.filter { $0.isFinite }
        let baseTemp = finiteSkin.isEmpty ? Double.nan : median(finiteSkin)
        let tempDev = skin.map { $0.isFinite && baseTemp.isFinite ? Float($0 - baseTemp) : .nan }
        // Oura pairs each night with the full day *before* it (`activityMap.get(day.minusDays(1))`
        // in the Symptom Radar input builder). Using the wake day itself fed the model a
        // near-empty morning, which drags the score down on exactly the nights that matter.
        let sedC = (0..<nDays).map { i in sed[anchor - i - 1].map { Float($0) } ?? .nan }
        let restC = (0..<nDays).map { i in rest[anchor - i - 1].map { Float($0) } ?? .nan }

        // 301/302 guards (mirror the model's input validator)
        if !tempDev[0].isFinite {
            return (IllnessResult(available: false, status: "MISSING_LAST_NIGHT_SLEEP",
                                  trafficLight: "", score: 0, decision: 0, date: "",
                                  daysWithData: 0, biomarkers: []), nil)
        }
        if tempDev.prefix(14).filter({ !$0.isFinite }).count > 7 {
            return (IllnessResult(available: false, status: "MISSING_SLEEP_DATA",
                                  trafficLight: "", score: 0, decision: 0, date: "",
                                  daysWithData: 0, biomarkers: []), nil)
        }

        // ── long-term baselines + demographics ────────────────────────────────
        let rhrF = lowHr.map(Double.init).filter { $0.isFinite }
        let hrvF = hrv.map(Double.init).filter { $0.isFinite }
        let sedF = sedC.map(Double.init).filter { $0.isFinite }
        func avg(_ a: [Double], _ d: Double) -> Double { a.isEmpty ? d : a.reduce(0, +) / Double(a.count) }
        func std(_ a: [Double], _ d: Double) -> Double {
            guard a.count > 1 else { return d }
            let m = a.reduce(0, +) / Double(a.count)
            return (a.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(a.count)).squareRoot()
        }
        let h = profile?.height_m ?? 1.78, w = profile?.weight_kg ?? 75
        let bmi = w / (h * h)
        let sex: Float = (profile?.sex?.uppercased() == "F") ? -1 : (profile?.sex?.uppercased() == "O" ? 0 : 1)
        let (y, mo, dd) = civil(anchor)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let dow = Float(((cal.dateComponents([.weekday], from: cal.date(from: DateComponents(year: y, month: mo, day: dd))!).weekday ?? 1) + 5) % 7) // Mon=0

        let scalars: [Float] = [
            Float(profile?.age ?? 30), Float(bmi), sex, dow,
            Float(avg(rhrF, 55)), Float(std(rhrF, 3)),
            Float(avg(hrvF, 45)), Float(std(hrvF, 6)),
            Float(baseTemp.isFinite ? baseTemp : 36), Float(std(finiteSkin, 0.2)),
            Float(avg(sedF, 30000)), Float(std(sedF, 4000)),
        ]
        var series = breath + avgHr + lowHr + hrv + tempDev + sedC + restC  // 7×30 row-major
        var scal = scalars
        guard !AnalysisRun.cancelled, events.error == nil else { return (nil, "analysis interrupted") }
        // Inputs are fingerprinted inside the entry; the file key stays the stable
        // profile/timezone key so a new day never discards the whole file.
        var fingerprint = FNV64(); fingerprint.combine(series); fingerprint.combine(scal); fingerprint.combine(anchor)
        let cached: [String: FingerprintedEntry<IllnessResult>] = ModelCacheStore.load(ModelCacheStore.illnessFile, globalKey: cacheKey)
        if let entry = cached["result"], entry.fp == fingerprint.hex {
            dlog("models", "illness cache=hit")
            ModelCacheStore.save(ModelCacheStore.illnessFile, globalKey: cacheKey, entries: cached, digest: storeDigest,
                                 keepGenerations: true)
            return (entry.value, nil)
        }
        var score = 0.0, decision: Int32 = 0
        var bio = [Float](repeating: 0, count: 16)
        let rc = oura_illness(modelPath, &series, &scal, &score, &decision, &bio)
        guard rc == 0 else { return (nil, "illness inference failed") }

        let light = ["NO_SIGNS", "MINOR_SIGNS", "MAJOR_SIGNS"][max(0, min(2, Int(decision)))]
        let labels = ["AverageBreath", "LowestHeartRate", "AverageHrv", "TemperatureDeviation"]
        var biomarkers: [IllnessBiomarker] = []
        for (b, label) in labels.enumerated() {
            let isOut = bio[b * 4 + 0], value = bio[b * 4 + 1]
            let lo = bio[b * 4 + 2], hi = bio[b * 4 + 3]
            if [isOut, value, lo, hi].contains(where: { !$0.isFinite }) { continue }
            let flagged = isOut.rounded() == 1
            biomarkers.append(IllnessBiomarker(
                type: label, value: Double(value), lower: Double(lo), upper: Double(hi),
                indicatesSymptoms: flagged,
                reason: flagged ? (value > hi ? "ELEVATED" : "DECREASED") : nil))
        }
        let daysWithData = tempDev.filter { $0.isFinite }.count
        let result = IllnessResult(
            available: true, status: light, trafficLight: light,
            score: score, decision: Int(decision),
            date: String(format: "%04d-%02d-%02d", y, mo, dd),
            daysWithData: daysWithData, biomarkers: biomarkers)
        ModelCacheStore.save(ModelCacheStore.illnessFile, globalKey: cacheKey,
                             entries: ["result": FingerprintedEntry(fp: fingerprint.hex, value: result)],
                             digest: storeDigest, keepGenerations: true)
        dlog("models", "illness cache=miss")
        return (result, nil)
    }

    // ── respiratory rate (RSA) — port of tools/respiratory_rate.py ────────────
    private static let fs = 4.0, respLo = 0.15, respHi = 0.40, winS = 60.0, stepS = 30.0

    static func respiratoryRate(_ ts: [Double], _ ibi: [Double]) -> Double {
        // ectopic filter: physiological range + within 30% of median
        var t: [Double] = [], v: [Double] = []
        for (i, x) in ibi.enumerated() where x >= 300 && x <= 2000 { t.append(ts[i]); v.append(x) }
        if v.count < 30 { return .nan }
        let med = median(v)
        var t2: [Double] = [], v2: [Double] = []
        for (i, x) in v.enumerated() where abs(x - med) <= 0.30 * med { t2.append(t[i]); v2.append(x) }
        if v2.count < 30 || (t2.last! - t2.first!) < winS { return .nan }
        // 4 Hz resample (linear interp on the IBI tachogram)
        let span = t2.last! - t2.first!
        // A mis-dated bedtime (ring reboot on a long hike) can span days and
        // allocate tens of millions of samples. Cap at an implausible night.
        if span > 18 * 3600 { return .nan }
        let n = Int(span * fs)
        if n < Int(winS * fs) { return .nan }
        var x = [Double](repeating: 0, count: n)
        var j = 0
        for k in 0..<n {
            let tk = t2.first! + Double(k) / fs
            while j < t2.count - 2 && t2[j + 1] < tk { j += 1 }
            let t0 = t2[j], t1 = t2[j + 1]
            let f = t1 > t0 ? (tk - t0) / (t1 - t0) : 0
            x[k] = v2[j] + (v2[j + 1] - v2[j]) * f
        }
        x = bandpass(x)
        // per-window dominant respiratory frequency (direct DFT scan over the band)
        let win = Int(winS * fs), hop = Int(stepS * fs)
        var rr: [Double] = []
        var i = 0
        while i + win <= x.count {
            if let f = dominantFreq(Array(x[i..<i + win])) { rr.append(f * 60.0) }
            i += hop
        }
        return rr.count >= 3 ? median(rr) : .nan
    }

    // windowed-sinc respiratory band-pass (scipy-free; matches the Python fallback)
    private static func bandpass(_ x: [Double]) -> [Double] {
        let mean = x.reduce(0, +) / Double(x.count)
        let centered = x.map { $0 - mean }
        let n = 129
        var kern = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) - Double(n - 1) / 2
            let lo = 2 * respLo / fs * sinc(2 * respLo / fs * t)
            let hi = 2 * respHi / fs * sinc(2 * respHi / fs * t)
            let hann = 0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(n - 1))
            kern[i] = (hi - lo) * hann
        }
        let km = kern.reduce(0, +) / Double(n)
        for i in 0..<n { kern[i] -= km }
        // 'same' convolution
        var out = [Double](repeating: 0, count: centered.count)
        let half = n / 2
        for i in 0..<centered.count {
            var acc = 0.0
            for k in 0..<n {
                let idx = i + k - half
                if idx >= 0 && idx < centered.count { acc += centered[idx] * kern[k] }
            }
            out[i] = acc
        }
        return out
    }

    // dominant frequency in [respLo, respHi] via a direct DFT scan; nil if no clear peak
    private static func dominantFreq(_ seg: [Double]) -> Double? {
        let m = seg.reduce(0, +) / Double(seg.count)
        let win = (0..<seg.count).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(seg.count - 1)) }
        let s = (0..<seg.count).map { (seg[$0] - m) * win[$0] }
        var freqs: [Double] = [], powers: [Double] = []
        var f = respLo
        while f <= respHi {
            var re = 0.0, im = 0.0
            for k in 0..<s.count {
                let a = 2 * .pi * f * Double(k) / fs
                re += s[k] * cos(a); im -= s[k] * sin(a)
            }
            freqs.append(f); powers.append(re * re + im * im)
            f += 0.005
        }
        guard let maxP = powers.max(), let mi = powers.firstIndex(of: maxP) else { return nil }
        if maxP < 4.0 * median(powers) { return nil }  // require a real peak
        return freqs[mi]
    }

    private static func sinc(_ x: Double) -> Double { x == 0 ? 1 : sin(.pi * x) / (.pi * x) }

    // ── helpers ───────────────────────────────────────────────────────────────
    private static func indicesInRange(_ ts: [Double], _ lo: Double, _ hi: Double) -> [Int] {
        (0..<ts.count).filter { ts[$0] >= lo && ts[$0] <= hi }
    }
    private static func median(_ a: [Double]) -> Double {
        if a.isEmpty { return .nan }
        let s = a.sorted(); let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
    // Howard Hinnant civil_from_days — matches oura-summary / run_illness_model.py
    private static func civil(_ days: Int) -> (Int, Int, Int) {
        let z = days + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (y + (m <= 2 ? 1 : 0), m, d)
    }
}
#endif
