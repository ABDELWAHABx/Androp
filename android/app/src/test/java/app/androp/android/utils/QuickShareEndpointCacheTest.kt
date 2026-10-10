package app.androp.android.utils

import org.junit.Assert.*
import org.junit.Test

class QuickShareEndpointCacheTest {
    @Test fun currentSocketCanAdvertiseItsReadyListener() {
        val cache = QuickShareEndpointCache()
        cache.begin(1)
        assertEquals(QuickShareEndpointCache.Advertisement(true, 54321), cache.update(1, true, 54321))
    }
    @Test fun newSocketClearsOldPortAndRejectsLateOldAdvertisement() {
        val cache = QuickShareEndpointCache()
        cache.begin(1); cache.update(1, true, 54321)
        assertEquals(QuickShareEndpointCache.Advertisement(), cache.begin(2))
        assertNull(cache.update(1, true, 55555))
        assertEquals(QuickShareEndpointCache.Advertisement(true, 1234), cache.update(2, true, 1234))
    }
    @Test fun missingPortClearsStoppedListenerWithoutPretendingLegacySupport() {
        val cache = QuickShareEndpointCache()
        cache.begin(1); cache.update(1, true, 54321)
        assertEquals(QuickShareEndpointCache.Advertisement(true, null), cache.update(1, true, null))
    }
    @Test fun legacyMacWithoutCapabilityRemainsDiscoverableViaNsd() {
        val cache = QuickShareEndpointCache(); cache.begin(1)
        assertEquals(QuickShareEndpointCache.Advertisement(), cache.update(1, false, null))
    }
    @Test fun malformedPortsNeverBecomeConnectionTargets() {
        val cache = QuickShareEndpointCache(); cache.begin(1)
        for (port in listOf(-1, 0, 65536, Int.MAX_VALUE, 80.5, "54321", 54321L)) {
            assertEquals(QuickShareEndpointCache.Advertisement(true, null), cache.update(1, true, port))
        }
    }
    @Test fun disconnectClearsEndpointImmediately() {
        val cache = QuickShareEndpointCache(); cache.begin(1); cache.update(1, true, 54321)
        assertEquals(QuickShareEndpointCache.Advertisement(), cache.clear())
    }
}
