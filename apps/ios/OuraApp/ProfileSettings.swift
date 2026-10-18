import SwiftUI
import HealthKit

private struct EditableProfile {
    var sex: String
    var age: Double
    var heightCm: Double
    var weightKg: Double
    var ringSize: Double
    /// Body Clock ideal sleep midpoint, `HH:MM` (`-HH:MM` before midnight); empty when unset.
    var idealMidpoint: String
    /// Where the daily step count comes from: "ring" (the ring's own counter) or "model" (the
    /// step counter model on the real-step records; needs its weights in the build).
    var stepsSource: String
    /// Sleep stager: "auto", "official" or "xgb" (oura-summary `sleep_stager`).
    var sleepStager: String
    /// The sleep need in hours when the user sets it; nil lets the app estimate it.
    var sleepNeedH: Double?

    init(_ profile: Profile?) {
        sleepNeedH = profile?.sleep_need_h
        let stored = (try? JSONSerialization.jsonObject(with: Data(contentsOf: DB.url.deletingLastPathComponent()
            .appendingPathComponent("profile.json"))) as? [String: Any])?["steps_source"] as? String
        stepsSource = stored == "model" && ModelFiles.stepCounter ? "model" : "ring"
        let stager = (try? JSONSerialization.jsonObject(with: Data(contentsOf: DB.url.deletingLastPathComponent()
            .appendingPathComponent("profile.json"))) as? [String: Any])?["sleep_stager"] as? String
        sleepStager = stager == "official" || stager == "xgb" ? stager! : "auto"
        sex = profile?.sex ?? "M"
        age = profile?.age ?? 30
        heightCm = (profile?.height_m ?? 1.78) * 100
        weightKg = profile?.weight_kg ?? 75
        ringSize = profile?.ring_size ?? 10
        idealMidpoint = profile?.ideal_midpoint ?? ""
    }
}

private enum ProfileStore {
    static var url: URL { DB.url.deletingLastPathComponent().appendingPathComponent("profile.json") }

    static func save(_ p: EditableProfile) throws {
        // keep keys this screen does not edit, such as the chronotype type
        var object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
        object["sex"] = p.sex; object["age"] = p.age; object["height_m"] = p.heightCm / 100
        object["weight_kg"] = p.weightKg; object["ring_size"] = p.ringSize
        object["steps_source"] = p.stepsSource
        if p.sleepStager == "auto" { object.removeValue(forKey: "sleep_stager") } else { object["sleep_stager"] = p.sleepStager }
        if let need = p.sleepNeedH { object["sleep_need_h"] = need } else { object.removeValue(forKey: "sleep_need_h") }
        let midpoint = p.idealMidpoint.trimmingCharacters(in: .whitespaces)
        if midpoint.isEmpty {
            object.removeValue(forKey: "chronotype")
        } else {
            let type = (object["chronotype"] as? [String: Any])?["type"] ?? 3
            object["chronotype"] = ["type": type, "ideal_midpoint": midpoint]
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    /// `HH:MM` or `-HH:MM`, or empty.
    static func validMidpoint(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return true }
        return t.range(of: #"^-?([01]?[0-9]|2[0-3]):[0-5][0-9]$"#, options: .regularExpression) != nil
    }
}

private struct HealthProfile {
    var sex: String?
    var age: Double?
    var heightCm: Double?
    var weightKg: Double?
}

private enum HealthProfileImporter {
    static func load(completion: @escaping (Result<HealthProfile, Error>) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(.failure(NSError(domain: "open_oura", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "Apple Health is unavailable on this device."])))
            return
        }
        let store = HKHealthStore()
        let dob = HKObjectType.characteristicType(forIdentifier: .dateOfBirth)!
        let biologicalSex = HKObjectType.characteristicType(forIdentifier: .biologicalSex)!
        let height = HKObjectType.quantityType(forIdentifier: .height)!
        let mass = HKObjectType.quantityType(forIdentifier: .bodyMass)!
        let read: Set<HKObjectType> = [dob, biologicalSex, height, mass]
        store.requestAuthorization(toShare: [], read: read) { granted, error in
            if let error { DispatchQueue.main.async { completion(.failure(error)) }; return }
            guard granted else {
                let e = NSError(domain: "open_oura", code: 2,
                                userInfo: [NSLocalizedDescriptionKey: "Apple Health access was not granted."])
                DispatchQueue.main.async { completion(.failure(e)) }
                return
            }

            var result = HealthProfile()
            if let birth = try? store.dateOfBirthComponents().date {
                result.age = Double(Calendar.current.dateComponents([.year], from: birth, to: Date()).year ?? 0)
            }
            if let value = try? store.biologicalSex().biologicalSex {
                switch value {
                case .female: result.sex = "F"
                case .male: result.sex = "M"
                case .other: result.sex = "O"
                default: break
                }
            }

            let group = DispatchGroup()
            func latest(_ type: HKQuantityType, unit: HKUnit, assign: @escaping (Double) -> Void) {
                group.enter()
                let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
                let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1,
                                          sortDescriptors: [sort]) { _, samples, _ in
                    if let sample = samples?.first as? HKQuantitySample {
                        assign(sample.quantity.doubleValue(for: unit))
                    }
                    group.leave()
                }
                store.execute(query)
            }
            latest(height, unit: .meterUnit(with: .centi)) { result.heightCm = $0 }
            latest(mass, unit: .gramUnit(with: .kilo)) { result.weightKg = $0 }
            group.notify(queue: .main) { completion(.success(result)) }
        }
    }
}

