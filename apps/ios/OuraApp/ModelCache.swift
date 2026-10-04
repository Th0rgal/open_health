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
    /// Set when the model rejected these exact inputs; absent in older files.
    var failed: Bool?
}

/// A single cached model result keyed by the fingerprint of its inputs (illness, CVA).
struct FingerprintedEntry<Value: Codable>: Codable {
    var fp: String
    var value: Value
}

struct StagedNightEntry: Codable {
    var fp: String
    var stages: [Int]
}

private struct ModelCacheFile<Entry: Codable>: Codable {
    var version: Int
    var globalKey: String
    var entries: [String: Entry]
    /// Cheap identity of the inputs the entries were computed from (e.g. the event
    /// store's row count and last id). When it still matches, a model can return its
    /// cached results without streaming the store at all.
    var digest: String?
    /// The last few generations written under other global keys, newest first.
    /// Travelling out of a timezone and back (or undoing a profile edit) restores
    /// them instead of recomputing the whole history twice. Absent in older files
    /// and in files saved without `keepGenerations`.
    var previous: [ModelCacheGeneration<Entry>]?
}

private struct ModelCacheGeneration<Entry: Codable>: Codable {
    var globalKey: String
    var entries: [String: Entry]
    /// The completed-run digest that generation had, so coming back to its key can
    /// take the digest fast path too. Absent in older files.
    var digest: String?
}

private struct ModelCacheDigest: Codable {
    var version: Int
    var globalKey: String
    var digest: String?
    var previous: [ModelCacheGenerationDigest]?
}

private struct ModelCacheGenerationDigest: Codable {
    var globalKey: String
    var digest: String?
}

/// Mirrors SummaryCache: Application Support, serial queue, atomic writes.
enum ModelCacheStore {
    // 8: SleepNet epochs aligned by their end time (every cached hypnogram had an
    // unknown first epoch and was reported incomplete).
    static let version = 8
    static let cvaFile = "cva-model-cache.json"
    static let illnessFile = "illness-model-cache.json"
    static let activityFile = "activity-model-cache.json"
    static let stagingFile = "sleep-staging-cache.json"
    /// Generations kept besides the current one (see `ModelCacheFile.previous`).
    static let previousGenerations = 2
    private static let queue = DispatchQueue(label: "md.thomas.openoura.model-cache", qos: .utility)

    private static func url(_ file: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(file)
    }

    /// Entries for `file`, or empty when missing / from another schema version /
    /// written under a different global key (profile, timezone, DB, app build).
    static func load<E: Codable>(_ file: String, globalKey: String) -> [String: E] {
        queue.sync {
            guard let data = try? Data(contentsOf: url(file)) else { return [:] }
            guard let decoded = try? JSONDecoder().decode(ModelCacheFile<E>.self, from: data) else {
                dlog("models", "\(file): cache unreadable, recomputing everything")
                return [:]
            }
            guard decoded.version == version else {
                dlog("models", "\(file): cache discarded (schema v\(decoded.version)→v\(version)), recomputing everything")
                return [:]
            }
            guard decoded.globalKey == globalKey else {
                if let earlier = decoded.previous?.first(where: { $0.globalKey == globalKey }) {
                    dlog("models", "\(file): restored \(earlier.entries.count) entries saved under global key \(globalKey.prefix(8)) (was \(decoded.globalKey.prefix(8)))")
                    return earlier.entries
                }
                dlog("models", "\(file): cache discarded (global key \(decoded.globalKey.prefix(8))→\(globalKey.prefix(8)): profile, timezone or store changed), recomputing everything")
                return [:]
            }
            return decoded.entries
        }
    }

    /// The digest a complete run stored, or nil when the file is missing, stale or
    /// was last written mid-run.
    static func loadDigest(_ file: String, globalKey: String) -> String? {
        queue.sync {
            guard let data = try? Data(contentsOf: url(file)),
                  let decoded = try? JSONDecoder().decode(ModelCacheDigest.self, from: data),
                  decoded.version == version else { return nil }
            if decoded.globalKey == globalKey { return decoded.digest }
            return decoded.previous?.first(where: { $0.globalKey == globalKey })?.digest
        }
    }

    /// Every entry is a finished, input-fingerprinted result, so it is worth keeping
    /// even when the run around it is being cancelled (backgrounding mid-history
    /// used to throw away every day computed so far and redo them on relaunch).
    /// `digest` is only passed by a run that finished every entry.
    ///
    /// `keepGenerations` is for timezone/profile-keyed files (activity, illness):
    /// the other generations are carried forward and a key change demotes the
    /// file's current one into them. Timezone-free files never switch back, so
    /// they don't pay for rereading and rewriting a generation nothing can reuse.
    static func save<E: Codable>(_ file: String, globalKey: String, entries: [String: E], digest: String? = nil,
                                 keepGenerations: Bool = false) {
        queue.async {
            var payload = ModelCacheFile(version: version, globalKey: globalKey, entries: entries, digest: digest)
            if keepGenerations,
               let data = try? Data(contentsOf: url(file)),
               let old = try? JSONDecoder().decode(ModelCacheFile<E>.self, from: data),
               old.version == version {
                var previous = old.previous ?? []
                if old.globalKey != globalKey {
                    previous.insert(ModelCacheGeneration(globalKey: old.globalKey, entries: old.entries,
                                                         digest: old.digest), at: 0)
                }
                previous = Array(previous.filter { $0.globalKey != globalKey }.prefix(previousGenerations))
                payload.previous = previous.isEmpty ? nil : previous
            }
            guard let data = try? JSONEncoder().encode(payload) else { return }
            try? data.write(to: url(file), options: .atomic)
        }
    }

    static func clearAll() {
        queue.sync {
            try? FileManager.default.removeItem(at: url(cvaFile))
            try? FileManager.default.removeItem(at: url(illnessFile))
            try? FileManager.default.removeItem(at: url(activityFile))
            try? FileManager.default.removeItem(at: url(stagingFile))
        }
    }

    /// Everything that invalidates every cached unit at once: model demographics,
    /// day bucketing, and which store is being read (the bundled seed vs the synced
    /// store). Deliberately NOT the DB's absolute path (it contains the install
    /// container id, so every reinstall/dev build used to recompute all history)
    /// nor the build number: a shipped model or port change bumps `version` instead.
    ///
    /// `timezone: false` is for models whose inputs and outputs are absolute times
    /// (sleep staging, CVA): the timezone cannot change their result, and keying on it
    /// recomputed all of them after every trip.
    static func globalKey(profile: Profile?, timezone: Bool = true) -> String {
        let material = "v\(version)|\(profile?.sex ?? "")|\(profile?.age ?? -1)"
            + "|\(profile?.height_m ?? -1)|\(profile?.weight_kg ?? -1)|\(profile?.ring_size ?? -1)"
            + (timezone ? "|\(TimeZone.current.identifier)" : "")
            + "|\(storeKind())"
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func storeKind() -> String {
        DB.readPath() == DB.url.path ? "store" : "seed"
    }
}
#endif
