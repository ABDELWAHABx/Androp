package app.androp.android.utils

import org.junit.Assert.*
import org.junit.Test

class TransferNetworkPolicyTest {
    private val id = "df32313c-e346-4c66-a0d3-443ecabf466c"
    @Test fun acceptsOnlyVersionedBoundedLeaseCommands() {
        for (action in listOf("start", "ready", "error", "stop", "keepAlive", "request", "connected")) {
            assertTrue(TransferNetworkPolicy.accepts(1, id, action, 256))
        }
        assertFalse(TransferNetworkPolicy.accepts(2, id, "start", 256))
        assertFalse(TransferNetworkPolicy.accepts(1, id, "enableInternetHotspot", 256))
        assertFalse(TransferNetworkPolicy.accepts(1, id, "start", 8193))
        assertFalse(TransferNetworkPolicy.accepts(1, id, "start", 0))
    }
    @Test fun rejectsMissingOrAmbiguousLeaseIdentifiers() {
        for (bad in listOf("", "*", id + "\n", id.replace("-", ""), " " + id)) {
            assertFalse(bad, TransferNetworkPolicy.accepts(1, bad, "stop", 256))
        }
    }
    @Test fun requiresUsableProtectedHotspotCredentialsWithoutChangingSSIDWhitespace() {
        assertTrue(TransferNetworkPolicy.validCredentials("AndroidShare", "aB3p7Yx9"))
        assertTrue(TransferNetworkPolicy.validCredentials(" my hotspot ", "aB3p7Yx9"))
        assertTrue(TransferNetworkPolicy.validCredentials("é".repeat(16), "aB3p7Yx9"))
        assertFalse(TransferNetworkPolicy.validCredentials("é".repeat(17), "aB3p7Yx9"))
        for (ssid in listOf("", "a\nb", "x".repeat(33))) assertFalse(TransferNetworkPolicy.validCredentials(ssid, "aB3p7Yx9"))
        for (password in listOf("", "1234567", "a".repeat(64), "abc\ndefgh", "abcdefgé")) {
            assertFalse(TransferNetworkPolicy.validCredentials("AndroidShare", password))
        }
    }
    @Test fun wifiCanMaintainOnlyAnExistingAuthenticatedLease() {
        for (action in listOf("keepAlive", "stop", "error", "connected")) {
            assertTrue(TransferNetworkPolicy.allowsNetworkControl(action, true, true))
            assertFalse(TransferNetworkPolicy.allowsNetworkControl(action, false, true))
            assertFalse(TransferNetworkPolicy.allowsNetworkControl(action, true, false))
        }
        for (action in listOf("start", "request", "ready"))
            assertFalse(TransferNetworkPolicy.allowsNetworkControl(action, true, true))
    }
    @Test fun encryptedCredentialsAuthenticateAndRejectAnotherPairingKey() {
        val key = CryptoUtil.decodeKey(java.util.Base64.getEncoder().encodeToString(ByteArray(32) { it.toByte() }))
        val other = CryptoUtil.decodeKey(java.util.Base64.getEncoder().encodeToString(ByteArray(32) { (it + 1).toByte() }))
        val message = "{\"v\":1,\"id\":\"$id\",\"action\":\"ready\",\"ssid\":\"AndroidShare\",\"password\":\"aB3p7Yx9\"}"
        val encrypted = CryptoUtil.encryptMessage(message, key)!!
        assertFalse(encrypted.contains("AndroidShare"))
        assertEquals(message, CryptoUtil.decryptMessage(encrypted, key))
        assertNull(CryptoUtil.decryptMessage(encrypted, other))
        val bytes = java.util.Base64.getDecoder().decode(encrypted)
        bytes[bytes.lastIndex] = (bytes.last().toInt() xor 1).toByte()
        assertNull(CryptoUtil.decryptMessage(java.util.Base64.getEncoder().encodeToString(bytes), key))
    }
    @Test fun connectionAcknowledgementCannotAuthorizeAnUnsolicitedPhoneShare() {
        assertTrue(TransferNetworkPolicy.acceptsConnected(phoneInitiated = true))
        assertFalse(TransferNetworkPolicy.acceptsConnected(phoneInitiated = false))
    }
}
