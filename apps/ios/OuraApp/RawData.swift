import Foundation
import SwiftUI

/// Everything the ring has actually sent, straight from the local database.
///
/// The dashboard shows interpreted results; this shows the inputs. It exists to answer
/// "is the ring emitting this at all?" — the question that decides whether a missing
/// panel is a decode gap, a feature that is switched off, or simply a night not yet
/// slept. Any numeric field a decoder produced can be plotted against real time.
enum RawData {
    struct Kind: Identifiable, Hashable {
        let name: String
        let total: Int
        let decoded: Int
        var id: String { name }
    }

    struct Event: Identifiable {
        let id = UUID()
        let name: String
        let tag: Int
        let ringTimestamp: Int
        let capturedUnix: Int
        let unix: Double
        let bodyLen: Int
        /// Numeric leaves of the decoded object, and the first level of any numeric
        /// array (`{"ibi_ms": [812, 806]}` → one point per sample) — decoders emit
        /// both shapes and either is worth charting. Built once at load, off the main
        /// thread, instead of on every redraw.
        let numbers: [String: [Double]]
        let prettyJSON: String

        var date: Date? { unix > 0 ? Date(timeIntervalSince1970: unix) : nil }

        init(name: String, tag: Int, ringTimestamp: Int, capturedUnix: Int, unix: Double,
             bodyLen: Int, decoded: [String: Any]?) {
            self.name = name; self.tag = tag; self.ringTimestamp = ringTimestamp
            self.capturedUnix = capturedUnix; self.unix = unix; self.bodyLen = bodyLen
            var numbers: [String: [Double]] = [:]
            for (key, value) in decoded ?? [:] {
                if let d = value as? Double { numbers[key] = [d] }
                else if let i = value as? Int { numbers[key] = [Double(i)] }
                else if let arr = value as? [Any] {
                    let nums = arr.compactMap { $0 as? Double ?? ($0 as? Int).map(Double.init) }
                    if !nums.isEmpty { numbers[key] = nums }
                }
            }
            self.numbers = numbers
            if let decoded,
               let data = try? JSONSerialization.data(withJSONObject: decoded,
                                                      options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                prettyJSON = text
            } else {
                prettyJSON = "not decoded — \(bodyLen) raw bytes stored"
            }
        }
    }

    /// One chart point. Events that carry N samples are spread backwards over their
    /// own interval only when we know it; otherwise they share the event's time, which
    /// is honest — the decoders do not yet emit per-sample timestamps.
    struct Point: Identifiable {
        let id = UUID()
        let t: Double
        let v: Double
    }

    struct Page {
        var kinds: [Kind]
        var events: [Event]
        var fields: [String]
        var error: String?
    }

    /// The type list alone (no filter) asks for no rows, so the core skips the
    /// history-wide clock scan that only the event list needs.
    static func load(filter: String, limit: UInt32 = 400) -> Page {
        let raw = eventsJson(dbPath: DB.url.path, nameFilter: filter, limit: filter.isEmpty ? 0 : limit)
        guard let data = raw.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return Page(kinds: [], events: [], fields: [], error: "unreadable response") }
        if let err = root["error"] as? String { return Page(kinds: [], events: [], fields: [], error: err) }

