import SwiftUI

// Full-page, research-grade sleep & activity reports — the iOS counterpart to the web
// dashboard's `sleepReport`/`activityReport` (see docs/clients-web-and-ios.md). The raw
// per-night signal series arrive from build_summary (NightRow.series); the hypnogram is
// the on-device SleepNet output (NightRow.stages, TORCH build). Sleep metrics + debt are
// computed here in Swift, mirroring crates/oura-summary so both clients agree.

// ── science: hypnogram-derived metrics (mirror of oura-summary sleep_metrics) ──
struct SleepMetrics {
    var asleepMin: Double
    var solMin: Double
    var remLatencyMin: Double?
    var wasoMin: Double
    var awakenings: Int
    var cycles: Int
    var fragIndex: Double
    var deepFirstHalfPct: Double?
    var remFirstHalfPct: Double?
}

// Mean HR/HRV per sleep stage — deep-sleep HRV is the recovery-relevant number. Mirror of
// oura-summary `autonomic_by_stage`. Uses per-sample timestamps (`series_t`) when present
// so iOS and web assign every HR/HRV sample to the stage at its actual timestamp.
struct StageAutonomic: Codable, Equatable {
    var hrvDeep: Double?; var hrvLight: Double?; var hrvRem: Double?
    var hrDeep: Double?; var hrLight: Double?; var hrRem: Double?
    var any: Bool { [hrvDeep, hrvLight, hrvRem, hrDeep, hrLight, hrRem].contains { $0 != nil } }
    enum CodingKeys: String, CodingKey {
        case hrvDeep = "hrv_deep", hrvLight = "hrv_light", hrvRem = "hrv_rem"
        case hrDeep = "hr_deep", hrLight = "hr_light", hrRem = "hr_rem"
    }
}

enum Sleep {
    /// Maximum unobserved gap (seconds) bridged by a continuous signal line; longer
    /// gaps break the line and area fill, matching `LANE_GAP_S` in `dashboard/web/app.js`.
    static let laneGapSeconds: Double = 15 * 60

    struct TimedSample: Equatable {
        let unix: Double
        let fraction: Double
        let value: Double
    }

    /// Convert `[[unix_s, value]]` pairs into normalized night-window samples.
    static func timedSamples(_ raw: [[Double]]?, startUnix: Int64?, endUnix: Int64?) -> [TimedSample]? {
        guard let raw, !raw.isEmpty, let startUnix, let endUnix, endUnix > startUnix else { return nil }
        let start = Double(startUnix), end = Double(endUnix), span = end - start
        let samples: [TimedSample] = raw.compactMap { pair in
            guard pair.count >= 2 else { return nil }
            let t = pair[0], v = pair[1]
            guard t.isFinite, v.isFinite, t >= start - 1e-6, t <= end + 1e-6 else { return nil }
            let f = min(max((t - start) / span, 0), 1)
            return TimedSample(unix: t, fraction: f, value: v)
        }
        return samples.isEmpty ? nil : samples
    }

    /// Split timestamped samples into contiguous segments separated by gaps > `maxGapSeconds`.
    static func contiguousSegments(_ samples: [TimedSample], maxGapSeconds: Double = laneGapSeconds) -> [[TimedSample]] {
        guard !samples.isEmpty else { return [] }
        var segments: [[TimedSample]] = [[samples[0]]]
        for sample in samples.dropFirst() {
            if sample.unix - segments[segments.count - 1].last!.unix > maxGapSeconds {
                segments.append([sample])
            } else {
                segments[segments.count - 1].append(sample)
            }
        }
        return segments
    }

    /// Value of the sample nearest `fraction` within `toleranceSeconds`, or `nil` inside a gap / missing edge.
    static func sampleAt(fraction: Double, in samples: [TimedSample], durationSeconds: Double,
                         toleranceSeconds: Double = laneGapSeconds / 2) -> Double? {
        guard durationSeconds > 0, !samples.isEmpty else { return nil }
        guard let nearest = samples.min(by: { abs($0.fraction - fraction) < abs($1.fraction - fraction) }),
              abs(nearest.fraction - fraction) * durationSeconds <= toleranceSeconds else {
            return nil
        }
        return nearest.value
    }

    /// Preserve SleepNet's absolute 30-second grid instead of stretching its output.
    static func alignedStages(timestamps: [Int64], stages: [Int], startMs: Int64, endMs: Int64) -> [Int]? {
        guard timestamps.count == stages.count, endMs > startMs,
              endMs - startMs <= 48 * 3600 * 1000,
              stages.allSatisfy({ (1...4).contains($0) }),
              zip(timestamps, timestamps.dropFirst()).allSatisfy({ $0 < $1 }) else { return nil }
        // SleepNet stamps each epoch with its END time: the first output is start+30 s
        // and the last lands on (or just past) the bedtime end. Epoch k covers
        // (t-30 s, t]; reading t as the start left epoch 0 unknown and dropped the
        // last one, so every night was reported incomplete. Mirrors
        // tools/sleep_inputs.py.
        let span = endMs - startMs
        var aligned = Array(repeating: 0, count: max(1, Int((span + 29_999) / 30_000)))
        for (timestamp, stage) in zip(timestamps, stages) {
            guard timestamp > startMs else { continue }
            let index = Int((timestamp - startMs - 1) / 30_000)
            if index < aligned.count { aligned[index] = stage }
        }
        return aligned
    }

    /// Mean of each stage's HR and HRV samples using actual sample timestamps (`series_t`).
    /// Mirrors `oura-summary::autonomic_by_stage`.
    static func autonomic(hrTimed: [[Double]], hrvTimed: [[Double]],
                          startUnix: Int64, endUnix: Int64, stages: [Int]) -> StageAutonomic {
        guard !stages.isEmpty, endUnix > startUnix else { return StageAutonomic() }
        let start = Double(startUnix), span = Double(endUnix - startUnix)
        func means(_ pts: [[Double]]) -> [Int: Double] {
            var sum: [Int: Double] = [:], cnt: [Int: Int] = [:]
            for pair in pts where pair.count >= 2 {
                let t = pair[0], v = pair[1]
                guard v > 0, t.isFinite, v.isFinite else { continue }
                let f = (t - start) / span
                guard f >= -1e-9, f <= 1 + 1e-9 else { continue }
                let clamped = min(max(f, 0), 1)
                let idx = min(Int((clamped + 1e-9) * Double(stages.count)), stages.count - 1)
                let s = stages[idx]
                sum[s, default: 0] += v; cnt[s, default: 0] += 1
            }
            return cnt.reduce(into: [:]) { $0[$1.key] = (sum[$1.key]! / Double($1.value)).rounded() }
        }
        let h = means(hrTimed), v = means(hrvTimed)
        return StageAutonomic(hrvDeep: v[1], hrvLight: v[2], hrvRem: v[3],
                              hrDeep: h[1], hrLight: h[2], hrRem: h[3])
    }

    /// Resolve stage-specific HR and HRV averages for `night`, preferring timestamped
    /// `series_t` samples, then precomputed `night.autonomic`, and finally flat `series`
    /// only for legacy cached summaries without timestamps.
    static func autonomic(night: NightRow, stages: [Int]) -> StageAutonomic {
        if let timed = night.series_t,
           (!timed.hr.isEmpty || !timed.hrv.isEmpty),
           let startUnix = night.start_unix, let endUnix = night.end_unix, endUnix > startUnix {
            return autonomic(hrTimed: timed.hr, hrvTimed: timed.hrv,
                             startUnix: startUnix, endUnix: endUnix, stages: stages)
        }
        if let precomputed = night.autonomic, precomputed.any {
            return precomputed
        }
        return autonomic(hr: night.series?.hr ?? [], hrv: night.series?.hrv ?? [], stages: stages)
    }

    /// Legacy fallback when `series_t` is unavailable: maps series index → stage by fraction of the night.
    static func autonomic(hr: [Double], hrv: [Double], stages: [Int]) -> StageAutonomic {
        func means(_ series: [Double]) -> [Int: Double] {
            guard series.count > 1, stages.count > 0 else { return [:] }
            var sum: [Int: Double] = [:], cnt: [Int: Int] = [:]
            for (i, v) in series.enumerated() where v > 0 {
                let f = Double(i) / Double(series.count - 1)
                let s = stages[min(Int(f * Double(stages.count)), stages.count - 1)]
                sum[s, default: 0] += v; cnt[s, default: 0] += 1
            }
            return cnt.reduce(into: [:]) { $0[$1.key] = (sum[$1.key]! / Double($1.value)).rounded() }
        }
        let h = means(hr), v = means(hrv)
        return StageAutonomic(hrvDeep: v[1], hrvLight: v[2], hrvRem: v[3],
                              hrDeep: h[1], hrLight: h[2], hrRem: h[3])
    }

    /// Mode filter over a centered odd window — removes single-epoch flicker so cycle /
    /// awakening counts reflect real architecture, not 30 s noise.
    static func smooth(_ v: [Int], _ win: Int) -> [Int] {
        guard v.count >= win, win >= 3 else { return v }
        let half = win / 2
        return v.indices.map { i in
            if v[i] == 0 { return 0 }
            let a = max(0, i - half), b = min(v.count, i + half + 1)
            var counts = [0, 0, 0, 0, 0]
            for s in v[a..<b] where (1...4).contains(s) { counts[s] += 1 }
            return (1...4).max(by: { counts[$0] < counts[$1] }) ?? v[i]
        }
    }

