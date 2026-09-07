package md.thomas.openoura.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

/**
 * Sleep debt groups every sleep session by wake date (naps included), then evaluates 14
 * calendar days needing at least five valid ones. The nightly need is personalized from
 * the previous 90 days, IQR-filtered, clamped to 7–9 h, rounded to 15 min and causal —
 * a night never sets its own need. Mirrors Rust `sleep_debt_summary`/`sleep_need_s` and
 * Swift `Summary.stagedSleepDebt`/`needS(on:)`.
 */
class SleepDebtTest {

    /**
     * A night whose smoothed hypnogram yields [asleepH] of sleep, waking on [wakeDate].
     * Stages are all-deep so smoothing is a no-op and asleep == in-bed.
     */
    private fun night(wakeDate: String, asleepH: Double, epochs: Int = 960): NightRow {
        val onset = LocalDate.parse(wakeDate).minusDays(1).toString()
        return NightRow(
            ymd = onset,
            start = "23:00",
            end = "07:00", // end < start, so wakeYmd rolls to the next day
            inBedH = asleepH,
            stages = List(epochs) { 1 },
        )
    }

    @Test
    fun `no staged nights yields no debt summary`() {
        assertNull(Summary(nights = emptyList()).stagedSleepDebt())
        // a night without a usable hypnogram is ignored too
        assertNull(
            Summary(nights = listOf(NightRow(ymd = "2026-03-01", inBedH = 8.0, stages = listOf(1))))
                .stagedSleepDebt()
        )
    }

    @Test
    fun `sleeping the default need leaves no debt`() {
        val nights = (0 until 14).map { night(LocalDate.parse("2026-03-14").minusDays(it.toLong()).toString(), 8.0) }
        val d = Summary(nights = nights).stagedSleepDebt()!!
        assertTrue(d.valid)
        assertEquals(14, d.validDays)
        assertEquals(0.0, d.debtMin, 1e-9)
        assertEquals("none", d.state)
        assertEquals(14, d.days.size)
    }

    @Test
    fun `fewer than five valid days is not a valid window`() {
        val nights = (0 until 4).map { night(LocalDate.parse("2026-03-14").minusDays(it.toLong()).toString(), 8.0) }
        val d = Summary(nights = nights).stagedSleepDebt()!!
        assertTrue(!d.valid)
        assertEquals(4, d.validDays)
        assertEquals(0.0, d.debtMin, 1e-9)
    }

    @Test
    fun `short sleep accumulates debt and escalates the state`() {
        val nights = (0 until 14).map { night(LocalDate.parse("2026-03-14").minusDays(it.toLong()).toString(), 5.0) }
        val d = Summary(nights = nights).stagedSleepDebt()!!
        assertTrue(d.valid)
        // 3 h short every night against the 8 h default need, decayed and clamped
        assertTrue("expected substantial debt, got ${d.debtMin}", d.debtMin >= 540)
        assertEquals("high", d.state)
        // debt is quantized to 45-minute steps
        assertEquals(0.0, d.debtMin % 45, 1e-9)
    }

    @Test
    fun `debt is capped at ten hours`() {
        val nights = (0 until 14).map { night(LocalDate.parse("2026-03-14").minusDays(it.toLong()).toString(), 1.0) }
        val d = Summary(nights = nights).stagedSleepDebt()!!
        assertTrue(d.debtMin <= 600.0)
    }

    @Test
    fun `naps on the same morning add to that day's total`() {
        val day = "2026-03-14"
        val main = night(day, 6.0)
        val nap = NightRow(
            ymd = day, start = "13:00", end = "14:30", inBedH = 1.5, stages = List(180) { 1 },
        )
        val withNap = Summary(nights = listOf(main, nap)).stagedSleepDebt()!!
        val withoutNap = Summary(nights = listOf(main)).stagedSleepDebt()!!
        // the nap counts toward the day, so the shortfall shrinks
        val napDay = withNap.days.last()
        val plainDay = withoutNap.days.last()
        assertTrue(napDay.totalSleepMin!! > plainDay.totalSleepMin!!)
        assertTrue(napDay.shortfallMin!! < plainDay.shortfallMin!!)
    }

    @Test
    fun `need falls back to eight hours below fourteen days of history`() {
        val nights = (0 until 10).map { night(LocalDate.parse("2026-03-14").minusDays(it.toLong()).toString(), 6.5) }
        val d = Summary(nights = nights).stagedSleepDebt()!!
        assertEquals(8.0, d.needH, 1e-9)
        assertEquals(480.0, d.days.last().sleepNeedMin, 1e-9)
    }

    @Test
    fun `need is personalized from ninety days of history and clamped to seven to nine hours`() {
        // 100 nights of a consistent 7.5 h sleeper
        val anchor = LocalDate.parse("2026-06-01")
        val nights = (0 until 100).map { night(anchor.minusDays(it.toLong()).toString(), 7.5) }
        val d = Summary(nights = nights).stagedSleepDebt()!!
        assertEquals(7.5, d.needH, 0.05)

        // a chronic 5 h sleeper is clamped up to the 7 h floor, not indulged
        val short = (0 until 100).map { night(anchor.minusDays(it.toLong()).toString(), 5.0) }
        assertEquals(7.0, Summary(nights = short).stagedSleepDebt()!!.needH, 0.05)

        // a 10 h sleeper is clamped down to the 9 h ceiling
        val long = (0 until 100).map { night(anchor.minusDays(it.toLong()).toString(), 10.0) }
        assertEquals(9.0, Summary(nights = long).stagedSleepDebt()!!.needH, 0.05)
    }

    @Test
    fun `need is causal - the anchor night does not set its own need`() {
        val anchor = LocalDate.parse("2026-06-01")
        // 99 nights of 7.5 h, then one wildly long night on the anchor date
        val nights = (1 until 100).map { night(anchor.minusDays(it.toLong()).toString(), 7.5) } +
            night(anchor.toString(), 14.0)
        val d = Summary(nights = nights).stagedSleepDebt()!!
        // the 14 h outlier must not drag the need up
        assertEquals(7.5, d.needH, 0.05)
    }

    @Test
    fun `need is rounded to a quarter hour`() {
        val anchor = LocalDate.parse("2026-06-01")
        val nights = (0 until 100).map { night(anchor.minusDays(it.toLong()).toString(), 7.6) }
        val needMin = Summary(nights = nights).stagedSleepDebt()!!.days.last().sleepNeedMin
        assertEquals(0.0, needMin % 15, 1e-9)
    }

    @Test
    fun `the window is always fourteen days ending on the most recent night`() {
        val nights = (0 until 30).map { night(LocalDate.parse("2026-03-30").minusDays(it.toLong()).toString(), 8.0) }
        val d = Summary(nights = nights).stagedSleepDebt()!!
        assertEquals(14, d.windowDays)
        assertEquals(14, d.days.size)
        assertEquals("2026-03-30", d.days.last().date)
        assertEquals("2026-03-17", d.days.first().date)
    }
}
