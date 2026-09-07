package md.thomas.openoura.models

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import md.thomas.openoura.store.DB
import kotlin.math.roundToLong

/**
 * On-device cardiovascular age: decode the ring's raw PPG (cva_raw_ppg_data, tag 0x81 /
 * 129) the same way the official app does, segment it into 1500-sample windows, and run
 * cva_2_1_0 — a faithful port of tools/run_cva_model.py and of
 * apps/ios/OuraApp/CvaModel.swift.
 *
 * This one reads the DB itself rather than sharing EventStore's decoded-JSON pass,
 * because it needs the raw `body` blobs.
 */
object CvaModel {

    private const val SEG_LEN = 1500
    private const val GAP_DS = 20L    // >2 s splits two PPG measurements
    private const val MODEL = "cva_2_1_0"

    /**
     * A long PPG archive can be tens of thousands of 1500-sample windows. Keep the most
     * recent 4000 (enough for the daily CVA estimate) so a hiking-heavy history does not
     * feed a 60 MB tensor into LibTorch.
     */
    private const val MAX_SEGS = 4000

    class Result(val vascularAge: Double, val pwv: Double, val segments: Int)

    class Outcome(val result: Result?, val error: String?)

    /**
     * The CVA result (null when there is simply no usable PPG), plus a non-null error only
     * for genuine failures (model missing / inference failed despite having data).
     */
    fun run(
        context: Context,
        sex: String,
        age: Double,
        heightM: Double,
        weightKg: Double,
        ringSize: Double,
    ): Outcome {
        val modelPath = ModelAssets.path(context, MODEL)
            ?: return Outcome(null, "cardiovascular model file missing from the app assets")

        val timestamps = ArrayList<Long>()
        val bodies = ArrayList<ByteArray>()
        try {
            // Read-only: a partial PPG read during a sync must fail loudly, never feed the
            // model a truncated waveform.
            SQLiteDatabase.openDatabase(
                DB.readPath(context), null, SQLiteDatabase.OPEN_READONLY
            ).use { db ->
                db.rawQuery(
                    "SELECT ring_timestamp, body FROM events " +
                        "WHERE tag=129 AND body IS NOT NULL ORDER BY ring_timestamp",
                    null,
                ).use { c ->
                    while (c.moveToNext()) {
                        val body = c.getBlob(1) ?: continue
                        if (body.isEmpty()) continue
                        timestamps.add(c.getLong(0))
                        bodies.add(body)
                    }
                }
            }
        } catch (e: Exception) {
            return Outcome(null, "couldn't read the database for CVA: ${e.message}")
        }

        if (bodies.isEmpty()) return Outcome(null, null) // no PPG captured — benign

        // Split into contiguous measurement runs, decode and chunk into 1500-sample segments.
        val segments = ArrayList<Float>()
        var run = ArrayList<ByteArray>().apply { add(bodies[0]) }

        fun flush(r: List<ByteArray>) {
            val wave = decode(r)
            var s = 0
            while (s + SEG_LEN <= wave.size) {
                for (i in s until s + SEG_LEN) segments.add(wave[i])
                s += SEG_LEN
            }
        }

        for (i in 1 until bodies.size) {
            if (timestamps[i] - timestamps[i - 1] > GAP_DS) {
                flush(run)
                run = ArrayList()
            }
            run.add(bodies[i])
        }
        flush(run)

        var nSegs = segments.size / SEG_LEN
        if (nSegs == 0) return Outcome(null, null) // PPG present but no full segment — benign

        var flat: FloatArray
        if (nSegs > MAX_SEGS) {
            val from = segments.size - MAX_SEGS * SEG_LEN
            flat = FloatArray(MAX_SEGS * SEG_LEN) { segments[from + it] }
            nSegs = MAX_SEGS
        } else {
            flat = FloatArray(nSegs * SEG_LEN) { segments[it] }
        }

        val sexVal = when (sex.uppercase()) {
            "F" -> -1f
            "O" -> 0f
            else -> 1f
        }
        val demo = floatArrayOf(
            sexVal, heightM.toFloat(), age.toFloat(), ringSize.toFloat(), weightKg.toFloat()
        )

        val out = TorchBridge.cva(modelPath, flat, nSegs, demo)
            ?: return Outcome(null, "cardiovascular model failed on $nSegs PPG segments")

        return Outcome(
            Result(
                vascularAge = (out[0] * 10).roundToLong() / 10.0,
                pwv = (out[1] * 100).roundToLong() / 100.0,
                segments = nSegs,
            ),
            null,
        )
    }

    /**
     * PPG delta stream: 0x80 marks the next 3 bytes as an absolute 24-bit sample;
     * otherwise a signed int8 delta from the previous sample.
     */
    internal fun decode(bodies: List<ByteArray>): FloatArray {
        var total = 0
        for (b in bodies) total += b.size
        val samples = FloatArray(total)
        var out = 0
        var acc = 0
        for (data in bodies) {
            var i = 0
            val n = data.size
            while (i < n) {
                val b = data[i].toInt() and 0xff
                if (b == 0x80 && i + 3 < n) {
                    var raw = (data[i + 1].toInt() and 0xff) or
                        ((data[i + 2].toInt() and 0xff) shl 8) or
                        ((data[i + 3].toInt() and 0xff) shl 16)
                    if (raw and 0x800000 != 0) raw -= 0x1000000
                    acc = raw
                    samples[out++] = acc.toFloat()
                    i += 4
                } else {
                    acc += data[i].toInt() // already sign-extended by Kotlin's Byte
                    samples[out++] = acc.toFloat()
                    i += 1
                }
            }
        }
        return if (out == samples.size) samples else samples.copyOf(out)
    }
}
