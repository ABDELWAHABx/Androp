package app.androp.android.quickshare

import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.util.Log
import com.google.android.gms.nearby.sharing.ConnectionResponseFrame
import app.androp.android.R
import app.androp.android.utils.SyncDashboardController
import app.androp.android.data.local.DataStoreManager
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/**
 * Foreground service that manages Quick Share advertisement and connections.
 */
class QuickShareService : Service() {

    companion object {
        private const val TAG = "QuickShareService"

        const val ACTION_ACCEPT = "app.androp.android.quickshare.ACCEPT"
        const val ACTION_REJECT = "app.androp.android.quickshare.REJECT"
        const val ACTION_START_DISCOVERY = "app.androp.android.quickshare.START_DISCOVERY"
        const val ACTION_CANCEL_TRANSFER = "app.androp.android.quickshare.CANCEL_TRANSFER"
        const val EXTRA_CONNECTION_ID = "connection_id"
        const val EXTRA_TRANSFER_ID = "transfer_id"
        @Volatile private var instance: QuickShareService? = null

        fun respondToShare(connectionId: String, accept: Boolean) {
            val active = instance
            val connection = active?.activeConnections?.get(connectionId)
            if (active == null || connection == null) {
                SyncDashboardController.clearConsent(connectionId)
                return
            }
            val responseJob = active.serviceScope.launch {
                try {
                    connection.sendSharingResponse(
                        if (accept) ConnectionResponseFrame.Status.ACCEPT else ConnectionResponseFrame.Status.REJECT)
                } catch (e: Exception) {
                    runCatching { connection.closeConnection() }
                    if (e is kotlinx.coroutines.CancellationException) throw e
                    Log.w(TAG, "Unable to answer Nearby share request", e)
                } finally {
                    SyncDashboardController.clearConsent(connectionId)
                }
            }
            // A scope already cancelled at launch never enters the coroutine's finally block.
            responseJob.invokeOnCompletion { SyncDashboardController.clearConsent(connectionId) }
        }

        fun cancelTransfer(transferId: String) {
            val service = instance ?: return
            service.serviceScope.launch {
                val payloadId = transferId.toLongOrNull() ?: return@launch
                service.activeConnections.values.toList().forEach {
                    if (it.transferredFiles.containsKey(payloadId)) it.closeConnection()
                }
            }
        }
    }

    private lateinit var server: QuickShareServer
    private lateinit var advertiser: QuickShareAdvertiser
    private lateinit var dataStoreManager: DataStoreManager
    private val activeConnections = java.util.concurrent.ConcurrentHashMap<String, InboundQuickShareConnection>()
    private val binder = LocalBinder()
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var discoveryJob: kotlinx.coroutines.Job? = null


