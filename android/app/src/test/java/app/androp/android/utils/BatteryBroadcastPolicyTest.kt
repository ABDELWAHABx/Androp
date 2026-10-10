package app.androp.android.utils

import org.junit.Assert.*
import org.junit.Test

class BatteryBroadcastPolicyTest {
    private val state = BatteryBroadcastPolicy.State(80, false, true)

    @Test fun unchangedBatteryDuringMediaPlaybackDoesNotWakeCompanionApp() {
        val policy = BatteryBroadcastPolicy()
        assertTrue(policy.shouldPublish(state))
        policy.didPublish(state)
        repeat(3_600) { assertFalse(policy.shouldPublish(state)) }
    }

    @Test fun batteryChangesDisconnectAndReconnectPublishImmediately() {
        val policy = BatteryBroadcastPolicy()
        policy.didPublish(state)
        assertTrue(policy.shouldPublish(state.copy(level = 79)))
        assertTrue(policy.shouldPublish(state.copy(charging = true)))
        val disconnected = BatteryBroadcastPolicy.State(-1, false, false)
        assertTrue(policy.shouldPublish(disconnected))
        policy.didPublish(disconnected)
        assertTrue(policy.shouldPublish(state))
    }

    @Test fun explicitRequestsAndReenablingCanRefreshUnchangedState() {
        val policy = BatteryBroadcastPolicy()
        policy.didPublish(state)
        assertTrue(policy.shouldPublish(state, force = true))
        policy.reset()
        assertTrue(policy.shouldPublish(state))
    }
}
