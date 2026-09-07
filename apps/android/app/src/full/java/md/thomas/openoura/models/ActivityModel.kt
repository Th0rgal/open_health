package md.thomas.openoura.models

import android.content.Context
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonPrimitive
import md.thomas.openoura.data.EventStore
import md.thomas.openoura.data.Profile
import md.thomas.openoura.data.WorkoutSession
import md.thomas.openoura.diag.Diagnostics.log
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/**
 * Runner for Oura's automatic_activity_detection 3.1.11 model. The official app evaluates
 * each LOCAL DAY separately and feeds the real decoded step-motion channel; both details
 * materially affect the predicted sport, so both are reproduced here.
 *
 * Port of apps/ios/OuraApp/ActivityModel.swift.
 */
object ActivityModel {

    private const val AAD_MODEL = "automatic_activity_detection_3_1_11"
    private const val STEP_MODEL = "steps_motion_decoder_2_0_0"

    private val BEHAVIOR = mapOf(
        -1 to "nothing", 0 to "—", 1 to "badminton", 2 to "boxing", 3 to "cross-country skiing",
        4 to "cross training", 5 to "cycling", 6 to "dance", 7 to "elliptical", 8 to "strength",
        9 to "hockey", 10 to "pilates", 11 to "rowing", 12 to "running", 13 to "swimming",
        14 to "walking", 15 to "yoga", 16 to "golf", 17 to "tennis", 18 to "climbing",
        19 to "downhill skiing", 20 to "snowboarding", 21 to "hiking", 22 to "horseback riding",
        23 to "volleyball", 24 to "basketball", 25 to "football", 26 to "soccer", 27 to "baseball",
        28 to "core", 29 to "cricket", 30 to "HIIT", 31 to "diving", 32 to "fitness class",
        39 to "martial arts", 41 to "mountain biking", 42 to "nordic walking", 49 to "stretching",
        50 to "surfing", 51 to "water fitness", 53 to "padel", 65535 to "other", 65536 to "nap",
        65537 to "sleep", 65538 to "pause", 70937 to "meditation", 71201 to "eating",
        71227 to "relax", 71239 to "transport",
    )

    private class TimedRow(val unixMinute: Double, val values: FloatArray)

    private class Matrix(val flat: FloatArray, val count: Int)

    /**
     * Everything the AAD model receives for one local day — also the exact material the
     * incremental cache fingerprints, so cache identity and model input can never
     * disagree. [rawStep] is the undecoded 27-column gait packets; the decoder runs only
     * on a cache miss so hiking days do not decode twice.
     */
    private class DayInputs(
        val dayStartEpochSec: Long,
        val context: FloatArray,
        val met: Matrix,
        val rawStep: List<TimedRow>,
        val motion: Matrix,
        val temp: Matrix,
        val hr: Matrix,
    )

    class Outcome(val sessions: List<WorkoutSession>, val error: String?)

