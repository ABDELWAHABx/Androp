package app.androp.android.data.ble

import android.bluetooth.BluetoothAdapter
import android.content.BroadcastReceiver
import android.content.Intent
import android.content.IntentFilter
import androidx.core.content.ContextCompat
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
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.NonCancellable

class BleConnectionManager(private val context: Context) {
    companion object {
        private const val TAG = "BleConnectionManager"
    }

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private val dataStoreManager = DataStoreManager(context)
    private var bleServer: BleGattServer? = null

    private var observationJob: Job? = null
    private var inputs = BleAvailabilityPolicy.Inputs(false, false, true, false, null)
    private var radioReceiverRegistered = false
    private var qrPairingActive = false
    private val radioReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            // Android delivers this receiver on main. Check actual adapter state in
            // start(), rather than trusting a broadcast extra to authorize work.
            val adapter = this@BleConnectionManager.context
                .getSystemService(android.bluetooth.BluetoothManager::class.java)?.adapter
            val enabled = try { adapter?.isEnabled == true } catch (_: SecurityException) { false }
            if (enabled) updateBleState() else bleServer?.stop()
        }
    }

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

        if (!radioReceiverRegistered) {
            try {
                ContextCompat.registerReceiver(context, radioReceiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED),
                    ContextCompat.RECEIVER_EXPORTED)
                radioReceiverRegistered = true
            } catch (failure: RuntimeException) { Log.w(TAG, "Unable to observe Bluetooth power changes", failure) }
        }
        if (observationJob?.isActive == true) return
        observationJob = scope.launch {
            combine(
                dataStoreManager.getBleSyncEnabled(),
                dataStoreManager.getUserManuallyDisconnected(),
                dataStoreManager.isAppPaused(),
                WebSocketUtil.connectionState,
                dataStoreManager.getLastConnectedDevice().map { it?.symmetricKey }.distinctUntilChanged()
            ) { enabled, manuallyDisconnected, paused, wsConnected, pairingKey ->
                BleAvailabilityPolicy.Inputs(enabled, manuallyDisconnected, paused, wsConnected, pairingKey)
            }.distinctUntilChanged().collectLatest { next ->
                // An IP change for the same Mac does not interrupt Bluetooth;
                // changing the pairing key must evict its old authenticated peer.
                if (inputs.pairingKey != next.pairingKey && bleServer?.acceptsPairingKeyChange(next.pairingKey) != true) bleServer?.stop()
                inputs = next
                updateBleState()
            }
        }
    }

    fun refreshAvailability() {
        scope.launch { updateBleState() }
    }

    private fun updateBleState() {
        val mayPair = qrPairingActive && inputs.enabled && !inputs.manuallyDisconnected && !inputs.paused
        if ((!BleAvailabilityPolicy.shouldRun(inputs) && !mayPair) || app.androp.android.utils.BackgroundWorkController.isPaused) {
            bleServer?.stop()
            return
        }
        // Both operations are idempotent. GATT stops advertising after a central
        // connects and resumes on disconnect; Wi-Fi never disables this link.
        bleServer?.start()
        bleServer?.resumeAdvertising()
    }

    /** A normal permission-gated QR action temporarily advertises without saved credentials. */
    suspend fun pairFromQr(symmetricKey: String, pairingSessionId: String, macName: String): Boolean = withContext(Dispatchers.Main) {
        if (qrPairingActive || !BlePairingProtocol.validKey(symmetricKey) ||
            !BlePairingProtocol.validId(pairingSessionId) || dataStoreManager.isAppPaused().first() ||
            app.androp.android.utils.BackgroundWorkController.isPaused ||
            !app.androp.android.utils.PermissionUtil.isBluetoothPermissionsGranted(context)) return@withContext false
        dataStoreManager.setBleSyncEnabled(true)
        dataStoreManager.setUserManuallyDisconnected(false)
        inputs = BleAvailabilityPolicy.Inputs(true, false, false, WebSocketUtil.isWifiConnected(),
            dataStoreManager.getLastConnectedDevice().first()?.symmetricKey)
        qrPairingActive = true
        try {
            start()
            bleServer?.pairFromQr(symmetricKey, pairingSessionId, macName) == true
        } finally {
            withContext(NonCancellable) {
                qrPairingActive = false
                // Return to the ordinary saved-peer policy, including after Cancel/expiry.
                inputs = inputs.copy(pairingKey = dataStoreManager.getLastConnectedDevice().first()?.symmetricKey)
                updateBleState()
            }
        }
    }

    fun stop() {
        observationJob?.cancel()
        observationJob = null
        if (radioReceiverRegistered) {
            runCatching { context.unregisterReceiver(radioReceiver) }
            radioReceiverRegistered = false
        }
        bleServer?.destroy()
        bleServer = null
        _serverFlow.value = null
        BleTransportBridge.clear()
    }

    val isAuthenticated: Boolean
        get() = bleServer?.isAuthenticated ?: false

    fun sendChunkedNotification(characteristicUuid: java.util.UUID, payload: String, stateKey: String? = null): Boolean =
        bleServer?.sendChunkedNotification(characteristicUuid, payload, stateKey) ?: false

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
        updateBleState()
    }
}
