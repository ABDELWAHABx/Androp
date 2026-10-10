package app.androp.android.utils

import android.content.Context
import android.util.Log
import app.androp.android.data.ble.BleConstants
import app.androp.android.data.ble.BleTransportBridge
import app.androp.android.domain.model.AudioInfo
import app.androp.android.widget.AirSyncWidgetProvider
import app.androp.android.utils.discovery.DiscoveryOrchestrator
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.isActive
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Singleton utility for managing the WebSocket connection to the AirSync Mac server.
 * Handles connection lifecycle, handshake, auto-reconnection, and message transport.
 */
object WebSocketUtil {
    private const val TAG = "WebSocketUtil"
    private const val HANDSHAKE_TIMEOUT_MS = 10_000L
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val connectionEpoch = ConnectionEpoch()
    private val connectionLock = Any()
    private val pendingSockets = java.util.concurrent.CopyOnWriteArraySet<WebSocket>()
    private var webSocket: WebSocket? = null
    private var client: OkHttpClient? = null
    var currentIpAddress: String? = null
    private var currentPort: Int? = null
    private var currentSymmetricKey: javax.crypto.SecretKey? = null
    private val isConnected = AtomicBoolean(false)
    private val isConnecting = AtomicBoolean(false)

    private fun updateConnectedStatus(status: Boolean) {
        isConnected.set(status)
        _connectionStateFlow.value = status
        if (!status) WebDavServer.revokeAccess()
        notifyConnectionStatusListeners(status)
        // A permanently held LOW_LATENCY Wi-Fi lock prevents the radio from sleeping.
        // WebSocket traffic and OS connection management do not require it.
    }

    // Transport state: true after OkHttp onOpen, false after closing/failure/disconnect
    private val isSocketOpen = AtomicBoolean(false)
    private val handshakeCompleted = AtomicBoolean(false)
    private val connectionStarted = AtomicBoolean(false)
    private val failedAttempts = java.util.concurrent.atomic.AtomicInteger(0)

    private var handshakeTimeoutJob: Job? = null
    private var connectionAttemptJob: Job? = null

    // Auto-reconnect machinery
    private var autoReconnectJob: Job? = null
    private var autoReconnectActive = AtomicBoolean(false)
    // Synchronous guard: DataStore persistence suspends, but queued callbacks must
    // respect Stop immediately while its persisted user-intent flag is being written.
    private val manualReconnectSuppressed = AtomicBoolean(false)
    private var autoReconnectStartTime: Long = 0L
    private var autoReconnectAttempts: Int = 0

    // Callback for connection status changes
    private var onConnectionStatusChanged: ((Boolean) -> Unit)? = null
    private var onMessageReceived: ((String) -> Unit)? = null

    // Application context for side-effects (notifications/services) when explicit context isn't provided
    private var appContext: Context? = null

    // Global connection status listeners for UI updates
    private val connectionStatusListeners = java.util.concurrent.CopyOnWriteArraySet<(Boolean) -> Unit>()

    private val _connectionStateFlow = MutableStateFlow(false)
    val connectionState = _connectionStateFlow.asStateFlow()

    private fun createClient(): OkHttpClient {
        return OkHttpClient.Builder()
            .connectTimeout(5, TimeUnit.SECONDS)
            .writeTimeout(30, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.SECONDS) // Keep connection alive
            .pingInterval(30, TimeUnit.SECONDS)
            .build()
    }

    // Manual connect listeners are invoked when a user-initiated connection starts (not auto reconnect)
    private val manualConnectListeners = java.util.concurrent.CopyOnWriteArraySet<() -> Unit>()

    fun registerManualConnectListener(listener: () -> Unit) {
        manualConnectListeners.add(listener)
    }

    fun unregisterManualConnectListener(listener: () -> Unit) {
        manualConnectListeners.remove(listener)
    }

