package app.androp.android.utils

/** Battery consumers need transitions, not a broadcast for every media position packet. */
class BatteryBroadcastPolicy {
    data class State(val level: Int, val charging: Boolean, val connected: Boolean)
    private var published: State? = null

    fun shouldPublish(state: State, force: Boolean = false) = force || state != published
    fun didPublish(state: State) { published = state }
    fun reset() { published = null }
}
