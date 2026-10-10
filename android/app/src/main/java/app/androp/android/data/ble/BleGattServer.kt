package app.androp.android.data.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.Context
import android.os.ParcelUuid
import android.util.Log
import app.androp.android.data.local.DataStoreManager
import app.androp.android.utils.ClipboardSyncManager
import app.androp.android.utils.MacDeviceStatusManager
import app.androp.android.utils.NotificationDismissalUtil
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelChildren
import java.util.UUID
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap

@SuppressLint("MissingPermission")
class BleGattServer(private val context: Context) {
    companion object {
        private const val TAG = "BleGattServer"
        private val CCCD_UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        private val authenticatedFlag = java.util.concurrent.atomic.AtomicBoolean(false)
        fun isAnyAuthenticated(): Boolean = authenticatedFlag.get()
    }

    private val bluetoothManager =
        context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val adapter = bluetoothManager.adapter
    @Volatile private var gattServer: BluetoothGattServer? = null
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private val dataStoreManager = DataStoreManager(context)

    private val _connectionState = MutableStateFlow(BleConnectionState.DISCONNECTED)
    val connectionState = _connectionState.asStateFlow()

    private val connectedDevices = ConcurrentHashMap.newKeySet<BluetoothDevice>()
    private val notificationSubscriptions = ConcurrentHashMap<String, MutableSet<UUID>>()
    private val reassemblers = ConcurrentHashMap<UUID, BleChunkUtil.Reassembler>()
    @Volatile private var authenticatedDevice: BluetoothDevice? = null
    internal class AuthenticatedPeer(val pairingKey: String)
    @Volatile private var authenticatedPeer: AuthenticatedPeer? = null
    internal fun captureAuthenticatedPeer(): AuthenticatedPeer? =
        authenticatedPeer?.takeIf { isAuthenticated && authenticatedDevice != null }
    internal fun isCurrentPeer(peer: AuthenticatedPeer): Boolean =
        isAuthenticated && authenticatedDevice != null && authenticatedPeer === peer

    @Volatile private var serverGeneration = 0L
    private val sendLock = Any()
    private data class OutboundMessage(val device: BluetoothDevice, val uuid: UUID, val chunks: List<ByteArray>,
        val stateKey: String? = null, var index: Int = 0, var retries: Int = 0)
    private val sendQueue = java.util.ArrayDeque<OutboundMessage>()
    private var queuedBytes = 0
    private var notificationInFlight = false
    private var notificationTimeout: Job? = null
    private var notificationRetry: Job? = null
    private var authenticationTimeout: Job? = null
    private val maxQueuedBytes = 512 * 1024
    private val priorityCharacteristics = setOf(BleConstants.CHAR_AUTH_RESULT, BleConstants.CHAR_MAC_CONTROL, BleConstants.CHAR_NOTIFICATION_DISMISS_NOTIFY)
    private val stateCharacteristics = setOf(BleConstants.CHAR_BATTERY_LEVEL, BleConstants.CHAR_SYSTEM_STATE, BleConstants.CHAR_MEDIA_STATE)


    @Volatile
    var isAuthenticated = false
        private set
    @Volatile private var negotiatedMtu = 23
    @Volatile private var isAdvertisingPaused = false

    enum class BleConnectionState {
        DISCONNECTED, ADVERTISING, CONNECTED, AUTHENTICATED
    }

    private val pendingServices = mutableListOf<BluetoothGattService>()
    @Volatile private var servicesReady = false

    /**
     * Start the GATT server and begin advertising
     */
    fun start() {
        if (app.androp.android.utils.BackgroundWorkController.isPaused) return
        if (gattServer != null) {
            Log.d(TAG, "BLE GATT Server already starting or started")
            return
        }

        if (!app.androp.android.utils.PermissionUtil.isBluetoothPermissionsGranted(context)) {
            Log.e(TAG, "Missing Bluetooth permissions, cannot start BLE transport")
            return
        }

        if (adapter == null || !adapter.isEnabled) {
            Log.e(TAG, "Bluetooth adapter not available or disabled")
            return
        }

        try { setupGattServer() } catch (failure: RuntimeException) {
            Log.w(TAG, "Bluetooth stack unavailable; waiting for the next lifecycle event", failure)
            stop()
        }
    }

