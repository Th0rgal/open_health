#if TORCH
import CryptoKit
import Foundation

// Persisted per-unit results of the on-device models, so a reload after a sync
// only recomputes the days/nights whose inputs actually changed (usually just
// today) and a mid-run kill resumes instead of restarting. Entries are keyed by
// a fingerprint of the EXACT model inputs, so a cache hit is by construction the
// result the model would have produced — rebases, redecodes, and RingClock
// re-anchoring all change the inputs and therefore miss.

/// FNV-1a 64 — deterministic, dependency-free hashing of model input material.
struct FNV64 {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325
    mutating func combine(_ x: UInt64) {
        var v = x
        for _ in 0..<8 {
            value = (value ^ (v & 0xff)) &* 0x0000_0100_0000_01b3
            v >>= 8
        }
    }
    mutating func combine(_ x: Int64) { combine(UInt64(bitPattern: x)) }
    mutating func combine(_ x: Int) { combine(Int64(x)) }
    mutating func combine(_ x: Double) { combine(x.bitPattern) }
    mutating func combine(_ x: Float) { combine(UInt64(x.bitPattern)) }
    mutating func combine(_ xs: [Float]) { combine(xs.count); for x in xs { combine(x) } }
    var hex: String { String(format: "%016llx", value) }
}

struct ActivityDayEntry: Codable {
    var fp: String
    var sessions: [WorkoutSession]
}

struct StagedNightEntry: Codable {
    var fp: String
    var stages: [Int]
}

private struct ModelCacheFile<Entry: Codable>: Codable {
    var version: Int
    var globalKey: String
    var entries: [String: Entry]
}

/// Mirrors SummaryCache: Application Support, serial queue, atomic writes.
enum ModelCacheStore {
    static let version = 2
    static let activityFile = "activity-model-cache.json"
    static let stagingFile = "sleep-staging-cache.json"
    private static let queue = DispatchQueue(label: "md.thomas.openoura.model-cache", qos: .utility)

    private static func url(_ file: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(file)
    }

    /// Entries for `file`, or empty when missing / from another schema version /
    /// written under a different global key (profile, timezone, DB, app build).
    static func load<E: Codable>(_ file: String, globalKey: String) -> [String: E] {
        guard let data = try? Data(contentsOf: url(file)),
              let decoded = try? JSONDecoder().decode(ModelCacheFile<E>.self, from: data),
              decoded.version == version, decoded.globalKey == globalKey
        else { return [:] }
        return decoded.entries
    }

    static func save<E: Codable>(_ file: String, globalKey: String, entries: [String: E]) {
        let payload = ModelCacheFile(version: version, globalKey: globalKey, entries: entries)
        queue.async {
            guard let data = try? JSONEncoder().encode(payload) else { return }
            try? data.write(to: url(file), options: .atomic)
        }
    }

    static func clearAll() {
        queue.sync {
            try? FileManager.default.removeItem(at: url(activityFile))
            try? FileManager.default.removeItem(at: url(stagingFile))
        }
    }

    /// Everything that invalidates every cached unit at once: model demographics,
    /// day bucketing, which DB is being read, and the app build (a shipped model
    /// or port change must not serve results from the old code).
    static func globalKey(profile: Profile?) -> String {
        let material = "v\(version)|\(profile?.sex ?? "")|\(profile?.age ?? -1)"
            + "|\(profile?.height_m ?? -1)|\(profile?.weight_kg ?? -1)|\(profile?.ring_size ?? -1)"
            + "|\(TimeZone.current.identifier)"
            + "|\(DB.readPath())"
            + "|\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "")"
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