    private static func bouts(_ seq: ArraySlice<Int>, _ code: Int, _ minLen: Int) -> Int {
        var count = 0, run = 0
        for c in seq {
            if c == code { run += 1 } else { if run >= minLen { count += 1 }; run = 0 }
        }
        if run >= minLen { count += 1 }
        return count
    }

    private static func periods(_ seq: ArraySlice<Int>, _ code: Int, _ mergeGap: Int, _ minLen: Int) -> Int {
        var runs: [(Int, Int)] = []
        let arr = Array(seq)
        var i = 0
        while i < arr.count {
            if arr[i] == code {
                let s = i
                while i < arr.count, arr[i] == code { i += 1 }
                runs.append((s, i))
            } else { i += 1 }
        }
        guard !runs.isEmpty else { return 0 }
        var merged = [runs[0]]
        for r in runs.dropFirst() {
            if r.0 - merged[merged.count - 1].1 < mergeGap { merged[merged.count - 1].1 = r.1 }
            else { merged.append(r) }
        }
        return merged.filter { $0.1 - $0.0 >= minLen }.count
    }

    static func metrics(_ stages: [Int], inBedS: Double) -> SleepMetrics? {
        let n = stages.count
        guard n > 0, inBedS > 0, stages.allSatisfy({ (1...4).contains($0) }) else { return nil }
        let epochMin = inBedS / 60.0 / Double(n)
        let isSleep = { (c: Int) in (1...3).contains(c) }
        guard let onset = stages.firstIndex(where: isSleep),
              let finalSleep = stages.lastIndex(where: isSleep) else { return nil }
        let span = stages[onset...finalSleep]
        let asleepEpochs = stages.filter(isSleep).count
        let asleepMin = Double(asleepEpochs) * epochMin

        let wasoEpochs = span.filter { $0 == 4 }.count
        let minWake = max(1, Int((1.0 / epochMin).rounded(.up)))
        let awakenings = bouts(span, 4, minWake)

        let remLatency = stages[onset...].firstIndex(of: 3).map { Double($0 - onset) * epochMin }
        let mergeGap = max(1, Int((15.0 / epochMin).rounded()))
        let minRem = max(1, Int((3.0 / epochMin).rounded(.up)))
        let cycles = periods(span, 3, mergeGap, minRem)

        let transitions = zip(span, span.dropFirst()).filter { $0 != $1 }.count
        let fragIndex = asleepMin > 0 ? Double(transitions) / (asleepMin / 60.0) : 0

        let mid = onset + (finalSleep - onset) / 2
        func halfPct(_ code: Int) -> Double? {
            let total = stages.filter { $0 == code }.count
            guard total > 0 else { return nil }
            let first = stages[onset...mid].filter { $0 == code }.count
            return (Double(first) / Double(total) * 100).rounded()
        }
        let r1 = { (x: Double) in (x * 10).rounded() / 10 }
        return SleepMetrics(
            asleepMin: r1(asleepMin), solMin: r1(Double(onset) * epochMin),
            remLatencyMin: remLatency.map(r1), wasoMin: r1(Double(wasoEpochs) * epochMin),
            awakenings: awakenings, cycles: cycles, fragIndex: r1(fragIndex),
            deepFirstHalfPct: halfPct(1), remFirstHalfPct: halfPct(3))
    }

    /// asleep seconds for a night from its (smoothed) stages.
    static func asleepS(_ stages: [Int], inBedS: Double) -> Int {
        let n = stages.count
        guard n > 0, stages.allSatisfy({ (1...4).contains($0) }) else { return 0 }
        let epochS = inBedS / Double(n)
        return Int(Double(stages.filter { (1...3).contains($0) }.count) * epochS)
    }

    private static func percentile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let pos = min(max(q, 0), 1) * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - Double(lo))
    }

    private static func epochSignalGrid(night: NightRow, count n: Int) -> (hr: [Double?], hrv: [Double?], motion: [Double])? {
        guard n >= 20 else { return nil }
        let startS = Double(night.start_unix ?? 0)
        let endS = Double(night.end_unix ?? Int64(night.durationS.rounded()))
        let spanS = endS > startS ? (endS - startS) : max(night.durationS, Double(n * 30))
        guard spanS > 0 else { return nil }
        let stepS = spanS / Double(n)

        func interpolate(_ pts: [[Double]], fallback: [Double], maxHoldS: Double) -> [Double?] {
            var pairs: [(Double, Double)] = pts.compactMap { p in
                guard p.count >= 2, p[0].isFinite, p[1].isFinite, p[1] > 0 else { return nil }
                return (p[0], p[1])
            }
            if pairs.isEmpty, fallback.count > 1 {
                pairs = fallback.enumerated().compactMap { i, v in
                    guard v.isFinite, v > 0 else { return nil }
                    let t = startS + spanS * Double(i) / Double(fallback.count - 1)
                    return (t, v)
                }
            }
            guard !pairs.isEmpty else { return Array(repeating: nil, count: n) }
            pairs.sort { $0.0 < $1.0 }
            var out = Array(repeating: Double?.none, count: n)
            var cursor = 0
            for idx in 0..<n {
                let center = startS + (Double(idx) + 0.5) * stepS
                while cursor + 1 < pairs.count && pairs[cursor + 1].0 <= center {
                    cursor += 1
                }
                var best = pairs[cursor]
                if cursor + 1 < pairs.count, abs(pairs[cursor + 1].0 - center) < abs(best.0 - center) {
                    best = pairs[cursor + 1]
                }
                if abs(best.0 - center) <= maxHoldS {
                    out[idx] = best.1
                }
            }
            return out
        }

        let hr = interpolate(night.series_t?.hr ?? [], fallback: night.series?.hr ?? [], maxHoldS: 450)
        let hrv = interpolate(night.series_t?.hrv ?? [], fallback: night.series?.hrv ?? [], maxHoldS: 450)
        var motion = Array(repeating: 0.0, count: n)
        if let timedMotion = night.series_t?.motion, !timedMotion.isEmpty {
            for p in timedMotion where p.count >= 2 && p[0].isFinite && p[1].isFinite {
                let f = (p[0] - startS) / spanS
                guard f >= -1e-6 && f <= 1 + 1e-6 else { continue }
                let idx = min(max(Int(f * Double(n)), 0), n - 1)
                if p[1] > motion[idx] { motion[idx] = p[1] }
            }
        } else if let mVals = night.series?.motion, !mVals.isEmpty {
            let mTimes = night.series?.motion_time
            for (i, v) in mVals.enumerated() where v.isFinite {
                let f: Double
                if let mTimes, i < mTimes.count { f = mTimes[i] }
                else { f = Double(i) / Double(max(1, mVals.count - 1)) }
                let idx = min(max(Int(f * Double(n)), 0), n - 1)
                if v > motion[idx] { motion[idx] = v }
            }
        }
        return (hr, hrv, motion)
    }

    /// Recover physiological N3 (Deep) bouts when Oura Gen 4 sparse IBI streams cause
    /// SleepNet to collapse N3 into N2 (0% Deep across a full night). Mirrors
    /// `oura-summary::refine_deep_stages`.
    static func refineDeepStages(stages: [Int], night: NightRow) -> [Int] {
        let n = stages.count
        guard n >= 40,
              stages.allSatisfy({ (1...4).contains($0) }),
              !stages.contains(1),
              stages.filter({ $0 == 2 }).count >= 20,
              let grid = epochSignalGrid(night: night, count: n) else {
            return stages
        }
        let hrValid = grid.hr.compactMap { $0 }
        guard hrValid.count >= 6 else { return stages }
        let hrQ35 = percentile(hrValid, 0.35)
        let hrQ50 = percentile(hrValid, 0.50)
        let hrvValid = grid.hrv.compactMap { $0 }
        let hrvQ45 = hrvValid.count >= 4 ? percentile(hrvValid, 0.45) : 0.0
        let posMotion = grid.motion.filter { $0 > 0 }
        let quietMotion = posMotion.isEmpty ? 2.0 : max(2.0, min(6.0, percentile(posMotion, 0.35)))

        let candidates: [Bool] = (0..<n).map { idx in
            guard stages[idx] == 2 else { return false }
            let frac = Double(idx) / Double(max(1, n - 1))
            guard frac <= 0.78, grid.motion[idx] <= quietMotion else { return false }
            let lo = max(0, idx - 3), hi = min(n, idx + 4)
            guard !(lo..<hi).contains(where: { stages[$0] == 4 || stages[$0] == 3 }),
                  let h = grid.hr[idx] else { return false }
            let hCap = frac <= 0.55 ? hrQ50 : hrQ35
            guard h <= hCap + 0.5 else { return false }
            let hrs = (lo..<hi).compactMap { grid.hr[$0] }
            if hrs.count >= 3 {
                let mean = hrs.reduce(0, +) / Double(hrs.count)
                let variance = hrs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(hrs.count)
                if variance.squareRoot() > 3.2 { return false }
            }
            if hrvQ45 > 0, let v = grid.hrv[idx], v < hrvQ45 * 0.75 && h > hrQ35 {
                return false
            }
            return true
        }

        var smoothed = candidates
        if n >= 3 {
            for idx in 1..<(n - 1) {
                if !smoothed[idx] && candidates[idx - 1] && candidates[idx + 1] && stages[idx] == 2 {
                    smoothed[idx] = true
                }
            }
        }
        var refined = stages
        let maxDeep = max(8, Int((Double(n) * 0.24).rounded()))
        var assigned = 0
        var idx = 0
        while idx < n {
            if smoothed[idx] {
                var end = idx + 1
                while end < n && smoothed[end] { end += 1 }
                if end - idx >= 6 {
                    for j in idx..<end where assigned < maxDeep {
                        refined[j] = 1
                        assigned += 1
                    }
                }
                idx = end
            } else {
                idx += 1
            }
        }
        return refined
    }

    /// Physiological 4-stage hypnogram estimator when Torch SleepNet cannot run on a night
    /// (e.g. Gen 4 nights with sparse raw PPG beats or model failure) yet valid overnight
    /// HR/HRV/temp/motion series are present. Mirrors `oura-summary::stage_night_from_signals`.
    static func estimateStages(night: NightRow) -> [Int]? {
        let spanS: Double
        if let s = night.start_unix, let e = night.end_unix, e > s {
            spanS = Double(e - s)
        } else {
            spanS = night.durationS
        }
        let n = Int((spanS / 30.0).rounded())
        guard (40...1920).contains(n),
              let grid = epochSignalGrid(night: night, count: n) else { return nil }
        let hrValid = grid.hr.compactMap { $0 }
        let hrvValid = grid.hrv.compactMap { $0 }
        guard hrValid.count >= 6 || hrvValid.count >= 6 else { return nil }

        let hrQ35 = hrValid.isEmpty ? 58.0 : percentile(hrValid, 0.35)
        let hrQ65 = hrValid.isEmpty ? 64.0 : percentile(hrValid, 0.65)
        let hrQ85 = hrValid.isEmpty ? 70.0 : percentile(hrValid, 0.85)
        let hrvQ35 = hrvValid.isEmpty ? 30.0 : percentile(hrvValid, 0.35)
        let hrvQ65 = hrvValid.isEmpty ? 50.0 : percentile(hrvValid, 0.65)
        let posMotion = grid.motion.filter { $0 > 0 }
        let wakeMotion = posMotion.isEmpty ? 12.0 : max(8.0, percentile(posMotion, 0.85))
        let quietMotion = posMotion.isEmpty ? 2.0 : max(2.0, min(5.0, percentile(posMotion, 0.30)))

        var rawStages = Array(repeating: 2, count: n)
        for idx in 0..<n {
            let frac = Double(idx) / Double(max(1, n - 1))
            let m = grid.motion[idx]
            let h = grid.hr[idx]
            let v = grid.hrv[idx]
            let edge = idx < 6 || idx + 6 >= n

            let lo = max(0, idx - 3), hi = min(n, idx + 4)
            let hrs = (lo..<hi).compactMap { grid.hr[$0] }
            let hrStd: Double = {
                guard hrs.count >= 3 else { return 1.5 }
                let mean = hrs.reduce(0, +) / Double(hrs.count)
                return (hrs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(hrs.count)).squareRoot()
            }()

            if m >= wakeMotion || (edge && m > quietMotion) || ((h ?? 0) >= hrQ85 + 2.0 && m > quietMotion) {
                rawStages[idx] = 4
                continue
            }
            let cyclePhase = sin(2.0 * .pi * (spanS * frac / 5400.0 - 0.25))
            if frac >= 0.12 && m <= quietMotion * 1.5 && (hrStd >= 2.0 || (cyclePhase > 0.35 && (h ?? hrQ65) >= hrQ35)) {
                if let v, v >= hrvQ65 && (h ?? hrQ65) > hrQ35 {
                    rawStages[idx] = 3
                    continue
                } else if hrStd >= 2.2 && frac >= 0.20 {
                    rawStages[idx] = 3
                    continue
                }
            }
            if frac <= 0.72 && m <= quietMotion && (h ?? (hrQ35 + 1.0)) <= hrQ35 + 0.5 && hrStd <= 2.5 {
                if (v ?? hrvQ35) >= hrvQ35 * 0.85 {
                    rawStages[idx] = 1
                    continue
                }
            }
            rawStages[idx] = 2
        }
        let smoothed = smooth(rawStages, 5)
        return refineDeepStages(stages: smoothed, night: night)
    }
}

