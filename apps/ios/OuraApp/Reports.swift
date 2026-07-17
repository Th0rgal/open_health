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
// oura-summary `autonomic_by_stage` (which the iOS FFI leaves null under NoModelRunner).
// iOS aligns the even-spread `series` to stages by index fraction rather than the server's
// per-sample timestamps, so values can differ by a hair; see docs/clients-web-and-ios.md.
struct StageAutonomic {
    var hrvDeep: Double?; var hrvLight: Double?; var hrvRem: Double?
    var hrDeep: Double?; var hrLight: Double?; var hrRem: Double?
    var any: Bool { [hrvDeep, hrvLight, hrvRem, hrDeep, hrLight, hrRem].contains { $0 != nil } }
}

enum Sleep {
    /// Mean of each stage's samples, mapping series index → stage by fraction of the night.
    /// A single overnight HRV slope is intentionally not derived — nocturnal HRV is
    /// stage-driven (deep ↑, REM ↓), so a slope tracks stage order, not recovery.
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
        guard n > 0 else { return nil }
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
        guard n > 0 else { return 0 }
        let epochS = inBedS / Double(n)
        return Int(Double(stages.filter { (1...3).contains($0) }.count) * epochS)
    }
}

extension Summary {
    /// iOS stages sleep on-device after the shared JSON is built. Rebuild the same
    /// Android-compatible 14-day result after staging, grouping main sleep + naps by
    /// wake date. The web receives this exact shape directly from `oura-summary`.
    func stagedSleepDebt() -> SleepDebtSummary? {
        let defaultNeedS = 8.0 * 3600.0
        var byDay: [String: Double] = [:]
        for n in nights where (n.stages?.count ?? 0) > 1 {
            guard let day = wakeYmd(n) else { continue }
            let actual = Double(Sleep.asleepS(Sleep.smooth(n.stages ?? [], 5),
                                              inBedS: (n.in_bed_h ?? 0) * 3600))
            if actual > 0 { byDay[day, default: 0] += actual }
        }
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
    private struct SignalLane { let v: [Double]; let color: Color; let dp: Int; let span: [Double] }

    private var lanes: [Lane] {
        var out: [Lane] = []
        if let st = night.stages, st.count > 1 { out.append(Lane(label: "Hypnogram", unit: "", signal: nil, stages: Sleep.smooth(st, 5))) }
        func sig(_ label: String, _ unit: String, _ v: [Double]?, _ color: Color,
                 _ dp: Int = 0, span: [Double]? = nil) {
            guard let v, v.count > 1 else { return }
            let coverage = span.flatMap { $0.count == 2 ? $0 : nil } ?? [0, 1]
            out.append(Lane(label: label, unit: unit,
                            signal: SignalLane(v: v, color: color, dp: dp,
                                               span: coverage), stages: nil))
        }
        let s = night.series
        sig("Heart rate", "bpm", s?.hr, Obs.yellow)
        sig("HRV", "ms", s?.hrv, Obs.teal)
        sig("Blood O₂", "%", s?.spo2, Obs.rem)
        sig("Skin temp", "°C", s?.temp, Obs.light, 1, span: s?.temp_span)
        sig("Motion", "s", s?.motion, Obs.ink2)
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
                    Rectangle().fill(Obs.teal.opacity(0.85)).frame(width: 1, height: totalH - axisH)
                        .offset(x: gutterW + CGFloat(f) * plotW)
                        .allowsHitTesting(false)
                    Text(clockAt(win, f)).font(Obs.mono(10, .medium)).foregroundStyle(Obs.black)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Obs.teal, in: RoundedRectangle(cornerRadius: 4))
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
                else if let s = lane.signal { SignalCanvas(v: s.v, color: s.color, span: s.span) }
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
            guard f >= s.span[0], f <= s.span[1] else { return "—" }
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
                let code = stages[i]; var j = i
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
    var body: some View {
        Canvas { ctx, size in
            guard v.count > 1 else { return }
            let lo = v.min()!, hi = v.max()!, rng = max(hi - lo, 1e-6)
            let pad: CGFloat = 5
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
private func stageName(_ c: Int) -> String { switch c { case 1: return "Deep"; case 2: return "Light"; case 3: return "REM"; default: return "Awake" } }

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
                        Text(debtDuration(debt.debt_min)).font(Obs.mono(26, .medium)).foregroundStyle(Obs.teal)
                        Text(debt.state).font(Obs.mono(11, .medium)).foregroundStyle(Obs.ink2).textCase(.uppercase)
                    }
                    Text(debtStateCopy(debt.state)).font(Obs.prose(14)).foregroundStyle(Obs.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("\(debt.valid_days) of 5 days available").font(Obs.mono(18, .medium)).foregroundStyle(Obs.ink)
                    Text("5 days of sleep data are needed within the past 2 weeks.")
                        .font(Obs.mono(11)).foregroundStyle(Obs.ink2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).obsCard()
    }
}

// Symptom Radar — on-device illness detection. A radar blip for the traffic-light
// status, then each biomarker plotted against its personal baseline band so you see
// at a glance how far breathing / lowest HR / HRV / temperature sit from normal.
struct IllnessCard: View {
    let illness: IllnessResult
    static let coral = Color(red: 0.87, green: 0.36, blue: 0.34)
    private static let copy = [
        "NO_SIGNS": "No signs of illness. Your biometrics are sitting within your normal range.",
        "MINOR_SIGNS": "Minor signs — a few biometrics have drifted outside your usual range. Worth an easy day.",
        "MAJOR_SIGNS": "Major signs — several biometrics are elevated. Your body may be fighting something.",
    ]
    private static let label = ["NO_SIGNS": "No signs", "MINOR_SIGNS": "Minor signs", "MAJOR_SIGNS": "Major signs"]
    private static let bmName = [
        "AverageBreath": "Breathing", "LowestHeartRate": "Lowest HR",
        "AverageHrv": "HRV", "TemperatureDeviation": "Body temp",
    ]
    private static let bmUnit = [
        "AverageBreath": "br", "LowestHeartRate": "bpm", "AverageHrv": "ms", "TemperatureDeviation": "°C",
    ]
    // display order matching Oura's card (breath, lowest HR, HRV, temperature)
    private static let order = ["AverageBreath", "LowestHeartRate", "AverageHrv", "TemperatureDeviation"]

    private var tint: Color {
        switch illness.trafficLight {
        case "MINOR_SIGNS": return Obs.yellow
        case "MAJOR_SIGNS": return Self.coral
        default: return Obs.teal
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ObsTag("symptom radar")
                Spacer()
                if illness.available {
                    Text("\(illness.daysWithData)/30d").font(Obs.mono(10)).foregroundStyle(Obs.trace)
                }
            }
            if !illness.available {
                Text(illness.status == "MISSING_LAST_NIGHT_SLEEP"
                     ? "Wear the ring overnight and sync — last night's data is missing."
                     : "Needs more recent nights (at least 7 of the last 14).")
                    .font(Obs.prose(14)).foregroundStyle(Obs.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            } else {
                // status: radar blip + word
                HStack(spacing: 13) {
                    RadarBlip(tint: tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.label[illness.trafficLight] ?? "—")
                            .font(Obs.prose(20, .semibold)).foregroundStyle(Obs.ink)
                        Text("illness signals").font(Obs.mono(9)).tracking(1.5)
                            .foregroundStyle(tint)
                    }
                }
                .padding(.top, 16)

                Text(Self.copy[illness.status] ?? "").font(Obs.prose(13.5)).foregroundStyle(Obs.ink2)
                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)

                Rectangle().fill(Obs.trace.opacity(0.28)).frame(height: 0.5)
                    .padding(.top, 16)

                let byType = Dictionary(uniqueKeysWithValues: illness.biomarkers.map { ($0.type, $0) })
                VStack(spacing: 13) {
                    ForEach(Self.order, id: \.self) { type in
                        if let b = byType[type] {
                            BiomarkerRow(name: Self.bmName[type] ?? type,
                                         unit: Self.bmUnit[type] ?? "",
                                         b: b, tint: tint)
                        }
                    }
                }
                .padding(.top, 16)

                Text("on-device illness model · \(illness.date)")
                    .font(Obs.mono(9)).foregroundStyle(Obs.trace)
                    .padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .obsCard()
    }
}

// concentric radar echo with a centre blip — the "Symptom Radar" motif.
private struct RadarBlip: View {
    let tint: Color
    var body: some View {
        ZStack {
            Circle().strokeBorder(tint.opacity(0.18), lineWidth: 1).frame(width: 34, height: 34)
            Circle().strokeBorder(tint.opacity(0.34), lineWidth: 1).frame(width: 22, height: 22)
            Circle().fill(tint).frame(width: 9, height: 9)
                .shadow(color: tint.opacity(0.7), radius: 5)
        }
        .frame(width: 34, height: 34)
    }
}

// one biomarker: name, a value dot placed on its personal baseline band, and the value.
private struct BiomarkerRow: View {
    let name: String
    let unit: String
    let b: IllnessBiomarker
    let tint: Color
    private var dotColor: Color {
        guard b.indicatesSymptoms else { return Obs.ink }
        return b.reason == "ELEVATED" ? IllnessCard.coral : Obs.yellow
    }
    private func fmt(_ v: Double) -> String {
        abs(v) < 10 && v != v.rounded() ? String(format: "%.1f", v) : String(Int(v.rounded()))
    }
    var body: some View {
        HStack(spacing: 12) {
            Text(name).font(Obs.mono(11)).foregroundStyle(Obs.ink2)
                .frame(width: 74, alignment: .leading)
            RangeTrack(value: b.value, lower: b.lower, upper: b.upper,
                       dot: dotColor, flagged: b.indicatesSymptoms)
                .frame(height: 14)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(fmt(b.value)).font(Obs.mono(13, .medium))
                    .foregroundStyle(b.indicatesSymptoms ? dotColor : Obs.ink).monospacedDigit()
                Text(unit).font(Obs.mono(9)).foregroundStyle(Obs.trace)
            }
            .frame(width: 56, alignment: .trailing)
        }
    }
}

// a thin track with the normal [lower, upper] band highlighted and today's value as a
// dot — the axis auto-frames to include both the band and the value.
private struct RangeTrack: View {
    let value, lower, upper: Double
    let dot: Color
    let flagged: Bool
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, midY = geo.size.height / 2
            let pad = max((upper - lower) * 0.7, 1e-6)
            let lo = min(lower, value) - pad, hi = max(upper, value) + pad
            let span = max(hi - lo, 1e-6)
            let x = { (v: Double) in CGFloat((v - lo) / span) * w }
            ZStack(alignment: .leading) {
                Capsule().fill(Obs.trace.opacity(0.22)).frame(height: 3).position(x: w / 2, y: midY)
                Capsule().fill(Obs.teal.opacity(0.30))
                    .frame(width: max(0, x(upper) - x(lower)), height: 3)
                    .position(x: (x(lower) + x(upper)) / 2, y: midY)
                Circle().fill(dot).frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Obs.base.opacity(0.9), lineWidth: 1.5))
                    .shadow(color: flagged ? dot.opacity(0.6) : .clear, radius: 3)
                    .position(x: min(max(x(value), 4.5), w - 4.5), y: midY)
            }
        }
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
                    context.stroke(need, with: .color(Obs.yellow.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                var line = Path(), started = false
                for (i, value) in values.enumerated() {
                    guard let value else { started = false; continue }
                    let point = CGPoint(x: x(i), y: y(value))
                    if started { line.addLine(to: point) } else { line.move(to: point); started = true }
                }
                context.stroke(line, with: .color(Obs.teal), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            .frame(height: 180)
            HStack {
                Text(debt.days.first.map { String($0.date.suffix(5)) } ?? "").font(Obs.mono(10)).foregroundStyle(Obs.ink2)
                Spacer()
                if mode == .sleep {
                    HStack(spacing: 5) { Rectangle().fill(Obs.yellow).frame(width: 16, height: 1); Text("sleep need").font(Obs.mono(10)).foregroundStyle(Obs.ink2) }
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
                            Text(debtDuration(debt.debt_min)).font(Obs.mono(34, .medium)).foregroundStyle(Obs.teal)
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
            .toolbarColorScheme(.dark, for: .navigationBar)
        }.preferredColorScheme(.dark)
    }
}

// ── the full-page report (sleep ⇄ activity) ──────────────────────────────────
struct DayReportView: View {
    let s: Summary
    let day: String
    @State var tab: Tab
    @Environment(\.dismiss) private var dismiss
    enum Tab: String, CaseIterable { case sleep = "Sleep", activity = "Activity" }

    var body: some View {
        ZStack {
            Obs.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Button { dismiss() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                            Text("Back").font(Obs.mono(13))
                        }.foregroundStyle(Obs.ink2)
                    }
                    Text(day).font(Obs.mono(13, .medium)).foregroundStyle(Obs.ink)
                    Spacer()
                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).fixedSize()
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                .overlay(alignment: .bottom) { Rectangle().fill(Obs.trace.opacity(0.3)).frame(height: 0.5) }

                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        if tab == .sleep { SleepReport(s: s, day: day) }
                        else { ActivityReport(s: s, day: day) }
                    }
                    .padding(20).padding(.bottom, 60)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct SleepReport: View {
    let s: Summary
    let day: String
    var body: some View {
        if let n = s.night(forDay: day) {
            let metrics = (n.stages.flatMap { st in Sleep.metrics(Sleep.smooth(st, 5), inBedS: (n.in_bed_h ?? 0) * 3600) })
            let asleepH = metrics.map { $0.asleepMin / 60 }

            // summary strip
            HStack(alignment: .top, spacing: 0) {
                Readout(value: n.in_bed_h.map { String(format: "%.1f h", $0) } ?? "—", caption: "in bed")
                Readout(value: asleepH.map { String(format: "%.1f h", $0) } ?? "—", caption: "asleep")
                Readout(value: n.efficiency.map { "\(Int($0))%" } ?? "—", caption: "efficiency")
                Readout(value: "\(n.start ?? "—")–\(n.end ?? "—")", caption: "bedtime")
            }

            if n.hasHypnogram {
                Rule("overnight polysomnograph")
                stageLegend
                Polysomnograph(night: n)

                Rule("sleep architecture")
                StageBar(n: n)
                HStack(spacing: 16) {
                    ForEach([("Deep", n.deep_pct), ("Light", n.light_pct), ("REM", n.rem_pct), ("Awake", n.wake_pct)], id: \.0) { name, pct in
                        Text(name).font(Obs.mono(11)).foregroundStyle(Obs.ink2)
                            + Text(" \(Int(pct ?? 0))%").font(Obs.mono(11, .medium)).foregroundStyle(Obs.ink)
                    }
                }
                if let m = metrics { clinicalGrid(m) }

                let auto = Sleep.autonomic(hr: n.series?.hr ?? [], hrv: n.series?.hrv ?? [],
                                           stages: Sleep.smooth(n.stages ?? [], 5))
                if auto.any {
                    Rule("autonomic recovery by stage")
                    autonomicGrid(auto)
                }

                Rule("interpretation")
                interpretation(n, metrics)
            } else {
                // model-free build: signals only, no hypnogram
                if hasAnySeries(n) {
                    Rule("overnight signals")
                    Polysomnograph(night: n)
                }
                Text("On-device sleep staging (SleepNet) runs in the torch build — the hypnogram, sleep cycles, and stage metrics appear there. The raw signals above are model-free.")
                    .font(Obs.mono(12)).foregroundStyle(Obs.ink2).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("No sleep recorded for this night.").font(Obs.mono(13)).foregroundStyle(Obs.ink2)
        }
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
        guard let s = n.series else { return false }
        return [s.hr, s.hrv, s.spo2, s.temp, s.motion].contains { $0.count > 1 }
    }

    @ViewBuilder private func clinicalGrid(_ m: SleepMetrics) -> some View {
        let mins = { (x: Double?) in x.map { "\(Int($0.rounded())) min" } ?? "—" }
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
        let hrv = { (x: Double?) in x.map { "\(Int($0)) ms" } ?? "—" }
        let hr = { (x: Double?) in x.map { "\(Int($0)) bpm" } ?? "—" }
        let cells: [(String, String)] = [
            ("hrv · deep", hrv(a.hrvDeep)), ("hrv · light", hrv(a.hrvLight)), ("hrv · rem", hrv(a.hrvRem)),
            ("hr · deep", hr(a.hrDeep)), ("hr · light", hr(a.hrLight)), ("hr · rem", hr(a.hrRem)),
        ]
        let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        LazyVGrid(columns: cols, alignment: .leading, spacing: 18) {
            ForEach(cells, id: \.0) { Readout(value: $0.1, caption: $0.0) }
        }
    }

    @ViewBuilder private func interpretation(_ n: NightRow, _ m: SleepMetrics?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(sentences(n, m), id: \.self) { t in
                Text(t).font(Obs.prose(14)).foregroundStyle(Obs.ink2).fixedSize(horizontal: false, vertical: true)
            }
            if let d = s.sleepDebt, d.valid {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(debtDuration(d.debt_min)).font(Obs.mono(20, .medium)).foregroundStyle(Obs.teal)
                    Text("accumulated sleep debt vs your \(debtDuration(d.need_h * 60)) nightly need" + (d.recent_shortfall_min > 0 ? " · last sleep day \(Int(d.recent_shortfall_min)) min short" : ""))
                        .font(Obs.mono(11)).foregroundStyle(Obs.ink2).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            }
        }
    }

    private func sentences(_ n: NightRow, _ m: SleepMetrics?) -> [String] {
        var out: [String] = []
        if let e = n.efficiency {
            out.append(e >= 85 ? "Sleep efficiency of \(Int(e))% is solid — little time awake once down."
                : e >= 75 ? "Efficiency \(Int(e))% is fair; some fragmentation kept you from deeper rest."
                : "Efficiency \(Int(e))% is low — much of the night in bed wasn't spent asleep.")
        }
        if let dp = n.deep_pct {
            out.append(dp < 10 ? "Deep sleep was scarce (\(Int(dp))%), the physically-restorative stage — often suppressed by late meals, alcohol, or stress."
                : "Deep sleep \(Int(dp))% (target ~13–23%), the physically-restorative stage.")
        }
        if let rp = n.rem_pct, let rl = m?.remLatencyMin {
            out.append("REM was \(Int(rp))% with first REM \(Int(rl.rounded())) min after onset.")
        }
        if let m {
            out.append("You spent \(Int(m.wasoMin.rounded())) min awake across \(m.awakenings) awakening\(m.awakenings == 1 ? "" : "s") after first falling asleep.")
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
            Readout(value: st.map { "\(Int($0.active_kcal ?? 0))" } ?? "—", caption: "active kcal")
            Readout(value: st.map { "\(Int($0.total_kcal ?? 0))" } ?? "—", caption: "total kcal")
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
    guard let steps else { return ("—", "steps") }
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
                ctx.fill(area, with: .color(Obs.teal.opacity(0.14)))
                ctx.stroke(line, with: .color(Obs.teal), lineWidth: 1.3)
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
