package app.androp.android.data.ble

/** A reconnect gets a fresh challenge; captured proof cannot move to another BLE connection. */
internal class BlePairingReplayGuard {
    private val used = mutableSetOf<String>()
    private var activeNonce: String? = null
    @Synchronized fun accepts(nonce: String): Boolean =
        nonce == activeNonce || (activeNonce == null && nonce !in used && used.size < 32)
    @Synchronized fun record(nonce: String) {
        if (accepts(nonce)) { activeNonce = nonce; used.add(nonce) }
    }
    @Synchronized fun disconnected() { activeNonce = null }
}
