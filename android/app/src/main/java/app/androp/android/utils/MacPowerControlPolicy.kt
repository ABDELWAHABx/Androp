package app.androp.android.utils

/** Unknown or legacy status never grants permission to show a sleep action. */
object MacPowerControlPolicy {
    fun canSleep(lidClosed: Boolean?, connected: Boolean, paused: Boolean): Boolean =
        lidClosed == true && connected && !paused

    fun toggleConfirmed(requested: Boolean, reported: Boolean?): Boolean =
        reported != null && requested == reported
}
