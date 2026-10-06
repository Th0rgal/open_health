#if TORCH
import Foundation
// sqlite3 comes from the bridging header (TorchBridge.h includes <sqlite3.h>)

// Shared DB reader for the on-device models. SleepStaging and ActivityModel both need
// the same decoded-JSON event stream and time anchor; this is that read in one place
// (CvaModel reads raw PPG blobs instead, so it opens the DB itself).
enum EventStore {
    /// A failed read must never masquerade as "no data": a truncated event list
    /// would wipe every model-derived panel and get persisted by SummaryCache.
    enum ReadError: Error, CustomStringConvertible {
        case open(String), prepare(String), step(String)
        var description: String {
            switch self {
            case .open(let m): return "couldn't open the ring database: \(m)"
            case .prepare(let m): return "couldn't query the ring database: \(m)"
            case .step(let m): return "ring database read was interrupted: \(m)"
            }
        }
    }

    // A decoded event row: ring timestamp (ds), tag, decoded JSON, capture unix time.
    struct Ev {
        let ds: Int64
        let tag: Int
        let json: [String: Any]
        let cu: Int64
        let body: Data?
    }

    /// Re-iterable SQLite stream: only the current row is decoded, never the archive.
    /// A shared error latch makes a truncated iteration fail the entire model pass.
    final class Events: Sequence {
        let path: String
        var error: Error?
        let predicate: String
        let metadata: Bool
        private let parent: Events?
        init(path: String, predicate: String = "1", metadata: Bool = false, parent: Events? = nil) {
            self.path = path; self.predicate = predicate; self.metadata = metadata; self.parent = parent
        }
        func fail(_ error: Error) { self.error = error; parent?.fail(error) }
        func validate() throws { try AnalysisRun.check(); if let error { throw error } }
        func restricted(_ predicate: String, metadata: Bool = false) -> Events {
            Events(path: path, predicate: "(\(self.predicate)) AND (\(predicate))", metadata: metadata, parent: self)
        }
        var isEmpty: Bool { makeIterator().next() == nil }

