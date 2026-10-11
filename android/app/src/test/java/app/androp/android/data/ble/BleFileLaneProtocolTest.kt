package app.androp.android.data.ble

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream

class BleFileLaneProtocolTest {
    private val pairingKey = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=" // bytes 0..31
    private val id = "0A1B2C3D-0000-4000-8000-000000000001"

    @Test fun keyMatchesTheMacDerivation() {
        // Same vector as the Mac's BLEFileLaneProtocol regression.
        val key = BleFileLaneProtocol.deriveKey(pairingKey, id)!!
        assertEquals("915e2b96873a2a5fc3e8149145b87b83417ce43a3ed1338a0938424b5788bb37",
            key.joinToString("") { "%02x".format(it.toInt() and 255) })
    }

    @Test fun eachTransferGetsItsOwnKey() {
        val other = BleFileLaneProtocol.deriveKey(pairingKey, "0A1B2C3D-0000-4000-8000-000000000002")!!
        assertFalse(BleFileLaneProtocol.deriveKey(pairingKey, id)!!.contentEquals(other))
    }

    @Test fun rejectsBadKeysAndIds() {
        assertNull(BleFileLaneProtocol.deriveKey("not base64!", id))
        assertNull(BleFileLaneProtocol.deriveKey("AAEC", id)) // too short
        assertNull(BleFileLaneProtocol.deriveKey(pairingKey, ""))
        assertNull(BleFileLaneProtocol.deriveKey(pairingKey, "../../etc"))
        assertNull(BleFileLaneProtocol.deriveKey(pairingKey, "a".repeat(129)))
    }

    @Test fun preambleRoundTripsAndRejectsGarbage() {
        val bytes = ByteArrayOutputStream()
        BleFileLaneProtocol.writePreamble(DataOutputStream(bytes), id)
        assertEquals(id, BleFileLaneProtocol.readPreamble(DataInputStream(ByteArrayInputStream(bytes.toByteArray()))))
        fun read(raw: ByteArray) = BleFileLaneProtocol.readPreamble(DataInputStream(ByteArrayInputStream(raw)))
        assertNull(read(byteArrayOf(0, 0)))
        assertNull(read(byteArrayOf(0x7f, 0x7f)))
        val wrongVersion = "androp-lane:2:$id".toByteArray()
        assertNull(read(byteArrayOf(0, wrongVersion.size.toByte()) + wrongVersion))
    }

    @Test fun onlySmallSelectionsUseTheLane() {
        assertTrue(BleFileLaneProtocol.fits(0))
        assertTrue(BleFileLaneProtocol.fits(BleFileLaneProtocol.MAX_LANE_BYTES))
        assertFalse(BleFileLaneProtocol.fits(BleFileLaneProtocol.MAX_LANE_BYTES + 1))
        assertFalse(BleFileLaneProtocol.fits(-1))
    }

    @Test fun receivedNamesStayInsideDownloads() {
        assertTrue(BleFileLaneProtocol.validName("photo.jpg"))
        for (bad in listOf("", ".", "..", ".hidden", "a/b", "a\\b", "nul\u0000l")) assertFalse(bad, BleFileLaneProtocol.validName(bad))
    }
}