extension Summary {
    /// iOS stages sleep on-device after the shared JSON is built. Rebuild the same
    /// Android-compatible 14-day result after staging, grouping main sleep + naps by
    /// wake date. The web receives this exact shape directly from `oura-summary`.
    func stagedSleepDebt() -> SleepDebtSummary? {
        let defaultNeedS = 8.0 * 3600.0
        var byDay: [String: Double] = [:]
        var incompleteDays = Set<String>()
        for n in nights {
            guard let day = wakeYmd(n) else { continue }
            guard n.stagingComplete else { incompleteDays.insert(day); continue }
            let actual = Double(Sleep.asleepS(Sleep.smooth(n.hypnogram ?? [], 5),
                                              inBedS: n.durationS))
            if actual > 0 { byDay[day, default: 0] += actual }
        }
        byDay = byDay.filter { !incompleteDays.contains($0.key) }
        guard let anchor = byDay.keys.max() else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let fmt = DateFormatter()
        fmt.calendar = cal; fmt.timeZone = cal.timeZone; fmt.dateFormat = "yyyy-MM-dd"
        guard let anchorDate = fmt.date(from: anchor) else { return nil }

        func date(_ offset: Int, from base: Date) -> String {
            fmt.string(from: cal.date(byAdding: .day, value: offset, to: base)!)
        }
        // Personalized daily need — the mirror of oura-summary's `sleep_need_s`
        // (typical sleep over the last 90 days, IQR-filtered, clamped to 7–9 h,
        // causal so a night never sets its own need). Keep the two in sync.
        func needS(on day: Date) -> Double {
            var vals: [Double] = (1...90).compactMap { byDay[date(-$0, from: day)] }.filter { $0 > 0 }
            guard vals.count >= 14 else { return defaultNeedS }
            vals.sort()
            func quantile(_ p: Double) -> Double {
                let idx = p * Double(vals.count - 1)
                let lo = Int(idx.rounded(.down)), hi = Int(idx.rounded(.up))
                return vals[lo] + (vals[hi] - vals[lo]) * (idx - Double(lo))
            }
            let q1 = quantile(0.25), q3 = quantile(0.75), fence = 1.5 * (q3 - q1)
            let kept = vals.filter { $0 >= q1 - fence && $0 <= q3 + fence }
            let mean = kept.reduce(0, +) / Double(kept.count)
            return (min(max(mean, 7 * 3600), 9 * 3600) / 900).rounded() * 900
        }
        func score(ending end: Date) -> (debt: Double, recent: Double, valid: Bool, count: Int) {
            let actual = (0..<14).map { byDay[date(-$0, from: end)] ?? 0 }
            let needs = (0..<14).map { needS(on: cal.date(byAdding: .day, value: -$0, to: end)!) }
            let count = actual.filter { $0 > 0 }.count
            guard actual[0] > 0 else { return (0, 0, false, count) }
            let decay = 0.75 / 13.0
            var debt = 0.0
            for i in actual.indices where actual[i] > 0 {
                debt += (1.0 - decay * Double(i)) * (needs[i] - actual[i])
            }
            debt = min(max(debt, 0), 36_000)
            debt = (debt / 2700).rounded() * 2700
            return (debt, needs[0] - actual[0], count >= 5, count)
        }
        let days: [SleepDebtDay] = (-13...0).map { offset in
            let d = cal.date(byAdding: .day, value: offset, to: anchorDate)!
            let key = fmt.string(from: d), total = byDay[key]
            let need = needS(on: d)
            let result = score(ending: d)
            return SleepDebtDay(date: key, total_sleep_min: total.map { ($0 / 60).rounded() },
                                sleep_need_min: (need / 60).rounded(),
                                shortfall_min: total.map { ((need - $0) / 60).rounded() },
                                cumulative_debt_min: result.valid ? (result.debt / 60).rounded() : nil,
                                valid_days: result.count)
        }
        let current = score(ending: anchorDate)
        let minutes = current.valid ? (current.debt / 60).rounded() : 0
        let state = minutes >= 540 ? "high" : minutes >= 360 ? "moderate" : minutes >= 180 ? "low" : "none"
        return SleepDebtSummary(debt_min: minutes,
                                recent_shortfall_min: current.valid ? (current.recent / 60).rounded() : 0,
                                valid: current.valid,
                                need_h: (needS(on: anchorDate) / 36).rounded() / 100,
                                valid_days: current.count,
                                window_days: 14, state: state, days: days)
    }
}

// ── research-grade primitives ────────────────────────────────────────────────
// A section rule: a hairline with a small all-caps mono label riding it.
struct Rule: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(spacing: 10) {
            Text(text.uppercased()).font(Obs.mono(10, .medium)).tracking(2).foregroundStyle(Obs.ink2)
            Rectangle().fill(Obs.trace.opacity(0.5)).frame(height: 0.5)
        }
    }
}

