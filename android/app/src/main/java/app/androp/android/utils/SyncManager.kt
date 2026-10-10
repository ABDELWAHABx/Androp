package app.androp.android.utils

import android.content.Context
import android.util.Log
import app.androp.android.data.local.DataStoreManager
import app.androp.android.domain.model.AudioInfo
import app.androp.android.domain.model.BatteryInfo
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicBoolean

object SyncManager {
    private const val TAG = "SyncManager"
    private const val BATTERY_SYNC_INTERVAL = 30_000L // Media and volume changes also trigger immediate sync.
    private const val MAX_DAILY_ICON_SYNCS = 3

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val statusMutex = Mutex()
    private var statusJob: Job? = null
    private var mediaUpdateJob: Job? = null
    private var syncJob: Job? = null
    private var lastAudioInfo: AudioInfo? = null
    private var lastBatteryInfo: BatteryInfo? = null
    private var lastVolume: Int = -1
    private val isSyncing = AtomicBoolean(false)

    // Track skip suppression mechanism
    @Volatile
    private var skipCommandTimestamp: Long = 0
    private const val SKIP_SUPPRESSION_DURATION = 1000L // 1 second suppression after skip command

    fun startPeriodicSync(context: Context) {
        if (BackgroundWorkController.isPaused || !isSyncing.compareAndSet(false, true)) {
            Log.d(TAG, "Sync already running")
            return
        }

        syncJob = scope.launch {
            Log.d(TAG, "Starting periodic sync")

            while (isActive && isSyncing.get()) {
                try {
                    if (DataStoreManager.getInstance(context).isAppPaused().first()) break
                    // Check if sync is needed (either via WebSocket or BLE)
                    if (WebSocketUtil.isConnected() || app.androp.android.data.ble.BleGattServer.isAnyAuthenticated()) {
                        // Battery/media status is independent of mirroring notifications.
                        checkAndSyncDeviceStatus(context)
                    }

                    delay(BATTERY_SYNC_INTERVAL)
                } catch (e: Exception) {
                    Log.e(TAG, "Error in periodic sync: ${e.message}")
                    delay(BATTERY_SYNC_INTERVAL)
                }
            }
        }
    }

    fun stopPeriodicSync() {
        Log.d(TAG, "Stopping periodic sync")
        isSyncing.set(false)
        scope.coroutineContext.cancelChildren()
        syncJob = null
        statusJob = null
        mediaUpdateJob = null
        lastAudioInfo = null
        lastBatteryInfo = null
        lastVolume = -1
    }

    fun checkAndSyncDeviceStatus(context: Context, forceSync: Boolean = false) {
        if (BackgroundWorkController.isPaused || !WebSocketUtil.isConnected()) return
        if (!forceSync && statusJob?.isActive == true) return
        statusJob = scope.launch {
            statusMutex.withLock {
            try {
                val dataStoreManager = DataStoreManager.getInstance(context)
                if (BackgroundWorkController.isPaused || dataStoreManager.isAppPaused().first()) return@launch
                val includeNowPlaying = dataStoreManager.getSendNowPlayingEnabled().first()

                val currentAudio = DeviceInfoUtil.getAudioInfo(context, includeNowPlaying)
                val currentBattery = DeviceInfoUtil.getBatteryInfo(context)

                var shouldSync = forceSync

                // Check if audio-related info changed
                lastAudioInfo?.let { last ->
                    if (last.isPlaying != currentAudio.isPlaying ||
                        last.title != currentAudio.title ||
                        last.artist != currentAudio.artist ||
                        last.volume != currentAudio.volume ||
                        last.isMuted != currentAudio.isMuted ||
                        last.isBuffering != currentAudio.isBuffering ||
                        last.durationMs != currentAudio.durationMs ||
                        kotlin.math.abs(last.positionMs - currentAudio.positionMs) >= 5_000L ||
                        last.likeStatus != currentAudio.likeStatus
                    ) {
                        shouldSync = true
                        Log.d(TAG, "Audio info changed, syncing device status")
                    }
                } ?: run {
                    shouldSync = true // First time
                }

                // Check if battery info changed significantly
                lastBatteryInfo?.let { last ->
                    if (last.isCharging != currentBattery.isCharging ||
                        kotlin.math.abs(last.level - currentBattery.level) >= 1
                    ) {
                        shouldSync = true
                        Log.d(TAG, "Battery info changed significantly, syncing device status")
                    }
                } ?: run {
                    shouldSync = true // First time
                }

                if (shouldSync) {
                    val statusJson = DeviceInfoUtil.generateDeviceStatusJson(context)
                    // sendMessage handles both WebSocket and BLE fallback internally
                    val success = WebSocketUtil.sendMessage(statusJson)

                    if (success) {
                        lastAudioInfo = currentAudio
                        lastBatteryInfo = currentBattery
                        lastVolume = currentAudio.volume
                    } else {
                        Log.w(TAG, "Failed to sync device status (WS/BLE)")
                    }
                }

            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.e(TAG, "Error checking device status: ${e.message}")
            }
            }
        }
    }

