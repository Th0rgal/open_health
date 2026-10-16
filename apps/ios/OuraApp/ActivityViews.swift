import SwiftUI

// The day's activities on a time line (sleep, naps, detected activities, the user's own exercise),
// the sheet that lists them with their tags, and the exercise sheet that starts and ends a
// workout on the ring. SIBLING CLIENT: iOS only (the web dashboard has no ring link).

private func kindColor(_ k: TimelineKind) -> Color {
    switch k {
    case .sleep: return Obs.sleepTint
    case .nap: return Obs.sleepTint.opacity(0.55)
    case .detected: return Obs.activityTint.opacity(0.6)
    case .exercise: return Obs.activityTint
    }
}

private func clockText(_ unix: Double) -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm"; f.timeZone = .current
    return f.string(from: Date(timeIntervalSince1970: unix))
}

/// 24 hours as one strip; each item is a block, with hour ticks and the current time on today.
struct ActivityTimelineBar: View {
    let items: [TimelineItem]
    var nowMin: Double? = nil
    var height: CGFloat = 34

    var body: some View {
        VStack(spacing: 4) {
            Canvas { ctx, size in
                let w = size.width
                let track = Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: size.height), cornerRadius: 6)
                ctx.fill(track, with: .color(Obs.rule.opacity(0.35)))
                for item in items {
                    let x = w * item.startMin / 1440
                    let width = max(3, w * (item.endMin - item.startMin) / 1440)
                    let r = CGRect(x: x, y: 0, width: width, height: size.height)
                    ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(kindColor(item.kind)))
                }
                for h in stride(from: 6, to: 24, by: 6) {
                    var p = Path()
                    let x = w * CGFloat(h) / 24
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(p, with: .color(Obs.paper.opacity(0.6)), lineWidth: 1)
                }
                if let nowMin {
                    var p = Path()
                    let x = w * nowMin / 1440
                    p.move(to: CGPoint(x: x, y: -2)); p.addLine(to: CGPoint(x: x, y: size.height + 2))
                    ctx.stroke(p, with: .color(Obs.ink), lineWidth: 1.5)
                }
            }
            .frame(height: height)
            HStack {
                ForEach(["00", "06", "12", "18", "24"], id: \.self) { h in
                    Text(h).font(Obs.sans(11)).foregroundStyle(Obs.muted)
                    if h != "24" { Spacer() }
                }
            }
        }
    }
}

/// Today-tab card: the day on one line, the first few items, and the way into the sheet.
struct ActivitiesCard: View {
    let s: Summary
    let day: String
    @ObservedObject var store: ActivityLogStore
    var open: () -> Void

