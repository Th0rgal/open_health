import SwiftUI

// The SwiftUI screens for OuraApp. Data types live in Models.swift, the model/FFI
// orchestration in Core.swift, the reusable charts/cells in Components.swift, and the
// full-page sleep/activity reports in Reports.swift.
// SIBLING CLIENT: the web dashboard (dashboard/web/app.js) renders the SAME summary
// JSON — a user-facing change here usually belongs there too (docs/clients.md).

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
    @State private var key = Keychain.loadKey() ?? ""
    @ObservedObject private var diag = RingDiag.shared
    @ObservedObject private var store = DiagStore.shared
    @State private var copied = false
    @State private var diagnosticFile: URL?
    @State private var showKey = false
    @State private var showDiagnostics = false
    @State private var confirmReset = false
    @FocusState private var keyFocused: Bool

    private var validKey: Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.utf8.count == 32 && trimmed.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    if ring.connectionIssue != nil { syncStatus }
                    else { preparation }
                    if !ring.busy { pairingKey }
                    connection
                    support
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Obs.paper)
            .navigationTitle("Your ring")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Obs.ink)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { keyFocused = false }
                }
            }
            .alert("Reset local sync data?", isPresented: $confirmReset) {
                Button("Cancel", role: .cancel) {}
                Button("Reset local data", role: .destructive) {
                    Task { if await ring.resetLocalDatabase() { onReset() } }
                }
            } message: {
                Text("This removes the synced data on this iPhone. Your next sync will download the history still available on your ring.")
            }
        }
        .tint(Obs.ink)
        // Sync belongs to RingSync and continues when this panel is dismissed.
        .sheet(isPresented: Binding(get: { diagnosticFile != nil }, set: { if !$0 { diagnosticFile = nil } })) {
            if let diagnosticFile { DiagnosticsShare(url: diagnosticFile) }
        }
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "circle.circle")
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(Obs.ink2)
                .frame(width: 56, height: 56)
                .background(Obs.rule.opacity(0.45), in: Circle())
                .accessibilityHidden(true)
                .padding(.bottom, 6)
            Text("Pair your ring")
                .font(.system(.largeTitle, design: .serif))
                .foregroundStyle(Obs.ink)
            Text("Bring your health history to this iPhone.")
                .font(.subheadline)
                .foregroundStyle(Obs.ink2)
        }
    }

    private var preparation: some View {
        VStack(alignment: .leading, spacing: 18) {
            setupRow(icon: "bolt", title: "Place your ring on its charger",
                     detail: "Keep it close to this iPhone.")
            setupRow(icon: "antenna.radiowaves.left.and.right", title: "Free up the Bluetooth connection",
                     detail: "Turn off Bluetooth on other phones using the Oura app. Keep it on here.")
        }
    }

    private func setupRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Obs.muted)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Obs.ink)
                Text(detail).font(.subheadline).foregroundStyle(Obs.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var pairingKey: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pairing key").font(.subheadline.weight(.semibold)).foregroundStyle(Obs.ink)
            HStack(spacing: 8) {
                Group {
                    if showKey { TextField("Paste your pairing key", text: $key) }
                    else { SecureField("Paste your pairing key", text: $key) }
                }
                .font(.system(.subheadline, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($keyFocused)
                .accessibilityLabel("Pairing key")
                .disabled(ring.busy)
                Button { showKey.toggle() } label: {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(showKey ? "Hide pairing key" : "Show pairing key")
            }
            .foregroundStyle(Obs.ink)
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .background(Obs.rule.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(keyFocused ? Obs.muted : Obs.rule))
            Text(!key.isEmpty && !validKey
                 ? "Use all 32 characters: numbers 0–9 and letters A–F."
                 : "Paste the 32-character key exported on your computer.")
                .font(.footnote)
                .foregroundStyle(Obs.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var syncStatus: some View {
        if ring.busy || !ring.status.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                if ring.busy {
                    ProgressView().tint(Obs.ink).frame(width: 24, height: 24)
                } else {
                    Image(systemName: ring.lastReport != nil ? "checkmark.circle" : "info.circle")
                        .font(.title3)
                        .foregroundStyle(ring.lastReport != nil ? Obs.good : Obs.ink2)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(ring.busy ? "Sync in progress" : (ring.connectionIssue ?? (ring.lastReport != nil ? "Your ring is up to date" : "Sync status")))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Obs.ink)
                    Text(ring.status)
                        .font(.subheadline).foregroundStyle(Obs.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    if ring.busy {
                        Text("Keep the app open. If the connection drops, sync resumes automatically.")
                            .font(.footnote).foregroundStyle(Obs.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Obs.rule.opacity(0.3), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if ring.connectionIssue == nil { syncStatus }
            if ring.busy {
                Button { ring.pause() } label: {
                    Label("Pause sync", systemImage: "pause")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .foregroundStyle(Obs.ink)
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Obs.rule))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    keyFocused = false
                    Task {
                        if let report = await ring.run(keyHex: key) { onSynced(report) }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Text("Connect & sync")
                        Image(systemName: "arrow.right")
                    }
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .foregroundStyle(validKey ? Obs.paper : Obs.muted)
                    .background(validKey ? Obs.ink : Obs.rule, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(!validKey)
                Text("The first sync downloads your ring’s available history and may take a few minutes.")
                    .font(.footnote).foregroundStyle(Obs.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var support: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(Obs.rule).frame(height: 1)
            DisclosureGroup(isExpanded: $showDiagnostics) {
                VStack(alignment: .leading, spacing: 18) {
                    Button { Task { await ring.checkDatabase() } } label: {
                        Label("Check database", systemImage: "externaldrive")
                            .frame(minHeight: 44)
                    }
                    .disabled(ring.busy)
                    Button {
                        Task {
                            let url = await Task.detached { DiagStore.shared.exportFile() }.value
                            if let url { diagnosticFile = url }
                        }
                    } label: {
                        Label("Share detailed diagnostics", systemImage: "square.and.arrow.up")
                            .frame(minHeight: 44)
                    }
                    diagnosticHistory
                    Button(role: .destructive) { confirmReset = true } label: {
                        Label("Reset local sync data", systemImage: "trash")
                            .foregroundStyle(Obs.alert)
                            .frame(minHeight: 44)
                    }
                    .disabled(ring.busy)
                }
                .font(.subheadline)
                .padding(.top, 16)
            } label: {
                Label("Troubleshooting & diagnostics", systemImage: "wrench.and.screwdriver")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Obs.ink2)
                    .frame(minHeight: 44)
            }
        }
    }

    private var diagnosticHistory: some View {
        // live transcript + leftover logs from previous crashes / kills.
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("diagnostics")
                    .font(Obs.mono(11)).foregroundStyle(Obs.ink2)
                Spacer()
                Button(copied ? "copied ✓" : "Copy summary") {
                    Task {
                        let text = await Task.detached { DiagStore.shared.exportSummary() }.value
                        UIPasteboard.general.string = text
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    }
                }
                .font(Obs.mono(11, .medium)).foregroundStyle(Obs.ink)
            }
            if !store.incidents.isEmpty {
                Text("diagnostic reports · \(store.incidents.count)")
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
                Text("No recorded incidents. Interrupted sessions are retained without assuming a crash.")
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

    }
}

private struct DiagnosticsShare: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
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
            requestAutomaticSync()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
            requestAutomaticSync()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                requestAutomaticSync()
            } else if phase == .background {
                WorkCoordinator.shared.invalidateAnalysis()
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
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        Task {
            _ = await ring.syncAutomaticallyIfNeeded()
            if WorkCoordinator.shared.available { load(force: true, clearCurrent: false) }
        }
    }

    private func load(force: Bool = false, clearCurrent: Bool = false) {
        guard force || s == nil else { return }
        let run = WorkCoordinator.shared.newAnalysis()
        loadGeneration += 1
        let generation = loadGeneration
        let previous = clearCurrent ? nil : s
        if clearCurrent { s = nil }
        isRefreshingSummary = true
        modelProgress.begin(generation)
        let progress = modelProgress.sink(generation)
        Task {
            await WorkGate.shared.acquire()
            guard !run.isCancelled, WorkCoordinator.shared.available else {
                await WorkGate.shared.release()
                WorkCoordinator.shared.finishAnalysis(run)
                if generation == loadGeneration { isRefreshingSummary = false; modelProgress.report(generation, "paused") }
                return
            }
            IdleTimerLock.acquire("models")
            dlog("models", "start run=\(run.id)")
            let started = ProcessInfo.processInfo.systemUptime
            let full: Summary = await withCheckedContinuation { completion in
                DispatchQueue.global(qos: .userInitiated).async {
                    let summary = run.perform {
                        let base = Core.base()
                        #if TORCH
                        return base.error == nil && !run.isCancelled
                            ? Core.withModels(base, previous: previous, progress: progress) : base
                        #else
                        return base
                        #endif
                    }
                    completion.resume(returning: summary)
                }
            }
            if generation == loadGeneration {
                if !run.isCancelled, WorkCoordinator.shared.available {
                    if full.error == nil {
                        s = full
                        SummaryCache.save(full)
                        HealthExport.shared.push(full)
                    } else if s == nil { s = full }
                    modelProgress.report(generation, full.error == nil ? nil : "refresh failed")
                } else { modelProgress.report(generation, "paused") }
                isRefreshingSummary = false
            }
            dlog("models", "end run=\(run.id) cancelled=\(run.isCancelled) duration=\(Int(ProcessInfo.processInfo.systemUptime - started))s")
            IdleTimerLock.release("models")
            WorkCoordinator.shared.finishAnalysis(run)
            await WorkGate.shared.release()
        }
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
