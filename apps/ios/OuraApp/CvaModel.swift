#if TORCH
import Foundation
// sqlite3 comes from the bridging header (TorchBridge.h includes <sqlite3.h>)

// On-device cardiovascular age: decode the ring's raw PPG (cva_raw_ppg_data, tag
// 0x81) the same way the app does, segment it into 1500-sample windows, and run
// cva_2_1_0 — a faithful port of tools/run_cva_model.py. Returns (vascular_age,
// pwv, segments), or nil when there's no usable PPG.
enum CvaModel {
    private static let SEG_LEN = 1500
    private static let GAP_DS: Int64 = 20  // >2 s splits two PPG measurements

    struct Result: Codable { let vascularAge: Double; let pwv: Double; let segments: Int }

    // Returns the CVA result (nil when there's simply no usable PPG), plus a non-nil
    // `error` only for genuine failures (model missing / inference failed despite data).
    static func run(sex: String, age: Double, heightM: Double, weightKg: Double, ringSize: Double) -> (result: Result?, error: String?) {
        let dbPath = DB.readPath()
        guard let modelPath = Bundle.main.path(forResource: "cva_2_1_0", ofType: "ptl")
        else { return (nil, "cardiovascular model file missing from the app bundle") }

        let sexVal: Float = sex.uppercased() == "F" ? -1 : (sex.uppercased() == "O" ? 0 : 1)
        var demo: [Float] = [sexVal, Float(heightM), Float(age), Float(ringSize), Float(weightKg)]

        // Vascular age moves on a scale of months; one inference per local day is
        // plenty, and every sync adds PPG segments that would otherwise trigger a
        // ~30 s recompute on the phone. The demographics are part of that daily stamp,
        // so a profile edit still recomputes the same day.
        let key = ModelCacheStore.globalKey(profile: nil, timezone: false)
        var demoHash = FNV64(); demoHash.combine(demo)
        let today = "\(localDay())|\(demoHash.hex)"
        if ModelCacheStore.loadDigest(ModelCacheStore.cvaFile, globalKey: key) == today {
            let cached: [String: FingerprintedEntry<Result>] = ModelCacheStore.load(ModelCacheStore.cvaFile, globalKey: key)
            if let entry = cached["result"] { dlog("models", "cva cache=today segments=\(entry.value.segments)"); return (entry.value, nil) }
        }
        let read = selectedSegments(dbPath: dbPath)
        guard var segments = read.segments else { return (nil, read.error) }
        let nSegs = segments.count / SEG_LEN
        guard nSegs > 0 else { return (nil, nil) }

        guard !AnalysisRun.cancelled else { return (nil, "analysis paused") }
        // Segments and demographics are fingerprinted inside the entry; the file key
        // is the stable global key so a newly synced PPG segment never discards the file.
        var fingerprint = FNV64(); fingerprint.combine(segments); fingerprint.combine(demo)
        let cached: [String: FingerprintedEntry<Result>] = ModelCacheStore.load(ModelCacheStore.cvaFile, globalKey: key)
        if let entry = cached["result"], entry.fp == fingerprint.hex {
            dlog("models", "cva cache=hit segments=\(nSegs)")
            ModelCacheStore.save(ModelCacheStore.cvaFile, globalKey: key, entries: cached, digest: today)
            return (entry.value, nil)
        }
        var vage = 0.0, pwv = 0.0
        let rc = oura_cva(modelPath, &segments, Int32(nSegs), &demo, &vage, &pwv)
        guard rc == 0 else { return (nil, "cardiovascular model failed on \(nSegs) PPG segments") }
        let result = Result(vascularAge: (vage * 10).rounded() / 10, pwv: (pwv * 100).rounded() / 100, segments: nSegs)
        ModelCacheStore.save(ModelCacheStore.cvaFile, globalKey: key,
                             entries: ["result": FingerprintedEntry(fp: fingerprint.hex, value: result)],
                             digest: today)
        dlog("models", "cva cache=miss segments=\(nSegs)")
        return (result, nil)
    }

