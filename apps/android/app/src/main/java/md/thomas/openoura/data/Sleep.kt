package md.thomas.openoura.data

import java.time.LocalDate
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

// ── science: hypnogram-derived metrics (mirror of oura-summary sleep_metrics) ──
//
// The clinical sleep metrics and sleep debt are computed in THREE places and must stay
// identical: Rust (`oura-summary` sleep_metrics / smooth_stages / count_bouts /
// count_periods / sleep_debt_summary / sleep_need_s) for the web, Swift
// (apps/ios/OuraApp/Reports.swift `Sleep.*` / `Summary.stagedSleepDebt`) for iOS, and
// here for Android. Android — like iOS — runs build_summary with NoModelRunner, so the
// FFI leaves `stages_full`/`metrics`/`autonomic` empty and we recompute from the
// on-device SleepNet hypnogram. If you change a smoothing window or a metric
// definition, change all three. See docs/clients.md.

/** Swift's `Double.rounded()` — round half away from zero, not Kotlin's default. */
internal fun rnd(x: Double): Double = if (x < 0) -floor(-x + 0.5) else floor(x + 0.5)

/** One decimal place, matching Reports.swift's `r1`. */
internal fun r1(x: Double): Double = rnd(x * 10) / 10

data class SleepMetrics(
    val asleepMin: Double,
    val solMin: Double,
    val remLatencyMin: Double?,
    val wasoMin: Double,
    val awakenings: Int,
    val cycles: Int,
    val fragIndex: Double,
    val deepFirstHalfPct: Double?,
    val remFirstHalfPct: Double?,
)

/**
 * Mean HR/HRV per sleep stage — deep-sleep HRV is the recovery-relevant number. Mirror
 * of oura-summary `autonomic_by_stage` (which the FFI leaves null under NoModelRunner).
 * Like iOS, we align the even-spread `series` to stages by index fraction rather than
 * the server's per-sample timestamps, so values can differ by a hair; see docs/clients.md.
 */
data class StageAutonomic(
    val hrvDeep: Double? = null,
    val hrvLight: Double? = null,
    val hrvRem: Double? = null,
    val hrDeep: Double? = null,
    val hrLight: Double? = null,
    val hrRem: Double? = null,
) {
    val any: Boolean
        get() = listOf(hrvDeep, hrvLight, hrvRem, hrDeep, hrLight, hrRem).any { it != null }
}

object Sleep {

    /**
     * Mean of each stage's samples, mapping series index → stage by fraction of the night.
     * A single overnight HRV slope is intentionally not derived — nocturnal HRV is
     * stage-driven (deep ↑, REM ↓), so a slope tracks stage order, not recovery.
     */
    fun autonomic(hr: List<Double>, hrv: List<Double>, stages: List<Int>): StageAutonomic {
        fun means(series: List<Double>): Map<Int, Double> {
            if (series.size <= 1 || stages.isEmpty()) return emptyMap()
            val sum = HashMap<Int, Double>()
            val cnt = HashMap<Int, Int>()
            series.forEachIndexed { i, v ->
                if (v > 0) {
                    val f = i.toDouble() / (series.size - 1)
                    val s = stages[min((f * stages.size).toInt(), stages.size - 1)]
                    sum[s] = (sum[s] ?: 0.0) + v
                    cnt[s] = (cnt[s] ?: 0) + 1
                }
            }
            return cnt.mapValues { (k, n) -> rnd(sum.getValue(k) / n) }
        }
        val h = means(hr)
        val v = means(hrv)
        return StageAutonomic(
            hrvDeep = v[1], hrvLight = v[2], hrvRem = v[3],
            hrDeep = h[1], hrLight = h[2], hrRem = h[3],
        )
    }

    /**
     * Mode filter over a centered odd window — removes single-epoch flicker so cycle /
     * awakening counts reflect real architecture, not 30 s noise. Ties resolve to the
     * lowest stage code, matching Swift's `max(by:)` and Rust's `smooth_stages`.
     */
    fun smooth(v: List<Int>, win: Int): List<Int> {
        if (v.size < win || win < 3) return v
        val half = win / 2
        return v.indices.map { i ->
            val a = max(0, i - half)
            val b = min(v.size, i + half + 1)
            val counts = IntArray(5)
            for (j in a until b) {
                val s = v[j]
                if (s in 1..4) counts[s]++
            }
            (1..4).maxByOrNull { counts[it] } ?: v[i]
        }
    }

