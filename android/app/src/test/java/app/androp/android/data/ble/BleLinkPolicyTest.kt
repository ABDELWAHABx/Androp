package app.androp.android.data.ble

import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseSettings
import org.junit.Assert.*
import org.junit.Test

class BleLinkPolicyTest {
    @Test fun advertisesFastAfterStartOrLostLinkThenSettlesToLowPower() {
        val fastUntil = 10_000L + BleLinkPolicy.FAST_ADVERTISE_MS
        assertEquals(BleLinkPolicy.AdvertiseSpeed.FAST, BleLinkPolicy.advertiseSpeed(10_000L, fastUntil, pairing = false))
        assertEquals(BleLinkPolicy.AdvertiseSpeed.LOW_POWER, BleLinkPolicy.advertiseSpeed(fastUntil, fastUntil, pairing = false))
        assertEquals(BleLinkPolicy.AdvertiseSpeed.LOW_POWER, BleLinkPolicy.advertiseSpeed(5_000L, 0L, pairing = false))
    }

    @Test fun visibleQrCodeAlwaysUsesTheQuickestAdvertising() {
        assertEquals(BleLinkPolicy.AdvertiseSpeed.PAIRING, BleLinkPolicy.advertiseSpeed(99_999L, 0L, pairing = true))
        assertEquals(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY, BleLinkPolicy.advertiseMode(BleLinkPolicy.AdvertiseSpeed.PAIRING))
        assertEquals(AdvertiseSettings.ADVERTISE_MODE_BALANCED, BleLinkPolicy.advertiseMode(BleLinkPolicy.AdvertiseSpeed.FAST))
        assertEquals(AdvertiseSettings.ADVERTISE_MODE_LOW_POWER, BleLinkPolicy.advertiseMode(BleLinkPolicy.AdvertiseSpeed.LOW_POWER))
    }

    @Test fun temporaryAdvertisingFailuresRetryForeverWithBoundedBackoff() {
        assertTrue(BleLinkPolicy.shouldRetryAdvertising(AdvertiseCallback.ADVERTISE_FAILED_TOO_MANY_ADVERTISERS))
        assertTrue(BleLinkPolicy.shouldRetryAdvertising(AdvertiseCallback.ADVERTISE_FAILED_INTERNAL_ERROR))
        assertFalse(BleLinkPolicy.shouldRetryAdvertising(AdvertiseCallback.ADVERTISE_FAILED_FEATURE_UNSUPPORTED))
        val delays = (1..8).map { BleLinkPolicy.advertiseRetryDelayMs(it) }
        assertEquals(2_000L, delays.first())
        assertEquals(delays, delays.sorted())
        assertEquals(60_000L, delays.last())
    }

    @Test fun serviceSetupKeepsRetryingSlowlyInsteadOfGivingUp() {
        assertEquals(2_000L, BleLinkPolicy.serviceSetupRetryDelayMs(0))
        assertEquals(2_000L, BleLinkPolicy.serviceSetupRetryDelayMs(4))
        assertEquals(60_000L, BleLinkPolicy.serviceSetupRetryDelayMs(5))
        assertEquals(60_000L, BleLinkPolicy.serviceSetupRetryDelayMs(500))
    }

    @Test fun onlyAMacThatSendsHeartbeatsIsJudgedSilent() {
        val limit = BleLinkPolicy.PEER_SILENCE_LIMIT_MS
        assertFalse(BleLinkPolicy.peerIsSilent(heartbeatSeen = false, lastActivityMs = 0L, nowMs = limit * 10))
        assertFalse(BleLinkPolicy.peerIsSilent(heartbeatSeen = true, lastActivityMs = 1_000L, nowMs = 1_000L + limit))
        assertTrue(BleLinkPolicy.peerIsSilent(heartbeatSeen = true, lastActivityMs = 1_000L, nowMs = 1_001L + limit))
        // The Mac gives up after four 20-second ticks; the phone must wait clearly longer.
        assertTrue(limit >= 2 * 4 * 20_000L)
    }
}
