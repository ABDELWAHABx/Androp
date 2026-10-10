package app.androp.android.utils

/** Event-driven publication: no clock/ticker runs when the visible dashboard is unchanged. */
class DashboardPublicationPolicy(private val progressIntervalMs: Long = 1_000L) {
    private var published: SyncDashboardState? = null
    private var publishedAt = 0L

    /** null = unchanged; zero = immediate; positive = coalesce progress until this deadline. */
    fun delayMillis(state: SyncDashboardState, nowMs: Long): Long? {
        val next = visible(state)
        val previous = published ?: return 0L
        if (previous == next) return null
        if (material(previous) != material(next)) return 0L
        return (progressIntervalMs - (nowMs - publishedAt).coerceAtLeast(0L)).coerceAtLeast(0L)
    }

    fun didPublish(state: SyncDashboardState, nowMs: Long) {
        published = visible(state)
        publishedAt = nowMs
    }

    fun invalidate() { published = null }

    private fun material(state: SyncDashboardState) =
        state.copy(transfers = state.transfers.map { it.copy(percent = 0) })

    private fun visible(state: SyncDashboardState): SyncDashboardState {
        if (!state.shouldShow) return SyncDashboardState()
        // Owner teardown and battery/connection callbacks must not repost the static paused card.
        if (state.paused) return SyncDashboardState(paused = true)
        return state.copy(
            owners = if (state.owners.isEmpty()) emptySet() else setOf("foreground"),
            ownerStatuses = if (state.transfers.isNotEmpty()) emptyMap() else state.ownerStatuses - "sync",
            battery = state.battery.takeIf { state.transport != null },
            charging = state.transport != null && state.charging,
            cancelledTransfers = emptySet()
        )
    }
}
