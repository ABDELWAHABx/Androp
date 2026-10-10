package app.androp.android

import app.androp.android.utils.BoundedValueCache
import org.junit.Assert.*
import org.junit.Test

class NotificationSendCacheTest {
    @Test fun identicalBodiesFromDifferentNotificationsAreNotDropped() {
        val cache = BoundedValueCache<String, String>(8)
        cache.remember("notification-A", "Download complete")
        assertFalse(cache.matches("notification-B", "Download complete"))
        assertTrue(cache.matches("notification-A", "Download complete"))
    }

    @Test fun updatesAndDismissalPermitAnotherSend() {
        val cache = BoundedValueCache<String, String>(8)
        cache.remember("download", "progress=10")
        assertFalse(cache.matches("download", "progress=20"))
        cache.remove("download")
        assertFalse(cache.matches("download", "progress=10"))
    }

    @Test fun historyIsBoundedAndPauseClearsIt() {
        val cache = BoundedValueCache<String, String>(2)
        cache.remember("one", "body")
        cache.remember("two", "body")
        cache.remember("three", "body")
        assertFalse(cache.matches("one", "body"))
        cache.clear()
        assertFalse(cache.matches("three", "body"))
    }
}
