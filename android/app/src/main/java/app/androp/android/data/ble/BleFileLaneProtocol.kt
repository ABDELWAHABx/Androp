package app.androp.android.data.ble

import java.io.DataInputStream
import java.io.DataOutputStream
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Bluetooth file lane: small files over an L2CAP channel when there is no Wi-Fi, instead of
 * starting a temporary hotspot. The Mac always opens the channel (Apple allows only the central
 * to), then sends a plaintext preamble [u16 length]["androp-lane:1:" + id]. Both sides derive that
 * transfer's key as HMAC-SHA256(pairing key, "androp-file-lane:v1:" + id) and exchange
 * [BulkTransferProtocol] records with it. The ID is fresh per transfer, so a key is never reused.
 * Must match BLEFileLaneProtocol.swift.
 */
object BleFileLaneProtocol {
    /** Bigger selections are faster over the temporary Wi-Fi network. */
    const val MAX_LANE_BYTES = 16L * 1024 * 1024
    /** Small records keep progress smooth at Bluetooth speed. */
    const val RECORD_BYTES = 32 * 1024
    private const val MAX_PREAMBLE_BYTES = 512
    private const val PREAMBLE_PREFIX = "androp-lane:1:"

    fun fits(totalBytes: Long): Boolean = totalBytes in 0..MAX_LANE_BYTES

    fun validId(id: String): Boolean = id.length in 1..128 && id.all { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it == '-' }

    fun deriveKey(pairingKeyBase64: String, id: String): ByteArray? {
        val pairingKey = runCatching { java.util.Base64.getDecoder().decode(pairingKeyBase64.trim()) }.getOrNull()
        if (pairingKey == null || pairingKey.size != 32 || !validId(id)) return null
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(pairingKey, "HmacSHA256"))
        return mac.doFinal("androp-file-lane:v1:$id".toByteArray(Charsets.UTF_8))
    }

    fun writePreamble(out: DataOutputStream, id: String) {
        val bytes = (PREAMBLE_PREFIX + id).toByteArray(Charsets.UTF_8)
        out.writeShort(bytes.size)
        out.write(bytes)
    }

    /** The transfer ID, or null for anything that isn't a version-1 preamble. */
    fun readPreamble(input: DataInputStream): String? {
        val length = input.readUnsignedShort()
        if (length !in 1..MAX_PREAMBLE_BYTES) return null
        val text = String(ByteArray(length).also { input.readFully(it) }, Charsets.UTF_8)
        if (!text.startsWith(PREAMBLE_PREFIX)) return null
        return text.removePrefix(PREAMBLE_PREFIX).takeIf(::validId)
    }

    /** A received file name: a single path component, no hidden or reserved names. */
    fun validName(name: String): Boolean = name.isNotBlank() && name.toByteArray(Charsets.UTF_8).size <= 255 &&
        name != "." && name != ".." && !name.startsWith(".") && name.none { it == '/' || it == '\\' || it == '\u0000' }
}