// A big mono datum with a tiny uppercase caption — the readout atom.
struct Readout: View {
    let value: String
    let caption: String
    var accent: Color = Obs.ink
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(Obs.mono(20, .medium)).foregroundStyle(accent).monospacedDigit()
            Text(caption.uppercased()).font(Obs.mono(9)).tracking(1.2).foregroundStyle(Obs.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// ── the polysomnograph: hypnogram + aligned signal lanes + a touch scrubber ──
struct Polysomnograph: View {
    let night: NightRow
    @State private var cursorF: Double? = nil
    private let gutterW: CGFloat = 76
    private let hypH: CGFloat = 84
    private let laneH: CGFloat = 44
    private let axisH: CGFloat = 18

    private struct Lane { let label: String; let unit: String; let signal: SignalLane?; let stages: [Int]? }
    private struct SignalLane {
        let v: [Double]
        let color: Color
        let dp: Int
        let span: [Double]
        var times: [Double]? = nil
        var timed: [Sleep.TimedSample]? = nil
    }

    private var lanes: [Lane] {
        var out: [Lane] = []
        if let st = night.hypnogram, st.count > 1 { out.append(Lane(label: "Hypnogram", unit: "", signal: nil, stages: Sleep.smooth(st, 5))) }
        func sig(_ label: String, _ unit: String, _ v: [Double]?, _ color: Color,
                 _ dp: Int = 0, span: [Double]? = nil, times: [Double]? = nil,
                 rawTimed: [[Double]]? = nil) {
            if let timed = Sleep.timedSamples(rawTimed, startUnix: night.start_unix, endUnix: night.end_unix),
               timed.count > 1 {
                let vals = timed.map(\.value)
                let coverage = [timed.first!.fraction, timed.last!.fraction]
                out.append(Lane(label: label, unit: unit,
                                signal: SignalLane(v: vals, color: color, dp: dp,
                                                   span: coverage, timed: timed), stages: nil))
                return
            }
            guard let v, v.count > 1 else { return }
            let coverage = span.flatMap { $0.count == 2 ? $0 : nil } ?? [0, 1]
            out.append(Lane(label: label, unit: unit,
                            signal: SignalLane(v: v, color: color, dp: dp,
                                               span: coverage, times: times), stages: nil))
        }
        let s = night.series
        let st = night.series_t
        sig("Heart rate", "bpm", s?.hr, Obs.chart, rawTimed: st?.hr)
        sig("HRV", "ms", s?.hrv, Obs.chart, rawTimed: st?.hrv)
        sig("Blood O₂", "%", s?.spo2, Obs.chart, rawTimed: st?.spo2)
        sig("Skin temp", "°C", s?.temp, Obs.chart, 1, span: s?.temp_span, rawTimed: st?.temp)
        // Prefer timestamped motion (`series_t.motion`), falling back to `series.motion_time`.
        // Legacy exports lost motion timestamps; do not invent their positions.
        if let timedMotion = Sleep.timedSamples(st?.motion, startUnix: night.start_unix, endUnix: night.end_unix),
           timedMotion.count > 1 {
            sig("Motion", "s", timedMotion.map(\.value), Obs.chart, times: timedMotion.map(\.fraction))
        } else if let times = s?.motion_time, times.count == s?.motion.count {
            sig("Motion", "s", s?.motion, Obs.chart, times: times)
        }
        return out
    }

    private var totalH: CGFloat {
        lanes.reduce(0) { $0 + ($1.stages != nil ? hypH : laneH) } + axisH
    }

    var body: some View {
        let win = nightWindow(night)
        GeometryReader { geo in
            let plotW = geo.size.width - gutterW
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(lanes.indices, id: \.self) { i in
                        laneRow(lanes[i], plotW: plotW)
                        if i < lanes.count - 1 { Rectangle().fill(Obs.trace.opacity(0.25)).frame(height: 0.5) }
                    }
                    axisRow(win, plotW: plotW)
                }
                if let f = cursorF {
                    Rectangle().fill(Obs.ink.opacity(0.85)).frame(width: 1, height: totalH - axisH)
                        .offset(x: gutterW + CGFloat(f) * plotW)
                        .allowsHitTesting(false)
                    Text(clockAt(win, f)).font(Obs.mono(10, .medium)).foregroundStyle(Obs.paper)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Obs.ink, in: RoundedRectangle(cornerRadius: 4))
                        .offset(x: gutterW + CGFloat(f) * plotW - 18, y: -2)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in cursorF = Double(max(0, min(1, (g.location.x - gutterW) / plotW))) }
                .onEnded { _ in cursorF = nil })
        }
        .frame(height: totalH)
    }

    @ViewBuilder private func laneRow(_ lane: Lane, plotW: CGFloat) -> some View {
        let h = lane.stages != nil ? hypH : laneH
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(lane.label).font(Obs.mono(10)).foregroundStyle(Obs.ink2)
                Text(gutterValue(lane)).font(Obs.mono(12, .medium)).foregroundStyle(Obs.ink).monospacedDigit()
            }
            .frame(width: gutterW, alignment: .leading)
            Group {
                if let st = lane.stages { HypnoCanvas(stages: st) }
                else if let s = lane.signal { SignalCanvas(v: s.v, color: s.color, span: s.span, times: s.times, timed: s.timed) }
            }
            .frame(width: plotW, height: h)
        }
        .frame(height: h)
    }

    private func gutterValue(_ lane: Lane) -> String {
        if let st = lane.stages {
            guard let f = cursorF else { return "" }
            let code = st[min(st.count - 1, max(0, Int(f * Double(st.count - 1))))]
            return stageName(code)
        }
        guard let s = lane.signal else { return "" }
        let fmt = { (x: Double) in s.dp > 0 ? String(format: "%.\(s.dp)f", x) : String(Int(x.rounded())) }
        if let f = cursorF {
            if let timed = s.timed {
                guard let val = Sleep.sampleAt(fraction: f, in: timed, durationSeconds: night.durationS) else { return "–" }
                return "\(fmt(val)) \(lane.unit)"
            }
            guard f >= s.span[0], f <= s.span[1] else { return "–" }
            if let times = s.times {
                guard let index = times.indices.min(by: { abs(times[$0] - f) < abs(times[$1] - f) }),
                      abs(times[index] - f) * night.durationS <= 30 else { return "–" }
                return "\(fmt(s.v[index])) \(lane.unit)"
            }
            let local = (f - s.span[0]) / max(1e-9, s.span[1] - s.span[0])
            let v = s.v[min(s.v.count - 1, max(0, Int(local * Double(s.v.count - 1))))]
            return "\(fmt(v)) \(lane.unit)"
        }
        let mean = s.v.reduce(0, +) / Double(s.v.count)
        return "\(fmt(mean)) \(lane.unit)"
    }

    private func axisRow(_ win: (a: Int, b: Int, span: Int), plotW: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutterW)
            GeometryReader { g in
                ForEach(hourTicks(win), id: \.self) { t in
                    Text(String(format: "%02d", (t % 1440) / 60))
                        .font(Obs.mono(9)).foregroundStyle(Obs.ink2)
                        .position(x: CGFloat(Double(t - win.a) / Double(win.span)) * g.size.width, y: 8)
                }
            }.frame(width: plotW, height: axisH)
        }
        .frame(height: axisH)
    }
}

// stepped clinical hypnogram: y = stage level (Awake top → Deep bottom), colored runs.
private struct HypnoCanvas: View {
    let stages: [Int]
    var body: some View {
        Canvas { ctx, size in
            let n = stages.count
            guard n > 1 else { return }
            let padT: CGFloat = 8, plotH = size.height - 16
            let lvl = { (c: Int) -> CGFloat in switch c { case 1: return 3; case 2: return 2; case 3: return 1; default: return 0 } }
            let yOf = { (l: CGFloat) in padT + l / 3 * plotH }
            let xOf = { (i: Int) in size.width * CGFloat(i) / CGFloat(n - 1) }
            for l in 0..<4 {
                let y = yOf(CGFloat(l))
                ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                           with: .color(Obs.trace.opacity(0.25)), lineWidth: 0.5)
            }
            var i = 0; var prev: CGFloat? = nil
            while i < n {
                let code = stages[i]
                if code == 0 { prev = nil; i += 1; continue }
                var j = i
                while j < n, stages[j] == code { j += 1 }
                let x1 = xOf(i), x2 = xOf(min(j, n - 1)), y = yOf(lvl(code))
                if let p = prev {
                    ctx.stroke(Path { $0.move(to: CGPoint(x: x1, y: p)); $0.addLine(to: CGPoint(x: x1, y: y)) },
                               with: .color(Obs.trace.opacity(0.6)), lineWidth: 0.8)
                }
                ctx.stroke(Path { $0.move(to: CGPoint(x: x1, y: y)); $0.addLine(to: CGPoint(x: x2, y: y)) },
                           with: .color(Obs.stage(code)), lineWidth: 2.2)
                prev = y; i = j
            }
        }
    }
}

