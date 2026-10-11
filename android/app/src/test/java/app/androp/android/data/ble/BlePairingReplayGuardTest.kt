package app.androp.android.data.ble

import org.junit.Assert.*
import org.junit.Test

class BlePairingReplayGuardTest {
    @Test fun permitsIdempotentRetryOnlyOnCurrentConnection() {
        val guard = BlePairingReplayGuard()
        assertTrue(guard.accepts("challenge-one"))
        guard.record("challenge-one")
        assertTrue(guard.accepts("challenge-one"))
        assertFalse(guard.accepts("challenge-two"))
        guard.disconnected()
        assertFalse(guard.accepts("challenge-one"))
        assertTrue(guard.accepts("challenge-two"))
    }
    @Test fun boundsChallengesOverWholeQrWindow() {
        val guard = BlePairingReplayGuard()
        for (index in 0 until 32) {
            assertTrue(guard.accepts("challenge-$index"))
            guard.record("challenge-$index")
            guard.disconnected()
        }
        assertFalse(guard.accepts("challenge-32"))
        assertFalse(guard.accepts("challenge-0"))
    }
}
