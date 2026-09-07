package md.thomas.openoura.models

import android.content.Context
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonPrimitive
import md.thomas.openoura.data.EventStore
import md.thomas.openoura.data.IllnessBiomarker
import md.thomas.openoura.data.IllnessResult
import md.thomas.openoura.data.Profile
import java.util.TimeZone
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * On-device Symptom Radar: assemble the 30-day biometric matrix + long-term baselines the
 * illness-detection model expects and run illness_detection_0_5_1 through the LibTorch
 * lite bridge. A faithful port of tools/run_illness_model.py and of
 * apps/ios/OuraApp/IllnessModel.swift (see docs/algorithms/illness-detection.md for the
 * full I/O contract). The model bakes in all normalization / calibration / thresholds — we
 * feed raw physiological values.
 *
 * HR/HRV come from the ring's own hrv_event (5-min rmssd_ms + hr_bpm); breathing rate is
 * reconstructed from the IBI stream (respiratory sinus arrhythmia), matching the Python
 * runner's respiratory_rate.py.
 */
object IllnessModel {

    const val N_DAYS = 30
    private const val MODEL = "illness_detection_0_5_1"
    private val IBI_TAGS = setOf(0x44, 0x60, 0x71)
    private val TEMP_TAGS = setOf(0x46, 0x69, 0x75)
    private const val DAY = 86400.0

    private class Nightly(
        val breath: Double,
        val avgHr: Double,
        val lowHr: Double,
        val hrv: Double,
        val skinTemp: Double,
        val dur: Double,
    )

    class Outcome(val result: IllnessResult?, val error: String?)

