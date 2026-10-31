import SwiftUI

// Research export: the ring's raw streams (every beat, 30 s movement, SpO2 ratio, skin
// temperature) for a chosen window, as a ZIP of CSVs on the corrected clock. Built by the
// shared Rust `oura_summary::research_export`, so a window gives the same bytes as the web
// dashboard's "Research export" panel and `oura research-export`.
/// Saves a marker off the main thread: the write can wait seconds on a sync's SQLite lock.
/// The Rust side stamps the marker before it waits, so the time is still the tap's.
enum ResearchMarker {
    static func save(label: String, write: @escaping @Sendable (String) throws -> Double) async -> Result<Double, Error> {
        await Task.detached { Result { try write(label) } }.value
    }
}

struct ResearchExportView: View {
    struct Option: Identifiable {
        let id: String
        let title: String
        let detail: String
    }
    static let options: [Option] = [
        Option(id: "rr_intervals", title: "Every heart beat", detail: "RR interval, heart rate and signal amplitude per beat"),
        Option(id: "rr_quality", title: "Beats with quality flag", detail: "A second beat series, recorded intermittently"),
        Option(id: "sleep_movement_30s", title: "Movement during sleep", detail: "Accelerometer statistics per 30 s window"),
        Option(id: "motion_30s", title: "Movement and posture", detail: "Mean x/y/z and seconds moving per 30 s, day and night"),
        Option(id: "spo2_raw", title: "SpO2 raw ratio", detail: "Red/infrared ratio and perfusion index"),
        Option(id: "skin_temperature", title: "Skin temperature", detail: "Every reading, in °C"),
    ]

    @State private var start: Date = Self.defaultStart()
    @State private var end: Date = Self.defaultEnd()
    @State private var selected: Set<String> = ["rr_intervals", "sleep_movement_30s", "motion_30s"]
    @State private var working = false
    @State private var message: String?
    @State private var file: URL?
    @State private var markerLabel = ""
    @State private var lastMarker: Date?
    @State private var marking = false

    var body: some View {
        Form {
            Section {
                DatePicker("From", selection: $start)
                DatePicker("To", selection: $end, in: start...)
            } header: {
                Text("Window")
            } footer: {
                Text("Times are on this iPhone's clock. Every file also has a UTC column for aligning with other recordings.")
            }
            Section("Data") {
                ForEach(Self.options) { o in
                    Toggle(isOn: Binding(
                        get: { selected.contains(o.id) },
                        set: { on in if on { selected.insert(o.id) } else { selected.remove(o.id) } }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(o.title).foregroundStyle(Obs.ink)
                            Text(o.detail).font(.footnote).foregroundStyle(Obs.muted)
                        }
                    }
                }
            }
            Section {
                TextField("Label, e.g. audio recording started", text: $markerLabel)
                // Before the first sync there is no synced store to write to (creating one
                // would hide the bundled seed), so markers wait for a sync.
                Button("Mark now") { mark() }
                    .disabled(marking || !FileManager.default.fileExists(atPath: DB.url.path))
                if let lastMarker {
                    Text("Marked at \(lastMarker.formatted(date: .omitted, time: .standard))")
                        .font(.footnote).foregroundStyle(Obs.muted)
                }
            } header: {
                Text("Markers")
            } footer: {
                Text("Tap at the start of another recording to line it up with the ring data. Markers are exported in markers.csv.")
            }
            Section {
                Button(working ? "Preparing…" : "Export ZIP") { Task { await run() } }
                    .disabled(working || selected.isEmpty || end <= start)
                if let message { Text(message).font(.footnote).foregroundStyle(Obs.muted) }
            } footer: {
                Text("Each row is one value the ring recorded; nothing is averaged or scored. A README in the ZIP describes every column.")
            }
        }
        .navigationTitle("Research export")
        .sheet(isPresented: Binding(get: { file != nil }, set: { if !$0 { file = nil } })) {
            if let file { DiagnosticsShare(url: file) }
        }
    }

    private func run() async {
        working = true
        defer { working = false }
        let ids = Self.options.map(\.id).filter(selected.contains)
        let tz = Double(TimeZone.current.secondsFromGMT(for: start)) / 3600
        let (s, e) = (start.timeIntervalSince1970, end.timeIntervalSince1970)
        let db = DB.readPath()
        let dir = FileManager.default.temporaryDirectory.path
        let result: Result<String, Error> = await Task.detached {
            Result { try researchExport(dbPath: db, startUnix: s, endUnix: e, streams: ids,
                                        tzOffsetHours: tz, outDir: dir) }
        }.value
        switch result {
        case .success(let path):
            message = nil
            file = URL(fileURLWithPath: path)
        case .failure(let error):
            message = "Export failed: \(error.localizedDescription). Sync the ring and try again."
        }
    }

    private func mark() {
        let path = DB.url.path
        marking = true
        Task {
            let result = await ResearchMarker.save(label: markerLabel) { try addResearchMarker(dbPath: path, label: $0) }
            marking = false
            switch result {
            case .success(let unix):
                lastMarker = Date(timeIntervalSince1970: unix)
                markerLabel = ""
                message = nil
            case .failure(let error):
                message = "Could not save the marker: \(error.localizedDescription)"
            }
        }
    }

    /// Last night by default: 20:00 yesterday to 12:00 today.
    static func defaultStart() -> Date {
        let cal = Calendar.current
        let y = cal.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        return cal.date(bySettingHour: 20, minute: 0, second: 0, of: y) ?? y
    }
    static func defaultEnd() -> Date {
        Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
    }
}
