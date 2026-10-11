package app.androp.android.utils

import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.TetheringManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import org.json.JSONObject
import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * On-demand internet-tethering requests. Never polls or creates a local-only hotspot.
 *
 * Hotspot state is read from the sticky Wi-Fi AP broadcast (works for ordinary apps on
 * every Android version) instead of TetheringEventCallback, whose interface list is
 * redacted for non-system apps and previously left the Mac stuck on "waiting".
 */
object HotspotControlManager {
    private const val AP_STATE_ACTION = "android.net.wifi.WIFI_AP_STATE_CHANGED"
    private const val AP_STATE_EXTRA = "wifi_state"
    private const val AP_DISABLING = 10
    private const val AP_DISABLED = 11
    private const val AP_ENABLING = 12
    private const val AP_ENABLED = 13
    private const val AP_FAILED = 14

    private val main = Handler(Looper.getMainLooper())
    private var pending: Observation? = null
    private val completed = linkedMapOf<String, Pair<Long, String>>()

    fun handle(context: Context, data: JSONObject) {
        val id = data.optString("id").takeIf { it.isNotBlank() && it.length <= 128 } ?: return
        val action = data.optString("action")
        if (action !in setOf("status", "enable", "disable", "setup")) return
        val application = context.applicationContext
        main.post {
            if (BackgroundWorkController.isPaused) return@post
            val now = android.os.SystemClock.elapsedRealtime()
            completed.entries.removeAll { now - it.value.first > 60_000 }
            completed["$action:$id"]?.let { deliver(it.second); return@post }
            if (pending?.id == id && pending?.action == action) return@post
            val current = isHotspotOn(application)
            when (action) {
                "status" -> {
                    // Answer immediately; there is nothing to wait for.
                    reply(application, id, action, "ready", null, current)
                    return@post
                }
                "setup" -> {
                    SyncDashboardController.hotspotSetup(setupPrompt(application))
                    reply(application, id, action, "ready", "Check your phone's notification.", current)
                    return@post
                }
            }
            val wantOn = action == "enable"
            if (current == wantOn) {
                if (wantOn) SyncDashboardController.hotspotSetup(null)
                reply(application, id, action, if (wantOn) "enabled" else "disabled", null, current)
                return@post
            }
            if (pending != null) {
                reply(application, id, action, "busy", "Already working on it.", current)
                return@post
            }
            if (Build.VERSION.SDK_INT < 36 || !canWrite(application)) {
                // Can't switch it automatically: put a one-tap action in the notification.
                SyncDashboardController.hotspotSetup(if (Build.VERSION.SDK_INT >= 36) "permission" else "hotspot")
                reply(application, id, action, if (Build.VERSION.SDK_INT >= 36) "permissionRequired" else "unsupported",
                    "Turn on Hotspot on your phone.", current)
                return@post
            }
            if (wantOn && dataSaverEnabled(application) == true) {
                SyncDashboardController.hotspotSetup("dataSaver")
                reply(application, id, action, "dataSaverEnabled", "Turn off Data Saver on your phone.", current)
                return@post
            }
            try {
                val observation = Observation(application, id, action)
                pending = observation
                observation.start()
            } catch (_: RuntimeException) {
                pending = null
                reply(application, id, action, "failed", "Turn on Hotspot on your phone.", current)
            } catch (_: LinkageError) {
                pending = null
                SyncDashboardController.hotspotSetup("hotspot")
                reply(application, id, action, "unsupported", "Turn on Hotspot on your phone.", current)
            }
        }
    }

    /** Pause cancels observation, not a hotspot the user explicitly enabled. */
    fun stopObserving() { main.post { if (Build.VERSION.SDK_INT >= 36) pending?.close() } }

    private fun canWrite(context: Context) = runCatching { Settings.System.canWrite(context) }.getOrDefault(false)

    private fun setupPrompt(context: Context) = when {
        Build.VERSION.SDK_INT >= 36 && !canWrite(context) -> "permission"
        dataSaverEnabled(context) == true -> "dataSaver"
        else -> "hotspot"
    }

    fun dataSaverEnabled(context: Context): Boolean? = runCatching {
        when (context.getSystemService(ConnectivityManager::class.java).restrictBackgroundStatus) {
            ConnectivityManager.RESTRICT_BACKGROUND_STATUS_DISABLED -> false
            ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED,
            ConnectivityManager.RESTRICT_BACKGROUND_STATUS_WHITELISTED -> true
            else -> null
        }
    }.getOrNull()

