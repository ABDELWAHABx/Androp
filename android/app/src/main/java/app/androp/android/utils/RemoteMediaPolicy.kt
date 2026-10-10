package app.androp.android.utils

/** Small, platform-independent rules for publishing a real remote media session. */
object RemoteMediaPolicy {
    fun hasSession(isPlaying: Boolean, title: String, artist: String): Boolean =
        isPlaying || listOf(title, artist).any {
            val text = it.trim()
            text.isNotEmpty() && text != "?" && !text.equals("Nothing Playing", ignoreCase = true)
        }

    fun playbackSpeed(isPlaying: Boolean, rate: Double): Float = when {
        !isPlaying -> 0f
        !rate.isFinite() || rate <= 0.0 -> 1f
        else -> rate.coerceAtMost(8.0).toFloat()
    }

    fun boundPosition(positionMs: Long, durationMs: Long): Long =
        positionMs.coerceAtLeast(0).let { if (durationMs > 0) it.coerceAtMost(durationMs) else it }

    fun projectPosition(positionMs: Long, sinceReportMs: Long, isPlaying: Boolean,
                        rate: Double, durationMs: Long): Long {
        val base = boundPosition(positionMs, durationMs)
        val advance = if (isPlaying && sinceReportMs in 1..30_000) {
            (sinceReportMs * playbackSpeed(true, rate)).toLong()
        } else 0L
        return boundPosition(base + advance.coerceAtMost(Long.MAX_VALUE - base), durationMs)
    }

    /** Local monotonic session timestamps have no remote clock-skew limit. */
    fun projectLocalPosition(positionMs: Long, sinceUpdateMs: Long, isPlaying: Boolean,
                             rate: Double, durationMs: Long): Long {
        val base = boundPosition(positionMs, durationMs)
        val advance = if (isPlaying) {
            (sinceUpdateMs.coerceAtLeast(0L).toDouble() * playbackSpeed(true, rate)).toLong()
        } else 0L
        return boundPosition(base + advance.coerceAtMost(Long.MAX_VALUE - base), durationMs)
    }
}
