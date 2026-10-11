package app.androp.android.data.ble

import app.androp.android.utils.CryptoUtil
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.util.Base64
import org.junit.Assert.*
import org.junit.Test

class BlePairingProtocolTest {
    private val key = Base64.getEncoder().encodeToString(ByteArray(32) { 7 })
    private val pairing = "83b32366-a60d-4722-8690-13a8e3b015fd"
    private val nonce = "a3b32366-a60d-4722-8690-13a8e3b015ff"
    private fun body(version: Int = 1, action: String = "request", session: String = pairing, challenge: String = nonce) =
        JsonObject().apply {
            addProperty("v", version); addProperty("action", action)
            addProperty("pairing", session); addProperty("nonce", challenge)
        }.toString()
    private fun seal(plain: String = body(), kind: String = "blePairing"): String = JsonObject().apply {
        addProperty("type", kind)
        addProperty("encrypted", CryptoUtil.encryptMessage(plain, CryptoUtil.decodeKey(key)))
    }.toString()

    @Test fun authenticatesFreshRequestUsingQrKeyAndExactWindow() {
        assertEquals(BlePairingProtocol.Request(pairing, nonce), BlePairingProtocol.request(seal(), key, pairing))
        assertNull(BlePairingProtocol.request(seal(), key, nonce))
        assertNull(BlePairingProtocol.request(seal(body(session = nonce)), key, pairing))
    }
    @Test fun canonicalUuidComparisonAcceptsMacUppercaseAndEchoesItsChallenge() {
        val request = BlePairingProtocol.request(seal(body(session = pairing.uppercase(), challenge = nonce.uppercase())), key, pairing)!!
        assertEquals(pairing.uppercase(), request.pairing)
        assertEquals(nonce.uppercase(), request.nonce)
    }
    @Test fun decodesSharedMacRequestAndConfirmationVectors() {
        val vectorKey = Base64.getEncoder().encodeToString(ByteArray(32) { it.toByte() })
        val vectorPairing = "11111111-1111-4111-8111-111111111111"
        val vectorNonce = "22222222-2222-4222-8222-222222222222"
        val request = """{"type":"blePairing","encrypted":"AAECAwQFBgcICQoLPCCgOf/U7jnsIuPi3odaV6Gk4kWFHiwIGkvH9XwActtvd4zGjfAjqUWVTty5qhkJ32hNuWvnkvcHphsoNdLE38EN90vi4BdQLXaGTIHgYItdqPNARFFhWs/PrP5Vwou/+dVt1JZz5SKsLgyfekcTTYhVUJnR9xeob4J0/OAwd4KRt/aJbk7orUOK"}"""
        val confirm = """{"type":"blePairing","encrypted":"AAECAwQFBgcICQoLPCCgOf/U7jnsIuPi3odaV6G16FqWEi0RGkvH9XwActtvd4zGjfAjqUWVTty5qhkJ32hNuWvnkvcHphsoNdLE38EN90vi4BdQLXaGTIHgYItdqPNARFFhWs/PrP5Vwou/+dVt1JZz5SKsLgyfekcTTYhVUJnR9xeob9N1ue2NC2CZaCL2heX4Zz3Xf4wF4y2gG5eHUFM8o3u+bMVDz+Te1qr2/HaNmqpc2gT7FifEjKqh12ro1aBB3sI="}"""
        assertEquals(BlePairingProtocol.Request(vectorPairing, vectorNonce), BlePairingProtocol.request(request, vectorKey, vectorPairing))
        assertNull(BlePairingProtocol.confirmation(request, vectorKey, vectorPairing))
        // Independently fixed AES-GCM fixture shared with the Mac regression suite.
        assertEquals(BlePairingProtocol.Confirmation(vectorPairing, vectorNonce, "01234567-89ab-cdef-0123-456789abcdef"),
            BlePairingProtocol.confirmation(confirm, vectorKey, vectorPairing))
        assertNull(BlePairingProtocol.request(confirm, vectorKey, vectorPairing))
        assertNull(BlePairingProtocol.confirmation(confirm, vectorKey, nonce))
    }
    @Test fun rejectsUnrelatedEncryptedTrafficAndResponsesAsRequests() {
        assertNull(BlePairingProtocol.request(seal(kind = "transferNetwork"), key, pairing))
        assertNull(BlePairingProtocol.request(seal(body(action = "response")), key, pairing))
        assertNull(BlePairingProtocol.request(seal(body(version = 2)), key, pairing))
        assertNull(BlePairingProtocol.request(seal(body(challenge = "")), key, pairing))
    }
    @Test fun rejectsWrongKeyAndTamperedEnvelope() {
        val wrongKey = Base64.getEncoder().encodeToString(ByteArray(32) { 8 })
        assertNull(BlePairingProtocol.request(seal(), wrongKey, pairing))
        val envelope = JsonParser.parseString(seal()).asJsonObject
        val bytes = Base64.getDecoder().decode(envelope.get("encrypted").asString)
        bytes[bytes.lastIndex] = (bytes.last().toInt() xor 1).toByte()
        envelope.addProperty("encrypted", Base64.getEncoder().encodeToString(bytes))
        assertNull(BlePairingProtocol.request(envelope.toString(), key, pairing))
    }
    @Test fun rejectsOversizedAndMalformedInputsWithoutThrowing() {
        for (value in listOf("", "{}", "null", "[]", "x".repeat(2049), seal(" ".repeat(1025))))
            assertNull(BlePairingProtocol.request(value, key, pairing))
        assertNull(BlePairingProtocol.request(seal(), "invalid", pairing))
    }
    @Test fun responsePreservesSessionNonceAndIdentityInsideEncryption() {
        val request = BlePairingProtocol.Request(pairing, nonce)
        val envelope = BlePairingProtocol.response(request, key, "abc123def456ghi789", "phone-id", "Galaxy S21 FE")!!
        assertFalse(envelope.contains("phone-id"))
        val outer = JsonParser.parseString(envelope).asJsonObject
        val response = JsonParser.parseString(CryptoUtil.decryptMessage(outer.get("encrypted").asString, CryptoUtil.decodeKey(key))).asJsonObject
        assertEquals("response", response.get("action").asString)
        assertEquals(pairing, response.get("pairing").asString)
        assertEquals(nonce, response.get("nonce").asString)
        assertEquals("phone-id", response.get("deviceID").asString)
        assertEquals("abc123def456ghi789", response.get("token").asString)
    }
    @Test fun rejectsUnboundedIdentityAndBearer() {
        val request = BlePairingProtocol.Request(pairing, nonce)
        assertNull(BlePairingProtocol.response(request, key, "tiny", "id", "phone"))
        assertNull(BlePairingProtocol.response(request, key, "x".repeat(257), "id", "phone"))
        assertNull(BlePairingProtocol.response(request, key, "x".repeat(24), "id", "é".repeat(129)))
        assertNull(BlePairingProtocol.response(request, key, "x".repeat(24), "", "phone"))
    }
    @Test fun supportsDefaultMtuWithoutConfusingLegacyToken() {
        val text = seal()
        val assembler = BleChunkUtil.Reassembler(BlePairingProtocol.MAX_ENVELOPE_BYTES)
        val parts = BleChunkUtil.splitIntoChunks(text, 20)
        assertTrue(parts.size > 1)
        var reassembled: String? = null
        for (part in parts) {
            assertTrue(BlePairingProtocol.isPairingChunk(part))
            reassembled = assembler.addChunk(part)
        }
        assertEquals(text, reassembled)
        assertFalse(BlePairingProtocol.isPairingChunk("abc123def456ghi78901234==".toByteArray()))
        assertFalse(BlePairingProtocol.isPairingChunk(byteArrayOf(1)))
    }
    @Test fun unauthenticatedChunksHaveSmallMemoryBound() {
        val assembler = BleChunkUtil.Reassembler(BlePairingProtocol.MAX_ENVELOPE_BYTES)
        val parts = BleChunkUtil.splitIntoChunks("x".repeat(2049), 20)
        for (part in parts) assertNull(assembler.addChunk(part))
        val valid = BleChunkUtil.splitIntoChunks(seal(), 20)
        var result: String? = null
        for (part in valid) result = assembler.addChunk(part)
        assertNotNull(result)
    }
    @Test fun qrIdsAndKeyAreStrict() {
        assertTrue(BlePairingProtocol.validId(pairing))
        assertFalse(BlePairingProtocol.validId("1-1-1-1-1"))
        assertFalse(BlePairingProtocol.validId("$pairing\n"))
        assertTrue(BlePairingProtocol.validKey(key))
        assertFalse(BlePairingProtocol.validKey(Base64.getEncoder().encodeToString(ByteArray(16))))
    }
}
