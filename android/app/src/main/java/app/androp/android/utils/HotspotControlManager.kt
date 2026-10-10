package app.androp.android.utils

import android.annotation.SuppressLint
import android.content.Context
import android.net.ConnectivityManager
import android.net.TetheringInterface
import android.net.TetheringManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.annotation.RequiresApi
import org.json.JSONObject

/** On-demand internet-tethering requests. Never polls or creates a local-only hotspot. */
object HotspotControlManager {
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
            completed["$action:$id"]?.let { WebSocketUtil.sendMessage(it.second); return@post }
            if (Build.VERSION.SDK_INT >= 36 && pending?.id == id && pending?.action == action) return@post
            if (pending != null) {
                reply(application, id, action, "busy", "Another hotspot request is still pending.")
                return@post
            }
            if (action == "setup") {
                SyncDashboardController.hotspotSetup(when {
                    Build.VERSION.SDK_INT >= 36 && !canWrite(application) -> "permission"
                    dataSaverEnabled(application) == true -> "dataSaver"
                    else -> "hotspot"
                })
                reply(application, id, action, "ready", "Tap the hotspot setup action in your phone's androp notification, or open androp Settings → Connection → Hotspot. Some firmware blocks automatic control even after permission is granted.")
                return@post
            }
            if (Build.VERSION.SDK_INT < 36) {
                reply(application, id, action, "unsupported", "Remote hotspot control requires Android 16. Use phone Hotspot settings on this version.")
                return@post
            }
            if (action != "status" && !canWrite(application)) {
                SyncDashboardController.hotspotSetup("permission")
                reply(application, id, action, "permissionRequired", "On your phone, open androp Settings → Connection → Hotspot and allow Modify system settings once. Firmware or carrier restrictions can still prevent remote control.")
                return@post
            }
            if (action == "enable" && dataSaverEnabled(application) != false) {
                SyncDashboardController.hotspotSetup("dataSaver")
                reply(application, id, action, "dataSaverEnabled", "Turn off Data Saver using the action in your phone's androp notification, then retry. Android does not offer a normal permission for androp to change it automatically.")
                return@post
            }
            try {
                val observation = Observation(application, id, action)
                pending = observation
                observation.start()
            } catch (_: RuntimeException) {
                reply(application, id, action, "failed", "Android could not initialize hotspot control.")
            } catch (_: LinkageError) {
                reply(application, id, action, "unsupported", "This phone's tethering module does not support remote control.")
            }
        }
    }

    /** Pause cancels observation, not a hotspot the user explicitly enabled. */
    fun stopObserving() { main.post { if (Build.VERSION.SDK_INT >= 36) pending?.close() } }

    private fun canWrite(context: Context) = runCatching { Settings.System.canWrite(context) }.getOrDefault(false)

    fun dataSaverEnabled(context: Context): Boolean? = runCatching {
        when (context.getSystemService(ConnectivityManager::class.java).restrictBackgroundStatus) {
            ConnectivityManager.RESTRICT_BACKGROUND_STATUS_DISABLED -> false
            ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED,
            ConnectivityManager.RESTRICT_BACKGROUND_STATUS_WHITELISTED -> true
            else -> null
        }
    }.getOrNull()

    private fun reply(context: Context, id: String, action: String, status: String,
                      message: String, enabled: Boolean? = null, error: Int? = null) {
        if (BackgroundWorkController.isPaused) return
        val supported = Build.VERSION.SDK_INT >= 36
        val writeGranted = canWrite(context)
        val data = JSONObject().put("id", id).put("action", action).put("status", status)
            .put("message", message).put("apiSupported", supported)
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
        WebSocketUtil.sendMessage(envelope)
    }

    @RequiresApi(36)
    private class Observation(val context: Context, val id: String, val action: String) {
        private val manager = context.getSystemService(TetheringManager::class.java)
        private var registered = false
        private var closed = false
        private var accepted = false
        private var enabled: Boolean? = null
        private val timeout = Runnable {
            finish("unknown", "The phone did not confirm the hotspot state. Check phone Hotspot settings before retrying.")
        }
        private val events = object : TetheringManager.TetheringEventCallback {
            override fun onTetheredInterfacesChanged(interfaces: MutableSet<TetheringInterface>) {
                if (closed) return
                enabled = interfaces.any { it.type == TetheringManager.TETHERING_WIFI }
                completeIfConfirmed()
            }
        }

        @SuppressLint("MissingPermission") // WRITE_SETTINGS is checked; platform denial is reported.
        fun start() {
            try {
                if (manager == null) {
                    finish("unsupported", "This phone does not expose the tethering service.")
                    return
                }
                main.postDelayed(timeout, 20_000)
                manager.registerTetheringEventCallback(context.mainExecutor, events)
                registered = true
                if (action == "status") return
                reply(context, id, action, "requesting", "Waiting for the phone to confirm hotspot ${if (action == "enable") "activation" else "shutdown"}.")
                val request = TetheringManager.TetheringRequest.Builder(TetheringManager.TETHERING_WIFI).build()
                if (action == "enable") {
                    manager.startTethering(request, context.mainExecutor, object : TetheringManager.StartTetheringCallback {
                        override fun onTetheringStarted() { if (!closed) { accepted = true; completeIfConfirmed() } }
                        override fun onTetheringFailed(error: Int) { failure(error) }
                    })
                } else {
                    manager.stopTethering(request, context.mainExecutor, object : TetheringManager.StopTetheringCallback {
                        override fun onStopTetheringSucceeded() { if (!closed) { accepted = true; completeIfConfirmed() } }
                        override fun onStopTetheringFailed(error: Int) { failure(error) }
                    })
                }
            } catch (_: SecurityException) {
                finish("unsupported", "This phone's firmware or carrier blocks hotspot control by ordinary apps. Use phone Hotspot settings.")
            } catch (_: RuntimeException) {
                finish("failed", "Android could not process the hotspot request. Check phone Hotspot settings.")
            } catch (_: LinkageError) {
                // Some vendor builds ship API 36 with an older tethering Mainline module.
                finish("unsupported", "This phone's tethering module does not support remote control. Use phone Hotspot settings.")
            }
        }

        private fun completeIfConfirmed() {
            val current = enabled ?: return
            if (action == "status") {
                finish("ready", if (current) "Phone internet tethering is active." else "Phone internet tethering is off.")
            } else if (accepted && current == (action == "enable")) {
                finish(if (current) "enabled" else "disabled", if (current) "Phone internet tethering is active. Internet access depends on your mobile connection and carrier." else "Phone internet tethering is off.")
            }
        }

        private fun failure(error: Int) {
            if (closed) return
            when (error) {
                TetheringManager.TETHER_ERROR_NO_CHANGE_TETHERING_PERMISSION,
                TetheringManager.TETHER_ERROR_NO_ACCESS_TETHERING_PERMISSION -> finish("unsupported", "This phone's firmware blocks hotspot control by ordinary apps, even with Modify system settings enabled. Use phone Hotspot settings.", error)
                TetheringManager.TETHER_ERROR_PROVISIONING_FAILED,
                TetheringManager.TETHER_ERROR_ENTITLEMENT_UNKNOWN -> finish("failed", "Your carrier could not authorize internet tethering. Check your plan and phone Hotspot settings.", error)
                TetheringManager.TETHER_ERROR_UNKNOWN_REQUEST -> finish("failed", "Android can only stop a hotspot started by androp. Use phone Hotspot settings to stop this session.", error)
                else -> finish("failed", "Android rejected the hotspot request (error $error). Check phone Hotspot settings.", error)
            }
        }

        private fun finish(status: String, message: String, error: Int? = null) {
            if (closed) return
            if (status == "enabled" || status == "disabled" || (status == "ready" && dataSaverEnabled(context) == false)) SyncDashboardController.hotspotSetup(null)
            if (status == "unsupported") SyncDashboardController.hotspotSetup("hotspot")
            reply(context, id, action, status, message, enabled, error)
            close()
        }

        fun close() {
            if (closed) return
            closed = true
            main.removeCallbacks(timeout)
            if (registered) runCatching { manager?.unregisterTetheringEventCallback(events) }
            registered = false
            if (pending === this) pending = null
        }
    }
}
