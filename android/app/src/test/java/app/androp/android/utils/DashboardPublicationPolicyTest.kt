package app.androp.android.utils

import org.junit.Assert.*
import org.junit.Test

class DashboardPublicationPolicyTest {
    private val initial = SyncDashboardState(owners = setOf("send", "sync"), transport = "Network")
        .withProgress("movie", "movie.mp4", 0, true)

    @Test fun unchangedStateNeverRepostsEvenAfterHours() {
        val policy = DashboardPublicationPolicy()
        policy.didPublish(initial, 0)
        repeat(10_000) { assertNull(policy.delayMillis(initial, it * 1_000L)) }
    }

    @Test fun progressBurstHasOneDeadlineAndPublishesLatestState() {
        val policy = DashboardPublicationPolicy()
        policy.didPublish(initial, 0)
        var latest = initial
        for (percent in 1..99) {
            latest = latest.withProgress("movie", "movie.mp4", percent, true)
            val wait = policy.delayMillis(latest, percent.toLong())
            if (percent < 10) assertNull(wait) else assertEquals(1_000L - percent, wait)
        }
        assertEquals(0L, policy.delayMillis(latest, 1_000))
        policy.didPublish(latest, 1_000)
        assertNull(policy.delayMillis(latest, 1_001))
        assertEquals(90, latest.transfers.single().percent)
    }

    @Test fun sustainedProgressCannotPostMoreThanOncePerSecond() {
        val policy = DashboardPublicationPolicy()
        var posts = 0
        for (millis in 0L..10_000L step 10) {
            val state = initial.copy(transfers = initial.transfers.map { it.copy(percent = ((millis / 10) % 100).toInt()) })
            if (policy.delayMillis(state, millis) == 0L) {
                posts++
                policy.didPublish(state, millis)
            }
        }
        assertTrue("Bounded posts, got $posts", posts <= 11)
    }

    @Test fun actionsAndMaterialChangesPublishWithoutWaitingForProgress() {
        val policy = DashboardPublicationPolicy()
        policy.didPublish(initial, 0)
        listOf(initial.pause(), initial.copy(transport = null),
            initial.copy(consents = listOf(DashboardConsent("request", "Mac", "photo"))),
            initial.copy(phoneAlert = true), initial.copy(transfers = emptyList(), lastEvent = "Sent"),
            initial.cancelTransfer("movie", true),
            initial.withProgress("second", "second.txt", 0, true)).forEach {
            assertEquals(0L, policy.delayMillis(it, 1))
        }
    }

    @Test fun pausedTeardownAndBatteryCallbacksDoNotRepost() {
        val policy = DashboardPublicationPolicy()
        val paused = initial.pause()
        policy.didPublish(paused, 0)
        assertNull(policy.delayMillis(paused.release("send").release("sync"), 1))
        assertNull(policy.delayMillis(paused.copy(battery = 76, charging = true), 2))
    }

    @Test fun internalBookkeepingAndHiddenBatteryDoNotRepost() {
        val policy = DashboardPublicationPolicy()
        val disconnected = SyncDashboardState(owners = setOf("sync"))
        policy.didPublish(disconnected, 0)
        assertNull(policy.delayMillis(disconnected.copy(battery = 30, charging = true,
            cancelledTransfers = setOf("true:old"), ownerStatuses = mapOf("sync" to "Idle")), 1))
    }

    @Test fun explicitRefreshCanRestoreDismissedOrNewlyPermittedCard() {
        val policy = DashboardPublicationPolicy()
        policy.didPublish(initial, 0)
        policy.invalidate()
        assertEquals(0L, policy.delayMillis(initial, 1))
    }

    @Test fun progressPreservesTheVisibleFileAndItsCancelTarget() {
        var state = initial.withProgress("second", "second.txt", 0, true)
        for (percent in 10..90 step 10) {
            state = state.withProgress("movie", "movie.mp4", percent, true)
            assertEquals(listOf("movie", "second"), state.transfers.map { it.id })
            assertEquals("movie", state.transfers.first().id)
        }
    }
}
