package md.thomas.openoura.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Clinical sleep metrics exist in three implementations (Rust `oura-summary`, Swift
 * `Reports.swift`, and Kotlin `Sleep.kt`). docs/clients.md requires them to agree, so
 * these pin the definitions rather than the current output.
 *
 * Stage codes: 1=deep 2=light 3=rem 4=wake.
 */
class SleepMetricsTest {

    /** 30-second epochs, the SleepNet output resolution. */
    private fun inBedSFor(epochs: Int) = epochs * 30.0

    private fun run(vararg pairs: Pair<Int, Int>): List<Int> =
        pairs.flatMap { (code, count) -> List(count) { code } }

    @Test
    fun `smooth removes a single-epoch flicker`() {
        val v = listOf(2, 2, 2, 4, 2, 2, 2)
        assertEquals(listOf(2, 2, 2, 2, 2, 2, 2), Sleep.smooth(v, 5))
    }

    @Test
    fun `smooth leaves a genuine run intact`() {
        val v = run(2 to 6, 4 to 6, 2 to 6)
        val out = Sleep.smooth(v, 5)
        // the 3-minute wake block survives a 5-epoch mode filter
        assertTrue(out.count { it == 4 } >= 4)
    }

    @Test
    fun `smooth is a no-op for windows below three or sequences shorter than the window`() {
        val v = listOf(1, 4, 1)
        assertEquals(v, Sleep.smooth(v, 1))
        assertEquals(listOf(1, 4), Sleep.smooth(listOf(1, 4), 5))
    }

    @Test
    fun `smooth ties resolve to the lowest stage code`() {
        // window of 4 around index 1: two 1s and two 2s -> tie, lowest code wins
        val out = Sleep.smooth(listOf(1, 1, 2, 2), 3)
        assertEquals(1, out[1])
    }

    @Test
    fun `bouts counts runs meeting the minimum length`() {
        val seq = listOf(4, 4, 2, 4, 2, 4, 4, 4)
        assertEquals(2, Sleep.bouts(seq, 4, 2)) // the 2-run and the 3-run; the single is dropped
        assertEquals(3, Sleep.bouts(seq, 4, 1))
        assertEquals(1, Sleep.bouts(seq, 4, 3))
    }

    @Test
    fun `periods merges runs separated by less than the gap`() {
        val seq = run(3 to 4, 2 to 2, 3 to 4, 2 to 20, 3 to 4)
        // gap of 2 < mergeGap 5, so the first two REM runs are one period; the third is
        // separated by 20 epochs and stays its own.
        assertEquals(2, Sleep.periods(seq, 3, 5, 3))
        // with a tiny merge gap they stay three separate periods
        assertEquals(3, Sleep.periods(seq, 3, 1, 3))
    }

    @Test
    fun `periods drops merged runs shorter than the minimum`() {
        assertEquals(0, Sleep.periods(run(3 to 2, 2 to 30, 3 to 2), 3, 1, 3))
    }

    @Test
    fun `metrics computes onset latency, WASO, awakenings and REM latency`() {
        // 10 epochs wake -> 20 deep -> 10 wake -> 40 light -> 20 rem -> 10 wake
        val stages = run(4 to 10, 1 to 20, 4 to 10, 2 to 40, 3 to 20, 4 to 10)
        val m = Sleep.metrics(stages, inBedSFor(stages.size))!!

        // epochMin is 0.5, so 10 wake epochs before the first sleep = 5 minutes
        assertEquals(5.0, m.solMin, 1e-9)
        // 80 sleep epochs * 0.5 min
        assertEquals(40.0, m.asleepMin, 1e-9)
        // only the wake INSIDE the sleep span counts (the trailing 10 do not)
        assertEquals(5.0, m.wasoMin, 1e-9)
        assertEquals(1, m.awakenings)
        // first REM epoch is 70 epochs after onset
        assertEquals(35.0, m.remLatencyMin!!, 1e-9)
        assertEquals(1, m.cycles)
    }

    @Test
    fun `metrics returns null without any sleep`() {
        assertNull(Sleep.metrics(List(20) { 4 }, inBedSFor(20)))
        assertNull(Sleep.metrics(emptyList(), 0.0))
    }

    @Test
    fun `metrics reports no REM latency when there is no REM`() {
        val stages = run(4 to 4, 1 to 20, 2 to 20)
        val m = Sleep.metrics(stages, inBedSFor(stages.size))!!
        assertNull(m.remLatencyMin)
        assertEquals(0, m.cycles)
    }

    @Test
    fun `deep is front-loaded and REM back-loaded in a realistic night`() {
        // deep concentrated in the first half, REM in the second — the normal pattern
        val stages = run(4 to 4, 1 to 40, 2 to 40, 2 to 40, 3 to 40)
        val m = Sleep.metrics(stages, inBedSFor(stages.size))!!
        assertEquals(100.0, m.deepFirstHalfPct!!, 1e-9)
        assertEquals(0.0, m.remFirstHalfPct!!, 1e-9)
    }

    @Test
    fun `fragmentation index counts stage transitions per asleep hour`() {
        // 120 epochs = 60 min asleep, alternating deep/light every 30 epochs -> 3 changes
        val stages = run(1 to 30, 2 to 30, 1 to 30, 2 to 30)
        val m = Sleep.metrics(stages, inBedSFor(stages.size))!!
        assertEquals(60.0, m.asleepMin, 1e-9)
        assertEquals(3.0, m.fragIndex, 1e-9)
    }

    @Test
    fun `asleepS counts only sleep stages`() {
        val stages = run(4 to 10, 1 to 10, 2 to 10, 3 to 10, 4 to 10)
        // 30 of 50 epochs are sleep, over a 25-minute in-bed window
        assertEquals(900, Sleep.asleepS(stages, inBedSFor(stages.size)))
    }

    @Test
    fun `autonomic means are grouped by stage via index fraction`() {
        // first half deep, second half REM; HR is 50 then 60
        val stages = run(1 to 10, 3 to 10)
        val hr = List(10) { 50.0 } + List(10) { 60.0 }
        val a = Sleep.autonomic(hr = hr, hrv = emptyList(), stages = stages)
        assertEquals(50.0, a.hrDeep!!, 1.0)
        assertEquals(60.0, a.hrRem!!, 1.0)
        assertNull(a.hrvDeep)
        assertTrue(a.any)
    }

    @Test
    fun `autonomic ignores non-positive samples`() {
        val stages = List(20) { 1 }
        val a = Sleep.autonomic(hr = List(20) { 0.0 }, hrv = emptyList(), stages = stages)
        assertNull(a.hrDeep)
        assertTrue(!a.any)
    }
}
