import SwiftUI

// The SwiftUI screens for OuraApp. Data types live in Models.swift, the model/FFI
// orchestration in Core.swift, the reusable charts/cells in Components.swift, and the
// full-page sleep/activity reports in Reports.swift.
// SIBLING CLIENT: the web dashboard (dashboard/web/app.js) renders the SAME summary
// JSON — a user-facing change here usually belongs there too (docs/clients-web-and-ios.md).

// The home's unified "today": last night's sleep and that day's activity as ONE unit,
// each region tappable to open its own detail (sleep → SleepDetail, activity →
// ActivityDetail). Mirrors the web dashboard's day card. Previous days live behind
// "show all days" (AllDaysView → DayDetailView, which shows the same pairing).
struct TodayCard: View {
    let s: Summary
    let day: String
    let onSleep: () -> Void
    let onActivity: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(day).font(Obs.mono(12, .medium)).foregroundStyle(Obs.ink)
                .padding(.bottom, 14)

            // night — tap for the hypnogram + breakdown + that night's vitals
            if let n = s.night(forDay: day) {
                Button(action: onSleep) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            ObsTag("sleep", icon: "moon.fill")
                            Spacer()
                            Text(n.in_bed_h.map { String(format: "%.1fh", $0) } ?? "—")
                                .font(Obs.mono(11)).foregroundStyle(Obs.ink2)
                            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Obs.trace)
                        }
                        Text("\(n.start ?? "—") → \(n.end ?? "—")")
                            .font(Obs.mono(12)).foregroundStyle(Obs.ink2)
                        if n.hasHypnogram { Hypnogram(stages: n.stages!, height: 28) }
                        else if let e = n.efficiency {
                            Text("efficiency \(Int(e))%").font(Obs.mono(12))
                                .foregroundStyle(e >= 85 ? Obs.good : (e < 75 ? Obs.bad : Obs.ink2))
                        }
                    }
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)

                Rectangle().fill(Obs.trace.opacity(0.4)).frame(height: 0.5)
                    .padding(.vertical, 16)
            }

            // activity — tap for the movement ridge + steps/kcal + this day's workouts
            Button(action: onActivity) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        ObsTag("activity", icon: "figure.walk")
                        Spacer()
                        if let st = s.activity_daily[day] {
                            Text("\(Int(st.steps ?? 0)) steps").font(Obs.mono(11)).foregroundStyle(Obs.ink2)
                            Text("· \(Int(st.active_kcal ?? 0)) kcal").font(Obs.mono(11)).foregroundStyle(Obs.ink2)
                        }
                        Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Obs.trace)
                    }
                    MovementRidge(profile: s.activity_profile[day] ?? [])
                    ForEach(Array(s.workoutsOn(day).prefix(2))) { w in
                        SessionRow(label: w.label, durationMin: w.durationMin, startHM: w.startHM)
                    }
                }
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .obsCard()
    }
}

