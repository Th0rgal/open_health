import SwiftUI
import UniformTypeIdentifiers

// The SwiftUI screens for OuraApp. Data types live in Models.swift, the model/FFI
// orchestration in Core.swift, the reusable charts/cells in Components.swift, and the
// full-page sleep/activity reports in Reports.swift.
// SIBLING CLIENT: the web dashboard (dashboard/web/app.js) renders the SAME summary
// JSON — a user-facing change here usually belongs there too (docs/clients-web-and-ios.md).

struct SyncView: View {
    @ObservedObject var ring: RingSync
    /// Identity and data counts from the latest summary; the ring's own report overrides them.
    var device: Device? = nil
    let onSynced: (SyncReport) -> Void
    let onReset: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var key = Keychain.loadKey() ?? ""
    @ObservedObject private var diag = RingDiag.shared
    @ObservedObject private var store = DiagStore.shared
    @State private var diagnosticFile: URL?
    @State private var showKey = false
    @State private var keyExpanded = false
    @State private var keyCopied = false
    @State private var clockReport: String?
    @State private var confirmReset = false
    @State private var confirmWipeRing = false
    @State private var showRestorePicker = false
    @State private var restoreNote: String?
    @FocusState private var keyFocused: Bool

    /// Validate the chosen file before it replaces anything: a truncated download or
    /// the wrong file entirely must not destroy a working database.
    private func restore(from result: Result<[URL], Error>) -> String {
        guard case .success(let urls) = result, let picked = urls.first else { return "Restore cancelled." }
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-candidate.db")
        do {
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.copyItem(at: picked, to: staging)
        } catch { return "Could not read that file: \(error.localizedDescription)" }

        do {
            let verdict = try databaseIntegrity(dbPath: staging.path)
            guard verdict.lowercased().contains("ok") else {
                return "That file is not a healthy database (\(verdict)). Nothing changed."
            }
        } catch { return "That file is not an Open Oura backup. Nothing changed." }

        do {
            try DB.resetWritableStore()
            try FileManager.default.copyItem(at: staging, to: DB.url)
            try? FileManager.default.removeItem(at: staging)
        } catch { return "Restore failed midway: \(error.localizedDescription)" }
        return "Restored. The next sync continues from where the backup left off."
    }

