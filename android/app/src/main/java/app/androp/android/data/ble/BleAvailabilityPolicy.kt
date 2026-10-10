package app.androp.android.data.ble

/** Wi-Fi adds capacity; it must never evict the paired Bluetooth control link. */
object BleAvailabilityPolicy {
    data class Inputs(val enabled: Boolean, val manuallyDisconnected: Boolean, val paused: Boolean,
        val networkConnected: Boolean, val pairingKey: String?)
    fun shouldRun(inputs: Inputs): Boolean = inputs.enabled && !inputs.manuallyDisconnected &&
        !inputs.paused && !inputs.pairingKey.isNullOrBlank()
    fun connectedForUi(networkConnected: Boolean, bleAuthenticated: Boolean, paused: Boolean): Boolean =
        !paused && (networkConnected || bleAuthenticated)
    fun keepBleOnNetworkDisconnect(manual: Boolean, paused: Boolean, authenticated: Boolean): Boolean =
        !manual && !paused && authenticated
}
