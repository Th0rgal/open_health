package md.thomas.openoura.models

import android.content.Context
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.KSerializer
import md.thomas.openoura.data.Profile
import md.thomas.openoura.data.SummaryJson
import md.thomas.openoura.data.WorkoutSession
import md.thomas.openoura.store.DB
import java.io.File
import java.security.MessageDigest
import java.util.TimeZone

// Persisted per-unit results of the on-device models, so a reload after a sync only
// recomputes the days/nights whose inputs actually changed (usually just today) and a
// mid-run kill resumes instead of restarting. Entries are keyed by a fingerprint of the
// EXACT model inputs, so a cache hit is by construction the result the model would have
// produced — rebases, redecodes, and RingClock re-anchoring all change the inputs and
// therefore miss. Port of apps/ios/OuraApp/ModelCache.swift.

/** FNV-1a 64 — deterministic, dependency-free hashing of model input material. */
class FNV64 {
    var value: ULong = 0xcbf2_9ce4_8422_2325uL
        private set

    fun combine(x: ULong) {
        var v = x
        repeat(8) {
            value = (value xor (v and 0xffuL)) * 0x0000_0100_0000_01b3uL
            v = v shr 8
        }
    }

    fun combine(x: Long) = combine(x.toULong())
    fun combine(x: Int) = combine(x.toLong())
    fun combine(x: Double) = combine(x.toRawBits().toULong())
    fun combine(x: Float) = combine(x.toRawBits().toLong().toULong())
    fun combine(xs: FloatArray) {
        combine(xs.size)
        for (x in xs) combine(x)
    }

    val hex: String get() = "%016x".format(value.toLong())
}

@Serializable
data class ActivityDayEntry(val fp: String, val sessions: List<WorkoutSession>)

@Serializable
data class StagedNightEntry(val fp: String, val stages: List<Int>)

@Serializable
private data class ModelCacheFile<E>(
    val version: Int,
    val globalKey: String,
    val entries: Map<String, E>,
)

/** Mirrors SummaryCache: app files dir, atomic writes. */
object ModelCacheStore {
    const val VERSION = 2
    const val ACTIVITY_FILE = "activity-model-cache.json"
    const val STAGING_FILE = "sleep-staging-cache.json"

    private fun file(context: Context, name: String) = File(context.filesDir, name)

    /**
     * Entries for [name], or empty when missing / from another schema version / written
     * under a different global key (profile, timezone, DB, app build).
     */
    fun <E> load(
        context: Context,
        name: String,
        globalKey: String,
        serializer: KSerializer<E>,
    ): MutableMap<String, E> = try {
        val f = file(context, name)
        if (!f.exists()) mutableMapOf() else {
            val decoded = SummaryJson.decodeFromString(
                ModelCacheFile.serializer(serializer), f.readText()
            )
            if (decoded.version != VERSION || decoded.globalKey != globalKey) mutableMapOf()
            else decoded.entries.toMutableMap()
        }
    } catch (_: Exception) {
        mutableMapOf()
    }

    fun <E> save(
        context: Context,
        name: String,
        globalKey: String,
        entries: Map<String, E>,
        serializer: KSerializer<E>,
    ) {
        try {
            val payload = ModelCacheFile(VERSION, globalKey, entries)
            val tmp = File(context.filesDir, "$name.tmp")
            tmp.writeText(
                SummaryJson.encodeToString(ModelCacheFile.serializer(serializer), payload)
            )
            tmp.renameTo(file(context, name))
        } catch (_: Exception) {
            // a cache write failure must never take down a model run
        }
    }

    fun clearAll(context: Context) {
        file(context, ACTIVITY_FILE).delete()
        file(context, STAGING_FILE).delete()
    }

    /**
     * Everything that invalidates every cached unit at once: model demographics, day
     * bucketing, which DB is being read, and the app build (a shipped model or port
     * change must not serve results from the old code).
     */
    fun globalKey(context: Context, profile: Profile?): String {
        val versionCode = try {
            context.packageManager.getPackageInfo(context.packageName, 0).longVersionCode
        } catch (_: Exception) {
            0L
        }
        val material = "v$VERSION|${profile?.sex ?: ""}|${profile?.age ?: -1}" +
            "|${profile?.heightM ?: -1}|${profile?.weightKg ?: -1}|${profile?.ringSize ?: -1}" +
            "|${TimeZone.getDefault().id}" +
            "|${DB.readPath(context)}" +
            "|$versionCode"
        return MessageDigest.getInstance("SHA-256")
            .digest(material.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
    }
}