    private var validKey: Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.utf8.count == 32 && trimmed.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    /// A sync or pairing has succeeded and the key is stored: the setup instructions and
    /// the key field give way to the ring's status and a single sync button.
    private var paired: Bool { ring.knownSerial != nil && validKey }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if paired {
                        ringCard
                        connection
                        if ring.connectionIssue != nil { preparation }
                        if !ring.busy { keyDisclosure }
                    } else {
                        if ring.connectionIssue != nil { syncStatus }
                        else { preparation }
                        if !ring.busy { pairingKey }
                        connection
                    }
                    support
                    BuildStamp()
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
            .alert("Factory-reset \(ring.knownSerial ?? "the ring")?", isPresented: $confirmWipeRing) {
                Button("Cancel", role: .cancel) {}
                Button("Erase the ring", role: .destructive) {
                    let serial = ring.knownSerial ?? ""
                    let current = key
                    Task {
                        if await ring.factoryReset(keyHex: current, confirmSerial: serial) {
                            key = ""
                            showKey = false
                        }
                    }
                }
            } message: {
                Text("Erases the ring's pairing key, its Bluetooth bonds, any events it hasn't sent yet, and your stored body profile. Sync first if you want those events. This cannot be undone — but the ring stays yours: pair it again right here afterwards.")
            }
        }
        .tint(Obs.ink)
        // Sync belongs to RingSync and continues when this panel is dismissed.
        .sheet(isPresented: Binding(get: { diagnosticFile != nil }, set: { if !$0 { diagnosticFile = nil } })) {
            if let diagnosticFile { DiagnosticsShare(url: diagnosticFile) }
        }
        .fileImporter(isPresented: $showRestorePicker,
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: false) { result in
            restoreNote = restore(from: result)
            if restoreNote?.hasPrefix("Restored") == true { onReset() }
        }
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        Text(paired ? "Your ring" : "Pair your ring")
            .font(Obs.serif(28))
            .foregroundStyle(Obs.ink)
    }

    /// Identity, charge and data counts: the ring's own report from the latest sync, else the
    /// values stored in the database.
    private var ringCard: some View {
        let info = ring.info
        let battery = info?.batteryPct ?? device?.battery_pct
        return VStack(spacing: 0) {
            ringCardRow("Serial", info?.serial ?? ring.knownSerial ?? device?.serial ?? "–")
            SupportDivider()
            ringCardRow("Firmware", info.flatMap { $0.firmware.isEmpty ? nil : $0.firmware } ?? device?.firmware ?? "–")
            SupportDivider()
            ringCardRow("Battery", battery.map { "\($0)%" } ?? "–", tint: (battery ?? 100) < 20 ? Obs.alert : Obs.ink)
            SupportDivider()
            ringCardRow("Last synced", ring.lastSuccessfulSyncAt.map(Self.relative)
                        ?? device?.synced.map { "\($0) \(device?.synced_hm ?? "")" } ?? "Never")
            if let raw = device?.raw_events ?? device?.total_events {
                SupportDivider()
                ringCardRow("Events", device?.decoded_events.map { "\(raw) raw · \($0) decoded" } ?? "\(raw)")
            }
            if let span = device?.days_of_data {
                SupportDivider()
                let observed = device?.observed_days.map { " (\($0) observed)" } ?? ""
                ringCardRow("Data", "\(String(format: "%.0f", span)) days\(observed) · \(device?.nights ?? 0) nights")
            }
        }
        .padding(.horizontal, 16)
        .background(Obs.rule.opacity(0.3), in: RoundedRectangle(cornerRadius: 16))
    }

    private func ringCardRow(_ label: String, _ value: String, tint: Color = Obs.ink) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(Obs.ink2)
            Spacer()
            Text(value).font(Obs.sans(13)).foregroundStyle(tint)
        }
        .padding(.vertical, 12)
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    /// The stored key, one tap away: for a backup, or to replace it.
    private var keyDisclosure: some View {
        DisclosureGroup(isExpanded: $keyExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                pairingKey
                Button {
                    UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: key]],
                                                  options: [.expirationDate: Date().addingTimeInterval(60)])
                    keyCopied = true
                } label: {
                    Label(keyCopied ? "Copied for 60 seconds" : "Copy key", systemImage: keyCopied ? "checkmark" : "doc.on.doc")
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Obs.ink)
                .disabled(!validKey)
            }
            .padding(.top, 10)
        } label: {
            Text("Pairing key")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Obs.ink)
        }
        .tint(Obs.ink2)
        .onChange(of: keyExpanded) { _, open in
            if !open { showKey = false; keyCopied = false; keyFocused = false }
        }
    }

    private var preparation: some View {
        VStack(alignment: .leading, spacing: 12) {
            setupRow(icon: "bolt", title: "Put the ring on its charger, next to this iPhone", detail: nil)
            setupRow(icon: "antenna.radiowaves.left.and.right", title: "Free the Bluetooth link",
                     detail: "Turn Bluetooth off on other phones running the Oura app.")
        }
    }

    private func setupRow(icon: String, title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Obs.muted)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Obs.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(.footnote).foregroundStyle(Obs.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var pairingKey: some View {
        VStack(alignment: .leading, spacing: 10) {
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
            if !key.isEmpty && !validKey {
                Text("Use all 32 characters: numbers 0–9 and letters A–F.")
                    .font(.footnote)
                    .foregroundStyle(Obs.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            pairReset
        }
    }

    /// Adopt a factory-reset ring without a computer: mint the key on this iPhone.
    private var pairReset: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                keyFocused = false
                Task { if let minted = await ring.pair() { key = minted } }
            } label: {
                (Text("No key? ").foregroundStyle(Obs.ink2)
                 + Text("Pair a factory-reset ring").foregroundStyle(Obs.ink).underline())
                    .font(.footnote)
            }
            .buttonStyle(.plain)
            .disabled(ring.busy)
            Text("Write the new key down: it cannot be read back from the ring.")
                .font(.footnote)
                .foregroundStyle(Obs.muted)
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
                        Text("Sync continues if you switch apps and resumes after a dropped connection. Saved data is never discarded.")
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
                        Text(paired ? "Sync now" : "Connect & sync")
                        Image(systemName: paired ? "arrow.triangle.2.circlepath" : "arrow.right")
                    }
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .foregroundStyle(validKey ? Obs.paper : Obs.muted)
                    .background(validKey ? Obs.ink : Obs.rule, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(!validKey)
                if ring.lastSuccessfulSyncAt == nil {
                    Text("Your first sync may take a few minutes.")
                        .font(.footnote).foregroundStyle(Obs.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // Help & diagnostics: one quiet card of grouped rows instead of nested disclosures.
    // Everyday actions first, the technical transcript one tap deeper, destructive last.
    private var support: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Help & diagnostics")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Obs.ink)
                Spacer()
                Text(appVersion).font(Obs.sans(11)).foregroundStyle(Obs.muted)
            }
            VStack(spacing: 0) {
                SupportRow(icon: "arrow.down.doc", title: "Export data",
                           detail: ring.exportStatus ?? "One file with every synced event",
                           disabled: ring.busy || ring.exportStatus != nil) {
                    Task { if let url = await ring.exportRawDatabase() { diagnosticFile = url } }
                }
                SupportDivider()
                NavigationLink {
                    ResearchExportView()
                } label: {
                    SupportRowLabel(icon: "tablecells", title: "Research export",
                                    detail: "Every heart beat and movement as CSV", trailing: "chevron.right")
                }
                .buttonStyle(.plain)
                SupportDivider()
                SupportRow(icon: "arrow.up.doc", title: "Restore from a backup",
                           detail: restoreNote ?? "Replaces what this iPhone holds",
                           disabled: ring.busy) { showRestorePicker = true }
                SupportDivider()
                NavigationLink {
                    RawDataView()
                } label: {
                    SupportRowLabel(icon: "waveform.path.ecg", title: "Raw data & charts",
                                    detail: "Every event the ring sent", trailing: "chevron.right")
                }
                .buttonStyle(.plain)
                SupportDivider()
                NavigationLink {
                    TechnicalReportsView(clockReport: $clockReport,
                                         checkDisabled: ring.busy,
                                         onCheck: { Task { await ring.checkDatabase() } },
                                         onShare: {
                                             Task {
                                                 let url = await Task.detached { DiagStore.shared.exportFile() }.value
                                                 if let url { diagnosticFile = url }
                                             }
                                         })
                } label: {
                    SupportRowLabel(icon: "doc.text.magnifyingglass", title: "Technical reports",
                                    detail: technicalSummary, trailing: "chevron.right")
                }
                .buttonStyle(.plain)
            }
            .background(Obs.rule.opacity(0.3), in: RoundedRectangle(cornerRadius: 16))

            VStack(spacing: 0) {
                SupportRow(icon: "trash", title: "Reset local sync data",
                           detail: "The next sync fetches it again",
                           tint: Obs.alert, disabled: ring.busy) { confirmReset = true }
                SupportDivider()
                SupportRow(icon: "exclamationmark.triangle", title: "Factory-reset the ring",
                           detail: ring.knownSerial == nil
                               ? "Available after the first sync"
                               : "Wipes the ring. Pair it again afterwards",
                           tint: Obs.alert,
                           disabled: ring.busy || ring.knownSerial == nil || !validKey) { confirmWipeRing = true }
            }
            .background(Obs.alert.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Obs.alert.opacity(0.18)))
        }
    }

    private var appVersion: String {
        // The plain swiftc simulator build ships Info.plist with unexpanded $(…) values.
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        guard !short.isEmpty, !short.contains("$(") else { return "" }
        return build.isEmpty || build.contains("$(") ? "v\(short)" : "v\(short) (\(build))"
    }

    private var technicalSummary: String {
        var parts: [String] = []
        if !store.incidents.isEmpty { parts.append("\(store.incidents.count) incidents") }
        if !store.sessions.isEmpty { parts.append("\(store.sessions.count) sessions") }
        if diag.totalLines > 0 { parts.append("\(diag.totalLines) log lines") }
        return parts.isEmpty ? "Ring clock, incidents and the live log" : parts.joined(separator: " · ")
    }
}

