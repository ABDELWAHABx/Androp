package app.androp.android.utils

import org.junit.Assert.*
import org.junit.Test

class RemotePlaybackPublicationPolicyTest {
    private val playing = RemotePlaybackSnapshot(true, 0, 1f, 123L, 0)

    @Test fun continuousAccurateReportsUseSystemInterpolationWithoutBinderUpdates() {
        for (seconds in 1..3_600) {
            val next = playing.copy(positionMs = seconds * 1_000L, updatedAtMs = seconds * 1_000L)
            assertFalse(RemotePlaybackPublicationPolicy.shouldPublish(playing, next, 0))
        }
    }

    @Test fun initialSessionAndChangedControlsPublishImmediately() {
        assertTrue(RemotePlaybackPublicationPolicy.shouldPublish(null, playing, 0))
        assertTrue(RemotePlaybackPublicationPolicy.shouldPublish(playing, playing.copy(playing = false, speed = 0f), 0))
        assertTrue(RemotePlaybackPublicationPolicy.shouldPublish(playing, playing.copy(speed = 2f), 0))
        assertTrue(RemotePlaybackPublicationPolicy.shouldPublish(playing, playing.copy(actions = 456), 0))
    }

    @Test fun seekAndLargeClockCorrectionsPublishButSmallJitterDoesNot() {
        assertFalse(RemotePlaybackPublicationPolicy.shouldPublish(playing, playing.copy(positionMs = 10_500, updatedAtMs = 10_000), 0))
        assertTrue(RemotePlaybackPublicationPolicy.shouldPublish(playing, playing.copy(positionMs = 5_000, updatedAtMs = 10_000), 0))
        assertTrue(RemotePlaybackPublicationPolicy.shouldPublish(playing, playing.copy(positionMs = 20_000, updatedAtMs = 10_000), 0))
    }

    @Test fun unchangedPausedStateDoesNotPublish() {
        val paused = playing.copy(playing = false, speed = 0f)
        assertFalse(RemotePlaybackPublicationPolicy.shouldPublish(paused, paused.copy(updatedAtMs = 900_000), 0))
    }

    @Test fun localProjectionDoesNotFreezeAfterThirtySeconds() {
        assertEquals(95_000L, RemoteMediaPolicy.projectLocalPosition(5_000, 90_000, true, 1.0, 0))
        assertEquals(50_000L, RemoteMediaPolicy.projectLocalPosition(5_000, 90_000, true, 1.0, 50_000))
        assertEquals(5_000L, RemoteMediaPolicy.projectLocalPosition(5_000, 90_000, false, 1.0, 0))
    }

    @Test fun projectionHandlesMalformedRateAndOverflow() {
        assertEquals(100L, RemoteMediaPolicy.projectLocalPosition(50, 50, true, Double.NaN, 0))
        assertEquals(Long.MAX_VALUE, RemoteMediaPolicy.projectLocalPosition(Long.MAX_VALUE - 1, Long.MAX_VALUE, true, 8.0, 0))
        assertEquals(50L, RemoteMediaPolicy.projectLocalPosition(50, -1, true, 1.0, 0))
    }
}