    fun performInitialSync(context: Context) {
        scope.launch {
            if (BackgroundWorkController.isPaused || DataStoreManager.getInstance(context).isAppPaused().first()) return@launch
            Log.d(TAG, "Performing initial sync sequence")

            try {
                val dataStoreManager = DataStoreManager.getInstance(context)

                // 1. Ensure ADB discovery is running (started at app startup)
                try {
                    val activity = context as? app.androp.android.MainActivity
                    activity?.initializeAdbDiscovery()
                    Log.d(TAG, "ADB discovery is running")
                    delay(1000)
                } catch (e: Exception) {
                    Log.w(TAG, "Could not access ADB discovery: ${e.message}")
                }

                // 2. Send lightweight device info immediately (no wallpaper) to trigger macInfo

                // Prefer the persisted device name set in the app. Fall back to system device name only if empty.
                val persistedName = dataStoreManager.getDeviceName().first().ifBlank { null }
                val deviceName =
                    persistedName ?: DeviceInfoUtil.getDeviceName(context).also { sysName ->
                        // Only save system name if no persisted name exists
                        try {
                            dataStoreManager.saveDeviceName(sysName)
                        } catch (_: Exception) {
                        }
                    }
                Log.d(TAG, "Using device name for sync: $deviceName")

                val localIp = DeviceInfoUtil.getWifiIpAddress(context) ?: "Unknown"
                val port = dataStoreManager.getPort().first().toIntOrNull() ?: 6997
                val version = context.packageManager
                    .getPackageInfo(context.packageName, 0).versionName ?: "3.0.0"

                // Get discovered ADB ports from the running mDNS discovery
                val adbPorts = try {
                    // Access the discovery holder directly - it's a true singleton object
                    val discoveredServices =
                        app.androp.android.AdbDiscoveryHolder.getDiscoveredServices()
                    Log.d(
                        TAG,
                        "Retrieved ${discoveredServices.size} discovered ADB services from holder"
                    )
                    discoveredServices.forEach { service ->
                        Log.d(
                            TAG,
                            "  - Service: ${service.serviceName} at ${service.hostAddress}:${service.port}"
                        )
                    }
                    discoveredServices.map { it.port.toString() }
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to get ADB ports: ${e.message}")
                    emptyList()
                }
                Log.d(TAG, "Discovered ADB ports: $adbPorts")

                val deviceId = DeviceInfoUtil.getDeviceId(context)
                val symmetricKey =
                    dataStoreManager.getLastConnectedDevice().first()?.symmetricKey ?: ""
                val bleAuthToken =
                    app.androp.android.data.ble.BleTransportBridge.deriveAuthToken(symmetricKey)

                val liteDeviceInfoJson = JsonUtil.createDeviceInfoJson(
                    id = deviceId,
                    name = deviceName,
                    ipAddress = localIp,
                    port = port,
                    version = version,
                    wallpaperBase64 = null,
                    adbPorts = adbPorts,
                    bleAuthToken = bleAuthToken,
                    targetIpAddress = WebSocketUtil.currentIpAddress
                )
                if (WebSocketUtil.sendMessage(liteDeviceInfoJson)) {
                    Log.d(TAG, "Lite device info sent to trigger macInfo (BLE token included)")
                } else {
                    Log.e(TAG, "Failed to send lite device info")
                }

                // Optionally send full device info with wallpaper a bit later, but don't block handshake
                launch {
                    if (BackgroundWorkController.isPaused) return@launch
                    try {
                        delay(1500)
                        val wallpaperBase64 = try {
                            WallpaperUtil.getWallpaperAsBase64(context)
                        } catch (_: Exception) {
                            null
                        }
                        val discoveredServices = try {
                            app.androp.android.AdbDiscoveryHolder.getDiscoveredServices()
                        } catch (e: Exception) {
                            emptyList()
                        }
                        val currentAdbPorts = discoveredServices.map { it.port.toString() }
                        val fullDeviceInfoJson = JsonUtil.createDeviceInfoJson(
                            id = deviceId,
                            name = deviceName,
                            ipAddress = localIp,
                            port = port,
                            version = version,
                            wallpaperBase64 = wallpaperBase64,
                            adbPorts = currentAdbPorts,
                            bleAuthToken = bleAuthToken,
                            targetIpAddress = WebSocketUtil.currentIpAddress
                        )
                        if (WebSocketUtil.sendMessage(fullDeviceInfoJson)) {
                            Log.d(
                                TAG,
                                "Full device info sent with wallpaper: ${if (wallpaperBase64 != null) "included" else "not available"}"
                            )
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "Failed to send full device info later: ${e.message}")
                    }
                }

                delay(150)

                // 2. Send device status (respect now playing setting)
                val includeNowPlaying = dataStoreManager.getSendNowPlayingEnabled().first()
                val statusJson = DeviceInfoUtil.generateDeviceStatusJson(context)
                if (WebSocketUtil.sendMessage(statusJson)) {
                    Log.d(TAG, "Device status sent")
                    // Update cache
                    lastAudioInfo = DeviceInfoUtil.getAudioInfo(context, includeNowPlaying)
                    lastBatteryInfo = DeviceInfoUtil.getBatteryInfo(context)
                } else {
                    Log.e(TAG, "Failed to send device status")
                }

                // 3. Defer icon sync to macInfo handler to avoid unnecessary extraction
                Log.d(
                    TAG,
                    "Deferring app icon sync until macInfo arrives (to compare package lists first)"
                )

                Log.d(TAG, "Initial sync sequence completed (handshake depends on macInfo)")

            } catch (e: Exception) {
                Log.e(TAG, "Error in initial sync: ${e.message}")
            }
        }
    }

