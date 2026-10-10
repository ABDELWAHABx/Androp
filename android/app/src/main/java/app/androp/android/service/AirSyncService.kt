package app.androp.android.service

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.IBinder
import android.util.Log
import app.androp.android.data.local.DataStoreManager
import app.androp.android.utils.DiscoveryMode
import app.androp.android.utils.MacDeviceStatusManager
import app.androp.android.utils.ShortcutUtil
import app.androp.android.utils.SyncDashboardController
import app.androp.android.utils.discovery.DiscoveryOrchestrator
import app.androp.android.utils.WebDavServer
import app.androp.android.utils.WebSocketUtil
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/**
 * Foreground service that maintains the airsync connection and handles discovery.
 *
 * Uses connectedDevice foreground service type as per Google Play Store requirements.
 */
class AirSyncService : Service() {

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private var connectedDeviceName: String? = null
    @Volatile private var isScanning = false
    @Volatile private var isSyncing = false
    @Volatile private var isStopping = false
    private var stateJob: Job? = null
    private var startupJob: Job? = null

    private var webDavServer: WebDavServer? = null
    private var webDavJob: Job? = null

    // Network state tracking
    private var networkCallback: ConnectivityManager.NetworkCallback? = null


    override fun onCreate() {
        super.onCreate()
        serviceInstance = this
        Log.d(TAG, "AirSyncService created")
        createNotificationChannel()
        // Android can reject promotion after a background-start exemption expires.
        // Do not install listeners or launch discovery for a service that cannot run.
        if (!promoteToForeground()) return
        MacDeviceStatusManager.startMonitoring(this)
        registerNetworkCallback()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "AirSyncService started with action: ${intent?.action}")