    fun run(
        context: Context,
        profile: Profile?,
        events: List<EventStore.Ev>,
        clock: EventStore.RingClock,
        progress: (String) -> Unit = {},
    ): Outcome {
        val aadPath = ModelAssets.path(context, AAD_MODEL)
            ?: return Outcome(emptyList(), "activity model file missing from the app assets")
        if (events.isEmpty()) return Outcome(emptyList(), null)

        val nan = Float.NaN
        fun num(e: EventStore.Ev, key: String): Float = e.num(key)?.toFloat() ?: 0f

        val met = ArrayList<TimedRow>()
        val motion = ArrayList<TimedRow>()
        val temperature = ArrayList<TimedRow>()
        val heartRate = ArrayList<TimedRow>()

        for (e in events) {
            // These are minute buckets; remove the few-second epoch-anchor jitter.
            val unixMinute = (clock.unixSeconds(e.ds, e.cu) / 60).roundToLong().toDouble()
            when (e.tag) {
                0x50 -> {
                    val values = e.json?.get("met") as? JsonArray ?: continue
                    values.forEachIndexed { index, v ->
                        val f = v.jsonPrimitive.doubleOrNull?.toFloat() ?: return@forEachIndexed
                        met.add(TimedRow(unixMinute + index, floatArrayOf(f)))
                    }
                }
                0x47 -> motion.add(
                    TimedRow(
                        unixMinute,
                        floatArrayOf(
                            num(e, "orientation"), num(e, "motion_seconds"),
                            num(e, "avg_x"), num(e, "avg_y"), num(e, "avg_z"),
                            nan, num(e, "low_intensity"), num(e, "high_intensity"),
                        )
                    )
                )
                0x46 -> {
                    val first = (e.json?.get("temps_c") as? JsonArray)
                        ?.firstOrNull()?.jsonPrimitive?.doubleOrNull ?: continue
                    temperature.add(TimedRow(unixMinute, floatArrayOf(first.toFloat())))
                }
                0x80 -> {
                    val values = e.json?.get("hr_bpm") as? JsonArray ?: continue
                    if (values.isEmpty()) continue
                    val avg = values.sumOf { it.jsonPrimitive.doubleOrNull ?: 0.0 } / values.size
                    heartRate.add(TimedRow(unixMinute, floatArrayOf(avg.toFloat())))
                }
            }
        }
        if (met.isEmpty()) return Outcome(emptyList(), null)

        val stepPackets = collectStepPackets(events, clock)
        val zone = ZoneId.systemDefault()
        // Newest first: today's card is the one the user is waiting on, and a mid-run kill
        // loses the least-relevant (oldest) days.
        val dayStarts = met
            .map {
                Instant.ofEpochSecond((it.unixMinute * 60).toLong())
                    .atZone(zone).toLocalDate()
            }
            .distinct()
            .sortedDescending()

        val sex = if (profile?.sex?.uppercase() == "M") 1f else 0f
        val user = FloatArray(14) { nan }
        user[0] = (profile?.age ?: 30.0).toFloat()
        user[1] = sex
        user[2] = (profile?.heightM ?: 1.78).toFloat()
        user[3] = (profile?.weightKg ?: 75.0).toFloat()

        fun dayInputs(day: LocalDate): DayInputs? {
            val dayStart = day.atStartOfDay(zone).toEpochSecond()
            val lo = dayStart / 60.0
            val hi = day.plusDays(1).atStartOfDay(zone).toEpochSecond() / 60.0

            fun matrix(rows: List<TimedRow>, columns: Int, required: Boolean = true): Matrix {
                val selected = rows.filter { it.unixMinute >= lo && it.unixMinute < hi }
                    .sortedBy { it.unixMinute }
                if (selected.isEmpty() && required) {
                    val flat = FloatArray(columns) { if (it == 0) 0f else nan }
                    return Matrix(flat, 1)
                }
                val flat = FloatArray(selected.size * columns)
                selected.forEachIndexed { i, row ->
                    flat[i * columns] = (row.unixMinute - lo).toFloat()
                    row.values.copyInto(flat, i * columns + 1)
                }
                return Matrix(flat, selected.size)
            }

            val metDay = matrix(met, 2)
            if (metDay.count == 0) return null
            val rawStep = stepPackets.filter { it.unixMinute >= lo && it.unixMinute < hi }
                .sortedBy { it.unixMinute }
            val ctx = floatArrayOf(
                day.year.toFloat(), day.monthValue.toFloat(), day.dayOfMonth.toFloat(),
                // Monday = 0, matching the Swift `(weekday + 5) % 7`
                ((day.dayOfWeek.value + 6) % 7).toFloat(),
            )
            return DayInputs(
                dayStartEpochSec = dayStart,
                context = ctx,
                met = metDay,
                rawStep = rawStep,
                motion = matrix(motion, 9),
                temp = matrix(temperature, 2),
                hr = matrix(heartRate, 2),
            )
        }

        val globalKey = ModelCacheStore.globalKey(context, profile)
        val cache = ModelCacheStore.load(
            context, ModelCacheStore.ACTIVITY_FILE, globalKey, ActivityDayEntry.serializer()
        )
        val dayKeyFmt = DateTimeFormatter.ofPattern("yyyy-MM-dd")

        val sessions = ArrayList<WorkoutSession>()
        val dirty = ArrayList<Triple<String, DayInputs, String>>()
        val currentKeys = HashSet<String>()

        for (day in dayStarts) {
            val inputs = dayInputs(day) ?: continue
            val key = day.format(dayKeyFmt)
            val fp = fingerprint(inputs)
            currentKeys.add(key)
            val entry = cache[key]
            if (entry != null && entry.fp == fp) sessions.addAll(entry.sessions)
            else dirty.add(Triple(key, inputs, fp))
        }

        log("models", "activity: ${dirty.size}/${currentKeys.size} days to recompute")
        dirty.forEachIndexed { index, (key, inputs, fp) ->
            progress("detecting activity · day ${index + 1}/${dirty.size}")
            val daySessions = runDay(context, inputs, user, aadPath, zone)
            sessions.addAll(daySessions)
            cache[key] = ActivityDayEntry(fp, daySessions)
            // Save after every completed day: a mid-run kill resumes here instead of
            // restarting the whole history.
            ModelCacheStore.save(
                context, ModelCacheStore.ACTIVITY_FILE, globalKey, cache,
                ActivityDayEntry.serializer(),
            )
        }

        // Drop days the current data no longer produces (e.g. re-dated by a clock
        // re-anchor) so the file tracks the DB instead of growing stale keys.
        val pruned = cache.filterKeys { it in currentKeys }
        if (pruned.size != cache.size) {
            ModelCacheStore.save(
                context, ModelCacheStore.ACTIVITY_FILE, globalKey, pruned,
                ActivityDayEntry.serializer(),
            )
        }
        return Outcome(sessions.sortedBy { it.start }, null)
    }

