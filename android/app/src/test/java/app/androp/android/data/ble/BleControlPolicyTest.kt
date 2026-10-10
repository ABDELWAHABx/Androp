package app.androp.android.data.ble

import org.junit.Assert.*
import org.junit.Test

class BleControlPolicyTest {
    @Test fun controlsWorkInBothDirections() {
        for (type in listOf("status", "mediaControl", "volumeControl", "callControl", "phoneHotspotControl", "notificationAction"))
            assertTrue(type, BleControlPolicy.acceptsIncoming(type, 300))
        for (type in listOf("macMediaControl", "phoneHotspotState", "mediaControlResponse", "call_event"))
            assertTrue(type, BleControlPolicy.acceptsOutgoing(type, 300))
    }
    @Test fun networkOnlyAndUnknownCommandsNeverEnterBleControl() {
        for (type in listOf("fileChunk", "fileTransferInit", "browseLs", "device", "requestWebDavAccess", "unknown")) {
            assertFalse(BleControlPolicy.acceptsIncoming(type, 200))
            assertFalse(BleControlPolicy.acceptsOutgoing(type, 200))
        }
    }
    @Test fun utf8EnvelopeLimitsRejectOversizedControlTraffic() {
        assertTrue(BleControlPolicy.acceptsIncoming("mediaControl", 65536))
        assertFalse(BleControlPolicy.acceptsIncoming("mediaControl", 65537))
        assertFalse(BleControlPolicy.acceptsOutgoing("macMediaControl", 0))
    }
    @Test fun keyboardAndButtonsWorkButCursorStreamStaysOnNetwork() {
        for (action in listOf("type", "keypress", "arrow_up", "vol_set", "lock_screen")) assertTrue(BleControlPolicy.acceptsRemoteAction(action))
        for (action in listOf("mouse_move", "mouse_click", "mouse_scroll", "unknown")) assertFalse(BleControlPolicy.acceptsRemoteAction(action))
    }
    @Test fun explicitClipboardWaitAllowsAllRetriesInsteadOfTimingOutAtFirstRetry() {
        for (bytes in listOf(1, 1024, 65536)) {
            val retry = BleControlPolicy.clipboardRetryMillis(bytes, false)
            assertTrue(retry in 8_000L..60_000L)
            assertTrue(BleControlPolicy.clipboardWaitMillis(bytes, false) > retry * 3)
        }
        assertEquals(4_000L, BleControlPolicy.clipboardRetryMillis(65536, true))
        assertTrue(BleControlPolicy.clipboardRetryMillis(1, false) < BleControlPolicy.clipboardRetryMillis(65536, false))
    }
}
