package app.androp.android.data.ble

/** A paired BLE peer may propose one local socket, never a URL or public host. */
object BleNetworkUpgradePolicy {
    const val MAX_MESSAGE_BYTES = 1024
    fun isValidEndpoint(ip: String, port: Int): Boolean {
        if (port !in 1..65535 || ip.length !in 7..15) return false
        val parts = ip.split('.')
        if (parts.size != 4) return false
        val bytes = parts.map { part ->
            if (part.isEmpty() || part.length > 3 || part.any { it !in '0'..'9' } ||
                (part.length > 1 && part[0] == '0')) return false
            part.toIntOrNull()?.takeIf { it in 0..255 } ?: return false
        }
        return bytes[0] == 10 || (bytes[0] == 172 && bytes[1] in 16..31) ||
            (bytes[0] == 192 && bytes[1] == 168)
    }
}
