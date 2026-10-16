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

    /// Hypnograms from Oura's own staging (NSSA or the ring) are shown verbatim.
    /// Mirrors `oura-summary::is_oura_staging`.
    static func isOuraStaging(_ source: String?) -> Bool { source == "nssa" || source == "ring" }

    /// Android SleepPhaseConverter.aggregate30SecTo5Min: drop codes outside 1...4, cut
    /// into 10-epoch windows (last partial), skip windows < 5, AWAKE when >= 4 awake,
    /// else the most frequent stage, ties AWAKE > DEEP > REM > LIGHT.
    /// Mirrors `oura-summary::aggregate_30s_to_5min`.
    static func aggregate5Min(_ stages: [Int]) -> [Int] {
        let codes = stages.filter { (1...4).contains($0) }
        var out: [Int] = []
        var i = 0
        while i < codes.count {
            let w = codes[i..<min(i + 10, codes.count)]
            i += 10
            if w.count < 5 { continue }
            var counts = [0, 0, 0, 0, 0]
            for c in w { counts[c] += 1 }
            if counts[4] >= 4 { out.append(4); continue }
            let top = counts[1...4].max() ?? 0
            out.append([4, 1, 3, 2].first { counts[$0] >= top } ?? 4)
        }
        return out
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

        func interpolate(_ pts: [[Double]], fallback: [Double]) -> [Double?] {
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
            var lo = 0
            for idx in 0..<n {
                let center = startS + (Double(idx) + 0.5) * stepS
                if center <= pairs[0].0 {
                    out[idx] = pairs[0].1
                    continue
                }
                if center >= pairs[pairs.count - 1].0 {
                    out[idx] = pairs[pairs.count - 1].1
                    continue
                }
                while lo + 1 < pairs.count && pairs[lo + 1].0 <= center {
                    lo += 1
                }
                let hi = min(lo + 1, pairs.count - 1)
                let (t0, v0) = pairs[lo]
                let (t1, v1) = pairs[hi]
                if t1 <= t0 {
                    out[idx] = v0
                } else {
                    let f = (center - t0) / (t1 - t0)
                    out[idx] = v0 * (1.0 - f) + v1 * f
                }
            }
            return out
        }

        let hr = interpolate(night.series_t?.hr ?? [], fallback: night.series?.hr ?? [])
        let hrv = interpolate(night.series_t?.hrv ?? [], fallback: night.series?.hrv ?? [])
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
    /// `oura-summary::refine_deep_stages_with_hrv`.
    static func refineDeepStages(stages: [Int], night: NightRow) -> [Int] {
        let n = stages.count
        let rawHRCount = max(night.series_t?.hr.count ?? 0, night.series?.hr.count ?? 0)
        guard n >= 40,
              rawHRCount >= 6,
              stages.allSatisfy({ (1...4).contains($0) }),
              !stages.contains(1),
              stages.filter({ $0 == 2 }).count >= 20,
              let grid = epochSignalGrid(night: night, count: n) else {
            return stages
        }
        let hrValid = grid.hr.compactMap { $0 }
        guard hrValid.count >= 6 else { return stages }
        let hrMed = percentile(hrValid, 0.50)
        let hrEp: [Double] = grid.hr.map { $0 ?? hrMed }
        if let minHR = hrEp.min(), let maxHR = hrEp.max(), maxHR - minHR < 2.0 {
            return stages
        }
        let hrvValid = grid.hrv.compactMap { $0 }
        let hrvMed = hrvValid.isEmpty ? 0.0 : percentile(hrvValid, 0.50)
        let hrvEp: [Double] = grid.hrv.map { $0 ?? hrvMed }

        let localHR: [Double] = (0..<n).map { i in
            let lo = max(0, i - 90), hi = min(n, i + 91)
            return hrEp[lo..<hi].reduce(0, +) / Double(max(1, hi - lo))
        }

        let sleepIndices = stages.enumerated().compactMap { (1...3).contains($0.element) ? $0.offset : nil }
        guard sleepIndices.count >= 20 else { return stages }
        let onset = sleepIndices.first ?? 0
        let finalSleep = sleepIndices.last ?? max(0, n - 1)
        let sleepSpan = Double(max(1, finalSleep - onset))

        var runs: [(Int, Int)] = []
        var idx = 0
        while idx < n {
            if stages[idx] == 2 && grid.motion[idx] <= 1.0 {
                var j = idx
                while j < n && stages[j] == 2 && grid.motion[j] <= 1.0 { j += 1 }
                if j - idx >= 12 { runs.append((idx, j)) }
                idx = j
            } else {
                idx += 1
            }
        }
        guard !runs.isEmpty else { return stages }

        var segmentedRuns: [(Int, Int)] = []
        for (rStart, rEnd) in runs {
            if rEnd - rStart <= 180 {
                segmentedRuns.append((rStart, rEnd))
            } else {
                var cur = rStart
                while cur + 12 <= rEnd {
                    var segEnd = min(rEnd, cur + 90)
                    if rEnd - segEnd < 24 { segEnd = rEnd }
                    segmentedRuns.append((cur, segEnd))
                    cur = segEnd
                }
            }
        }

        let firstCycleMaxLen = segmentedRuns.compactMap { s, e -> Int? in
            let frac = (Double(s + e) / 2.0 - Double(onset)) / sleepSpan
            return frac < 0.16 ? (e - s) : nil
        }.max() ?? 0

        var scoredRuns: [(score: Double, start: Int, end: Int, frac: Double, dip: Double)] = []
        for (rStart, rEnd) in segmentedRuns {
            let runLen = rEnd - rStart
            let mid = Double(rStart + rEnd) / 2.0
            let sleepFrac = max(0.0, (mid - Double(onset)) / sleepSpan)
            if sleepFrac > 0.56 { continue }
            if sleepFrac < 0.12 && firstCycleMaxLen >= 40 && Double(runLen) < Double(firstCycleMaxLen) * 0.65 {
                continue
            }
            let meanHR = hrEp[rStart..<rEnd].reduce(0, +) / Double(runLen)
            let meanLocHR = localHR[rStart..<rEnd].reduce(0, +) / Double(runLen)
            let prevEnd = max(1, rStart)
            let prevHR = hrEp[0..<prevEnd].reduce(0, +) / Double(prevEnd)
            let meanHRV = hrvValid.isEmpty ? 0.0 : hrvEp[rStart..<rEnd].reduce(0, +) / Double(runLen)
            let hrDip = meanLocHR - meanHR
            let prevDip = prevHR - meanHR
            if prevDip < -0.25 || (prevDip < 0.10 && hrDip < 0.35) {
                continue
            }
            if !hrvValid.isEmpty && sleepFrac > 0.12 && meanHRV > max(38.0, hrvMed * 1.15) && hrDip < 2.0 {
                continue
            }
            let homeo = exp(-2.2 * sleepFrac)
            let durBonus = min(1.0, max(0.0, Double(runLen - 12) / 48.0))
            let dipBonus = min(0.6, max(-0.5, hrDip / 3.0))
            let score = homeo * 0.55 + durBonus * 0.35 + dipBonus * 0.25
            scoredRuns.append((score, rStart, rEnd, sleepFrac, hrDip))
        }

        scoredRuns.sort { $0.score > $1.score }
        let asleepEpochs = sleepIndices.count
        let targetDeep = max(12, Int((Double(asleepEpochs) * 0.105).rounded()))
        var out = stages
        var selectedCenters: [Int] = []
        var deepCount = 0

        for item in scoredRuns {
            if deepCount >= targetDeep { break }
            let rStart = item.start, rEnd = item.end, sleepFrac = item.frac
            let runLen = rEnd - rStart
            let mid = (rStart + rEnd) / 2
            if selectedCenters.contains(where: { abs(mid - $0) < 110 }) { continue }
            let remaining = targetDeep - deepCount
            if remaining < 8 { break }

            let sIdx: Int
            let eIdx: Int
            if sleepFrac < 0.16 {
                let lead = rStart <= onset + 12 ? 2 : min(10, max(2, (runLen - 12) / 5))
                let tail = min(4, max(1, (runLen - 12 - lead) / 6))
                let maxBout = min(56, max(0, runLen - lead - tail), remaining)
                if maxBout < 8 { continue }
                let searchEnd = max(rStart + lead, rEnd - tail - maxBout)
                var bestS = rStart + lead
                var bestHR = Double.infinity
                for candS in (rStart + lead)...searchEnd {
                    let mHR = hrEp[candS..<(candS + maxBout)].reduce(0, +) / Double(maxBout)
                    if mHR < bestHR {
                        bestHR = mHR
                        bestS = candS
                    }
                }
                sIdx = bestS
                eIdx = bestS + maxBout
            } else if sleepFrac < 0.36 {
                let cap = item.dip >= 2.0 ? min(42, max(10, (runLen * 9) / 20)) : min(26, max(10, (runLen * 2) / 5))
                let maxBout = min(cap, min(remaining, runLen))
                let tail = min(4, max(1, (runLen - maxBout) / 4))
                eIdx = rEnd - tail
                sIdx = max(rStart + min(4, runLen), eIdx - maxBout)
            } else {
                let maxBout = min(min(22, max(8, (runLen * 2) / 5)), min(remaining, runLen))
                sIdx = rStart + (runLen - maxBout) / 2
                eIdx = sIdx + maxBout
            }
            if eIdx <= sIdx || eIdx - sIdx < 8 { continue }
            for k in sIdx..<eIdx { out[k] = 1 }
            deepCount += eIdx - sIdx
            selectedCenters.append((sIdx + eIdx) / 2)
        }
        return out
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
        let rawHRCount = max(night.series_t?.hr.count ?? 0, night.series?.hr.count ?? 0)
        guard (120...1920).contains(n),
              rawHRCount >= 12,
              let grid = epochSignalGrid(night: night, count: n) else { return nil }
        let hrValid = grid.hr.compactMap { $0 }
        let hrvValid = grid.hrv.compactMap { $0 }
        guard hrValid.count >= 12 else { return nil }

        let hrMed = percentile(hrValid, 0.50)
        let hrEp: [Double] = grid.hr.map { $0 ?? hrMed }
        let hrvRawMed = hrvValid.isEmpty ? 0.0 : percentile(hrvValid, 0.50)
        let hrvRaw: [Double] = grid.hrv.map { $0 ?? hrvRawMed }
        let hrvEp: [Double] = (0..<n).map { i in
            let lo = max(0, i - 12), hi = min(n, i + 13)
            return hrvRaw[lo..<hi].reduce(0, +) / Double(max(1, hi - lo))
        }
        let hrvMed = hrvValid.isEmpty ? 0.0 : percentile(hrvEp, 0.50)
        let hrvP62 = hrvValid.isEmpty ? 0.0 : percentile(hrvEp, 0.62)
        let hrvP80 = hrvValid.isEmpty ? 0.0 : percentile(hrvEp, 0.80)

        var stages = Array(repeating: 2, count: n)
        var onset = 0
        let maxOnset = min(n / 4, 120)
        for i in 0..<maxOnset {
            let endChk = min(n, i + 10)
            if (i..<endChk).allSatisfy({ grid.motion[$0] <= 4.0 }) {
                onset = i
                break
            }
        }
        for i in 0..<onset { stages[i] = 4 }

        var wakeEnd = n
        let minWakeEnd = max(onset, n - 90)
        var foundQuietEnd = false
        for i in stride(from: n - 1, through: minWakeEnd, by: -1) {
            let loChk = max(onset, i - 20)
            if (loChk...i).allSatisfy({ grid.motion[$0] <= 2.0 }) {
                wakeEnd = i + 1
                foundQuietEnd = true
                break
            }
        }
        if !foundQuietEnd {
            while wakeEnd > minWakeEnd && grid.motion[wakeEnd - 1] >= 4.0 {
                wakeEnd -= 1
            }
        }
        for i in wakeEnd..<n { stages[i] = 4 }

        for i in onset..<wakeEnd {
            let loN = max(onset, i - 4), hiN = min(wakeEnd, i + 5)
            let nearMo = grid.motion[loN..<hiN].reduce(0, +)
            if grid.motion[i] >= 8.0 || (grid.motion[i] >= 5.0 && nearMo >= 10.0) {
                let lo = max(onset, i - 1), hi = min(wakeEnd, i + 2)
                for k in lo..<hi { stages[k] = 4 }
            }
        }

        var refined = refineDeepStages(stages: stages, night: night)
        let remStart = min(wakeEnd, onset + 90)
        let remEnd = max(remStart, wakeEnd - 2)
        let sleepSpan = Double(max(1, wakeEnd - onset))
        for i in remStart..<remEnd {
            if refined[i] != 2 || grid.motion[i] > 2.0 { continue }
            let frac = Double(i - onset) / sleepSpan
            let cyclePos = Double((i - onset) % 176) / 176.0
            let inRemPhase = (0.56...0.90).contains(cyclePos)
            let isRem: Bool
            if !hrvValid.isEmpty && hrvP80 > hrvMed {
                let hrvV = hrvEp[i]
                isRem = (inRemPhase && hrvV >= hrvP62)
                    || (frac >= 0.30 && hrvV >= hrvP80)
                    || (frac >= 0.80 && inRemPhase && hrvV >= hrvMed * 0.90)
            } else {
                isRem = inRemPhase && (frac >= 0.35 || hrEp[i] >= hrMed - 0.5)
            }
            if isRem { refined[i] = 3 }
        }
        return smooth(refined, 5)
    }
}

