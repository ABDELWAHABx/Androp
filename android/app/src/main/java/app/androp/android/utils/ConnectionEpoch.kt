package app.androp.android.utils

import java.util.concurrent.atomic.AtomicLong

/** Rejects callbacks from sockets created before pause, disconnect, or a newer connection. */
internal class ConnectionEpoch {
    private val value = AtomicLong(0)
    fun advance(): Long = value.incrementAndGet()
    fun isCurrent(epoch: Long): Boolean = value.get() == epoch
}