    /** Sticky AP broadcast first; a soft-AP interface with an address as fallback. */
    fun isHotspotOn(context: Context): Boolean? {
        val sticky = runCatching {
            ContextCompat.registerReceiver(context, null, IntentFilter(AP_STATE_ACTION), ContextCompat.RECEIVER_NOT_EXPORTED)
        }.getOrNull()
        when (sticky?.getIntExtra(AP_STATE_EXTRA, -1)) {
            AP_ENABLED -> return true
            AP_DISABLED, AP_FAILED -> return softApInterfaceUp()
        }
        return softApInterfaceUp().takeIf { it } ?: sticky?.let { false }
    }

    private fun softApInterfaceUp(): Boolean = runCatching {
        NetworkInterface.getNetworkInterfaces()?.toList().orEmpty().any { nif ->
            val name = nif.name.lowercase()
            (name.startsWith("swlan") || name.startsWith("ap") || name.startsWith("softap")) &&
                nif.isUp && nif.inetAddresses.toList().any { it is Inet4Address && !it.isLoopbackAddress }
        }
    }.getOrDefault(false)

    private fun reply(context: Context, id: String, action: String, status: String,
                      message: String?, enabled: Boolean?, error: Int? = null) {
        if (BackgroundWorkController.isPaused) return
        val supported = Build.VERSION.SDK_INT >= 36
        val writeGranted = canWrite(context)
        val data = JSONObject().put("id", id).put("action", action).put("status", status)
            .put("message", message ?: "").put("apiSupported", supported)
            .put("writeSettingsGranted", writeGranted)
            .put("dataSaverEnabled", dataSaverEnabled(context) ?: JSONObject.NULL)
            .put("hotspotEnabled", enabled ?: JSONObject.NULL)
            .put("canAttemptControl", supported && writeGranted && status != "unsupported")
        error?.let { data.put("errorCode", it) }
        val envelope = JSONObject().put("type", "phoneHotspotState").put("data", data).toString()
        if (status != "requesting" && status != "busy") {
            completed["$action:$id"] = android.os.SystemClock.elapsedRealtime() to envelope
            while (completed.size > 16) completed.remove(completed.keys.first())
        }
        deliver(envelope)
    }

    /**
     * Turning Hotspot on drops the phone's own Wi-Fi on most phones, and the socket with it,
     * so an answer sent only over Wi-Fi was often lost and the Mac waited for nothing.
     * Bluetooth survives the switch: send over it whenever it is up, and over Wi-Fi too while
     * that socket is open. The Mac matches answers by request ID, so a second copy is ignored.
     */
    private fun deliver(envelope: String) {
        val message = runCatching { JSONObject(envelope) }.getOrNull() ?: return
        val viaBluetooth = app.androp.android.data.ble.BleTransportBridge.sendControl(
            message.optString("type"), message.optJSONObject("data") ?: JSONObject())
        if (!viaBluetooth || WebSocketUtil.isWifiConnected()) WebSocketUtil.sendMessage(envelope)
    }

    /**
     * The phone's own "Connect Mac" button: ask the paired Mac to run its Connect, which turns
     * Hotspot on (or waits for you to) and joins it with the Mac's saved password.
     * Returns false when no Mac is connected to ask.
     */
    fun askMacToConnect(): Boolean {
        if (BackgroundWorkController.isPaused) return false
        val data = JSONObject().put("id", java.util.UUID.randomUUID().toString())
        val envelope = JSONObject().put("type", "phoneHotspotOffer").put("data", data).toString()
        val viaBluetooth = app.androp.android.data.ble.BleTransportBridge.sendControl("phoneHotspotOffer", data)
        val viaWifi = WebSocketUtil.isWifiConnected() && WebSocketUtil.sendMessage(envelope)
        return viaBluetooth || viaWifi
    }

    @RequiresApi(36)
    private class Observation(val context: Context, val id: String, val action: String) {
        private val manager = context.getSystemService(TetheringManager::class.java)
        private val wantOn = action == "enable"
        private var receiver: BroadcastReceiver? = null
        private var closed = false
        private var accepted = false
        private val timeout = Runnable {
            // The platform accepted the request but never broadcast a final state:
            // trust the acceptance rather than leaving the Mac guessing.
            if (accepted) finish(if (wantOn) "enabled" else "disabled", null, wantOn)
            else finish("unknown", "Turn on Hotspot on your phone.", isHotspotOn(context))
        }
        private val graceAfterAccept = Runnable { if (accepted) confirm(isHotspotOn(context) ?: wantOn) }