// ── research-grade primitives ────────────────────────────────────────────────
// A section rule: a hairline with a small all-caps mono label riding it.
struct Rule: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(spacing: 10) {
            Text(text).font(Obs.sans(11, .medium)).foregroundStyle(Obs.ink2)
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
            Text(value).font(Obs.sans(20, .medium)).foregroundStyle(accent).monospacedDigit()
            Text(caption).font(Obs.sans(11)).foregroundStyle(Obs.ink2)
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

    private struct Lane { let label: String; let unit: String; let signal: SignalLane?; let stages: [Int]?; var stageSpan: [Double]? = nil }
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
        // The official app's main chart: 5-minute blocks laid from the first NSSA epoch.
        if let st5 = night.stages_5min, !st5.isEmpty, let s0 = night.start_unix, let e0 = night.end_unix, e0 > s0 {
            let t0 = night.stages_t0_unix ?? Double(s0)
            let span = Double(e0 - s0)
            let a = (t0 - Double(s0)) / span, b = (t0 + Double(st5.count) * 300 - Double(s0)) / span
            out.append(Lane(label: night.staging_source == "nssa" ? "Hypnogram · 5 min (Oura app)" : "Hypnogram · 5 min", unit: "", signal: nil, stages: st5, stageSpan: [a, b]))
        }
        if let st = night.hypnogram, st.count > 1 { out.append(Lane(label: "Hypnogram", unit: "", signal: nil, stages: night.analysisStages)) }
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
                    Text(clockAt(win, f)).font(Obs.sans(11, .medium)).foregroundStyle(Obs.paper)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Obs.ink, in: RoundedRectangle(cornerRadius: 4))
                        .offset(x: gutterW + CGFloat(f) * plotW - 18, y: -2)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .overlay(HorizontalScrub(onChange: { x in cursorF = Double(max(0, min(1, (x - gutterW) / plotW))) },
                                     onEnd: { cursorF = nil }))
        }
        .frame(height: totalH)
    }

    @ViewBuilder private func laneRow(_ lane: Lane, plotW: CGFloat) -> some View {
        let h = lane.stages != nil ? hypH : laneH
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(lane.label).font(Obs.sans(11)).foregroundStyle(Obs.ink2)
                Text(gutterValue(lane)).font(Obs.sans(12, .medium)).foregroundStyle(Obs.ink).monospacedDigit()
            }
            .frame(width: gutterW, alignment: .leading)
            Group {
                if let st = lane.stages { HypnoCanvas(stages: st, span: lane.stageSpan) }
                else if let s = lane.signal { SignalCanvas(v: s.v, color: s.color, span: s.span, times: s.times, timed: s.timed) }
            }
            .frame(width: plotW, height: h)
        }
        .frame(height: h)
    }

    private func gutterValue(_ lane: Lane) -> String {
        if let st = lane.stages, let sp = lane.stageSpan {
            guard let f = cursorF else { return "" }
            guard f >= sp[0], f < sp[1] else { return "—" }
            let local = (f - sp[0]) / max(1e-9, sp[1] - sp[0])
            return stageName(st[min(st.count - 1, max(0, Int(local * Double(st.count))))])
        }
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
                        .font(Obs.sans(11)).foregroundStyle(Obs.ink2)
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
    /// When set, the stages are blocks spanning [span0, span1] of the night (edge mapping).
    var span: [Double]? = nil
    var body: some View {
        Canvas { ctx, size in
            let n = stages.count
            guard n > (span == nil ? 1 : 0) else { return }
            let padT: CGFloat = 8, plotH = size.height - 16
            let lvl = { (c: Int) -> CGFloat in switch c { case 1: return 3; case 2: return 2; case 3: return 1; default: return 0 } }
            let yOf = { (l: CGFloat) in padT + l / 3 * plotH }
            let xOf = { (i: Int) -> CGFloat in
                if let sp = span { return size.width * CGFloat(sp[0] + (sp[1] - sp[0]) * Double(i) / Double(n)) }
                return size.width * CGFloat(i) / CGFloat(n - 1)
            }
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
                let x1 = xOf(i), x2 = xOf(span == nil ? min(j, n - 1) : j), y = yOf(lvl(code))
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
                    .font(Obs.sans(38, .medium)).foregroundStyle(tint).monospacedDigit()
                VStack(alignment: .leading, spacing: 2) {
                    Text("/ 100").font(Obs.sans(12)).foregroundStyle(Obs.ink2)
                    Text(score.basis ?? "published norms")
                        .font(Obs.sans(11)).foregroundStyle(Obs.muted)
                }
                Spacer()
                if let breathRate {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.1f", breathRate))
                            .font(Obs.sans(15, .medium)).foregroundStyle(Obs.ink).monospacedDigit()
                        Text("br/min").font(Obs.sans(11)).foregroundStyle(Obs.muted)
                    }
                }
            }

            ForEach(score.components) { component in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(component.label).font(Obs.sans(11)).foregroundStyle(Obs.ink2)
                        Spacer()
                        Text("\(Int(component.score))")
                            .font(Obs.sans(11, .medium)).foregroundStyle(Obs.ink).monospacedDigit()
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
                        Text(source).font(Obs.sans(11)).foregroundStyle(Obs.muted)
                    }
                }
            }

            Button { expanded.toggle() } label: {
                Text(expanded ? "hide sources" : "show sources")
                    .font(Obs.sans(11)).foregroundStyle(Obs.ink2)
            }
            .buttonStyle(.plain)
        }
        .obsCard()
    }
}


