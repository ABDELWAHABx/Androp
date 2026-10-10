package app.androp.android.data.ble

import android.util.Log
import app.androp.android.domain.model.AudioInfo
import app.androp.android.domain.model.BatteryInfo
import app.androp.android.utils.CallControlUtil
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import java.security.MessageDigest
import java.util.Base64
import org.json.JSONArray
import org.json.JSONObject

object BleTransportBridge {
    private const val TAG = "BleTransportBridge"

    private var gattServer: BleGattServer? = null

    fun initialize(server: BleGattServer) {
        gattServer = server
    }

    fun clear() {
        gattServer = null
    }

    fun deriveAuthToken(symmetricKey: String): String {
        return try {
            val md = MessageDigest.getInstance("SHA-256")
            val hash = md.digest(symmetricKey.toByteArray(Charsets.UTF_8))
            Base64.getEncoder().encodeToString(hash.copyOf(16))
        } catch (e: Exception) {
            Log.e(TAG, "Error deriving auth token: ${e.message}")
            ""
        }
    }

    // --- Outbound (Android -> Mac) ---

    fun sendNotification(pkg: String, appName: String, title: String, text: String) {
        sendNotification(JSONObject().put("package", pkg).put("app", appName)
            .put("title", title).put("body", text))
    }

    fun sendNotification(data: JSONObject) {
        // Keep the legacy four fields; newer clients decode the optional fifth
        // JSON field. Bound visible text, never truncate IDs or action names.
        fun field(value: String, limit: Int) = value.replace(BleConstants.DELIMITER, " ").take(limit)
        val fields = mutableListOf(
            field(data.optString("package"), 255),
            field(data.optString("app"), 80),
            field(data.optString("title"), 200),
            field(data.optString("body"), 500)
        )
        val id = data.optString("id")
        if (id.isNotBlank() && id.length <= 512) {
            val actions = JSONArray()
            val source = data.optJSONArray("actions")
            for (index in 0 until minOf(source?.length() ?: 0, 8)) {
                val action = source?.optJSONObject(index) ?: continue
                val name = action.optString("name")
                val type = action.optString("type")
                if (name.isNotBlank() && name.length <= 128 && (type == "button" || type == "reply")) {
                    actions.put(JSONObject().put("name", name).put("type", type))
                }
            }
            fields.add(JSONObject().put("id", id).put("actions", actions)
                .put("priority", field(data.optString("priority", "alerting"), 32)).toString())
        }
        gattServer?.sendChunkedNotification(BleConstants.CHAR_NOTIFICATION_DATA, fields.joinToString(BleConstants.DELIMITER))
    }

    fun sendBatteryStatus(battery: BatteryInfo) {
        val level = battery.level.toByte()
        gattServer?.sendNotification(BleConstants.CHAR_BATTERY_LEVEL, byteArrayOf(level))
    }

    fun sendMediaState(audio: AudioInfo) {
        val payload = listOf(
            if (audio.isPlaying) "1" else "0",
            audio.title,
            audio.artist,
            audio.volume.toString(),
            if (audio.isMuted) "1" else "0",
            audio.likeStatus,
            "" // Avoid sending heavy base64 art over BLE to conserve bandwidth
        ).joinToString(BleConstants.DELIMITER)

        gattServer?.sendChunkedNotification(BleConstants.CHAR_MEDIA_STATE, payload)
    }

    fun sendSystemState(isDnd: Boolean, isPowerSave: Boolean) {
        val payload = listOf(
            if (isDnd) "1" else "0",
            if (isPowerSave) "1" else "0"
        ).joinToString(BleConstants.DELIMITER)

        gattServer?.sendNotification(BleConstants.CHAR_SYSTEM_STATE, payload.toByteArray())
    }

    fun sendClipboardEnvelope(data: JSONObject, acknowledgement: Boolean = false): Boolean {
        val envelope = JSONObject(data.toString()).put("andropClipboard", 1).put("kind", if (acknowledgement) "ack" else "update")
        return gattServer?.sendChunkedNotification(BleConstants.CHAR_CLIPBOARD_DATA_NOTIFY, envelope.toString()) ?: false
    }

    fun handleClipboardEnvelope(context: android.content.Context, payload: String) {
        val envelope = try { JSONObject(payload) } catch (_: Exception) { null }
        if (envelope?.optInt("andropClipboard") == 1 && envelope.optString("kind") in setOf("update", "ack")) {
            if (envelope.optString("kind") == "ack") app.androp.android.utils.ClipboardSyncManager.handleAcknowledgement(envelope)
            else app.androp.android.utils.ClipboardSyncManager.handleClipboardEnvelope(context, envelope)
        } else app.androp.android.utils.ClipboardSyncManager.handleClipboardUpdate(context, payload)
    }

    fun sendClipboard(text: String) {
        gattServer?.sendChunkedNotification(BleConstants.CHAR_CLIPBOARD_DATA_NOTIFY, text)
    }

    fun sendNotificationDismissal(id: String) {
        gattServer?.sendChunkedNotification(BleConstants.CHAR_NOTIFICATION_DISMISS_NOTIFY, id)
    }

    fun sendManualDisconnect() {
        gattServer?.sendChunkedNotification(BleConstants.CHAR_MAC_CONTROL, "remote|manual_disconnect")
    }

