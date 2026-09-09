package md.thomas.openoura.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The day-pairing rule is duplicated across all three clients (web `wakeYmd()` in
 * app.js, iOS `Summary.wakeYmd` in Models.swift, and here). docs/clients.md calls it
 * out as something that MUST stay identical, so it gets tests.
 */
class DayPairingTest {

    private fun night(
        ymd: String?,
        start: String?,
        end: String?,
        inBedH: Double? = null,
        date: String? = null,
    ) = NightRow(date = date, ymd = ymd, start = start, end = end, inBedH = inBedH)

    @Test
    fun `night crossing midnight is labelled by the morning it ends`() {
        val s = Summary(nights = listOf(night("2026-03-01", "23:10", "07:05")))
        // onset 2026-03-01 evening, wake 2026-03-02 morning
        assertEquals("2026-03-02", s.wakeYmd(s.nights[0]))
    }

    @Test
    fun `night entirely within one day keeps its onset date`() {
        val s = Summary(nights = listOf(night("2026-03-01", "01:10", "08:40")))
        // end > start, so no midnight crossing
        assertEquals("2026-03-01", s.wakeYmd(s.nights[0]))
    }

    @Test
    fun `month and year boundaries roll over correctly`() {
        val s = Summary(
            nights = listOf(
                night("2026-01-31", "23:30", "06:30"),
                night("2025-12-31", "22:45", "07:15"),
                night("2024-02-28", "23:50", "06:00"), // leap year
            )
        )
        assertEquals("2026-02-01", s.wakeYmd(s.nights[0]))
        assertEquals("2026-01-01", s.wakeYmd(s.nights[1]))
        assertEquals("2024-02-29", s.wakeYmd(s.nights[2]))
    }

    @Test
    fun `a night without ymd has no wake date`() {
        val s = Summary(nights = listOf(night(null, "23:00", "07:00")))
        assertNull(s.wakeYmd(s.nights[0]))
    }

    @Test
    fun `missing start or end falls back to the onset date`() {
        val s = Summary(nights = listOf(night("2026-03-01", null, "07:05")))
        assertEquals("2026-03-01", s.wakeYmd(s.nights[0]))
    }

    @Test
    fun `the longest in-bed night wins over a same-morning nap`() {
        val s = Summary(
            nights = listOf(
                night("2026-03-02", "05:30", "06:10", inBedH = 0.7),  // early-morning nap
                night("2026-03-01", "23:10", "07:05", inBedH = 7.9),  // the real sleep
            )
        )
        val picked = s.nightForDay("2026-03-02")
        assertEquals(7.9, picked?.inBedH!!, 1e-9)
    }

    @Test
    fun `legacy nights without ymd match on the MM-DD suffix`() {
        // Older rows carry no `ymd`, so the wake-date filter finds nothing and the
        // fallback matches the last five characters of the day key against `date`.
        val s = Summary(nights = listOf(night(null, null, null, date = "2026-03-02")))
        assertEquals("2026-03-02", s.nightForDay("2026-03-02")?.date)
        // a date that does not end in MM-DD is correctly not matched
        val other = Summary(nights = listOf(night(null, null, null, date = "2026-03-02 23:10")))
        assertNull(other.nightForDay("2026-03-02"))
    }

    @Test
    fun `days unions activity dates with night wake dates, newest first`() {
        val s = Summary(
            nights = listOf(night("2026-03-01", "23:10", "07:05", inBedH = 7.9)),
            activityProfile = mapOf(
                "2026-03-02" to listOf(1.0, 2.0),
                "2026-02-28" to listOf(1.0, 2.0),
            ),
        )
        // the night's wake date (03-02) coincides with an activity day, so no duplicate
        assertEquals(listOf("2026-03-02", "2026-02-28"), s.days)
    }

    @Test
    fun `nightlySeries keeps one value per wake date, preferring the longest night`() {
        val s = Summary(
            nights = listOf(
                night("2026-03-02", "05:30", "06:10", inBedH = 0.7).copy(hrvMs = 20.0),
                night("2026-03-01", "23:10", "07:05", inBedH = 7.9).copy(hrvMs = 55.0),
                night("2026-02-28", "23:00", "06:30", inBedH = 7.5).copy(hrvMs = 48.0),
            )
        )
        val series = s.nightlySeries { it.hrvMs }
        // oldest first, one point per wake date, nap discarded in favour of the real sleep
        assertEquals(listOf("2026-03-01", "2026-03-02"), series.map { it.date })
        assertEquals(48.0, series[0].value, 1e-9)
        assertEquals(55.0, series[1].value, 1e-9)
    }

    @Test
    fun `non-finite vitals are dropped from the series`() {
        val s = Summary(
            nights = listOf(
                night("2026-03-01", "23:10", "07:05", inBedH = 7.9).copy(hrvMs = Double.NaN),
                night("2026-02-28", "23:00", "06:30", inBedH = 7.5).copy(hrvMs = 48.0),
            )
        )
        assertEquals(listOf("2026-03-01"), s.nightlySeries { it.hrvMs }.map { it.date })
    }

    @Test
    fun `workoutsOn filters by day and by the isWorkout threshold`() {
        val s = Summary(
            workouts = listOf(
                WorkoutSession("2026-03-02T10:00", "2026-03-02T10:40", 40, "walk", 0.9),
                WorkoutSession("2026-03-02T14:00", "2026-03-02T14:20", 20, "idle", 0.2),
                WorkoutSession("2026-03-01T10:00", "2026-03-01T10:40", 40, "run", 1.0),
            )
        )
        val day = s.workoutsOn("2026-03-02")
        assertEquals(1, day.size)
        assertEquals("walk", day[0].label)
    }
}
