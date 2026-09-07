package md.thomas.openoura.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Ring 5 history arrives as thousands of tiny GATT notifications, so history payloads are
 * coalesced into 32 KB chunks while command replies and the terminal batch summary stay
 * immediate. That classification lives in the CLIENT, not in Rust — it exists in both
 * Swift (`BLETransport.isHistoryPayload`) and Kotlin and must agree, because misclassifying
 * a terminator would leave it buffered and stall the drain. See docs/clients.md.
 */
class HistoryPayloadTest {

    private fun packet(tag: Int, vararg payload: Int): ByteArray =
        byteArrayOf(tag.toByte(), payload.size.toByte()) + payload.map { it.toByte() }.toByteArray()

    @Test
    fun `a legacy history packet has an event tag at or above 0x41`() {
        assertTrue(BleTransport.isHistoryPayload(packet(0x41, 1, 2, 3)))
        assertTrue(BleTransport.isHistoryPayload(packet(0x7E, 9, 9)))
        assertTrue(BleTransport.isHistoryPayload(packet(0xFF, 0)))
    }

    @Test
    fun `extended history is 0x2f with a 0x43 first byte`() {
        assertTrue(BleTransport.isHistoryPayload(packet(0x2f, 0x43, 7)))
        // 0x2f carrying anything else is a control packet, not history
        assertFalse(BleTransport.isHistoryPayload(packet(0x2f, 0x42, 7)))
    }

    @Test
    fun `a command reply below 0x41 is delivered immediately`() {
        assertFalse(BleTransport.isHistoryPayload(packet(0x10, 0)))
        assertFalse(BleTransport.isHistoryPayload(packet(0x40, 1, 2)))
    }

    @Test
    fun `several packets in one notification are all walked`() {
        val both = packet(0x41, 1) + packet(0x42, 2, 3)
        assertTrue(BleTransport.isHistoryPayload(both))
    }

    @Test
    fun `one control packet anywhere forces immediate delivery`() {
        // A trailing terminator must never sit buffered behind history packets.
        val mixed = packet(0x41, 1) + packet(0x10, 0)
        assertFalse(BleTransport.isHistoryPayload(mixed))
        val leading = packet(0x10, 0) + packet(0x41, 1)
        assertFalse(BleTransport.isHistoryPayload(leading))
    }

    @Test
    fun `a truncated packet is not treated as history`() {
        // length byte claims more than the buffer holds
        assertFalse(BleTransport.isHistoryPayload(byteArrayOf(0x41, 10, 1, 2)))
        // a lone tag with no length byte
        assertFalse(BleTransport.isHistoryPayload(byteArrayOf(0x41)))
    }

    @Test
    fun `an empty notification is not history`() {
        assertFalse(BleTransport.isHistoryPayload(ByteArray(0)))
    }

    @Test
    fun `a zero-length history packet still counts`() {
        assertTrue(BleTransport.isHistoryPayload(byteArrayOf(0x41, 0)))
    }
}