// "show all days" → a page listing every day; tap one for its full report.
struct AllDaysView: View {
    let s: Summary
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ZStack {
                Obs.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(s.days, id: \.self) { day in
                            NavigationLink {
                                DayReportView(s: s, day: day, tab: .sleep)
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(day).font(Obs.mono(13, .medium)).foregroundStyle(Obs.ink)
                                        if let st = s.activity_daily[day] {
                                            Text("\(Int(st.steps ?? 0)) steps · \(Int(st.active_kcal ?? 0)) kcal")
                                                .font(Obs.mono(11)).foregroundStyle(Obs.ink2)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    if let n = s.night(forDay: day), n.hasHypnogram {
                                        Hypnogram(stages: n.stages!, height: 20).frame(width: 96)
                                    }
                                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Obs.trace)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(24)
                }
            }
            .navigationTitle("all days")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

// Pair + sync from a real ring: paste the auth key (exported on the desktop), connect
// over BLE, drain history into the writable DB. BLE only works on a physical device.
struct SyncView: View {
    @ObservedObject var ring: RingSync
    let onSynced: (SyncReport) -> Void
    let onReset: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var key = Keychain.loadKey() ?? ""
    @ObservedObject private var diag = RingDiag.shared
    @ObservedObject private var store = DiagStore.shared
    @State private var copied = false
    var body: some View {
        NavigationStack {
            ZStack {
                Obs.canvas.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 18) {
                    Text("Pair your ring").font(Obs.serif(24)).foregroundStyle(Obs.ink)
                    // the ring advertises reliably only ON its charger, and its single
                    // BLE link is usually held by any phone running the official app.
                    Text("Put the ring on its charger next to this iPhone, turn off Bluetooth on any phone with the official Oura app, then paste the auth key you exported on your computer. The first sync pulls the ring's full history and can take a while — keep the app open; if the connection drops it reconnects and resumes automatically.")
                        .font(Obs.mono(12)).foregroundStyle(Obs.ink2).fixedSize(horizontal: false, vertical: true)
                    TextField("32-hex auth key", text: $key)
                        .font(Obs.mono(13)).foregroundStyle(Obs.ink)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(12)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Obs.trace, lineWidth: 0.8))
                    Button {
                        Task {
                            if let report = await ring.run(keyHex: key) { onSynced(report) }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if ring.busy { ProgressView().tint(Obs.paper) }
                            Text(ring.busy ? "syncing…" : "Connect & Sync").font(Obs.mono(13, .medium))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Obs.ink).foregroundStyle(Obs.paper)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .disabled(ring.busy)
                    Button(role: .destructive) {
                        ring.resetLocalDatabase()
                        onReset()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "trash")
                            Text("Reset local sync data").font(Obs.mono(12, .medium))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Obs.trace, lineWidth: 0.8))
                    }
                    .disabled(ring.busy)
                    if !ring.status.isEmpty {
                        Text(ring.status).font(Obs.mono(12))
                            .foregroundStyle(ring.lastReport != nil ? Obs.good : Obs.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // live transcript + leftover logs from previous crashes / kills.
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("diagnostics")
                                .font(Obs.mono(11)).foregroundStyle(Obs.ink2)
                            Spacer()
                            Button(copied ? "copied ✓" : "copy all") {
                                UIPasteboard.general.string = DiagStore.shared.exportAll()
                                copied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                            }
                            .font(Obs.mono(11, .medium)).foregroundStyle(Obs.ink)
                        }
                        if !store.incidents.isEmpty {
                            Text("previous crashes · \(store.incidents.count)")
                                .font(Obs.mono(10, .medium)).foregroundStyle(Obs.bad)
                            ForEach(store.incidents.prefix(8)) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).font(Obs.mono(10, .medium)).foregroundStyle(Obs.ink)
                                    Text(item.preview).font(Obs.mono(9)).foregroundStyle(Obs.ink2)
                                        .lineLimit(5)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Button("copy this") {
                                        UIPasteboard.general.string = item.body
                                    }
                                    .font(Obs.mono(10, .medium)).foregroundStyle(Obs.ink)
                                }
                                .padding(8)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Obs.trace, lineWidth: 0.8))
                            }
                        } else {
                            Text("No leftover crash logs. If the app dies mid-sync or mid-analysis, the next launch will keep that session here.")
                                .font(Obs.mono(10)).foregroundStyle(Obs.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !store.sessions.isEmpty {
                            Text("older sessions · \(store.sessions.count)")
                                .font(Obs.mono(10, .medium)).foregroundStyle(Obs.ink2)
                            ForEach(store.sessions.prefix(4)) { item in
                                HStack {
                                    Text(item.title).font(Obs.mono(10)).foregroundStyle(Obs.ink2)
                                    Spacer()
                                    Button("copy") { UIPasteboard.general.string = item.body }
                                        .font(Obs.mono(10, .medium)).foregroundStyle(Obs.ink)
                                }
                            }
                        }
                        if diag.totalLines > 0 {
                            Text("this launch · \(diag.totalLines) lines")
                                .font(Obs.mono(10, .medium)).foregroundStyle(Obs.ink2)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(Array(diag.tail.enumerated()), id: \.offset) { _, line in
                                        Text(line).font(Obs.mono(9)).foregroundStyle(Obs.ink2)
                                            .lineLimit(3)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .padding(8)
                            }
                            .defaultScrollAnchor(.bottom)
                            .frame(maxHeight: 220)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Obs.trace, lineWidth: 0.8))
                        }
                    }
                    Spacer()
                }
                .padding(24)
            }
            .navigationTitle("sync").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .disabled(ring.busy)
                }
            }
        }
        // The sync belongs to RingSync, not to this presentation. Let the panel be
        // tucked away while BLE keeps running; the top-bar indicator remains live
        // and can reopen these diagnostics at any time.
        .presentationDragIndicator(.visible)
        .onAppear {
            if ring.busy { IdleTimerLock.acquire("pair-screen") }
        }
        .onDisappear {
            IdleTimerLock.release("pair-screen")
        }
        .onChange(of: ring.busy) { _, busy in
            if busy {
                IdleTimerLock.acquire("pair-screen")
            } else {
                IdleTimerLock.release("pair-screen")
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, ring.busy {
                IdleTimerLock.refreshIfHeld("ring-sync")
                IdleTimerLock.refreshIfHeld("pair-screen")
            }
        }
    }
}

