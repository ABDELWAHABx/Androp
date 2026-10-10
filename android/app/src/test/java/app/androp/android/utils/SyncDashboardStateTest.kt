package app.androp.android.utils

import org.junit.Assert.*
import org.junit.Test

class SyncDashboardStateTest {
    @Test fun transferServiceStoppingKeepsOtherForegroundOwner() {
        val state = SyncDashboardState(owners = setOf("sync", "receive", "send"))
            .withProgress("1", "photo.jpg", 42, false)
            .withProgress("2", "archive.zip", 11, true)
        val released = state.release("receive")
        assertEquals(setOf("sync", "send"), released.owners)
        assertTrue(released.shouldShow)
        assertEquals(listOf("archive.zip"), released.transfers.map { it.name })
    }

    @Test fun pausedNotificationSurvivesAllServicesStoppingWithoutWork() {
        val paused = SyncDashboardState(owners = setOf("sync", "send"), phoneAlert = true,
            link = "https://private.example", lastEvent = "Clipboard sent")
            .withProgress("1", "private.txt", 55, true).pause().release("send").release("sync")
        assertTrue(paused.shouldShow)
        assertTrue(paused.paused)
        assertTrue(paused.owners.isEmpty())
        assertTrue(paused.transfers.isEmpty())
        assertFalse(paused.phoneAlert)
        assertNull(paused.link)
        assertNull(paused.lastEvent)
        assertSame(paused, paused.withProgress("late", "late.txt", 90, false))
    }

    @Test fun byteProgressWithinSameBucketDoesNotTriggerShadeUpdates() {
        val initial = SyncDashboardState(owners = setOf("send")).withProgress("1", "movie.mp4", 20, true)
        for (percent in 21..29) assertSame(initial, initial.withProgress("1", "movie.mp4", percent, true))
        assertEquals(30, initial.withProgress("1", "movie.mp4", 30, true).transfers.single().percent)
    }

    @Test fun bluetoothTransportAndBatteryAreVisibleInOneConnectionRow() {
        val state = SyncDashboardState(device = "My Mac", transport = "Bluetooth", battery = 83, charging = true)
        assertEquals("My Mac · Bluetooth · 83% · Charging", state.connectionLine)
    }

    @Test fun stoppingQuickShareKeepsWebSocketTransferVisible() {
        val state = SyncDashboardState(owners = setOf("sync", "receive"))
            .withProgress("ws-file", "document.pdf", 20, false, "ws")
            .withProgress("quick-file", "photo.jpg", 20, false)
        assertEquals(listOf("ws-file"), state.release("receive").transfers.map { it.id })
    }
    @Test fun pausedAndDiscoveryOnlyNotificationsNeverRequestLivePromotion() {
        assertFalse(SyncDashboardState(owners = setOf("sync"), reconnecting = true).shouldRequestPromotion)
        assertFalse(SyncDashboardState(paused = true, phoneAlert = true, transport = "Wi-Fi").shouldRequestPromotion)
        assertTrue(SyncDashboardState(transport = "Bluetooth").shouldRequestPromotion)
        assertTrue(SyncDashboardState(phoneAlert = true).shouldRequestPromotion)
        assertTrue(SyncDashboardState().withProgress("1", "file", 50, true).shouldRequestPromotion)
    }

    @Test fun lateTransferCallbacksCannotRestoreCancelledProgress() {
        val cancelled = SyncDashboardState(owners = setOf("send"))
            .withProgress("1", "file", 40, true).cancelTransfer("1", true)
        assertTrue(cancelled.transfers.isEmpty())
        assertEquals("Transfer cancelled", cancelled.lastEvent)
        assertSame(cancelled, cancelled.withProgress("1", "file", 60, true))
    }

}