        let kinds = (root["counts"] as? [[String: Any]] ?? []).map {
            Kind(name: $0["name"] as? String ?? "?",
                 total: $0["total"] as? Int ?? 0,
                 decoded: $0["decoded"] as? Int ?? 0)
        }
        let events = (root["events"] as? [[String: Any]] ?? []).map {
            Event(name: $0["name"] as? String ?? "?",
                  tag: $0["tag"] as? Int ?? 0,
                  ringTimestamp: $0["ring_timestamp"] as? Int ?? 0,
                  capturedUnix: $0["captured_unix"] as? Int ?? 0,
                  unix: ($0["unix_s"] as? Double) ?? Double($0["captured_unix"] as? Int ?? 0),
                  bodyLen: $0["body_len"] as? Int ?? 0,
                  decoded: $0["decoded"] as? [String: Any])
        }
        let fields = Set(events.flatMap { $0.numbers.keys }).sorted()
        return Page(kinds: kinds, events: events, fields: fields, error: nil)
    }

    /// Chart series for one field, oldest → newest so the line reads left to right.
    /// Long series are thinned to each bucket's min and max, which keeps spikes and
    /// the envelope while drawing a few thousand segments instead of every sample.
    static func points(_ events: [Event], field: String, maxPoints: Int = 2000) -> [Point] {
        let all = events.reversed().flatMap { e -> [Point] in
            guard let values = e.numbers[field], e.unix > 0 else { return [] }
            return values.enumerated().map { i, v in Point(t: e.unix + Double(i) * 0.001, v: v) }
        }
        guard all.count > maxPoints else { return all }
        let bucket = Int((Double(all.count) / Double(max(1, maxPoints / 2))).rounded(.up))
        var out: [Point] = []
        out.reserveCapacity(maxPoints + 2)
        var start = 0
        while start < all.count {
            let slice = all[start..<min(start + bucket, all.count)]
            let lo = slice.min { $0.v < $1.v }!, hi = slice.max { $0.v < $1.v }!
            if lo.t <= hi.t { out.append(lo); if hi.t != lo.t || hi.v != lo.v { out.append(hi) } }
            else { out.append(hi); out.append(lo) }
            start += bucket
        }
        return out
    }

    /// Pages already loaded this session, so reopening the screen or switching back
    /// to a type is instant. Each is stamped with the store's file identity; a sync
    /// changes it and the page is refreshed in the background while still shown.
    enum Cache {
        private static let lock = NSLock()
        private static var pages: [String: (stamp: String, page: Page)] = [:]
        static func page(_ filter: String) -> (stamp: String, page: Page)? {
            lock.lock(); defer { lock.unlock() }
            return pages[filter]
        }
        static func store(_ filter: String, stamp: String, page: Page) {
            guard page.error == nil else { return }
            lock.lock(); defer { lock.unlock() }
            pages[filter] = (stamp, page)
        }
    }

    /// Cheap identity of the synced store: size and modification time of the DB and
    /// its WAL, which every committed sync touches.
    static func storeStamp() -> String {
        [DB.url.path, DB.url.path + "-wal"].map { path in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(size)@\(modified)"
        }.joined(separator: "|")
    }
}

struct RawDataView: View {
    @State private var kinds: [RawData.Kind] = []
    @State private var events: [RawData.Event] = []
    @State private var fields: [String] = []
    @State private var points: [RawData.Point] = []
    @State private var error: String?
    @State private var filter = ""
    @State private var field: String?
    /// Nothing to show yet (first open of the screen).
    @State private var loading = true
    /// The selected type's rows are being fetched; the type list stays usable.
    @State private var loadingEvents = false
    @State private var request = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let error {
                    Text(error).font(.subheadline).foregroundStyle(Obs.alert)
                } else if loading {
                    ProgressView().tint(Obs.ink).frame(maxWidth: .infinity)
                } else if kinds.isEmpty {
                    Text("Nothing stored yet. Sync the ring and come back.")
                        .font(.subheadline).foregroundStyle(Obs.ink2)
                } else {
                    kindList
                    if !filter.isEmpty {
                        if loadingEvents && events.isEmpty {
                            ProgressView().tint(Obs.ink).frame(maxWidth: .infinity).obsCard()
                        } else { chart; eventList }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(Obs.paper)
        .navigationTitle(filter.isEmpty ? "Raw data" : filter)
        .navigationBarTitleDisplayMode(.inline)
        .task { reload() }
        .onChange(of: field) { _, _ in updatePoints() }
    }

    private var kindList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("event types").font(Obs.mono(11)).foregroundStyle(Obs.ink2)
            ForEach(kinds) { k in
                Button {
                    filter = (filter == k.name) ? "" : k.name
                    reload()
                } label: {
                    HStack {
                        Text(k.name)
                            .font(Obs.mono(12))
                            .foregroundStyle(filter == k.name ? Obs.ink : Obs.ink2)
                        Spacer()
                        Text(k.decoded == k.total ? "\(k.total)" : "\(k.decoded)/\(k.total)")
                            .font(Obs.mono(12)).foregroundStyle(Obs.muted)
                    }
                    .frame(minHeight: 36)
                }
                .buttonStyle(.plain)
            }
            Text("count shown as decoded/total when some bodies have no decoder yet.")
                .font(.footnote).foregroundStyle(Obs.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .obsCard()
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("chart").font(Obs.mono(11)).foregroundStyle(Obs.ink2)
                if loadingEvents { ProgressView().controlSize(.mini).tint(Obs.muted) }
                Spacer()
                if !fields.isEmpty {
                    Menu {
                        ForEach(fields, id: \.self) { f in
                            Button(f) { field = f }
                        }
                    } label: {
                        Text(field ?? "pick a field")
                            .font(Obs.mono(11)).foregroundStyle(Obs.ink)
                    }
                }
            }
            if fields.isEmpty {
                Text("No numeric fields in these events.")
                    .font(.footnote).foregroundStyle(Obs.ink2)
            } else if field == nil {
                Text("Pick a field to plot it over time.")
                    .font(.footnote).foregroundStyle(Obs.ink2)
            } else {
                TimeSeriesChart(points: points)
                    .frame(height: 180)
                if let first = points.first, let last = points.last {
                    HStack {
                        Text(Self.stamp(first.t)).font(Obs.mono(9)).foregroundStyle(Obs.muted)
                        Spacer()
                        Text("\(points.count) pts").font(Obs.mono(9)).foregroundStyle(Obs.muted)
                        Spacer()
                        Text(Self.stamp(last.t)).font(Obs.mono(9)).foregroundStyle(Obs.muted)
                    }
                }
            }
        }
        .obsCard()
    }

    private var eventList: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("newest first · \(events.count) shown")
                .font(Obs.mono(11)).foregroundStyle(Obs.ink2)
            ForEach(events.prefix(60)) { e in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(e.date.map(Self.full) ?? "no time")
                            .font(Obs.mono(10)).foregroundStyle(Obs.ink2)
                        Spacer()
                        Text("tag 0x\(String(e.tag, radix: 16)) · ds \(e.ringTimestamp)")
                            .font(Obs.mono(9)).foregroundStyle(Obs.muted)
                    }
                    Text(e.prettyJSON)
                        .font(Obs.mono(10)).foregroundStyle(Obs.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 2)
                Rectangle().fill(Obs.rule).frame(height: 1)
            }
        }
        .obsCard()
    }

    /// Shows this session's cached page at once, then refreshes it off the main
    /// thread only when the store changed since (or it was never loaded).
    private func reload() {
        request += 1
        let current = request, f = filter
        let cached = RawData.Cache.page(f)
        if let cached { apply(cached.page, filter: f) } else if !f.isEmpty { events = []; fields = []; points = [] }
        loadingEvents = !f.isEmpty
        Task.detached(priority: .userInitiated) {
            let stamp = RawData.storeStamp()
            if cached?.stamp == stamp {
                await MainActor.run { if current == request { loadingEvents = false } }
                return
            }
            let page = RawData.load(filter: f)
            await MainActor.run {
                RawData.Cache.store(f, stamp: stamp, page: page)
                guard current == request else { return }
                // A failed refresh (e.g. the store is busy mid-sync) keeps the page
                // already on screen instead of replacing it with only an error.
                if page.error == nil || cached == nil { apply(page, filter: f) }
                loadingEvents = false
            }
        }
    }

    private func apply(_ page: RawData.Page, filter f: String) {
        error = page.error
        kinds = page.kinds; events = page.events; fields = page.fields
        loading = false
        let before = field
        if f.isEmpty { field = nil }
        else if field == nil || !fields.contains(field!) { field = fields.first }
        if field == before { updatePoints() }   // otherwise .onChange(of: field) does it
    }

    private func updatePoints() {
        points = field.map { RawData.points(events, field: $0) } ?? []
    }

    private static let stampFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d HH:mm"; return f
    }()
    private static func stamp(_ t: Double) -> String {
        stampFmt.string(from: Date(timeIntervalSince1970: t))
    }
    private static func full(_ d: Date) -> String { stampFmt.string(from: d) }
}