    var body: some View {
        let items = DayTimeline.items(on: day, summary: s, log: store.log)
        let doing = Array(items.filter { $0.kind != .sleep }.reversed())   // newest first; the night's sleep has its own card
        Button(action: open) {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(title: "Activities", icon: "figure.walk", tint: Obs.activityTint,
                             trailing: doing.isEmpty ? nil : "\(doing.count)", chevron: true)
                ActivityTimelineBar(items: items, nowMin: nowMinute())
                if doing.isEmpty {
                    Text(store.log.active != nil ? "An exercise is running on the ring."
                         : !ModelFiles.activityDetection ? "Automatic activity detection is not included in this build."
                         : "No activity detected. Detection needs Step motion: turn it on in Profile, Ring capture, apply it, then sync.")
                        .font(Obs.sans(11)).foregroundStyle(Obs.muted)
                } else {
                    ForEach(Array(doing.prefix(3))) { item in
                        SessionRow(label: item.label, durationMin: item.durationMin, startHM: clockText(item.startUnix))
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .surface()
    }

    private func nowMinute() -> Double? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        guard f.string(from: Date()) == day else { return nil }
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
    }
}

/// The day's items with detail, tagging of detected activities, and the way to start an exercise.
struct ActivityTimelineView: View {
    let s: Summary
    let day: String
    @ObservedObject var store: ActivityLogStore
    @ObservedObject var ring: RingSync
    var onFinished: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showExercise = false
    @State private var detail: TimelineItem?

    var body: some View {
        let items = DayTimeline.items(on: day, summary: s, log: store.log)
        NavigationStack {
            ZStack {
                Obs.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ActivityTimelineBar(items: items, height: 44).surface()
                        Button { showExercise = true } label: {
                            HStack {
                                Image(systemName: store.log.active == nil ? "play.circle" : "stop.circle")
                                Text(store.log.active == nil ? "Start exercise" : "Exercise running").font(Obs.sans(13, .medium))
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 11))
                            }
                            .foregroundStyle(Obs.ink).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).surface()
                        if items.isEmpty {
                            Text("Nothing recorded for \(day).").font(Obs.sans(12)).foregroundStyle(Obs.muted)
                        }
                        ForEach(Array(items.reversed())) { item in row(item) }
                        Text("Detected activities come from the ring's motion and step data, run through the same model the official app uses on the phone. The official app also sends them to a cloud classifier for their type and for things like housework, which this app does not have, so the type may be wrong. Tag an activity to correct it; tags stay on this iPhone.")
                            .font(Obs.sans(11)).foregroundStyle(Obs.muted)
                    }
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
                }
            }
            .navigationTitle(day)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showExercise) {
                ExerciseView(s: s, store: store, ring: ring, onFinished: onFinished)
            }
            .sheet(item: $detail) { ActivityDetailView(item: $0) }
        }
    }

    @ViewBuilder private func row(_ item: TimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3).fill(kindColor(item.kind)).frame(width: 6, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(actLabel(item.label)).font(Obs.sans(14, .medium)).foregroundStyle(Obs.ink)
                    Text("\(clockText(item.startUnix)) to \(clockText(item.endUnix)), \(item.durationMin) min")
                        .font(Obs.sans(11)).foregroundStyle(Obs.ink2)
                }
                Spacer()
                Text(sourceText(item)).font(Obs.sans(11)).foregroundStyle(Obs.muted)
                if item.kind != .sleep { Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Obs.muted) }
            }
            .contentShape(Rectangle())
            .onTapGesture { if item.kind != .sleep { detail = item } }
            if let l = item.logged, let avg = l.hrAvg, let mx = l.hrMax {
                Text("Heart rate average \(Int(avg.rounded())), maximum \(Int(mx.rounded())) bpm")
                    .font(Obs.sans(11)).foregroundStyle(Obs.ink2)
            }
            if let key = item.detectedKey {
                Menu {
                    ForEach(ActivityTagChoice.all, id: \.self) { type in
                        Button(actLabel(type)) { store.tag(key, as: type) }
                    }
                    if item.tagged { Button("Remove tag", role: .destructive) { store.tag(key, as: nil) } }
                } label: {
                    Label(item.tagged ? "Change tag" : "Tag", systemImage: "tag").font(Obs.sans(11)).foregroundStyle(Obs.ink)
                }
            }
            if let l = item.logged {
                Button(role: .destructive) { store.remove(l.id) } label: {
                    Label("Delete", systemImage: "trash").font(Obs.sans(11))
                }
            }
        }
        .surface()
    }

    private func sourceText(_ item: TimelineItem) -> String {
        switch item.kind {
        case .sleep: return "sleep"
        case .nap: return item.detectedKey == nil ? "nap" : "your tag"
        case .detected:
            if item.tagged { return "your tag" }
            return item.confidence.map { "detected \(Int(($0 * 100).rounded()))%" } ?? "detected"
        case .exercise: return "your exercise"
        }
    }
}