    fun run(
        context: Context,
        profile: Profile?,
        events: List<EventStore.Ev>,
        clock: EventStore.RingClock,
    ): Outcome {
        val modelPath = ModelAssets.path(context, MODEL)
            ?: return Outcome(null, "illness model file missing from the app assets")
        if (events.isEmpty()) return Outcome(null, null)

        fun u(ds: Long, cu: Long) = clock.unixSeconds(ds, cu)
        val tz = TimeZone.getDefault().getOffset(System.currentTimeMillis()) / 1000.0

        // ── gather raw signals with absolute times ────────────────────────────
        val ibiT = ArrayList<Double>(); val ibiV = ArrayList<Double>()
        val hrvT = ArrayList<Double>(); val hrvR = ArrayList<Double>(); val hrvH = ArrayList<Double>()
        val tempT = ArrayList<Double>(); val tempV = ArrayList<Double>()
        val windows = ArrayList<Pair<Double, Double>>()
        val sed = HashMap<Int, Double>()
        val rest = HashMap<Int, Double>()

        for (e in events) {
            val json = e.json
            when {
                e.tag in IBI_TAGS -> {
                    val arr = json?.get("ibi_ms") as? JsonArray ?: continue
                    var acc = 0.0
                    val base = u(e.ds, e.cu)
                    for (x in arr) {
                        val v = x.jsonPrimitive.doubleOrNull ?: 0.0
                        if (v > 0) {
                            acc += v / 1000.0
                            ibiT.add(base + acc)
                            ibiV.add(v)
                        }
                    }
                }
                e.tag == 0x5D -> { // hrv_event: 5-min avg RMSSD + HR
                    val rm = json?.get("rmssd_ms") as? JsonArray ?: continue
                    val hb = json["hr_bpm"] as? JsonArray
                    val step = (e.num("interval_min") ?: 5.0) * 60.0
                    val base = u(e.ds, e.cu)
                    rm.forEachIndexed { i, x ->
                        val r = x.jsonPrimitive.doubleOrNull ?: 0.0
                        if (r > 0) {
                            hrvT.add(base + i * step)
                            hrvR.add(r)
                            hrvH.add(
                                hb?.getOrNull(i)?.jsonPrimitive?.doubleOrNull ?: Double.NaN
                            )
                        }
                    }
                }
                e.tag in TEMP_TAGS -> {
                    val arr = json?.get("temps_c") as? JsonArray ?: continue
                    val base = u(e.ds, e.cu)
                    for (x in arr) {
                        val v = x.jsonPrimitive.doubleOrNull ?: 0.0
                        if (v > 20) { tempT.add(base); tempV.add(v) }
                    }
                }
                e.tag == 0x76 -> { // bedtime_period
                    val s = e.long("bedtime_start_ds")
                    val en = e.long("bedtime_end_ds")
                    if (s != null && en != null && en > s) {
                        windows.add(u(s, e.cu) to u(en, e.cu))
                    }
                }
                else -> {
                    val met = json?.get("met") as? JsonArray ?: continue
                    val base = u(e.ds, e.cu)
                    met.forEachIndexed { i, x ->
                        val mv = x.jsonPrimitive.doubleOrNull ?: 1.0
                        val d = ((base + i * 60.0 + tz) / DAY).toInt()
                        if (mv < 1.05) rest[d] = (rest[d] ?: 0.0) + 60
                        else if (mv < 2.0) sed[d] = (sed[d] ?: 0.0) + 60
                    }
                }
            }
        }

        // ── per wake-day nightly biometrics (longest sleep wins) ──────────────
        val perDay = HashMap<Int, Nightly>()
        for ((start, end) in windows) {
            val dur = end - start
            if (dur < 3600) continue
            val wakeDay = ((end + tz) / DAY).toInt()
            val hIdx = indicesInRange(hrvT, start, end)
            if (hIdx.size < 3) continue
            val rmssd = median(hIdx.map { hrvR[it] })
            val hrs = hIdx.map { hrvH[it] }.filter { it.isFinite() }
            if (hrs.size < 3) continue
            val iIdx = indicesInRange(ibiT, start, end)
            val breath = if (iIdx.size > 200) {
                respiratoryRate(iIdx.map { ibiT[it] }, iIdx.map { ibiV[it] })
            } else {
                Double.NaN
            }
            val tIdx = indicesInRange(tempT, start, end)
            val skin = if (tIdx.isEmpty()) Double.NaN else median(tIdx.map { tempV[it] })
            val n = Nightly(breath, median(hrs), hrs.min(), rmssd, skin, dur)
            val existing = perDay[wakeDay]
            if (existing == null || dur > existing.dur) perDay[wakeDay] = n
        }
        val anchor = perDay.keys.maxOrNull() ?: return Outcome(null, null)

        // ── 30-day columns (index 0 = today) ──────────────────────────────────
        fun col(pick: (Nightly) -> Double) = FloatArray(N_DAYS) { i ->
            perDay[anchor - i]?.let { pick(it).toFloat() } ?: Float.NaN
        }
        val breath = col { it.breath }
        val avgHr = col { it.avgHr }
        val lowHr = col { it.lowHr }
        val hrv = col { it.hrv }
        val skin = DoubleArray(N_DAYS) { i -> perDay[anchor - i]?.skinTemp ?: Double.NaN }
        val finiteSkin = skin.filter { it.isFinite() }
        val baseTemp = if (finiteSkin.isEmpty()) Double.NaN else median(finiteSkin)
        val tempDev = FloatArray(N_DAYS) { i ->
            if (skin[i].isFinite() && baseTemp.isFinite()) (skin[i] - baseTemp).toFloat()
            else Float.NaN
        }
        val sedC = FloatArray(N_DAYS) { i -> sed[anchor - i]?.toFloat() ?: Float.NaN }
        val restC = FloatArray(N_DAYS) { i -> rest[anchor - i]?.toFloat() ?: Float.NaN }

        // 301/302 guards (mirror the model's own input validator)
        if (!tempDev[0].isFinite()) {
            return Outcome(
                IllnessResult(
                    available = false, status = "MISSING_LAST_NIGHT_SLEEP", trafficLight = "",
                    score = 0.0, decision = 0, date = "", daysWithData = 0, biomarkers = emptyList(),
                ),
                null,
            )
        }
        if (tempDev.take(14).count { !it.isFinite() } > 7) {
            return Outcome(
                IllnessResult(
                    available = false, status = "MISSING_SLEEP_DATA", trafficLight = "",
                    score = 0.0, decision = 0, date = "", daysWithData = 0, biomarkers = emptyList(),
                ),
                null,
            )
        }

        // ── long-term baselines + demographics ────────────────────────────────
        val rhrF = lowHr.map { it.toDouble() }.filter { it.isFinite() }
        val hrvF = hrv.map { it.toDouble() }.filter { it.isFinite() }
        val sedF = sedC.map { it.toDouble() }.filter { it.isFinite() }
        val h = profile?.heightM ?: 1.78
        val w = profile?.weightKg ?: 75.0
        val bmi = w / (h * h)
        val sex = when (profile?.sex?.uppercase()) {
            "F" -> -1f
            "O" -> 0f
            else -> 1f
        }
        val (y, mo, dd) = civil(anchor)
        // Monday = 0, matching the Python runner and the Swift port.
        val dow = ((java.time.LocalDate.of(y, mo, dd).dayOfWeek.value + 6) % 7).toFloat()

        val scalars = floatArrayOf(
            (profile?.age ?: 30.0).toFloat(), bmi.toFloat(), sex, dow,
            avg(rhrF, 55.0).toFloat(), std(rhrF, 3.0).toFloat(),
            avg(hrvF, 45.0).toFloat(), std(hrvF, 6.0).toFloat(),
            (if (baseTemp.isFinite()) baseTemp else 36.0).toFloat(), std(finiteSkin, 0.2).toFloat(),
            avg(sedF, 30000.0).toFloat(), std(sedF, 4000.0).toFloat(),
        )

        // 7×30 row-major, in the order the model's validator expects
        val series = FloatArray(7 * N_DAYS)
        listOf(breath, avgHr, lowHr, hrv, tempDev, sedC, restC).forEachIndexed { k, c ->
            c.copyInto(series, k * N_DAYS)
        }

        val out = TorchBridge.illness(modelPath, series, scalars)
            ?: return Outcome(null, "illness inference failed")

        val score = out[0].toDouble()
        val decision = out[1].roundToInt()
        val light = listOf("NO_SIGNS", "MINOR_SIGNS", "MAJOR_SIGNS")[decision.coerceIn(0, 2)]
        val labels = listOf("AverageBreath", "LowestHeartRate", "AverageHrv", "TemperatureDeviation")
        val biomarkers = ArrayList<IllnessBiomarker>()
        labels.forEachIndexed { b, label ->
            val isOut = out[2 + b * 4]
            val value = out[2 + b * 4 + 1]
            val lo = out[2 + b * 4 + 2]
            val hi = out[2 + b * 4 + 3]
            if (listOf(isOut, value, lo, hi).any { !it.isFinite() }) return@forEachIndexed
            val flagged = isOut.roundToInt() == 1
            biomarkers.add(
                IllnessBiomarker(
                    type = label,
                    value = value.toDouble(),
                    lower = lo.toDouble(),
                    upper = hi.toDouble(),
                    indicatesSymptoms = flagged,
                    reason = if (!flagged) null else if (value > hi) "ELEVATED" else "DECREASED",
                )
            )
        }

        return Outcome(
            IllnessResult(
                available = true,
                status = light,
                trafficLight = light,
                score = score,
                decision = decision,
                date = "%04d-%02d-%02d".format(y, mo, dd),
                daysWithData = tempDev.count { it.isFinite() },
                biomarkers = biomarkers,
            ),
            null,
        )
    }

