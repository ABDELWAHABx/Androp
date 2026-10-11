package app.androp.android.utils

import org.junit.Assert.*
import org.junit.Test

class PairingLinkTest {
    @Test fun malformedExternalLinksDoNotCrashOrCreateConnections() {
        listOf(null, "androp://192.168.1.5:nope", "androp://host:0", "androp://host:65536",
            "androp://host", "androp://user@host:6997", "https://host:6997",
            "androp://host:6997?name=%ZZ", "androp://host:6997/socket",
            "androp://host:6997#fragment", "androp://host:6997?key=%ZZ").forEach { assertNull(it, PairingLink.parse(it)) }
    }

    @Test fun readsLegacyQrAndStandardQuerySeparators() {
        val legacy = PairingLink.parse("androp://192.168.1.5:6997?name=My%20Mac?plus=true?key=YWJj==")!!
        val standard = PairingLink.parse("androp://192.168.1.5:6997?name=My%20Mac&plus=true&key=YWJj==")!!
        assertEquals(legacy, standard)
        assertEquals("My Mac", legacy.name)
        assertEquals("YWJj==", legacy.key)
        assertEquals(6997, legacy.port)
    }

    @Test fun preservesMacBase64KeyWithPlusSlashAndPadding() {
        val key = "++//AQ=="
        val raw = PairingLink.parse("androp://192.168.1.5:6997?name=Mac?plus=true?key=$key")!!
        val encoded = PairingLink.parse("androp://192.168.1.5:6997?name=Mac&plus=true&key=%2B%2B%2F%2FAQ%3D%3D")!!
        assertEquals(key, raw.key)
        assertEquals(raw, encoded)
        assertTrue(raw.plus)
    }

    @Test fun reservedCharactersInMacNameCannotBecomeParameters() {
        val pairing = PairingLink.parse("androp://192.168.1.5:6997?name=My%20Mac%20%26%20A%3FB%3DC%2BD%25?plus=true?key=YWJj==")!!
        assertEquals("My Mac & A?B=C+D%", pairing.name)
        assertEquals("YWJj==", pairing.key)
        assertTrue(pairing.plus)
    }

    @Test fun missingOrEmptyKeyDoesNotReuseAnEarlierPairing() {
        assertNull(PairingLink.parse("androp://192.168.1.5:6997?name=Other")!!.key)
        assertNull(PairingLink.parse("androp://192.168.1.5:6997?key=")!!.key)
    }

    @Test fun acceptsMacAdapterListButRejectsMalformedOrUnboundedEndpoints() {
        val pairing = PairingLink.parse("androp://192.168.1.5,10.0.0.2:6997?name=Mac?key=YWJj==")!!
        assertEquals("192.168.1.5,10.0.0.2", pairing.host)
        assertEquals(6997, pairing.port)
        listOf(
            "androp://192.168.1.5,999.1.1.1:6997",
            "androp://192.168.1.5,:6997",
            "androp://user@192.168.1.5,10.0.0.2:6997",
            "androp://" + List(17) { "10.0.0.${it + 1}" }.joinToString(",") + ":6997"
        ).forEach { assertNull(it, PairingLink.parse(it)) }
    }

    private val session = "01234567-89ab-4cde-8fab-0123456789ab"
    private val aesKey = java.util.Base64.getEncoder().encodeToString(ByteArray(32) { 0xfb.toByte() })
    private val bluetoothLink get() = "androp://pair?transport=ble&v=1&name=My%20Mac&key=$aesKey&pairing=$session"

    @Test fun bluetoothPairingDoesNotRequireWifiEndpoint() {
        val pairing = PairingLink.parse(bluetoothLink)!!
        assertTrue(pairing.isBluetoothPairing)
        assertEquals("", pairing.host)
        assertEquals(0, pairing.port)
        assertEquals(session, pairing.pairingSessionId)
        assertEquals(aesKey, pairing.key)
        assertEquals("My Mac", pairing.name)
        assertFalse(PairingLink.parse("androp://192.168.1.5:6997")!!.isBluetoothPairing)
    }

    @Test fun bluetoothPairingRequiresKnownVersionSessionAndFullEncryptionKey() {
        listOf(
            bluetoothLink.replace("v=1", "v=2"),
            bluetoothLink.replace("transport=ble", "transport=other"),
            bluetoothLink.replace("androp://pair?", "androp://pair:6997?"),
            bluetoothLink.replace("pairing=$session", "pairing=1-1-1-1-1"),
            bluetoothLink.replace("key=$aesKey", "key=YWJj=="),
            bluetoothLink.replace("key=$aesKey", "key="),
            "$bluetoothLink&key=$aesKey",
            "$bluetoothLink&transport=wifi"
        ).forEach { assertNull(it, PairingLink.parse(it)) }
    }

    @Test fun supportsBracketedIpv6AndRejectsOverlongData() {
        assertNotNull(PairingLink.parse("androp://[fd00::1]:6997?name=Mac"))
        assertNull(PairingLink.parse("androp://host:6997?name=" + "a".repeat(8_192)))
    }
}
