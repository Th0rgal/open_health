package md.thomas.openoura.ble

import md.thomas.openoura.store.isValidRingKey
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RingSyncFormatTest {

    @Test
    fun `auth rejections are recognised so they are not retried`() {
        // Retrying a deterministic rejection just re-fails and burns the ring's battery.
        assertTrue(SyncEngine.isAuthenticationFailure("protocol error: authentication failed"))
        assertTrue(SyncEngine.isAuthenticationFailure("Ring rejected auth key"))
        assertFalse(SyncEngine.isAuthenticationFailure("BLE link lost mid-batch"))
        assertFalse(SyncEngine.isAuthenticationFailure("extended history request failed with result code 0xff"))
    }

    @Test
    fun `the ring key must be exactly 32 hex characters`() {
        // Rust's parse_key enforces the same rule; rejecting early gives a better message.
        assertTrue(isValidRingKey("0123456789abcdef0123456789ABCDEF"))
        assertTrue(isValidRingKey("  0123456789abcdef0123456789abcdef  "))
        assertFalse(isValidRingKey("0123456789abcdef0123456789abcde"))   // 31
        assertFalse(isValidRingKey("0123456789abcdef0123456789abcdef0")) // 33
        assertFalse(isValidRingKey("0123456789abcdef0123456789abcdeg"))  // non-hex
        assertFalse(isValidRingKey(""))
    }

    @Test
    fun `byte counts read as KB below a megabyte and MB above`() {
        assertEquals("512 KB", SyncEngine.fmtBytes(524_288uL))
        assertEquals("1.0 MB", SyncEngine.fmtBytes(1_048_576uL))
        assertEquals("2.5 MB", SyncEngine.fmtBytes(2_621_440uL))
    }

    @Test
    fun `durations read in seconds, minutes then hours`() {
        assertEquals("1s", SyncEngine.fmtDuration(0.0))   // never "0s"
        assertEquals("45s", SyncEngine.fmtDuration(45.0))
        assertEquals("2 min", SyncEngine.fmtDuration(120.0))
        assertEquals("1.5 h", SyncEngine.fmtDuration(5400.0))
    }
}