    /**
     * Initiates a WebSocket connection to the specified IP and port.
     *
     * @param context Context for widget updates and service management.
     * @param ipAddress Target IP address(es), comma-separated if multiple.
     * @param port Target port.
     * @param symmetricKey Encryption key for secure communication.
     * @param onConnectionStatus Callback for connection success/failure.
     * @param onMessage Callback for received messages.
     * @param manualAttempt True if triggered by user interaction, false if auto-reconnect.
     * @param onHandshakeTimeout Callback invoked if handshake fails (e.g., auth error).
     */
    fun connect(
        context: Context,
        ipAddress: String,
        port: Int,
        symmetricKey: String?,
        onConnectionStatus: ((Boolean) -> Unit)? = null,
        onMessage: ((String) -> Unit)? = null,
        manualAttempt: Boolean = true,
        onHandshakeTimeout: (() -> Unit)? = null
    ) {
        // Cache application context for future cleanup even if callers don't pass context on disconnect
        appContext = context.applicationContext

        val epoch = synchronized(connectionLock) {
            if (BackgroundWorkController.isPaused || isConnected.get() || isConnecting.get()) {
                Log.d(TAG, "Already connected or connecting")
                return
            }
            if (manualAttempt) manualReconnectSuppressed.set(false)
            else if (manualReconnectSuppressed.get()) return
            isConnecting.set(true)
            connectionEpoch.advance()
        }
        WebSocketFileTransfer.cancelAll()

        // If user initiates a manual attempt, stop any auto-reconnect loop
        if (manualAttempt) {
            cancelAutoReconnect()
        }

        // Validate local network IP
        scope.launch {
            val ds = app.androp.android.data.local.DataStoreManager.getInstance(context)
            if (ds.isAppPaused().first() || BackgroundWorkController.isPaused || !connectionEpoch.isCurrent(epoch)) {
                if (connectionEpoch.isCurrent(epoch)) isConnecting.set(false)
                return@launch
            }
            if (!manualAttempt && (manualReconnectSuppressed.get() || ds.getUserManuallyDisconnected().first() || !ds.getAutoReconnectEnabled().first())) {
                if (connectionEpoch.isCurrent(epoch)) isConnecting.set(false)
                return@launch
            }
            // Validate before launching socket work. A malformed persisted endpoint
            // must not throw from a child coroutine and leave Connecting stuck.
            val ipList = ConnectionEndpoints.hosts(ipAddress, port)

            if (ipList.isEmpty()) {
                Log.e(TAG, "No valid IP addresses provided")
                isConnecting.set(false)
                onConnectionStatus?.invoke(false)
                return@launch
            }

            // Validate at least one local network IP
            val localIps = ipList.filter { isLocalNetwork(context, it) }
            if (localIps.isEmpty()) {
                Log.e(TAG, "None of the provided IP addresses are in the local network: $ipAddress")
                isConnecting.set(false)
                onConnectionStatus?.invoke(false)
                return@launch
            }

            if (!isActive || !connectionEpoch.isCurrent(epoch) || BackgroundWorkController.isPaused) return@launch
            handshakeCompleted.set(false)
            notifyConnectionStatusListeners(false)

            // Reset manual disconnect flag on manual attempt
            if (manualAttempt) {
                try {
                    val ds = app.androp.android.data.local.DataStoreManager.getInstance(context)
                    ds.setUserManuallyDisconnected(false)
                } catch (_: Exception) {
                }
            }

            // Update widgets to show "Connecting…" immediately
            try {
                AirSyncWidgetProvider.updateAllWidgets(context)
            } catch (_: Exception) {
            }

            // Notify listeners that a manual connection attempt has begun
            if (manualAttempt) {
                manualConnectListeners.forEach { listener ->
                    try {
                        listener()
                    } catch (e: Exception) {
                        Log.w(TAG, "ManualConnectListener error: ${e.message}")
                    }
                }
            }
            currentIpAddress = ipAddress
            currentPort = port
            currentSymmetricKey = try {
                symmetricKey?.let { CryptoUtil.decodeKey(it) }
            } catch (_: IllegalArgumentException) {
                isConnecting.set(false)
                onConnectionStatus?.invoke(false)
                notifyConnectionStatusListeners(false)
                return@launch
            }
            onConnectionStatusChanged = onConnectionStatus
            onMessageReceived = onMessage

            try {
                if (client == null) {
                    client = createClient()
                }

                connectionAttemptJob?.cancel()
                connectionStarted.set(false)
                failedAttempts.set(0)

                // Overall timeout for all parallel connection attempts
                connectionAttemptJob = scope.launch {
                    delay(15000) // 15 seconds global timeout
                    if (connectionEpoch.isCurrent(epoch) && isConnecting.get() && !isSocketOpen.get()) {
                        connectionEpoch.advance()
                        pendingSockets.forEach { it.cancel() }
                        pendingSockets.clear()
                        Log.w(TAG, "All connection attempts timed out")
                        isConnecting.set(false)
                        onConnectionStatusChanged?.invoke(false)
                        notifyConnectionStatusListeners(false)
                        tryStartAutoReconnect(context)
                        try {
                            AirSyncWidgetProvider.updateAllWidgets(context)
                        } catch (_: Exception) {
                        }
                    }
                }

                // Try each IP in parallel
                localIps.forEach { ip ->
                    // Handle IPv6 addresses, wrapping them in brackets for URI parsing.
                    // Also handle link-local scope zones (e.g. fe80::18cd:e714:19a7:2c21%wlan0 -> [fe80::18cd:e714:19a7:2c21])
                    val formattedIp = if (ip.contains(":")) {
                        var cleanIp = ip
                        if (cleanIp.contains("%")) {
                            cleanIp = cleanIp.substringBefore("%")
                        }
                        if (!cleanIp.startsWith("[")) {
                            "[$cleanIp]"
                        } else {
                            cleanIp
                        }
                    } else {
                        ip
                    }
                    val url = "ws://$formattedIp:$port/socket"
                    Log.d(TAG, "Attempting connection to $url")

                    run {
                        if (!connectionEpoch.isCurrent(epoch) || BackgroundWorkController.isPaused || isConnected.get() || connectionStarted.get()) return@run

                        val request = Request.Builder()
                            .url(url)
                            .build()

                        val perAttemptClient = client!!.newBuilder()
                            .connectTimeout(5, TimeUnit.SECONDS)
                            .readTimeout(
                                0,
                                TimeUnit.MILLISECONDS
                            ) // websockets should have no read timeout
                            .build()

                        val listener = object : WebSocketListener() {
                            override fun onOpen(webSocket: WebSocket, response: Response) {
                                synchronized(connectionLock) {
                                    if (!connectionEpoch.isCurrent(epoch) || BackgroundWorkController.isPaused) {
                                        pendingSockets.remove(webSocket)
                                        webSocket.cancel()
                                        return
                                    }
                                    if (isConnected.get() || !connectionStarted.compareAndSet(
                                            false,
                                            true
                                        )
                                    ) {
                                        pendingSockets.remove(webSocket)
                                        webSocket.cancel()
                                        return
                                    }
                                    Log.d(TAG, "WebSocket connected to $url")

                                    connectionAttemptJob?.cancel()
                                    WebSocketUtil.webSocket = webSocket
                                    pendingSockets.filter { it != webSocket }.forEach { it.cancel() }
                                    pendingSockets.clear()
                                    currentIpAddress = ip // Store the successful IP
                                    isSocketOpen.set(true)
                                    updateConnectedStatus(false)
                                    isConnecting.set(true)

                                    try {
                                        SyncManager.performInitialSync(context)
                                    } catch (_: Exception) {
                                    }

                                    handshakeTimeoutJob?.cancel()
                                    handshakeTimeoutJob = scope.launch {
                                        try {
                                            delay(HANDSHAKE_TIMEOUT_MS)
                                            if (connectionEpoch.isCurrent(epoch) && !handshakeCompleted.get()) {
                                                Log.w(TAG, "Handshake timed out")
                                                updateConnectedStatus(false)
                                                isConnecting.set(false)
                                                try {
                                                    webSocket.close(4001, "Handshake timeout")
                                                } catch (_: Exception) {
                                                }
                                                if (manualAttempt) {
                                                    try {
                                                        val ds =
                                                            app.androp.android.data.local.DataStoreManager(
                                                                context
                                                            )
                                                        ds.setUserManuallyDisconnected(true)
                                                    } catch (_: Exception) {
                                                    }
                                                }
                                                onConnectionStatusChanged?.invoke(false)
                                                notifyConnectionStatusListeners(false)
                                                onHandshakeTimeout?.invoke()
                                                try {
                                                    AirSyncWidgetProvider.updateAllWidgets(context)
                                                } catch (_: Exception) {
                                                }
                                            }
                                        } catch (_: Exception) {
                                        }
                                    }
                                }
                            }

                            override fun onMessage(webSocket: WebSocket, text: String) {
                                synchronized(connectionLock) {
                                    if (!connectionEpoch.isCurrent(epoch) || BackgroundWorkController.isPaused || webSocket != WebSocketUtil.webSocket) return
                                    Log.d(TAG, "WebSocket message received (${text.length} characters)")
                                    val key = currentSymmetricKey
                                    val decryptedMessage = if (key != null) {
                                        CryptoUtil.decryptMessage(text, key) ?: return
                                    } else text

                                    if (!handshakeCompleted.get()) {
                                        val handshakeOk = try {
                                            val json = org.json.JSONObject(decryptedMessage)
                                            json.optString("type") == "macInfo"
                                        } catch (_: Exception) {
                                            false
                                        }
                                        if (handshakeOk) {
                                            handshakeCompleted.set(true)
                                            ClipboardSyncManager.onPeerChanged(symmetricKey)
                                            try {
                                                AirSyncWidgetProvider.updateAllWidgets(context)
                                            } catch (_: Exception) {
                                            }
                                            updateConnectedStatus(true)
                                            isConnecting.set(false)
                                            handshakeTimeoutJob?.cancel()
                                            scope.launch {
                                                 try {
                                                     val ds =
                                                         app.androp.android.data.local.DataStoreManager.getInstance(
                                                             context
                                                         )
                                                     if (!connectionEpoch.isCurrent(epoch) || BackgroundWorkController.isPaused || manualReconnectSuppressed.get()) return@launch
                                                     val lastDevice = ds.getLastConnectedDevice().first()
                                                     if (!connectionEpoch.isCurrent(epoch) || BackgroundWorkController.isPaused || manualReconnectSuppressed.get()) return@launch
                                                     app.androp.android.service.AirSyncService.start(
                                                         context,
                                                         lastDevice?.name
                                                     )
                                                 } catch (e: Exception) {
                                                     Log.e(
                                                         TAG,
                                                         "Error starting AirSyncService: ${e.message}"
                                                     )
                                                 }
                                             }
                                            try {
                                                SyncManager.startPeriodicSync(context)
                                            } catch (_: Exception) {
                                            }

                                            onConnectionStatusChanged?.invoke(true)
                                            notifyConnectionStatusListeners(true)
                                            cancelAutoReconnect()
                                            try {
                                                AirSyncWidgetProvider.updateAllWidgets(context)
                                            } catch (_: Exception) {
                                            }
                                        }
                                        if (!handshakeCompleted.get()) return
                                    }

                                    WebSocketMessageHandler.handleIncomingMessage(
                                        context,
                                        decryptedMessage
                                    )
                                    updateLastSyncTime(context)
                                    onMessageReceived?.invoke(decryptedMessage)
                                }
                            }

                            override fun onClosing(
                                webSocket: WebSocket,
                                code: Int,
                                reason: String
                            ) {
                                synchronized(connectionLock) {
                                    if (!connectionEpoch.isCurrent(epoch)) return
                                    webSocket.close(code, reason)
                                    if (webSocket == WebSocketUtil.webSocket) {
                                        WebSocketFileTransfer.cancelAll()
                                        if (!app.androp.android.data.ble.BleGattServer.isAnyAuthenticated()) SyncManager.stopPeriodicSync()
                                        if (code != 1000 || reason != "Manual disconnection") {
                                            if (app.androp.android.AirSyncApp.isAppForeground()) {
                                                CoroutineScope(Dispatchers.Main).launch {
                                                    val msg =
                                                        reason.ifEmpty { "Unknown Server Disconnect" }
                                                    android.widget.Toast.makeText(
                                                        context,
                                                        "Disconnected: $msg",
                                                        android.widget.Toast.LENGTH_SHORT
                                                    ).show()
                                                }
                                            }
                                        }
                                        updateConnectedStatus(false)
                                        isSocketOpen.set(false)
                                        isConnecting.set(false)
                                        handshakeCompleted.set(false)
                                        handshakeTimeoutJob?.cancel()
                                        currentIpAddress = null
                                        try {
                                            ServiceManager.updateServiceState(context)
                                        } catch (_: Exception) {
                                        }
                                        if (!isConnected()) {
                                            try {
                                                app.androp.android.utils.MacDeviceStatusManager.cleanup(context)
                                            } catch (_: Exception) {
                                            }
                                        }
                                        onConnectionStatusChanged?.invoke(false)
                                        notifyConnectionStatusListeners(false)

                                        // Only auto-reconnect if it wasn't a manual close
                                        if (code != 1000 || reason != "Manual disconnection") {
                                            tryStartAutoReconnect(context)
                                        }

                                        try {
                                            AirSyncWidgetProvider.updateAllWidgets(context)
                                        } catch (_: Exception) {
                                        }
                                    }
                                }
                            }

                            override fun onFailure(
                                webSocket: WebSocket,
                                t: Throwable,
                                response: Response?
                            ) {
                                synchronized(connectionLock) {
                                    pendingSockets.remove(webSocket)
                                    if (!connectionEpoch.isCurrent(epoch) || BackgroundWorkController.isPaused) return
                                    val totalToTry = localIps.size
                                    val failedCount = failedAttempts.incrementAndGet()
                                    val wasActive = webSocket == WebSocketUtil.webSocket
                                    val isFinalManualAttempt =
                                        !connectionStarted.get() && failedCount >= totalToTry

                                    if (wasActive || isFinalManualAttempt) {
                                        WebSocketFileTransfer.cancelAll()
                                        if (!app.androp.android.data.ble.BleGattServer.isAnyAuthenticated()) SyncManager.stopPeriodicSync()
                                        if (manualAttempt || isSocketOpen.get()) {
                                            if (app.androp.android.AirSyncApp.isAppForeground()) {
                                                CoroutineScope(Dispatchers.Main).launch {
                                                    val msg = when (t) {
                                                        is java.net.ConnectException -> "Connection Refused (Is androp Mac running?)"
                                                        is java.net.SocketTimeoutException -> "Could not discover your mac"
                                                        is java.net.UnknownHostException -> "Could not reach your mac"
                                                        is java.io.EOFException, is java.net.SocketException -> "Lost connection to your mac"
                                                        else -> t.message ?: "Unknown connection error"
                                                    }
                                                    android.widget.Toast.makeText(
                                                        context,
                                                        "androp: $msg",
                                                        android.widget.Toast.LENGTH_LONG
                                                    ).show()
                                                }
                                            }
                                        }
                                        updateConnectedStatus(false)
                                        isConnecting.set(false)
                                        isSocketOpen.set(false)
                                        handshakeCompleted.set(false)
                                        handshakeTimeoutJob?.cancel()
                                        connectionAttemptJob?.cancel()
                                        currentIpAddress = null
                                        try {
                                            ServiceManager.updateServiceState(context)
                                        } catch (_: Exception) {
                                        }
                                        if (!isConnected()) {
                                            try {
                                                app.androp.android.utils.MacDeviceStatusManager.cleanup(context)
                                            } catch (_: Exception) {
                                            }
                                        }
                                        onConnectionStatusChanged?.invoke(false)
                                        notifyConnectionStatusListeners(false)

                                        // Check manual disconnect flag before auto-reconnecting on failure
                                        scope.launch {
                                            try {
                                                val ds =
                                                    app.androp.android.data.local.DataStoreManager.getInstance(
                                                        context
                                                    )
                                                val manual = ds.getUserManuallyDisconnected().first()
                                                if (!manual && connectionEpoch.isCurrent(epoch)) {
                                                    tryStartAutoReconnect(context)
                                                }
                                            } catch (_: Exception) {
                                                // Unknown persisted user intent must not restart work.
                                            }
                                        }

                                        try {
                                            AirSyncWidgetProvider.updateAllWidgets(context)
                                        } catch (_: Exception) {
                                        }
                                    }
                                }
                            }
                        }
                        val candidate = perAttemptClient.newWebSocket(request, listener)
                        pendingSockets.add(candidate)
                        if (!connectionEpoch.isCurrent(epoch) || BackgroundWorkController.isPaused ||
                            (connectionStarted.get() && candidate != WebSocketUtil.webSocket)) {
                            pendingSockets.remove(candidate)
                            candidate.cancel()
                        }
                    }
                }
            } catch (e: Exception) {
                if (!connectionEpoch.isCurrent(epoch)) return@launch
                Log.e(TAG, "Failed to create WebSocket: ${e.message}")
                connectionEpoch.advance()
                pendingSockets.forEach { it.cancel() }
                pendingSockets.clear()
                connectionAttemptJob?.cancel()
                isConnecting.set(false)
                handshakeCompleted.set(false)
                onConnectionStatusChanged?.invoke(false)
            }
        }
    }

