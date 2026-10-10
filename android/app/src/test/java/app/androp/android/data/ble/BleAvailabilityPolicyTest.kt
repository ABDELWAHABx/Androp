package app.androp.android.data.ble

import org.junit.Assert.*
import org.junit.Test

class BleAvailabilityPolicyTest {
    @Test fun wifiAppearingAndDisappearingNeverDisablesAvailableBluetooth() {
        val base = BleAvailabilityPolicy.Inputs(true, false, false, false, "paired-key")
        assertTrue(BleAvailabilityPolicy.shouldRun(base))
        assertTrue(BleAvailabilityPolicy.shouldRun(base.copy(networkConnected = true)))
        assertTrue(BleAvailabilityPolicy.shouldRun(base.copy(networkConnected = false)))
    }
    @Test fun pauseManualDisconnectAndOptOutOverrideBothNetworkStates() {
        for (network in listOf(false, true)) {
            val ready = BleAvailabilityPolicy.Inputs(true, false, false, network, "paired-key")
            assertFalse(BleAvailabilityPolicy.shouldRun(ready.copy(paused = true)))
            assertFalse(BleAvailabilityPolicy.shouldRun(ready.copy(manuallyDisconnected = true)))
            assertFalse(BleAvailabilityPolicy.shouldRun(ready.copy(enabled = false)))
        }
    }
    @Test fun unpairedOrForgottenDevicesDoNotAdvertise() {
        val ready = BleAvailabilityPolicy.Inputs(true, false, false, true, "paired-key")
        for (key in listOf(null, "", " ")) assertFalse(BleAvailabilityPolicy.shouldRun(ready.copy(pairingKey = key)))
    }
    @Test fun networkOnlyTeardownPreservesBluetoothButUserDisconnectAndPauseDoNot() {
        assertTrue(BleAvailabilityPolicy.keepBleOnNetworkDisconnect(false, false, true))
        assertFalse(BleAvailabilityPolicy.keepBleOnNetworkDisconnect(true, false, true))
        assertFalse(BleAvailabilityPolicy.keepBleOnNetworkDisconnect(false, true, true))
        assertFalse(BleAvailabilityPolicy.keepBleOnNetworkDisconnect(false, false, false))
    }
}
