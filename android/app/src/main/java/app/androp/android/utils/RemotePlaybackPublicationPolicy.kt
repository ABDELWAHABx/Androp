package app.androp.android.utils

data class RemotePlaybackSnapshot(
    val playing: Boolean,
    val positionMs: Long,
    val speed: Float,
    val actions: Long,
    val updatedAtMs: Long
)

/** MediaSession clients interpolate progress themselves; only meaningful corrections need IPC. */
object RemotePlaybackPublicationPolicy {
    fun shouldPublish(previous: RemotePlaybackSnapshot?, next: RemotePlaybackSnapshot,
                      durationMs: Long): Boolean {
        if (previous == null || previous.playing != next.playing || previous.speed != next.speed ||
            previous.actions != next.actions) return true
        val expected = RemoteMediaPolicy.projectLocalPosition(previous.positionMs,
            (next.updatedAtMs - previous.updatedAtMs).coerceAtLeast(0L), previous.playing,
            previous.speed.toDouble(), durationMs)
        val difference = maxOf(expected, next.positionMs) - minOf(expected, next.positionMs)
        return difference >= 1_500L
    }
}
