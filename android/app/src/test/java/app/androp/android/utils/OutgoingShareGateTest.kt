package app.androp.android.utils

import org.junit.Assert.*
import org.junit.Test

class OutgoingShareGateTest {
    @Test fun bleOnlyWaitsAndSamePeerWifiBecomesReady() {
        val gate = OutgoingShareGate("paired")
        assertEquals(OutgoingShareGate.Decision.WAIT, gate.evaluate("paired", false, false, null))
        assertEquals(OutgoingShareGate.Decision.READY, gate.evaluate("paired", false, false, "192.168.1.2"))
        assertTrue(gate.claim("paired", false, false, "192.168.1.2"))
    }
    @Test fun duplicateNetworkCallbacksCannotSendTwice() {
        val gate = OutgoingShareGate("paired")
        assertTrue(gate.claim("paired", false, false, "192.168.1.2"))
        assertFalse(gate.claim("paired", false, false, "192.168.1.2"))
    }
    @Test fun cancellationBeforeWifiNeverSendsLater() {
        val gate = OutgoingShareGate("paired")
        gate.cancel()
        assertFalse(gate.claim("paired", false, false, "192.168.1.2"))
    }
    @Test fun pausePermanentlyInvalidatesPendingRequestEvenAfterResume() {
        val gate = OutgoingShareGate("paired")
        assertEquals(OutgoingShareGate.Decision.STOP, gate.evaluate("paired", true, false, null))
        assertFalse(gate.claim("paired", false, false, "192.168.1.2"))
    }
    @Test fun switchingPairedMacCannotRedirectSelectedFiles() {
        val gate = OutgoingShareGate("paired")
        assertEquals(OutgoingShareGate.Decision.STOP, gate.evaluate("other", false, false, "192.168.1.2"))
        assertFalse(gate.claim("paired", false, false, "192.168.1.2"))
    }
    @Test fun manualDisconnectInvalidatesPendingRequest() {
        val gate = OutgoingShareGate("paired")
        assertEquals(OutgoingShareGate.Decision.STOP, gate.evaluate("paired", false, true, null))
        assertFalse(gate.claim("paired", false, false, "192.168.1.2"))
    }
    @Test fun unpairedOrUnauthenticatedNetworkCannotStartTransfer() {
        assertFalse(OutgoingShareGate("").claim("", false, false, "192.168.1.2"))
        assertFalse(OutgoingShareGate("paired").claim("paired", false, false, null))
    }
    @Test fun concurrentReadyCallbacksHaveOnlyOneWinner() {
        val gate = OutgoingShareGate("paired")
        val wins = java.util.concurrent.atomic.AtomicInteger()
        val threads = List(16) { Thread { if (gate.claim("paired", false, false, "192.168.1.2")) wins.incrementAndGet() } }
        threads.forEach { it.start() }; threads.forEach { it.join() }
        assertEquals(1, wins.get())
    }
    @Test fun oldWifiReconnectionCannotSendBeforeMacConfirmsTransferNetwork() {
        val gate = OutgoingShareGate("paired")
        assertEquals(OutgoingShareGate.Decision.WAIT,
            gate.evaluate("paired", false, false, "192.168.1.2", setupConfirmed = false))
        assertFalse(gate.claim("paired", false, false, "192.168.1.2", setupConfirmed = false))
        assertTrue(gate.claim("paired", false, false, "192.168.1.2", setupConfirmed = true))
    }
    @Test fun macConfirmationAloneCannotSendBeforeAuthenticatedWifi() {
        val gate = OutgoingShareGate("paired")
        assertFalse(gate.claim("paired", false, false, null, setupConfirmed = true))
        assertTrue(gate.claim("paired", false, false, "192.168.1.2", setupConfirmed = true))
    }
}