    /**
     * Send updated device info immediately (used when user changes device name in the app).
     */
    fun sendDeviceInfoNow(context: Context, name: String? = null) {
        scope.launch {
            if (BackgroundWorkController.isPaused || DataStoreManager.getInstance(context).isAppPaused().first()) return@launch
            try {
                val ds = DataStoreManager.getInstance(context)
                val deviceName = name ?: ds.getDeviceName().first()
                    .ifBlank { DeviceInfoUtil.getDeviceName(context) }
                val localIp = DeviceInfoUtil.getWifiIpAddress(context) ?: "Unknown"
                val port = ds.getPort().first().toIntOrNull() ?: 6997
                val version = try {
                    context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: ""
                } catch (_: Exception) {
                    ""
                }

                // Get discovered ADB ports from the running mDNS discovery
                val adbPorts = try {
                    val discoveredServices =
                        app.androp.android.AdbDiscoveryHolder.getDiscoveredServices()
                    discoveredServices.map { it.port.toString() }
                } catch (e: Exception) {
                    emptyList()
                }

                val wallpaperBase64 = try {
                    WallpaperUtil.getWallpaperAsBase64(context)
                } catch (_: Exception) {
                    null
                }
                val deviceId = DeviceInfoUtil.getDeviceId(context)
                val deviceInfoJson = JsonUtil.createDeviceInfoJson(
                    deviceId,
                    deviceName,
                    localIp,
                    port,
                    version,
                    wallpaperBase64,
                    adbPorts,
                    WebSocketUtil.currentIpAddress
                )

                if (WebSocketUtil.sendMessage(deviceInfoJson)) {
                    Log.d(TAG, "Sent updated device info: $deviceName")
                } else {
                    Log.w(TAG, "Failed to send updated device info for $deviceName")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error sending updated device info: ${e.message}")
            }
        }
    }

    /**
     * Check if automatic icon sync is allowed based on daily limit
     */
    private suspend fun shouldSyncIconsAutomatically(context: Context): Boolean {
        try {
            val dataStoreManager = DataStoreManager.getInstance(context)
            val lastDevice = dataStoreManager.getLastConnectedDevice().first()

            if (lastDevice == null) return true // First connection always syncs

            val today = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault())
                .format(java.util.Date())

            // If it's a new day, reset the counter
            if (lastDevice.lastIconSyncDate != today) {
                Log.d(TAG, "New day detected, resetting icon sync counter")
                return true
            }

            // Check if under daily limit
            val isUnderLimit = lastDevice.iconSyncCount < MAX_DAILY_ICON_SYNCS
            Log.d(
                TAG,
                "Icon sync count for today: ${lastDevice.iconSyncCount}/$MAX_DAILY_ICON_SYNCS"
            )

            return isUnderLimit
        } catch (e: Exception) {
            Log.e(TAG, "Error checking icon sync limit: ${e.message}")
            return false
        }
    }

