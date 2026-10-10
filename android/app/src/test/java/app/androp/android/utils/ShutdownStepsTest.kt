package app.androp.android.utils

import org.junit.Assert.assertEquals
import org.junit.Test

class ShutdownStepsTest {
    @Test fun rejectedPlatformCleanupStillStopsRemainingBatteryWork() {
        val stopped = mutableListOf<String>()
        val failed = mutableListOf<String>()
        runShutdownSteps(listOf(
            "listener" to { throw SecurityException("permission revoked") },
            "socket" to { stopped += "socket" },
            "service" to { throw IllegalStateException("already stopped") },
            "timer" to { stopped += "timer" }
        )) { name, _ -> failed += name }
        assertEquals(listOf("socket", "timer"), stopped)
        assertEquals(listOf("listener", "service"), failed)
    }
}
