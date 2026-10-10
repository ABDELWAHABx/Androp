package app.androp.android.utils

/** Limits on the encrypted, paired-peer transfer-network protocol. */
object TransferNetworkPolicy {
    const val MAX_MESSAGE_BYTES = 8 * 1024
    const val STARTUP_TIMEOUT_MS = 30_000L
    const val IDLE_TIMEOUT_MS = 90_000L
    private val uuid = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
    fun accepts(version: Int, id: String, action: String, bytes: Int): Boolean =
        version == 1 && uuid.matches(id) && bytes in 1..MAX_MESSAGE_BYTES &&
            action in setOf("start", "ready", "error", "stop", "keepAlive", "request", "connected")

    fun allowsNetworkControl(action: String, matchingLease: Boolean, authenticatedWifi: Boolean): Boolean =
        matchingLease && authenticatedWifi && action in setOf("keepAlive", "stop", "error", "connected")

    fun acceptsConnected(phoneInitiated: Boolean): Boolean = phoneInitiated

    fun validCredentials(ssid: String, password: String): Boolean =
        ssid.toByteArray(Charsets.UTF_8).size in 1..32 && ssid.none { it.isISOControl() } &&
            password.length in 8..63 && password.all { it.code in 32..126 }
}
