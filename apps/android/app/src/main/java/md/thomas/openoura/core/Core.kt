package md.thomas.openoura.core

import android.content.Context
import md.thomas.openoura.data.Summary
import md.thomas.openoura.data.SummaryJson
import md.thomas.openoura.store.DB
import uniffi.oura_core.quickSummaryJson
import uniffi.oura_core.summaryJson
import java.util.TimeZone
import kotlin.math.roundToLong

/**
 * The shared Rust brain, as seen from Android. `summary_json` is the SAME
 * `oura_summary::build_summary()` the web dashboard and the iOS app render — see
 * docs/clients.md. Port of apps/ios/OuraApp/Core.swift.
 */
object Core {

    /**
     * Fast, model-free summary (vitals, activity ridges, device) straight from the
     * shared-core JSON — safe to compute on a background dispatcher and show at once.
     */
    fun base(context: Context): Summary {
        val path = DB.readPath(context) // synced DB if present, else the seed
        val json = try {
            summaryJson(path, tzOffsetHours())
        } catch (e: Throwable) {
            return Summary(error = "core call failed: ${e.message ?: e.toString()}")
        }
        return decode(json)
    }

    /** `{serials, device, event_counts, decoded_events}` — used by the diagnostics panel. */
    fun quick(context: Context): String = try {
        quickSummaryJson(DB.readPath(context))
    } catch (e: Throwable) {
        """{"error":"${e.message ?: e.toString()}"}"""
    }

    /**
     * The phone's actual UTC offset, so night labels / sleep windows / digest timing
     * match the wearer's local clock — not a hardcoded constant. The whole stack (web
     * --tz-offset, the Python model runners, this FFI) takes whole hours, so round to
     * the nearest hour (the best representable value for sub-hour zones like IST +5:30).
     */
    fun tzOffsetHours(): Long {
        val secs = TimeZone.getDefault().getOffset(System.currentTimeMillis()) / 1000.0
        return (secs / 3600.0).roundToLong()
    }

    internal fun decode(json: String): Summary = try {
        SummaryJson.decodeFromString(Summary.serializer(), json)
    } catch (e: Exception) {
        Summary(error = "decode failed: ${e.message ?: e.toString()}")
    }
}
