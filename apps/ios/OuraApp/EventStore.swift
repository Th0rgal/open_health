#if TORCH
import Foundation
// sqlite3 comes from the bridging header (TorchBridge.h includes <sqlite3.h>)

// Shared DB reader for the on-device models. SleepStaging and ActivityModel both need
// the same decoded-JSON event stream and time anchor; this is that read in one place
// (CvaModel reads raw PPG blobs instead, so it opens the DB itself).
enum EventStore {
    // A decoded event row: ring timestamp (ds), tag, decoded JSON, capture unix time.
    struct Ev {
        let ds: Int64
        let tag: Int
        let json: [String: Any]
        let cu: Int64
        let body: Data?
    }

    /// All events with decoded JSON, ordered by ring timestamp. Empty on any failure.
    static func decodedEvents(dbPath: String) -> [Ev] {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        var events: [Ev] = []
        var stmt: OpaquePointer?
        let sql = "SELECT ring_timestamp, tag, decoded_json, captured_unix, body FROM events WHERE decoded_json IS NOT NULL ORDER BY captured_unix, id"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let cText = sqlite3_column_text(stmt, 2),
                      let data = String(cString: cText).data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                let body: Data?
                if let bytes = sqlite3_column_blob(stmt, 4) {
                    body = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 4)))
                } else {
                    body = nil
                }
                events.append(Ev(ds: sqlite3_column_int64(stmt, 0),
                                 tag: Int(sqlite3_column_int(stmt, 1)),
                                 json: obj,
                                 cu: sqlite3_column_int64(stmt, 3),
                                 body: body))
            }
        }
        sqlite3_finalize(stmt)
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
    }

    /// Immutable clock mapping shared by the on-device models. Epoch construction and
    /// replay recovery are paid once per model run instead of once per sample.
    struct RingClock {
        private static let epochResetSlackDs: Int64 = 6 * 3600 * 10
        private static let futureSlackSeconds: Int64 = 6 * 3600

        private let epochs: [Epoch]
        private let anchorOffsetsDs: [Int64]

        init(events: [Ev]) {
            precondition(!events.isEmpty)
            var built: [Epoch] = []
            for event in events {
                if var epoch = built.last,
                   event.ds >= epoch.maxDs - Self.epochResetSlackDs {
                    if event.ds >= epoch.maxDs {
                        epoch.maxDs = event.ds
                        epoch.fallbackAnchorUnix = event.cu
                    }
                    epoch.minDs = min(epoch.minDs, event.ds)
                    epoch.captureMin = min(epoch.captureMin, event.cu)
                    epoch.captureMax = max(epoch.captureMax, event.cu)
                    if event.tag == 0x42,
                       let unix = (event.json["unix_time"] as? NSNumber)?.int64Value {
                        epoch.anchors.append((event.ds, unix))
                    }
                    built[built.count - 1] = epoch
                } else {
                    var anchors: [(Int64, Int64)] = []
                    if event.tag == 0x42,
                       let unix = (event.json["unix_time"] as? NSNumber)?.int64Value {
                        anchors.append((event.ds, unix))
                    }
                    built.append(Epoch(minDs: event.ds, maxDs: event.ds,
                                       captureMin: event.cu, captureMax: event.cu,
                                       fallbackAnchorUnix: event.cu, anchors: anchors))
                }
            }
            epochs = built
            anchorOffsetsDs = built.flatMap(\.anchors)
                .map { $0.unix * 10 - $0.ds }
                .sorted()
        }

        /// Map a raw ds to wall-clock seconds via the ring's authoritative time-sync.
        /// `capturedUnix` selects the right boot when ds ranges overlap.
        func unixSeconds(_ ds: Int64, capturedUnix: Int64? = nil) -> Double {
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
                if capturedUnix == nil
                    || predicted <= Double(capturedUnix! + Self.futureSlackSeconds) {
                    return predicted
                }
            }
            if let capturedUnix,
               let predicted = latestPlausibleProjection(ds, capturedUnix: capturedUnix) {
                return predicted
            }
            let fallback = Double(epoch.fallbackAnchorUnix)
                - Double(epoch.maxDs - ds) / 10.0
            return capturedUnix.map {
                min(fallback, Double($0 + Self.futureSlackSeconds))
            } ?? fallback
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
                if anchorOffsetsDs[middle] <= maxOffset {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            guard low > 0 else { return nil }
            return Double(ds + anchorOffsetsDs[low - 1]) / 10.0
        }
    }
}
#endif
