package app.androp.android.utils

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteMediaPolicyTest {
    @Test fun emptyAndPlaceholderMetadataDoNotCreateNativePlayer() {
        assertFalse(RemoteMediaPolicy.hasSession(false, "", ""))
        assertFalse(RemoteMediaPolicy.hasSession(false, " ? ", "Nothing Playing"))
        assertTrue(RemoteMediaPolicy.hasSession(false, "Paused track", ""))
        assertTrue(RemoteMediaPolicy.hasSession(true, "", ""))
    }

    @Test fun nativeProgressProjectsPlayingSourceAndStopsWhenPaused() {
        assertEquals(12_000L, RemoteMediaPolicy.projectPosition(10_000, 2_000, true, 1.0, 60_000))
        assertEquals(10_000L, RemoteMediaPolicy.projectPosition(10_000, 2_000, false, 1.0, 60_000))
        assertEquals(11_000L, RemoteMediaPolicy.projectPosition(10_000, 2_000, true, 0.5, 60_000))
        assertEquals(0f, RemoteMediaPolicy.playbackSpeed(false, 1.0), 0f)
    }

    @Test fun malformedClockAndRateCannotOverflowOrAdvanceBeyondDuration() {
        assertEquals(60_000L, RemoteMediaPolicy.projectPosition(59_000, 2_000, true, 1.0, 60_000))
        assertEquals(10_000L, RemoteMediaPolicy.projectPosition(10_000, -5_000, true, 1.0, 60_000))
        assertEquals(10_000L, RemoteMediaPolicy.projectPosition(10_000, 31_000, true, 1.0, 60_000))
        assertEquals(1f, RemoteMediaPolicy.playbackSpeed(true, Double.NaN), 0f)
        assertEquals(1f, RemoteMediaPolicy.playbackSpeed(true, Double.POSITIVE_INFINITY), 0f)
        assertEquals(Long.MAX_VALUE, RemoteMediaPolicy.projectPosition(Long.MAX_VALUE, 2_000, true, 1.0, 0))
        assertEquals(0L, RemoteMediaPolicy.boundPosition(-1, 60_000))
        assertEquals(60_000L, RemoteMediaPolicy.boundPosition(90_000, 60_000))
    }
}
