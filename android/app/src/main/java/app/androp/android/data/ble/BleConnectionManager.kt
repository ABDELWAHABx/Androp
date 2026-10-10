package app.androp.android.data.ble

import android.content.Context
import android.util.Log
import app.androp.android.data.local.DataStoreManager
import app.androp.android.utils.WebSocketUtil
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.launch

class BleConnectionManager(private val context: Context) {
    companion object {
        private const val TAG = "BleConnectionManager"
    }

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private val dataStoreManager = DataStoreManager(context)
    private var bleServer: BleGattServer? = null

    private var isBleEnabled = false
    private var observationJob: Job? = null
    private var isPaused = true
    private var isManuallyDisconnected = false
    private var regularConnectionActive = false

    @OptIn(ExperimentalCoroutinesApi::class)
    private val _serverFlow = kotlinx.coroutines.flow.MutableStateFlow<BleGattServer?>(null)

    @OptIn(ExperimentalCoroutinesApi::class)
    val connectionState = _serverFlow.flatMapLatest { server ->
        server?.connectionState
            ?: kotlinx.coroutines.flow.MutableStateFlow(BleGattServer.BleConnectionState.DISCONNECTED)
    }

    fun start() {
        if (bleServer == null) {
            bleServer = BleGattServer(context)
            _serverFlow.value = bleServer
            BleTransportBridge.initialize(bleServer!!)
        }

        if (observationJob?.isActive == true) return
        observationJob = scope.launch {
            combine(
                dataStoreManager.getBleSyncEnabled(),
                dataStoreManager.getUserManuallyDisconnected(),
                dataStoreManager.isAppPaused(),
                WebSocketUtil.connectionState
            ) { enabled, manuallyDisconnected, isPaused, wsConnected ->
                data class BleInputs(val enabled: Boolean, val manuallyDisconnected: Boolean, val isPaused: Boolean, val wsConnected: Boolean)
                BleInputs(enabled, manuallyDisconnected, isPaused, wsConnected)
            }.collectLatest { inputs ->
                isBleEnabled = inputs.enabled
                isPaused = inputs.isPaused
                isManuallyDisconnected = inputs.manuallyDisconnected
                regularConnectionActive = inputs.wsConnected
                updateBleState(
                    regularConnectionActive = inputs.wsConnected,
                    manuallyDisconnected = inputs.manuallyDisconnected,
                    isPaused = inputs.isPaused
                )
            }
        }
    }

    private fun updateBleState(regularConnectionActive: Boolean, manuallyDisconnected: Boolean, isPaused: Boolean = false) {
        if (isPaused || !isBleEnabled || manuallyDisconnected) {
            Log.d(TAG, "BLE paused or disabled in settings, stopping/pausing server")
            bleServer?.stop()
            return
        }

        if (regularConnectionActive) {
            // Regular Wi-Fi/USB connection is up — pause advertising to save power.
            Log.d(TAG, "Regular connection active — pausing BLE advertising")
            bleServer?.pauseAdvertising()
        } else {
            // No regular connection — ensure server is started and advertising so devices can discover and connect
            Log.d(TAG, "No regular connection — resuming BLE advertising")
            bleServer?.start()
            bleServer?.resumeAdvertising()
        }
    }

    fun stop() {
        observationJob?.cancel()
        observationJob = null
        bleServer?.destroy()
        bleServer = null
        _serverFlow.value = null
        BleTransportBridge.clear()
    }

    val isAuthenticated: Boolean
        get() = bleServer?.isAuthenticated ?: false

    fun sendChunkedNotification(characteristicUuid: java.util.UUID, payload: String): Boolean =
        bleServer?.sendChunkedNotification(characteristicUuid, payload) ?: false

    fun sendNotification(characteristicUuid: java.util.UUID, data: ByteArray): Boolean =
        bleServer?.sendNotification(characteristicUuid, data) ?: false

    fun disconnectAllConnectedDevices() {
        bleServer?.disconnectAllConnectedDevices()
    }

    fun restartServer() {
        Log.d(TAG, "Restarting BLE GATT server...")
        bleServer?.destroy()
        bleServer = BleGattServer(context)
        _serverFlow.value = bleServer
        BleTransportBridge.initialize(bleServer!!)
        if (isBleEnabled && !isPaused && !isManuallyDisconnected && !regularConnectionActive) {
            bleServer?.start()
        }
    }
}
