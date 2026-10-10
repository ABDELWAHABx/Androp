package app.androp.android.utils.discovery

import android.content.Context
import app.androp.android.utils.DiscoveredDevice
import app.androp.android.utils.DiscoveryMode
import kotlinx.coroutines.flow.StateFlow

enum class DiscoverySource {
    MDNS,
    UDP
}

interface DiscoveryBackend {
    val discoveredDevices: StateFlow<List<DiscoveredDevice>>
    fun start(context: Context)
    fun stop(context: Context)
    fun broadcastPresence(context: Context)
    fun setMode(mode: DiscoveryMode)
}