    private suspend fun isLocalNetwork(context: Context, ipAddress: String): Boolean {
        // Check if expand networking is enabled - if so, allow all IPs
        val ds = app.androp.android.data.local.DataStoreManager(context)
        val expandNetworkingEnabled = ds.getExpandNetworkingEnabled().first()
        if (expandNetworkingEnabled) {
            return true
        }

        // Handle IPv6 address checks
        if (ipAddress.contains(":")) {
            // Check for IPv6 localhost (::1) or Link-local (fe80::)
            val cleanIp = ipAddress.lowercase().trim().removeSurrounding("[", "]").substringBefore("%")
            if (cleanIp == "::1" || cleanIp.startsWith("fe80:")) {
                return true
            }
            // Other common local/unique-local IPv6 prefixes (fc00::/7)
            if (cleanIp.startsWith("fc") || cleanIp.startsWith("fd")) {
                return true
            }
            return false
        }

        // Check standard private IP ranges (RFC 1918) and Carrier-Grade NAT (Tailscale/VPNs)
        if (ipAddress.startsWith("192.168.") || ipAddress.startsWith("10.") || ipAddress.startsWith(
                "100."
            )
        ) {
            return true
        }
        // Check 172.16.0.0 to 172.31.255.255 range
        if (ipAddress.startsWith("172.")) {
            val parts = ipAddress.split(".")
            if (parts.size >= 2) {
                val secondOctet = parts[1].toIntOrNull()
                if (secondOctet != null && secondOctet in 16..31) {
                    return true
                }
            }
        }
        // Check localhost
        if (ipAddress == "127.0.0.1" || ipAddress == "localhost") {
            return true
        }
        return false
    }