    // ── respiratory rate (RSA) — port of tools/respiratory_rate.py ────────────
    private const val FS = 4.0
    private const val RESP_LO = 0.15
    private const val RESP_HI = 0.40
    private const val WIN_S = 60.0
    private const val STEP_S = 30.0

    fun respiratoryRate(ts: List<Double>, ibi: List<Double>): Double {
        // ectopic filter: physiological range, then within 30% of the median
        val t = ArrayList<Double>()
        val v = ArrayList<Double>()
        ibi.forEachIndexed { i, x ->
            if (x in 300.0..2000.0) { t.add(ts[i]); v.add(x) }
        }
        if (v.size < 30) return Double.NaN
        val med = median(v)
        val t2 = ArrayList<Double>()
        val v2 = ArrayList<Double>()
        v.forEachIndexed { i, x ->
            if (abs(x - med) <= 0.30 * med) { t2.add(t[i]); v2.add(x) }
        }
        if (v2.size < 30 || (t2.last() - t2.first()) < WIN_S) return Double.NaN

        val span = t2.last() - t2.first()
        // A mis-dated bedtime (ring reboot on a long hike) can span days and allocate
        // tens of millions of samples. Cap at an implausible night.
        if (span > 18 * 3600) return Double.NaN
        val n = (span * FS).toInt()
        if (n < (WIN_S * FS).toInt()) return Double.NaN

        // 4 Hz resample (linear interpolation on the IBI tachogram)
        var x = DoubleArray(n)
        var j = 0
        for (k in 0 until n) {
            val tk = t2.first() + k / FS
            while (j < t2.size - 2 && t2[j + 1] < tk) j++
            val t0 = t2[j]
            val t1 = t2[j + 1]
            val f = if (t1 > t0) (tk - t0) / (t1 - t0) else 0.0
            x[k] = v2[j] + (v2[j + 1] - v2[j]) * f
        }
        x = bandpass(x)

        // per-window dominant respiratory frequency (direct DFT scan over the band)
        val win = (WIN_S * FS).toInt()
        val hop = (STEP_S * FS).toInt()
        val rr = ArrayList<Double>()
        var i = 0
        while (i + win <= x.size) {
            dominantFreq(x.copyOfRange(i, i + win))?.let { rr.add(it * 60.0) }
            i += hop
        }
        return if (rr.size >= 3) median(rr) else Double.NaN
    }

