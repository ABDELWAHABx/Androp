package app.androp.android.data.ble

import app.androp.android.utils.CryptoUtil
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.util.UUID

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
}
