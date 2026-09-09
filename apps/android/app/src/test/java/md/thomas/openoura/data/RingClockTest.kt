package md.thomas.openoura.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `ring_timestamp` (ds) is a per-boot relative deciseconds counter: it resets to ~0 every
 * time the ring reboots. Anchoring every ds to one global reference scatters older boots
 * to wildly wrong dates. The epoch-aware mapping exists in THREE places that must agree —
 * `crates/oura-summary/src/ring_time.rs`, `tools/epoch_time.py` and this Kotlin/Swift pair
 * (docs/clients.md). These tests pin the behaviour that matters.
 */
class RingClockTest {

    /** A `time_sync` record (tag 0x42) — the ring's own authoritative ds ↔ UTC anchor. */
    private fun timeSync(ds: Long, unix: Long, cu: Long = unix) = EventStore.Ev(
        ds = ds,
        tag = 0x42,
        json = SummaryJson.parseToJsonElement("""{"unix_time":$unix}""")
            as kotlinx.serialization.json.JsonObject,
        cu = cu,
        body = null,
    )

    private fun event(ds: Long, cu: Long) = EventStore.Ev(ds, 0x50, null, cu, null)

    @Test
    fun `a ds maps through its epoch's time_sync anchor`() {
        val base = 1_772_000_000L
        val clock = EventStore.RingClock(listOf(timeSync(1000, base), event(1600, base + 60)))
        // 600 ds after the anchor is 60 seconds later
        assertEquals(base + 60.0, clock.unixSeconds(1600, base + 60), 0.001)
    }

    @Test
    fun `a reboot starts a new epoch anchored independently`() {
        val bootA = 1_772_000_000L
        val bootB = 1_772_600_000L   // a week later in wall-clock terms
        val events = listOf(
            timeSync(500_000, bootA, cu = bootA),
            event(500_600, bootA + 60),
            // ds jumps far backwards: the ring rebooted and its counter restarted
            timeSync(1_000, bootB, cu = bootB),
            event(1_600, bootB + 60),
        )
        val clock = EventStore.RingClock(events)
        // The low ds belongs to the NEW boot, not to the old epoch's early history.
        assertEquals(bootB + 60.0, clock.unixSeconds(1_600, bootB + 60), 0.001)
        // The high ds still resolves through the first boot's anchor.
        assertEquals(bootA + 60.0, clock.unixSeconds(500_600, bootA + 60), 0.001)
    }

    @Test
    fun `capturedUnix picks the right boot when ds ranges overlap`() {
        val bootA = 1_772_000_000L
        val bootB = 1_772_600_000L
        // Two boots that each ran from ds 1_000 to 500_000, so their ds ranges overlap
        // completely. Only the reboot between them (a backward ds jump far beyond the
        // six-hour slack) separates the epochs.
        val events = listOf(
            timeSync(1_000, bootA, cu = bootA),
            event(500_000, bootA + 49_900),
            timeSync(1_000, bootB, cu = bootB),
            event(500_000, bootB + 49_900),
        )
        val clock = EventStore.RingClock(events)
        // Identical ds; only the capture time says which boot it came from.
        assertEquals(bootA + 100.0, clock.unixSeconds(2_000, bootA + 100), 1.0)
        assertEquals(bootB + 100.0, clock.unixSeconds(2_000, bootB + 100), 1.0)
    }

    @Test
    fun `a small backward ds step is not treated as a reboot`() {
        val base = 1_772_000_000L
        // Events can arrive slightly out of ds order within one boot; only a jump beyond
        // the six-hour slack means the counter actually restarted.
        val clock = EventStore.RingClock(
            listOf(timeSync(10_000, base, cu = base), event(9_000, base - 100))
        )
        // Still the same epoch, so it maps through the same anchor rather than becoming
        // its own boot.
        assertEquals(base - 100.0, clock.unixSeconds(9_000, base - 100), 1.0)
    }

    @Test
    fun `a projection more than six hours past its capture time is rejected`() {
        val base = 1_772_000_000L
        // An anchor that would project this event far into the future relative to when the
        // phone actually captured it — the signature of a replayed older boot.
        val clock = EventStore.RingClock(
            listOf(timeSync(1_000, base), event(10_000_000, base + 60))
        )
        val projected = clock.unixSeconds(10_000_000, capturedUnix = base + 60)
        assertTrue(
            "expected a plausible time, got ${projected - base} s past the anchor",
            projected <= base + 60 + 6 * 3600,
        )
    }

    @Test
    fun `latestUnix reports the newest time_sync`() {
        val base = 1_772_000_000L
        val clock = EventStore.RingClock(
            listOf(timeSync(1_000, base), timeSync(2_000, base + 100))
        )
        assertEquals(base + 100, clock.latestUnix)
    }

    @Test
    fun `without any time_sync the clock falls back to capture times`() {
        val base = 1_772_000_000L
        val clock = EventStore.RingClock(listOf(event(1_000, base), event(1_600, base + 60)))
        // No anchors at all, so the epoch's newest capture time carries the mapping.
        assertEquals(base + 60.0, clock.unixSeconds(1_600, base + 60), 1.0)
        assertEquals(base + 60, clock.latestUnix)
    }
}
