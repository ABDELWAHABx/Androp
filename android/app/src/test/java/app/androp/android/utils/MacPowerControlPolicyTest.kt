package app.androp.android.utils

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MacPowerControlPolicyTest {
    @Test fun unknownOrOpenLidNeverOffersSleep() {
        assertFalse(MacPowerControlPolicy.canSleep(null, true, false))
        assertFalse(MacPowerControlPolicy.canSleep(false, true, false))
        assertTrue(MacPowerControlPolicy.canSleep(true, true, false))
    }

    @Test fun pausedAndDisconnectedConnectionsCannotSendSleep() {
        assertFalse(MacPowerControlPolicy.canSleep(true, true, true))
        assertFalse(MacPowerControlPolicy.canSleep(true, false, false))
    }

    @Test fun queuedRequestWithoutMatchingReportedStateIsUnconfirmed() {
        assertFalse(MacPowerControlPolicy.toggleConfirmed(true, null))
        assertFalse(MacPowerControlPolicy.toggleConfirmed(true, false))
        assertTrue(MacPowerControlPolicy.toggleConfirmed(true, true))
        assertTrue(MacPowerControlPolicy.toggleConfirmed(false, false))
    }
}
