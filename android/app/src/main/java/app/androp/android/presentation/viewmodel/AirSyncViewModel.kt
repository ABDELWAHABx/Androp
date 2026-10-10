package app.androp.android.presentation.viewmodel

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.PowerManager
import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.androp.android.data.local.DataStoreManager
import app.androp.android.data.repository.AirSyncRepositoryImpl
import app.androp.android.domain.model.ConnectedDevice
import app.androp.android.domain.model.DeviceInfo
import app.androp.android.domain.model.NetworkDeviceConnection
import app.androp.android.domain.model.UiState
import app.androp.android.domain.repository.AirSyncRepository
import app.androp.android.smartspacer.AirSyncDeviceTarget
import app.androp.android.utils.DeviceInfoUtil
import app.androp.android.utils.DiscoveredDevice
import app.androp.android.utils.MacDeviceStatusManager
import app.androp.android.utils.NetworkMonitor
import app.androp.android.utils.PermissionUtil
import app.androp.android.utils.ServiceManager
import app.androp.android.utils.ShortcutUtil
import app.androp.android.utils.SyncManager
import app.androp.android.utils.discovery.DiscoveryOrchestrator
import app.androp.android.utils.WebSocketUtil
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking

class AirSyncViewModel(
    private val repository: AirSyncRepository
) : ViewModel() {

    companion object {
        fun create(context: Context): AirSyncViewModel {
            val dataStoreManager = DataStoreManager(context)
            val repository = AirSyncRepositoryImpl(dataStoreManager)
            return AirSyncViewModel(repository)
        }
    }

    private val _uiState = MutableStateFlow(UiState())
    val uiState: StateFlow<UiState> = _uiState.asStateFlow()

    private val _deviceInfo = MutableStateFlow(DeviceInfo())
    val deviceInfo: StateFlow<DeviceInfo> = _deviceInfo.asStateFlow()

    // Network-aware device connections state
    private val _networkDevices = MutableStateFlow<List<NetworkDeviceConnection>>(emptyList())

    // Discovered devices from Orchestrator
    val discoveredDevices: StateFlow<List<DiscoveredDevice>> = DiscoveryOrchestrator.discoveredDevices

    // Notes Role state
    private val _stylusMode = MutableStateFlow(false)
    val stylusMode: StateFlow<Boolean> = _stylusMode.asStateFlow()

    private val _launchedFromLockScreen = MutableStateFlow(true)
    val launchedFromLockScreen: StateFlow<Boolean> = _launchedFromLockScreen.asStateFlow()

    private val _isFloatingWindow = MutableStateFlow(true)
    val isFloatingWindow: StateFlow<Boolean> = _isFloatingWindow.asStateFlow()

    private val _isNotesRoleHeld = MutableStateFlow(false)
    val isNotesRoleHeld: StateFlow<Boolean> = _isNotesRoleHeld.asStateFlow()

    // Network monitoring
    private var isNetworkMonitoringActive = false
    private var previousNetworkIp: String? = null

    private var appContext: Context? = null

    private val powerSaveReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == PowerManager.ACTION_POWER_SAVE_MODE_CHANGED) {
                context?.let { updateBlurState(it) }
            }
        }
    }

    // Manual connect canceller reference (set in init) for unregistering
    private val manualConnectCanceler: () -> Unit = {
        // Cancel any active auto-reconnect when user starts manual connection
        try {
            WebSocketUtil.cancelAutoReconnect()
        } catch (_: Exception) {
        }
    }

    // Connection status listener for WebSocket updates
    private val connectionStatusListener: (Boolean) -> Unit = { isWsConnected ->
        viewModelScope.launch {
            val isBleConnected =
                _uiState.value.bleConnectionState == app.androp.android.data.ble.BleGattServer.BleConnectionState.AUTHENTICATED
            val isGlobalConnected = isWsConnected || isBleConnected

            val deviceToShow = if (isGlobalConnected) {
                val networkAwareDevice = getNetworkAwareLastConnectedDevice()
                val storedDevice = repository.getLastConnectedDevice().first()
                networkAwareDevice ?: storedDevice
            } else {
                _uiState.value.lastConnectedDevice
            }

            val activeIp = if (isWsConnected) WebSocketUtil.currentIpAddress else null
            if (isWsConnected && activeIp != null) {
                repository.saveIpAddress(activeIp)
            }
            val savedIp = if (isWsConnected && activeIp != null) activeIp else repository.getIpAddress().first()

            _uiState.value = _uiState.value.copy(
                isConnected = isGlobalConnected,
                isConnecting = false,
                response = if (isGlobalConnected) "Connected successfully!" else "Disconnected",
                ipAddress = savedIp,
                activeIp = activeIp,
                macDeviceStatus = if (isGlobalConnected) _uiState.value.macDeviceStatus else null,
                lastConnectedDevice = deviceToShow
            )

            if (isGlobalConnected) {
                repository.setFirstMacConnectionTime(System.currentTimeMillis())
                updateRatingPromptDisplay()
            }

            // Update dynamic shortcuts
            appContext?.let { ctx ->
                ShortcutUtil.refreshShortcuts(ctx, isGlobalConnected)
            }

            // Notify Smartspacer of connection status change
            appContext?.let { context ->
                try {
                    AirSyncDeviceTarget.notifyChange(context)
                } catch (_: Exception) {
                    // Smartspacer might not be installed, ignore
                }
            }
        }
    }

    init {
        // Initialize current connection state immediately
        val isWsConnected = WebSocketUtil.isConnected()
        val isBleConnected = app.androp.android.AirSyncApp.getBleConnectionManager()?.isAuthenticated == true
        val isGlobalConnected = isWsConnected || isBleConnected

        val storedDevice = try {
            kotlinx.coroutines.runBlocking { repository.getLastConnectedDevice().first() }
        } catch (_: Exception) {
            null
        }

        val activeIp = if (isWsConnected) WebSocketUtil.currentIpAddress else null

        val initialIp = if (isWsConnected && activeIp != null) {
            runBlocking {
                repository.saveIpAddress(activeIp)
                activeIp
            }
        } else {
            null
        }

        val savedIp = initialIp ?: try {
            kotlinx.coroutines.runBlocking { repository.getIpAddress().first() }
        } catch (_: Exception) {
            ""
        }

        _uiState.value = _uiState.value.copy(
            isConnected = isGlobalConnected,
            ipAddress = savedIp,
            activeIp = activeIp,
            macDeviceStatus = if (isGlobalConnected) MacDeviceStatusManager.macDeviceStatus.value else null,
            lastConnectedDevice = storedDevice
        )

        // Register for WebSocket connection status updates
        WebSocketUtil.registerConnectionStatusListener(connectionStatusListener)
        try {
            WebSocketUtil.registerManualConnectListener(manualConnectCanceler)
        } catch (_: Exception) {
        }

        // Observe Mac device status updates
        viewModelScope.launch {
            MacDeviceStatusManager.macDeviceStatus.collect { macStatus ->
                _uiState.value = _uiState.value.copy(macDeviceStatus = macStatus)
            }
        }
        // Observe manual disconnect flag to immediately cancel any running auto-reconnect
        viewModelScope.launch {
            repository.getUserManuallyDisconnected().collect { _ ->
                // No device status notification to update
            }
        }

        // Observe pitch black theme preference
        viewModelScope.launch {
            repository.getPitchBlackThemeEnabled().collect { enabled ->
                _uiState.value = _uiState.value.copy(isPitchBlackThemeEnabled = enabled)
            }
        }

        // Observe ripple preference
        viewModelScope.launch {
            repository.getUseRippleEnabled().collect { enabled ->
                _uiState.value = _uiState.value.copy(isRippleSettingEnabled = enabled)
            }
        }

        
        viewModelScope.launch {
            repository.getDeveloperModeVisible().collect { visible ->
                _uiState.value = _uiState.value.copy(isDeveloperModeVisible = visible)
            }
        }

        viewModelScope.launch {
            repository.isAppPaused().collect { paused ->
                _uiState.value = _uiState.value.copy(isAppPaused = paused)
            }
        }



        // Observe widget transparency preference
        viewModelScope.launch {
            repository.getWidgetTransparency().collect { trans ->
                _uiState.value = _uiState.value.copy(widgetTransparency = trans)
            }
        }

        // Observe first run preference for onboarding status
        viewModelScope.launch {
            repository.getFirstRun().collect { firstRun ->
                _uiState.value = _uiState.value.copy(isOnboardingCompleted = !firstRun)
            }
        }

        // Observe Quick Share preference
        viewModelScope.launch {
            repository.isQuickShareEnabled().collect { enabled ->
                _uiState.value = _uiState.value.copy(isQuickShareEnabled = enabled)
            }
        }

        // Observe File Access preference
        viewModelScope.launch {
            repository.isFileAccessEnabled().collect { enabled ->
                _uiState.value = _uiState.value.copy(isFileAccessEnabled = enabled)
            }
        }

        // Observe Send now playing preference
        viewModelScope.launch {
            repository.getSendNowPlayingEnabled().collect { enabled ->
                _uiState.value = _uiState.value.copy(isSendNowPlayingEnabled = enabled)
            }
        }

        // Observe Excluded media packages preference
        viewModelScope.launch {
            repository.getExcludedMediaPackages().collect { packages ->
                _uiState.value = _uiState.value.copy(excludedMediaPackages = packages)
                app.androp.android.service.MediaNotificationListener.setExcludedMediaPackages(packages)
            }
        }

        // Observe Notify on Crash preference
        viewModelScope.launch {
            repository.getNotifyOnCrashEnabled().collect { enabled ->
                _uiState.value = _uiState.value.copy(isNotifyOnCrashEnabled = enabled)
            }
        }

        // Observe BLE connection status
        viewModelScope.launch {
            app.androp.android.AirSyncApp.getBleConnectionManager()?.connectionState?.collect { state ->
                Log.d("AirSyncViewModel", "BLE connection state changed: $state")
                val isBleAuthenticated =
                    state == app.androp.android.data.ble.BleGattServer.BleConnectionState.AUTHENTICATED
                val isWsConnected = WebSocketUtil.isConnected()

                _uiState.value = _uiState.value.copy(
                    bleConnectionState = state,
                    isConnected = isWsConnected || isBleAuthenticated
                )

                if (isBleAuthenticated && !isWsConnected) {
                    // Refresh shortcuts and other side effects if this is the only connection
                    appContext?.let { ctx ->
                        ShortcutUtil.refreshShortcuts(ctx, true)
                    }
                    updateRatingPromptDisplay()
                }
            }
        }
    }

    override fun onCleared() {
        super.onCleared()
        // Unregister listeners
        WebSocketUtil.unregisterConnectionStatusListener(connectionStatusListener)
        try {
            WebSocketUtil.unregisterManualConnectListener(manualConnectCanceler)
        } catch (_: Exception) {
        }
        try {
            appContext?.unregisterReceiver(powerSaveReceiver)
        } catch (_: IllegalArgumentException) {
            // Receiver was not registered
        }
    }

    private fun startObservingDeviceChanges(context: Context) {
        val dataStoreManager = DataStoreManager(context)

        // Observe both last connected device and network devices for real-time updates
        viewModelScope.launch {
            dataStoreManager.getLastConnectedDevice()
                .distinctUntilChanged()
                .collect { device ->
                    Log.d(
                        "AirSyncViewModel",
                        "Last connected device changed: ${device?.name}, isPlus: ${device?.isPlus}"
                    )
                    updateDisplayedDevice(context)
                }
        }

        viewModelScope.launch {
            dataStoreManager.getAllNetworkDeviceConnections()
                .distinctUntilChanged()
                .collect { networkDevices ->
                    Log.d(
                        "AirSyncViewModel",
                        "Network devices changed: ${networkDevices.size} devices"
                    )
                    _networkDevices.value = networkDevices
                    updateDisplayedDevice(context)
                }
        }
    }

    private fun updateDisplayedDevice(context: Context) {
        viewModelScope.launch {
            // Get current network IP for network-aware device lookup
            val currentIp = DeviceInfoUtil.getWifiIpAddress(context) ?: "Unknown"
            _deviceInfo.value = _deviceInfo.value.copy(localIp = currentIp)

            // Use network-aware device if available for current network, otherwise use the stored device
            val networkAwareDevice = getNetworkAwareLastConnectedDevice()
            val storedDevice = repository.getLastConnectedDevice().first()
            val deviceToShow = networkAwareDevice ?: storedDevice

            // Only update if changed
            if (_uiState.value.lastConnectedDevice != deviceToShow) {
                Log.d(
                    "AirSyncViewModel",
                    "Updating displayed device: ${deviceToShow?.name}, isPlus: ${deviceToShow?.isPlus}, model: ${deviceToShow?.model}"
                )
                _uiState.value = _uiState.value.copy(lastConnectedDevice = deviceToShow)
            }
        }
    }

    fun initializeState(
        context: Context,
        initialIp: String? = null,
        initialPort: String? = null,
        showConnectionDialog: Boolean = false,
        pcName: String? = null,
        isPlus: Boolean = false,
        symmetricKey: String? = null
    ) {
        appContext = context.applicationContext
        viewModelScope.launch {
            // Load saved values
            val savedIp = initialIp ?: repository.getIpAddress().first()
            val savedPort = initialPort ?: repository.getPort().first()
            val savedDeviceName = repository.getDeviceName().first()
            val lastConnected = repository.getLastConnectedDevice().first()
            val isNotificationSyncEnabled = repository.getNotificationSyncEnabled().first()
            val isDeveloperMode = repository.getDeveloperMode().first()
            val isClipboardSyncEnabled = repository.getClipboardSyncEnabled().first()
            val isAutoReconnectEnabled = repository.getAutoReconnectEnabled().first()
            val lastConnectedSymmetricKey = lastConnected?.symmetricKey
            val isContinueBrowsingEnabled = repository.getContinueBrowsingEnabled().first()
            val isSendNowPlayingEnabled = repository.getSendNowPlayingEnabled().first()
            val isKeepPreviousLinkEnabled = repository.getKeepPreviousLinkEnabled().first()
            val isMacMediaControlsEnabled = repository.getMacMediaControlsEnabled().first()
            val isClipboardHistoryEnabled = repository.getClipboardHistoryEnabled().first()
            repository.getDefaultTab().first()
            val isEssentialsConnectionEnabled = repository.getEssentialsConnectionEnabled().first()
            val isDeviceDiscoveryEnabled = repository.getDeviceDiscoveryEnabled().first()
            val isBlurEnabledSetting = repository.getUseBlurEnabled().first()
            val isRippleEnabledSetting = repository.getUseRippleEnabled().first()
            val isPitchBlackThemeEnabled = repository.getPitchBlackThemeEnabled().first()
            val isFirstRun = repository.getFirstRun().first()
            val isPowerSaveMode = DeviceInfoUtil.isPowerSaveMode(context)
            val isBlurProblematic = DeviceInfoUtil.isBlurProblematicDevice()
            val isQuickShareEnabled = repository.isQuickShareEnabled().first()
            val isNotifyOnCrashEnabled = repository.getNotifyOnCrashEnabled().first()

            // Replicate Essentials logic for initial state
            val isBlurEnabled = isBlurEnabledSetting && !isPowerSaveMode && !isBlurProblematic

            // Rating tracking
            repository.getFirstMacConnectionTime().first()
            repository.getLastPromptDismissedVersion().first()
            repository.hasRatedApp().first()

            // Get device info
            val deviceName = savedDeviceName.ifEmpty {
                val autoName = DeviceInfoUtil.getDeviceName(context)
                repository.saveDeviceName(autoName)
                autoName
            }

            val localIp = DeviceInfoUtil.getWifiIpAddress(context) ?: "Unknown"

            _deviceInfo.value = DeviceInfo(name = deviceName, localIp = localIp)

            // Load network-aware device connections
            loadNetworkDevices()

            // Check for network-aware device for current network
            val networkAwareDevice = getNetworkAwareLastConnectedDevice()
            val deviceToShow = networkAwareDevice ?: lastConnected

            // Check permissions
            val missingPermissions = PermissionUtil.getAllMissingPermissions(context)
            val isNotificationEnabled = PermissionUtil.isNotificationListenerEnabled(context)

            // Check current WebSocket connection status
            val currentlyConnected = WebSocketUtil.isConnected()

            _uiState.value = _uiState.value.copy(
                ipAddress = savedIp,
                port = savedPort,
                deviceNameInput = deviceName,
                // Only show dialog if not already connected and showConnectionDialog is true
                isDialogVisible = showConnectionDialog && !currentlyConnected,
                missingPermissions = missingPermissions,
                isNotificationEnabled = isNotificationEnabled,
                lastConnectedDevice = deviceToShow,
                isNotificationSyncEnabled = isNotificationSyncEnabled,
                isDeveloperMode = isDeveloperMode,
                isClipboardSyncEnabled = isClipboardSyncEnabled,
                isAutoReconnectEnabled = isAutoReconnectEnabled,
                isConnected = currentlyConnected,
                symmetricKey = symmetricKey ?: lastConnectedSymmetricKey,
                isContinueBrowsingEnabled = isContinueBrowsingEnabled,
                isSendNowPlayingEnabled = isSendNowPlayingEnabled,
                isKeepPreviousLinkEnabled = isKeepPreviousLinkEnabled,
                isMacMediaControlsEnabled = isMacMediaControlsEnabled,
                isClipboardHistoryEnabled = isClipboardHistoryEnabled,
                isEssentialsConnectionEnabled = isEssentialsConnectionEnabled,
                isDeviceDiscoveryEnabled = isDeviceDiscoveryEnabled,
                isBlurSettingEnabled = isBlurEnabledSetting,
                isRippleSettingEnabled = isRippleEnabledSetting,
                isPowerSaveMode = isPowerSaveMode,
                isPitchBlackThemeEnabled = isPitchBlackThemeEnabled,
                isBlurEnabled = isBlurEnabled,
                isOnboardingCompleted = !isFirstRun,
                isQuickShareEnabled = isQuickShareEnabled,
                isNotifyOnCrashEnabled = isNotifyOnCrashEnabled
            )

            updateRatingPromptDisplay()

            // If we have PC name from QR code and not already connected, store it temporarily for the dialog
            if (pcName != null && showConnectionDialog && !currentlyConnected) {
                _uiState.value = _uiState.value.copy(
                    lastConnectedDevice = ConnectedDevice(
                        name = pcName,
                        ipAddress = savedIp,
                        port = savedPort,
                        lastConnected = System.currentTimeMillis(),
                        isPlus = isPlus,
                        symmetricKey = symmetricKey
                    )
                )
            }


            // Start observing device changes for real-time updates
            startObservingDeviceChanges(context)

            // Register power save receiver on application context to avoid leaking Activity context
            context.applicationContext.registerReceiver(
                powerSaveReceiver,
                IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
            )

            // Start AirSync Service conditionally
            ServiceManager.updateServiceState(context)

            // Initial shortcut state
            ShortcutUtil.refreshShortcuts(context, WebSocketUtil.isConnected())
            isNetworkMonitoringActive = true
        }
    }

    fun updateIpAddress(ipAddress: String) {
        _uiState.value = _uiState.value.copy(ipAddress = ipAddress)
        viewModelScope.launch {
            repository.saveIpAddress(ipAddress)
        }
    }

    fun updatePort(port: String) {
        _uiState.value = _uiState.value.copy(port = port)
        viewModelScope.launch {
            repository.savePort(port)
        }
    }

    fun updateSymmetricKey(symmetricKey: String?) {
        _uiState.value = _uiState.value.copy(symmetricKey = symmetricKey)
    }

    fun updateManualPcName(name: String) {
        _uiState.value = _uiState.value.copy(manualPcName = name)
    }

    fun updateManualIsPlus(isPlus: Boolean) {
        _uiState.value = _uiState.value.copy(manualIsPlus = isPlus)
    }

    fun prepareForManualConnection() {
        val manualDevice = ConnectedDevice(
            name = _uiState.value.manualPcName.ifEmpty { "My Mac/PC" },
            ipAddress = _uiState.value.ipAddress,
            port = _uiState.value.port,
            lastConnected = System.currentTimeMillis(),
            isPlus = _uiState.value.manualIsPlus,
            symmetricKey = _uiState.value.symmetricKey
        )
        _uiState.value = _uiState.value.copy(
            lastConnectedDevice = manualDevice,
            isDialogVisible = true
        )
    }

    fun updateDeviceName(name: String) {
        _uiState.value = _uiState.value.copy(deviceNameInput = name)
        _deviceInfo.value = _deviceInfo.value.copy(name = name)
        viewModelScope.launch {
            repository.saveDeviceName(name)
        }

        val ctx = appContext
        if (ctx != null) {
            // Send updated device info immediately so desktop sees the new name
            try {
                SyncManager.sendDeviceInfoNow(ctx, name)
            } catch (_: Exception) {
                // ignore
            }
        }
    }

    fun setLoading(loading: Boolean) {
        _uiState.value = _uiState.value.copy(isLoading = loading)
    }

    fun setResponse(response: String) {
        _uiState.value = _uiState.value.copy(response = response)
    }

    fun setDialogVisible(visible: Boolean) {
        _uiState.value = _uiState.value.copy(isDialogVisible = visible)
    }

    fun setPermissionDialogVisible(visible: Boolean) {
        _uiState.value = _uiState.value.copy(showPermissionDialog = visible)
    }

    fun setConnectionStatus(isConnected: Boolean, isConnecting: Boolean = false) {
        _uiState.value = _uiState.value.copy(
            isConnected = isConnected,
            isConnecting = isConnecting,
            connectingDeviceId = if (!isConnecting) null else _uiState.value.connectingDeviceId
        )
    }

    fun setConnectingDeviceId(id: String?) {
        _uiState.value = _uiState.value.copy(connectingDeviceId = id)
    }

    fun refreshPermissions(context: Context) {
        val missingPermissions = PermissionUtil.getAllMissingPermissions(context)
        val isNotificationEnabled = PermissionUtil.isNotificationListenerEnabled(context)
        _uiState.value = _uiState.value.copy(
            missingPermissions = missingPermissions,
            isNotificationEnabled = isNotificationEnabled
        )
    }

    fun saveLastConnectedDevice(
        pcName: String? = null,
        isPlus: Boolean = false,
        symmetricKey: String? = null
    ) {
        viewModelScope.launch {
            val deviceName = pcName ?: "My Mac"
            val ourIp = _deviceInfo.value.localIp
            val clientIp = _uiState.value.ipAddress
            val port = _uiState.value.port

            // Save using network-aware storage
            repository.saveNetworkDeviceConnection(
                deviceName,
                ourIp,
                clientIp,
                port,
                isPlus,
                symmetricKey
            )

            // Also save to legacy storage for backwards compatibility
            val connectedDevice = ConnectedDevice(
                name = deviceName,
                ipAddress = clientIp,
                port = port,
                lastConnected = System.currentTimeMillis(),
                isPlus = isPlus,
                symmetricKey = symmetricKey
            )
            repository.saveLastConnectedDevice(connectedDevice)
            _uiState.value = _uiState.value.copy(lastConnectedDevice = connectedDevice)

            // Refresh network devices list
            loadNetworkDevices()

            // Notify Smartspacer of device update
            appContext?.let { context ->
                try {
                    AirSyncDeviceTarget.notifyChange(context)
                } catch (_: Exception) {
                    // Smartspacer might not be installed, ignore
                }
            }
        }
    }

    private suspend fun loadNetworkDevices() {
        repository.getAllNetworkDeviceConnections().first().let { devices ->
            _networkDevices.value = devices
        }
    }

    fun getNetworkAwareLastConnectedDevice(): ConnectedDevice? {
        val ourIp = _deviceInfo.value.localIp
        if (ourIp.isEmpty() || ourIp == "Unknown") return null

        // Find the most recent device that has a connection for our current network
        val networkDevice = _networkDevices.value
            .filter { it.getClientIpForNetwork(ourIp) != null }
            .maxByOrNull { it.lastConnected }

        return networkDevice?.toConnectedDevice(ourIp)
    }

    fun setNotificationSyncEnabled(enabled: Boolean) {
        _uiState.value = _uiState.value.copy(isNotificationSyncEnabled = enabled)
        viewModelScope.launch {
            repository.setNotificationSyncEnabled(enabled)
        }
    }

    fun setDeveloperMode(enabled: Boolean) {
        _uiState.value = _uiState.value.copy(isDeveloperMode = enabled)
        viewModelScope.launch {
            repository.setDeveloperMode(enabled)
        }
    }

    fun toggleDeveloperModeVisibility() {
        val newVisibility = !_uiState.value.isDeveloperModeVisible
        _uiState.value = _uiState.value.copy(
            isDeveloperModeVisible = newVisibility
        )
        viewModelScope.launch {
            repository.setDeveloperModeVisible(newVisibility)
        }
    }

    fun setClipboardSyncEnabled(enabled: Boolean) {
        _uiState.value = _uiState.value.copy(isClipboardSyncEnabled = enabled)
        viewModelScope.launch {
            repository.setClipboardSyncEnabled(enabled)
        }
    }

    fun setClipboardHistoryEnabled(enabled: Boolean) {
        _uiState.value = _uiState.value.copy(isClipboardHistoryEnabled = enabled)
        viewModelScope.launch {
            repository.setClipboardHistoryEnabled(enabled)
            if (!enabled) {
                clearClipboardHistory()
            }
        }
    }

    fun setAutoReconnectEnabled(enabled: Boolean) {
        _uiState.value = _uiState.value.copy(isAutoReconnectEnabled = enabled)
        viewModelScope.launch {
            repository.setAutoReconnectEnabled(enabled)
            appContext?.let { ServiceManager.updateServiceState(it) }
        }
    }

    fun setUseBlurEnabled(enabled: Boolean, context: Context) {
        viewModelScope.launch {
            repository.setUseBlurEnabled(enabled)
            updateBlurState(context)
        }
    }

    private fun updateBlurState(context: Context) {
        viewModelScope.launch {
            val isBlurEnabledSetting = repository.getUseBlurEnabled().first()
            val isPowerSaveMode = DeviceInfoUtil.isPowerSaveMode(context)
            val isBlurProblematic = DeviceInfoUtil.isBlurProblematicDevice()

            // 1:1 Logic from Essentials: turned off if power saving is on or device is problematic
            val isBlurEnabled = isBlurEnabledSetting && !isPowerSaveMode && !isBlurProblematic

            _uiState.value = _uiState.value.copy(
                isBlurSettingEnabled = isBlurEnabledSetting,
                isPowerSaveMode = isPowerSaveMode,
                isBlurEnabled = isBlurEnabled
            )
        }
    }



    fun setPitchBlackThemeEnabled(enabled: Boolean) {
        _uiState.value = _uiState.value.copy(isPitchBlackThemeEnabled = enabled)
        viewModelScope.launch {
            repository.setPitchBlackThemeEnabled(enabled)
            // Note: Currently theme changes check via MainActivity collection instead of restart
        }
    }

    fun setWidgetTransparency(alpha: Float) {
        _uiState.value = _uiState.value.copy(widgetTransparency = alpha)
        viewModelScope.launch {
            repository.setWidgetTransparency(alpha)
            appContext?.let { context ->
                app.androp.android.widget.AirSyncWidgetProvider.updateAllWidgets(context)
            }
        }
    }

    fun setDeviceDiscoveryEnabled(context: Context, enabled: Boolean) {
        _uiState.value = _uiState.value.copy(isDeviceDiscoveryEnabled = enabled)
        viewModelScope.launch {
            repository.setDeviceDiscoveryEnabled(enabled)
            ServiceManager.updateServiceState(context)
        }
    }

    fun setQuickShareEnabled(context: Context, enabled: Boolean) {
        _uiState.value = _uiState.value.copy(isQuickShareEnabled = enabled)
        viewModelScope.launch {
            repository.setQuickShareEnabled(enabled)
            val intent =
                Intent(context, app.androp.android.quickshare.QuickShareService::class.java)
            if (enabled) {
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } else {
                context.stopService(intent)
            }
        }
    }

    fun setFileAccessEnabled(context: Context, enabled: Boolean) {
        _uiState.value = _uiState.value.copy(isFileAccessEnabled = enabled)
        viewModelScope.launch {
            repository.setFileAccessEnabled(enabled)
            ServiceManager.updateServiceState(context)
        }
    }

    fun setNotifyOnCrashEnabled(enabled: Boolean) {
        _uiState.value = _uiState.value.copy(isNotifyOnCrashEnabled = enabled)
        viewModelScope.launch {
            repository.setNotifyOnCrashEnabled(enabled)
        }
    }

    fun manualSyncAppIcons(context: Context) {
        _uiState.value = _uiState.value.copy(isIconSyncLoading = true, iconSyncMessage = "")

        SyncManager.manualSyncAppIcons(context) { _, message ->
            viewModelScope.launch {
                _uiState.value = _uiState.value.copy(
                    isIconSyncLoading = false,
                    iconSyncMessage = message
                )
            }
        }
    }

    fun clearIconSyncMessage() {
        _uiState.value = _uiState.value.copy(iconSyncMessage = "")
    }

    // Auth failure dialog controls
    fun showAuthFailure(message: String) {
        _uiState.value =
            _uiState.value.copy(showAuthFailureDialog = true, authFailureMessage = message)
    }

    fun dismissAuthFailure() {
        _uiState.value = _uiState.value.copy(showAuthFailureDialog = false, authFailureMessage = "")
    }

    fun setUserManuallyDisconnected(disconnected: Boolean) {
        viewModelScope.launch {
            repository.setUserManuallyDisconnected(disconnected)
        }
    }

    fun setAppPaused(context: Context, paused: Boolean) {
        viewModelScope.launch {
            if (paused) app.androp.android.utils.BackgroundWorkController.pause(context)
            repository.setAppPaused(paused)
            if (paused) {
                _uiState.value = _uiState.value.copy(
                    isConnected = false,
                    isConnecting = false,
                    response = "Paused"
                )
                ShortcutUtil.refreshShortcuts(context, false)
            } else {
                app.androp.android.utils.BackgroundWorkController.resume()
                repository.setUserManuallyDisconnected(false)
                val isDiscovery = repository.getDeviceDiscoveryEnabled().first()
                app.androp.android.utils.discovery.DiscoveryOrchestrator.start(context, isDiscovery)
                app.androp.android.service.AirSyncService.startScanning(context)
                WebSocketUtil.requestAutoReconnect(context)
                ShortcutUtil.refreshShortcuts(context, false)
            }
        }
    }

    private fun hasNetworkAwareMappingForLastDevice(): ConnectedDevice? {
        val ourIp = _deviceInfo.value.localIp
        val last = _uiState.value.lastConnectedDevice ?: return null
        if (ourIp.isEmpty() || ourIp == "Unknown" || ourIp == "No Wi-Fi") return null
        // Find matching device by name with mapping for our IP
        val networkDevice = _networkDevices.value.firstOrNull {
            it.deviceName == last.name && it.getClientIpForNetwork(ourIp) != null
        }
        return networkDevice?.toConnectedDevice(ourIp)
    }

    private suspend fun loadNetworkDevicesForNetworkChange() {
        // thin wrapper in case logic needs splitting
        loadNetworkDevices()
    }

    // Start monitoring network changes (Wi-Fi IP) to update mappings and trigger auto-reconnect attempts
    fun startNetworkMonitoring(context: Context) {
        if (isNetworkMonitoringActive) return
        isNetworkMonitoringActive = true
        previousNetworkIp = DeviceInfoUtil.getWifiIpAddress(context) ?: "Unknown"

        viewModelScope.launch {
            try {
                NetworkMonitor.observeNetworkChanges(context).collect { networkInfo ->
                    if (repository.isAppPaused().first()) return@collect
                    val currentIp = networkInfo.ipAddress ?: "No Wi-Fi"

                    if (currentIp != previousNetworkIp) {
                        previousNetworkIp = currentIp

                        // Update local device info immediately
                        _deviceInfo.value = _deviceInfo.value.copy(localIp = currentIp)

                        // Always refresh network-aware device mappings on network change
                        loadNetworkDevicesForNetworkChange()

                        // Cancel any ongoing auto-reconnect loop; we'll restart with the new network context if needed
                        try {
                            WebSocketUtil.cancelAutoReconnect()
                        } catch (_: Exception) {
                        }

                        val manual = repository.getUserManuallyDisconnected().first()
                        val autoOn = repository.getAutoReconnectEnabled().first()

                        // Determine if we have a mapping for the last connected device on this network
                        val target = hasNetworkAwareMappingForLastDevice()

                        if (currentIp == "No Wi-Fi" || currentIp == "Unknown") {
                            // No usable Wi‑Fi: ensure we stop any active Wi-Fi WebSocket connection without affecting BLE
                            try {
                                if (WebSocketUtil.isWifiConnected()) {
                                    WebSocketUtil.disconnect(context)
                                }
                            } catch (_: Exception) {
                            }
                            // Stop service if needed
                            ServiceManager.updateServiceState(context)
                            _uiState.value =
                                _uiState.value.copy(isConnected = false, isConnecting = false)
                            return@collect
                        } else {
                            // Ensure service state is updated
                            ServiceManager.updateServiceState(context)
                        }

                        if (target != null) {
                            // We have a specific device mapping for this network. Switch immediately.
                            // Update UI fields so the user sees the correct endpoint.
                            updateIpAddress(target.ipAddress)
                            updatePort(target.port)
                            updateSymmetricKey(target.symmetricKey)

                            // If Wi-Fi WebSocket is connected to old network, disconnect it first
                            if (WebSocketUtil.isWifiConnected()) {
                                try {
                                    WebSocketUtil.disconnect(context)
                                } catch (_: Exception) {
                                }
                            }

                            // Auto-connect if auto-reconnect is enabled and the user hasn't manually disconnected.
                            if (autoOn && !manual) {
                                // Mark as connecting in UI and kick off a non-manual connection (so it won't flip manual flags)
                                _uiState.value = _uiState.value.copy(isConnecting = true)
                                try {
                                    WebSocketUtil.connect(
                                        context = context,
                                        ipAddress = target.ipAddress,
                                        port = target.port.toIntOrNull() ?: 6997,
                                        symmetricKey = target.symmetricKey,
                                        manualAttempt = false,
                                        onConnectionStatus = { connected ->
                                            viewModelScope.launch {
                                                _uiState.value = _uiState.value.copy(
                                                    isConnected = connected,
                                                    isConnecting = false,
                                                    response = if (connected) "Connected successfully!" else "Reconnection failed"
                                                )
                                                if (connected) {
                                                    // Update last connected record timestamp for this device
                                                    try {
                                                        // Persist as the last connected device and refresh network-aware mapping timestamps
                                                        saveLastConnectedDevice(
                                                            pcName = target.name,
                                                            isPlus = target.isPlus,
                                                            symmetricKey = target.symmetricKey
                                                        )
                                                    } catch (_: Exception) {
                                                    }
                                                } else if (autoOn && !manual) {
                                                    // If the immediate connect failed, restart the auto-reconnect loop for this network
                                                    try {
                                                        WebSocketUtil.requestAutoReconnect(context)
                                                    } catch (_: Exception) {
                                                    }
                                                }
                                            }
                                        }
                                    )
                                } catch (_: Exception) {
                                    // Fall back to auto-reconnect loop
                                    try {
                                        WebSocketUtil.requestAutoReconnect(context)
                                    } catch (_: Exception) {
                                    }
                                }
                            } else {
                                // User has disabled auto connect, just update the displayed device/IP
                                _uiState.value = _uiState.value.copy(isConnecting = false)
                            }
                        } else {
                            // No mapping for this network: disconnect if connected and, if allowed, start generic auto-reconnect
                            if (WebSocketUtil.isConnected() || WebSocketUtil.isConnecting()) {
                                try {
                                    WebSocketUtil.disconnect(context)
                                } catch (_: Exception) {
                                }
                            }
                            if (autoOn && !manual) {
                                try {
                                    WebSocketUtil.requestAutoReconnect(context)
                                } catch (_: Exception) {
                                }
                            }
                        }
                    }
                }
            } catch (_: Exception) {
                // ignore
            }
        }
    }

    fun setContinueBrowsingEnabled(enabled: Boolean) {
        _uiState.value = _uiState.value.copy(isContinueBrowsingEnabled = enabled)
        viewModelScope.launch {
            repository.setContinueBrowsingEnabled(enabled)
        }
    }

    fun setSendNowPlayingEnabled(enabled: Boolean) {
        _uiState.value = _uiState.value.copy(isSendNowPlayingEnabled = enabled)
        viewModelScope.launch {
            repository.setSendNowPlayingEnabled(enabled)
            appContext?.let { ctx ->
                // Update media listener immediate behavior and sync status
                app.androp.android.service.MediaNotificationListener.setNowPlayingEnabled(
                    ctx,
                    enabled
                )
            }
        }
    }

    fun setKeepPreviousLinkEnabled(enabled: Boolean) {
        _uiState.value = _uiState.value.copy(isKeepPreviousLinkEnabled = enabled)
        viewModelScope.launch {
            repository.setKeepPreviousLinkEnabled(enabled)
        }
    }

    fun setSmartspacerShowWhenDisconnected(enabled: Boolean) {
        _uiState.value = _uiState.value.copy(isSmartspacerShowWhenDisconnected = enabled)
        viewModelScope.launch {
            repository.setSmartspacerShowWhenDisconnected(enabled)
        }
        // Notify Smartspacer to update immediately
        appContext?.let { context ->
            try {
                AirSyncDeviceTarget.notifyChange(context)
            } catch (_: Exception) {
            }
        }
    }

    fun setMacMediaControlsEnabled(enabled: Boolean) {
        _uiState.value = _uiState.value.copy(isMacMediaControlsEnabled = enabled)
        viewModelScope.launch {
            repository.setMacMediaControlsEnabled(enabled)
            appContext?.let { context ->
                if (enabled) {
                    // Re-evaluate the cached session even if no new Mac packet arrives.
                    app.androp.android.utils.MacDeviceStatusManager.refreshNativePlayer(context)
                } else {
                    app.androp.android.service.MacMediaPlayerService.stopMacMedia(context)
                }
            }
        }
    }

    // Expose DataStore export/import helpers
    suspend fun exportAllDataToJson(context: Context): String? {
        return try {
            val manager = DataStoreManager(context)
            manager.exportAllDataToJson()
        } catch (e: Exception) {
            e.printStackTrace()
            null
        }
    }

    suspend fun importDataFromJson(context: Context, json: String): Boolean {
        return try {
            val manager = DataStoreManager(context)
            manager.importAllDataFromJson(json)
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }

    fun getSymmetricKeyForDevice(deviceName: String): String? {
        return _networkDevices.value.firstOrNull { it.deviceName == deviceName }?.symmetricKey
    }

    // Clipboard history management
    fun addClipboardEntry(text: String, isFromPc: Boolean) {
        if (!_uiState.value.isClipboardHistoryEnabled) return

        val entry = app.androp.android.domain.model.ClipboardEntry(
            id = java.util.UUID.randomUUID().toString(),
            text = text,
            timestamp = System.currentTimeMillis(),
            isFromPc = isFromPc
        )
        val updatedHistory =
            (listOf(entry) + _uiState.value.clipboardHistory).take(100) // Keep last 100 entries
        _uiState.value = _uiState.value.copy(clipboardHistory = updatedHistory)
    }

    fun clearClipboardHistory() {
        _uiState.value = _uiState.value.copy(clipboardHistory = emptyList())
    }

    fun clearDisconnectionClipboardHistory() {
        // Clear clipboard history when disconnected
        _uiState.value = _uiState.value.copy(clipboardHistory = emptyList())
    }

    // Notes Role state setters
    fun setStylusMode(enabled: Boolean) {
        _stylusMode.value = enabled
    }

    fun setLaunchedFromLockScreen(isLockScreen: Boolean) {
        _launchedFromLockScreen.value = isLockScreen
    }

    fun setIsFloatingWindow(isFloating: Boolean) {
        _isFloatingWindow.value = isFloating
    }

    fun setIsNotesRoleHeld(held: Boolean) {
        _isNotesRoleHeld.value = held
    }

    fun setDefaultTab(tab: String) {
        _uiState.value = _uiState.value.copy(defaultTab = tab)
        viewModelScope.launch {
            repository.setDefaultTab(tab)
        }
    }

    fun setEssentialsConnectionEnabled(enabled: Boolean) {
        _uiState.value = _uiState.value.copy(isEssentialsConnectionEnabled = enabled)
        viewModelScope.launch {
            repository.setEssentialsConnectionEnabled(enabled)
            if (enabled) {
                appContext?.let { app.androp.android.utils.MacDeviceStatusManager.broadcastCurrentStatus(it) }
            }
        }
    }

    private fun updateRatingPromptDisplay() {
        // Private androp builds have no store listing.
        _uiState.value = _uiState.value.copy(shouldShowRatingPrompt = false)
    }

    private fun getAppVersionCode(): Int {
        return try {
            val context = appContext ?: return -1
            val packageInfo =
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                    context.packageManager.getPackageInfo(
                        context.packageName,
                        android.content.pm.PackageManager.PackageInfoFlags.of(0)
                    )
                } else {
                    @Suppress("DEPRECATION")
                    context.packageManager.getPackageInfo(context.packageName, 0)
                }
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
                packageInfo.longVersionCode.toInt()
            } else {
                @Suppress("DEPRECATION")
                packageInfo.versionCode
            }
        } catch (_: Exception) {
            -1
        }
    }

    fun setRatingCardDismissed() {
        viewModelScope.launch {
            val currentVersion = getAppVersionCode()
            repository.setLastPromptDismissedVersion(currentVersion)
            updateRatingPromptDisplay()
        }
    }

    fun setAppRated() {
        viewModelScope.launch {
            repository.setHasRatedApp(true)
            updateRatingPromptDisplay()
        }
    }

    fun setUseBlurEnabled(enabled: Boolean) {
        val finalEnabled = if (DeviceInfoUtil.isBlurProblematicDevice()) false else enabled
        _uiState.value = _uiState.value.copy(isBlurEnabled = finalEnabled)
        viewModelScope.launch {
            repository.setUseBlurEnabled(enabled)
        }
    }

    fun setUseRippleEnabled(enabled: Boolean) {
        _uiState.value = _uiState.value.copy(isRippleSettingEnabled = enabled)
        viewModelScope.launch {
            repository.setUseRippleEnabled(enabled)
        }
    }

    fun resetOnboarding() {
        viewModelScope.launch {
            repository.setFirstRun(true)
            repository.setFirstMacConnectionTime(0L)
            repository.setLastPromptDismissedVersion(-1)
            repository.setHasRatedApp(false)
            updateRatingPromptDisplay()
        }
    }

    fun setOnboardingCompleted(completed: Boolean) {
        _uiState.value = _uiState.value.copy(isOnboardingCompleted = completed)
        viewModelScope.launch {
            repository.setFirstRun(!completed)
        }
    }

    private val _mediaApps =
        MutableStateFlow<List<app.androp.android.domain.model.NotificationApp>>(emptyList())
    val mediaApps: StateFlow<List<app.androp.android.domain.model.NotificationApp>> =
        _mediaApps.asStateFlow()

    fun loadMediaApps(context: Context) {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val installed = app.androp.android.utils.AppUtil.getInstalledApps(context)
                val excluded = _uiState.value.excludedMediaPackages
                val mapped = installed.map { app ->
                    app.copy(isEnabled = excluded.contains(app.packageName))
                }
                _mediaApps.value = mapped
            } catch (e: Exception) {
                Log.e("AirSyncViewModel", "Failed to load media apps: ${e.message}")
            }
        }
    }

    fun toggleExcludedMediaPackage(packageName: String, isExcluded: Boolean) {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val currentExcluded = _uiState.value.excludedMediaPackages.toMutableSet()
                if (isExcluded) {
                    currentExcluded.add(packageName)
                } else {
                    currentExcluded.remove(packageName)
                }
                repository.setExcludedMediaPackages(currentExcluded)
                _mediaApps.value = _mediaApps.value.map { app ->
                    if (app.packageName == packageName) app.copy(isEnabled = isExcluded) else app
                }
            } catch (e: Exception) {
                Log.e("AirSyncViewModel", "Failed to toggle excluded media package: ${e.message}")
            }
        }
    }

    fun saveAllMediaApps(apps: List<app.androp.android.domain.model.NotificationApp>) {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val excluded = apps.filter { it.isEnabled }.map { it.packageName }.toSet()
                repository.setExcludedMediaPackages(excluded)
                _mediaApps.value = apps
            } catch (e: Exception) {
                Log.e("AirSyncViewModel", "Failed to save all media apps: ${e.message}")
            }
        }
    }

    private val _notificationApps =
        MutableStateFlow<List<app.androp.android.domain.model.NotificationApp>>(emptyList())
    val notificationApps: StateFlow<List<app.androp.android.domain.model.NotificationApp>> =
        _notificationApps.asStateFlow()

    private val notificationAppsMutex = Mutex()
    private var notificationAppsJob: Job? = null
    private val _notificationAppsLoading = MutableStateFlow(false)
    val notificationAppsLoading: StateFlow<Boolean> = _notificationAppsLoading.asStateFlow()

    fun loadNotificationApps(context: Context) {
        notificationAppsJob?.cancel()
        notificationAppsJob = viewModelScope.launch {
            _notificationAppsLoading.value = true
            try {
                val installed = app.androp.android.utils.AppUtil.getInstalledApps(context)
                // Keep the open settings sheet current when the Mac or discovery changes preferences.
                repository.getNotificationApps().collect { saved ->
                    _notificationApps.value = app.androp.android.utils.AppUtil.mergeWithSavedApps(installed, saved)
                    _notificationAppsLoading.value = false
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (e: Exception) {
                Log.e("AirSyncViewModel", "Failed to load notification apps: ${e.message}")
            } finally {
                _notificationAppsLoading.value = false
            }
        }
    }

    fun toggleNotificationApp(context: Context, packageName: String, enabled: Boolean) {
        setNotificationAppsEnabled(setOf(packageName), enabled)
    }

    fun setNotificationAppsEnabled(packages: Set<String>, enabled: Boolean) {
        if (packages.isEmpty()) return
        updateNotificationAppSelection(packages.associateWith { enabled })
    }

    fun saveAllNotificationApps(
        context: Context,
        apps: List<app.androp.android.domain.model.NotificationApp>
    ) {
        // Apply only the user's changed rows; preserve newer remote choices on other apps.
        val previous = _notificationApps.value.associateBy { it.packageName }
        val changes = apps.filter { previous[it.packageName]?.isEnabled != it.isEnabled }
            .associate { it.packageName to it.isEnabled }
        updateNotificationAppSelection(changes)
    }

    private fun updateNotificationAppSelection(changes: Map<String, Boolean>) {
        if (changes.isEmpty()) return
        viewModelScope.launch {
            notificationAppsMutex.withLock {
                try {
                    val installed = _notificationApps.value.associateBy { it.packageName }
                    val timestamp = System.currentTimeMillis()
                    val updated = repository.updateNotificationApps { saved ->
                        val byPackage = saved.associateBy { it.packageName }.toMutableMap()
                        for ((pkg, enabled) in changes) {
                            val current = byPackage[pkg] ?: installed[pkg] ?: continue
                            byPackage[pkg] = current.copy(isEnabled = enabled, lastUpdated = timestamp)
                        }
                        byPackage.values.toList()
                    }
                    _notificationApps.value = app.androp.android.utils.AppUtil.mergeWithSavedApps(installed.values.toList(), updated)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (e: Exception) {
                    Log.e("AirSyncViewModel", "Failed to save notification selection: ${e.message}")
                }
            }
        }
    }

}