    private static func localDay() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Separately testable decoding/selection; closes SQLite before inference.
    static func selectedSegments(dbPath: String) -> (segments: [Float]?, error: String?) {
        var db: OpaquePointer?
        // Read-only + busy timeout: a partial PPG read during a sync must fail
        // loudly, never feed the model a truncated waveform.
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            return (nil, "couldn't open the database for CVA: \(msg)")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)

        // Decode incrementally. Preserve the existing timestamp order and last-4000
        // selection, including delta state across packet boundaries within each run.
        let maxSegs = 4000
        var segments: [Float] = []
        segments.reserveCapacity(maxSegs * SEG_LEN)
        var pending: [Float] = []
        var accumulator: Int32 = 0
        var previousTs: Int64?
        var nextSegment = 0
        var totalSegments = 0
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT ring_timestamp, body FROM events WHERE tag=129 AND body IS NOT NULL ORDER BY ring_timestamp", -1, &stmt, nil) == SQLITE_OK else {
            return (nil, "CVA query failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        var rcStep = sqlite3_step(stmt)
        while rcStep == SQLITE_ROW {
            guard !AnalysisRun.cancelled else { return (nil, "analysis paused") }
            let ts = sqlite3_column_int64(stmt, 0)
            let n = Int(sqlite3_column_bytes(stmt, 1))
            if n > 0, let raw = sqlite3_column_blob(stmt, 1) {
                if let previousTs, ts - previousTs > GAP_DS { pending.removeAll(keepingCapacity: true); accumulator = 0 }
                previousTs = ts
                let bytes = raw.assumingMemoryBound(to: UInt8.self)
                var i = 0
                while i < n {
                    let b = bytes[i]
                    if b == 0x80 && i + 3 < n {
                        var absolute = Int32(bytes[i+1]) | (Int32(bytes[i+2]) << 8) | (Int32(bytes[i+3]) << 16)
                        if absolute & 0x800000 != 0 { absolute -= 0x1000000 }
                        accumulator = absolute; i += 4
                    } else { accumulator &+= Int32(Int8(bitPattern: b)); i += 1 }
                    pending.append(Float(accumulator))
                    if pending.count == SEG_LEN {
                        if totalSegments < maxSegs { segments.append(contentsOf: pending) }
                        else { segments.replaceSubrange(nextSegment * SEG_LEN..<(nextSegment + 1) * SEG_LEN, with: pending) }
                        totalSegments += 1
                        nextSegment = totalSegments % maxSegs
                        pending.removeAll(keepingCapacity: true)
                    }
                }
            }
            rcStep = sqlite3_step(stmt)
        }
        guard rcStep == SQLITE_DONE else { return (nil, "CVA read failed: sqlite=\(rcStep) extended=\(sqlite3_extended_errcode(db))") }
        let nSegs = min(totalSegments, maxSegs)
        guard nSegs > 0 else { return ([], nil) }
        if totalSegments > maxSegs, nextSegment > 0 {
            segments = Array(segments[(nextSegment * SEG_LEN)...]) + segments[..<(nextSegment * SEG_LEN)]
        }

        return (segments, nil)
    }

    // PPG delta stream: 0x80 marks the next 3 bytes as an absolute 24-bit sample;
    // otherwise an int8 delta from the previous sample.
    private static func decode(_ bodies: [[UInt8]]) -> [Float] {
        var samples: [Float] = []
        var acc: Int32 = 0
        for data in bodies {
            var i = 0; let n = data.count
            while i < n {
                let b = data[i]
                if b == 0x80 && i + 3 < n {
                    var raw = Int32(data[i + 1]) | (Int32(data[i + 2]) << 8) | (Int32(data[i + 3]) << 16)
                    if raw & 0x800000 != 0 { raw -= 0x1000000 }
                    acc = raw; samples.append(Float(acc)); i += 4
                } else {
                    acc &+= Int32(Int8(bitPattern: b)); samples.append(Float(acc)); i += 1
                }
            }
        }
        return samples
    }
}
#endif