// ── the full-page report (sleep ⇄ activity) ──────────────────────────────────
extension Notification.Name { static let summaryNeedsReload = Notification.Name("summaryNeedsReload") }

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
                    Text(day).font(Obs.sans(13, .medium)).foregroundStyle(Obs.ink)
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
            let metrics = (n.hypnogram.flatMap { st in Sleep.metrics(Sleep.isOuraStaging(n.staging_source) ? st : Sleep.smooth(st, 5), inBedS: n.durationS) })
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
                        .font(Obs.sans(11)).foregroundStyle(Obs.ink2)
                }
                Rule("Sleep stages & signals")
                stageLegend
                Polysomnograph(night: n)

                Rule("Sleep stages")
                StageBar(n: n)
                HStack(spacing: 16) {
                    ForEach([("Deep", n.deep_pct), ("Light", n.light_pct), ("REM", n.rem_pct), ("Awake", n.wake_pct)], id: \.0) { name, pct in
                        Text(name).font(Obs.sans(11)).foregroundStyle(Obs.ink2)
                            + Text(" \(Int(pct ?? 0))%").font(Obs.sans(11, .medium)).foregroundStyle(Obs.ink)
                    }
                }
                if let m = metrics { clinicalGrid(m) }

                let auto = Sleep.autonomic(night: n,
                                           stages: n.analysisStages)
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
                    .font(Obs.sans(12)).foregroundStyle(Obs.ink2).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("No sleep recorded for this night.").font(Obs.sans(13)).foregroundStyle(Obs.ink2)
        }
    }

    /// Without the torch refresh (model-free builds) the root view just rebuilds the summary.
    private func reloadSleep() async {
        if let analysis { _ = await analysis.refresh(DayAnalysisRequest(day: day, kind: .sleep)) }
        else { NotificationCenter.default.post(name: .summaryNeedsReload, object: nil) }
    }

    @ViewBuilder private func bedtimeEditor(_ n: NightRow) -> some View {
        let nightKey = n.date ?? day
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Text("Bedtime").font(Obs.sans(11)).foregroundStyle(Obs.ink2)
                    DatePicker("Bedtime", selection: $bedtimeDate, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .disabled(savingBedtime)
                }
                HStack(spacing: 6) {
                    Text("Wake-up").font(Obs.sans(11)).foregroundStyle(Obs.ink2)
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
                        try? BedtimeOverrideStore.set(startHM: startHM, endHM: endHM, forNightKey: nightKey, night: n)
                        await reloadSleep()
                        savingBedtime = false
                        editingBedtime = false
                    }
                } label: {
                    Text(savingBedtime ? "saving…" : "apply")
                        .font(Obs.sans(11, .medium))
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
                            try? BedtimeOverrideStore.clear(forNightKey: nightKey, night: n)
                            await reloadSleep()
                            savingBedtime = false
                            editingBedtime = false
                        }
                    } label: {
                        Text("reset\(n.raw_start.map { " (\($0)–\(n.raw_end ?? ""))" } ?? "")")
                            .font(Obs.sans(11))
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
                    Text("cancel").font(Obs.sans(11)).foregroundStyle(Obs.muted)
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
                    Text(name).font(Obs.sans(11)).foregroundStyle(Obs.ink2)
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
                    Text(detail).font(Obs.sans(11)).foregroundStyle(Obs.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Text(value).font(Obs.sans(15, .medium)).foregroundStyle(tint).monospacedDigit()
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
        MetProfile(timeline: s.wakingActivityTimeline(for: day), nowHour: hourNow(on: day))

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

        if let c = st?.contributors, c.count == 7 {
            let names = ["Meet daily targets", "Stay active", "Move every hour", "Training frequency", "Training volume", "Recovery time"]
            let vals = [c[0], c[1], c[2], c[3], c[4], (10 * c[5] + 15 * c[6]) / 25]
            Rule("activity score \(Int((st?.score ?? 0).rounded()))")
            LazyVGrid(columns: cols, alignment: .leading, spacing: 18) {
                ForEach(0..<6, id: \.self) { i in
                    Readout(value: "\(Int(vals[i].rounded()))", caption: names[i])
                }
            }
        }

        let ws = s.workoutsOn(day)
        Rule("sessions")
        if ws.isEmpty {
            Text("No sessions detected this day.").font(Obs.sans(12)).foregroundStyle(Obs.ink2)
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
    /// Hour of day to mark with a dashed line (today only), where the data ends.
    var nowHour: Double? = nil

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
            .font(Obs.sans(11, .medium))
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
                if let nowHour, (timeline.startHour...timeline.endHour).contains(nowHour) {
                    let x = x(nowHour)
                    ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                               with: .color(Obs.ink2), style: .init(lineWidth: 1, dash: [3, 3]))
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
                        .font(Obs.sans(11)).foregroundStyle(Obs.ink2)
                        .frame(width: 24)
                        .position(x: min(max(12, rawX), g.size.width - 12), y: 6)
                }
            }.frame(height: 12)
        }
    }
}
