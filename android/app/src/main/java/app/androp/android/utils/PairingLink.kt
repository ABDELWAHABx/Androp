package app.androp.android.utils

import java.net.URI
import java.net.URLDecoder
import java.util.Base64
import java.util.UUID

/** Untrusted QR/deep links never reach a transport until their pairing data is valid. */
data class PairingLink(
    val host: String,
    val port: Int,
    val name: String?,
    val plus: Boolean,
    val key: String?,
    val transport: String = "wifi",
    val pairingSessionId: String? = null
) {
    val isBluetoothPairing: Boolean get() = transport == "ble"

    companion object {
        fun parse(value: String?): PairingLink? = runCatching {
            if (value == null || value.length > 8_192) return null
            val uri = URI(value)
            if (uri.scheme != "androp" || uri.userInfo != null || uri.fragment != null ||
                !uri.rawPath.isNullOrEmpty() || uri.rawAuthority.orEmpty().contains('@')) return null
            // Accept both the upstream repeated '?' separator and standard '&' queries.
            val parameters = mutableMapOf<String, String>()
            for (item in uri.rawQuery.orEmpty().split('?', '&')) {
                if (item.isEmpty()) continue
                val parts = item.split('=', limit = 2)
                // Ambiguous credentials/transport must not be interpreted differently by peers.
                if (parameters.put(parts[0], parts.getOrElse(1) { "" }) != null) return null
            }
            val name = parameters["name"]?.let { URLDecoder.decode(it, "UTF-8") }
            val plus = parameters["plus"]?.toBooleanStrictOrNull() ?: false
            // Older Mac QR codes write raw base64 (+, /, =) while standard links can
            // percent-encode it. A literal + in the key must never become a space.
            val key = parameters["key"]?.let { decodePreservingPlus(it) }?.takeIf { it.isNotBlank() }
            val transport = parameters["transport"] ?: "wifi"
            if (transport == "ble") {
                if (uri.host != "pair" || uri.port != -1 || parameters["v"] != "1") return null
                val pairing = parameters["pairing"]?.let { decodePreservingPlus(it) } ?: return null
                val session = UUID.fromString(pairing)
                if (!session.toString().equals(pairing, ignoreCase = true)) return null
                if (key == null || Base64.getDecoder().decode(key).size != 32) return null
                return PairingLink("", 0, name, plus, key, transport, session.toString())
            }
            if (transport != "wifi") return null
            val authority = uri.rawAuthority ?: return null
            // Mac QR codes may advertise several adapters as a comma-separated host list.
            val host = uri.host ?: authority.substringBeforeLast(':').takeIf { ',' in it } ?: return null
            val port = if (uri.port != -1) uri.port else authority.substringAfterLast(':').toIntOrNull() ?: return null
            if (port !in 1..65535 || host.isBlank()) return null
            val inputs = host.split(',')
            if (inputs.size > 16 || inputs.any { ConnectionEndpoints.hosts(it, port).size != 1 }) return null
            PairingLink(host, port, name, plus, key)
        }.getOrNull()

        private fun decodePreservingPlus(value: String): String =
            URLDecoder.decode(value.replace("+", "%2B"), "UTF-8")
    }
}
