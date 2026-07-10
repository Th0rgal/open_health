#if TORCH
import Foundation
// sqlite3 comes from the bridging header (TorchBridge.h includes <sqlite3.h>)

// Shared DB reader for the on-device models. SleepStaging and ActivityModel both need
// the same decoded-JSON event stream and time anchor; this is that read in one place
// (CvaModel reads raw PPG blobs instead, so it opens the DB itself).
enum EventStore {
    // A decoded event row: ring timestamp (ds), tag, decoded JSON, capture unix time.
    struct Ev { let ds: Int64; let tag: Int; let json: [String: Any]; let cu: Int64 }

    /// All events with decoded JSON, ordered by ring timestamp. Empty on any failure.
    static func decodedEvents(dbPath: String) -> [Ev] {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        var events: [Ev] = []
        var stmt: OpaquePointer?
        let sql = "SELECT ring_timestamp, tag, decoded_json, captured_unix FROM events WHERE decoded_json IS NOT NULL ORDER BY captured_unix, id"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let cText = sqlite3_column_text(stmt, 2),
                      let data = String(cString: cText).data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                events.append(Ev(ds: sqlite3_column_int64(stmt, 0),
                                 tag: Int(sqlite3_column_int(stmt, 1)),
                                 json: obj,
                                 cu: sqlite3_column_int64(stmt, 3)))
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

    // A real reboot drops ds by millions; 6 h of slack absorbs minor out-of-order framing
    // within an epoch without ever splitting one.
    static let epochResetSlackDs: Int64 = 6 * 3600 * 10

    /// Segment events into boot epochs. Precondition: `events` is non-empty.
    static func epochs(_ events: [Ev]) -> [Epoch] {
        var eps: [Epoch] = []
        for o in events {
            if var e = eps.last, o.ds >= e.maxDs - epochResetSlackDs {
                if o.ds >= e.maxDs { e.maxDs = o.ds; e.fallbackAnchorUnix = o.cu }
                e.minDs = min(e.minDs, o.ds)
                e.captureMin = min(e.captureMin, o.cu)
                e.captureMax = max(e.captureMax, o.cu)
                if o.tag == 0x42, let unix = (o.json["unix_time"] as? NSNumber)?.int64Value {
                    e.anchors.append((o.ds, unix))
                }
                eps[eps.count - 1] = e
            } else {
                var anchors: [(Int64, Int64)] = []
                if o.tag == 0x42, let unix = (o.json["unix_time"] as? NSNumber)?.int64Value {
                    anchors.append((o.ds, unix))
                }
                eps.append(Epoch(minDs: o.ds, maxDs: o.ds, captureMin: o.cu,
                                 captureMax: o.cu, fallbackAnchorUnix: o.cu, anchors: anchors))
            }
        }
        return eps
    }

    /// Map a raw ds to wall-clock seconds via the ring's authoritative time-sync
    /// record. `capturedUnix` selects the right boot when ds ranges overlap.
    static func unixSeconds(_ ds: Int64, _ eps: [Epoch], capturedUnix: Int64? = nil) -> Double {
        let candidates = eps.filter {
            ds >= $0.minDs - epochResetSlackDs && ds <= $0.maxDs + epochResetSlackDs
        }
        let e: Epoch
        if let cu = capturedUnix, !candidates.isEmpty {
            e = candidates.min { a, b in
                func distance(_ x: Epoch) -> Int64 {
                    if cu < x.captureMin { return x.captureMin - cu }
                    if cu > x.captureMax { return cu - x.captureMax }
                    return 0
                }
                return distance(a) < distance(b)
            }!
        } else {
            e = candidates.min { ($0.maxDs - $0.minDs) < ($1.maxDs - $1.minDs) }
                ?? eps[eps.count - 1]
        }
        if let a = e.anchors.min(by: { abs($0.ds - ds) < abs($1.ds - ds) }) {
            return Double(a.unix) + Double(ds - a.ds) / 10.0
        }
        return Double(e.fallbackAnchorUnix) - Double(e.maxDs - ds) / 10.0
    }

    static func latestUnix(_ eps: [Epoch]) -> Int64 {
        eps.flatMap(\.anchors).map(\.unix).max()
            ?? eps.map(\.fallbackAnchorUnix).max()!
    }
}
#endif