/// One tappable row of the Help & diagnostics card.
private struct SupportRow: View {
    let icon: String
    let title: String
    let detail: String
    var tint: Color = Obs.ink
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            SupportRowLabel(icon: icon, title: title, detail: detail, tint: tint, trailing: nil)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}

private struct SupportRowLabel: View {
    let icon: String
    let title: String
    let detail: String
    var tint: Color = Obs.ink
    let trailing: String?
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(tint == Obs.ink ? Obs.ink2 : tint)
                .frame(width: 32, height: 32)
                .background(Obs.paper.opacity(0.85), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(tint)
                Text(detail).font(.footnote).foregroundStyle(Obs.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let trailing {
                Image(systemName: trailing).font(.system(size: 12, weight: .semibold)).foregroundStyle(Obs.trace)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}

private struct SupportDivider: View {
    var body: some View { Rectangle().fill(Obs.rule).frame(height: 0.6).padding(.leading, 60) }
}

/// The technical transcript on its own page: ring clock anchors, recorded incidents,
/// previous sessions and the live log, each with a copy action.
private struct TechnicalReportsView: View {
    @Binding var clockReport: String?
    var checkDisabled: Bool = false
    var onCheck: () -> Void = {}
    var onShare: () -> Void = {}
    @ObservedObject private var diag = RingDiag.shared
    @ObservedObject private var store = DiagStore.shared
    @State private var copied: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    Button { onShare() } label: {
                        Label("Share report", systemImage: "square.and.arrow.up")
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1).minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Obs.rule))
                    }
                    Button { onCheck() } label: {
                        Label("Check data", systemImage: "externaldrive")
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1).minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Obs.rule))
                    }
                    .disabled(checkDisabled)
                }
                .buttonStyle(.plain).foregroundStyle(Obs.ink)
                section("Ring clock", copy: clockReport) {
                    Text(clockReport ?? "No summary rendered yet.")
                        .font(.caption.monospaced()).foregroundStyle(clockReport == nil ? Obs.muted : Obs.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                section("Incidents · \(store.incidents.count)", copy: nil) {
                    if store.incidents.isEmpty {
                        Text("No incidents recorded.").font(.caption).foregroundStyle(Obs.muted)
                    }
                    ForEach(store.incidents.prefix(8)) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(item.title).font(.caption.weight(.medium)).foregroundStyle(Obs.ink)
                                Spacer()
                                Text(item.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    .font(.caption2).foregroundStyle(Obs.muted)
                            }
                            Text(item.preview).font(.caption.monospaced()).foregroundStyle(Obs.ink2)
                                .lineLimit(5).frame(maxWidth: .infinity, alignment: .leading)
                            copyButton("incident-\(item.id)", text: item.body)
                        }
                        .padding(10)
                        .background(Obs.paper.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                if !store.sessions.isEmpty {
                    section("Previous sessions · \(store.sessions.count)", copy: nil) {
                        ForEach(store.sessions.prefix(4)) { item in
                            HStack {
                                Text(item.title).font(Obs.sans(11)).foregroundStyle(Obs.ink2)
                                Spacer()
                                copyButton("session-\(item.id)", text: item.body)
                            }
                        }
                    }
                }
                section("Current session · \(diag.totalLines) lines", copy: nil) {
                    HStack {
                        Spacer()
                        Button(copied == "summary" ? "Copied" : "Copy summary") {
                            Task {
                                let text = await Task.detached { DiagStore.shared.exportSummary() }.value
                                UIPasteboard.general.string = text
                                flash("summary")
                            }
                        }
                        .font(.caption.weight(.medium)).foregroundStyle(Obs.ink).frame(minHeight: 32)
                    }
                    if diag.totalLines > 0 {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(diag.tail.enumerated()), id: \.offset) { _, line in
                                    Text(line).font(Obs.sans(11)).foregroundStyle(Obs.ink2)
                                        .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(8)
                        }
                        .defaultScrollAnchor(.bottom)
                        .frame(maxHeight: 260)
                        .background(Obs.paper.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                    } else {
                        Text("Nothing logged yet.").font(.caption).foregroundStyle(Obs.muted)
                    }
                }
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 24).padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .background(Obs.paper)
        .navigationTitle("Technical reports")
        .navigationBarTitleDisplayMode(.inline)
        .task { if clockReport == nil { clockReport = await Task.detached { ClockReport.text() }.value } }
    }

    private func section<Content: View>(_ title: String, copy: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Obs.sans(11, .medium)).foregroundStyle(Obs.muted)
                Spacer()
                if let copy { copyButton(title, text: copy) }
            }
            content()
        }
        .padding(14)
        .background(Obs.rule.opacity(0.3), in: RoundedRectangle(cornerRadius: 16))
    }

    private func copyButton(_ id: String, text: String) -> some View {
        Button(copied == id ? "Copied" : "Copy") {
            UIPasteboard.general.string = text
            flash(id)
        }
        .font(.caption.weight(.medium)).foregroundStyle(Obs.ink).frame(minHeight: 32)
    }

    private func flash(_ id: String) {
        copied = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if copied == id { copied = nil } }
    }
}