        if (isStopping || intent?.action == ACTION_STOP_SYNC) {
            stopSync()
            return START_NOT_STICKY
        }
        startupJob?.cancel()
        startupJob = scope.launch {
            if (isStopping || DataStoreManager.getInstance(applicationContext).isAppPaused().first()) {
                stopSync()
                return@launch
            }
            when (intent?.action) {
                ACTION_START_SCANNING -> if (WebSocketUtil.isConnected()) startSync() else startScanning()
                ACTION_START_SYNC -> {
                    connectedDeviceName = intent.getStringExtra(EXTRA_DEVICE_NAME) ?: "Mac"
                    if (WebSocketUtil.isConnected()) {
                        startSync()
                        ShortcutUtil.refreshShortcuts(this@AirSyncService, true)
                    } else startScanning()
                }
                ACTION_APP_FOREGROUND -> handleAppForeground()
                ACTION_APP_BACKGROUND -> handleAppBackground()
                else -> if (WebSocketUtil.isConnected()) startSync() else startScanning()
            }
        }
        // Active sync survives process eviction, but every restart checks persisted pause state.
        return START_STICKY
    }

    private fun startScanning() {
        if (isStopping || isScanning) return
        Log.d(TAG, "Starting androp scanning mode")
        isScanning = true
        isSyncing = false
        webDavJob?.cancel()
        webDavJob = null
        stopWebDavServer()
        connectedDeviceName = null
        updateNotification()

        stateJob?.cancel()
        stateJob = scope.launch {
            val dataStoreManager = DataStoreManager.getInstance(applicationContext)
            if (isStopping || dataStoreManager.isAppPaused().first()) return@launch
            val isDiscoveryEnabled = dataStoreManager.getDeviceDiscoveryEnabled().first()

            // Default to PASSIVE mode to save battery
            // But do a burst to check for devices immediately
            DiscoveryOrchestrator.start(this@AirSyncService, isDiscoveryEnabled)
            DiscoveryOrchestrator.setDiscoveryMode(this@AirSyncService, DiscoveryMode.PASSIVE)
            DiscoveryOrchestrator.burstBroadcast(this@AirSyncService)

            // Start WakeupService for HTTP wakeups
            WakeupService.startService(this@AirSyncService)

            // Also trigger auto-reconnect logic to check if we already have a candidate
            WebSocketUtil.requestAutoReconnect(this@AirSyncService)
        }
    }

    private fun startWebDavServer() {
        if (webDavServer == null) {
            webDavServer = WebDavServer(this)
        }
        webDavServer?.start()
    }

    private fun stopWebDavServer() {
        webDavServer?.stop()
        webDavServer = null
    }

    private fun monitorWebDavRequirements() {
        webDavJob?.cancel()
        webDavJob = scope.launch {
            val dataStoreManager = DataStoreManager.getInstance(applicationContext)
            combine(
                dataStoreManager.isFileAccessEnabled(),
                dataStoreManager.getLastConnectedDevice(),
                WebSocketUtil.connectionState
            ) { isEnabled, device, connected ->
                Log.d(TAG, "WebDAV flow evaluation: isEnabled=$isEnabled, isPlus=${device?.isPlus}")
                isEnabled && device?.isPlus == true && connected
            }.collect { shouldStart ->
                Log.d(TAG, "WebDAV requirement state updated: shouldStart = $shouldStart")
                if (shouldStart && !isStopping && !app.androp.android.utils.BackgroundWorkController.isPaused) {
                    startWebDavServer()
                } else {
                    stopWebDavServer()
                }
            }
        }
    }

    private fun promoteToForeground(): Boolean {
        val promoted = SyncDashboardController.acquire(this, SyncDashboardController.OWNER_SYNC,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        if (!promoted) isStopping = true
        return promoted
    }

    private fun handleAppForeground() {
        if (isScanning) {
            Log.d(TAG, "App in foreground, switching to ACTIVE discovery")
            DiscoveryOrchestrator.setDiscoveryMode(this, DiscoveryMode.ACTIVE)
        }
    }

    private fun handleAppBackground() {
        if (isScanning) {
            Log.d(TAG, "App in background, switching to PASSIVE discovery")
            DiscoveryOrchestrator.setDiscoveryMode(this, DiscoveryMode.PASSIVE)
        }
    }

    private fun startSync() {
        if (isStopping || isSyncing) {
            Log.d(TAG, "androp foreground service already in sync state, ignoring")
            return
        }
        Log.d(TAG, "Starting androp foreground service (connected)")
        isScanning = false
        isSyncing = true
        updateNotification()

        stateJob?.cancel()
        stateJob = scope.launch {
            val dataStoreManager = DataStoreManager.getInstance(applicationContext)
            if (isStopping || dataStoreManager.isAppPaused().first()) return@launch
            val isDiscoveryEnabled = dataStoreManager.getDeviceDiscoveryEnabled().first()

            // Keep discovery manager running for wake-ups even when connected
            // But stay in Passive mode mostly
            DiscoveryOrchestrator.start(this@AirSyncService, isDiscoveryEnabled)
            DiscoveryOrchestrator.setDiscoveryMode(this@AirSyncService, DiscoveryMode.PASSIVE)

            WakeupService.startService(this@AirSyncService)
            monitorWebDavRequirements()
        }
    }

    private fun stopSync() {
        if (isStopping) { stopSelf(); return }
        Log.d(TAG, "Stopping androp foreground service")
        isStopping = true
        isScanning = false
        isSyncing = false
        startupJob?.cancel()
        stateJob?.cancel()
        stateJob = null
        webDavJob?.cancel()
        webDavJob = null
        stopWebDavServer()
        ShortcutUtil.refreshShortcuts(this, false)
        DiscoveryOrchestrator.stop(this)
        WakeupService.stopService(this)
        SyncDashboardController.release(this, SyncDashboardController.OWNER_SYNC)
        stopSelf()
    }

    private fun registerNetworkCallback() {
        try {
            val connectivityManager =
                getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
            val builder = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .addTransportType(NetworkCapabilities.TRANSPORT_ETHERNET)

            networkCallback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    if (isStopping || app.androp.android.utils.BackgroundWorkController.isPaused) return
                    Log.d(
                        TAG,
                        "Network available, triggering burst broadcast and refreshing socket"
                    )
                    // Refresh UDP socket to bind to new network interface
                    DiscoveryOrchestrator.refreshSocket()
                    // When network becomes available, do a burst to announce ourselves
                    if (isScanning && !app.androp.android.data.ble.BleGattServer.isAnyAuthenticated()) {
                        DiscoveryOrchestrator.burstBroadcast(applicationContext)
                        WebSocketUtil.requestAutoReconnect(applicationContext)
                    } else if (isScanning) {
                        DiscoveryOrchestrator.burstBroadcast(applicationContext)
                    }
                }
            }

            connectivityManager.registerNetworkCallback(builder.build(), networkCallback!!)
        } catch (e: Exception) {
            Log.e(TAG, "Error registering network callback", e)
        }
    }

    private fun createNotificationChannel() {
        SyncDashboardController.initialize(this)
    }

    private fun updateNotification() {
        if (!isStopping) SyncDashboardController.refreshConnection()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        Log.d(TAG, "AirSyncService destroyed")
        serviceInstance = null

        networkCallback?.let {
            try {
                val cm = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
                cm.unregisterNetworkCallback(it)
            } catch (e: Exception) {
                Log.e(TAG, "Error unregistering network callback", e)
            }
        }

        isStopping = true
        stateJob?.cancel()
        startupJob?.cancel()
        webDavJob?.cancel()
        stopWebDavServer()
        DiscoveryOrchestrator.stop(this)
        WakeupService.stopService(this)
        MacDeviceStatusManager.stopMonitoring()
        MacDeviceStatusManager.cleanup(this)
        scope.coroutineContext.cancel()
        SyncDashboardController.release(this, SyncDashboardController.OWNER_SYNC)
        super.onDestroy()
    }

    companion object {
        private const val TAG = "AirSyncService"

        const val ACTION_START_SCANNING = "app.androp.android.START_SCANNING"
        const val ACTION_START_SYNC = "app.androp.android.START_SYNC"
        const val ACTION_STOP_SYNC = "app.androp.android.STOP_SYNC"
        const val ACTION_DISCONNECT = "app.androp.android.DISCONNECT_FROM_NOTIFICATION"
        const val ACTION_APP_FOREGROUND = "app.androp.android.APP_FOREGROUND"
        const val ACTION_APP_BACKGROUND = "app.androp.android.APP_BACKGROUND"

        const val EXTRA_DEVICE_NAME = "device_name"

        @Volatile private var serviceInstance: AirSyncService? = null
        private val actionScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
        private val shutdownScope = CoroutineScope(Dispatchers.Main.immediate + SupervisorJob())

        fun isRunning(): Boolean = serviceInstance != null

        fun startScanning(context: Context) {
            actionScope.launch {
                val dataStoreManager = DataStoreManager.getInstance(context)
                if (dataStoreManager.isAppPaused().first()) {
                    Log.d(TAG, "App is paused, ignoring startScanning")
                    return@launch
                }
                val intent = Intent(context, AirSyncService::class.java).apply {
                    action = ACTION_START_SCANNING
                }
                startAction(context, intent)
            }
        }

        fun start(context: Context, deviceName: String?) {
            actionScope.launch {
                val dataStoreManager = DataStoreManager.getInstance(context)
                if (dataStoreManager.isAppPaused().first()) {
                    Log.d(TAG, "App is paused, ignoring start")
                    return@launch
                }
                val intent = Intent(context, AirSyncService::class.java).apply {
                    action = ACTION_START_SYNC
                    putExtra(EXTRA_DEVICE_NAME, deviceName)
                }
                startAction(context, intent)
            }
        }

        fun notifyAppForeground(context: Context) {
            if (!isRunning()) return
            val intent = Intent(context, AirSyncService::class.java).apply {
                action = ACTION_APP_FOREGROUND
            }
            startAction(context, intent)
        }

        fun notifyAppBackground(context: Context) {
            if (!isRunning()) return
            val intent = Intent(context, AirSyncService::class.java).apply {
                action = ACTION_APP_BACKGROUND
            }
            startAction(context, intent)
        }

        private fun startAction(context: Context, intent: Intent) {
            if (app.androp.android.utils.BackgroundWorkController.isPaused) return
            try {
                if (isRunning()) {
                    context.startService(intent)
                } else {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        context.startForegroundService(intent)
                    } else {
                        context.startService(intent)
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error starting foreground service", e)
            }
        }

        fun stop(context: Context) {
            // Starting a service merely to stop it revives discovery and can violate background limits.
            // ServiceManager can call from IO; serialize teardown with Main-bound startup jobs.
            val application = context.applicationContext
            shutdownScope.launch {
                serviceInstance?.stopSync()
                application.stopService(Intent(application, AirSyncService::class.java))
            }
        }
    }
}