/// The top-bar sync affordance doubles as a live status light and the entry point
/// to diagnostics. Motion stays quiet: one slow continuous turn only while BLE is
/// active.
private struct SyncIndicatorButton: View {
    @ObservedObject var ring: RingSync
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation = 0.0

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(Obs.rule, lineWidth: 0.8)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(ring.busy ? Obs.ink : (ring.wasRecentlySynced ? Obs.good : Obs.ink2))
                    .rotationEffect(.degrees(rotation))
            }
            .frame(width: 31, height: 31)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ring.busy ? "Ring sync in progress" : "Ring sync and diagnostics")
        .accessibilityHint("Opens sync status, logs, and manual controls")
        .onAppear(perform: updateAnimation)
        .onChange(of: ring.busy) { _, _ in updateAnimation() }
        .onChange(of: reduceMotion) { _, _ in updateAnimation() }
    }

    private func updateAnimation() {
        if ring.busy && !reduceMotion {
            rotation = 0
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { rotation = 0 }
        }
    }
}

// ── root ─────────────────────────────────────────────────────────────────────
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var s: Summary? = SummaryCache.load()
    @State private var report: ReportSel?
    @State private var showAllDays = false
    @State private var showSync = false
    @State private var showProfile = false
    @State private var showSleepDebt = false
    @State private var vital: VitalKind?
    @State private var loadGeneration = 0
    @State private var isRefreshingSummary = false
    @StateObject private var ring = RingSync()
    @StateObject private var modelProgress = ModelProgress()
    private func f(_ v: Double?, _ fallback: String = "—") -> String {
        v.map { "\(Int($0))" } ?? fallback
    }
    private func relAge(_ diff: Double) -> String {
        let a = abs((diff * 10).rounded() / 10)
        if diff < -0.05 { return "\(a) yr younger" }
        if diff > 0.05 { return "\(a) yr older" }
        return "in line"
    }
    private func localDay(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    private func displayedDayLabel(_ day: String, now: Date = Date()) -> String {
        if day == localDay(now) { return "today" }
        if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now),
           day == localDay(yesterday) { return "yesterday" }
        return day
    }
    private func latestLabel(date: String?, time: String? = nil) -> String {
        let day = date.map { String($0.suffix(5)) }
        let stamp = [day, time].compactMap { $0 }.joined(separator: " · ")
        return stamp.isEmpty ? "latest sync" : "latest · \(stamp)"
    }
    var body: some View {
        ZStack {
            Obs.canvas.ignoresSafeArea()
            if let s {
                content(s)
            } else {
                VStack(spacing: 14) {
                    ProgressView().tint(Obs.ink)
                    Text("reading your ring…").font(Obs.mono(12)).foregroundStyle(Obs.ink2)
                }
            }
        }
        .fullScreenCover(item: $report) { sel in if let s { DayReportView(s: s, day: sel.day, tab: sel.sleep ? .sleep : .activity) } }
        .sheet(isPresented: $showAllDays) { if let s { AllDaysView(s: s) } }
        .sheet(isPresented: $showSync) {
            SyncView(ring: ring, onSynced: refreshAfterSync, onReset: resetAndReload)
        }
        .sheet(isPresented: $showProfile) { ProfileSettingsView(profile: s?.profile, onSaved: refreshDerivedData) }
        .sheet(isPresented: $showSleepDebt) { if let debt = s?.sleepDebt { SleepDebtDetail(debt: debt) } }
        .sheet(item: $vital) { kind in if let s { VitalTrendView(s: s, kind: kind) } }
        .onAppear {
            // A cached summary makes launch immediate; this forced load replaces it
            // with SQLite + model output without blanking the existing Today card.
            load(force: true, clearCurrent: false)
            requestAutomaticSync()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                IdleTimerLock.refreshIfHeld("models")
                requestAutomaticSync()
            }
        }
    }

    // re-read the DB after a sync brought in new events
    private func reload() {
        load(force: true, clearCurrent: true)
    }

    private func resetAndReload() {
        SummaryCache.clear()
        #if TORCH
        ModelCacheStore.clearAll()
        #endif
        reload()
    }

    /// Profile changes affect CVA and activity inference, but do not invalidate the
    /// summary already on screen. Keep the last complete result visible until every
    /// derived model has finished, avoiding a transient sleep-debt regression.
    private func refreshDerivedData() {
        load(force: true, clearCurrent: false)
    }

    /// New ring events invalidate every derived view. In particular this reruns AAD
    /// after the database transaction has completed, so newly accumulated movement
    /// cannot leave yesterday's activity sessions cached on screen.
    private func refreshAfterSync(_ report: SyncReport) {
        guard report.inserted > 0 else { return }
        load(force: true, clearCurrent: false)
    }

    private func requestAutomaticSync() {
        Task {
            if let report = await ring.syncAutomaticallyIfNeeded() {
                refreshAfterSync(report)
            }
        }
    }

    // The heavy on-device models run off the main thread (load): show the fast
    // model-free summary first, then fold in the hypnogram / CVA / activity results.
    // Keep the screen awake for the whole pass so auto-lock cannot kill a long
    // analysis (same IdleTimerLock the BLE sync already uses).
    private func load(force: Bool = false, clearCurrent: Bool = false) {
        guard force || s == nil else { return }
        isRefreshingSummary = true
        loadGeneration += 1
        let generation = loadGeneration
        IdleTimerLock.acquire("models")
        #if TORCH
        let publishBase = s == nil || clearCurrent
        #else
        let publishBase = true
        #endif
        // Captured before the background hop: the last published summary is the
        // fallback if a model read fails mid-sync (withModels never replaces real
        // results with emptiness).
        let previous = s
        if clearCurrent { s = nil }
        modelProgress.begin(generation)
        let progress = modelProgress.sink(generation)
        DispatchQueue.global(qos: .userInitiated).async {
            let base = Core.base()
            if publishBase {
                DispatchQueue.main.async {
                    guard generation == loadGeneration else { return }
                    s = base
                    SummaryCache.save(base)
                    HealthExport.shared.push(base)
                }
            }
            #if TORCH
            if base.error == nil {
                let full = Core.withModels(base, previous: previous, progress: progress)
                DispatchQueue.main.async { finishLoad(generation, summary: full) }
            } else {
                DispatchQueue.main.async { finishLoad(generation, summary: nil) }
            }
            #else
            DispatchQueue.main.async { finishLoad(generation, summary: nil) }
            #endif
        }
    }

    private func finishLoad(_ generation: Int, summary: Summary?) {
        if generation == loadGeneration {
            if let summary {
                s = summary
                SummaryCache.save(summary)
                HealthExport.shared.push(summary)
            }
            isRefreshingSummary = false
            modelProgress.report(generation, nil)
        }
        IdleTimerLock.release("models")
    }

    @ViewBuilder private func content(_ s: Summary) -> some View {
        let latestTemp = s.nights.first { $0.skin_temp != nil }
        let latestOxygen = s.nights.first { $0.spo2_mean != nil }
        let recentTemperatures = Array(s.nights.compactMap(\.skin_temp).prefix(14).reversed())
        let recentOxygen = Array(s.nights.compactMap(\.spo2_mean).prefix(14).reversed())
        let latestHR = s.vitals.hr
        ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack {
                        Text("Open Oura").font(Obs.serif(24)).foregroundStyle(Obs.ink)
                        Text("BETA").font(Obs.mono(9, .bold)).tracking(1).foregroundStyle(Obs.ink2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Obs.trace, lineWidth: 0.8))
                        Spacer()
                        Button { showProfile = true } label: {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 17)).foregroundStyle(Obs.ink2)
                        }
                        SyncIndicatorButton(ring: ring) { showSync = true }
                    }

                    if let err = s.error {
                        ObsTag("no data"); Text(err).font(Obs.mono(13)).foregroundStyle(Obs.bad)
                    } else {
                        // digest headline
                        if let d = s.digest {
                            Text(d).font(Obs.prose(16, .regular)).foregroundStyle(Obs.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // today — last night's sleep + that day's activity as one unit, the
                        // hero of the home; tap the sleep or the activity region for its report.
                        if let day = s.days.first {
                            HStack(spacing: 9) {
                                ObsTag(displayedDayLabel(day), icon: "sun.max.fill")
                                if ring.busy || isRefreshingSummary {
                                    ProgressView().controlSize(.mini).scaleEffect(0.68).tint(Obs.ink)
                                    Text(modelProgress.label ?? "updating").font(Obs.mono(9, .medium))
                                        .tracking(0.8).foregroundStyle(Obs.ink2)
                                }
                            }
                            .animation(.easeInOut(duration: 0.2), value: ring.busy || isRefreshingSummary)
                            TodayCard(s: s, day: day,
                                      onSleep: { report = ReportSel(day: day, sleep: true) },
                                      onActivity: { report = ReportSel(day: day, sleep: false) })
                        }

                        // vitals
                        ObsTag("vitals", icon: "waveform.path.ecg")
                        HStack(alignment: .top, spacing: 24) {
                            VitalCell(tag: "nightly hrv", value: f(s.vitals.hrv.latest), unit: "ms",
                                      delta: s.vitals.hrv.delta_pct, series: s.vitals.hrv.series,
                                      baseline: s.vitals.hrv.baseline,
                                      action: { vital = .hrv })
                            VitalCell(tag: "heart rate",
                                      value: f(latestHR?.latest ?? s.vitals.rhr.latest), unit: "bpm",
                                      series: s.vitals.rhr.series,
                                      baseline: s.vitals.rhr.baseline,
                                      deltaGoodWhenPositive: false,
                                      detail: latestHR.map { latestLabel(date: $0.date, time: $0.hm) }
                                          ?? "nightly minimum",
                                      action: { vital = .heartRate })
                        }
                        HStack(alignment: .top, spacing: 24) {
                            VitalCell(tag: "skin temp",
                                      value: latestTemp?.skin_temp.map { String(format: "%.1f", $0) } ?? "—",
                                      unit: "°c",
                                      series: recentTemperatures,
                                      detail: latestTemp.map { latestLabel(date: s.wakeYmd($0)) },
                                      action: { vital = .temp })
                            VitalCell(tag: "blood o₂", value: f(latestOxygen?.spo2_mean), unit: "%",
                                      series: recentOxygen,
                                      detail: latestOxygen.map { latestLabel(date: s.wakeYmd($0)) },
                                      action: { vital = .oxygen })
                        }

                        if let debt = s.sleepDebt {
                            SleepDebtCard(debt: debt) { showSleepDebt = true }
                        }

                        if let illness = s.illness {
                            IllnessCard(illness: illness)
                        }

                        // Cardiovascular estimates belong together: vascular age/PWV
                        // from raw PPG plus the demographic VO₂max estimate.
                        if s.cardio?.vascular_age != nil || s.fitness?.vo2max != nil {
                            ObsTag("cardiovascular", icon: "heart.fill")
                            VStack(spacing: 12) {
                                if let cv = s.cardio, let va = cv.vascular_age {
                                    ObsStat(label: "vascular age", value: String(format: "%.1f yr", va))
                                    if let ca = cv.chronological_age { ObsStat(label: "vs your age", value: relAge(va - ca)) }
                                    if let pwv = cv.pwv_ms { ObsStat(label: "pulse-wave velocity", value: String(format: "%.2f m/s", pwv)) }
                                    if let seg = cv.segments { ObsStat(label: "segments analysed", value: "\(seg)") }
                                }
                                if let vo = s.fitness?.vo2max {
                                    ObsStat(label: "vo₂max estimate", value: String(format: "%.1f ml/kg/min", vo))
                                }
                            }
                            .obsCard()
                        }

                        // browse every day → per-day detail (sleep + activity)
                        if !s.days.isEmpty {
                            Button { showAllDays = true } label: {
                                HStack {
                                    Text("show all \(s.days.count) days").font(Obs.mono(12, .medium)).foregroundStyle(Obs.ink)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Obs.trace)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }

                        // on-device model failures (empty unless a torch model genuinely
                        // failed — a missing bundle or an inference error, not just no data)
                        if !s.modelErrors.isEmpty {
                            ObsTag("on-device models", icon: "exclamationmark.triangle")
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(s.modelErrors, id: \.self) { e in
                                    Text("• \(e)").font(Obs.mono(11)).foregroundStyle(Obs.bad)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }

                        // device & data health
                        ObsTag("device & data health", icon: "cpu")
                        VStack(spacing: 12) {
                            ObsStat(label: "serial", value: s.device?.serial ?? "—")
                            ObsStat(label: "firmware", value: s.device?.firmware ?? "—")
                            ObsStat(label: "battery",
                                    value: s.device?.battery_pct.map { "\($0)%" } ?? "—",
                                    accent: (s.device?.battery_pct ?? 100) < 20 ? Obs.bad : Obs.ink)
                            ObsStat(label: "synced",
                                    value: s.device.flatMap { d in d.synced.map { "\($0) \(d.synced_hm ?? "")" } } ?? "—")
                            ObsStat(label: "days of data",
                                    value: s.device?.days_of_data.map { String(format: "%.0f", $0) } ?? "—")
                            ObsStat(label: "nights", value: "\(s.device?.nights ?? s.nights.count)")
                        }
                        .obsCard()
                    }
                }
                .padding(24).padding(.top, 8)
            }
    }
}

@main
struct OuraApp: App {
    init() { DiagStore.shared.bootstrap() }
    var body: some Scene { WindowGroup { RootView() } }
}