/// Human-readable rendering of the shared brain's `clock` block (per-boot ring clock
/// anchors), from the last rendered summary. Shown in Technical reports and appended
/// to the shared diagnostic report so a misdated night can be diagnosed remotely.
enum ClockReport {
    static func text() -> String? {
        guard let clock = SummaryCache.load()?.clock else { return nil }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH:mm"; fmt.timeZone = .current
        let day = { (unix: Int64?) -> String in unix.map { fmt.string(from: Date(timeIntervalSince1970: Double($0))) } ?? "–" }
        var lines: [String] = []
        for (i, e) in clock.epochs.enumerated() {
            let sources = (e.anchor_sources ?? []).joined(separator: ",")
            lines.append("boot \(i + 1): ds \(e.min_ds ?? 0)…\(e.max_ds ?? 0) (\(e.span_h ?? 0)h) synced \(day(e.capture_min))…\(day(e.capture_max)) anchors=\(e.anchors ?? 0)\(sources.isEmpty ? "" : " [\(sources)]") latest=\(day(e.latest_anchor_unix))")
        }
        for n in clock.undated_nights {
            lines.append("undated night: ds \(n.start_ds ?? 0)…\(n.end_ds ?? 0) \(n.in_bed_h ?? 0)h captured \(day(n.captured_unix)) (\(n.source ?? "?"))")
        }
        lines.append(contentsOf: clock.warnings.map { "warning: \($0)" })
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

struct DiagnosticsShare: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The sync status glyph: a circle that fills with the drain progress while the ring syncs, the
/// sync arrow turning slowly while BLE is active and green once the ring is synced.
private struct SyncGlyph: View {
    @ObservedObject var ring: RingSync
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation = 0.0

    var body: some View {
        ZStack {
            Circle().stroke(Obs.rule, lineWidth: 0.8)
            if ring.busy, let fraction = ring.drainFraction {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Obs.ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(ring.busy ? Obs.ink : Obs.good)
                .rotationEffect(.degrees(rotation))
        }
        .frame(width: size, height: size)
        .accessibilityLabel(ring.busy ? "Ring sync in progress" : "Ring synced")
        .onAppear(perform: updateAnimation)
        .onChange(of: ring.busy) { _, _ in updateAnimation() }
        .onChange(of: reduceMotion) { _, _ in updateAnimation() }
    }

    private func updateAnimation() {
        if ring.busy && !reduceMotion {
            rotation = 0
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { rotation = 360 }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { rotation = 0 }
        }
    }
}

/// The line under the screen title. It shows the sync glyph while the ring syncs, keeps it green
/// with a spinner beside it while the synced data is analyzed, and disappears when both are done.
private struct SyncStatusLine: View {
    @ObservedObject var ring: RingSync
    let analyzing: Bool
    let label: String?
    /// A sync ran in this cycle, so the glyph stays after it ends.
    @State private var synced = false

    private var visible: Bool { ring.busy || analyzing }

    var body: some View {
        Group {
            if visible {
                HStack(spacing: 7) {
                    if ring.busy || synced { SyncGlyph(ring: ring, size: 18) }
                    if analyzing && !ring.busy {
                        ProgressView().controlSize(.mini).scaleEffect(0.68).tint(Obs.ink)
                    }
                    Text((ring.busy ? "Syncing ring" : (label ?? "Analyzing saved data")))
                        .font(Obs.sans(11, .medium)).foregroundStyle(Obs.ink2)
                        .lineLimit(1)
                }
            }
        }
        .onChange(of: ring.busy) { _, busy in if busy { synced = true } }
        .onChange(of: visible) { _, now in
            guard !now else { return }
            // The analysis follows a sync after a moment; reset only if nothing started.
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !visible { synced = false }
            }
        }
    }
}

// ── root ─────────────────────────────────────────────────────────────────────
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var s: Summary? = SummaryCache.load()
    @State private var report: ReportSel?
    /// QA hooks for `simctl launch … -openSync` / `-openDay YYYY-MM-DD [activity]`, so
    /// a screen can be captured without driving the UI. Ignored in normal launches.
    private func applyLaunchArguments() {
        let args = CommandLine.arguments
        dlog("keychain", "pairing key \(Keychain.loadKey() == nil ? "missing" : "present")")
        if args.contains("-openSync") { showSync = true }
        if args.contains("-openAllDays") { showAllDays = true }
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        if let v = value("-tab"), let t = AppTab(rawValue: v) { tab = t }
        if let v = value("-score"), let k = ScoreKind(rawValue: v) { scoreKind = k; if value("-noSheet") == nil { scoreSheet = k } }
        if let v = value("-metric"), let m = MetricID(rawValue: v) { metricSheet = m }
        if let v = value("-day") { homeDay = v }
        if args.contains("-liveDemo") { live.demo() }
        if args.contains("-openRadar") { showRadar = true }
        if args.contains("-openProfile") { showProfile = true }
        if args.contains("-hopDay") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if let s, s.days.count > 3 { homeDay = s.days[3] } }
        }
        if args.contains("-openDebt") { showSleepDebt = true }
        if args.contains("-syncNow"), let key = Keychain.loadKey() {
            Task { _ = await ring.run(keyHex: key, source: "launch-argument") }
        }
        if let index = args.firstIndex(of: "-benchDrain"), index + 1 < args.count, let days = UInt32(args[index + 1]) {
            let mode = args.firstIndex(of: "-bleMode").flatMap { $0 + 1 < args.count ? Int32(args[$0 + 1]) : nil } ?? -1
            Task { await ring.benchDrain(days: days, bleMode: mode) }
        }
        #if TORCH
        if args.contains("-recomputeAll") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { recomputeAll() }
        }
        #endif
        if let index = args.firstIndex(of: "-openDay"), index + 1 < args.count {
            report = ReportSel(day: args[index + 1], sleep: !args.contains("activity"))
        }
    }
    @State private var showAllDays = false
    @State private var showActivities = false
    /// The day every daily panel shows; nil until the pager reports the latest.
    @State private var homeDay: String?
    @State private var showSync = false
    @State private var showProfile = false
    @State private var showSleepDebt = false
    @State private var showVo2 = false
    @State private var vital: VitalKind?
    @State private var tab: AppTab = .today
    @State private var scoreKind: ScoreKind = .sleep
    @State private var scoreSheet: ScoreKind?
    @State private var metricSheet: MetricID?
    @State private var showRadar = false
    @State private var loadGeneration = 0
    @State private var isRefreshingSummary = false
    @State private var automaticSyncRequested = false
    @State private var reloadPending = false
    @StateObject private var ring = RingSync()
    @StateObject private var live = LiveHeartRate()
    @StateObject private var modelProgress = ModelProgress()
    var body: some View {
        ZStack {
            Obs.canvas.ignoresSafeArea()
            if let s {
                content(s)
            } else {
                VStack(spacing: 14) {
                    ProgressView().tint(Obs.ink)
                    Text("Loading your data…").font(Obs.sans(12)).foregroundStyle(Obs.ink2)
                }
            }
        }
        .environment(\.radarAnalyzing, modelProgress.radarActive)
        .environment(\.openRingCapture, { showProfile = true })
        .fullScreenCover(item: $report) { sel in if let s { DayReportView(s: s, day: sel.day, tab: sel.sleep ? .sleep : .activity) } }
        .sheet(isPresented: $showAllDays) {
            if let s { HistoryView(s: s, selected: shownDay(s), onSelect: { homeDay = $0 }) }
        }
        .onAppear(perform: applyLaunchArguments)
        .sheet(isPresented: $showSync) {
            SyncView(ring: ring, device: s?.device, onSynced: refreshAfterSync, onReset: resetAndReload)
        }
        .sheet(isPresented: $showActivities) {
            if let s { ActivityTimelineView(s: s, day: shownDay(s), store: ActivityLogStore.shared, ring: ring, onFinished: refreshDerivedData) }
        }
        .sheet(isPresented: $showProfile) {
            ProfileSettingsView(profile: s?.profile, recompute: recomputeHook, ring: ring, onSaved: refreshDerivedData)
        }
        .sheet(isPresented: $showVo2) { if let s { Vo2DetailView(s: s) } }
        .sheet(isPresented: $showSleepDebt) {
            if let s { DebtDetailView(s: s, day: shownDay(s), onOpenDay: openReport) }
        }
        .sheet(item: $vital) { kind in if let s { VitalTrendView(s: s, kind: kind) } }
        .sheet(item: $scoreSheet) { kind in
            if let s { ScoreDetailView(s: s, kind: kind, day: shownDay(s), onOpenDay: openReport) }
        }
        .sheet(item: $metricSheet) { id in
            if let s { MetricDetailView(s: s, id: id, day: shownDay(s), onOpenDay: openReport) }
        }
        .sheet(isPresented: $showRadar) {
            if let s, let radar = s.symptomRadar { RadarDetailView(s: s, illness: radar, day: shownDay(s)) }
        }
        #if TORCH
        .environment(\.dayAnalysis, DayAnalysisContext(summary: s,
            isBusy: isRefreshingSummary || ring.busy, refresh: refreshDayAnalysis))
        #endif
        .onAppear {
            // A cached summary makes launch immediate; this forced load replaces it
            // with SQLite + model output without blanking the existing Today card.
            requestAutomaticSync()
        }
        .onReceive(NotificationCenter.default.publisher(for: .summaryNeedsReload)) { _ in load(force: true) }
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

    /// The profile screen's "Recompute everything": only where the models exist.
    private var recomputeHook: RecomputeHook? {
        #if TORCH
        RecomputeHook(run: recomputeAll, label: modelProgress.label, busy: isRefreshingSummary || ring.busy)
        #else
        nil
        #endif
    }

    #if TORCH
    /// Drops every cached model result and reruns the models over all saved data. The
    /// current summary stays on screen until the new one is complete.
    private func recomputeAll() {
        guard !isRefreshingSummary, !ring.busy else { return }
        ModelCacheStore.clearAll()
        load(force: true, clearCurrent: false)
    }
    #endif

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
        guard !automaticSyncRequested else { return }
        automaticSyncRequested = true
        Task {
            defer { automaticSyncRequested = false }
            // At cold launch the app can still report itself inactive when onAppear
            // fires, and no later scene change follows; wait briefly for it.
            for _ in 0..<5 where !WorkCoordinator.shared.available {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            _ = await ring.syncAutomaticallyIfNeeded()
            if WorkCoordinator.shared.available { load(force: true, clearCurrent: false) }
        }
    }

    #if TORCH
    @MainActor private func refreshDayAnalysis(_ request: DayAnalysisRequest) async -> String? {
        guard !isRefreshingSummary, !ring.busy, let previous = s else {
            return "Wait for sync and analysis to finish, then try again."
        }
        guard WorkCoordinator.shared.available else { return "Keep the app open to refresh analysis." }
        let run = WorkCoordinator.shared.newAnalysis()
        loadGeneration += 1
        let generation = loadGeneration
        isRefreshingSummary = true
        defer {
            if reloadPending {
                reloadPending = false
                load(force: true, clearCurrent: false)
            }
        }
        modelProgress.begin(generation)
        let progress = modelProgress.sink(generation)
        await WorkGate.shared.acquire()
        guard !run.isCancelled, WorkCoordinator.shared.available else {
            await WorkGate.shared.release()
            WorkCoordinator.shared.finishAnalysis(run)
            if generation == loadGeneration { isRefreshingSummary = false }
            return "Refresh paused. Keep the app open and try again."
        }
        IdleTimerLock.acquire("models")
        dlog("models", "refresh start day=\(request.day) kind=\(request.kind.rawValue) run=\(run.id)")
        let result: (summary: Summary, error: String?) = await withCheckedContinuation { completion in
            DispatchQueue.global(qos: .userInitiated).async {
                completion.resume(returning: run.perform {
                    Core.refreshAnalysis(previous, request: request, progress: progress)
                })
            }
        }
        let canPublish = generation == loadGeneration && !run.isCancelled && WorkCoordinator.shared.available
        if canPublish && result.error == nil {
            s = result.summary
            SummaryCache.save(result.summary)
            HealthExport.shared.push(result.summary)
        }
        if generation == loadGeneration {
            isRefreshingSummary = false
            modelProgress.report(generation, nil)
        }
        IdleTimerLock.release("models")
        WorkCoordinator.shared.finishAnalysis(run)
        await WorkGate.shared.release()
        dlog("models", "refresh end day=\(request.day) kind=\(request.kind.rawValue) cancelled=\(run.isCancelled)")
        return canPublish ? result.error : "Refresh paused. Keep the app open and try again."
    }
    #endif

    private func load(force: Bool = false, clearCurrent: Bool = false) {
        guard force || s == nil else { return }
        // Lifecycle notifications and sync completion can request the same load.
        // Queue one refresh instead of repeatedly cancelling its predecessor.
        guard !isRefreshingSummary else { reloadPending = true; return }
        let run = WorkCoordinator.shared.newAnalysis()
        loadGeneration += 1
        let generation = loadGeneration
        let previous = clearCurrent ? nil : s
        if clearCurrent { s = nil }
        isRefreshingSummary = true
        modelProgress.begin(generation)
        let progress = modelProgress.sink(generation)
        Task {
            defer {
                if reloadPending {
                    reloadPending = false
                    load(force: true, clearCurrent: false)
                }
            }
            modelProgress.report(generation, "Waiting for ring data")
            dlog("models", "waiting for work gate run=\(run.id)")
            await WorkGate.shared.acquire()
            guard !run.isCancelled, WorkCoordinator.shared.available else {
                await WorkGate.shared.release()
                WorkCoordinator.shared.finishAnalysis(run)
                if generation == loadGeneration { isRefreshingSummary = false; modelProgress.report(generation, "Analysis paused") }
                return
            }
            modelProgress.report(generation, "Reading ring data")
            IdleTimerLock.acquire("models")
            dlog("models", "start run=\(run.id)")
            let started = ProcessInfo.processInfo.systemUptime
            #if TORCH
            let pending = Core.Pending()
            #endif
            let full: Summary = await withCheckedContinuation { completion in
                DispatchQueue.global(qos: .userInitiated).async {
                    let summary = run.perform {
                        let base = Core.base()
                        #if TORCH
                        return base.error == nil && !run.isCancelled
                            ? Core.withModels(base, previous: previous, pending: pending, progress: progress) : base
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
                        Task { await Vo2Walk.scan(full) }
                    } else if s == nil { s = full }
                    modelProgress.report(generation, full.error == nil ? nil : "Couldn’t refresh data.")
                } else { modelProgress.report(generation, "Analysis paused") }
            }
            #if TORCH
            // The symptom radar is the slowest model; the rest is already on screen.
            if pending.illness, generation == loadGeneration, !run.isCancelled, WorkCoordinator.shared.available, full.error == nil {
                modelProgress.report(generation, "Analyzing symptom radar")
                let withIllness: Summary = await withCheckedContinuation { completion in
                    DispatchQueue.global(qos: .userInitiated).async {
                        completion.resume(returning: run.perform { Core.withIllness(full, progress: progress) })
                    }
                }
                if generation == loadGeneration, !run.isCancelled, WorkCoordinator.shared.available {
                    s = withIllness
                    SummaryCache.save(withIllness)
                }
                if generation == loadGeneration { modelProgress.report(generation, nil) }
            }
            #endif
            if generation == loadGeneration { isRefreshingSummary = false }
            dlog("models", "end run=\(run.id) cancelled=\(run.isCancelled) duration=\(Int(ProcessInfo.processInfo.systemUptime - started))s")
            IdleTimerLock.release("models")
            WorkCoordinator.shared.finishAnalysis(run)
            await WorkGate.shared.release()
        }
    }

    private func shownDay(_ s: Summary) -> String {
        homeDay.flatMap { s.days.contains($0) ? $0 : nil }
            ?? s.days.first { s.scores[$0].map { $0.sleep != nil || $0.readiness != nil || $0.activity != nil } ?? false }
            ?? s.days.first ?? ""
    }

    private func open(_ route: Route) {
        switch route {
        case .score(let k): scoreSheet = k
        case .metric(let m): metricSheet = m
        case .vital(let v): vital = v
        case .debt: showSleepDebt = true
        case .vo2: showVo2 = true
        case .radar: showRadar = true
        case .allDays: showAllDays = true
        case .activities: showActivities = true
        case .day(let d, let sleep): report = ReportSel(day: d, sleep: sleep)
        }
    }

    /// Opens a day's report from inside a sheet: close the sheet first so the full-screen
    /// cover is not presented over a sheet that is still dismissing.
    private func openReport(_ day: String) {
        scoreSheet = nil; metricSheet = nil; showSleepDebt = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { report = ReportSel(day: day, sleep: true) }
    }

    /// Screen title with the ring, sync and profile controls; sync progress sits under it.
    private func topBar(_ title: String, _ s: Summary) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                Text(title).font(Obs.serif(28)).foregroundStyle(Obs.ink)
                Spacer()
                Button { showAllDays = true } label: {
                    Image(systemName: "calendar")
                        .font(.system(size: 16)).foregroundStyle(Obs.ink2)
                        .frame(width: 31, height: 31)
                }
                .accessibilityLabel("History")
                Button { showProfile = true } label: {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 17)).foregroundStyle(Obs.ink2)
                        .frame(width: 31, height: 31)
                }
                RingBatteryButton(pct: ring.info?.batteryPct ?? s.device?.battery_pct) { showSync = true }
            }
            SyncStatusLine(ring: ring, analyzing: isRefreshingSummary && !modelProgress.radarActive,
                           label: modelProgress.label)
        }
        .animation(.easeInOut(duration: 0.2), value: ring.busy || isRefreshingSummary))
    }

    /// Ring-clock warnings and model failures, the only prose left on Today.
    private func dataNotes(_ s: Summary) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 14) {
            if let warnings = s.clock?.warnings, !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(title: "Ring clock", icon: "clock.badge.exclamationmark")
                    ForEach(warnings, id: \.self) { w in
                        Text("• \(w)").font(Obs.sans(11)).foregroundStyle(Obs.bad)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !s.modelErrors.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(title: "On-device models", icon: "exclamationmark.triangle")
                    ForEach(s.modelErrors, id: \.self) { e in
                        Text("• \(e)").font(Obs.sans(11)).foregroundStyle(Obs.bad)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        })
    }

    @ViewBuilder private func content(_ s: Summary) -> some View {
        if let err = s.error {
            VStack(alignment: .leading, spacing: 12) {
                topBar("Open Oura", s)
                SectionLabel(title: "No data")
                Text(err).font(Obs.sans(13)).foregroundStyle(Obs.bad)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 12)
        } else {
            let day = shownDay(s)
            TabView(selection: $tab) {
                TodayTab(s: s, day: day, live: live, ring: ring, kind: $scoreKind, onSelectDay: { homeDay = $0 }, open: open,
                         header: topBar("Today", s), notes: dataNotes(s))
                    .tabItem { Label("Today", systemImage: "sun.max.fill") }.tag(AppTab.today)
                VitalsTab(s: s, day: day, kind: $scoreKind, onSelectDay: { homeDay = $0 }, open: open, header: topBar("Vitals", s))
                    .tabItem { Label("Vitals", systemImage: "waveform.path.ecg") }.tag(AppTab.vitals)
                TrendsTab(s: s, day: day, open: open, header: topBar("Trends", s))
                    .tabItem { Label("Trends", systemImage: "chart.line.uptrend.xyaxis") }.tag(AppTab.trends)
            }
            .tint(Obs.ink)
        }
    }
}

