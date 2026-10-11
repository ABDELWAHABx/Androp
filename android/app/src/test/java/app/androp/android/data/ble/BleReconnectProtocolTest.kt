package app.androp.android.data.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BleReconnectProtocolTest {
    private val macNonce = "bWFjbWFjbWFjbWFjbWFjbQ=="
    private val phoneNonce = "cGhvbmVwaG9uZXBob25lcA=="

    // Same vector is checked by the Mac regression test.
    @Test fun proofMatchesSharedVector() {
        assertEquals("ZLFMCEKWZipsawh6Q45rCDI0AjySYuAiLtJh/jGmXZM=",
            BlePairingProtocol.reconnectProof("token", "phone", macNonce, phoneNonce))
    }

    @Test fun helloCarriesOnlyAValidNonce() {
        assertEquals(macNonce, BlePairingProtocol.helloNonce("""{"v":2,"action":"hello","nonce":"$macNonce"}"""))
        assertNull(BlePairingProtocol.helloNonce("""{"v":2,"action":"hello","nonce":"short"}"""))
        assertNull(BlePairingProtocol.helloNonce("""{"v":1,"action":"hello","nonce":"$macNonce"}"""))
        assertNull(BlePairingProtocol.helloNonce("plain-bearer-token"))
    }

    @Test fun macMustProveTheTokenForThePhonesNonce() {
        val good = """{"v":2,"action":"auth","proof":"${BlePairingProtocol.reconnectProof("token", "mac", phoneNonce, macNonce)}"}"""
        assertTrue(BlePairingProtocol.verifiesMacAuth(good, "token", macNonce, phoneNonce))
        assertFalse(BlePairingProtocol.verifiesMacAuth(good, "other", macNonce, phoneNonce))
        assertFalse(BlePairingProtocol.verifiesMacAuth(good, "token", macNonce, BlePairingProtocol.newNonce()))
        // Replaying the phone's own proof as the Mac's must fail (roles are bound).
        val reflected = """{"v":2,"action":"auth","proof":"${BlePairingProtocol.reconnectProof("token", "phone", macNonce, phoneNonce)}"}"""
        assertFalse(BlePairingProtocol.verifiesMacAuth(reflected, "token", macNonce, phoneNonce))
    }

    @Test fun challengeNeverContainsTheToken() {
        val challenge = BlePairingProtocol.challenge("super-secret-token", macNonce, phoneNonce)
        assertFalse(challenge.contains("super-secret-token"))
        assertTrue(challenge.contains(phoneNonce))
    }
}