    /**
     * Stop the GATT server and advertising
     */
    fun stop() {
        app.androp.android.utils.TransferNetworkManager.onPeerDisconnected(this)
        serverGeneration++
        scope.coroutineContext.cancelChildren()
        authenticationTimeout = null
        stopAdvertising()
        val server = gattServer
        gattServer = null
        servicesReady = false
        runCatching { server?.clearServices() }.onFailure { Log.w(TAG, "Unable to clear Bluetooth services", it) }
        runCatching { server?.close() }.onFailure { Log.w(TAG, "Unable to close Bluetooth server", it) }
        connectedDevices.clear()
        notificationSubscriptions.clear()
        authenticatedDevice = null
        negotiatedMtu = 23
        reassemblers.clear()
        clearSendQueue()
        pendingServices.clear()
        _connectionState.value = BleConnectionState.DISCONNECTED
        isAuthenticated = false
        authenticatedPeer = null
        authenticatedFlag.set(false)
        ClipboardSyncManager.onTransportChanged(app.androp.android.utils.WebSocketUtil.isConnected())
        if (!app.androp.android.utils.WebSocketUtil.isWifiConnected()) app.androp.android.utils.SyncManager.stopPeriodicSync()
        isAdvertisingPaused = false
    }

    fun destroy() {
        stop()
        scope.cancel()
    }

    private fun setupGattServer() {
        gattServer = bluetoothManager.openGattServer(context, gattServerCallback) ?: return
        val generation = ++serverGeneration

        pendingServices.clear()

        // System Service
        val systemService = BluetoothGattService(
            BleConstants.SERVICE_SYSTEM,
            BluetoothGattService.SERVICE_TYPE_PRIMARY
        )
        systemService.addCharacteristic(createReadCharacteristic(BleConstants.CHAR_PROTOCOL_VERSION))
        systemService.addCharacteristic(createWriteCharacteristic(BleConstants.CHAR_AUTH_TOKEN))
        systemService.addCharacteristic(createNotifyCharacteristic(BleConstants.CHAR_AUTH_RESULT))
        systemService.addCharacteristic(createNotifyCharacteristic(BleConstants.CHAR_BATTERY_LEVEL))
        systemService.addCharacteristic(createWriteCharacteristic(BleConstants.CHAR_MAC_BATTERY))
        systemService.addCharacteristic(createNotifyCharacteristic(BleConstants.CHAR_SYSTEM_STATE))
        systemService.addCharacteristic(createNotifyCharacteristic(BleConstants.CHAR_MAC_CONTROL))
        systemService.addCharacteristic(createNotifyCharacteristic(BleConstants.CHAR_DEVICE_NAME))
        pendingServices.add(systemService)

        // Notifications Service
        val notifService = BluetoothGattService(
            BleConstants.SERVICE_NOTIFICATIONS,
            BluetoothGattService.SERVICE_TYPE_PRIMARY
        )
        notifService.addCharacteristic(createNotifyCharacteristic(BleConstants.CHAR_NOTIFICATION_DATA))
        notifService.addCharacteristic(createWriteCharacteristic(BleConstants.CHAR_NOTIFICATION_ACTION))
        notifService.addCharacteristic(createWriteCharacteristic(BleConstants.CHAR_NOTIFICATION_DISMISS))
        notifService.addCharacteristic(createNotifyCharacteristic(BleConstants.CHAR_NOTIFICATION_DISMISS_NOTIFY))
        pendingServices.add(notifService)

        // Media Service
        val mediaService = BluetoothGattService(
            BleConstants.SERVICE_MEDIA,
            BluetoothGattService.SERVICE_TYPE_PRIMARY
        )
        mediaService.addCharacteristic(createNotifyCharacteristic(BleConstants.CHAR_MEDIA_STATE))
        mediaService.addCharacteristic(createWriteCharacteristic(BleConstants.CHAR_MEDIA_CONTROL))
        mediaService.addCharacteristic(createWriteCharacteristic(BleConstants.CHAR_MAC_MEDIA_STATE))
        pendingServices.add(mediaService)

        // Clipboard Service
        val clipService = BluetoothGattService(
            BleConstants.SERVICE_CLIPBOARD,
            BluetoothGattService.SERVICE_TYPE_PRIMARY
        )
        clipService.addCharacteristic(createNotifyCharacteristic(BleConstants.CHAR_CLIPBOARD_DATA_NOTIFY))
        clipService.addCharacteristic(createWriteCharacteristic(BleConstants.CHAR_CLIPBOARD_DATA_WRITE))
        pendingServices.add(clipService)

        // Add first service with a small delay for stability
        scope.launch(Dispatchers.Main) {
            delay(300)
            if (generation == serverGeneration && gattServer != null && pendingServices.isNotEmpty()) {
                val first = pendingServices.removeAt(0)
                gattServer?.addService(first)
            }
        }
    }

