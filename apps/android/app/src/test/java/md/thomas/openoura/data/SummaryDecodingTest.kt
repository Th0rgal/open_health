package md.thomas.openoura.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The FFI hands us `build_summary()` output as a JSON string. These pin the snake_case
 * key mapping, so a rename in crates/oura-summary fails here instead of silently
 * rendering blanks.
 */
class SummaryDecodingTest {

    @Test
    fun `decodes the summary shape produced by build_summary`() {
        val json = """
        {
          "generated_at": 1772000000,
          "tz": 1,
          "digest": "Solid night.",
          "device": {"serial":"ABC123","firmware":"2.9.4","battery_pct":76,
                     "days_of_data":41.5,"nights":38,"synced":"2026-03-02","synced_hm":"08:12"},
          "nights": [{
             "date":"2026-03-01 23:10","ymd":"2026-03-01","start":"23:10","end":"07:05",
             "in_bed_h":7.9,"hrv_ms":55.2,"rhr":48.0,"skin_temp":36.1,"spo2_mean":96.4,
             "deep_pct":18.0,"light_pct":52.0,"rem_pct":22.0,"wake_pct":8.0,"efficiency":91.0,
             "stages":[1,1,2,3,4],
             "series":{"hr":[50.0,49.0],"hrv":[55.0],"spo2":[96.0],"temp":[36.0],
                       "temp_span":[0.0,1.0],"motion":[0.1]}
          }],
          "vitals": {"hrv":{"series":[50.0,55.0],"latest":55.2,"baseline":52.0,"delta_pct":6.1},
                     "rhr":{"series":[49.0,48.0],"latest":48.0,"baseline":49.5,"delta_pct":-3.0},
                     "hr":{"latest":62.0,"date":"2026-03-02","hm":"08:00","at_unix":1772000000}},
          "activity_profile": {"2026-03-02":[0.0,1.5,2.0]},
          "activity_daily": {"2026-03-02":{"active_kcal":410.0,"total_kcal":2210.0,
                                           "steps":8123.0,"distance_m":6180.0}},
          "profile": {"sex":"M","age":34.0,"height_m":1.81,"weight_kg":74.0,"ring_size":11.0},
          "cardio": {"vascular_age":31.2,"chronological_age":34.0,"pwv_ms":6.4,"segments":812},
          "fitness": {"vo2max":47.3},
          "sleep_debt": {"debt_min":126.0,"recent_shortfall_min":41.0,"valid":true,
                         "need_h":8.0,"valid_days":12,"window_days":14,"state":"moderate",
                         "days":[{"date":"2026-03-02","total_sleep_min":420.0,
                                  "sleep_need_min":480.0,"shortfall_min":60.0,
                                  "cumulative_debt_min":126.0,"valid_days":12}]}
        }
        """.trimIndent()

        val s = SummaryJson.decodeFromString(Summary.serializer(), json)

        assertEquals("Solid night.", s.digest)
        assertEquals(76, s.device?.batteryPct)
        assertEquals("08:12", s.device?.syncedHm)

        val n = s.nights.single()
        assertEquals(7.9, n.inBedH!!, 1e-9)
        assertEquals(55.2, n.hrvMs!!, 1e-9)
        assertEquals(96.4, n.spo2Mean!!, 1e-9)
        assertEquals(18.0, n.deepPct!!, 1e-9)
        assertTrue(n.hasHypnogram)
        assertEquals(listOf(0.0, 1.0), n.series?.tempSpan)

        assertEquals(52.0, s.vitals.hrv.baseline!!, 1e-9)
        assertEquals(-3.0, s.vitals.rhr.deltaPct!!, 1e-9)
        assertEquals(1772000000L, s.vitals.hr?.atUnix)

        assertEquals(8123.0, s.activityDaily["2026-03-02"]?.steps!!, 1e-9)
        assertEquals(6180.0, s.activityDaily["2026-03-02"]?.distanceM!!, 1e-9)
        assertEquals(1.81, s.profile?.heightM!!, 1e-9)
        assertEquals(31.2, s.cardio?.vascularAge!!, 1e-9)
        assertEquals(47.3, s.fitness?.vo2max!!, 1e-9)
        assertEquals("moderate", s.sleepDebt?.state)
        assertEquals(480.0, s.sleepDebt?.days?.single()?.sleepNeedMin!!, 1e-9)
    }

    @Test
    fun `unknown fields from a newer core do not break decoding`() {
        val s = SummaryJson.decodeFromString(
            Summary.serializer(),
            """{"digest":"hi","brand_new_field":{"a":1},"nights":[]}"""
        )
        assertEquals("hi", s.digest)
    }

    @Test
    fun `an FFI error object decodes into the error field`() {
        val s = SummaryJson.decodeFromString(
            Summary.serializer(),
            """{"error":"no decoded events in oura.db — run `oura sync` first"}"""
        )
        assertTrue(s.error!!.startsWith("no decoded events"))
        assertTrue(s.nights.isEmpty())
    }
}