/// What the profile screen needs to launch and follow a full model recompute. Nil in
/// builds without the on-device models.
struct RecomputeHook {
    var run: () -> Void
    /// The model runners' current step ("detecting activity · day 3/33"), when busy.
    var label: String?
    var busy: Bool
}

// ── midpoint <-> time of day ─────────────────────────────────────────────────

/// The Body Clock's ideal sleep midpoint is stored as `HH:MM`, or `-HH:MM` for the
/// evening before midnight (`-01:00` is 23:00). The screen edits it as a time of day.
private enum Midpoint {
    static func date(from text: String) -> Date? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, ProfileStore.validMidpoint(t) else { return nil }
        let negative = t.hasPrefix("-")
        let parts = t.replacingOccurrences(of: "-", with: "").split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        let minutes = parts[0] * 60 + parts[1]
        let total = negative ? (1440 - minutes) % 1440 : minutes
        return Calendar.current.date(bySettingHour: total / 60, minute: total % 60, second: 0, of: Date())
    }
    static func text(from date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let total = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let (sign, minutes) = total >= 12 * 60 ? ("-", (1440 - total) % 1440) : ("", total)
        return String(format: "%@%02d:%02d", sign, minutes / 60, minutes % 60)
    }
}

// ── building blocks ──────────────────────────────────────────────────────────

/// One labeled value: the name on the left, the editable value and its unit on the right.
/// Tapping anywhere on the row edits the value.
private struct FieldRow: View {
    let label: String
    let unit: String
    @Binding var value: Double
    var decimals: Int = 0
    var focus: FocusState<Bool>.Binding
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(Obs.sans(13)).foregroundStyle(Obs.ink2)
            Spacer(minLength: 12)
            TextField("", value: $value, format: .number.precision(.fractionLength(0...decimals)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(Obs.sans(17, .medium)).foregroundStyle(Obs.ink).monospacedDigit()
                .focused(focus)
                .frame(maxWidth: 90)
            Text(unit).font(Obs.sans(11)).foregroundStyle(Obs.muted).frame(width: 34, alignment: .leading)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .onTapGesture { focus.wrappedValue = true }
    }
}

private struct FieldRule: View {
    var body: some View { Rectangle().fill(Obs.rule).frame(height: 0.6) }
}

struct Card<Content: View>: View {
    let title: String
    var icon: String? = nil
    var note: String? = nil
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: title, icon: icon)
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 16).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Obs.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if let note {
                Text(note).font(Obs.sans(11)).foregroundStyle(Obs.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
        }
    }
}