// auto-scaled polyline + faint fill + dashed mean for one signal lane.
private struct SignalCanvas: View {
    let v: [Double]
    let color: Color
    let span: [Double]
    var times: [Double]? = nil
    var timed: [Sleep.TimedSample]? = nil
    var body: some View {
        Canvas { ctx, size in
            guard v.count > 1 else { return }
            if let times, times.count == v.count {
                let lo = min(0, v.min()!), hi = max(lo + 1, v.max()!)
                for i in v.indices {
                    let x = size.width * CGFloat(times[i])
                    let y = 5 + (1 - CGFloat((v[i] - lo) / (hi - lo))) * (size.height - 10)
                    ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: size.height - 5)); $0.addLine(to: CGPoint(x: x, y: y)) },
                               with: .color(color), lineWidth: 1.5)
                }
                return
            }
            let lo = v.min()!, hi = v.max()!, rng = max(hi - lo, 1e-6)
            let pad: CGFloat = 5
            if let timed, timed.count > 1 {
                func pt(_ s: Sleep.TimedSample) -> CGPoint {
                    CGPoint(x: size.width * CGFloat(s.fraction),
                            y: pad + (1 - CGFloat((s.value - lo) / rng)) * (size.height - 2 * pad))
                }
                for seg in Sleep.contiguousSegments(timed) {
                    var line = Path()
                    let first = pt(seg[0])
                    line.move(to: first)
                    if seg.count == 1 {
                        let endX = min(size.width, first.x + 1.5)
                        line.addLine(to: CGPoint(x: endX, y: first.y))
                        var area = line
                        area.addLine(to: CGPoint(x: endX, y: size.height))
                        area.addLine(to: CGPoint(x: first.x, y: size.height))
                        area.closeSubpath()
                        ctx.fill(area, with: .color(color.opacity(0.10)))
                    } else {
                        for sample in seg.dropFirst() { line.addLine(to: pt(sample)) }
                        let last = pt(seg.last!)
                        var area = line
                        area.addLine(to: CGPoint(x: last.x, y: size.height))
                        area.addLine(to: CGPoint(x: first.x, y: size.height))
                        area.closeSubpath()
                        ctx.fill(area, with: .color(color.opacity(0.10)))
                    }
                    ctx.stroke(line, with: .color(color), lineWidth: 1.3)
                }
                let x0 = size.width * CGFloat(timed.first!.fraction)
                let x1 = size.width * CGFloat(timed.last!.fraction)
                let mean = v.reduce(0, +) / Double(v.count)
                let my = pad + (1 - CGFloat((mean - lo) / rng)) * (size.height - 2 * pad)
                ctx.stroke(Path { $0.move(to: CGPoint(x: x0, y: my)); $0.addLine(to: CGPoint(x: x1, y: my)) },
                           with: .color(color.opacity(0.4)), style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
                return
            }
            func pt(_ i: Int) -> CGPoint {
                CGPoint(x: size.width * CGFloat(span[0] + (span[1] - span[0]) * Double(i) / Double(v.count - 1)),
                        y: pad + (1 - CGFloat((v[i] - lo) / rng)) * (size.height - 2 * pad))
            }
            var line = Path(); line.move(to: pt(0)); for i in 1..<v.count { line.addLine(to: pt(i)) }
            let x0 = size.width * CGFloat(span[0]), x1 = size.width * CGFloat(span[1])
            var area = line; area.addLine(to: CGPoint(x: x1, y: size.height)); area.addLine(to: CGPoint(x: x0, y: size.height)); area.closeSubpath()
            ctx.fill(area, with: .color(color.opacity(0.10)))
            let mean = v.reduce(0, +) / Double(v.count)
            let my = pad + (1 - CGFloat((mean - lo) / rng)) * (size.height - 2 * pad)
            ctx.stroke(Path { $0.move(to: CGPoint(x: x0, y: my)); $0.addLine(to: CGPoint(x: x1, y: my)) },
                       with: .color(color.opacity(0.4)), style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
            ctx.stroke(line, with: .color(color), lineWidth: 1.3)
        }
    }
}

// stage-proportion bar (Deep/Light/REM/Awake)
private struct StageBar: View {
    let n: NightRow
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach([(1, n.deep_pct), (2, n.light_pct), (3, n.rem_pct), (4, n.wake_pct)], id: \.0) { code, pct in
                    Rectangle().fill(Obs.stage(code)).frame(width: geo.size.width * CGFloat((pct ?? 0) / 100))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 10).clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

// ── time helpers ─────────────────────────────────────────────────────────────
private func hm2min(_ s: String?) -> Int { let p = (s ?? "0:0").split(separator: ":").map { Int($0) ?? 0 }; return (p.first ?? 0) * 60 + (p.count > 1 ? p[1] : 0) }
private func nightWindow(_ n: NightRow) -> (a: Int, b: Int, span: Int) {
    let a = hm2min(n.start); var b = hm2min(n.end); if b <= a { b += 1440 }
    return (a, b, max(1, b - a))
}
private func clockAt(_ win: (a: Int, b: Int, span: Int), _ f: Double) -> String {
    let t = (win.a + Int((Double(win.span) * f).rounded())) % 1440
    return String(format: "%02d:%02d", t / 60, t % 60)
}
private func hourTicks(_ win: (a: Int, b: Int, span: Int)) -> [Int] {
    var t = ((win.a + 59) / 60) * 60; var out: [Int] = []
    while t <= win.b { out.append(t); t += 60 }
    return out
}
private func stageName(_ c: Int) -> String { switch c { case 1: return "Deep"; case 2: return "Light"; case 3: return "REM"; case 4: return "Awake"; default: return "No data" } }

private func debtDuration(_ minutes: Double) -> String {
    let m = max(0, Int(minutes.rounded()))
    return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
}

private func debtStateCopy(_ state: String) -> String {
    switch state {
    case "high": return "Your sleep debt is high right now. Prioritize several consistent nights with enough sleep."
    case "moderate": return "You’ve built up a moderate amount of sleep debt. A few longer nights can help you recover."
    case "low": return "You’re mostly meeting your sleep need, with a small amount left to recover."
    default: return "You’ve met your sleep need consistently over the past two weeks."
    }
}

struct SleepDebtCard: View {
    let debt: SleepDebtSummary
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ObsTag("sleep debt", icon: "moon.zzz.fill")
                    Spacer()
                    Text("past \(debt.window_days) days").font(Obs.mono(10)).foregroundStyle(Obs.ink2)
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Obs.trace)
                }
                if debt.valid {
                    HStack(alignment: .firstTextBaseline) {
                        Text(debtDuration(debt.debt_min)).font(Obs.mono(26, .medium)).foregroundStyle(Obs.debt(debt.state))
                        Text(debt.state).font(Obs.mono(11, .medium)).foregroundStyle(Obs.debt(debt.state)).textCase(.uppercase)
                    }
                    Text(debtStateCopy(debt.state)).font(Obs.prose(14)).foregroundStyle(Obs.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("\(debt.valid_days) of 5 nights").font(Obs.mono(14, .medium)).foregroundStyle(Obs.ink2)
                    Text("Needs 5 nights of sleep in the past 2 weeks.")
                        .font(Obs.mono(11)).foregroundStyle(Obs.muted)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// A readable summary first; personal ranges are available on demand.
/// The literature-based sleep score, with its components opened up.
///
/// The number matters less than the breakdown: every component names the paper its
/// thresholds came from, so a bad score can be argued with rather than believed.
struct SleepScoreCard: View {
    let score: SleepScore
    var breathRate: Double? = nil
    @State private var expanded = false

    private var tint: Color {
        switch score.score {
        case 85...: return Obs.good
        case 70..<85: return Obs.chart
        default: return Obs.bad
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(Int(score.score))")
                    .font(Obs.mono(38, .medium)).foregroundStyle(tint).monospacedDigit()
                VStack(alignment: .leading, spacing: 2) {
                    Text("/ 100").font(Obs.mono(12)).foregroundStyle(Obs.ink2)
                    Text(score.basis ?? "published norms")
                        .font(Obs.mono(9)).foregroundStyle(Obs.muted)
                }
                Spacer()
                if let breathRate {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.1f", breathRate))
                            .font(Obs.mono(15, .medium)).foregroundStyle(Obs.ink).monospacedDigit()
                        Text("br/min").font(Obs.mono(9)).foregroundStyle(Obs.muted)
                    }
                }
            }

            ForEach(score.components) { component in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(component.label).font(Obs.mono(11)).foregroundStyle(Obs.ink2)
                        Spacer()
                        Text("\(Int(component.score))")
                            .font(Obs.mono(11, .medium)).foregroundStyle(Obs.ink).monospacedDigit()
                    }
                    // bar width is the component score; opacity is how much it counted
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Obs.rule).frame(height: 3)
                            Rectangle()
                                .fill(Obs.chart.opacity(0.35 + 0.65 * min(1, component.weight * 3)))
                                .frame(width: geo.size.width * component.score / 100, height: 3)
                        }
                    }
                    .frame(height: 3)
                    if expanded, let source = component.source {
                        Text(source).font(Obs.mono(9)).foregroundStyle(Obs.muted)
                    }
                }
            }

            Button { expanded.toggle() } label: {
                Text(expanded ? "hide sources" : "show sources")
                    .font(Obs.mono(10)).foregroundStyle(Obs.ink2)
            }
            .buttonStyle(.plain)
        }
        .obsCard()
    }
}

