package app.androp.android.utils

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.net.InetAddress

class LocalSocketRoutingTest {
    private fun ip(value: String) = InetAddress.getByName(value).address
    private fun route(index: Int, host: String, prefix: Int) =
        LocalSocketRouting.Candidate(index, prefix, ip(host))

    @Test fun selectsAttachedWifiWhileCellularIsDefault() {
        assertEquals(1, LocalSocketRouting.select(ip("192.168.4.20"), listOf(
            route(0, "10.0.0.2", 8), route(1, "192.168.4.5", 24)
        ), false))
    }
    @Test fun vpnNeverGetsBypassedEvenWithMatchingWifi() {
        assertNull(LocalSocketRouting.select(ip("192.168.4.20"), listOf(route(1, "192.168.4.5", 24)), true))
    }
    @Test fun unrelatedWifiAndDefaultRouteCannotCaptureRemotePeer() {
        assertNull(LocalSocketRouting.select(ip("10.5.1.2"), listOf(
            route(1, "192.168.4.5", 24), route(2, "0.0.0.0", 0)
        ), false))
    }
    @Test fun moreSpecificAttachedNetworkWins() {
        assertEquals(2, LocalSocketRouting.select(ip("10.5.1.2"), listOf(
            route(1, "10.0.0.1", 8), route(2, "10.5.1.3", 24)
        ), false))
    }
    @Test fun partialByteSubnetBoundaryIsRespected() {
        val routes = listOf(route(1, "172.20.0.1", 20))
        assertEquals(1, LocalSocketRouting.select(ip("172.20.15.254"), routes, false))
        assertNull(LocalSocketRouting.select(ip("172.20.16.1"), routes, false))
    }
    @Test fun ipv6RoutingKeepsAddressFamiliesSeparate() {
        val routes = listOf(route(1, "192.168.4.5", 24), route(2, "fd12:3456::1", 64))
        assertEquals(2, LocalSocketRouting.select(ip("fd12:3456::2"), routes, false))
        assertNull(LocalSocketRouting.select(ip("fd12:3457::2"), routes, false))
    }
}
