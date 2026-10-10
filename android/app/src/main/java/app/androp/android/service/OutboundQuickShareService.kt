package app.androp.android.service

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.provider.OpenableColumns
import android.util.Log
import app.androp.android.R
import app.androp.android.data.local.DataStoreManager
import app.androp.android.quickshare.OutboundQuickShareConnection
import app.androp.android.quickshare.QuickShareDiscovery
import app.androp.android.utils.TransferNetworkManager
import app.androp.android.utils.WebSocketUtil
import app.androp.android.utils.NotificationUtil
import app.androp.android.utils.SyncDashboardController
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.isActive
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.ensureActive
import java.io.File
import java.net.Socket
import java.net.InetSocketAddress

/**
 * Foreground service that sends one or more files to the paired Mac via Quick Share, initiated
 * from within the AirSync app (share-sheet target) rather than Android's system Quick Share.
 * Mirrors QuickShareService's structure, but drives OutboundQuickShareConnection instead.
 */
class OutboundQuickShareService : Service() {

    companion object {
        private const val TAG = "OutboundQuickShare"
        private const val DISCOVERY_TIMEOUT_MS = 15_000L

        const val EXTRA_URIS = "uris"
        private const val EXTRA_PAIRING_KEY = "paired_transfer_key"
        private const val EXTRA_NETWORK_LEASE = "network_lease"

        @Volatile var isSending = false
            private set

        @Synchronized
        fun start(context: Context, uris: List<Uri>, pairingKey: String, networkLease: String? = null): Boolean {
            if (isSending || uris.isEmpty() || uris.size > 256 || app.androp.android.utils.BackgroundWorkController.isPaused) return false
            if (WebSocketUtil.authenticatedPeerAddress(pairingKey) == null) return false
            isSending = true
            val intent = Intent(context, OutboundQuickShareService::class.java).apply {
                putParcelableArrayListExtra(EXTRA_URIS, ArrayList(uris))
                putExtra(EXTRA_PAIRING_KEY, pairingKey)
                putExtra(EXTRA_NETWORK_LEASE, networkLease)
            }
            return try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent)
                else context.startService(intent)
                true
            } catch (error: RuntimeException) {
                isSending = false
                Log.w(TAG, "Couldn't start file transfer service", error)
                false
            }
        }
    }

    private lateinit var dataStoreManager: DataStoreManager
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var discovery: QuickShareDiscovery? = null
    private var connection: OutboundQuickShareConnection? = null
    private val connecting = java.util.concurrent.atomic.AtomicBoolean(false)
    private var activeStart = false
    private var foregroundReady = false
    @Volatile
    private var pendingSocket: Socket? = null
    private var outgoingCacheFiles: List<File> = emptyList()
    private var expectedPairingKey: String? = null
    private var networkLease: String? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        dataStoreManager = DataStoreManager.getInstance(this)
        foregroundReady = SyncDashboardController.acquire(this, SyncDashboardController.OWNER_SEND,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE, "Preparing to send...")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val uris: List<Uri> = intent?.getParcelableArrayListExtra(EXTRA_URIS) ?: emptyList()
        if (activeStart) return START_NOT_STICKY
        expectedPairingKey = intent?.getStringExtra(EXTRA_PAIRING_KEY)
        networkLease = intent?.getStringExtra(EXTRA_NETWORK_LEASE)
        // Own the complete staged batch before any permission, pause or discovery failure.
        // This also cleans unreadable files instead of only the metadata-success subset.
        outgoingCacheFiles = uris.filter { it.scheme == "file" }.mapNotNull { it.path?.let(::File) }
        if (!foregroundReady) { stopSelf(); return START_NOT_STICKY }
        if (uris.isEmpty()) {
            Log.w(TAG, "No files to send, stopping")
            stopSelf()
            return START_NOT_STICKY
        }

        activeStart = true
        serviceScope.launch {
            try {
            if ((app.androp.android.utils.BackgroundWorkController.isPaused || dataStoreManager.isAppPaused().first())) {
                stopSelf()
                return@launch
            }
            val pairedDevice = dataStoreManager.getLastConnectedDevice().first()
            if (pairedDevice == null) {
                Log.w(TAG, "No paired Mac, cannot send")
                updateNotification("No paired Mac found")
                stopSelf()
                return@launch
            }

            val expected = expectedPairingKey
            if (expected == null || pairedDevice.symmetricKey != expected ||
                WebSocketUtil.authenticatedPeerAddress(expected) == null || dataStoreManager.getUserManuallyDisconnected().first()) {
                updateNotification("Connection changed before sending. Share the files again when connected.")
                stopSelf()
                return@launch
            }
            // Stop the active send on Pause, manual disconnect, pairing changes or loss of
            // the authenticated Wi-Fi session. A later reconnect never replays the files.
            serviceScope.launch {
                combine(dataStoreManager.getLastConnectedDevice(), dataStoreManager.isAppPaused(),
                    dataStoreManager.getUserManuallyDisconnected(), WebSocketUtil.connectionState) { device, paused, manual, _ ->
                    device?.symmetricKey != expected || paused || manual ||
                        WebSocketUtil.authenticatedPeerAddress(expected) == null
                }.first { it }
                stopSelf()
            }
            networkLease?.let { id -> serviceScope.launch {
                while (isActive) { TransferNetworkManager.keepAlive(id); delay(25_000) }
            } }

            // Must match SyncManager's fallback chain exactly — this is what the Mac stored as
            // AppState.shared.device?.name during pairing, and its Quick Share auto-accept does
            // an exact string match against it (no normalization), so any divergence here means
            // it silently falls through to a manual consent notification instead of auto-accepting.
            val ourName = dataStoreManager.getDeviceName().first().ifBlank { null }
                ?: app.androp.android.utils.DeviceInfoUtil.getDeviceName(this@OutboundQuickShareService)
            val files = uris.map { requireNotNull(toPendingFile(it)) { "Couldn't read all selected files" } }
            if (files.isEmpty()) {
                Log.w(TAG, "Could not read any of the shared files")
                updateNotification("Couldn't read the selected file(s)")
                stopSelf()
                return@launch
            }

            updateNotification("Looking for ${pairedDevice.name}...")
            findAndSend(pairedDevice.name, ourName, files)
            } catch (error: Exception) {
                if (error is kotlinx.coroutines.CancellationException) throw error
                Log.w(TAG, "Couldn't prepare transfer", error)
                updateNotification("Couldn't prepare all selected files. Share them again.")
                stopSelf()
            }
        }

        return START_NOT_STICKY
    }

    private suspend fun findAndSend(
        macName: String,
        ourName: String,
        files: List<OutboundQuickShareConnection.PendingFile>
    ) {
        val key = expectedPairingKey ?: run { stopSelf(); return }
        // A phone-hosted hotspot need not participate in Android's default NSD
        // network. New Macs advertise the ready listener through the paired
        // encrypted socket, allowing a direct connection to that exact peer.
        val advertisement = withTimeoutOrNull(6_000) {
            WebSocketUtil.quickShareAdvertisement.map {
                WebSocketUtil.authenticatedQuickShareAdvertisement(key)?.takeIf { it.port != null }
            }.filterNotNull().first()
        }
        val authenticatedHost = WebSocketUtil.authenticatedPeerAddress(key) ?: run { stopSelf(); return }
        if (advertisement?.port != null) {
            val latest = WebSocketUtil.authenticatedQuickShareAdvertisement(key)
            if (latest?.port != advertisement.port) {
                updateNotification("Mac file receiving changed. Share again when ready.")
                stopSelf()
                return
            }
            if (connecting.compareAndSet(false, true)) {
                connectAndSend(authenticatedHost, advertisement.port, macName, ourName, files)
            }
            return
        }
        if (WebSocketUtil.authenticatedQuickShareAdvertisement(key)?.supported == true) {
            updateNotification("Enable file receiving on your Mac, then share again.")
            delay(2000)
            stopSelf()
            return
        }
        // Older Macs do not advertise a port; preserve their existing discovery path.
        val d = QuickShareDiscovery(this)
        discovery = d
        val timeoutJob = serviceScope.launch {
            delay(DISCOVERY_TIMEOUT_MS)
            if (connection == null) {
                updateNotification("Couldn't find $macName")
                d.stop()
                delay(2000)
                stopSelf()
            }
        }
        d.start(macName, expectedHost = authenticatedHost) { resolved ->
            val address = expectedPairingKey?.let(WebSocketUtil::authenticatedPeerAddress) ?: return@start
            val expectedAddress = runCatching { java.net.InetAddress.getByName(address) }.getOrNull()
            if (resolved.host != expectedAddress || !connecting.compareAndSet(false, true)) return@start
            timeoutJob.cancel()
            d.stop()
            serviceScope.launch { connectAndSend(address, resolved.port, macName, ourName, files) }
        }
    }

    private suspend fun connectAndSend(
        address: String, port: Int, macName: String, ourName: String,
        files: List<OutboundQuickShareConnection.PendingFile>
    ) {
        try {
            check(port in 1..65535) { "Invalid file receiving endpoint" }
            if (app.androp.android.utils.BackgroundWorkController.isPaused || dataStoreManager.isAppPaused().first()) {
                stopSelf(); return
            }
            kotlinx.coroutines.currentCoroutineContext().ensureActive()
            val liveAddress = expectedPairingKey?.let(WebSocketUtil::authenticatedPeerAddress)
            check(liveAddress == address) { "Paired connection changed" }
            val socket = Socket()
            pendingSocket = socket
            kotlinx.coroutines.currentCoroutineContext().ensureActive()
            socket.connect(InetSocketAddress(address, port), 10_000)
            socket.tcpNoDelay = true
            socket.soTimeout = 60_000
            val conn = OutboundQuickShareConnection(
                context = this@OutboundQuickShareService,
                socket = socket,
                ourDeviceName = ourName,
                files = files
            )
            kotlinx.coroutines.currentCoroutineContext().ensureActive()
            connection = conn
            wireCallbacks(conn, macName)
            conn.start() // Receiver consent and the Quick Share handshake remain required.
        } catch (error: Exception) {
            runCatching { pendingSocket?.close() }
            if (error is kotlinx.coroutines.CancellationException) throw error
            Log.w(TAG, "Couldn't open the paired file receiver", error)
            updateNotification("Couldn't connect to $macName")
            delay(2000)
            stopSelf()
        }
    }

    private fun wireCallbacks(conn: OutboundQuickShareConnection, macName: String) {
        conn.onConnectionReady = { pin ->
            Log.d(TAG, "Connection ready, PIN: $pin")
            updateNotification("Connecting to $macName (PIN $pin)...")
        }

        conn.onRejected = {
            Log.d(TAG, "Transfer rejected by $macName")
            updateNotification("$macName declined the transfer")
            serviceScope.launch {
                kotlinx.coroutines.delay(2000)
                stopSelf()
            }
        }

        conn.onFileProgress = { fileName, percent, _, _, transferId ->
            NotificationUtil.showFileProgress(this, transferId.hashCode(), fileName, percent,
                transferId, isSending = true)
        }

        conn.onFileComplete = { fileName, transferId, success ->
            NotificationUtil.showFileComplete(
                this,
                transferId.hashCode(),
                fileName,
                success,
                isSending = true
            )
        }

        conn.onError = { e ->
            Log.e(TAG, "Transfer error", e)
            updateNotification("Failed to send to $macName")
            serviceScope.launch {
                kotlinx.coroutines.delay(2000)
                stopSelf()
            }
        }

        conn.onFinished = {
            Log.d(TAG, "Transfer to $macName finished")
            updateNotification("Sent to $macName")
            serviceScope.launch {
                kotlinx.coroutines.delay(1500)
                stopSelf()
            }
        }
    }

    private fun toPendingFile(uri: Uri): OutboundQuickShareConnection.PendingFile? {
        return try {
            // Files we cached ourselves (see QuickShareSendActivity.copyUrisToCache) — a plain
            // java.io.File is always the accurate source of truth for these, and ContentResolver
            // has no provider registered for the "file" scheme to query metadata from anyway.
            if (uri.scheme == "file") {
                val f = java.io.File(uri.path ?: return null)
                if (!f.isFile) {
                    Log.w(TAG, "Cached file missing or empty: $uri")
                    return null
                }
                return OutboundQuickShareConnection.PendingFile(
                    uri = uri,
                    name = f.name,
                    mimeType = java.net.URLConnection.guessContentTypeFromName(f.name) ?: "application/octet-stream",
                    size = f.length()
                )
            }

            var name = "file"
            var size = -1L
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val nameIdx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIdx = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (cursor.moveToFirst()) {
                    if (nameIdx >= 0) name = cursor.getString(nameIdx) ?: name
                    if (sizeIdx >= 0 && !cursor.isNull(sizeIdx)) size = cursor.getLong(sizeIdx)
                }
            }

            // OpenableColumns.SIZE is unreliable for some providers (returns 0/null) — the Mac
            // hard-rejects any chunk that would exceed the size we declared in FileMetadata, so
            // a wrong-but-truthy 0 here breaks the very first real chunk. Fall back to the AFD's
            // stat size, which reflects the real underlying file.
            if (size <= 0) {
                size = try {
                    contentResolver.openAssetFileDescriptor(uri, "r")?.use { it.length } ?: -1L
                } catch (e: Exception) {
                    -1L
                }
            }
            if (size < 0) {
                Log.w(TAG, "Could not determine size for $uri, skipping")
                return null
            }

            val mimeType = contentResolver.getType(uri) ?: "application/octet-stream"
            OutboundQuickShareConnection.PendingFile(
                uri = uri,
                name = name,
                mimeType = mimeType,
                size = size
            )
        } catch (e: Exception) {
            Log.e(TAG, "Failed to read metadata for $uri", e)
            null
        }
    }

    private fun createNotificationChannel() { SyncDashboardController.initialize(this) }

    private fun updateNotification(content: String) {
        SyncDashboardController.setOwnerStatus(SyncDashboardController.OWNER_SEND, content)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        serviceScope.cancel()
        networkLease?.let(TransferNetworkManager::stop)
        networkLease = null
        expectedPairingKey = null
        discovery?.stop()
        runCatching { pendingSocket?.close() }
        connection?.closeConnection()
        // Clean up the cache copies QuickShareSendActivity made (see copyUrisToCache) now that
        // this transfer attempt is done, successful or not.
        runCatching {
            val cacheRoot = File(cacheDir, "quickshare_outgoing").canonicalFile
            outgoingCacheFiles.forEach { file ->
                runCatching { if (file.canonicalFile.parentFile == cacheRoot) file.delete() }
            }
        }
        SyncDashboardController.release(this, SyncDashboardController.OWNER_SEND)
        isSending = false
        super.onDestroy()
    }
}