    /**
     * A day's fingerprint covers its exact model inputs; profile and timezone live in the
     * global key. A hit is therefore the result the model would have produced.
     */
    private fun fingerprint(inputs: DayInputs): String {
        val h = FNV64()
        h.combine(inputs.dayStartEpochSec.toDouble())
        h.combine(inputs.context)
        h.combine(inputs.met.flat); h.combine(inputs.met.count)
        h.combine(inputs.rawStep.size)
        for (row in inputs.rawStep) { h.combine(row.unixMinute); h.combine(row.values) }
        h.combine(inputs.motion.flat); h.combine(inputs.motion.count)
        h.combine(inputs.temp.flat); h.combine(inputs.temp.count)
        h.combine(inputs.hr.flat); h.combine(inputs.hr.count)
        return h.hex
    }

    /** One AAD inference over one local day's inputs. */
    private fun runDay(
        context: Context,
        inputs: DayInputs,
        user: FloatArray,
        aadPath: String,
        zone: ZoneId,
    ): List<WorkoutSession> {
        val nan = Float.NaN
        val decoded = decodeStepPackets(context, inputs.rawStep)
        val lo = inputs.dayStartEpochSec / 60.0
        val firstMet = inputs.met.flat[0]
        val lastMet = inputs.met.flat[(inputs.met.count - 1) * 2]

        // Boundary rows keep the AAD valid-time window equal to the complete MET day.
        // unixMinute is absolute; column 0 of the tensor is minutes since local midnight.
        val stepRows = ArrayList<TimedRow>(decoded.size + 2)
        stepRows.add(TimedRow(lo + firstMet, FloatArray(11) { nan }))
        stepRows.addAll(decoded)
        stepRows.add(TimedRow(lo + lastMet, FloatArray(11) { nan }))
        val stepFlat = FloatArray(stepRows.size * 12)
        stepRows.forEachIndexed { i, row ->
            stepFlat[i * 12] = (row.unixMinute - lo).toFloat()
            row.values.copyInto(stepFlat, i * 12 + 1)
        }

        val output = TorchBridge.activity(
            aadPath, inputs.context, user,
            inputs.met.flat, inputs.met.count,
            stepFlat, stepRows.size,
            inputs.motion.flat, inputs.motion.count,
            inputs.temp.flat, inputs.temp.count,
            inputs.hr.flat, inputs.hr.count,
            0.5f, 10.0f,
        ) ?: return emptyList()
        if (output.isEmpty()) return emptyList()

        val stamp = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm").withZone(zone)
        val time = DateTimeFormatter.ofPattern("HH:mm").withZone(zone)
        val rows = output.size / 9
        return (0 until rows).map { row ->
            val v = output.copyOfRange(row * 9, row * 9 + 9)
            val start = Instant.ofEpochSecond(inputs.dayStartEpochSec + (v[0] * 60).toLong())
            val end = Instant.ofEpochSecond(inputs.dayStartEpochSec + (v[1] * 60).toLong())
            WorkoutSession(
                start = stamp.format(start),
                end = time.format(end),
                durationMin = (v[1] - v[0]).roundToInt(),
                label = BEHAVIOR[v[3].toInt()] ?: "activity",
                isWorkout = v[2].toDouble(),
            )
        }
    }