    /**
     * Sends a text message over the WebSocket connection.
     * Encrypts the message if a symmetric key is active.
     *
     * @param message The raw JSON message string to send.
     * @return True if the message was enqueued, false if not connected.
     */
    fun sendMessage(message: String): Boolean {
        val snapshot = synchronized(connectionLock) {
            if (BackgroundWorkController.isPaused) return false
            val socket = webSocket
            if (isSocketOpen.get() && socket != null) socket to currentSymmetricKey else null
        }
        if (snapshot != null) {
            val (socket, key) = snapshot
            val messageToSend = if (key != null) {
                CryptoUtil.encryptMessage(message, key) ?: return false
            } else message
            // Pause/disconnect may have happened while encryption ran; do not send to an old socket.
            return synchronized(connectionLock) {
                if (BackgroundWorkController.isPaused || socket !== webSocket || !isSocketOpen.get()) false
                else {
                    Log.d(TAG, "Sending WebSocket message (${message.length} characters)")
                    socket.send(messageToSend)
                }
            }
        }
        val ble = app.androp.android.AirSyncApp.getBleConnectionManager()
        if (!BackgroundWorkController.isPaused && ble?.isAuthenticated == true) {
            Log.d(TAG, "Sending BLE fallback message (${message.length} characters)")
            return sendOverBLE(message)
        }
        Log.w(TAG, "Neither WebSocket nor BLE connected, cannot send message")
        return false
    }