        @SuppressLint("MissingPermission") // WRITE_SETTINGS is checked; platform denial is reported.
        fun start() {
            try {
                if (manager == null) {
                    SyncDashboardController.hotspotSetup("hotspot")
                    finish("unsupported", "Turn on Hotspot on your phone.", isHotspotOn(context))
                    return
                }
                main.postDelayed(timeout, 15_000)
                receiver = object : BroadcastReceiver() {
                    override fun onReceive(c: Context, intent: Intent) {
                        if (closed) return
                        when (intent.getIntExtra(AP_STATE_EXTRA, -1)) {
                            AP_ENABLED -> confirm(true)
                            AP_DISABLED -> confirm(false)
                            AP_FAILED -> if (wantOn) finish("failed", "Your phone couldn't start Hotspot.", false)
                            AP_ENABLING, AP_DISABLING -> Unit
                        }
                    }
                }.also {
                    ContextCompat.registerReceiver(context, it, IntentFilter(AP_STATE_ACTION), ContextCompat.RECEIVER_NOT_EXPORTED)
                }
                reply(context, id, action, "requesting", null, isHotspotOn(context))
                val request = TetheringManager.TetheringRequest.Builder(TetheringManager.TETHERING_WIFI).build()
                if (wantOn) {
                    manager.startTethering(request, context.mainExecutor, object : TetheringManager.StartTetheringCallback {
                        override fun onTetheringStarted() { onAccepted() }
                        override fun onTetheringFailed(error: Int) { failure(error) }
                    })
                } else {
                    manager.stopTethering(request, context.mainExecutor, object : TetheringManager.StopTetheringCallback {
                        override fun onStopTetheringSucceeded() { onAccepted() }
                        override fun onStopTetheringFailed(error: Int) { failure(error) }
                    })
                }
            } catch (_: SecurityException) {
                SyncDashboardController.hotspotSetup("hotspot")
                finish("unsupported", "Turn on Hotspot on your phone.", isHotspotOn(context))
            } catch (_: RuntimeException) {
                finish("failed", "Turn on Hotspot on your phone.", isHotspotOn(context))
            } catch (_: LinkageError) {
                // Some vendor builds ship API 36 with an older tethering Mainline module.
                SyncDashboardController.hotspotSetup("hotspot")
                finish("unsupported", "Turn on Hotspot on your phone.", isHotspotOn(context))
            }
        }

        private fun onAccepted() {
            if (closed) return
            accepted = true
            if (isHotspotOn(context) == wantOn) confirm(wantOn) else main.postDelayed(graceAfterAccept, 4_000)
        }

        private fun confirm(on: Boolean) {
            if (closed) return
            if (on == wantOn) finish(if (on) "enabled" else "disabled", null, on)
        }

        private fun failure(error: Int) {
            if (closed) return
            when (error) {
                TetheringManager.TETHER_ERROR_NO_CHANGE_TETHERING_PERMISSION,
                TetheringManager.TETHER_ERROR_NO_ACCESS_TETHERING_PERMISSION -> {
                    SyncDashboardController.hotspotSetup("hotspot")
                    finish("unsupported", "Turn on Hotspot on your phone.", isHotspotOn(context), error)
                }
                TetheringManager.TETHER_ERROR_PROVISIONING_FAILED,
                TetheringManager.TETHER_ERROR_ENTITLEMENT_UNKNOWN ->
                    finish("failed", "Your carrier blocked Hotspot.", isHotspotOn(context), error)
                TetheringManager.TETHER_ERROR_UNKNOWN_REQUEST ->
                    finish("failed", "Turn off Hotspot on your phone.", isHotspotOn(context), error)
                else -> finish("failed", "Your phone couldn't change Hotspot.", isHotspotOn(context), error)
            }
        }

        private fun finish(status: String, message: String?, enabled: Boolean?, error: Int? = null) {
            if (closed) return
            if (status == "enabled" || status == "disabled") SyncDashboardController.hotspotSetup(null)
            reply(context, id, action, status, message, enabled, error)
            close()
        }

        fun close() {
            if (closed) return
            closed = true
            main.removeCallbacks(timeout)
            main.removeCallbacks(graceAfterAccept)
            receiver?.let { runCatching { context.unregisterReceiver(it) } }
            receiver = null
            if (pending === this) pending = null
        }
    }
}