/// One series against clock time, scaled to its own range, with the range and the window ends.
struct SeriesChart: View {
    let title: String
    let unit: String
    let points: [(t: Double, v: Double)]
    let start: Double
    let end: Double
    var color: Color = Obs.activityTint
    var bars = false
    var height: CGFloat = 92

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Obs.sans(11, .medium)).foregroundStyle(Obs.ink2)
                Spacer()
                if let lo = points.map(\.v).min(), let hi = points.map(\.v).max() {
                    Text("\(fmt(lo)) to \(fmt(hi)) \(unit)").font(Obs.sans(11)).foregroundStyle(Obs.muted)
                }
            }
            if points.count < 2 {
                Text("no saved records in this window").font(Obs.sans(11)).foregroundStyle(Obs.muted)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            } else {
                Canvas { ctx, size in
                    let lo = min(points.map(\.v).min() ?? 0, bars ? 0 : .infinity)
                    let hi = points.map(\.v).max() ?? 1
                    let span = max(hi - lo, 1e-6)
                    let dur = max(end - start, 1)
                    func pt(_ p: (t: Double, v: Double)) -> CGPoint {
                        CGPoint(x: size.width * (p.t - start) / dur, y: size.height - size.height * 0.9 * (p.v - lo) / span - 2)
                    }
                    if bars {
                        let w = max(2, size.width * 60 / dur)
                        for p in points {
                            let q = pt(p)
                            ctx.fill(Path(CGRect(x: q.x, y: q.y, width: w, height: size.height - q.y)), with: .color(color.opacity(0.8)))
                        }
                    } else {
                        var path = Path()
                        for (i, p) in points.enumerated() { i == 0 ? path.move(to: pt(p)) : path.addLine(to: pt(p)) }
                        ctx.stroke(path, with: .color(color), lineWidth: 1.8)
                    }
                }
                .frame(height: height)
                HStack {
                    Text(clockText(start)).font(Obs.sans(11)).foregroundStyle(Obs.muted)
                    Spacer()
                    Text(clockText(end)).font(Obs.sans(11)).foregroundStyle(Obs.muted)
                }
            }
        }
    }

    private func fmt(_ x: Double) -> String { abs(x) >= 10 ? String(Int(x.rounded())) : String(format: "%.1f", x) }
}

/// An activity afterwards: when, how long, where it came from, and plots of the records saved on
/// this iPhone for the window (heart rate, MET, motion). Nothing is fetched from the ring.
struct ActivityDetailView: View {
    let item: TimelineItem
    @State private var series: ActivitySeries?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Obs.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(actLabel(item.label)).font(Obs.sans(18, .medium)).foregroundStyle(Obs.ink)
                            Text("\(clockText(item.startUnix)) to \(clockText(item.endUnix)), \(item.durationMin) min")
                                .font(Obs.sans(12)).foregroundStyle(Obs.ink2)
                            if let c = item.confidence {
                                Text("model confidence \(Int((c * 100).rounded()))%").font(Obs.sans(11)).foregroundStyle(Obs.muted)
                            }
                        }
                        .surface()
                        if let s = series {
                            summary(s)
                            VStack(alignment: .leading, spacing: 18) {
                                SeriesChart(title: "Heart rate", unit: "bpm", points: s.hr, start: item.startUnix, end: item.endUnix, color: Obs.alert)
                                SeriesChart(title: "Intensity (MET)", unit: "MET", points: s.met, start: item.startUnix, end: item.endUnix)
                                SeriesChart(title: "Motion", unit: "s", points: s.motion, start: item.startUnix, end: item.endUnix, color: Obs.chart, bars: true)
                            }
                            .surface()
                        } else {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("reading saved records").font(Obs.sans(11)).foregroundStyle(Obs.ink2)
                            }
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
                }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task {
            let (a, b) = (item.startUnix, item.endUnix)
            series = await Task.detached { ExerciseMetrics.series(startUnix: a, endUnix: b) }.value
        }
    }

    @ViewBuilder private func summary(_ s: ActivitySeries) -> some View {
        let hr = s.hr.map(\.v)
        HStack(alignment: .top, spacing: 8) {
            StatCell(label: "Avg HR", value: hr.isEmpty ? "–" : String(Int((hr.reduce(0, +) / Double(hr.count)).rounded())), unit: "bpm")
            StatCell(label: "Max HR", value: hr.max().map { String(Int($0.rounded())) } ?? "–", unit: "bpm")
            StatCell(label: "Avg MET", value: s.met.isEmpty ? "–" : String(format: "%.1f", s.met.map(\.v).reduce(0, +) / Double(s.met.count)))
        }
    }
}

/// Starts a workout on the ring (parameters, then exercise heart rate REQUESTED) and ends it
/// (back to the earlier mode), then syncs so the ring's records for the window arrive.
struct ExerciseView: View {
    let s: Summary
    @ObservedObject var store: ActivityLogStore
    @ObservedObject var ring: RingSync
    var onFinished: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var type = ExerciseType.all[0]
    @State private var working = false
    @State private var message: String?
    @State private var stopFailed = false