        /// Cheap identity of the store's contents for cache early-exits: row count and
        /// last id of decoded events, plus the same for clock anchors and `ring_start`
        /// reboots (a new anchor or newly decoded reboot can re-date old rows, so it
        /// must invalidate day-bucketed caches too).
        func digest() -> String? {
            var db: OpaquePointer?
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 5000)
            var statement: OpaquePointer?
            let sql = "SELECT COUNT(*), IFNULL(MAX(id),0), SUM(tag IN (66,133)), IFNULL(MAX(CASE WHEN tag IN (66,133) THEN id END),0), SUM(tag = 65), IFNULL(MAX(CASE WHEN tag = 65 THEN id END),0) FROM events WHERE decoded_json IS NOT NULL OR (tag = 65 AND LENGTH(body) >= 14)"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return (0..<6).map { String(sqlite3_column_int64(statement, Int32($0))) }.joined(separator: ":")
        }
        var last: Ev? {
            restricted("id=(SELECT id FROM events WHERE decoded_json IS NOT NULL OR (tag = 65 AND LENGTH(body) >= 14) ORDER BY captured_unix DESC,id DESC LIMIT 1)").makeIterator().next()
        }
        func makeIterator() -> Iterator { Iterator(self) }
        final class Iterator: IteratorProtocol {
            private let source: Events
            private var db: OpaquePointer?
            private var statement: OpaquePointer?
            private var finished = false
            init(_ source: Events) {
                self.source = source
                guard sqlite3_open_v2(source.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                    source.fail(ReadError.open(message())); finished = true; return
                }
                sqlite3_busy_timeout(db, 5000)
                let json = source.metadata ? "CASE WHEN tag IN (66,133) THEN COALESCE(decoded_json, '{}') ELSE '{}' END" : "COALESCE(decoded_json, '{}')"
                let body = source.metadata ? "NULL" : "CASE WHEN tag IN (126,127) THEN body ELSE NULL END"
                let sql = "SELECT ring_timestamp,tag,\(json),captured_unix,\(body) FROM events WHERE (decoded_json IS NOT NULL OR (tag = 65 AND LENGTH(body) >= 14)) AND (\(source.predicate)) ORDER BY captured_unix,id"
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                    source.fail(ReadError.prepare(message())); finished = true; return
                }
            }
            deinit { sqlite3_finalize(statement); sqlite3_close(db) }
            private func message() -> String {
                guard let db else { return "open failed" }
                return "sqlite=\(sqlite3_errcode(db)) extended=\(sqlite3_extended_errcode(db)): \(String(cString: sqlite3_errmsg(db)))"
            }
            func next() -> Ev? {
                guard !finished, source.error == nil else { return nil }
                if AnalysisRun.cancelled { source.fail(CancellationError()); finished = true; return nil }
                let rc = sqlite3_step(statement)
                guard rc == SQLITE_ROW else {
                    finished = true
                    if rc != SQLITE_DONE { source.fail(ReadError.step(message())) }
                    return nil
                }
                return autoreleasepool {
                    let tag = Int(sqlite3_column_int(statement, 1))
                    var json: [String: Any] = [:]
                    if tag != 0x7e && tag != 0x7f && (!source.metadata || tag == 66 || tag == 133) {
                        guard let text = sqlite3_column_text(statement, 2),
                              let data = String(cString: text).data(using: .utf8),
                              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            source.fail(ReadError.step("malformed event JSON; refusing partial analysis")); finished = true; return nil
                        }
                        json = parsed
                    }
                    let body = sqlite3_column_blob(statement, 4).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(statement, 4))) }
                    return Ev(ds: sqlite3_column_int64(statement, 0), tag: tag, json: json,
                              cu: sqlite3_column_int64(statement, 3), body: body)
                }
            }
        }
    }

    static func decodedEvents(dbPath: String) throws -> Events {
        let events = Events(path: dbPath)
        _ = events.isEmpty
        try events.validate()
        return events
    }

    // `ds` (ring_timestamp) is a per-boot relative deciseconds counter — it resets to ~0
    // every time the ring reboots. A single global anchor therefore mis-dates older
    // boots (data scattered months off). Recover each boot "epoch" by walking events in
    // real sync order (captured_unix, then insertion id) and splitting on backward jumps
    // in ds, then anchor each epoch independently. Mirrors crates/oura-summary/src/lib.rs
    // and tools/epoch_time.py so the on-device models and the shared brain agree.
    struct Epoch {
        var minDs: Int64
        var maxDs: Int64
        var captureMin: Int64
        var captureMax: Int64
        var fallbackAnchorUnix: Int64
        var anchors: [(ds: Int64, unix: Int64)]
        // `ring_start` ds values: where a stalled (brownout) counter lost its time.
        var boots: [Int64] = []
    }

    /// Immutable clock mapping shared by the on-device models. Epoch construction and
    /// replay recovery are paid once per model run instead of once per sample.
    struct RingClock {
        private static let epochResetSlackDs: Int64 = 6 * 3600 * 10
        private static let futureSlackSeconds: Int64 = 6 * 3600
        // Two anchors of one boot must agree on the counter rate (10 ds/s plus drift).
        // A fresh ring's first days ran the counter erratically — weeks of ds in an
        // hour — so nothing between two disagreeing anchors has a calendar day.
        // Mirrors ANCHOR_AGREEMENT_* in crates/oura-summary/src/ring_time.rs.
        private static let anchorAgreementSeconds = 30.0 * 60.0
        private static let anchorAgreementFraction = 0.02

        /// How a wall-clock time was obtained. Mirrors `ClockSource` in ring_time.rs:
        /// only `anchor`/`projected` are trustworthy; `downloadTime` is off by up to a
        /// sync gap and `undated` means nothing ties that boot to real time.
        enum Source: String { case anchor, projected, downloadTime = "download_time", undated
            var isDated: Bool { self == .anchor || self == .projected }
        }

        private let epochs: [Epoch]
        private let anchorOffsetsDs: [(offset: Int64, epoch: Int)]

        init(events: Events) {
            precondition(!events.isEmpty)
            var built: [Epoch] = []
            for event in events.restricted("1", metadata: true) {
                if var epoch = built.last,
                   event.ds >= epoch.maxDs - Self.epochResetSlackDs {
                    if event.ds >= epoch.maxDs {
                        epoch.maxDs = event.ds
                        epoch.fallbackAnchorUnix = event.cu
                    }
                    epoch.minDs = min(epoch.minDs, event.ds)
                    epoch.captureMin = min(epoch.captureMin, event.cu)
                    epoch.captureMax = max(epoch.captureMax, event.cu)
                    if (event.tag == 0x42 || event.tag == 0x85),
                       let unix = (event.json["unix_time"] as? NSNumber)?.int64Value {
                        epoch.anchors.append((event.ds, unix))
                    }
                    built[built.count - 1] = epoch
                } else {
                    var anchors: [(Int64, Int64)] = []
                    if (event.tag == 0x42 || event.tag == 0x85),
                       let unix = (event.json["unix_time"] as? NSNumber)?.int64Value {
                        anchors.append((event.ds, unix))
                    }
                    built.append(Epoch(minDs: event.ds, maxDs: event.ds,
                                       captureMin: event.cu, captureMax: event.cu,
                                       fallbackAnchorUnix: event.cu, anchors: anchors))
                }
                if event.tag == 0x41 { built[built.count - 1].boots.append(event.ds) }
            }
            for index in built.indices { built[index].anchors.sort { $0.ds < $1.ds } }
            epochs = built
            anchorOffsetsDs = built.enumerated()
                .flatMap { index, epoch in epoch.anchors.map { ($0.unix * 10 - $0.ds, index) } }
                .sorted { $0.0 < $1.0 }
        }

        /// Map a raw ds to wall-clock seconds via time-sync or RTC beacon anchors.
        /// `capturedUnix` selects the right boot when ds ranges overlap.
        func unixSeconds(_ ds: Int64, capturedUnix: Int64? = nil) -> Double {
            resolve(ds, capturedUnix: capturedUnix).unix
        }

        /// Wall-clock seconds only when the boot clock can be trusted for this ds;
        /// nil for undated data, which the per-day models must leave out.
        func datedUnixSeconds(_ ds: Int64, capturedUnix: Int64? = nil) -> Double? {
            let resolved = resolve(ds, capturedUnix: capturedUnix)
            return resolved.source == .undated ? nil : resolved.unix
        }

        /// How the anchors on either side of `ds` relate: they agree; the counter
        /// stalled between them (ring off, wall clock ran ahead) so the later anchor's
        /// offset applies from the stall on; or the counter ran faster than wall time
        /// (a fresh ring's erratic first days) and nothing between them is datable.
        /// Outside the anchored range the nearest anchor extrapolates as usual.
        private enum Bracket { case consistent, stalled(before: (ds: Int64, unix: Int64), after: (ds: Int64, unix: Int64)), erratic }
        private static func bracket(_ anchors: [(ds: Int64, unix: Int64)], _ ds: Int64) -> Bracket {
            var low = 0, high = anchors.count
            while low < high {
                let middle = (low + high) / 2
                if anchors[middle].ds < ds { low = middle + 1 } else { high = middle }
            }
            guard low < anchors.count, low > 0 else { return .consistent }
            let next = anchors[low], prev = anchors[low - 1]
            if next.ds == ds { return .consistent }
            let wall = Double(next.unix - prev.unix)
            let counter = Double(next.ds - prev.ds) / 10.0
            let tolerance = max(anchorAgreementSeconds, counter * anchorAgreementFraction)
            if wall < counter - tolerance { return .erratic }
            if wall > counter + tolerance { return .stalled(before: prev, after: next) }
            return .consistent
        }

        func resolve(_ ds: Int64, capturedUnix: Int64? = nil) -> (unix: Double, source: Source) {
            let candidates = epochs.filter {
                ds >= $0.minDs - Self.epochResetSlackDs
                    && ds <= $0.maxDs + Self.epochResetSlackDs
            }
            let epoch: Epoch
            if let capturedUnix, !candidates.isEmpty {
                epoch = candidates.min { lhs, rhs in
                    Self.captureDistance(capturedUnix, lhs)
                        < Self.captureDistance(capturedUnix, rhs)
                }!
            } else {
                epoch = candidates.min { ($0.maxDs - $0.minDs) < ($1.maxDs - $1.minDs) }
                    ?? epochs[epochs.count - 1]
            }
            if let anchor = epoch.anchors.min(by: { abs($0.ds - ds) < abs($1.ds - ds) }) {
                let predicted = Double(anchor.unix) + Double(ds - anchor.ds) / 10.0
                switch Self.bracket(epoch.anchors, ds) {
                case .erratic:
                    return (predicted, .undated)
                case .stalled(let before, let after):
                    let late = Double(after.unix) - Double(after.ds - ds) / 10.0
                    let early = Double(before.unix) + Double(ds - before.ds) / 10.0
                    // A ring_start between the anchors marks the stall exactly.
                    let boots = epoch.boots.filter { $0 > before.ds && $0 <= after.ds }
                    if let first = boots.min(), let last = boots.max(), ds >= first && ds < last {
                        return (predicted, .undated)
                    }
                    if let boot = boots.max() {
                        return (ds >= boot ? late : early, .anchor)
                    }
                    let plausible = capturedUnix.map { late <= Double($0 + Self.futureSlackSeconds) } ?? true
                    return (plausible ? late : early, .anchor)
                case .consistent:
                    break
                }
                if capturedUnix == nil
                    || predicted <= Double(capturedUnix! + Self.futureSlackSeconds) {
                    return (predicted, .anchor)
                }
                if let capturedUnix,
                   let projected = latestPlausibleProjection(ds, capturedUnix: capturedUnix) {
                    return (projected, .projected)
                }
                let fallback = Double(epoch.fallbackAnchorUnix)
                    - Double(epoch.maxDs - ds) / 10.0
                let unix = capturedUnix.map {
                    min(fallback, Double($0 + Self.futureSlackSeconds))
                } ?? fallback
                return (unix, .undated)
            }
            // Download-time arithmetic only when the phone kept up with the ring (capture
            // span comparable to the ds span). A boot downloaded in one go would be dated
            // to the sync moment, so it is reported undated instead.
            let dsSpan = Double(epoch.maxDs - epoch.minDs) / 10.0
            let captureSpan = Double(epoch.captureMax - epoch.captureMin)
            let incremental = dsSpan <= 0 || captureSpan * 2 >= dsSpan
            let fallback = Double(epoch.fallbackAnchorUnix)
                - Double(epoch.maxDs - ds) / 10.0
            let unix = capturedUnix.map {
                min(fallback, Double($0 + Self.futureSlackSeconds))
            } ?? fallback
            return (unix, incremental ? .downloadTime : .undated)
        }

        var latestUnix: Int64 {
            epochs.flatMap(\.anchors).map(\.unix).max()
                ?? epochs.map(\.fallbackAnchorUnix).max()!
        }

        private static func captureDistance(_ capturedUnix: Int64, _ epoch: Epoch) -> Int64 {
            if capturedUnix < epoch.captureMin { return epoch.captureMin - capturedUnix }
            if capturedUnix > epoch.captureMax { return capturedUnix - epoch.captureMax }
            return 0
        }

        private func latestPlausibleProjection(_ ds: Int64, capturedUnix: Int64) -> Double? {
            let maxOffset = (capturedUnix + Self.futureSlackSeconds) * 10 - ds
            var low = 0
            var high = anchorOffsetsDs.count
            while low < high {
                let middle = low + (high - low) / 2
                if anchorOffsetsDs[middle].offset <= maxOffset {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            // Borrowing another boot's clock is only legitimate when this ds continues
            // that boot's counter: a new boot restarts near zero and must never be
            // projected through an older boot that only ran at higher counts, and a
            // counter jump far beyond an older boot's maxDs must not borrow it either.
            var index = low - 1
            while index >= 0 {
                let candidate = anchorOffsetsDs[index]
                let ep = epochs[candidate.epoch]
                if ds >= ep.minDs - Self.epochResetSlackDs && ds <= ep.maxDs + Self.epochResetSlackDs {
                    return Double(ds + candidate.offset) / 10.0
                }
                index -= 1
            }
            return nil
        }
    }
}
#endif