    /**
     * Update icon sync counter after successful sync
     */
    private suspend fun updateIconSyncCounter(context: Context) {
        try {
            val dataStoreManager = DataStoreManager.getInstance(context)
            val lastDevice = dataStoreManager.getLastConnectedDevice().first()

            if (lastDevice != null) {
                val today = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault())
                    .format(java.util.Date())

                val newCount = if (lastDevice.lastIconSyncDate == today) {
                    lastDevice.iconSyncCount + 1
                } else {
                    1 // New day, reset to 1
                }

                val updatedDevice = lastDevice.copy(
                    iconSyncCount = newCount,
                    lastIconSyncDate = today
                )

                dataStoreManager.saveLastConnectedDevice(updatedDevice)
                Log.d(TAG, "Updated icon sync counter: $newCount/$MAX_DAILY_ICON_SYNCS for $today")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error updating icon sync counter: ${e.message}")
        }
    }

    /**
     * Manually sync app icons (ignores daily limit)
     */
    fun manualSyncAppIcons(context: Context, onResult: (Boolean, String) -> Unit) {
        scope.launch {
            if (BackgroundWorkController.isPaused || DataStoreManager.getInstance(context).isAppPaused().first()) return@launch
            try {
                if (!WebSocketUtil.isConnected()) {
                    onResult(false, "Not connected to desktop")
                    return@launch
                }

                Log.d(TAG, "Starting manual app icons sync")
                sendAppIcons(context, isManualSync = true, onResult = onResult)
            } catch (e: Exception) {
                Log.e(TAG, "Error in manual icon sync: ${e.message}")
                onResult(false, "Error: ${e.message}")
            }
        }
    }

    private suspend fun sendAppIcons(
        context: Context,
        isManualSync: Boolean = false,
        onResult: ((Boolean, String) -> Unit)? = null
    ) {
        try {
            Log.d(TAG, "Starting app icons sync (manual: $isManualSync)")

            val dataStoreManager = DataStoreManager.getInstance(context)

            // Get ALL installed apps first
            val installedApps = AppUtil.getInstalledApps(context)
            Log.d(TAG, "Found ${installedApps.size} installed apps")

            if (installedApps.isEmpty()) {
                val message = "No installed apps found"
                Log.w(TAG, message)
                onResult?.invoke(false, message)
                return
            }

            // Merge against the latest choices inside the write transaction.
            val allApps = dataStoreManager.updateNotificationApps { saved ->
                AppUtil.mergeWithSavedApps(installedApps, saved)
            }

            Log.d(
                TAG,
                "Collecting icons for ${allApps.size} apps (${allApps.count { it.isEnabled }} enabled)"
            )

            // Get package names for icon collection
            val allPackages = allApps.map { it.packageName }

            // Get app icons as base64
            val iconMap = AppIconUtil.getAppIconsAsBase64(context, allPackages)

            if (iconMap.isNotEmpty()) {
                // Create and send app icons JSON
                val appIconsJson = JsonUtil.createAppIconsJson(allApps, iconMap)

                if (WebSocketUtil.sendMessage(appIconsJson)) {
                    Log.d(
                        TAG,
                        "✅ App icons sent successfully (${iconMap.size} icons with full app details)"
                    )

                    // Update counter only for automatic syncs
                    if (!isManualSync) {
                        updateIconSyncCounter(context)
                    }

                    val message = "Successfully synced ${iconMap.size} app icons with details"
                    onResult?.invoke(true, message)
                } else {
                    Log.e(TAG, "Failed to send app icons")
                    onResult?.invoke(false, "Failed to send app icons")
                }
            } else {
                val message = "No app icons could be collected"
                Log.w(TAG, message)
                onResult?.invoke(false, message)
            }

        } catch (e: Exception) {
            Log.e(TAG, "Error sending app icons: ${e.message}")
            onResult?.invoke(false, "Error: ${e.message}")
        }
    }

