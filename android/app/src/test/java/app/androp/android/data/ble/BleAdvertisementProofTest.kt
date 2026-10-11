package app.androp.android.data.ble

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class BleAdvertisementProofTest {
    @Test fun proofIsStableWithinWindowAndChangesAcrossWindows() {
        val a = BleAdvertisementProof.proof("token", 100)
        assertEquals(BleAdvertisementProof.PROOF_BYTES, a.size)
        assertArrayEquals(a, BleAdvertisementProof.proof("token", 100))
        assertFalse(a.contentEquals(BleAdvertisementProof.proof("token", 101)))
        assertFalse(a.contentEquals(BleAdvertisementProof.proof("other", 100)))
    }

    // Same vector is checked by the Mac regression test.
    @Test fun matchesSharedVector() {
        val hex = BleAdvertisementProof.proof("token", 100).joinToString("") { "%02x".format(it) }
        assertEquals("ff06e76291", hex)
    }

    @Test fun windowBoundaries() {
        assertEquals(1L, BleAdvertisementProof.window(600))
        assertEquals(600_000L, BleAdvertisementProof.millisUntilNextWindow(0))
        assertEquals(1L, BleAdvertisementProof.millisUntilNextWindow(599_999))
    }
}