    private var currentAdvertiseCallback: AdvertiseCallback? = null

    private fun startAdvertising() {
        if (app.androp.android.utils.BackgroundWorkController.isPaused) return
        if (gattServer == null || !servicesReady || isAdvertisingPaused || connectedDevices.isNotEmpty()) return
        if (currentAdvertiseCallback != null) return

        val advertiser = try { adapter.bluetoothLeAdvertiser } catch (failure: RuntimeException) {
            Log.w(TAG, "Bluetooth advertiser unavailable", failure)
            null
        } ?: return

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_POWER)
            .setConnectable(true)
            .setTimeout(0)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .build()

        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(BleConstants.SERVICE_SYSTEM))
            .build()

        val scanResponse = AdvertiseData.Builder()
            .setIncludeDeviceName(true)
            .build()

        val callback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                if (currentAdvertiseCallback !== this || gattServer == null || isAdvertisingPaused) return
                Log.d(TAG, "BLE Advertising started successfully")
                _connectionState.value = BleConnectionState.ADVERTISING
            }

            override fun onStartFailure(errorCode: Int) {
                if (currentAdvertiseCallback !== this || gattServer == null || isAdvertisingPaused) return
                if (errorCode == ADVERTISE_FAILED_ALREADY_STARTED) {
                    Log.d(TAG, "BLE Advertising already started, treating as success")
                    _connectionState.value = BleConnectionState.ADVERTISING
                } else {
                    Log.e(TAG, "BLE Advertising failed: $errorCode")
                    currentAdvertiseCallback = null
                    _connectionState.value = BleConnectionState.DISCONNECTED
                }
            }
        }

        currentAdvertiseCallback = callback
        try { advertiser.startAdvertising(settings, data, scanResponse, callback) }
        catch (failure: RuntimeException) {
            currentAdvertiseCallback = null
            _connectionState.value = BleConnectionState.DISCONNECTED
            Log.w(TAG, "Unable to advertise; waiting for a radio/settings event", failure)
        }
    }

    private fun stopAdvertising() {
        val callback = currentAdvertiseCallback ?: return
        currentAdvertiseCallback = null
        runCatching { adapter.bluetoothLeAdvertiser?.stopAdvertising(callback) }
            .onFailure { Log.w(TAG, "Unable to stop Bluetooth advertising", it) }
    }

    /**
     * Stop advertising while keeping the GATT server alive.
     * Existing BLE connections remain active
     */
    fun pauseAdvertising() {
        if (isAdvertisingPaused) return
        Log.d(TAG, "BLE advertising paused")
        isAdvertisingPaused = true
        stopAdvertising()
        if (_connectionState.value == BleConnectionState.ADVERTISING) {
            _connectionState.value = BleConnectionState.DISCONNECTED
        }
    }

    /**
     * Resume advertising after it was paused. No-op if already advertising.
     */
    fun resumeAdvertising() {
        if (app.androp.android.utils.BackgroundWorkController.isPaused) return
        if (gattServer == null) return
        // Retry only on a lifecycle/radio/settings event after an advertising
        // failure; startAdvertising itself ignores live or connected sessions.
        Log.d(TAG, "BLE advertising available")
        isAdvertisingPaused = false
        startAdvertising()
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            if (gattServer == null) return
            if (status != BluetoothGatt.GATT_SUCCESS) { stop(); return }
            Log.d(TAG, "Service added: ${service.uuid}, status: $status")
            if (pendingServices.isNotEmpty()) {
                val next = pendingServices.removeAt(0)
                gattServer?.addService(next)
            } else {
                Log.d(TAG, "All services added, starting advertising")
                servicesReady = true
                startAdvertising()
            }
        }

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            Log.d(
                TAG,
                "onConnectionStateChange: device=${device.address}, status=$status, newState=$newState, bond=${device.bondState}"
            )

            if (gattServer == null) return
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                Log.d(TAG, "Device connected: ${device.address}")
                if (connectedDevices.isNotEmpty() && device !in connectedDevices) {
                    // Pairing credentials represent one Mac. Do not mix its stream with another central.
                    gattServer?.cancelConnection(device)
                    return
                }
                connectedDevices.add(device)
                negotiatedMtu = 23
                stopAdvertising()
                _connectionState.value = BleConnectionState.CONNECTED
                authenticationTimeout?.cancel()
                val generation = serverGeneration
                authenticationTimeout = scope.launch {
                    delay(15_000)
                    if (generation == serverGeneration && device in connectedDevices && authenticatedDevice != device) {
                        Log.w(TAG, "BLE client authentication timed out")
                        gattServer?.cancelConnection(device)
                    }
                }
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                Log.d(TAG, "Device disconnected: ${device.address}")
                if (!connectedDevices.remove(device)) return
                notificationSubscriptions.remove(device.address)
                authenticationTimeout?.cancel()
                authenticationTimeout = null
                if (authenticatedDevice == device) {
                    authenticatedDevice = null
                    authenticatedPeer = null
                    app.androp.android.utils.TransferNetworkManager.onPeerDisconnected(this@BleGattServer, allowWifiFallback = true)
                }
                reassemblers.clear()
                clearSendQueue()
                if (connectedDevices.isEmpty()) {
                    _connectionState.value =
                        if (gattServer != null && !isAdvertisingPaused) BleConnectionState.ADVERTISING else BleConnectionState.DISCONNECTED
                    isAuthenticated = false
                    authenticatedFlag.set(false)
                    ClipboardSyncManager.onTransportChanged(app.androp.android.utils.WebSocketUtil.isConnected())
                    if (!app.androp.android.utils.WebSocketUtil.isWifiConnected()) app.androp.android.utils.SyncManager.stopPeriodicSync()
                    if (gattServer != null && !isAdvertisingPaused) startAdvertising()
                }
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            Log.d(TAG, "MTU changed for ${device.address}: $mtu")
            if (device in connectedDevices) negotiatedMtu = mtu.coerceIn(23, 517)
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic
        ) {
            if (characteristic.uuid == BleConstants.CHAR_PROTOCOL_VERSION) {
                gattServer?.sendResponse(
                    device,
                    requestId,
                    BluetoothGatt.GATT_SUCCESS,
                    0,
                    byteArrayOf(BleConstants.PROTOCOL_VERSION.toByte())
                )
            } else {
                gattServer?.sendResponse(
                    device,
                    requestId,
                    BluetoothGatt.GATT_READ_NOT_PERMITTED,
                    0,
                    null
                )
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray
        ) {
            if (gattServer == null || app.androp.android.utils.BackgroundWorkController.isPaused) {
                if (responseNeeded) gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_WRITE_NOT_PERMITTED, offset, null)
                return
            }
            if (preparedWrite || offset != 0) {
                if (responseNeeded) gattServer?.sendResponse(device, requestId,
                    BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED, offset, null)
                return
            }

            if (characteristic.uuid != BleConstants.CHAR_AUTH_TOKEN && (!isAuthenticated || authenticatedDevice != device)) {
                Log.w(
                    TAG,
                    "Blocked unauthorized write request to ${characteristic.uuid} from ${device.address}"
                )
                if (responseNeeded) {
                    gattServer?.sendResponse(
                        device,
                        requestId,
                        BluetoothGatt.GATT_WRITE_NOT_PERMITTED,
                        offset,
                        null
                    )
                }
                return
            }

            when (characteristic.uuid) {
                BleConstants.CHAR_AUTH_TOKEN -> handleAuthRequest(device, value)
                BleConstants.CHAR_MAC_BATTERY -> handleMacBattery(value)
                BleConstants.CHAR_NOTIFICATION_ACTION -> handleChunkedWrite(
                    characteristic.uuid,
                    value
                ) { handleNotificationAction(it.toByteArray(Charsets.UTF_8)) }

                BleConstants.CHAR_MEDIA_CONTROL -> handleChunkedWrite(
                    characteristic.uuid,
                    value
                ) { handleMediaControl(it.toByteArray(Charsets.UTF_8)) }

                BleConstants.CHAR_MAC_MEDIA_STATE -> handleChunkedWrite(
                    characteristic.uuid,
                    value
                ) { handleMacMediaState(it) }

                BleConstants.CHAR_CLIPBOARD_DATA_WRITE -> handleChunkedWrite(
                    characteristic.uuid,
                    value
                ) {
                    BleTransportBridge.handleClipboardEnvelope(context, it)
                }

                BleConstants.CHAR_DEVICE_NAME -> handleChunkedWrite(characteristic.uuid, value) {
                    Log.d(TAG, "Received Mac Device Name: $it")
                    // Update Mac name in status manager
                    MacDeviceStatusManager.updateMacStatus(context, name = it)
                }

                BleConstants.CHAR_NOTIFICATION_DISMISS -> handleChunkedWrite(
                    characteristic.uuid,
                    value
                ) { handleNotificationDismiss(it) }

                else -> Log.w(TAG, "Unknown characteristic write: ${characteristic.uuid}")
            }

            if (responseNeeded) {
                gattServer?.sendResponse(
                    device,
                    requestId,
                    BluetoothGatt.GATT_SUCCESS,
                    offset,
                    value
                )
            }
        }

        private fun handleChunkedWrite(uuid: UUID, value: ByteArray, onComplete: (String) -> Unit) {
            reassemblers.getOrPut(uuid) { BleChunkUtil.Reassembler() }.addChunk(value)?.let(onComplete)
        }

        override fun onDescriptorReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            descriptor: BluetoothGattDescriptor
        ) {
            Log.d(TAG, "Descriptor read request: ${descriptor.uuid}")
            if (offset != 0 || descriptor.uuid != CCCD_UUID) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED, offset, null)
                return
            }
            val subscribed = notificationSubscriptions[device.address]?.contains(descriptor.characteristic.uuid) == true
            gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0,
                if (subscribed) BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE else BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE)
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray
        ) {
            val valid = !preparedWrite && offset == 0 && descriptor.uuid == CCCD_UUID &&
                (value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) ||
                    value.contentEquals(BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE))
            if (valid) {
                val subscriptions = notificationSubscriptions.getOrPut(device.address) { ConcurrentHashMap.newKeySet() }
                if (value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)) {
                    subscriptions.add(descriptor.characteristic.uuid)
                } else {
                    subscriptions.remove(descriptor.characteristic.uuid)
                }
            }
            if (responseNeeded) gattServer?.sendResponse(device, requestId,
                if (valid) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED, offset, null)
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            synchronized(sendLock) {
                val head = sendQueue.peekFirst() ?: return
                if (!notificationInFlight || head.device != device) return
                notificationInFlight = false
                notificationTimeout?.cancel()
                notificationTimeout = null
                if (status == BluetoothGatt.GATT_SUCCESS) { head.index++; head.retries = 0 } else {
                    Log.w(TAG, "BLE notification failed: $status; dropping incomplete message")
                    removeHeadMessage()
                }
                if (sendQueue.peekFirst() === head && head.index == head.chunks.size) removeHeadMessage()
                // Other characteristics have independent reassembly buffers. Let a
                // control packet bypass a large clipboard after the current packet.
                val priority = sendQueue.firstOrNull { it.uuid in priorityCharacteristics }
                if (priority != null && priority !== sendQueue.peekFirst()) {
                    sendQueue.remove(priority)
                    sendQueue.addFirst(priority)
                }
                drainNotifications()
            }
        }
    }

    private fun handleAuthRequest(device: BluetoothDevice, token: ByteArray) {
        val generation = serverGeneration
        scope.launch {
            val deviceData = dataStoreManager.getLastConnectedDevice().first()
            val storedKey = deviceData?.symmetricKey
            Log.d(
                TAG,
                "Handling auth request from ${device.address}. Device in DB: ${deviceData?.name}, hasKey: ${storedKey != null}"
            )

            if (generation != serverGeneration || device !in connectedDevices ||
                app.androp.android.utils.BackgroundWorkController.isPaused) return@launch
            if (storedKey != null) {
                val expectedToken = BleTransportBridge.deriveAuthToken(storedKey)
                if (expectedToken.isNotEmpty() && MessageDigest.isEqual(token, expectedToken.toByteArray(Charsets.UTF_8))) {
                    Log.i(TAG, "BLE Auth Success!")
                    authenticationTimeout?.cancel()
                    authenticationTimeout = null
                    authenticatedDevice = device
                    authenticatedPeer = AuthenticatedPeer(storedKey)
                    isAuthenticated = true
                    authenticatedFlag.set(true)
                    ClipboardSyncManager.onPeerChanged(storedKey)
                    ClipboardSyncManager.onTransportChanged(true)
                    _connectionState.value = BleConnectionState.AUTHENTICATED
                    sendNotification(
                        BleConstants.CHAR_AUTH_RESULT,
                        byteArrayOf(BleConstants.AUTH_SUCCESS)
                    )
                    BleTransportBridge.sendDeviceName()
                    dataStoreManager.setUserManuallyDisconnected(false)
                    if (generation != serverGeneration || !isAuthenticated || authenticatedDevice != device ||
                        app.androp.android.utils.BackgroundWorkController.isPaused) return@launch
                    BleTransportBridge.sendBatteryStatus(app.androp.android.utils.DeviceInfoUtil.getBatteryInfo(context))
                    app.androp.android.utils.SyncManager.startPeriodicSync(context)
                    app.androp.android.utils.SyncManager.checkAndSyncDeviceStatus(context, forceSync = true)
                    // Retain the existing connected-device foreground service
                    // when Bluetooth is the first/only transport to authenticate.
                    app.androp.android.service.AirSyncService.start(context, deviceData?.name)
                } else {
                    Log.w(TAG, "BLE Auth Failed! Token mismatch.")
                    sendNotification(
                        BleConstants.CHAR_AUTH_RESULT,
                        byteArrayOf(BleConstants.AUTH_FAILED)
                    )
                }
            } else {
                Log.w(TAG, "BLE Auth Failed! No symmetric key found for last connected device.")
                sendNotification(
                    BleConstants.CHAR_AUTH_RESULT,
                    byteArrayOf(BleConstants.AUTH_FAILED)
                )
            }
        }
    }

    private fun handleNotificationDismiss(id: String) {
        Log.d(TAG, "Handling notification dismissal from BLE: $id")
        NotificationDismissalUtil.dismissNotification(id)
    }

    private fun handleMacBattery(value: ByteArray) {
        if (!isAuthenticated) return
        val payload = String(value, Charsets.UTF_8)
        val parts = if (payload.contains(BleConstants.DELIMITER)) payload.split(BleConstants.DELIMITER) else payload.split("|")
        if (parts.size >= 2) {
            val level = parts[0].toIntOrNull() ?: -1
            val isCharging = parts[1] == "1"
            Log.d(TAG, "Received Mac battery level via BLE: $level%, charging: $isCharging")
            MacDeviceStatusManager.updateBatteryStatus(context, level, isCharging)
        } else if (value.size == 1) {
            // Legacy 1-byte fallback
            val level = value[0].toInt() and 0xFF
            MacDeviceStatusManager.updateBatteryStatus(context, level, false)
        }
    }

    private fun handleMacMediaState(payload: String) {
        if (!isAuthenticated) return
        val parts = payload.split(BleConstants.DELIMITER)
        if (parts.size >= 6) {
            val isPlaying = parts[0] == "1"
            val title = parts[1]
            val artist = parts[2]
            val volume = parts[3].toIntOrNull() ?: 0
            val isMuted = parts[4] == "1"
            val likeStatus = parts[5]
            val albumArt = if (parts.size >= 7) parts[6] else null

            Log.d(TAG, "Received Mac media state via BLE: $title by $artist (Playing: $isPlaying)")
            MacDeviceStatusManager.updateMusicStatus(
                context, isPlaying, title, artist, volume, isMuted, likeStatus, albumArt
            )
        }
    }

    private fun handleNotificationAction(value: ByteArray) {
        if (!isAuthenticated) return
        val data = String(value, Charsets.UTF_8)
        BleTransportBridge.handleNotificationAction(data, context)
    }

    private fun handleMediaControl(value: ByteArray) {
        if (!isAuthenticated) return
        val action = String(value, Charsets.UTF_8)
        BleTransportBridge.handleMediaControl(action, context)
    }

    /**
     * Send a notification to all connected devices (with chunking)
     */
    fun sendNotification(characteristicUuid: UUID, data: ByteArray): Boolean {
        return enqueueNotification(characteristicUuid, listOf(data))
    }

    fun sendChunkedNotification(characteristicUuid: UUID, payload: String, stateKey: String? = null): Boolean {
        // negotiatedMtu includes the ATT opcode and attribute handle (3 bytes).
        val chunks = BleChunkUtil.splitIntoChunks(payload, negotiatedMtu - 3)
        return chunks.isNotEmpty() && enqueueNotification(characteristicUuid, chunks, stateKey)
    }

    private fun enqueueNotification(uuid: UUID, chunks: List<ByteArray>, stateKey: String? = null): Boolean {
        val device = if (uuid == BleConstants.CHAR_AUTH_RESULT) connectedDevices.firstOrNull() else authenticatedDevice
        if (app.androp.android.utils.BackgroundWorkController.isPaused || device == null || device !in connectedDevices ||
            notificationSubscriptions[device.address]?.contains(uuid) != true) return false
        return synchronized(sendLock) {
            val replacementKey = stateKey ?: uuid.takeIf { it in stateCharacteristics }?.toString()
            if (replacementKey != null) {
                // Match both characteristic and message kind: CHAR_MAC_CONTROL
                // also carries commands and correlated responses that must survive.
                // Never discard the head or the tail of an in-flight message.
                val iterator = sendQueue.iterator()
                while (iterator.hasNext()) {
                    val queued = iterator.next()
                    if (queued.uuid == uuid && queued.stateKey == replacementKey &&
                        queued.index == 0 && queued !== sendQueue.peekFirst()) {
                        queuedBytes -= queued.chunks.sumOf { it.size }
                        iterator.remove()
                    }
                }
            }
            val byteCount = chunks.sumOf { it.size }
            if (queuedBytes + byteCount > maxQueuedBytes || sendQueue.size >= 256) {
                Log.w(TAG, "BLE send queue full; dropping new message")
                return false
            }
            queuedBytes += byteCount
            val message = OutboundMessage(device, uuid, chunks, stateKey = replacementKey)
            if (uuid in priorityCharacteristics && !notificationInFlight && notificationRetry?.isActive != true) {
                sendQueue.addFirst(message)
            } else {
                sendQueue.addLast(message)
            }
            drainNotifications()
            true
        }
    }

    private fun clearSendQueue() = synchronized(sendLock) {
        sendQueue.clear()
        queuedBytes = 0
        notificationInFlight = false
        notificationTimeout?.cancel()
        notificationTimeout = null
        notificationRetry?.cancel()
        notificationRetry = null
    }

    private fun removeHeadMessage() {
        val message = sendQueue.pollFirst() ?: return
        queuedBytes -= message.chunks.sumOf { it.size }
    }

    // Android permits a single outstanding GATT notification per server. The
    // completion callback releases exactly that packet, across all characteristics.
    private fun drainNotifications() {
        if (notificationInFlight || notificationRetry?.isActive == true) return
        while (sendQueue.isNotEmpty()) {
            val message = sendQueue.peekFirst() ?: return
            val server = gattServer
            val characteristic = findCharacteristic(message.uuid)
            if (server == null || characteristic == null || message.device !in connectedDevices) {
                removeHeadMessage()
                continue
            }
            val data = message.chunks[message.index]
            notificationInFlight = true
            val accepted = try {
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                    server.notifyCharacteristicChanged(message.device, characteristic, false, data) == android.bluetooth.BluetoothStatusCodes.SUCCESS
                } else {
                    @Suppress("DEPRECATION")
                    characteristic.value = data
                    @Suppress("DEPRECATION")
                    server.notifyCharacteristicChanged(message.device, characteristic, false)
                }
            } catch (e: Exception) {
                Log.w(TAG, "BLE notification rejected: ${e.message}")
                false
            }
            if (accepted) {
                val generation = serverGeneration
                notificationTimeout = scope.launch {
                    delay(10_000)
                    synchronized(sendLock) {
                        if (generation == serverGeneration && notificationInFlight && sendQueue.peekFirst() === message) {
                            Log.w(TAG, "BLE notification completion timed out; resetting connection")
                            clearSendQueue()
                            app.androp.android.utils.TransferNetworkManager.onPeerDisconnected(this@BleGattServer, allowWifiFallback = true)
                            isAuthenticated = false
                            authenticatedPeer = null
                            authenticatedDevice = null
                            authenticatedFlag.set(false)
                            ClipboardSyncManager.onTransportChanged(app.androp.android.utils.WebSocketUtil.isConnected())
                            if (!app.androp.android.utils.WebSocketUtil.isWifiConnected()) app.androp.android.utils.SyncManager.stopPeriodicSync()
                            gattServer?.cancelConnection(message.device)
                        }
                    }
                }
                return
            }
            notificationInFlight = false
            if (++message.retries <= 3) {
                val generation = serverGeneration
                notificationRetry = scope.launch {
                    delay(40L * message.retries)
                    synchronized(sendLock) {
                        notificationRetry = null
                        if (generation == serverGeneration) drainNotifications()
                    }
                }
                return
            }
            Log.w(TAG, "BLE stack repeatedly rejected notification; dropping incomplete message")
            removeHeadMessage()
        }
    }

    private fun findCharacteristic(uuid: UUID): BluetoothGattCharacteristic? {
        gattServer?.services?.forEach { service ->
            service.getCharacteristic(uuid)?.let { return it }
        }
        return null
    }

    private fun createReadCharacteristic(uuid: UUID): BluetoothGattCharacteristic {
        return BluetoothGattCharacteristic(
            uuid,
            BluetoothGattCharacteristic.PROPERTY_READ,
            BluetoothGattCharacteristic.PERMISSION_READ
        )
    }

    private fun createWriteCharacteristic(uuid: UUID): BluetoothGattCharacteristic {
        return BluetoothGattCharacteristic(
            uuid,
            BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
            BluetoothGattCharacteristic.PERMISSION_WRITE
        )
    }

    private fun createNotifyCharacteristic(uuid: UUID): BluetoothGattCharacteristic {
        val char = BluetoothGattCharacteristic(
            uuid,
            BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ
        )
        // Add CCCD for notification support
        val configDescriptor = BluetoothGattDescriptor(
            UUID.fromString("00002902-0000-1000-8000-00805f9b34fb"),
            BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
        )
        char.addDescriptor(configDescriptor)
        return char
    }

    fun disconnectAllConnectedDevices() {
        app.androp.android.utils.TransferNetworkManager.onPeerDisconnected(this)
        Log.d(TAG, "Disconnecting all connected BLE devices manually...")
        val devicesCopy = connectedDevices.toList()
        for (device in devicesCopy) {
            try {
                gattServer?.cancelConnection(device)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to cancel connection for ${device.address}: ${e.message}")
            }
        }
        isAuthenticated = false
        authenticatedPeer = null
        authenticatedFlag.set(false)
        ClipboardSyncManager.onTransportChanged(app.androp.android.utils.WebSocketUtil.isConnected())
        if (!app.androp.android.utils.WebSocketUtil.isWifiConnected()) app.androp.android.utils.SyncManager.stopPeriodicSync()
        _connectionState.value = if (gattServer != null && !isAdvertisingPaused) BleConnectionState.ADVERTISING else BleConnectionState.DISCONNECTED
        authenticatedDevice = null
        clearSendQueue()
        reassemblers.clear()
        if (gattServer != null && !isAdvertisingPaused) {
            startAdvertising()
        }
    }
}
