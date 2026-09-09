package md.thomas.openoura.data

import android.database.sqlite.SQLiteDatabase
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlin.math.abs
import kotlin.math.min

/**
 * Shared DB reader for the on-device models. Sleep staging and activity detection both
 * need the same decoded-JSON event stream and time anchor; this is that read in one
 * place (the CVA model reads raw PPG blobs instead, so it opens the DB itself).
 *
 * Port of apps/ios/OuraApp/EventStore.swift.
 */
object EventStore {

    /**
     * A failed read must never masquerade as "no data": a truncated event list would wipe
     * every model-derived panel and get persisted by the summary cache.
     */
    class ReadException(message: String, cause: Throwable? = null) : Exception(message, cause)

    /** A decoded event row: ring timestamp (ds), tag, decoded JSON, capture unix time. */
    class Ev(
        val ds: Long,
        val tag: Int,
        val json: JsonObject?,
        val cu: Long,
        val body: ByteArray?,
    ) {
        /** A numeric field of the decoded JSON, or null when absent/not a number. */
        fun num(key: String): Double? = json?.get(key)?.jsonPrimitive?.doubleOrNull

        fun long(key: String): Long? = json?.get(key)?.jsonPrimitive?.longOrNull
    }

    private const val SQL =
        "SELECT ring_timestamp, tag, decoded_json, captured_unix, body FROM events " +
            "WHERE decoded_json IS NOT NULL ORDER BY captured_unix, id"

    /**
     * All events with decoded JSON, ordered by sync order. Throws on any failure —
     * callers must distinguish "no data" (empty list) from "couldn't read".
     */
    fun decodedEvents(dbPath: String): List<Ev> {
        val db = try {
            // Read-only: the sync writer may hold the file. Rust owns the schema, so we
            // never let the framework try to create or upgrade it.
            SQLiteDatabase.openDatabase(dbPath, null, SQLiteDatabase.OPEN_READONLY)
        } catch (e: Exception) {
            throw ReadException("couldn't open the ring database: ${e.message}", e)
        }
        try {
            val events = ArrayList<Ev>()
            db.rawQuery(SQL, null).use { c ->
                while (c.moveToNext()) {
                    val tag = c.getInt(1)
                    val body = if (c.isNull(4)) null else c.getBlob(4)
                    // real_step packets (0x7E/0x7F) are 14-byte bodies. Parsing their JSON
                    // on hiking-heavy histories is a large share of the analysis RAM spike
                    // and the models never read that JSON.
                    val json = if (tag == 0x7E || tag == 0x7F) {
                        null
                    } else {
                        val text = c.getString(2) ?: continue
                        try {
                            SummaryJson.parseToJsonElement(text) as? JsonObject ?: continue
                        } catch (_: Exception) {
                            continue
                        }
                    }
                    events.add(Ev(c.getLong(0), tag, json, c.getLong(3), body))
                }
            }
            return events
        } catch (e: ReadException) {
            throw e
        } catch (e: Exception) {
            throw ReadException("ring database read was interrupted: ${e.message}", e)
        } finally {
            db.close()
        }
    }

    class Epoch(
        var minDs: Long,
        var maxDs: Long,
        var captureMin: Long,
        var captureMax: Long,
        var fallbackAnchorUnix: Long,
        val anchors: MutableList<Anchor>,
    )

    data class Anchor(val ds: Long, val unix: Long)

    /**
     * `ds` (ring_timestamp) is a per-boot relative deciseconds counter — it resets to ~0
     * every time the ring reboots. A single global anchor therefore mis-dates older boots
     * (data scattered months off). Recover each boot "epoch" by walking events in real
     * sync order (captured_unix, then insertion id) and splitting on backward jumps in
     * ds, then anchor each epoch independently.
     *
     * This is one of THREE implementations that must agree — see docs/clients.md:
     * `crates/oura-summary/src/ring_time.rs`, `tools/epoch_time.py`, and this file
     * (plus its iOS twin in EventStore.swift).
     *
     * Epoch construction and replay recovery are paid once per model run rather than
     * once per sample.
     */
    class RingClock(events: List<Ev>) {

        private val epochs: List<Epoch>
        private val anchorOffsetsDs: LongArray