    /** Runs of [code] at least [minLen] epochs long. Mirrors Rust `count_bouts`. */
    internal fun bouts(seq: List<Int>, code: Int, minLen: Int): Int {
        var count = 0
        var run = 0
        for (c in seq) {
            if (c == code) {
                run++
            } else {
                if (run >= minLen) count++
                run = 0
            }
        }
        if (run >= minLen) count++
        return count
    }

    /**
     * Runs of [code] merged across gaps shorter than [mergeGap], then kept when at least
     * [minLen] long. Mirrors Rust `count_periods`.
     */
    internal fun periods(seq: List<Int>, code: Int, mergeGap: Int, minLen: Int): Int {
        val runs = ArrayList<IntArray>()
        var i = 0
        while (i < seq.size) {
            if (seq[i] == code) {
                val s = i
                while (i < seq.size && seq[i] == code) i++
                runs.add(intArrayOf(s, i))
            } else {
                i++
            }
        }
        if (runs.isEmpty()) return 0
        val merged = ArrayList<IntArray>()
        merged.add(runs[0])
        for (r in runs.drop(1)) {
            val last = merged.last()
            if (r[0] - last[1] < mergeGap) last[1] = r[1] else merged.add(r)
        }
        return merged.count { it[1] - it[0] >= minLen }
    }

    fun metrics(stages: List<Int>, inBedS: Double): SleepMetrics? {
        val n = stages.size
        if (n == 0) return null
        val epochMin = inBedS / 60.0 / n
        if (epochMin <= 0) return null
        val isSleep = { c: Int -> c in 1..3 }

        val onset = stages.indexOfFirst(isSleep)
        val finalSleep = stages.indexOfLast(isSleep)
        if (onset < 0 || finalSleep < 0) return null

        val span = stages.subList(onset, finalSleep + 1)
        val asleepEpochs = stages.count(isSleep)
        val asleepMin = asleepEpochs * epochMin

        val wasoEpochs = span.count { it == 4 }
        val minWake = max(1, ceil(1.0 / epochMin).toInt())
        val awakenings = bouts(span, 4, minWake)

        val remOffset = stages.subList(onset, n).indexOf(3)
        val remLatency = if (remOffset >= 0) remOffset * epochMin else null

        val mergeGap = max(1, rnd(15.0 / epochMin).toInt())
        val minRem = max(1, ceil(3.0 / epochMin).toInt())
        val cycles = periods(span, 3, mergeGap, minRem)

        val transitions = (0 until span.size - 1).count { span[it] != span[it + 1] }
        val fragIndex = if (asleepMin > 0) transitions / (asleepMin / 60.0) else 0.0

        val mid = onset + (finalSleep - onset) / 2
        fun halfPct(code: Int): Double? {
            val total = stages.count { it == code }
            if (total == 0) return null
            val first = stages.subList(onset, mid + 1).count { it == code }
            return rnd(first.toDouble() / total * 100)
        }

        return SleepMetrics(
            asleepMin = r1(asleepMin),
            solMin = r1(onset * epochMin),
            remLatencyMin = remLatency?.let(::r1),
            wasoMin = r1(wasoEpochs * epochMin),
            awakenings = awakenings,
            cycles = cycles,
            fragIndex = r1(fragIndex),
            deepFirstHalfPct = halfPct(1),
            remFirstHalfPct = halfPct(3),
        )
    }

    /** Asleep seconds for a night from its (smoothed) stages. */
    fun asleepS(stages: List<Int>, inBedS: Double): Int {
        val n = stages.size
        if (n == 0) return 0
        val epochS = inBedS / n
        return (stages.count { it in 1..3 } * epochS).toInt()
    }
}

