package md.thomas.openoura.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The scheduled 6-hour background sync retries a momentarily unreachable ring with
 * exponential backoff, up to 5 attempts, each wait capped at one minute. Attempt 1 runs
 * immediately, so backoff is only consulted for attempts 2..5.
 */
class BackoffTest {

    @Test
    fun `scheduled backoff doubles from 5s and never exceeds one minute`() {
        assertEquals(5_000L, SyncEngine.SCHEDULED_BACKOFF(2))
        assertEquals(10_000L, SyncEngine.SCHEDULED_BACKOFF(3))
        assertEquals(20_000L, SyncEngine.SCHEDULED_BACKOFF(4))
        assertEquals(40_000L, SyncEngine.SCHEDULED_BACKOFF(5))
    }

    @Test
    fun `scheduled backoff stays capped at one minute past attempt 5`() {
        // Defensive: even if the attempt count is ever raised, no wait grows past 60 s.
        for (attempt in 2..12) {
            assertTrue(
                "attempt $attempt wait must be <= 60s",
                SyncEngine.SCHEDULED_BACKOFF(attempt) <= 60_000L,
            )
        }
        assertEquals(60_000L, SyncEngine.SCHEDULED_BACKOFF(6))
        assertEquals(60_000L, SyncEngine.SCHEDULED_BACKOFF(7))
    }

    @Test
    fun `manual and automatic keep the fixed three-second pause`() {
        assertEquals(3_000L, SyncEngine.FIXED_3S(2))
        assertEquals(3_000L, SyncEngine.FIXED_3S(5))
    }
}