    private fun sendOverBLE(message: String): Boolean {
        if (BackgroundWorkController.isPaused) return false
        val ble = app.androp.android.AirSyncApp.getBleConnectionManager() ?: return false
        try {
            val json = JSONObject(message)
            val type = json.optString("type")
            val data = json.optJSONObject("data") ?: JSONObject()

            if (app.androp.android.data.ble.BleControlPolicy.acceptsOutgoing(type, message.toByteArray(Charsets.UTF_8).size)) {
                return ble.sendChunkedNotification(BleConstants.CHAR_MAC_CONTROL, message)
            }

            when (type) {
                "macPowerControl" -> {
                    if (!ble.isAuthenticated) return false
                    val action = data.optString("action")
                    val requestId = data.optString("requestId")
                    if (requestId.isEmpty() || requestId.length > 128 || action !in setOf("setKeepAwake", "sleep")) return false
                    if (action == "setKeepAwake" && data.opt("enabled") !is Boolean) return false
                    val command = JSONObject().put("action", action).put("requestId", requestId)
                    if (action == "setKeepAwake") command.put("enabled", data.getBoolean("enabled"))
                    val payload = JSONObject().put("type", type).put("data", command).toString()
                    return ble.sendChunkedNotification(BleConstants.CHAR_MAC_CONTROL, payload)
                }
                "notificationAction" -> {
                    val pkg = data.optString("package")
                    val actionId = data.optString("actionId")
                    val payload = "$pkg|$actionId"
                    return ble.sendChunkedNotification(BleConstants.CHAR_NOTIFICATION_ACTION, payload)
                }

                "mediaControl" -> {
                    val action = data.optString("action")
                    // Protocol: type|action
                    val payload = "media|$action"
                    return ble.sendChunkedNotification(BleConstants.CHAR_MAC_CONTROL, payload)
                }

                "volumeControl" -> {
                    val action = data.optString("action")
                    // Protocol: type|action
                    val payload = if (action == "vol_set") "volume|$action|${data.optInt("value", -1)}" else "volume|$action"
                    return ble.sendChunkedNotification(BleConstants.CHAR_MAC_CONTROL, payload)
                }

                "clipboard", "clipboardUpdate" -> {
                    return BleTransportBridge.sendClipboardEnvelope(data)
                }

                "clipboardAck" -> return BleTransportBridge.sendClipboardEnvelope(data, acknowledgement = true)

                "dismissNotification" -> {
                    val id = data.optString("id")
                    return ble.sendChunkedNotification(BleConstants.CHAR_NOTIFICATION_DISMISS_NOTIFY, id)
                }

                "remoteControl" -> {
                    if (!app.androp.android.data.ble.BleControlPolicy.acceptsRemoteAction(data.optString("action")) ||
                        message.toByteArray(Charsets.UTF_8).size > app.androp.android.data.ble.BleControlPolicy.MAX_CONTROL_BYTES) return false
                    return ble.sendChunkedNotification(BleConstants.CHAR_MAC_CONTROL, message)
                }

                "notification" -> {
                    return BleTransportBridge.sendNotification(data)
                }

                "notificationUpdate" -> {
                    if (data.optBoolean("dismissed") || data.optString("action") == "dismiss") {
                        return BleTransportBridge.sendNotificationDismissal(data.optString("id"))
                    }
                    return false
                }

                "status" -> return BleTransportBridge.sendCompactStatus(data)

            }
        } catch (e: Exception) {
            Log.e(TAG, "Error sending over BLE fallback: ${e.message}")
        }
        return false
    }