/**
 * Android, like iOS, stages sleep on-device after the shared JSON is built. Rebuild the
 * same 14-day result after staging, grouping main sleep + naps by wake date. The web
 * receives this exact shape directly from `oura-summary`.
 */
fun Summary.stagedSleepDebt(): SleepDebtSummary? {
    val defaultNeedS = 8.0 * 3600.0
    val byDay = HashMap<String, Double>()
    for (n in nights) {
        val st = n.stages ?: continue
        if (st.size <= 1) continue
        val day = wakeYmd(n) ?: continue
        val actual = Sleep.asleepS(Sleep.smooth(st, 5), (n.inBedH ?: 0.0) * 3600).toDouble()
        if (actual > 0) byDay[day] = (byDay[day] ?: 0.0) + actual
    }
    val anchor = byDay.keys.maxOrNull() ?: return null
    val anchorDate = try {
        LocalDate.parse(anchor)
    } catch (_: Exception) {
        return null
    }

    fun key(base: LocalDate, offset: Int): String = base.plusDays(offset.toLong()).toString()

    // Personalized daily need — the mirror of oura-summary's `sleep_need_s` (typical
    // sleep over the last 90 days, IQR-filtered, clamped to 7–9 h, causal so a night
    // never sets its own need). Keep all three implementations in sync.
    fun needS(day: LocalDate): Double {
        val vals = (1..90).mapNotNull { byDay[key(day, -it)] }.filter { it > 0 }.sorted()
        if (vals.size < 14) return defaultNeedS
        fun quantile(p: Double): Double {
            val idx = p * (vals.size - 1)
            val lo = floor(idx).toInt()
            val hi = ceil(idx).toInt()
            return vals[lo] + (vals[hi] - vals[lo]) * (idx - lo)
        }
        val q1 = quantile(0.25)
        val q3 = quantile(0.75)
        val fence = 1.5 * (q3 - q1)
        val kept = vals.filter { it >= q1 - fence && it <= q3 + fence }
        val mean = kept.sum() / kept.size
        return rnd(min(max(mean, 7 * 3600.0), 9 * 3600.0) / 900) * 900
    }

    data class Score(val debt: Double, val recent: Double, val valid: Boolean, val count: Int)

    fun score(end: LocalDate): Score {
        val actual = (0 until 14).map { byDay[key(end, -it)] ?: 0.0 }
        val needs = (0 until 14).map { needS(end.minusDays(it.toLong())) }
        val count = actual.count { it > 0 }
        if (actual[0] <= 0) return Score(0.0, 0.0, false, count)
        val decay = 0.75 / 13.0
        var debt = 0.0
        for (i in actual.indices) {
            if (actual[i] > 0) debt += (1.0 - decay * i) * (needs[i] - actual[i])
        }
        debt = min(max(debt, 0.0), 36_000.0)
        debt = rnd(debt / 2700) * 2700
        return Score(debt, needs[0] - actual[0], count >= 5, count)
    }

    val days = (-13..0).map { offset ->
        val d = anchorDate.plusDays(offset.toLong())
        val k = d.toString()
        val total = byDay[k]
        val need = needS(d)
        val result = score(d)
        SleepDebtDay(
            date = k,
            totalSleepMin = total?.let { rnd(it / 60) },
            sleepNeedMin = rnd(need / 60),
            shortfallMin = total?.let { rnd((need - it) / 60) },
            cumulativeDebtMin = if (result.valid) rnd(result.debt / 60) else null,
            validDays = result.count,
        )
    }

    val current = score(anchorDate)
    val minutes = if (current.valid) rnd(current.debt / 60) else 0.0
    val state = when {
        minutes >= 540 -> "high"
        minutes >= 360 -> "moderate"
        minutes >= 180 -> "low"
        else -> "none"
    }
    return SleepDebtSummary(
        debtMin = minutes,
        recentShortfallMin = if (current.valid) rnd(current.recent / 60) else 0.0,
        valid = current.valid,
        needH = rnd(needS(anchorDate) / 36) / 100,
        validDays = current.count,
        windowDays = 14,
        state = state,
        days = days,
    )
}
