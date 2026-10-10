package app.androp.android.utils

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.core.net.toUri
import app.androp.android.MainActivity
import app.androp.android.R
import app.androp.android.data.local.DataStoreManager
import app.androp.android.service.NotificationActionReceiver
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** One native dashboard shared by all non-media foreground services. No polling or render timer. */
object SyncDashboardController {
    const val NOTIFICATION_ID = 4001
    const val CHANNEL_ID = "androp_dashboard_v1"
    const val OWNER_SYNC = "sync"
    const val OWNER_RECEIVE = "receive"
    const val OWNER_SEND = "send"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val state = MutableStateFlow(SyncDashboardState())
    val dashboardState = state.asStateFlow()
    private val lock = Any()
    private var initialized = false
    private var channelCreated = false
    private var lastPublished: SyncDashboardState? = null
    private val foregroundOwners = mutableMapOf<String, java.lang.ref.WeakReference<Service>>()

    fun initialize(context: Context) {
        synchronized(lock) {
            if (initialized) return
            initialized = true
        }
        val application = context.applicationContext
        ensureChannel(application)
        // Retire old routine notifications once, preserving the independent native media player.
        val manager = application.getSystemService(NotificationManager::class.java)
        manager.activeNotifications.filter { it.notification.channelId in setOf(
            "airsync_file_transfer", "airsync_continue_browsing", "quick_share_channel",
            "quick_share_send_channel", "airsync_connection_channel") }.forEach { manager.cancel(it.id) }
        scope.launch { state.collect { publish(application, it) } }
        val dataStore = DataStoreManager.getInstance(application)
        scope.launch {
            combine(dataStore.isAppPaused(), dataStore.getLastConnectedDevice(),
                WebSocketUtil.connectionState, MacDeviceStatusManager.macDeviceStatus) { paused, device, _, status ->
                val level = status?.battery?.level?.takeIf { it in 0..100 }
                Triple(paused, device?.name, level to (status?.battery?.isCharging == true))
            }.collect { (paused, device, battery) ->
                update { current ->
                    val next = current.copy(device = device, battery = battery.first, charging = battery.second)
                    if (paused || BackgroundWorkController.isPaused) next.pause() else connectivity(next.copy(paused = false))
                }
            }
        }
        WebSocketUtil.registerConnectionStatusListener { refreshConnection() }
        app.androp.android.AirSyncApp.getBleConnectionManager()?.let { ble ->
            scope.launch { ble.connectionState.collect { refreshConnection() } }
        }
        scope.launch {
            FindPhoneManager.isRinging.collect { ringing -> update { it.copy(phoneAlert = ringing && !it.paused) } }
        }
    }

    private fun connectivity(current: SyncDashboardState): SyncDashboardState = current.copy(
        transport = when {
            current.paused -> null
            WebSocketUtil.isWifiConnected() -> "Network"
            app.androp.android.data.ble.BleGattServer.isAnyAuthenticated() -> "Bluetooth"
            else -> null
        },
        connecting = !current.paused && WebSocketUtil.isConnecting(),
        reconnecting = !current.paused && WebSocketUtil.isAutoReconnecting()
    )

    fun refreshConnection() { update { connectivity(it) } }
    fun refreshNotification() {
        scope.launch {
            synchronized(lock) { lastPublished = null }
            app.androp.android.AirSyncApp.getContext()?.let { publish(it, state.value) }
        }
    }
    fun setPaused(paused: Boolean) { update { if (paused) it.pause() else connectivity(it.copy(paused = false)) } }

    private fun update(change: (SyncDashboardState) -> SyncDashboardState) {
        synchronized(lock) { state.value = change(state.value) }
    }

