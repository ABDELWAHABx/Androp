package app.androp.android.utils

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ConnectionEndpointsTest {
    @Test fun invalidPortsNeverReachSocketCreation() {
        for (port in listOf(-1, 0, 65536, Int.MAX_VALUE))
            assertTrue(ConnectionEndpoints.hosts("192.168.1.1", port).isEmpty())
    }
    @Test fun malformedSavedHostDoesNotDiscardValidAlternatives() {
        assertEquals(listOf("192.168.1.2"), ConnectionEndpoints.hosts("http://evil,192.168.1.2, bad/path, user@host, host?query,192.168.1.2", 6997))
    }
    @Test fun ipv6AndWhitespaceAreCanonicalized() {
        assertEquals(listOf("::1", "192.168.1.2"), ConnectionEndpoints.hosts(" [::1], ::1, 192.168.1.2 ", 6997))
    }
    @Test fun invalidIpv4AndScopedIpv6AreRejected() {
        assertTrue(ConnectionEndpoints.hosts("999.999.999.999,fe80::1%en0", 6997).isEmpty())
    }
    @Test fun parallelAttemptsHaveAFiniteLimit() {
        assertEquals(16, ConnectionEndpoints.hosts((1..100).joinToString(",") { "192.168.1.$it" }, 6997).size)
    }
    @Test fun oversizedInputIsRejectedBeforeAllocationOfAttempts() {
        assertTrue(ConnectionEndpoints.hosts("a".repeat(4097), 6997).isEmpty())
    }
}
