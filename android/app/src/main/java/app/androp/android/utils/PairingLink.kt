package app.androp.android.utils

import java.net.URI
import java.net.URLDecoder

/** Untrusted QR/deep links never reach socket setup until their endpoint is valid. */
data class PairingLink(val host: String, val port: Int, val name: String?, val plus: Boolean, val key: String?) {
    companion object {
        fun parse(value: String?): PairingLink? = runCatching {
            if (value == null || value.length > 8_192) return null
            val uri = URI(value)
            if (uri.scheme != "androp" || uri.userInfo != null || uri.fragment != null ||
                uri.host.isNullOrBlank() || uri.port !in 1..65535) return null
            // Accept both the upstream repeated '?' separator and standard '&' queries.
            val parameters = uri.rawQuery.orEmpty().split('?', '&').associate { item ->
                val parts = item.split('=', limit = 2)
                parts[0] to parts.getOrElse(1) { "" }
            }
            PairingLink(uri.host, uri.port,
                parameters["name"]?.let { URLDecoder.decode(it, "UTF-8") },
                parameters["plus"]?.toBooleanStrictOrNull() ?: false, parameters["key"])
        }.getOrNull()
    }
}
