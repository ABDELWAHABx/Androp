package app.androp.android.quickshare

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.util.Base64
import android.util.Log
import java.net.InetAddress
import java.nio.charset.StandardCharsets

class QuickShareDiscovery(private val context: Context) {
    companion object {
        private const val TAG = "QuickShareDiscovery"
        private const val SERVICE_TYPE = "_FC9F5ED42C8A._tcp."

        fun decodeDeviceName(endpointInfoBase64: String): String? {
            return try {
                val bytes = Base64.decode(
                    endpointInfoBase64,
                    Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING
                )
                if (bytes.size < 18) return null
                val nameLen = bytes[17].toInt() and 0xFF
                if (bytes.size < 18 + nameLen) return null
                String(bytes, 18, nameLen, StandardCharsets.UTF_8)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to decode endpoint info", e)
                null
            }
        }
    }

    data class ResolvedHost(val host: InetAddress, val port: Int, val deviceName: String)

    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    @Volatile
    private var generation = 0
    private val infoCallbacks = java.util.concurrent.ConcurrentHashMap.newKeySet<NsdManager.ServiceInfoCallback>()
    private var discoveryListener: NsdManager.DiscoveryListener? = null

    @Synchronized
    fun start(targetDeviceName: String, onFound: (ResolvedHost) -> Unit) {
        stop()

        if (app.androp.android.utils.BackgroundWorkController.isPaused) return
        val currentGeneration = generation
        val normalizedTarget = targetDeviceName.replace("’", "'").lowercase()

        discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {
                if (generation != currentGeneration || app.androp.android.utils.BackgroundWorkController.isPaused) {
                    runCatching { nsdManager.stopServiceDiscovery(this) }
                    return
                }
                Log.d(TAG, "Discovery started")
            }

            override fun onServiceFound(service: NsdServiceInfo) {
                Log.d(TAG, "Service found: ${service.serviceName}")
                if (generation == currentGeneration) resolve(service, normalizedTarget, onFound, currentGeneration)
            }

            override fun onServiceLost(service: NsdServiceInfo) {
                Log.d(TAG, "Service lost: ${service.serviceName}")
            }

            override fun onDiscoveryStopped(serviceType: String) {
                Log.d(TAG, "Discovery stopped")
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e(TAG, "Start discovery failed: $errorCode")
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e(TAG, "Stop discovery failed: $errorCode")
            }
        }

        try {
            nsdManager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start discovery", e)
        }
    }

    @Synchronized
    private fun resolve(
        service: NsdServiceInfo,
        normalizedTarget: String,
        onFound: (ResolvedHost) -> Unit,
        currentGeneration: Int
    ) {
        if (generation != currentGeneration) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val callback = object : NsdManager.ServiceInfoCallback {
                override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {
                    infoCallbacks.remove(this)
                    Log.e(TAG, "Resolve registration failed: $errorCode")
                }
                override fun onServiceUpdated(info: NsdServiceInfo) {
                    if (generation == currentGeneration && !app.androp.android.utils.BackgroundWorkController.isPaused) {
                        handleResolved(info, normalizedTarget, onFound)
                    }
                    infoCallbacks.remove(this)
                    runCatching { nsdManager.unregisterServiceInfoCallback(this) }
                }
                override fun onServiceLost() {
                    infoCallbacks.remove(this)
                    runCatching { nsdManager.unregisterServiceInfoCallback(this) }
                }
                override fun onServiceInfoCallbackUnregistered() { infoCallbacks.remove(this) }
            }
            infoCallbacks.add(callback)
            try {
                nsdManager.registerServiceInfoCallback(service, context.mainExecutor, callback)
            } catch (e: Exception) {
                infoCallbacks.remove(callback)
                Log.w(TAG, "Cannot resolve Quick Share service", e)
            }
        } else {
            @Suppress("DEPRECATION")
            nsdManager.resolveService(service, object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                    Log.e(TAG, "Resolve failed: $errorCode")
                }

                override fun onServiceResolved(info: NsdServiceInfo) {
                    if (generation == currentGeneration && !app.androp.android.utils.BackgroundWorkController.isPaused) {
                        handleResolved(info, normalizedTarget, onFound)
                    }
                }
            })
        }
    }

    private fun handleResolved(
        info: NsdServiceInfo,
        normalizedTarget: String,
        onFound: (ResolvedHost) -> Unit
    ) {
        val endpointInfoBytes = info.attributes["n"] ?: return
        val endpointInfoBase64 = String(endpointInfoBytes, StandardCharsets.UTF_8)
        val deviceName = decodeDeviceName(endpointInfoBase64) ?: return
        val normalizedFound = deviceName.replace("’", "'").lowercase()

        Log.d(TAG, "Resolved '$deviceName' at ${info.host}:${info.port}")

        if (normalizedFound == normalizedTarget) {
            val host = info.host ?: return
            onFound(ResolvedHost(host, info.port, deviceName))
        }
    }

    @Synchronized
    fun stop() {
        generation++
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            infoCallbacks.toList().forEach { runCatching { nsdManager.unregisterServiceInfoCallback(it) } }
        }
        infoCallbacks.clear()
        discoveryListener?.let {
            try {
                nsdManager.stopServiceDiscovery(it)
            } catch (e: Exception) {
                // Ignore
            }
        }
        discoveryListener = null
    }
}