/// Battery level as the border of a ring: green from 30%, yellow below 30%, red below 15%.
struct RingBatteryButton: View {
    let pct: Int?
    let action: () -> Void

    private static func color(_ pct: Int?) -> Color {
        guard let pct else { return Obs.muted }
        if pct < 15 { return Obs.alert }
        if pct < 30 { return Obs.caution }
        return Obs.good
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(Obs.rule, lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(pct ?? 0, 0), 100)) / 100)
                    .stroke(Self.color(pct), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Circle().stroke(Obs.ink2, lineWidth: 1.4).frame(width: 11, height: 11)
            }
            .frame(width: 24, height: 24)
            .frame(width: 31, height: 31)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pct.map { "Ring battery \($0) percent" } ?? "Your ring")
        .accessibilityHint("Opens your ring: battery, sync and diagnostics")
    }
}

/// Which build is actually on this phone. A sideloaded app has no App Store version
/// to compare against, and a failed install looks exactly like a successful one — so
/// show the version, when this binary was signed, and when its free-account
/// certificate stops launching (7 days).
struct BuildStamp: View {
    var prefix: String? = nil
    private static let signedAt: Date? = {
        guard let path = Bundle.main.executableURL?.path,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return attrs[.modificationDate] as? Date
    }()

    private static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm"
        return f
    }()

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private var line: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var out = "Open Oura \(short) (\(build)) · \(coreVersion())"
        if let prefix { out = prefix + " · " + out }
        if let signed = Self.signedAt {
            out += " · built \(Self.stampFormat.string(from: signed))"
            if let expiry = Calendar.current.date(byAdding: .day, value: 7, to: signed) {
                let days = Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? 0
                out += days < 0
                    ? " · signing expired"
                    : " · signing good to \(Self.dayFormat.string(from: expiry))"
            }
        }
        return out
    }

    var body: some View {
        Text(line)
            .font(Obs.sans(11))
            .foregroundStyle(Obs.muted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 6)
            .textSelection(.enabled)
    }
}

@main
struct OuraApp: App {
    init() { DiagStore.shared.bootstrap() }
    var body: some Scene { WindowGroup { RootView() } }
}