struct ProfileSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profile: EditableProfile
    @State private var midpointOn: Bool
    @State private var midpointTime: Date
    @State private var importing = false
    @State private var message: String?
    @State private var recomputeStarted = false
    @ObservedObject private var health = HealthExport.shared
    @FocusState private var ageFocus: Bool
    @FocusState private var heightFocus: Bool
    @FocusState private var weightFocus: Bool
    @FocusState private var ringFocus: Bool
    let onSaved: () -> Void
    let recompute: RecomputeHook?
    var ring: RingSync?

    init(profile: Profile?, recompute: RecomputeHook? = nil, ring: RingSync? = nil, onSaved: @escaping () -> Void) {
        self.ring = ring
        let editable = EditableProfile(profile)
        _profile = State(initialValue: editable)
        let existing = Midpoint.date(from: editable.idealMidpoint)
        _midpointOn = State(initialValue: existing != nil)
        _midpointTime = State(initialValue: existing
            ?? Calendar.current.date(bySettingHour: 3, minute: 0, second: 0, of: Date()) ?? Date())
        self.recompute = recompute
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Obs.canvas
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        bodyCard
                        sleepCard
                        sleepStagingCard
                        stepsCard
                        healthCard
                        if let ring { CaptureSettingsCard(ring: ring) }
                        if let recompute { modelsCard(recompute) }
                        Text("Everything here stays on this iPhone.")
                            .font(Obs.sans(11)).foregroundStyle(Obs.muted).padding(.horizontal, 4)
                    }
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { ageFocus = false; heightFocus = false; weightFocus = false; ringFocus = false }
                }
            }
        }
    }

    // sex, age, height, weight, ring size
    private var bodyCard: some View {
        Card(title: "Body", icon: "figure.stand",
             note: "Sex is biological sex. Used by cardiovascular age, activity targets, calories and the sleep score.") {
            HStack {
                Text("Sex").font(Obs.sans(13)).foregroundStyle(Obs.ink2)
                Spacer(minLength: 12)
                HStack(spacing: 4) {
                    ForEach([("F", "Female"), ("M", "Male"), ("O", "Other")], id: \.0) { code, name in
                        Button { profile.sex = code } label: {
                            Text(name).font(Obs.sans(12, profile.sex == code ? .medium : .regular))
                                .lineLimit(1).fixedSize()
                                .foregroundStyle(profile.sex == code ? Obs.paper : Obs.ink2)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(profile.sex == code ? Obs.ink : Color.clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3).background(Obs.paper.opacity(0.7), in: Capsule())
            }
            .padding(.vertical, 8)
            FieldRule()
            FieldRow(label: "Age", unit: "years", value: $profile.age, decimals: 1, focus: $ageFocus)
            FieldRule()
            FieldRow(label: "Height", unit: "cm", value: $profile.heightCm, decimals: 1, focus: $heightFocus)
            FieldRule()
            FieldRow(label: "Weight", unit: "kg", value: $profile.weightKg, decimals: 1, focus: $weightFocus)
            FieldRule()
            FieldRow(label: "Ring size", unit: "size", value: $profile.ringSize, decimals: 1, focus: $ringFocus)
        }
    }

    // the timing part of the sleep score
    private var stepsCard: some View {
        Card(title: "Steps", icon: "figure.walk",
             note: ModelFiles.stepCounter
                ? "Ring counter uses the step count the ring reports. Step model counts steps from the ring's real-step records with the step counter; days without real-step records count 0. Real steps must be switched on under Ring capture."
                : "Ring counter uses the step count the ring reports. The step model is not included in this build.") {
            // A segment cannot be disabled in a segmented picker, so an option whose model is not in
            // this build is not offered; the note above says why.
            if ModelFiles.stepCounter {
                Picker("Step count", selection: $profile.stepsSource) {
                    Text("Ring counter").tag("ring")
                    Text("Step model").tag("model")
                }
                .pickerStyle(.segmented)
                .padding(.vertical, 12)
            } else {
                Text("Ring counter").font(Obs.sans(13)).foregroundStyle(Obs.ink2).padding(.vertical, 12)
            }
        }
    }

    /// Which stager produces the hypnogram. An option whose classifier file is not in this build is
    /// not offered and is explained in the same muted style as the capture hints.
    private var sleepStagingCard: some View {
        let status = SleepStagerStatus.load()
        let current = status?.options.first { $0.id == profile.sleepStager && $0.available }
        return Card(title: "Sleep staging", icon: "waveform.path.ecg",
             note: "Automatic uses the Oura model staging when its classifier file is in the build, otherwise the built-in staging. Saving re-stages your nights.") {
            // A segment cannot be disabled in a segmented picker, so only options whose classifier
            // file is in this build are offered. A stored choice that is not offered shows as Automatic.
            let offered = (status?.options ?? []).filter { $0.available }
            Picker("Sleep staging", selection: Binding(
                get: { profile.sleepStager == "auto" || offered.contains { $0.id == profile.sleepStager } ? profile.sleepStager : "auto" },
                set: { profile.sleepStager = $0 })) {
                Text("Automatic").tag("auto")
                ForEach(offered) { option in
                    Text(option.label).tag(option.id)
                }
            }
            .pickerStyle(.segmented)
            .padding(.vertical, 12)
            if profile.sleepStager == "auto" {
                Text("Using \(status?.effective == "official" ? "Oura model" : "built-in") staging.")
                    .font(Obs.sans(11)).foregroundStyle(Obs.ink2).padding(.bottom, 8)
            } else if let current {
                Text(current.detail).font(Obs.sans(11)).foregroundStyle(Obs.ink2).padding(.bottom, 8)
            }
            ForEach(status?.options ?? []) { option in
                if let notice = option.notice {
                    Text("\(option.label): \(notice)").font(Obs.sans(11)).foregroundStyle(Obs.muted)
                        .fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
                }
            }
            if let notice = status?.notice {
                Text(notice).font(Obs.sans(11)).foregroundStyle(Obs.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
            }
        }
    }

    private var sleepCard: some View {
        Card(title: "Sleep", icon: "moon.fill",
             note: "The midpoint is on the Oura app's Body Clock screen. It sets the timing part of the sleep score. Sleep need is estimated from your nights unless you set it; Sleep debt shows why the estimate changes.") {
            Toggle(isOn: Binding(get: { profile.sleepNeedH != nil },
                                 set: { profile.sleepNeedH = $0 ? (profile.sleepNeedH ?? 7.5) : nil })) {
                Text("Set sleep need").font(Obs.sans(13)).foregroundStyle(Obs.ink2)
            }
            .tint(Obs.sleepTint)
            .padding(.vertical, 8)
            if let need = profile.sleepNeedH {
                FieldRule()
                Stepper(value: Binding(get: { need }, set: { profile.sleepNeedH = $0 }), in: 5...11, step: 0.25) {
                    HStack {
                        Text("Sleep need").font(Obs.sans(13)).foregroundStyle(Obs.ink2)
                        Spacer(minLength: 12)
                        Text(fmtMinutes(need * 60)).font(Obs.sans(13)).foregroundStyle(Obs.ink).monospacedDigit()
                    }
                }
                .padding(.vertical, 6)
            }
            FieldRule()
            Toggle(isOn: $midpointOn.animation(.easeOut(duration: 0.2))) {
                Text("Ideal sleep midpoint").font(Obs.sans(13)).foregroundStyle(Obs.ink2)
            }
            .tint(Obs.sleepTint)
            .padding(.vertical, 8)
            if midpointOn {
                FieldRule()
                DatePicker(selection: $midpointTime, displayedComponents: .hourAndMinute) {
                    Text("Midpoint time").font(Obs.sans(13)).foregroundStyle(Obs.ink2)
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var healthCard: some View {
        Card(title: "Apple Health", icon: "heart.text.square.fill",
             note: "Writing exports workouts (and removes ones the ring no longer detects), sleep stages, heart rate, HRV, resting HR, steps, active calories and distance.") {
            Button {
                importing = true; message = nil
                HealthProfileImporter.load { result in
                    importing = false
                    switch result {
                    case .success(let imported):
                        if let v = imported.sex { profile.sex = v }
                        if let v = imported.age, v > 0 { profile.age = v }
                        if let v = imported.heightCm { profile.heightCm = v }
                        if let v = imported.weightKg { profile.weightKg = v }
                        message = "Imported sex, age, height and weight from Apple Health."
                    case .failure(let error): message = error.localizedDescription
                    }
                }
            } label: {
                HStack {
                    Text("Import sex, age, height, weight").font(Obs.sans(13)).foregroundStyle(Obs.ink)
                    Spacer()
                    if importing { ProgressView() } else {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 13)).foregroundStyle(Obs.ink2)
                    }
                }
                .padding(.vertical, 12).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(importing)
            if let message {
                Text(message).font(Obs.sans(11)).foregroundStyle(Obs.ink2).padding(.bottom, 10)
            }
            FieldRule()
            Toggle(isOn: Binding(get: { health.enabled },
                                 set: { health.setEnabled($0, summary: SummaryCache.load()) })) {
                Text("Write ring data to Health").font(Obs.sans(13)).foregroundStyle(Obs.ink2)
            }
            .tint(Obs.good)
            .padding(.vertical, 8)
            if !health.status.isEmpty {
                Text(health.status).font(Obs.sans(11)).foregroundStyle(Obs.ink2).padding(.bottom, 8)
            }
            if health.enabled {
                FieldRule()
                Button { health.removeExportedSamples() } label: {
                    Text("Remove Open Oura samples from Health").font(Obs.sans(13)).foregroundStyle(Obs.bad)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func modelsCard(_ recompute: RecomputeHook) -> some View {
        Card(title: "Models", icon: "cpu",
             note: "Clears saved sleep, activity, cardiovascular and illness results and runs the on-device models again over all saved ring data. Ring data is not changed. This can take a few minutes.") {
            Button { recomputeStarted = true; recompute.run() } label: {
                HStack {
                    Text("Recompute everything").font(Obs.sans(13)).foregroundStyle(Obs.ink)
                    Spacer()
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 13)).foregroundStyle(Obs.ink2)
                }
                .padding(.vertical, 12).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(recompute.busy).opacity(recompute.busy ? 0.4 : 1)
            if recompute.busy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text((recompute.label ?? "Analyzing saved data"))
                        .font(Obs.sans(11)).foregroundStyle(Obs.ink2)
                }
                .padding(.bottom, 10)
            } else if recomputeStarted {
                Text("Recomputed with the current models.").font(Obs.sans(11)).foregroundStyle(Obs.ink2).padding(.bottom, 10)
            }
        }
    }

    private func save() {
        profile.idealMidpoint = midpointOn ? Midpoint.text(from: midpointTime) : ""
        do {
            try ProfileStore.save(profile)
            onSaved()
            dismiss()
        } catch { message = "Could not save: \(error.localizedDescription)" }
    }
}