    /**
     * Disconnects the WebSocket and cleans up resources.
     * Stops related services (AirSyncService, periodic sync) and updates UI state.
     *
     * @param manual True only for a user-initiated disconnect. Persists the manual-disconnect
     * flag and tells the Mac so neither side auto-reconnects. Internal/automatic disconnects
     * (handshake timeout, network change, socket error) must pass false so auto-reconnect can
     * still resume.
     */
    fun disconnect(context: Context? = null, manual: Boolean = false) {
        WebSocketFileTransfer.cancelAll()
        synchronized(connectionLock) {
            if (manual) manualReconnectSuppressed.set(true)
            Log.d(TAG, "Disconnecting WebSocket (manual=$manual)")

            if (manual) {
                sendMessage("{\"type\":\"userDisconnected\",\"data\":{}}")
            }

            val disconnectEpoch = connectionEpoch.advance()
            scope.coroutineContext.cancelChildren()
            connectionAttemptJob?.cancel()
            connectionAttemptJob = null
            pendingSockets.forEach { it.cancel() }
            pendingSockets.clear()
            SyncManager.stopPeriodicSync()
            updateConnectedStatus(false)
            isConnecting.set(false)
            isSocketOpen.set(false)
            handshakeCompleted.set(false)
            handshakeTimeoutJob?.cancel()
            currentIpAddress = null

            val ctx = context ?: appContext

            if (manual && !BackgroundWorkController.isPaused) {
                ctx?.let { c ->
                    scope.launch {
                        try {
                            val ds = app.androp.android.data.local.DataStoreManager.getInstance(c)
                            ds.setUserManuallyDisconnected(true)
                            // DataStore is now authoritative, including a later explicit
                            // Mac/BLE connect that clears the persisted user choice.
                            if (connectionEpoch.isCurrent(disconnectEpoch)) manualReconnectSuppressed.set(false)
                        } catch (_: Exception) {
                        }
                    }
                }
            }

            val closingSocket = webSocket
            if (BackgroundWorkController.isPaused) closingSocket?.cancel()
            else closingSocket?.close(1000, if (manual) "Manual disconnection" else "Disconnected")
            webSocket = null

            // Transition back to scanning on disconnect
            ctx?.let { c ->
                try {
                    ServiceManager.updateServiceState(c)
                } catch (e: Exception) {
                    Log.e(TAG, "Error updating service state on disconnect: ${e.message}")
                }
            }

            onConnectionStatusChanged?.invoke(false)

            // Resolve a context for side-effects (try provided one, fall back to appContext)
            // Clear continue browsing notifications if possible
            ctx?.let { c ->
                try {
                    NotificationUtil.clearContinueBrowsingNotifications(c)
                } catch (_: Exception) {
                }
            }

            // Notify listeners about the disconnection
            notifyConnectionStatusListeners(false)
            // Stop any auto-reconnect in progress
            cancelAutoReconnect()
            // Stop media player if running
            ctx?.let { c ->
                try {
                    app.androp.android.service.MacMediaPlayerService.stopMacMedia(c)
                } catch (_: Exception) {
                }
            }

            // Disconnect any active BLE transport connections
            try {
                val bleManager = app.androp.android.AirSyncApp.getBleConnectionManager()
                if (manual && bleManager != null && bleManager.isAuthenticated) {
                    BleTransportBridge.sendManualDisconnect()
                }
                bleManager?.disconnectAllConnectedDevices()
            } catch (e: Exception) {
                Log.w(TAG, "Error disconnecting BLE devices: ${e.message}")
            }

            // Update widgets to reflect new state
            ctx?.let { c ->
                try {
                    AirSyncWidgetProvider.updateAllWidgets(c)
                } catch (_: Exception) {
                }
            }
        }
    }