    fun sendDeviceName(context: android.content.Context? = null) {
        val ctx = context ?: app.androp.android.AirSyncApp.getContext() ?: return
        kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.IO).launch {
            val dataStoreManager = app.androp.android.data.local.DataStoreManager.getInstance(ctx)
            val persistedName = dataStoreManager.getDeviceName().first().ifBlank { null }
            val name = persistedName ?: app.androp.android.utils.DeviceInfoUtil.getDeviceName(ctx)
            gattServer?.sendChunkedNotification(BleConstants.CHAR_DEVICE_NAME, name)
        }
    }

    // --- Inbound (Mac -> Android) ---

    fun handleMediaControl(action: String, context: android.content.Context) {
        // Small authenticated control envelopes share this existing write
        // characteristic without changing legacy media command framing.
        if (action.toByteArray(Charsets.UTF_8).size <= 64 * 1024 && action.startsWith("{")) {
            val message = try { JSONObject(action) } catch (_: Exception) { null }
            if (message?.optString("type") in setOf("macInfo", "macPowerControlResponse")) {
                if (!BleGattServer.isAnyAuthenticated() || app.androp.android.utils.BackgroundWorkController.isPaused) return
                app.androp.android.utils.WebSocketMessageHandler.handleIncomingMessage(context, action)
                return
            }
        }
        Log.d(TAG, "Media control from BLE: $action")
        when {
            action == "findPhone" -> app.androp.android.utils.FindPhoneManager.start(context)
            action == "stopFindPhone" -> app.androp.android.utils.FindPhoneManager.stop()
            action == "manual_disconnect" -> {
                Log.d(TAG, "Received manual disconnect from Mac via BLE")
                app.androp.android.utils.WebSocketUtil.disconnect(context, manual = true)
                gattServer?.disconnectAllConnectedDevices()
            }

            action == "play" -> app.androp.android.utils.MediaControlUtil.play(context)
            action == "pause" -> app.androp.android.utils.MediaControlUtil.pause(context)
            action == "stop" -> app.androp.android.utils.MediaControlUtil.stop(context)
            action == "playPause" -> app.androp.android.utils.MediaControlUtil.playPause(context)
            action == "next" -> app.androp.android.utils.MediaControlUtil.skipNext(context)
            action == "previous" -> app.androp.android.utils.MediaControlUtil.skipPrevious(
                context
            )

            action == "callAccept" -> CallControlUtil.acceptCall(context)
            action == "callDecline" || action == "callEnd" -> CallControlUtil.endCall(context)

            // Volume Controls over BLE
            action == "volumeUp" -> app.androp.android.utils.VolumeControlUtil.increaseVolume(
                context
            )

            action == "volumeDown" -> app.androp.android.utils.VolumeControlUtil.decreaseVolume(
                context
            )

            action == "muteToggle" -> app.androp.android.utils.VolumeControlUtil.toggleMute(
                context
            )

            action.startsWith("setVolume|") -> {
                val volStr = action.substringAfter("setVolume|")
                val vol = volStr.toIntOrNull()
                if (vol != null && vol in 0..100) {
                    app.androp.android.utils.VolumeControlUtil.setVolume(context, vol)
                }
            }

            action.startsWith("toggleNotifs|") -> {
                if (action.length > 140_000) return
                val payload = try { JSONObject(action.substringAfter('|')) } catch (_: Exception) { return }
                val items = payload.optJSONArray("packages") ?: return
                val enabled = payload.optString("state").toBooleanStrictOrNull() ?: return
                if (items.length() !in 1..512) return
                val packages = (0 until items.length()).map { items.optString(it) }.toSet()
                updateNotificationSelection(context, packages, enabled)
            }

            action.startsWith("toggleNotif|") -> {
                val parts = action.split("|", limit = 3)
                if (parts.size != 3) return
                val enabled = parts[2].toBooleanStrictOrNull() ?: return
                updateNotificationSelection(context, setOf(parts[1]), enabled)
            }
        }
    }

    private fun updateNotificationSelection(context: android.content.Context, packages: Set<String>, enabled: Boolean) {
        if (packages.isEmpty() || packages.size > 512 ||
            packages.any { it.length !in 1..255 || !it.matches(Regex("[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)*")) }) return
        if (!BleGattServer.isAnyAuthenticated() || app.androp.android.utils.BackgroundWorkController.isPaused) return
        kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.IO).launch {
            try {
                val dataStore = app.androp.android.data.local.DataStoreManager.getInstance(context)
                val now = System.currentTimeMillis()
                val defaults = packages.associateWith { pkg ->
                    val system = try {
                        (context.packageManager.getApplicationInfo(pkg, 0).flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0
                    } catch (_: Exception) { false }
                    app.androp.android.domain.model.NotificationApp(pkg, pkg, enabled, isSystemApp = system, lastUpdated = now)
                }
                dataStore.updateNotificationApps { saved ->
                    val current = saved.associateBy { it.packageName }.toMutableMap()
                    for (pkg in packages) {
                        current[pkg] = (current[pkg] ?: defaults.getValue(pkg)).copy(isEnabled = enabled, lastUpdated = now)
                    }
                    current.values.toList()
                }
                app.androp.android.utils.SyncManager.checkAndSyncDeviceStatus(context, forceSync = true)
            } catch (cancelled: kotlinx.coroutines.CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                Log.e(TAG, "Error updating app notification preferences via BLE", failure)
            }
        }
    }

    fun handleNotificationAction(data: String, context: android.content.Context) {
        Log.d(TAG, "Notification action from BLE: $data")
        val parts = if (data.contains(BleConstants.DELIMITER)) data.split(BleConstants.DELIMITER, limit = 3) else data.split("|", limit = 3)
        if (parts.size >= 2) {
            val id = parts[0]
            val actionName = parts[1]
            // Reply text is optional and was previously dropped, so inline replies
            // never worked over BLE. Empty means "plain button", not an empty reply.
            val replyText = parts.getOrNull(2)?.takeIf { it.isNotEmpty() }
            app.androp.android.utils.NotificationDismissalUtil.performNotificationAction(
                id,
                actionName,
                replyText
            )
        }
    }
}
