package app.androp.android.data.ble

import org.junit.Assert.*
import org.junit.Test

class BleNetworkUpgradePolicyTest {
    @Test fun allowsPrivateHotspotAndLanAddressesWithValidPorts() {
        for (ip in listOf("192.168.43.2", "192.168.1.254", "10.0.0.2", "172.16.0.2", "172.31.255.2", "10.1.2.0", "172.16.1.255")) {
            assertTrue(ip, BleNetworkUpgradePolicy.isValidEndpoint(ip, 6997))
            assertTrue(ip, BleNetworkUpgradePolicy.isValidEndpoint(ip, 65535))
        }
    }
    @Test fun rejectsPublicLoopbackMulticastAndBroadcastDestinations() {
        for (ip in listOf("8.8.8.8", "127.0.0.1", "0.0.0.0", "224.0.0.1", "255.255.255.255",
            "169.254.1.2", "172.15.0.2", "172.32.0.2"))
            assertFalse(ip, BleNetworkUpgradePolicy.isValidEndpoint(ip, 6997))
    }
    @Test fun rejectsUrlsHostnamesAlternateNumericFormatsAndInvalidPorts() {
        for (ip in listOf("localhost", "http://192.168.1.2", "192.168.1.2/path", "user@192.168.1.2", "[::1]",
            "192.168.1.2:6997", "192.168.001.2", "192.168.1.256", "192.168.1", " 192.168.1.2", "0xC0.168.1.2"))
            assertFalse(ip, BleNetworkUpgradePolicy.isValidEndpoint(ip, 6997))
        for (port in listOf(-1, 0, 65536, Int.MAX_VALUE)) assertFalse(BleNetworkUpgradePolicy.isValidEndpoint("192.168.1.2", port))
    }
    @Test fun failedNetworkAttemptCannotHideAuthenticatedBluetoothButPauseOverridesBoth() {
        assertTrue(BleAvailabilityPolicy.connectedForUi(false, true, false))
        assertTrue(BleAvailabilityPolicy.connectedForUi(true, false, false))
        assertFalse(BleAvailabilityPolicy.connectedForUi(false, false, false))
        assertFalse(BleAvailabilityPolicy.connectedForUi(true, true, true))
    }
}
