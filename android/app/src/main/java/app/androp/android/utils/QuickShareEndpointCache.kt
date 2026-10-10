package app.androp.android.utils

/** Endpoint advertisements belong to a socket generation, never a remembered device name. */
internal class QuickShareEndpointCache {
    data class Advertisement(val supported: Boolean = false, val port: Int? = null)
    private var epoch: Long? = null
    private var value = Advertisement()

    fun begin(epoch: Long): Advertisement {
        this.epoch = epoch
        value = Advertisement()
        return value
    }

    fun clear(): Advertisement { value = Advertisement(); return value }

    fun update(epoch: Long, supported: Boolean, rawPort: Any?): Advertisement? {
        if (this.epoch != epoch) return null
        // JSON integer only: reject strings, fractional numbers, zero and overflow.
        val port = (rawPort as? Int)?.takeIf { it in 1..65535 }
        value = Advertisement(supported || port != null, port)
        return value
    }
}
