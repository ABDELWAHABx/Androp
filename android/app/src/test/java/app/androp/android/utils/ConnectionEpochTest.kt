package app.androp.android.utils

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

class ConnectionEpochTest {
    @Test
    fun delayedSocketOpenCannotReviveConnectionAfterPauseAndResume() {
        val epochs = ConnectionEpoch()
        val oldAttempt = epochs.advance()
        val callbackReady = CountDownLatch(1)
        val callbackAllowed = CountDownLatch(1)
        val callbackFinished = CountDownLatch(1)
        val staleConnected = AtomicBoolean(false)
        val callback = thread {
            callbackReady.countDown()
            callbackAllowed.await()
            if (epochs.isCurrent(oldAttempt)) staleConnected.set(true)
            callbackFinished.countDown()
        }
        assertTrue(callbackReady.await(2, TimeUnit.SECONDS))
        epochs.advance() // Pause/disconnect invalidates already queued callbacks.
        val resumedAttempt = epochs.advance()
        callbackAllowed.countDown()
        assertTrue(callbackFinished.await(2, TimeUnit.SECONDS))
        callback.join()
        assertFalse(staleConnected.get())
        assertTrue(epochs.isCurrent(resumedAttempt))
    }

    @Test
    fun failureFromPreviousRetryCannotResetNewerConnection() {
        val epochs = ConnectionEpoch()
        val timedOutAttempt = epochs.advance()
        epochs.advance() // Global timeout cancels all parallel socket attempts.
        val nextAttempt = epochs.advance()
        val connected = AtomicBoolean(true)
        if (epochs.isCurrent(timedOutAttempt)) connected.set(false)
        assertTrue(connected.get())
        assertTrue(epochs.isCurrent(nextAttempt))
    }
}