    private fun collectStepPackets(
        events: List<EventStore.Ev>,
        clock: EventStore.RingClock,
    ): List<TimedRow> {
        val secondPackets = HashMap<Long, ByteArray>()
        for (e in events) {
            if (e.tag != 0x7F) continue
            val body = e.body ?: continue
            if (body.size != 14) continue
            secondPackets[(clock.unixSeconds(e.ds, e.cu) * 10).roundToLong()] = body
        }
        val rows = ArrayList<TimedRow>()
        for (e in events) {
            if (e.tag != 0x7E) continue
            val first = e.body ?: continue
            if (first.size != 14) continue
            val wallDecisecond = (clock.unixSeconds(e.ds, e.cu) * 10).roundToLong()
            val second = secondPackets[wallDecisecond + 1] ?: continue
            val values = unpack(first, second)
            rows.add(TimedRow(wallDecisecond / 10.0 / 60.0, values))
        }
        return rows
    }

    /**
     * Decode one day's 27-column gait packets. Hiking days can be thousands of pairs;
     * feeding the whole history as one tensor was what jetsam-killed the iOS app, so the
     * work is chunked with an overlap and de-duplicated by timestamp.
     */
    private fun decodeStepPackets(context: Context, packets: List<TimedRow>): List<TimedRow> {
        if (packets.isEmpty()) return emptyList()
        val modelPath = ModelAssets.path(context, STEP_MODEL) ?: return emptyList()
        val chunk = 4096
        val overlap = 24
        if (packets.size <= chunk) return runStepDecoder(packets, modelPath)

        val out = ArrayList<TimedRow>()
        val seen = HashSet<Long>()
        var i = 0
        while (i < packets.size) {
            val end = min(packets.size, i + chunk)
            for (row in runStepDecoder(packets.subList(i, end), modelPath)) {
                val key = (row.unixMinute * 60_000).roundToLong()
                if (seen.add(key)) out.add(row)
            }
            if (end == packets.size) break
            i = end - overlap
        }
        return out
    }

    private fun runStepDecoder(packets: List<TimedRow>, modelPath: String): List<TimedRow> {
        val timestamps = LongArray(packets.size) { (packets[it].unixMinute * 60_000).roundToLong() }
        val raw = FloatArray(packets.size * 27)
        packets.forEachIndexed { i, p -> p.values.copyInto(raw, i * 27) }
        val capacity = packets.size * 3
        val outputTimestamps = LongArray(capacity)

        val features = TorchBridge.stepMotion(
            modelPath, timestamps, raw, packets.size, outputTimestamps
        ) ?: return emptyList()
        val rows = features.size / 11
        if (rows == 0) return emptyList()

        // The decoder's output columns are not in the order AAD wants them.
        val order = intArrayOf(6, 7, 9, 10, 8, 5, 4, 0, 3, 1, 2)
        return (0 until rows).map { row ->
            val decoded = features.copyOfRange(row * 11, row * 11 + 11)
            TimedRow(
                outputTimestamps[row] / 60_000.0,
                FloatArray(11) { decoded[order[it]] },
            )
        }
    }

    /** Native Ring 5 real-step packet layout, recovered from libringeventparser.so. */
    internal fun unpack(p1: ByteArray, p2: ByteArray): FloatArray {
        fun b(a: ByteArray, i: Int) = a[i].toInt() and 0xff
        val c = b(p2, 13)
        val values = intArrayOf(
            b(p2, 10) shl 2 or (c and 3), b(p2, 11), b(p2, 12),
            b(p1, 0) shl 1 or (b(p1, 3) shr 7), b(p1, 1) shl 1 or (c shr 7 and 1),
            b(p1, 2) shl 1 or (c shr 6 and 1), b(p1, 3) and 127,
            b(p1, 4), b(p1, 5), b(p1, 6), b(p1, 7),
            b(p1, 8) shl 1 or (b(p1, 11) shr 7), b(p1, 9) shl 1 or (c shr 5 and 1),
            b(p1, 10) shl 1 or (c shr 4 and 1), b(p1, 11) and 127,
            b(p1, 12), b(p1, 13), b(p2, 0), b(p2, 1),
            b(p2, 2) shl 1 or (b(p2, 5) shr 7), b(p2, 3) shl 1 or (c shr 3 and 1),
            b(p2, 4) shl 1 or (c shr 2 and 1), b(p2, 5) and 127,
            b(p2, 6), b(p2, 7), b(p2, 8), b(p2, 9),
        )
        return FloatArray(27) { values[it].toFloat() }
    }
}
