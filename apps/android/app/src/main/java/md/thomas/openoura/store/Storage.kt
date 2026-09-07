package md.thomas.openoura.store

import android.content.Context
import android.content.SharedPreferences
import md.thomas.openoura.data.Profile
import md.thomas.openoura.data.Summary
import md.thomas.openoura.data.SummaryJson
import java.io.File

/**
 * Where the app reads/writes its SQLite DB. The synced DB lives in `filesDir`
 * (writable); until a sync has happened we fall back to the seed copied out of assets.
 * Port of `enum DB` in apps/ios/OuraApp/RingSync.swift.
 *
 * `filesDir` — not `getDatabasePath` — because Rust owns the schema and opens the file
 * by absolute path, and `oura-summary` derives `profile.json` / `feature_modes.json`
 * from that same directory (`profile_path` / `feature_modes_path`). The sidecars have
 * to sit NEXT TO the DB or the Rust side writes them somewhere we never read.
 */
object DB {
    const val FILE = "oura.db"
    private const val SEED_ASSET = "oura.db"

    fun file(context: Context): File = File(context.filesDir, FILE)

    /** Absolute path of the DB to READ from (synced if present, else the seed). */
    fun readPath(context: Context): String {
        val f = file(context)
        if (f.exists()) return f.absolutePath
        return seedFile(context)?.absolutePath ?: f.absolutePath
    }

    /** Absolute path of the DB to WRITE to. Always the writable copy. */
    fun writePath(context: Context): String = file(context).absolutePath

    /**
     * iOS gets its seed DB for free as a bundle resource; on Android an asset is inside
     * the APK and has no filesystem path, so it is copied out once into a cache file.
     * Absent in CI and in the `lite` flavor's plain builds — the app then shows the
     * "run a sync first" empty state, exactly as iOS does without a bundled DB.
     */
    private fun seedFile(context: Context): File? {
        val dst = File(context.cacheDir, "seed-oura.db")
        if (dst.exists() && dst.length() > 0) return dst
        return try {
            context.assets.open(SEED_ASSET).use { input ->
                dst.outputStream().use { input.copyTo(it) }
            }
            dst
        } catch (_: Exception) {
            null // no seed shipped; that is a normal configuration
        }
    }

    /**
     * Drop the writable synced DB. The seed remains intact; the next sync starts from an
     * empty local store and drains the ring from cursor 0. WAL sidecars go too, or
     * SQLite would reopen against a journal describing a file that no longer exists.
     */
    fun resetWritableStore(context: Context) {
        for (suffix in listOf("", "-wal", "-shm", "-journal")) {
            File(context.filesDir, FILE + suffix).takeIf { it.exists() }?.delete()
        }
    }
}

/**
 * The ring auth key (exported from the desktop client). iOS keeps it in the Keychain;
 * here it is encrypted with an AES/GCM key held in the Android Keystore and stored as
 * ciphertext in SharedPreferences. Never logged — Diagnostics prints only a short
 * SHA-256 fingerprint, matching iOS.
 *
 * `androidx.security:security-crypto` would do the same thing but is deprecated, so we
 * use the Keystore directly rather than take a dependency that is on its way out.
 */
object RingKeyStore {
    private const val PREFS = "ring-secure"
    private const val VALUE = "ring-auth-key"

    fun save(context: Context, hex: String) {
        val sealed = Crypto.encrypt(hex.trim().toByteArray(Charsets.UTF_8))
        prefs(context).edit().putString(VALUE, sealed).apply()
    }

    fun load(context: Context): String? {
        val sealed = prefs(context).getString(VALUE, null) ?: return null
        return try {
            String(Crypto.decrypt(sealed), Charsets.UTF_8)
        } catch (_: Exception) {
            // The Keystore key is gone (app data cleared, device restored from backup
            // onto new hardware). Treat it as "no key" and let the user re-enter it
            // rather than crashing every launch.
            null
        }
    }

    fun clear(context: Context) {
        prefs(context).edit().remove(VALUE).apply()
    }

    private fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}

/** The 32-hex ring key the FFI expects; `parse_key` in Rust rejects anything else. */
fun isValidRingKey(hex: String): Boolean {
    val h = hex.trim()
    return h.length == 32 && h.all { it.isDigit() || it in 'a'..'f' || it in 'A'..'F' }
}

/**
 * Last successfully rendered summary. Display-only: the SQLite store remains the source
 * of truth and a fresh summary always replaces this after launch. Kept out of
 * SharedPreferences because the signal payload can be large. Port of `SummaryCache`.
 */
object SummaryCache {
    private const val FILE = "summary-cache.json"

    fun load(context: Context): Summary? = try {
        val f = File(context.filesDir, FILE)
        if (!f.exists()) null else {
            SummaryJson.decodeFromString(Summary.serializer(), f.readText())
                .takeIf { it.error == null }
        }
    } catch (_: Exception) {
        null
    }

    fun save(context: Context, summary: Summary) {
        if (summary.error != null) return
        try {
            val f = File(context.filesDir, FILE)
            val tmp = File(context.filesDir, "$FILE.tmp")
            tmp.writeText(SummaryJson.encodeToString(Summary.serializer(), summary))
            tmp.renameTo(f)
        } catch (_: Exception) {
            // a cache write failure must never take down a render
        }
    }

    fun clear(context: Context) {
        File(context.filesDir, FILE).delete()
    }
}

/**
 * `profile.json` beside the DB — the same file `oura-summary::read_profile` parses, so
 * the Rust summary picks up demographics the user edits here.
 */
object ProfileStore {
    private const val FILE = "profile.json"

    fun path(context: Context): File = File(context.filesDir, FILE)

    fun load(context: Context): Profile? = try {
        val f = path(context)
        if (f.exists()) SummaryJson.decodeFromString(Profile.serializer(), f.readText()) else null
    } catch (_: Exception) {
        null
    }

    fun save(context: Context, profile: Profile) {
        val f = path(context)
        val tmp = File(context.filesDir, "$FILE.tmp")
        tmp.writeText(SummaryJson.encodeToString(Profile.serializer(), profile))
        tmp.renameTo(f)
    }
}

/** The UserDefaults equivalents from RingSync.swift / HealthExport.swift. */
object Prefs {
    private const val PREFS = "openoura"

    const val LAST_SUCCESSFUL_SYNC_AT = "ring.last-successful-sync-at"
    const val SYNC_INCOMPLETE = "ring.sync-incomplete"
    const val HEALTH_EXPORT_ENABLED = "health.export.enabled"
    const val HEALTH_EXPORT_FP = "health.export.fp"

    fun of(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