    /** Every service still calls startForeground immediately, using its declared service type. */
    fun acquire(service: Service, owner: String, foregroundType: Int, status: String? = null): Boolean {
        initialize(service)
        val alreadyForeground = synchronized(lock) {
            val registered = foregroundOwners[owner]?.get() === service
            foregroundOwners[owner] = java.lang.ref.WeakReference(service)
            registered
        }
        update { it.copy(owners = it.owners + owner,
            ownerStatuses = if (status == null) it.ownerStatuses else it.ownerStatuses + (owner to status)) }
        if (alreadyForeground) return true
        return try {
            val notification = build(service, state.value)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) service.startForeground(NOTIFICATION_ID, notification, foregroundType)
            else service.startForeground(NOTIFICATION_ID, notification)
            true
        } catch (error: RuntimeException) {
            // startForeground is a separate framework call from startForegroundService:
            // a try/catch at the caller cannot catch this failure in onCreate.
            synchronized(lock) {
                if (foregroundOwners[owner]?.get() === service) {
                    foregroundOwners.remove(owner)
                    state.value = state.value.release(owner)
                }
            }
            android.util.Log.w("SyncDashboard", "Foreground service promotion rejected for $owner", error)
            service.stopSelf()
            false
        }
    }

    fun release(service: Service, owner: String) {
        // REMOVE would erase another foreground service's notification sharing this ID.
        service.stopForeground(Service.STOP_FOREGROUND_DETACH)
        synchronized(lock) {
            if (foregroundOwners[owner]?.get() !== service) return
            foregroundOwners.remove(owner)
            state.value = state.value.release(owner)
        }
        when (owner) {
            OWNER_SEND -> NotificationUtil.clearTransferKind("quickshare", sending = true)
            OWNER_RECEIVE -> NotificationUtil.clearTransferKind("quickshare", sending = false)
        }
        // Service shutdown callbacks can arrive on IO. Serialize notification writes on Main
        // and read the latest state there so an old release cannot overwrite a paused card.
        scope.launch { publish(service.applicationContext, state.value) }
    }

    fun setOwnerStatus(owner: String, status: String) { update { if (owner in it.owners) it.copy(ownerStatuses = it.ownerStatuses + (owner to status)) else it } }
    fun progress(id: String, name: String, percent: Int, sending: Boolean, kind: String = "quickshare") {
        update { if (kind == "quickshare" && (if (sending) OWNER_SEND else OWNER_RECEIVE) !in it.owners) it
            else it.withProgress(id, name, percent, sending, kind) }
    }
    fun complete(id: String, name: String, success: Boolean, sending: Boolean, uri: String?, detail: String? = null) {
        update { current ->
            if (current.paused || "$sending:$id" in current.cancelledTransfers) current else current.copy(
                transfers = current.transfers.filterNot { it.id == id && it.sending == sending },
                lastEvent = detail ?: "${if (success) { if (sending) "Sent" else "Received" } else "Transfer failed"} · $name",
                receivedFile = uri?.takeIf { success && !sending })
        }
    }
    fun clearTransfers(kind: String) { update { it.copy(transfers = it.transfers.filterNot { transfer -> transfer.kind == kind }) } }
    fun cancelTransfer(id: String, sending: Boolean) {
        update { it.cancelTransfer(id, sending) }
    }
    fun consent(id: String, sender: String, files: String) { update { if (it.paused) it else it.copy(consents = (it.consents.filterNot { c -> c.id == id } + DashboardConsent(id, sender, files)).takeLast(8)) } }
    fun clearConsent(id: String) { update { it.copy(consents = it.consents.filterNot { consent -> consent.id == id }) } }
    fun link(url: String) { update { if (it.paused) it else it.copy(link = url, lastEvent = "Link received · Open in browser", receivedFile = null) } }
    fun clearLink() { update { it.copy(link = null, lastEvent = if (it.link != null) null else it.lastEvent) } }
    fun clipboard(sent: Boolean) { update { if (it.paused) it else it.copy(lastEvent = if (sent) "Clipboard sent" else "Clipboard received", receivedFile = null) } }
    fun clearActivity() { update { it.copy(lastEvent = null, link = null, receivedFile = null) } }

    private fun ensureChannel(context: Context) {
        synchronized(lock) {
            if (channelCreated) return
            context.getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "androp dashboard", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Connection, transfers and quick controls in one quiet notification"
                    setShowBadge(false); setSound(null, null); enableVibration(false)
                })
            channelCreated = true
        }
    }

    private fun destination(context: Context, destination: String, request: Int): PendingIntent = PendingIntent.getActivity(
        context, request, Intent(context, MainActivity::class.java).apply {
            putExtra("androp_destination", destination)
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    private fun action(context: Context, action: String, request: Int, extras: Intent.() -> Unit = {}): PendingIntent = PendingIntent.getBroadcast(
        context, request, Intent(context, NotificationActionReceiver::class.java).apply { this.action = action; extras() },
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    fun build(context: Context, snapshot: SyncDashboardState = state.value): Notification {
        ensureChannel(context)
        val lines = mutableListOf(snapshot.connectionLine)
        if (!snapshot.paused) {
            if (snapshot.phoneAlert) lines += "Find phone alert · Tap Stop alert to end"
            snapshot.consents.firstOrNull()?.let { lines += "${it.sender}: ${it.files}" }
            snapshot.transfers.take(3).forEach { lines += "${if (it.sending) "↑ Sending" else "↓ Receiving"} ${it.name} · ${it.percent}%" }
            snapshot.lastEvent?.let { lines += it }
            snapshot.ownerStatuses.filterKeys { it != OWNER_SYNC }.values.forEach { if (it !in lines && snapshot.transfers.isEmpty()) lines += it }
        }
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_laptop_24)
            .setContentTitle(if (snapshot.paused) "androp · Paused" else "androp")
            .setContentText(snapshot.activityLine)
            .setSubText(if (snapshot.paused) null else snapshot.connectionLine)
            .setStyle(NotificationCompat.BigTextStyle().setBigContentTitle("androp dashboard").bigText(lines.take(6).joinToString("\n")))
            .setContentIntent(destination(context, "dashboard", 40010))
            .setOnlyAlertOnce(true).setSilent(true).setShowWhen(false)
            .setOngoing(snapshot.owners.isNotEmpty() || snapshot.paused || snapshot.shouldRequestPromotion)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setCategory(NotificationCompat.CATEGORY_SERVICE).setPriority(NotificationCompat.PRIORITY_LOW)
            .setDeleteIntent(action(context, NotificationActionReceiver.ACTION_CLEAR_ACTIVITY, 40011))
            .setPublicVersion(NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_laptop_24).setContentTitle("androp")
                .setContentText(if (snapshot.paused) "Syncing paused" else "Connection and quick controls")
                .setSilent(true).setShowWhen(false).build())
        val consent = snapshot.consents.firstOrNull()
        val transfer = snapshot.transfers.firstOrNull()
        if (!snapshot.paused) when {
            snapshot.phoneAlert -> builder.addAction(0, "Stop alert", action(context, NotificationActionReceiver.ACTION_STOP_PHONE_ALERT, 40012))
            consent != null -> {
                builder.addAction(0, "Accept", action(context, NotificationActionReceiver.ACTION_ACCEPT_SHARE, 40013) { putExtra("connection_id", consent.id) })
                builder.addAction(0, "Reject", action(context, NotificationActionReceiver.ACTION_REJECT_SHARE, 40014) { putExtra("connection_id", consent.id) })
            }
            transfer != null -> builder.addAction(0, "Cancel", action(context, NotificationActionReceiver.ACTION_CANCEL_TRANSFER, 40015) {
                putExtra("transfer_id", transfer.id); putExtra("is_sending", transfer.sending); putExtra("transfer_kind", transfer.kind)
            })
            snapshot.link != null -> {
                val link = snapshot.link.trim().let { if (it.startsWith("https://") || it.startsWith("http://")) it else "https://$it" }
                builder.addAction(0, "Open link", PendingIntent.getActivity(context, 40016, Intent(Intent.ACTION_VIEW, link.toUri()), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            }
            snapshot.receivedFile != null -> {
                val uri = snapshot.receivedFile.toUri()
                val mimeType = runCatching { context.contentResolver.getType(uri) }.getOrNull() ?: "application/octet-stream"
                builder.addAction(0, "Open file", PendingIntent.getActivity(context, 40017,
                    Intent(Intent.ACTION_VIEW).apply { setDataAndType(uri, mimeType); flags = Intent.FLAG_GRANT_READ_URI_PERMISSION },
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            }
        }
        builder.addAction(0, if (snapshot.paused) "Resume" else "Pause", action(context,
            if (snapshot.paused) NotificationActionReceiver.ACTION_RESUME else NotificationActionReceiver.ACTION_PAUSE, 40018))
        if (consent == null || snapshot.paused || snapshot.phoneAlert) builder.addAction(0, "Remote", destination(context, "remote", 40019))
        transfer?.takeUnless { snapshot.paused }?.let { builder.setProgress(100, it.percent, false) }
        val regular = builder.build()
        // Android 16 Live Updates are native and conditional. Samsung chooses Now Bar placement;
        // the ordinary shade notification remains available when promotion is disabled.
        try {
            if (Build.VERSION.SDK_INT >= 36 && snapshot.shouldRequestPromotion &&
                context.getSystemService(NotificationManager::class.java).canPostPromotedNotifications()) {
                val native = Notification.Builder.recoverBuilder(context, regular)
                    // Use the same backward-compatible extra as AndroidX NotificationCompat.
                    // The framework setter itself is only available starting with API 36.1.
                    .addExtras(Bundle().apply { putBoolean("android.requestPromotedOngoing", true) })
                    .setShortCriticalText(when {
                        transfer != null -> "${transfer.percent}%"
                        snapshot.phoneAlert -> "Alert"
                        snapshot.battery != null -> "${snapshot.battery}%"
                        snapshot.transport == "Bluetooth" -> "BLE"
                        else -> snapshot.transport?.take(7) ?: "Active"
                    })
                if (transfer != null && !snapshot.phoneAlert && consent == null) {
                    native.setStyle(Notification.ProgressStyle()
                        .setProgressSegments(listOf(Notification.ProgressStyle.Segment(100)))
                        .setProgress(transfer.percent).setStyledByProgress(true))
                }
                val promoted = native.build()
                if (promoted.hasPromotableCharacteristics()) return promoted
            }
        } catch (error: RuntimeException) {
            // An OEM's Live Update implementation must not take down the ordinary dashboard.
            android.util.Log.w("SyncDashboard", "Live Update unavailable; using regular notification", error)
        }
        return regular
    }

    private fun publish(context: Context, snapshot: SyncDashboardState) {
        synchronized(lock) { if (lastPublished == snapshot) return }
        val manager = context.getSystemService(NotificationManager::class.java)
        if (!snapshot.shouldShow) {
            manager.cancel(NOTIFICATION_ID)
            synchronized(lock) { lastPublished = snapshot }
            return
        }
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        try {
            manager.notify(NOTIFICATION_ID, build(context, snapshot))
            synchronized(lock) { lastPublished = snapshot }
        } catch (error: RuntimeException) {
            android.util.Log.w("SyncDashboard", "Could not publish dashboard notification", error)
        }
    }
}