/// A plain time-series line: x is real time, so gaps in the data look like gaps.
struct TimeSeriesChart: View {
    let points: [RawData.Point]
    var accent: Color = Obs.chart

    var body: some View {
        Canvas { ctx, size in
            guard points.count > 1 else { return }
            let xs = points.map(\.t), ys = points.map(\.v)
            let x0 = xs.min()!, x1 = xs.max()!
            let y0 = ys.min()!, y1 = ys.max()!
            let xSpan = max(x1 - x0, 1e-6)
            let ySpan = max(y1 - y0, 1e-6)
            let inset: CGFloat = 6
            let w = max(1, size.width - inset * 2)
            let h = max(1, size.height - inset * 2)

            func place(_ p: RawData.Point) -> CGPoint {
                CGPoint(x: inset + w * CGFloat((p.t - x0) / xSpan),
                        y: inset + h * (1 - CGFloat((p.v - y0) / ySpan)))
            }

            var line = Path()
            line.move(to: place(points[0]))
            for p in points.dropFirst() { line.addLine(to: place(p)) }
            ctx.stroke(line, with: .color(accent), style: StrokeStyle(lineWidth: 1.1,
                                                                      lineJoin: .round))

            for (label, value) in [("\(fmt(y1))", y1), ("\(fmt(y0))", y0)] {
                let y = inset + h * (1 - CGFloat((value - y0) / ySpan))
                ctx.draw(Text(label).font(Obs.mono(9)).foregroundColor(Obs.muted),
                         at: CGPoint(x: inset + 2, y: max(8, min(size.height - 8, y))),
                         anchor: .leading)
            }
        }
    }

    private func fmt(_ v: Double) -> String {
        abs(v) >= 100 || v == v.rounded() ? String(Int(v.rounded())) : String(format: "%.1f", v)
    }
}