        init {
            require(events.isNotEmpty()) { "RingClock needs at least one event" }
            val built = ArrayList<Epoch>()
            for (event in events) {
                val last = built.lastOrNull()
                if (last != null && event.ds >= last.maxDs - EPOCH_RESET_SLACK_DS) {
                    if (event.ds >= last.maxDs) {
                        last.maxDs = event.ds
                        last.fallbackAnchorUnix = event.cu
                    }
                    last.minDs = min(last.minDs, event.ds)
                    last.captureMin = min(last.captureMin, event.cu)
                    last.captureMax = maxOf(last.captureMax, event.cu)
                    if (event.tag == 0x42) {
                        event.long("unix_time")?.let { last.anchors.add(Anchor(event.ds, it)) }
                    }
                } else {
                    val anchors = ArrayList<Anchor>()
                    if (event.tag == 0x42) {
                        event.long("unix_time")?.let { anchors.add(Anchor(event.ds, it)) }
                    }
                    built.add(
                        Epoch(
                            minDs = event.ds,
                            maxDs = event.ds,
                            captureMin = event.cu,
                            captureMax = event.cu,
                            fallbackAnchorUnix = event.cu,
                            anchors = anchors,
                        )
                    )
                }
            }
            epochs = built
            anchorOffsetsDs = built
                .flatMap { it.anchors }
                .map { it.unix * 10 - it.ds }
                .sorted()
                .toLongArray()
        }

        /**
         * Map a raw ds to wall-clock seconds via the ring's authoritative time-sync.
         * [capturedUnix] selects the right boot when ds ranges overlap.
         */
        fun unixSeconds(ds: Long, capturedUnix: Long? = null): Double {
            val candidates = epochs.filter {
                ds >= it.minDs - EPOCH_RESET_SLACK_DS && ds <= it.maxDs + EPOCH_RESET_SLACK_DS
            }
            val epoch: Epoch = if (capturedUnix != null && candidates.isNotEmpty()) {
                candidates.minByOrNull { captureDistance(capturedUnix, it) }!!
            } else {
                candidates.minByOrNull { it.maxDs - it.minDs } ?: epochs.last()
            }

            epoch.anchors.minByOrNull { abs(it.ds - ds) }?.let { anchor ->
                val predicted = anchor.unix.toDouble() + (ds - anchor.ds) / 10.0
                if (capturedUnix == null ||
                    predicted <= (capturedUnix + FUTURE_SLACK_SECONDS).toDouble()
                ) {
                    return predicted
                }
            }

            // A from-zero recovery drain may replay an older boot after a newer one is
            // already stored. If the selected epoch projects an event more than six hours
            // beyond its phone capture time, fall back to the newest globally plausible
            // time_sync projection — otherwise replay fragments fabricate future days.
            if (capturedUnix != null) {
                latestPlausibleProjection(ds, capturedUnix)?.let { return it }
            }

            val fallback = epoch.fallbackAnchorUnix.toDouble() - (epoch.maxDs - ds) / 10.0
            return if (capturedUnix != null) {
                min(fallback, (capturedUnix + FUTURE_SLACK_SECONDS).toDouble())
            } else {
                fallback
            }
        }

        val latestUnix: Long
            get() = epochs.flatMap { it.anchors }.maxOfOrNull { it.unix }
                ?: epochs.maxOf { it.fallbackAnchorUnix }

        private fun captureDistance(capturedUnix: Long, epoch: Epoch): Long = when {
            capturedUnix < epoch.captureMin -> epoch.captureMin - capturedUnix
            capturedUnix > epoch.captureMax -> capturedUnix - epoch.captureMax
            else -> 0
        }

        private fun latestPlausibleProjection(ds: Long, capturedUnix: Long): Double? {
            val maxOffset = (capturedUnix + FUTURE_SLACK_SECONDS) * 10 - ds
            var low = 0
            var high = anchorOffsetsDs.size
            while (low < high) {
                val middle = low + (high - low) / 2
                if (anchorOffsetsDs[middle] <= maxOffset) low = middle + 1 else high = middle
            }
            if (low == 0) return null
            return (ds + anchorOffsetsDs[low - 1]) / 10.0
        }

        companion object {
            private const val EPOCH_RESET_SLACK_DS = 6L * 3600 * 10
            private const val FUTURE_SLACK_SECONDS = 6L * 3600
        }
    }
}