    /** Windowed-sinc respiratory band-pass (scipy-free; matches the Python fallback). */
    private fun bandpass(x: DoubleArray): DoubleArray {
        val mean = x.average()
        val centered = DoubleArray(x.size) { x[it] - mean }
        val n = 129
        val kern = DoubleArray(n)
        for (i in 0 until n) {
            val t = i - (n - 1) / 2.0
            val lo = 2 * RESP_LO / FS * sinc(2 * RESP_LO / FS * t)
            val hi = 2 * RESP_HI / FS * sinc(2 * RESP_HI / FS * t)
            val hann = 0.5 - 0.5 * cos(2 * Math.PI * i / (n - 1))
            kern[i] = (hi - lo) * hann
        }
        val km = kern.average()
        for (i in 0 until n) kern[i] -= km

        // 'same' convolution
        val out = DoubleArray(centered.size)
        val half = n / 2
        for (i in centered.indices) {
            var acc = 0.0
            for (k in 0 until n) {
                val idx = i + k - half
                if (idx in centered.indices) acc += centered[idx] * kern[k]
            }
            out[i] = acc
        }
        return out
    }

    /** Dominant frequency in [RESP_LO, RESP_HI] via a direct DFT scan; null if no clear peak. */
    private fun dominantFreq(seg: DoubleArray): Double? {
        val m = seg.average()
        val s = DoubleArray(seg.size) {
            (seg[it] - m) * (0.5 - 0.5 * cos(2 * Math.PI * it / (seg.size - 1)))
        }
        val freqs = ArrayList<Double>()
        val powers = ArrayList<Double>()
        var f = RESP_LO
        while (f <= RESP_HI) {
            var re = 0.0
            var im = 0.0
            for (k in s.indices) {
                val a = 2 * Math.PI * f * k / FS
                re += s[k] * cos(a)
                im -= s[k] * sin(a)
            }
            freqs.add(f)
            powers.add(re * re + im * im)
            f += 0.005
        }
        val maxP = powers.maxOrNull() ?: return null
        val mi = powers.indexOf(maxP)
        if (maxP < 4.0 * median(powers)) return null // require a real peak
        return freqs[mi]
    }

    private fun sinc(x: Double): Double = if (x == 0.0) 1.0 else sin(Math.PI * x) / (Math.PI * x)

    // ── helpers ───────────────────────────────────────────────────────────────
    private fun indicesInRange(ts: List<Double>, lo: Double, hi: Double): List<Int> =
        ts.indices.filter { ts[it] in lo..hi }

    internal fun median(a: List<Double>): Double {
        if (a.isEmpty()) return Double.NaN
        val s = a.sorted()
        val n = s.size
        return if (n % 2 == 1) s[n / 2] else (s[n / 2 - 1] + s[n / 2]) / 2
    }

    private fun avg(a: List<Double>, d: Double): Double = if (a.isEmpty()) d else a.average()

    private fun std(a: List<Double>, d: Double): Double {
        if (a.size <= 1) return d
        val m = a.average()
        return sqrt(a.sumOf { (it - m) * (it - m) } / a.size)
    }

    /** Howard Hinnant civil_from_days — matches oura-summary / run_illness_model.py. */
    internal fun civil(days: Int): Triple<Int, Int, Int> {
        val z = days + 719468
        val era = (if (z >= 0) z else z - 146096) / 146097
        val doe = z - era * 146097
        val yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        val y = yoe + era * 400
        val doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        val mp = (5 * doy + 2) / 153
        val d = doy - (153 * mp + 2) / 5 + 1
        val m = if (mp < 10) mp + 3 else mp - 9
        return Triple(y + if (m <= 2) 1 else 0, m, d)
    }
}
