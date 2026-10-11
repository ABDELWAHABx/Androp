package app.androp.android.utils.discovery

import app.androp.android.utils.ConnectionEndpoints

/** The explicit list describes listener-bound addresses; Bonjour's host can include other adapters. */
internal object MdnsEndpointPolicy {
    fun addresses(advertisedIps: ByteArray?, hasAdvertisedIps: Boolean, legacyHost: String?, port: Int): Set<String> {
        if (port !in 1..65535) return emptySet()
        if (!hasAdvertisedIps) {
            return legacyHost?.let { ConnectionEndpoints.hosts(it, port).toSet() }.orEmpty()
        }
        // Treat malformed or empty explicit data as unavailable, never broaden back to Bonjour's host.
        if (advertisedIps == null || advertisedIps.isEmpty() || advertisedIps.size > 255) return emptySet()
        val value = advertisedIps.toString(Charsets.UTF_8)
        if (value.any { it !in '0'..'9' && it != '.' && it != ',' }) return emptySet()
        val hosts = value.split(',')
        if (hosts.size !in 1..16 || hosts.any { !canonicalUnicastIPv4(it) }) return emptySet()
        return hosts.toSet()
    }

    private fun canonicalUnicastIPv4(host: String): Boolean {
        val octets = host.split('.')
        if (octets.size != 4) return false
        val numbers = octets.map { octet ->
            val number = octet.toIntOrNull() ?: return false
            if (number !in 0..255 || number.toString() != octet) return false
            number
        }
        return numbers.first() in 1..223 && numbers.first() != 127
    }
}