    /**
     * Send optimized app icons for a subset of packages (triggered by macInfo)
     */
    fun sendOptimizedAppIcons(
        context: Context,
        packageNames: List<String>,
        fetchIcons: Boolean = true
    ) {
        scope.launch {
            if (BackgroundWorkController.isPaused || DataStoreManager.getInstance(context).isAppPaused().first()) return@launch
            try {
                if (!WebSocketUtil.isConnected()) {
                    Log.w(TAG, "Not connected; cannot send optimized app icons")
                    return@launch
                }

                if (packageNames.isEmpty()) {
                    Log.d(TAG, "No packages to sync icons for")
                    return@launch
                }

                val pm = context.packageManager
                val apps = mutableListOf<app.androp.android.domain.model.NotificationApp>()

                val ds = DataStoreManager.getInstance(context)
                val savedApps = ds.getNotificationApps().first()
                val savedAppsMap = savedApps.associateBy { it.packageName }

                packageNames.forEach { pkg ->
                    currentCoroutineContext().ensureActive()
                    if (BackgroundWorkController.isPaused) return@launch
                    try {
                        val ai = pm.getApplicationInfo(pkg, 0)
                        val appName = pm.getApplicationLabel(ai).toString()
                        val isSystem =
                            (ai.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0 ||
                                    (ai.flags and android.content.pm.ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0

                        // Use saved preference if available, default to true
                        val isEnabled = savedAppsMap[pkg]?.isEnabled ?: true

                        apps.add(
                            app.androp.android.domain.model.NotificationApp(
                                packageName = pkg,
                                appName = appName,
                                isEnabled = isEnabled,
                                isSystemApp = isSystem,
                                lastUpdated = System.currentTimeMillis()
                            )
                        )
                    } catch (e: Exception) {
                        Log.w(
                            TAG,
                            "Skipping package $pkg (not found or inaccessible): ${e.message}"
                        )
                    }
                }

                if (apps.isEmpty()) {
                    Log.w(TAG, "No valid apps resolved for optimized icon sync")
                    return@launch
                }

                // Extract icons only if requested
                val iconMap = if (fetchIcons) {
                    AppIconUtil.getAppIconsAsBase64(context, apps.map { it.packageName })
                } else {
                    Log.d(TAG, "Skipping icon extraction (metadata sync only)")
                    emptyMap()
                }

                // If verifying icons, we need them. But for metadata sync, empty map is fine.
                if (fetchIcons && iconMap.isEmpty()) {
                    Log.w(TAG, "Icon extraction returned empty for optimized sync")
                    return@launch
                }

                val appIconsJson = JsonUtil.createAppIconsJson(apps, iconMap)
                if (WebSocketUtil.sendMessage(appIconsJson)) {
                    Log.d(
                        TAG,
                        "✅ Optimized app icons sent: ${apps.size} apps (icons included: $fetchIcons)"
                    )
                } else {
                    Log.e(TAG, "Failed to send optimized app icons")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error in sendOptimizedAppIcons: ${e.message}")
            }
        }
    }

    fun onVolumeChanged(context: Context) {
        Log.d(TAG, "Volume change detected, checking sync")
        checkAndSyncDeviceStatus(context)
    }

    /**
     * Call this before executing a track skip command to suppress automatic media updates
     */
    fun suppressMediaUpdatesForSkip() {
        skipCommandTimestamp = System.currentTimeMillis()
        Log.d(TAG, "Media update suppression activated for track skip")
    }

    /**
     * Check if media updates should be suppressed due to recent skip command
     */
    private fun shouldSuppressMediaUpdate(): Boolean {
        val timeSinceSkip = System.currentTimeMillis() - skipCommandTimestamp
        return timeSinceSkip < SKIP_SUPPRESSION_DURATION
    }

    fun onMediaStateChanged(context: Context) {
        if (BackgroundWorkController.isPaused) return
        // The listener already filters meaningful metadata, artwork and playback changes.
        // Preserve its seek/artwork updates even when status polling would suppress them.
        mediaUpdateJob?.cancel()
        mediaUpdateJob = scope.launch {
            if (shouldSuppressMediaUpdate()) {
                val remaining = SKIP_SUPPRESSION_DURATION - (System.currentTimeMillis() - skipCommandTimestamp)
                delay(remaining.coerceAtLeast(0L))
            }
            if (!BackgroundWorkController.isPaused) checkAndSyncDeviceStatus(context, forceSync = true)
        }
    }

    fun reset() {
        lastAudioInfo = null
        lastBatteryInfo = null
        lastVolume = -1
    }
}