    fun cleanup() {
        disconnect()

        // Reset sync manager state
        SyncManager.reset()

        client?.dispatcher?.executorService?.shutdown()
        client = null
        currentIpAddress = null
        currentPort = null
        currentSymmetricKey = null
        onConnectionStatusChanged = null
        onMessageReceived = null
        handshakeCompleted.set(false)
        handshakeTimeoutJob?.cancel()
        appContext = null
    }

    fun isWifiConnected(): Boolean {
        return isConnected.get()
    }

    fun isConnected(): Boolean {
        return isConnected.get() || app.androp.android.data.ble.BleGattServer.isAnyAuthenticated()
    }

    fun isConnecting(): Boolean {
        return isConnecting.get()
    }

    private val lastSyncTimeCache = java.util.concurrent.atomic.AtomicLong(0L)

    private fun updateLastSyncTime(context: Context) {
        val now = System.currentTimeMillis()
        // Only update if at least 60 seconds have passed since last write
        val previous = lastSyncTimeCache.get()
        if (now - previous < 60_000L || !lastSyncTimeCache.compareAndSet(previous, now)) {
            return
        }

        scope.launch {
            try {
                val dataStoreManager = app.androp.android.data.local.DataStoreManager(context)
                dataStoreManager.updateLastSyncTime(now)
            } catch (e: Exception) {
                Log.e(TAG, "Error updating last sync time: ${e.message}")
            }
        }
    }

    // Register a global connection status listener
    fun registerConnectionStatusListener(listener: (Boolean) -> Unit) {
        connectionStatusListeners.add(listener)
    }

    // Unregister a global connection status listener
    fun unregisterConnectionStatusListener(listener: (Boolean) -> Unit) {
        connectionStatusListeners.remove(listener)
    }

    // Notify listeners about the connection status
    private fun notifyConnectionStatusListeners(isConnected: Boolean) {
        ClipboardSyncManager.onTransportChanged(this.isConnected())
        connectionStatusListeners.forEach { listener ->
            try { listener(isConnected) }
            catch (e: Exception) { Log.w(TAG, "Connection listener failed", e) }
        }
    }

    // Public API to cancel auto reconnect (from Stop action)
    fun cancelAutoReconnect() {
        autoReconnectActive.set(false)
        autoReconnectJob?.cancel()
        autoReconnectJob = null
        autoReconnectAttempts = 0
        autoReconnectStartTime = 0L
        notifyConnectionStatusListeners(false)
    }

    fun isAutoReconnecting(): Boolean = autoReconnectActive.get()

    fun stopAutoReconnect(context: Context) {
        // Stop also cancels an in-flight connection, and survives later network events.
        disconnect(context, manual = true)
    }

