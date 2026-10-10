package app.androp.android.utils

import android.app.Activity
import android.app.Application
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import app.androp.android.AirSyncApp
import app.androp.android.data.local.DataStoreManager
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject

object ClipboardSyncManager {
    data class DeliveryState(val id: String? = null, val status: String = "idle", val message: String? = null)
    private val _deliveryState = MutableStateFlow(DeliveryState())
    val deliveryState = _deliveryState.asStateFlow()
    private val outbox = ClipboardOutbox()
    private val deliveryResults = MutableStateFlow<Map<String, Boolean>>(emptyMap())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var retryJob: Job? = null
    private var settingsJob: Job? = null
    private var clipboardListener: ClipboardManager.OnPrimaryClipChangedListener? = null
    private var listenerContext: Context? = null
    private var lifecycleRegistered = false
    private val resumed = mutableSetOf<Activity>()
    private val receivedIds = linkedSetOf<String>()
    @Volatile private var isEnabled = false
    private var transportConnected = false
    private var peerIdentity: String? = null
    @Volatile private var lastReceivedText: String? = null
    private var onClipboardSent: ((String) -> Unit)? = null

    fun setOnClipboardSentCallback(callback: ((String) -> Unit)?) { onClipboardSent = callback }

    fun startSync(context: Context) {
        if (BackgroundWorkController.isPaused) return
        val app = context.applicationContext as? Application ?: return
        registerLifecycle(app)
        if (isEnabled || settingsJob?.isActive == true) return
        settingsJob = scope.launch {
            isEnabled = DataStoreManager(app).getClipboardSyncEnabled().first()
            if (isEnabled && !BackgroundWorkController.isPaused && AirSyncApp.isAppForeground()) {
                // startSync originates from the visible app. Android does not allow
                // background clipboard reads; the listener is detached on pause.
                attachListener(app)
                delay(250)
                if (!BackgroundWorkController.isPaused && isEnabled && AirSyncApp.isAppForeground()) ClipboardUtil.getClipboardText(app, automatic = true)?.let(::automaticSend)
            }
        }
    }