struct IllnessCard: View {
    let illness: IllnessResult
    @State private var showDetails = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let names = [
        "AverageBreath": "Breathing rate", "LowestHeartRate": "Lowest heart rate",
        "AverageHrv": "Heart rate variability", "TemperatureDeviation": "Temperature change",
    ]
    private static let units = [
        "AverageBreath": "br/min", "LowestHeartRate": "bpm", "AverageHrv": "ms", "TemperatureDeviation": "°C",
    ]
    private static let order = ["AverageBreath", "LowestHeartRate", "AverageHrv", "TemperatureDeviation"]
    private var tint: Color {
        switch illness.trafficLight {
        case "NO_SIGNS": return Obs.good
        case "MINOR_SIGNS": return Obs.bad
        case "MAJOR_SIGNS": return Obs.alert
        default: return Obs.muted
        }
    }
    private var status: String {
        switch illness.trafficLight {
        case "NO_SIGNS": return "No signs"
        case "MINOR_SIGNS": return "Minor signs"
        case "MAJOR_SIGNS": return "Major signs"
        default: return "No result yet"
        }
    }
    private var explanation: String {
        switch illness.status {
        case "NO_SIGNS":
            // The decision comes from the model's overall score, not a count of flags:
            // a night can have biometrics out of range and still not add up to strain.
            let flagged = illness.biomarkers.filter(\.indicatesSymptoms).count
            return flagged == 0
                ? "Your overnight biometrics are within their usual ranges."
                : "\(flagged == 1 ? "One overnight biometric is" : "\(flagged) overnight biometrics are") outside your usual range, but together they don’t match the pattern of your body fighting something."
        case "MINOR_SIGNS": return "Some overnight biometrics are outside your usual ranges."
        case "MAJOR_SIGNS": return "Several overnight biometrics are outside your usual ranges."
        case "MISSING_LAST_NIGHT_SLEEP": return "Wear your ring overnight, then sync to see your latest result."
        default: return "Your radar needs at least 7 nights of data from the last 14 days."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                ObsTag("symptom radar", icon: "waveform.path.ecg")
                Spacer(minLength: 12)
                Text(illness.date).font(Obs.mono(10)).foregroundStyle(Obs.ink2)
            }
            VStack(alignment: .leading, spacing: 8) {
                Label(illness.available ? status : "Getting to know you",
                      systemImage: illness.available ? (illness.trafficLight == "NO_SIGNS" ? "checkmark.circle" : "waveform.path.ecg") : "moon")
                    .font(Obs.mono(18, .medium))
                    .foregroundStyle(illness.available ? tint : Obs.ink2)
                Text(explanation).font(Obs.prose(14)).foregroundStyle(Obs.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if illness.available {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        showDetails.toggle()
                    }
                } label: {
                    HStack {
                        Text(showDetails ? "Hide details" : "View details")
                        Spacer()
                        Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .font(Obs.mono(12, .medium))
                    .foregroundStyle(Obs.ink)
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(showDetails ? "Expanded" : "Collapsed")
                .accessibilityHint("Shows overnight measurements and personal ranges")
            }
            if illness.available && showDetails {
                Rectangle().fill(Obs.rule).frame(height: 1)
                Text("Overnight measurements")
                    .font(.subheadline.weight(.medium)).foregroundStyle(Obs.ink)
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Self.order, id: \.self) { type in
                        if let biomarker = illness.biomarkers.first(where: { $0.type == type }) {
                            BiomarkerRow(name: Self.names[type] ?? type,
                                         unit: Self.units[type] ?? "", biomarker: biomarker)
                        }
                    }
                }
                if illness.biomarkers.isEmpty {
                    Text("Measurement details aren’t available for this result.")
                        .font(.subheadline).foregroundStyle(Obs.muted)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Based on \(illness.daysWithData) nights in the past 30 days")
                        .font(.caption).foregroundStyle(Obs.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BiomarkerRow: View {
    let name: String
    let unit: String
    let biomarker: IllnessBiomarker
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var change: String {
        switch biomarker.reason {
        case "ELEVATED": return "Above usual"
        case "DECREASED": return "Below usual"
        default: return "Outside usual range"
        }
    }
    private func formatted(_ value: Double) -> String {
        guard value.isFinite else { return "–" }
        return unit == "°C"
            ? value.formatted(.number.precision(.fractionLength(1)))
            : value.formatted(.number.precision(.fractionLength(0...1)))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
            layout {
                Text(name).font(.subheadline).foregroundStyle(Obs.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                Text("\(formatted(biomarker.value)) \(unit)")
                    .font(.subheadline.weight(.medium)).monospacedDigit()
                    .foregroundStyle(biomarker.indicatesSymptoms ? Obs.alert : Obs.ink)
                    .fixedSize()
            }
            if biomarker.indicatesSymptoms {
                Text(change).font(.caption).foregroundStyle(Obs.alert)
            }
            if biomarker.lower.isFinite && biomarker.upper.isFinite && biomarker.lower <= biomarker.upper {
                Text("Personal range: \(formatted(biomarker.lower)) to \(formatted(biomarker.upper)) \(unit)")
                    .font(.caption).foregroundStyle(Obs.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Personal range unavailable").font(.caption).foregroundStyle(Obs.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private enum DebtGraph: String, CaseIterable { case debt = "Cumulative debt", sleep = "Total sleep" }

private struct SleepDebtChart: View {
    let debt: SleepDebtSummary
    let mode: DebtGraph
    var body: some View {
        VStack(spacing: 8) {
            Canvas { context, size in
                let values: [Double?] = debt.days.map {
                    mode == .debt ? $0.cumulative_debt_min : $0.total_sleep_min
                }
                let maxValue = mode == .debt ? 600.0 : max(720, values.compactMap { $0 }.max() ?? 0)
                let x = { (i: Int) in CGFloat(i) / CGFloat(max(1, values.count - 1)) * size.width }
                let y = { (v: Double) in size.height - CGFloat(min(max(v / maxValue, 0), 1)) * size.height }
                for fraction in [0.25, 0.5, 0.75] {
                    var grid = Path(); let yy = size.height * CGFloat(1 - fraction)
                    grid.move(to: CGPoint(x: 0, y: yy)); grid.addLine(to: CGPoint(x: size.width, y: yy))
                    context.stroke(grid, with: .color(Obs.trace.opacity(0.35)), lineWidth: 0.5)
                }
                if mode == .sleep {
                    var need = Path(); let yy = y(debt.need_h * 60)
                    need.move(to: CGPoint(x: 0, y: yy)); need.addLine(to: CGPoint(x: size.width, y: yy))
                    context.stroke(need, with: .color(Obs.ink.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                var line = Path(), started = false
                for (i, value) in values.enumerated() {
                    guard let value else { started = false; continue }
                    let point = CGPoint(x: x(i), y: y(value))
                    if started { line.addLine(to: point) } else { line.move(to: point); started = true }
                }
                context.stroke(line, with: .color(Obs.chart), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            .frame(height: 180)
            HStack {
                Text(debt.days.first.map { String($0.date.suffix(5)) } ?? "").font(Obs.mono(10)).foregroundStyle(Obs.ink2)
                Spacer()
                if mode == .sleep {
                    HStack(spacing: 5) { Rectangle().fill(Obs.ink.opacity(0.45)).frame(width: 16, height: 1); Text("sleep need").font(Obs.mono(10)).foregroundStyle(Obs.ink2) }
                }
                Spacer()
                Text(debt.days.last.map { String($0.date.suffix(5)) } ?? "").font(Obs.mono(10)).foregroundStyle(Obs.ink2)
            }
        }
    }
}

struct SleepDebtDetail: View {
    let debt: SleepDebtSummary
    @Environment(\.dismiss) private var dismiss
    @State private var graph = DebtGraph.debt
    var body: some View {
        NavigationStack {
            ZStack {
                Obs.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if debt.valid {
                            Text(debtDuration(debt.debt_min)).font(Obs.mono(34, .medium)).foregroundStyle(Obs.debt(debt.state))
                            Text(debtStateCopy(debt.state)).font(Obs.prose(16)).foregroundStyle(Obs.ink2)
                        } else {
                            Text("Not enough data yet").font(Obs.prose(22, .semibold)).foregroundStyle(Obs.ink)
                            Text("\(debt.valid_days) of 5 sleep days available within the past 2 weeks.")
                                .font(Obs.mono(12)).foregroundStyle(Obs.ink2)
                        }
                        Picker("Graph", selection: $graph) {
                            ForEach(DebtGraph.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented)
                        SleepDebtChart(debt: debt, mode: graph)
                        Rule("how it works")
                        Text("Sleep debt estimates missed sleep over the past 14 days. Total sleep combines main sleep and naps, recent days carry more weight, and your sleep need (\(debtDuration(debt.need_h * 60))) is personalized from your typical sleep over the past 3 months, ignoring unusually short or long days.")
                            .font(Obs.prose(14)).foregroundStyle(Obs.ink2).fixedSize(horizontal: false, vertical: true)
                    }.padding(24)
                }
            }
            .navigationTitle("sleep debt").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

// ── the full-page report (sleep ⇄ activity) ──────────────────────────────────
struct DayAnalysisContext {
    var summary: Summary?
    var isBusy: Bool
    var refresh: (DayAnalysisRequest) async -> String?
}

private struct DayAnalysisContextKey: EnvironmentKey {
    static let defaultValue: DayAnalysisContext? = nil
}

extension EnvironmentValues {
    var dayAnalysis: DayAnalysisContext? {
        get { self[DayAnalysisContextKey.self] }
        set { self[DayAnalysisContextKey.self] = newValue }
    }
}

struct DayReportView: View {
    let s: Summary
    let day: String
    @State var tab: Tab
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dayAnalysis) private var analysis
    @State private var refreshing: Tab?
    @State private var refreshMessages: [String: String] = [:]
    @State private var exportFile: URL?
    @State private var exportNote: String?
    @State private var autoRefreshedDays: Set<String> = []
    typealias Tab = DayAnalysisKind

    var body: some View {
        ZStack {
            Obs.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Obs.ink2)
                            .frame(width: 34, height: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                    Text(day).font(Obs.mono(13, .medium)).foregroundStyle(Obs.ink)
                        .lineLimit(1).fixedSize()
                    Spacer(minLength: 6)
                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).fixedSize()
                    if let analysis { refreshButton(analysis) }
                    exportMenu
                }
                .padding(.leading, 12).padding(.trailing, 14).padding(.vertical, 10)
                .overlay(alignment: .bottom) { Rectangle().fill(Obs.trace.opacity(0.3)).frame(height: 0.5) }

                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        if let analysis, let note = refreshNote(analysis) {
                            Text(note)
                                .font(.footnote).foregroundStyle(Obs.muted)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.updatesFrequently)
                        }
                        if tab == .sleep { SleepReport(s: analysis?.summary ?? s, day: day) }
                        else { ActivityReport(s: analysis?.summary ?? s, day: day) }
                    }
                    .padding(20).padding(.bottom, 60)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: Binding(get: { exportFile != nil }, set: { if !$0 { exportFile = nil } })) {
            if let exportFile { DiagnosticsShare(url: exportFile) }
        }
        .task(id: "\(day)-\(tab.rawValue)") {
            guard tab == .sleep,
                  !autoRefreshedDays.contains(day),
                  let analysis,
                  !analysis.isBusy,
                  refreshing == nil,
                  let n = (analysis.summary ?? s).night(forDay: day),
                  !n.hasHypnogram,
                  n.hasSignals else { return }
            autoRefreshedDays.insert(day)
            refreshing = .sleep
            let error = await analysis.refresh(DayAnalysisRequest(day: day, kind: .sleep))
            if let error { refreshMessages[Tab.sleep.rawValue] = error }
            refreshing = nil
        }
    }

    /// Rerun the selected analysis for this day. Lives in the header as an icon so the
    /// report itself starts right under the title.
    private func refreshButton(_ analysis: DayAnalysisContext) -> some View {
        Button {
            let selected = tab
            refreshing = selected
            refreshMessages[selected.rawValue] = nil
            Task {
                let error = await analysis.refresh(DayAnalysisRequest(day: day, kind: selected))
                refreshMessages[selected.rawValue] = error ?? "Analysis updated."
                refreshing = nil
            }
        } label: {
            Group {
                if refreshing == tab { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .medium)) }
            }
            .foregroundStyle(Obs.ink2)
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(refreshing != nil || analysis.isBusy)
        .opacity(analysis.isBusy && refreshing == nil ? 0.4 : 1)
        .accessibilityLabel(refreshing == tab ? "Refreshing \(tab.rawValue.lowercased()) analysis"
                            : "Refresh \(tab.rawValue.lowercased()) analysis")
    }

    /// Only shown while a refresh runs or right after one, so the report keeps its space.
    private func refreshNote(_ analysis: DayAnalysisContext) -> String? {
        if let message = refreshMessages[tab.rawValue] { return message }
        if refreshing == tab { return "Keep the app open while analysis runs." }
        return nil
    }

    /// The day's data as JSON — copy for a quick paste, or share as a file. Built off
    /// the main thread: a night carries its full signal series.
    private var exportMenu: some View {
        Menu {
            Button { export(share: false) } label: { Label("Copy JSON", systemImage: "doc.on.doc") }
            Button { export(share: true) } label: { Label("Share JSON…", systemImage: "square.and.arrow.up") }
        } label: {
            Image(systemName: exportNote == nil ? "square.and.arrow.up" : "checkmark")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Obs.ink2)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityLabel(exportNote ?? "Export \(tab.rawValue.lowercased()) data as JSON")
    }

    private func export(share: Bool) {
        let summary = analysis?.summary ?? s
        let selected = tab
        Task {
            let payload = DayExport(summary: summary, day: day, kind: selected)
            let result: Result<URL?, Error> = await Task.detached {
                Result {
                    if payload.isEmpty { return nil }
                    if share { return try payload.writeTemporaryFile() }
                    DayExport.copyToPasteboard(try payload.json())
                    return nil
                }
            }.value
            switch result {
            case .success(let url):
                if payload.isEmpty { exportNote = "Nothing to export for this day."; refreshMessages[selected.rawValue] = exportNote }
                else if let url { exportFile = url }
                else { exportNote = "Copied" }
            case .failure(let error):
                dlog("export", "day \(day) \(selected.rawValue): \(error)")
                refreshMessages[selected.rawValue] = "Couldn’t build the JSON export."
            }
            if exportNote != nil {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                exportNote = nil
            }
        }
    }
}

struct SleepReport: View {
    let s: Summary
    let day: String
    @Environment(\.dayAnalysis) private var analysis
    @State private var editingBedtime = false
    @State private var bedtimeDate = Date()
    @State private var wakeupDate = Date()
    @State private var savingBedtime = false

    private static func dateFromHM(_ hm: String?) -> Date {
        let parts = (hm ?? "23:00").split(separator: ":").compactMap { Int($0) }
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = parts.first ?? 23
        comps.minute = parts.count > 1 ? parts[1] : 0
        return Calendar.current.date(from: comps) ?? Date()
    }

    private static func hmFromDate(_ date: Date) -> String {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
    }

    var body: some View {
        if let n = s.night(forDay: day) {
            let metrics = (n.hypnogram.flatMap { st in Sleep.metrics(Sleep.smooth(st, 5), inBedS: n.durationS) })
            let asleepH = metrics.map { $0.asleepMin / 60 }

            // summary strip
            HStack(alignment: .top, spacing: 0) {
                Readout(value: n.in_bed_h.map { String(format: "%.1f h", $0) } ?? "–", caption: "in bed")
                Readout(value: asleepH.map { String(format: "%.1f h", $0) } ?? "–", caption: "asleep")
                Readout(value: n.efficiency.map { "\(Int($0))%" } ?? "–", caption: "efficiency")
                Button {
                    bedtimeDate = Self.dateFromHM(n.start)
                    wakeupDate = Self.dateFromHM(n.end)
                    editingBedtime.toggle()
                } label: {
                    Readout(value: "\(n.start ?? "–")–\(n.end ?? "–")",
                            caption: n.isBedtimeManual ? "bedtime · edited" : "bedtime · adjust",
                            accent: editingBedtime ? Obs.chart : Obs.ink)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Adjust bedtime and wake-up time")
            }

            if editingBedtime {
                bedtimeEditor(n)
            }

            if let score = n.sleep_score {
                Rule("sleep score")
                SleepScoreCard(score: score, breathRate: n.breath_rate)
            }

            if n.hasHypnogram {
                if !n.stagingComplete && n.hasHypnogram {
                    Text("Incomplete sleep analysis. Gaps mean no data, not awake time; sleep metrics are withheld.")
                        .font(Obs.mono(11)).foregroundStyle(Obs.ink2)
                }
                Rule("Sleep stages & signals")
                stageLegend
                Polysomnograph(night: n)

                Rule("Sleep stages")
                StageBar(n: n)
                HStack(spacing: 16) {
                    ForEach([("Deep", n.deep_pct), ("Light", n.light_pct), ("REM", n.rem_pct), ("Awake", n.wake_pct)], id: \.0) { name, pct in
                        Text(name).font(Obs.mono(11)).foregroundStyle(Obs.ink2)
                            + Text(" \(Int(pct ?? 0))%").font(Obs.mono(11, .medium)).foregroundStyle(Obs.ink)
                    }
                }
                if let m = metrics { clinicalGrid(m) }

                let auto = Sleep.autonomic(night: n,
                                           stages: Sleep.smooth(n.hypnogram ?? [], 5))
                if auto.any {
                    Rule("HR & HRV by stage")
                    autonomicGrid(auto)
                }

                Rule("Sleep summary")
                if n.stagingComplete { interpretation(n, metrics) }
            } else {
                // model-free build: signals only, no hypnogram
                if hasAnySeries(n) {
                    Rule("overnight signals")
                    Polysomnograph(night: n)
                }
                Text("Sleep analysis is not available for this night yet.")
                    .font(Obs.mono(12)).foregroundStyle(Obs.ink2).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("No sleep recorded for this night.").font(Obs.mono(13)).foregroundStyle(Obs.ink2)
        }
    }

    @ViewBuilder private func bedtimeEditor(_ n: NightRow) -> some View {
        let nightKey = n.date ?? day
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Text("BEDTIME").font(Obs.mono(9)).tracking(1.1).foregroundStyle(Obs.ink2)
                    DatePicker("Bedtime", selection: $bedtimeDate, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .disabled(savingBedtime)
                }
                HStack(spacing: 6) {
                    Text("WAKE-UP").font(Obs.mono(9)).tracking(1.1).foregroundStyle(Obs.ink2)
                    DatePicker("Wake-up", selection: $wakeupDate, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .disabled(savingBedtime)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                Button {
                    let startHM = Self.hmFromDate(bedtimeDate)
                    let endHM = Self.hmFromDate(wakeupDate)
                    savingBedtime = true
                    Task {
                        try? BedtimeOverrideStore.set(startHM: startHM, endHM: endHM, forNightKey: nightKey)
                        _ = await analysis?.refresh(DayAnalysisRequest(day: day, kind: .sleep))
                        savingBedtime = false
                        editingBedtime = false
                    }
                } label: {
                    Text(savingBedtime ? "saving…" : "apply")
                        .font(Obs.mono(11, .medium))
                        .foregroundStyle(Obs.paper)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Obs.ink, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .disabled(savingBedtime)

                if n.isBedtimeManual || n.raw_start != nil {
                    Button {
                        savingBedtime = true
                        Task {
                            try? BedtimeOverrideStore.clear(forNightKey: nightKey)
                            _ = await analysis?.refresh(DayAnalysisRequest(day: day, kind: .sleep))
                            savingBedtime = false
                            editingBedtime = false
                        }
                    } label: {
                        Text("reset\(n.raw_start.map { " (\($0)–\(n.raw_end ?? ""))" } ?? "")")
                            .font(Obs.mono(11))
                            .foregroundStyle(Obs.ink2)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Obs.trace.opacity(0.6), lineWidth: 0.8))
                    }
                    .buttonStyle(.plain)
                    .disabled(savingBedtime)
                }

                Button {
                    editingBedtime = false
                } label: {
                    Text("cancel").font(Obs.mono(11)).foregroundStyle(Obs.muted)
                }
                .buttonStyle(.plain)
                .disabled(savingBedtime)
            }
        }
        .padding(12)
        .background(Obs.paper.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Obs.trace.opacity(0.45), lineWidth: 0.6))
    }

    private var stageLegend: some View {
        HStack(spacing: 16) {
            ForEach([(1, "Deep"), (2, "Light"), (3, "REM"), (4, "Awake")], id: \.0) { code, name in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(Obs.stage(code)).frame(width: 9, height: 9)
                    Text(name).font(Obs.mono(11)).foregroundStyle(Obs.ink2)
                }
            }
        }
    }

    private func hasAnySeries(_ n: NightRow) -> Bool {
        if let st = n.series_t,
           [st.hr, st.hrv, st.spo2, st.temp, st.motion].contains(where: { $0.count > 1 }) {
            return true
        }
        guard let s = n.series else { return false }
        return [s.hr, s.hrv, s.spo2, s.temp, s.motion].contains { $0.count > 1 }
    }

    @ViewBuilder private func clinicalGrid(_ m: SleepMetrics) -> some View {
        let mins = { (x: Double?) in x.map { "\(Int($0.rounded())) min" } ?? "–" }
        let cells: [(String, String)] = [
            ("sleep onset", mins(m.solMin)),
            ("rem latency", mins(m.remLatencyMin)),
            ("awake · waso", mins(m.wasoMin)),
            ("awakenings", "\(m.awakenings)"),
            ("sleep cycles", "\(m.cycles)"),
            ("fragmentation", String(format: "%.0f /h", m.fragIndex)),
        ]
        let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        LazyVGrid(columns: cols, alignment: .leading, spacing: 18) {
            ForEach(cells, id: \.0) { Readout(value: $0.1, caption: $0.0) }
        }
    }

    @ViewBuilder private func autonomicGrid(_ a: StageAutonomic) -> some View {
        let hrv = { (x: Double?) in x.map { "\(Int($0)) ms" } ?? "–" }
        let hr = { (x: Double?) in x.map { "\(Int($0)) bpm" } ?? "–" }
        let cells: [(String, String)] = [
            ("hrv · deep", hrv(a.hrvDeep)), ("hrv · light", hrv(a.hrvLight)), ("hrv · rem", hrv(a.hrvRem)),
            ("hr · deep", hr(a.hrDeep)), ("hr · light", hr(a.hrLight)), ("hr · rem", hr(a.hrRem)),
        ]
        let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        LazyVGrid(columns: cols, alignment: .leading, spacing: 18) {
            ForEach(cells, id: \.0) { Readout(value: $0.1, caption: $0.0) }
        }
    }

    /// One row per finding: an icon in the stage colour, a plain label and a mono value.
    /// Same vocabulary as the summary strip at the top of the report.
    @ViewBuilder private func interpretation(_ n: NightRow, _ m: SleepMetrics?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(findings(n, m), id: \.label) { f in
                summaryRow(icon: f.icon, tint: f.tint, label: f.label, value: f.value, detail: f.detail)
            }
            if let d = s.sleepDebt, d.valid {
                summaryRow(icon: "bed.double", tint: Obs.debt(d.state), label: "Sleep debt",
                           value: debtDuration(d.debt_min),
                           detail: "vs \(debtDuration(d.need_h * 60)) nightly need"
                               + (d.recent_shortfall_min > 0 ? " · last day \(Int(d.recent_shortfall_min)) min short" : ""))
            }
        }
    }

    private func summaryRow(icon: String, tint: Color, label: String, value: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(tint)
                .frame(width: 20, alignment: .center)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(Obs.prose(14)).foregroundStyle(Obs.ink2)
                if let detail {
                    Text(detail).font(Obs.mono(11)).foregroundStyle(Obs.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Text(value).font(Obs.mono(15, .medium)).foregroundStyle(tint).monospacedDigit()
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(Obs.trace.opacity(0.5)).frame(height: 0.5) }
    }

    private struct Finding { let icon: String; let tint: Color; let label: String; let value: String; let detail: String? }

    private func findings(_ n: NightRow, _ m: SleepMetrics?) -> [Finding] {
        var out: [Finding] = []
        if let e = n.efficiency {
            let tint: Color = e >= 85 ? Obs.good : e < 75 ? Obs.bad : Obs.ink
            out.append(Finding(icon: "moon.zzz", tint: tint, label: "Asleep while in bed", value: "\(Int(e))%", detail: nil))
        }
        if let dp = n.deep_pct {
            out.append(Finding(icon: "waveform.path", tint: Obs.deep, label: "Deep sleep", value: "\(Int(dp))%", detail: nil))
        }
        if let rp = n.rem_pct {
            let detail = m?.remLatencyMin.map { "first REM \(Int($0.rounded())) min after onset" }
            out.append(Finding(icon: "eye", tint: Obs.rem, label: "REM sleep", value: "\(Int(rp))%", detail: detail))
        }
        if let m {
            let n = m.awakenings
            out.append(Finding(icon: "sun.max", tint: Obs.wake, label: "Awake after falling asleep",
                               value: "\(Int(m.wasoMin.rounded())) min",
                               detail: "\(n) awakening\(n == 1 ? "" : "s")"))
        }
        return out
    }
}

struct ActivityReport: View {
    let s: Summary
    let day: String
    var body: some View {
        let st = s.activity_daily[day]
        let prof = s.activity_profile[day] ?? []
        let steps = compactSteps(st?.steps)

        HStack(alignment: .top, spacing: 0) {
            Readout(value: steps.value, caption: steps.unit)
            Readout(value: st.map { "\(Int($0.active_kcal ?? 0))" } ?? "–", caption: "active kcal")
            Readout(value: st.map { "\(Int($0.total_kcal ?? 0))" } ?? "–", caption: "total kcal")
            if let d = st?.distance_m { Readout(value: String(format: "%.1f", d / 1000), caption: "distance · km") }
        }

        Rule("movement across the day")
        MetProfile(timeline: s.wakingActivityTimeline(for: day))

        let bucketMin = prof.isEmpty ? 15.0 : 24.0 * 60.0 / Double(prof.count)
        let activeMin = Double(prof.filter { $0 >= 3 }.count) * bucketMin
        let lightMin = Double(prof.filter { $0 >= 1.5 && $0 < 3 }.count) * bucketMin
        let peak = prof.max() ?? 0
        let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        LazyVGrid(columns: cols, alignment: .leading, spacing: 18) {
            Readout(value: "\(Int(activeMin)) min", caption: "active")
            Readout(value: "\(Int(lightMin)) min", caption: "lightly active")
            Readout(value: String(format: "%.1f MET", peak), caption: "peak intensity")
        }

        let ws = s.workoutsOn(day)
        Rule("sessions")
        if ws.isEmpty {
            Text("No sessions detected this day.").font(Obs.mono(12)).foregroundStyle(Obs.ink2)
        } else {
            VStack(spacing: 14) {
                ForEach(ws) { w in SessionRow(label: w.label, durationMin: w.durationMin, startHM: w.startHM) }
            }
        }
    }
}

private func compactSteps(_ steps: Double?) -> (value: String, unit: String) {
    guard let steps else { return ("–", "steps") }
    guard steps >= 1_000 else { return ("\(Int(steps.rounded()))", "steps") }
    return (String(format: "%.1f", steps / 1_000), "k steps")
}

// MET-above-rest across the human waking day, rather than a calendar-day 00–24
// window. The timeline can cross midnight and says when its bedtime is estimated.
private struct MetProfile: View {
    let timeline: WakingActivityTimeline

    private var ticks: [Double] {
        var result = [timeline.startHour]
        var hour = ceil(timeline.startHour / 6) * 6
        while hour < timeline.endHour {
            if hour - timeline.startHour > 1 { result.append(hour) }
            hour += 6
        }
        if timeline.endHour - (result.last ?? timeline.startHour) > 1 { result.append(timeline.endHour) }
        return result
    }

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Text(timeline.startCaption)
                Spacer()
                Text(timeline.endCaption)
            }
            .font(Obs.mono(9, .medium))
            .foregroundStyle(Obs.ink2)

            Canvas { ctx, size in
                let span = max(1, timeline.endHour - timeline.startHour)
                let x = { (hour: Double) in
                    size.width * CGFloat((hour - timeline.startHour) / span)
                }
                for hour in ticks {
                    let x = x(hour)
                    ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                               with: .color(Obs.trace.opacity(0.2)), lineWidth: 0.5)
                }
                guard timeline.points.count > 1 else { return }
                let peak = max(1, timeline.points.map(\.met).max() ?? 1)
                func pt(_ point: TimedActivityPoint) -> CGPoint {
                    CGPoint(x: x(point.hour),
                            y: 6 + (1 - CGFloat(min(1, point.met / peak))) * (size.height - 12))
                }
                var line = Path(); line.move(to: pt(timeline.points[0]))
                for point in timeline.points.dropFirst() { line.addLine(to: pt(point)) }
                var area = line
                area.addLine(to: CGPoint(x: x(timeline.points.last!.hour), y: size.height))
                area.addLine(to: CGPoint(x: x(timeline.points[0].hour), y: size.height))
                area.closeSubpath()
                ctx.fill(area, with: .color(Obs.chart.opacity(0.14)))
                ctx.stroke(line, with: .color(Obs.chart), lineWidth: 1.3)
            }
            .frame(height: 120)
            GeometryReader { g in
                let span = max(1, timeline.endHour - timeline.startHour)
                ForEach(ticks, id: \.self) { hour in
                    let rawX = g.size.width * CGFloat((hour - timeline.startHour) / span)
                    Text(String(format: "%02d", Int(hour) % 24))
                        .font(Obs.mono(9)).foregroundStyle(Obs.ink2)
                        .frame(width: 24)
                        .position(x: min(max(12, rawX), g.size.width - 12), y: 6)
                }
            }.frame(height: 12)
        }
    }
}
