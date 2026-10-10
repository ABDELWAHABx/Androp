package app.androp.android.utils

import okhttp3.HttpUrl

/** Bounded, literal host-only input shared by saved, manual and discovered connections. */
internal object ConnectionEndpoints {
    fun hosts(addresses: String, port: Int): List<String> {
        if (port !in 1..65535 || addresses.length > 4096) return emptyList()
        return addresses.split(',').asSequence().map { it.trim() }
            .filter { it.isNotEmpty() }
            .mapNotNull { input ->
                // Host builder rejects URI paths, credentials, query strings and malformed IPs.
                val host = input.removeSurrounding("[", "]")
                if ('%' in host) return@mapNotNull null // OkHttp cannot retain an IPv6 scope ID.
                if (host.all { it.isDigit() || it == '.' }) {
                    val octets = host.split('.')
                    if (octets.size != 4 || octets.any { it.toIntOrNull() !in 0..255 }) return@mapNotNull null
                }
                try {
                    HttpUrl.Builder().scheme("http").host(host).port(port).build().host
                } catch (_: IllegalArgumentException) { null }
            }.distinct().take(16).toList()
    }
}
