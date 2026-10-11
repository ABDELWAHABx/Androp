package app.androp.android.data.ble

import app.androp.android.utils.CryptoUtil
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.util.UUID
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** The QR secret proves possession on both sides before legacy BLE authentication is enabled. */
object BlePairingProtocol {
    const val MAX_ENVELOPE_BYTES = 2048
    const val MAX_PLAIN_BYTES = 1024
    const val WINDOW_MS = 120_000L
    data class Request(val pairing: String, val nonce: String)
    data class Confirmation(val pairing: String, val nonce: String, val token: String)

    fun isPairingChunk(value: ByteArray): Boolean =
        BleChunkUtil.parseHeader(value)?.second?.let { it <= MAX_ENVELOPE_BYTES } == true

    fun validId(value: String): Boolean = runCatching {
        UUID.fromString(value).toString().equals(value, ignoreCase = true)
    }.getOrDefault(false)

    fun validKey(value: String): Boolean = runCatching {
        CryptoUtil.decodeKey(value).encoded.size == 32
    }.getOrDefault(false)

    private fun decode(envelope: String, key: String, pairing: String): JsonObject? = runCatching {
        if (!validKey(key) || !validId(pairing) || envelope.toByteArray().size !in 1..MAX_ENVELOPE_BYTES) return null
        val outer = JsonParser.parseString(envelope).asJsonObject
        if (outer.get("type")?.asString != "blePairing") return null
        val plain = CryptoUtil.decryptMessage(outer.get("encrypted").asString, CryptoUtil.decodeKey(key)) ?: return null
        if (plain.toByteArray().size !in 1..MAX_PLAIN_BYTES) return null
        val body = JsonParser.parseString(plain).asJsonObject
        val requestedSession = body.get("pairing")?.asString ?: return null
        if (body.get("v")?.toString() != "1" ||
            !validId(requestedSession) || !requestedSession.equals(pairing, ignoreCase = true)) return null
        val nonce = body.get("nonce").asString
        if (!validId(nonce)) return null
        body
    }.getOrNull()

    fun request(envelope: String, key: String, pairing: String): Request? = runCatching {
        val body = decode(envelope, key, pairing) ?: return null
        if (body.get("action")?.asString != "request") return null
        Request(body.get("pairing").asString, body.get("nonce").asString)
    }.getOrNull()

    fun confirmation(envelope: String, key: String, pairing: String): Confirmation? = runCatching {
        val body = decode(envelope, key, pairing) ?: return null
        if (body.get("action")?.asString != "confirm") return null
        val token = body.get("token").asString
        if (token.length !in 16..256 || token.any { it.code !in 33..126 }) return null
        Confirmation(body.get("pairing").asString, body.get("nonce").asString, token)
    }.getOrNull()

    fun response(request: Request, key: String, token: String, deviceID: String, name: String): String? = runCatching {
        if (!validId(request.pairing) || !validId(request.nonce) || !validKey(key) ||
            token.length !in 16..256 || token.any { it.code !in 33..126 } ||
            deviceID.toByteArray().size !in 1..128 || name.toByteArray().size !in 1..256) return null
        val body = JsonObject().apply {
            addProperty("v", 1); addProperty("action", "response")
            addProperty("pairing", request.pairing); addProperty("nonce", request.nonce)
            addProperty("token", token); addProperty("deviceID", deviceID); addProperty("name", name)
        }.toString()
        if (body.toByteArray().size > MAX_PLAIN_BYTES) return null
        val encrypted = CryptoUtil.encryptMessage(body, CryptoUtil.decodeKey(key)) ?: return null
        JsonObject().apply { addProperty("type", "blePairing"); addProperty("encrypted", encrypted) }.toString()
            .takeIf { it.toByteArray().size <= MAX_ENVELOPE_BYTES }
    }.getOrNull()

    // ---- Reconnect after QR pairing: mutual proof, the token never crosses the air. ----
    // Mac -> phone: {"v":2,"action":"hello","nonce":Nm}
    // phone -> Mac: {"v":2,"action":"challenge","nonce":Np,"proof":HMAC(token,"…|phone|Nm|Np")}
    // Mac -> phone: {"v":2,"action":"auth","proof":HMAC(token,"…|mac|Np|Nm")}
    // phone -> Mac: AUTH_SUCCESS. A device replaying the phone's advertisement learns nothing:
    // it cannot answer the Mac's fresh nonce, and the Mac never sends a reusable secret.
    // Must match BLEPairingProtocol.swift.

    private val random = java.security.SecureRandom()

    fun newNonce(): String = java.util.Base64.getEncoder().encodeToString(ByteArray(16).also(random::nextBytes))

    private fun validNonce(value: String?): Boolean = value != null && value.length <= 32 &&
        runCatching { java.util.Base64.getDecoder().decode(value).size == 16 }.getOrDefault(false)

    fun reconnectProof(token: String, role: String, first: String, second: String): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(token.toByteArray(Charsets.UTF_8), "HmacSHA256"))
        return java.util.Base64.getEncoder().encodeToString(
            mac.doFinal("androp-ble-auth|$role|$first|$second".toByteArray(Charsets.UTF_8)))
    }

    private fun body(text: String, action: String): JsonObject? = runCatching {
        if (text.toByteArray().size > MAX_PLAIN_BYTES) return null
        val body = JsonParser.parseString(text).asJsonObject
        body.takeIf { it.get("v")?.asInt == 2 && it.get("action")?.asString == action }
    }.getOrNull()

    /** The Mac's nonce from a reconnect hello, or null if [text] is not one. */
    fun helloNonce(text: String): String? = body(text, "hello")?.get("nonce")?.asString?.takeIf(::validNonce)

    fun challenge(token: String, macNonce: String, phoneNonce: String): String = JsonObject().apply {
        addProperty("v", 2); addProperty("action", "challenge"); addProperty("nonce", phoneNonce)
        addProperty("proof", reconnectProof(token, "phone", macNonce, phoneNonce))
    }.toString()

    /** True when [text] proves the Mac holds [token] for this exchange's nonces. */
    fun verifiesMacAuth(text: String, token: String, macNonce: String, phoneNonce: String): Boolean {
        val proof = body(text, "auth")?.get("proof")?.asString ?: return false
        return java.security.MessageDigest.isEqual(proof.toByteArray(),
            reconnectProof(token, "mac", phoneNonce, macNonce).toByteArray())
    }
}
