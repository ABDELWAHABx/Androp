package app.androp.android.utils.discovery

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MdnsEndpointPolicyTest {
    private fun explicit(value: String, host: String = "fe80::1234", port: Int = 6997) =
        MdnsEndpointPolicy.addresses(value.toByteArray(), true, host, port)

    @Test fun boundIpv4OverridesUnreachableBonjourIpv6() {
        assertEquals(setOf("192.168.1.25", "10.0.0.8"), explicit("192.168.1.25,10.0.0.8"))
    }
    @Test fun missingExplicitListPreservesLegacyHost() {
        assertEquals(setOf("192.168.1.25"), MdnsEndpointPolicy.addresses(null, false, "192.168.1.25", 6997))
        assertEquals(setOf("fd12::1"), MdnsEndpointPolicy.addresses(null, false, "fd12::1", 6997))
    }
    @Test fun emptyOrMissingExplicitValueNeverFallsBack() {
        assertTrue(explicit("").isEmpty())
        assertTrue(MdnsEndpointPolicy.addresses(null, true, "192.168.1.25", 6997).isEmpty())
    }
    @Test fun oneMalformedEntryRejectsTheWholeAdvertisedList() {
        for (bad in listOf("example.com", "10.0.0.999", "01.2.3.4", "10.0.0.2:6997", "10.0.0.2/socket", "::1", "", " 10.0.0.2")) {
            assertTrue(bad, explicit("192.168.1.25,$bad").isEmpty())
        }
    }
    @Test fun wildcardLoopbackAndMulticastCannotBecomeRemoteMacAddresses() {
        for (bad in listOf("0.0.0.0", "127.0.0.1", "224.1.2.3", "255.255.255.255")) {
            assertTrue(explicit(bad).isEmpty())
        }
    }
    @Test fun countAndByteLimitsAreEnforcedBeforeConnecting() {
        assertEquals(16, explicit((1..16).joinToString(",") { "10.0.0.$it" }).size)
        assertTrue(explicit((1..17).joinToString(",") { "10.0.0.$it" }).isEmpty())
        assertTrue(explicit("1".repeat(256)).isEmpty())
    }
    @Test fun invalidUtf8AndPortNeverReachSocketCreation() {
        assertTrue(MdnsEndpointPolicy.addresses(byteArrayOf(-1), true, "192.168.1.25", 6997).isEmpty())
        for (port in listOf(0, -1, 65536)) assertTrue(explicit("192.168.1.25", port = port).isEmpty())
    }
    @Test fun repeatedAddressesAreDeduplicatedWithoutAddingHost() {
        assertEquals(setOf("10.0.0.2"), explicit("10.0.0.2,10.0.0.2", host = "192.168.1.99"))
    }
}