    var body: some View {
        NavigationStack {
            ZStack {
                Obs.canvas.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 18) {
                    if let active = store.log.active {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            let secs = max(0, Int(ctx.date.timeIntervalSince1970 - active.startUnix))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(actLabel(active.type)).font(Obs.sans(14, .medium)).foregroundStyle(Obs.ink)
                                Text(String(format: "%d:%02d:%02d", secs / 3600, secs % 3600 / 60, secs % 60))
                                    .font(Obs.sans(34, .medium)).monospacedDigit().foregroundStyle(Obs.ink)
                                Text("started \(clockText(active.startUnix))").font(Obs.sans(11)).foregroundStyle(Obs.muted)
                            }
                        }
                        .surface()
                        button("Stop exercise", symbol: "stop.fill") { Task { await stop(active) } }
                        if stopFailed {
                            Button(role: .destructive) { store.clearActive(); stopFailed = false } label: {
                                Text("Discard this exercise (the ring could not be reached)").font(Obs.sans(11))
                            }
                        }
                    } else {
                        Picker("Type", selection: $type) {
                            ForEach(ExerciseType.all) { Text(actLabel($0.name)).tag($0) }
                        }
                        .pickerStyle(.wheel).frame(height: 130).surface()
                        button("Start exercise", symbol: "play.fill") { Task { await start() } }
                    }
                    if working {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("talking to the ring").font(Obs.sans(11)).foregroundStyle(Obs.ink2)
                        }
                    } else if let message {
                        Text(message).font(Obs.sans(11)).foregroundStyle(Obs.ink2)
                    }
                    Text("Starting tells the ring this is a workout, as the official app does, so it records exercise heart rate. The phone does not need to stay connected. Stopping puts the ring back as it was and syncs. Heart rate for the session comes from the beats saved on this iPhone after the sync.")
                        .font(Obs.sans(11)).foregroundStyle(Obs.muted)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.top, 8)
            }
            .navigationTitle("Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func button(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: symbol)
                Text(title).font(Obs.sans(14, .semibold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .foregroundStyle(Obs.paper).background(Obs.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(working).opacity(working ? 0.5 : 1)
    }

    private func start() async {
        working = true; message = nil
        let resting = UInt8(max(30, min(120, s.vitals.rhr.latest ?? 60)))
        let age = s.profile?.age ?? 30  // placeholder default, replaced by the profile
        let maxHr = UInt8(max(120, min(220, 230 - age)))
        let result = await ring.startExercise(activityId: type.id, restingHr: resting, maxHr: maxHr)
        working = false
        switch result {
        case .success(let started):
            let previous = started.previousMode.map { $0 <= 1 ? $0 : 0 } ?? 0
            store.begin(ActiveExercise(id: UUID().uuidString, startUnix: Date().timeIntervalSince1970,
                                       type: type.name, activityId: type.id, previousMode: previous))
            if started.modeAfter != 2 { message = "The ring did not report the workout mode. It is recording anyway; check Ring capture in Profile." }
        case .failure(let e):
            message = e.text
        }
    }

    private func stop(_ active: ActiveExercise) async {
        working = true; message = nil
        let result = await ring.stopExercise(restoreMode: active.previousMode)
        switch result {
        case .failure(let e):
            working = false
            stopFailed = true
            message = e.text + " The exercise is still marked as running; try again near the ring."
        case .success:
            let end = Date().timeIntervalSince1970
            let logged = LoggedActivity(id: active.id, startUnix: active.startUnix, endUnix: end, type: active.type)
            store.add(logged)
            store.clearActive()
            message = "Saved. Syncing the ring for heart rate."
            if let key = Keychain.loadKey() {
                _ = await ring.run(keyHex: key, source: "exercise")
                let hr = await Task.detached { ExerciseMetrics.heartRate(startUnix: active.startUnix, endUnix: end) }.value
                if let hr { store.update(active.id, hr: hr); message = "Saved with heart rate." }
                else { message = "Saved. The ring has no heart-rate beats for this window yet." }
            }
            working = false
            onFinished()
        }
    }
}