    inner class LocalBinder : Binder() {
        fun getService(): QuickShareService = this@QuickShareService
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        createNotificationChannel()

        SyncDashboardController.acquire(this, SyncDashboardController.OWNER_RECEIVE,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE, "Quick Share is active")

        server = QuickShareServer(this) { connection ->
            val id = java.util.UUID.randomUUID().toString()
            activeConnections[id] = connection

            connection.onConnectionReady = { conn ->
                discoveryJob?.cancel() // Transfer started, abort timeout
                val pin = conn.ukey2Context?.authString ?: ""
                Log.d(TAG, "Connection ready, PIN: $pin")
                updateForegroundNotification("PIN: $pin - Waiting for files...")

                conn.onFileProgress = { fileName, percent, _, _, transferId ->
                    app.androp.android.utils.NotificationUtil.showFileProgress(
                        this@QuickShareService, transferId.hashCode(), fileName, percent, transferId,
                        isSending = false)
                }

                conn.onFileComplete = { fileName, transferId, success, uri ->
                    app.androp.android.utils.NotificationUtil.showFileComplete(
                        this@QuickShareService,
                        transferId.hashCode(),
                        fileName,
                        success,
                        isSending = false,
                        contentUri = uri
                    )
                }
            }

            connection.onIntroductionReceived = { intro ->
                val deviceName = connection.endpointName ?: "Unknown Device"
                val firstFileName = intro.file_metadata.firstOrNull()?.name ?: "Unknown File"
                val fileCount = intro.file_metadata.size
                val displayText =
                    if (fileCount > 1) "$firstFileName and ${fileCount - 1} more" else firstFileName

                serviceScope.launch {
                    if ((app.androp.android.utils.BackgroundWorkController.isPaused || dataStoreManager.isAppPaused().first())) {
                        connection.closeConnection()
                        return@launch
                    }
                    // Nearby endpoint names are advertised, not authenticated identities.
                    // Every Nearby transfer needs explicit consent; paired encrypted WS drops
                    // use the separately authenticated transfer receiver.
                    showConsentNotification(id, deviceName, displayText)
                }
            }

            connection.onFinished = {
                activeConnections.remove(id)
                SyncDashboardController.clearConsent(id)

                if (activeConnections.isEmpty()) {
                    Log.d(TAG, "All transfers finished, stopping discovery")
                    stopDiscovery()
                }
            }
        }
        advertiser = QuickShareAdvertiser(this)
        dataStoreManager = DataStoreManager.getInstance(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (app.androp.android.utils.BackgroundWorkController.isPaused) {
            stopSelf()
            return START_NOT_STICKY
        }
        when (intent?.action) {
            ACTION_ACCEPT -> {
                val id = intent.getStringExtra(EXTRA_CONNECTION_ID)
                serviceScope.launch {
                    val connection = activeConnections[id]
                    if (connection == null) stopSelf() else connection.sendSharingResponse(ConnectionResponseFrame.Status.ACCEPT)
                }
            }

            ACTION_REJECT -> {
                val id = intent.getStringExtra(EXTRA_CONNECTION_ID)
                serviceScope.launch {
                    val connection = activeConnections[id]
                    if (connection == null) stopSelf() else connection.sendSharingResponse(ConnectionResponseFrame.Status.REJECT)
                }
            }

            ACTION_START_DISCOVERY -> {
                serviceScope.launch {
                    val enabled = !(app.androp.android.utils.BackgroundWorkController.isPaused || dataStoreManager.isAppPaused().first()) && dataStoreManager.isQuickShareEnabled().first()
                    if (enabled) {
                        startDiscoveryWithTimeout()
                    } else {
                        stopDiscovery()
                    }
                }
            }

            ACTION_CANCEL_TRANSFER -> {
                val transferIdStr = intent.getStringExtra(EXTRA_TRANSFER_ID)
                val transferId = transferIdStr?.toLongOrNull()
                Log.d(TAG, "Notification cancel requested for $transferIdStr")
                if (transferId != null) {
                    activeConnections.values.toList().forEach { conn ->
                        if (conn.transferredFiles.containsKey(transferId)) {
                            Log.d(TAG, "Found connection for $transferId, closing")
                            conn.closeConnection()
                        }
                    }
                }
                transferIdStr?.let { SyncDashboardController.cancelTransfer(it, false) }
            }

            else -> {
                serviceScope.launch {
                    val enabled = !(app.androp.android.utils.BackgroundWorkController.isPaused || dataStoreManager.isAppPaused().first()) && dataStoreManager.isQuickShareEnabled().first()
                    if (enabled) {
                        startDiscoveryWithTimeout()
                    } else {
                        Log.d(TAG, "Service restarted by system but Quick Share is disabled, stopping")
                        stopDiscovery()
                    }
                }
            }
        }
        return START_NOT_STICKY
    }

    private fun startDiscoveryWithTimeout() {
        if (app.androp.android.utils.BackgroundWorkController.isPaused) { stopSelf(); return }
        discoveryJob?.cancel()

        SyncDashboardController.acquire(this, SyncDashboardController.OWNER_RECEIVE,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE, "Searching for files...")

        server.start()
        val port = server.port
        if (port == -1) {
            Log.e(TAG, "Failed to get server port")
            return
        }

        discoveryJob = serviceScope.launch {
            val persistedName = dataStoreManager.getDeviceName().first().ifBlank { null }
            val deviceName = persistedName ?: Build.MODEL
            Log.d(TAG, "Starting discovery with name: $deviceName")
            if (app.androp.android.utils.BackgroundWorkController.isPaused || dataStoreManager.isAppPaused().first()) return@launch
            advertiser.startAdvertising(deviceName, port)
            updateForegroundNotification("Quick Share is visible for 60s...")

            kotlinx.coroutines.delay(60_000) // 1 minute timeout

            if (activeConnections.isEmpty()) {
                Log.d(TAG, "Discovery timed out, stopping")
                stopDiscovery()
            } else {
                Log.d(TAG, "Discovery timed out but connections are active, keeping discovery on")
            }
        }
    }

    private fun stopDiscovery() {
        discoveryJob?.cancel()
        discoveryJob = null
        advertiser.stopAdvertising()

        if (activeConnections.isEmpty()) {
            SyncDashboardController.release(this, SyncDashboardController.OWNER_RECEIVE)
            stopSelf()
        } else {
            updateForegroundNotification("Active transfer in progress...")
        }
    }

    private fun createNotificationChannel() { SyncDashboardController.initialize(this) }

    private fun updateForegroundNotification(content: String) {
        SyncDashboardController.setOwnerStatus(SyncDashboardController.OWNER_RECEIVE, content)
    }

    fun showConsentNotification(connectionId: String, deviceName: String, fileName: String) {
        SyncDashboardController.consent(connectionId, deviceName, fileName)
    }

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onDestroy() {
        if (instance === this) instance = null
        serviceScope.cancel()
        discoveryJob?.cancel()
        advertiser.stopAdvertising()
        server.stop()
        activeConnections.values.toList().forEach { it.closeConnection() }
        activeConnections.clear()
        SyncDashboardController.release(this, SyncDashboardController.OWNER_RECEIVE)
        super.onDestroy()
    }
}