    /**
     * Internal logic to attempt auto-reconnection to the last known device.
     * Uses a dual strategy: proactive exponential backoff AND discovery-triggered.
     */
    private fun tryStartAutoReconnect(context: Context) {
        if (BackgroundWorkController.isPaused || manualReconnectSuppressed.get() || !autoReconnectActive.compareAndSet(false, true)) return
        autoReconnectStartTime = System.currentTimeMillis()
        if (!app.androp.android.data.ble.BleGattServer.isAnyAuthenticated()) {
            notifyConnectionStatusListeners(false)
        }
        Log.d(TAG, "Starting Smart Auto-Reconnect strategy")

        autoReconnectJob?.cancel()
        autoReconnectJob = scope.launch {
            try {
                val ds = app.androp.android.data.local.DataStoreManager.getInstance(context)

                if (ds.isAppPaused().first() || ds.getUserManuallyDisconnected().first() || !ds.getAutoReconnectEnabled().first()) {
                    cancelAutoReconnect()
                    return@launch
                }
                // 1. Retry Loop (Try last known IPs immediately and periodically)
                launch {
                    var backoffMs = 2000L
                    var failedStreak = 0
                    while (isActive && autoReconnectActive.get() && !isConnected()) {
                        val manual = ds.getUserManuallyDisconnected().first()
                        val autoEnabled = ds.getAutoReconnectEnabled().first()

                        if (manual || manualReconnectSuppressed.get() || !autoEnabled || BackgroundWorkController.isPaused || ds.isAppPaused().first()) {
                            Log.d(
                                TAG,
                                "Auto-reconnect cancelled: manual=$manual, enabled=$autoEnabled"
                            )
                            cancelAutoReconnect()
                            break
                        }

                        // Check network capabilities before attempting Wi-Fi socket reconnect
                        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? android.net.ConnectivityManager
                        val activeNetwork = cm?.activeNetwork
                        val caps = cm?.getNetworkCapabilities(activeNetwork)
                        val hasWifiOrVpn = caps?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) == true ||
                                caps?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN) == true ||
                                caps?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_ETHERNET) == true

                        val expandNetworking = ds.getExpandNetworkingEnabled().first()
                        val canAttemptWifiSocket = hasWifiOrVpn || expandNetworking

                        if (!isConnecting.get() && canAttemptWifiSocket) {
                            val last = ds.getLastConnectedDevice().first()
                            if (last != null) {
                                val all = ds.getAllNetworkDeviceConnections().first()
                                val targetConnection =
                                    all.firstOrNull { it.deviceName == last.name }

                                if (targetConnection != null) {
                                    val ips =
                                        targetConnection.networkConnections.values.joinToString(",")
                                    val port = targetConnection.port.toIntOrNull() ?: 6997

                                    Log.d(
                                        TAG,
                                        "Proactive retry to $ips:$port (backoff: ${backoffMs}ms)"
                                    )
                                    connect(
                                        context = context,
                                        ipAddress = ips,
                                        port = port,
                                        symmetricKey = targetConnection.symmetricKey,
                                        manualAttempt = false,
                                        onConnectionStatus = { connected ->
                                            if (connected) {
                                                cancelAutoReconnect()
                                            }
                                        }
                                    )
                                }
                            }
                        }

                        delay(backoffMs)
                        failedStreak++
                        // Back off to two minutes when a device remains offline.
                        val maxCap = if (failedStreak > 10) 120_000L else 30_000L
                        backoffMs = (backoffMs * 1.5).toLong().coerceAtMost(maxCap)
                    }
                }

                // 2. Discovery Monitoring (Listen for presence packets in case IP changed)
                DiscoveryOrchestrator.discoveredDevices.collect { discoveredList ->
                    if (!autoReconnectActive.get() || manualReconnectSuppressed.get() || BackgroundWorkController.isPaused || isConnected() || isConnecting.get()) return@collect
                    if (ds.isAppPaused().first() || ds.getUserManuallyDisconnected().first() || !ds.getAutoReconnectEnabled().first()) return@collect

                    val last = ds.getLastConnectedDevice().first() ?: return@collect

                    // Match by name within the discovery list
                    val discoveryMatch = discoveredList.find { it.name == last.name }
                    if (discoveryMatch != null) {
                        Log.d(TAG, "Discovery-triggered reconnect for: ${discoveryMatch.name}")

                        val all = ds.getAllNetworkDeviceConnections().first()
                        val targetConnection = all.firstOrNull { it.deviceName == last.name }

                        if (targetConnection != null) {
                            val ips = discoveryMatch.ips.joinToString(",")
                            val port = targetConnection.port.toIntOrNull() ?: 6997

                            connect(
                                context = context,
                                ipAddress = ips,
                                port = port,
                                symmetricKey = targetConnection.symmetricKey,
                                manualAttempt = false,
                                onConnectionStatus = { connected ->
                                    if (connected) {
                                        cancelAutoReconnect()
                                    }
                                }
                            )
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error in smart auto-reconnect: ${e.message}")
            }
        }
    }

    // Public wrapper to request auto-reconnect from app logic (e.g., network changes)
    fun requestAutoReconnect(context: Context) {
        // Only if not already connected or connecting
        if (BackgroundWorkController.isPaused || isConnected() || isConnecting.get()) return
        tryStartAutoReconnect(context)
    }
}
