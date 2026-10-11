package app.androp.android.utils

/** One explicit share request can authorize at most one service handoff. */
internal class OutgoingShareGate(private val pairedKey: String) {
    enum class Decision { WAIT, READY, STOP }
    private var consumed = false
    private var cancelled = false

    @Synchronized fun evaluate(currentKey: String?, paused: Boolean, manuallyDisconnected: Boolean,
                               authenticatedAddress: String?, setupConfirmed: Boolean = true): Decision {
        if (consumed || cancelled || pairedKey.isBlank() || currentKey != pairedKey || paused || manuallyDisconnected) {
            cancelled = true
            return Decision.STOP
        }
        return if (authenticatedAddress.isNullOrBlank() || !setupConfirmed) Decision.WAIT else Decision.READY
    }

    @Synchronized fun claim(currentKey: String?, paused: Boolean, manuallyDisconnected: Boolean,
                            authenticatedAddress: String?, setupConfirmed: Boolean = true): Boolean {
        if (evaluate(currentKey, paused, manuallyDisconnected, authenticatedAddress, setupConfirmed) != Decision.READY) return false
        consumed = true
        return true
    }

    @Synchronized fun cancel() { cancelled = true }

    companion object {
        /** Route marker for a selection that goes over the Bluetooth file lane instead of a network address. */
        const val BLUETOOTH_LANE = "bluetooth-lane"
    }
}