    private fun registerLifecycle(app: Application) {
        if (lifecycleRegistered) return
        lifecycleRegistered = true
        app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityResumed(activity: Activity) {
                resumed.add(activity)
                if (isEnabled && !BackgroundWorkController.isPaused) {
                    attachListener(app)
                    scope.launch { delay(250); if (resumed.isNotEmpty() && isEnabled && !BackgroundWorkController.isPaused) ClipboardUtil.getClipboardText(app, automatic = true)?.let(::automaticSend) }
                }
            }
            override fun onActivityPaused(activity: Activity) { resumed.remove(activity); if (resumed.isEmpty()) detachListener() }
            override fun onActivityDestroyed(activity: Activity) { resumed.remove(activity); if (resumed.isEmpty()) detachListener() }
            override fun onActivityCreated(activity: Activity, state: Bundle?) = Unit
            override fun onActivityStarted(activity: Activity) = Unit
            override fun onActivityStopped(activity: Activity) = Unit
            override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) = Unit
        })
    }

    private fun attachListener(context: Context) {
        if (clipboardListener != null || BackgroundWorkController.isPaused) return
        listenerContext = context.applicationContext
        clipboardListener = try {
            ClipboardUtil.registerClipboardListener(context) { automaticSend(it) }
        } catch (_: RuntimeException) {
            listenerContext = null
            null // Clipboard service/permission failures must not crash activity resume.
        }
    }
    private fun detachListener() {
        clipboardListener?.let { listener -> listenerContext?.let { ClipboardUtil.unregisterClipboardListener(it, listener) } }
        clipboardListener = null
        listenerContext = null
    }
    private fun automaticSend(text: String) {
        if (!isEnabled || BackgroundWorkController.isPaused || !WebSocketUtil.isConnected()) return
        if (text == lastReceivedText) return
        lastReceivedText = null
        if (outbox.enqueue(text, explicit = false) != null) scheduleRetry()
    }

    fun stopSync(context: Context) {
        detachListener()
        scope.coroutineContext.cancelChildren()
        settingsJob = null
        retryJob = null
        isEnabled = false
        outbox.entries().forEach { rememberResult(it.id, false) }
        outbox.clear()
        lastReceivedText = null
        _deliveryState.value = DeliveryState()
    }

    /** The verified persistent pairing identity; do not call when only an ephemeral socket key clears. */
    fun onPeerChanged(identity: String?) {
        scope.launch {
            if (identity == peerIdentity) return@launch
            peerIdentity = identity
            val abandoned = outbox.peerChanged(identity)
            synchronized(receivedIds) { receivedIds.clear() }
            lastReceivedText = null
            abandoned.forEach { rememberResult(it.id, false) }
            if (abandoned.isNotEmpty()) {
                retryJob?.cancel()
                retryJob = null
                _deliveryState.value = DeliveryState(status = "failed", message = "Paired device changed")
            }
        }
    }

    fun onTransportChanged(connected: Boolean) {
        scope.launch {
            if (connected == transportConnected) return@launch
            transportConnected = connected
            retryJob?.cancel()
            retryJob = null
            if (connected && !BackgroundWorkController.isPaused) { outbox.reconnect(); scheduleRetry() }
            else { outbox.entries().forEach { rememberResult(it.id, false) }; outbox.clear() }
        }
    }

    /** Explicit sends may repeat identical content. True means queued, never delivered. */
    fun syncTextToDesktop(text: String, videoHandoff: Boolean = false): Boolean = enqueueExplicit(text, videoHandoff) != null

    private fun enqueueExplicit(text: String, videoHandoff: Boolean): String? {
        if (BackgroundWorkController.isPaused || !WebSocketUtil.isConnected()) return null
        val value = if (videoHandoff) YouTubeHandoff.extract(text) ?: return null else text
        val entry = outbox.enqueue(value, explicit = true, videoHandoff = videoHandoff) ?: return null
        _deliveryState.value = DeliveryState(entry.id, "queued")
        scheduleRetry()
        return entry.id
    }

    suspend fun sendAndAwait(text: String, videoHandoff: Boolean = false): Boolean {
        val id = enqueueExplicit(text, videoHandoff) ?: return false
        val deadline = app.androp.android.data.ble.BleControlPolicy.clipboardWaitMillis(text.toByteArray(Charsets.UTF_8).size, WebSocketUtil.isWifiConnected())
        val result = try {
            withTimeoutOrNull(deadline) { deliveryResults.first { id in it }[id] } ?: false
        } catch (e: CancellationException) {
            outbox.acknowledge(id, false)
            rememberResult(id, false)
            stopEmptyRetry()
            throw e
        }
        if (!result) { outbox.acknowledge(id, false); rememberResult(id, false); stopEmptyRetry() }
        return result
    }

    private fun stopEmptyRetry() {
        retryJob?.cancel()
        retryJob = null
        if (outbox.size() > 0) scheduleRetry()
    }

    private fun rememberResult(id: String, ok: Boolean) {
        synchronized(deliveryResults) {
            val updated = deliveryResults.value.toMutableMap()
            updated[id] = ok
            while (updated.size > 64) updated.remove(updated.keys.first())
            deliveryResults.value = updated
        }
    }

    private fun scheduleRetry() {
        scope.launch {
            if (retryJob?.isActive == true || BackgroundWorkController.isPaused || !WebSocketUtil.isConnected()) return@launch
            retryJob = scope.launch {
                while (!BackgroundWorkController.isPaused && WebSocketUtil.isConnected() && outbox.size() > 0) {
                    val now = System.nanoTime() / 1_000_000
                    outbox.expired(now).forEach { rememberResult(it.id, false); _deliveryState.value = DeliveryState(it.id, "failed", "No clipboard acknowledgement") }
                    val entry = outbox.due(now)
                    if (entry != null) {
                        val data = JSONObject().put("text", entry.text).put("id", entry.id).put("videoHandoff", entry.videoHandoff)
                        outbox.attempted(entry.id, now, app.androp.android.data.ble.BleControlPolicy.clipboardRetryMillis(entry.text.toByteArray(Charsets.UTF_8).size, WebSocketUtil.isWifiConnected()))
                        val queued = WebSocketUtil.sendMessage(JSONObject().put("type", "clipboardUpdate").put("data", data).toString())
                        _deliveryState.value = DeliveryState(entry.id, "waiting", if (queued) null else "Transport busy")
                    } else {
                        val deadline = outbox.nextDeadline() ?: break
                        delay((deadline - now).coerceAtLeast(1))
                    }
                }
            }
        }
    }

    fun handleAcknowledgement(data: JSONObject) {
        scope.launch {
            if (BackgroundWorkController.isPaused) return@launch
            val id = data.optString("id")
            if (id.length > 128) return@launch
            val ok = data.optBoolean("ok", false)
            val entry = outbox.acknowledge(id, ok) ?: return@launch
            rememberResult(id, ok)
            // The head may have been waiting on its retry deadline. Wake the next
            // queued item immediately instead of making it wait another 4–60 seconds.
            retryJob?.cancel()
            retryJob = null
            if (outbox.size() > 0) scheduleRetry()
            _deliveryState.value = DeliveryState(id, if (ok) "delivered" else "failed", if (ok) null else "Phone or Mac could not store clipboard")
            if (ok) { onClipboardSent?.invoke(entry.text); SyncDashboardController.clipboard(sent = true) }
        }
    }

    fun handleClipboardEnvelope(context: Context, data: JSONObject) {
        if (BackgroundWorkController.isPaused) return
        val id = data.optString("id")
        val text = data.optString("text", data.optString("content"))
        val bounded = (data.has("text") || data.has("content")) && text.toByteArray(Charsets.UTF_8).size <= 64 * 1024 && (id.isEmpty() || id.length <= 128)
        val alreadyApplied = synchronized(receivedIds) { id.isNotEmpty() && id in receivedIds }
        val ok = bounded && (alreadyApplied || handleClipboardUpdate(context, text, data.optBoolean("videoHandoff")))
        if (ok && id.isNotEmpty()) synchronized(receivedIds) {
            receivedIds.add(id)
            while (receivedIds.size > 64) receivedIds.remove(receivedIds.first())
        }
        if (id.isNotEmpty()) WebSocketUtil.sendMessage(JSONObject().put("type", "clipboardAck")
            .put("data", JSONObject().put("id", id).put("ok", ok)).toString())
    }

    fun handleClipboardUpdate(context: Context, text: String, videoHandoff: Boolean = false): Boolean {
        if (BackgroundWorkController.isPaused || text.toByteArray(Charsets.UTF_8).size > 64 * 1024) return false
        val previousReceived = lastReceivedText
        lastReceivedText = text // Set before clipboard callbacks can echo the incoming content.
        if (!ClipboardUtil.setClipboardText(context, text)) { lastReceivedText = previousReceived; return false }
        SyncDashboardController.clipboard(sent = false)
        scope.launch {
            if (BackgroundWorkController.isPaused) return@launch
            val settings = DataStoreManager(context)
            val video = if (videoHandoff) YouTubeHandoff.extract(text) else null
            val url = video ?: text.trim().takeIf { it.matches(Regex("https?://[^\\s]+")) }
            if (url != null && (video != null || settings.getContinueBrowsingEnabled().first())) {
                val keepPrevious = settings.getKeepPreviousLinkEnabled().first()
                if (!BackgroundWorkController.isPaused) NotificationUtil.showContinueBrowsingLink(context, url, keepPrevious)
            }
        }
        return true
    }
}
