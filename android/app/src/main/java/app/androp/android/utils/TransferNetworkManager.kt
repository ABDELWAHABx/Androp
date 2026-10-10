package app.androp.android.utils

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import app.androp.android.data.ble.BleGattServer
import app.androp.android.data.ble.BleTransportBridge
import app.androp.android.data.local.DataStoreManager
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.collect
import org.json.JSONObject
import java.util.UUID

/** A short-lived Wi-Fi reservation owned by an authenticated BLE session. No credentials are saved. */
object TransferNetworkManager {
    enum class Phase { IDLE, REQUESTING, STARTING, READY, CONNECTED, ERROR }
    data class State(val id: String? = null, val phase: Phase = Phase.IDLE, val message: String? = null)
    private val mutableState = MutableStateFlow(State())
    val state: StateFlow<State> = mutableState
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val handler = Handler(Looper.getMainLooper())
    private class Lease(val id: String, var server: BleGattServer, var peer: BleGattServer.AuthenticatedPeer, val phoneInitiated: Boolean) {
        var reservation: WifiManager.LocalOnlyHotspotReservation? = null
        var timeout: Job? = null
        var settingsObserver: Job? = null
        var starting = false
    }
    @Volatile private var lease: Lease? = null
    private val completedIDs = LinkedHashSet<String>()
    private val pendingPermission = MutableStateFlow(false)
    val permissionNeeded: StateFlow<Boolean> = pendingPermission

    fun requiredPermissions(): Array<String> = if (Build.VERSION.SDK_INT >= 33)
        arrayOf(Manifest.permission.NEARBY_WIFI_DEVICES) else
        arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
    fun requiredPermission(): String = if (Build.VERSION.SDK_INT >= 33)
        Manifest.permission.NEARBY_WIFI_DEVICES else Manifest.permission.ACCESS_FINE_LOCATION
    fun hasPermission(context: Context): Boolean = ContextCompat.checkSelfPermission(context, requiredPermission()) == PackageManager.PERMISSION_GRANTED
    fun consumePendingPermission(): Boolean = pendingPermission.value.also { pendingPermission.value = false }

    internal fun receive(context: Context, server: BleGattServer, envelope: JSONObject, bytes: Int) {
        if (bytes !in 1..TransferNetworkPolicy.MAX_MESSAGE_BYTES) return
        val peer = server.captureAuthenticatedPeer() ?: return
        val encrypted = envelope.optJSONObject("data")?.opt("encrypted") as? String ?: return
        scope.launch {
            if (!authorized(context, server, peer)) return@launch
            val plain = runCatching { CryptoUtil.decryptMessage(encrypted, CryptoUtil.decodeKey(peer.pairingKey)) }.getOrNull() ?: return@launch
            val data = runCatching { JSONObject(plain) }.getOrNull() ?: return@launch
            val id = data.optString("id").lowercase(java.util.Locale.ROOT)
            val action = data.optString("action")
            if (!TransferNetworkPolicy.accepts(data.optInt("v"), id, action, plain.toByteArray(Charsets.UTF_8).size)) return@launch
            // After an established Wi-Fi handoff, a fresh authenticated BLE session
            // for the same pairing may take over this existing lease's controls.
            lease?.takeIf { it.id == id && it.peer !== peer && it.peer.pairingKey == peer.pairingKey &&
                action in setOf("keepAlive", "stop", "error", "connected") && hasAuthenticatedWifi(it) }?.let {
                it.server = server
                it.peer = peer
            }
            when (action) {
                "start" -> start(context.applicationContext, server, peer, id)
                "connected" -> lease?.takeIf { it.id == id && it.peer === peer }?.let(::markConnected)
                "keepAlive" -> lease?.takeIf { it.id == id && it.peer === peer }?.let { if (!it.starting) armTimeout(it, TransferNetworkPolicy.IDLE_TIMEOUT_MS) }
                "stop" -> lease?.takeIf { it.id == id && it.peer === peer }?.let { close(it) }
                "error" -> lease?.takeIf { it.id == id && it.peer === peer }?.let {
                    close(it, data.optString("message").take(256).ifBlank { "The Mac could not prepare Wi-Fi. Try again." })
                }
                // Android owns the local network. A peer cannot supply credentials or create an unsolicited outbound share.
            }
        }
    }


    /** Wi-Fi may maintain an existing lease, but cannot create a network or an unsolicited share. */
    fun handleNetworkEnvelope(context: Context, envelope: JSONObject, bytes: Int) {
        if (bytes !in 1..TransferNetworkPolicy.MAX_MESSAGE_BYTES) return
        val current = lease ?: return
        val encrypted = envelope.optJSONObject("data")?.opt("encrypted") as? String ?: return
        scope.launch {
            if (!authorizedNetwork(context, current) || lease !== current) return@launch
            val plain = runCatching { CryptoUtil.decryptMessage(encrypted, CryptoUtil.decodeKey(current.peer.pairingKey)) }.getOrNull() ?: return@launch
            val data = runCatching { JSONObject(plain) }.getOrNull() ?: return@launch
            val id = data.optString("id").lowercase(java.util.Locale.ROOT)
            val action = data.optString("action")
            if (!TransferNetworkPolicy.accepts(data.optInt("v"), id, action, plain.toByteArray(Charsets.UTF_8).size) ||
                !TransferNetworkPolicy.allowsNetworkControl(action, id == current.id, hasAuthenticatedWifi(current))) return@launch
            when (action) {
                "connected" -> markConnected(current)
                "keepAlive" -> if (!current.starting) armTimeout(current, TransferNetworkPolicy.IDLE_TIMEOUT_MS)
                "stop" -> close(current)
                "error" -> close(current, data.optString("message").take(256).ifBlank { "The Mac could not maintain Wi-Fi. Send again." })
            }
        }
    }

    private fun hasAuthenticatedWifi(current: Lease): Boolean = WebSocketUtil.authenticatedPeerAddress(current.peer.pairingKey) != null
    private fun hasAuthenticatedBle(current: Lease): Boolean =
        current.server.isCurrentPeer(current.peer) && BleTransportBridge.authenticatedServer() === current.server

    private suspend fun authorizedNetwork(context: Context, current: Lease): Boolean {
        val settings = DataStoreManager.getInstance(context.applicationContext)
        return withTimeoutOrNull(5_000) {
            !BackgroundWorkController.isPaused && !settings.isAppPaused().first() && !settings.getUserManuallyDisconnected().first() &&
                settings.getLastConnectedDevice().first()?.symmetricKey == current.peer.pairingKey && hasAuthenticatedWifi(current) && !BackgroundWorkController.isPaused
        } ?: false
    }

    suspend fun requestMacNetwork(context: Context, id: String = UUID.randomUUID().toString(), expectedPairingKey: String): Boolean = withContext(Dispatchers.Main.immediate) {
        val server = BleTransportBridge.authenticatedServer() ?: return@withContext false
        val peer = server.captureAuthenticatedPeer() ?: return@withContext false
        if (peer.pairingKey != expectedPairingKey || !TransferNetworkPolicy.accepts(1, id, "request", 1) || !authorized(context, server, peer) || lease != null || id in completedIDs) return@withContext false
        val normalizedID = id.lowercase(java.util.Locale.ROOT)
        if (normalizedID in completedIDs) return@withContext false
        val current = createLease(context.applicationContext, normalizedID, server, peer, phoneInitiated = true)
        mutableState.value = State(normalizedID, Phase.REQUESTING, "Preparing Wi-Fi with your Mac…")
        if (!send(current, "request")) { close(current, "Bluetooth could not send the connection request. Try again."); return@withContext false }
        armTimeout(current, TransferNetworkPolicy.IDLE_TIMEOUT_MS)
        true
    }

    /** Only a matching active transfer can refresh or release its reservation. */
    fun keepAlive(id: String) { scope.launch { lease?.takeIf { it.id.equals(id, ignoreCase = true) }?.let {
        if ((!hasAuthenticatedBle(it) && !hasAuthenticatedWifi(it)) || BackgroundWorkController.isPaused) close(it)
        else { if (!it.starting) armTimeout(it, TransferNetworkPolicy.IDLE_TIMEOUT_MS); send(it, "keepAlive") }
    } } }
    fun stop(id: String) { scope.launch { lease?.takeIf { it.id.equals(id, ignoreCase = true) }?.let { send(it, "stop"); close(it) } } }
    internal fun onPeerDisconnected(server: BleGattServer, allowWifiFallback: Boolean = false) {
        val disconnected = lease?.takeIf { it.server === server } ?: return
        scope.launch { if (lease === disconnected && (!allowWifiFallback || BackgroundWorkController.isPaused || !hasAuthenticatedWifi(disconnected))) close(disconnected) }
    }
    fun cancelAll() { scope.launch { lease?.let { send(it, "stop"); close(it) } } }

    private suspend fun authorized(context: Context, server: BleGattServer, peer: BleGattServer.AuthenticatedPeer): Boolean {
        val settings = DataStoreManager.getInstance(context.applicationContext)
        return withTimeoutOrNull(5_000) {
            !BackgroundWorkController.isPaused && !settings.isAppPaused().first() && !settings.getUserManuallyDisconnected().first() &&
                settings.getLastConnectedDevice().first()?.symmetricKey == peer.pairingKey && server.isCurrentPeer(peer) && BleTransportBridge.authenticatedServer() === server && !BackgroundWorkController.isPaused
        } ?: false
    }

    private fun createLease(context: Context, id: String, server: BleGattServer, peer: BleGattServer.AuthenticatedPeer, phoneInitiated: Boolean = false): Lease {
        val current = Lease(id, server, peer, phoneInitiated)
        lease = current
        current.settingsObserver = scope.launch(start = CoroutineStart.LAZY) {
            val settings = DataStoreManager.getInstance(context)
            combine(settings.getLastConnectedDevice(), settings.isAppPaused(), settings.getUserManuallyDisconnected(), WebSocketUtil.connectionState) { saved, paused, disconnected, _ ->
                saved?.symmetricKey == peer.pairingKey && !paused && !disconnected &&
                    (hasAuthenticatedBle(current) || hasAuthenticatedWifi(current))
            }.collect { valid -> if (!valid && lease === current) close(current) }
        }
        current.settingsObserver?.start()
        return current
    }

    private fun start(context: Context, server: BleGattServer, peer: BleGattServer.AuthenticatedPeer, id: String) {
        val existing = lease
        if (existing != null && (existing.id != id || existing.peer !== peer)) {
            send(Lease(id, server, peer, false), "error", JSONObject().put("code", "busy").put("message", "Another transfer is preparing Wi-Fi. Wait for it to finish.")); return
        }
        if (id in completedIDs) return
        val current = existing ?: createLease(context, id, server, peer)
        current.reservation?.let { sendReady(current, it); return }
        if (current.starting) return
        if (!hasPermission(context)) {
            pendingPermission.value = true
            fail(current, "permission", "Open androp on your phone and allow ${if (Build.VERSION.SDK_INT >= 33) "Nearby Wi-Fi devices" else "Location"}, then send again.")
            return
        }
        val wifi = context.applicationContext.getSystemService(WifiManager::class.java)
        if (wifi == null) { fail(current, "unavailable", "Wi-Fi is unavailable on this phone."); return }
        current.starting = true
        mutableState.value = State(id, Phase.STARTING, "Preparing a temporary Wi-Fi connection…")
        armTimeout(current, TransferNetworkPolicy.STARTUP_TIMEOUT_MS)
        try {
            // Public local-only API does not disable or reconfigure the user's internet hotspot.
            wifi.startLocalOnlyHotspot(object : WifiManager.LocalOnlyHotspotCallback() {
                override fun onStarted(reservation: WifiManager.LocalOnlyHotspotReservation) {
                    if (lease !== current || !current.server.isCurrentPeer(current.peer) || BackgroundWorkController.isPaused) {
                        runCatching { reservation.close() }; return
                    }
                    current.reservation = reservation
                    scope.launch {
                        if (!authorized(context, server, peer) || lease !== current) {
                            if (lease === current) close(current) else runCatching { reservation.close() }
                            return@launch
                        }
                        current.starting = false
                        if (sendReady(current, reservation)) {
                            mutableState.value = State(id, Phase.READY, "Temporary Wi-Fi is ready for file transfer.")
                            armTimeout(current, TransferNetworkPolicy.IDLE_TIMEOUT_MS)
                        } else fail(current, "connection", "Bluetooth disconnected while preparing Wi-Fi. Send again.")
                    }
                }
                override fun onStopped() { if (lease === current) fail(current, "stopped", "The phone stopped the temporary Wi-Fi connection. Send again.") }
                override fun onFailed(reason: Int) {
                    if (lease !== current) return
                    val message = when (reason) {
                        ERROR_TETHERING_DISALLOWED -> "Your phone currently blocks temporary Wi-Fi. Check hotspot restrictions or use a shared Wi-Fi network."
                        ERROR_INCOMPATIBLE_MODE -> "Wi-Fi is busy with another hotspot or connection. Use that shared network or turn it off and try again."
                        ERROR_NO_CHANNEL -> "No Wi-Fi channel is available. Try again nearby."
                        else -> "The phone could not start temporary Wi-Fi. Try a shared Wi-Fi network."
                    }
                    fail(current, "unavailable", message)
                }
            }, handler)
        } catch (_: SecurityException) {
            fail(current, "permission", "Allow Nearby Wi-Fi devices in androp's phone permissions. On older Android, enable Location too.")
        } catch (_: IllegalStateException) {
            fail(current, "busy", "The phone is already setting up Wi-Fi. Wait briefly and send again.")
        } catch (_: RuntimeException) {
            fail(current, "unavailable", "The phone could not start temporary Wi-Fi. Try a shared Wi-Fi network.")
        }
    }

    private fun markConnected(current: Lease) {
        if (lease !== current || !TransferNetworkPolicy.acceptsConnected(current.phoneInitiated)) return
        // BLE can deliver this ack before Android consumes its WebSocket handshake.
        // The outgoing share separately requires this phase AND the same-key Wi-Fi session.
        mutableState.value = State(current.id, Phase.CONNECTED, "Connected to your Mac for file transfer.")
        armTimeout(current, TransferNetworkPolicy.IDLE_TIMEOUT_MS)
    }

    private fun sendReady(current: Lease, reservation: WifiManager.LocalOnlyHotspotReservation): Boolean {
        val config = reservation.softApConfiguration
        val ssid = config.ssid ?: return false
        val password = config.passphrase ?: return false
        if (!TransferNetworkPolicy.validCredentials(ssid, password)) return false
        return send(current, "ready", JSONObject().put("ssid", ssid).put("password", password))
    }

    private fun send(current: Lease, action: String, fields: JSONObject = JSONObject()): Boolean {
        if (BackgroundWorkController.isPaused) return false
        val plain = fields.put("v", 1).put("id", current.id).put("action", action).toString()
        val encrypted = runCatching { CryptoUtil.encryptMessage(plain, CryptoUtil.decodeKey(current.peer.pairingKey)) }.getOrNull() ?: return false
        val envelope = JSONObject().put("encrypted", encrypted)
        if (hasAuthenticatedBle(current) && BleTransportBridge.sendControl("transferNetwork", envelope)) return true
        if (!TransferNetworkPolicy.allowsNetworkControl(action, lease === current, hasAuthenticatedWifi(current))) return false
        return WebSocketUtil.sendMessage(JSONObject().put("type", "transferNetwork").put("data", envelope).toString())
    }

    private fun armTimeout(current: Lease, millis: Long) {
        current.timeout?.cancel()
        current.timeout = scope.launch {
            delay(millis)
            if (lease === current) fail(current, "timeout", "The transfer connection timed out. Send again to retry.")
        }
    }
    private fun fail(current: Lease, code: String, message: String) {
        send(current, "error", JSONObject().put("code", code).put("message", message))
        close(current, message)
    }
    private fun close(current: Lease, error: String? = null) {
        if (lease !== current) return
        lease = null
        current.timeout?.cancel()
        current.settingsObserver?.cancel()
        current.reservation?.let { runCatching { it.close() } }
        current.reservation = null
        completedIDs.add(current.id)
        while (completedIDs.size > 64) completedIDs.remove(completedIDs.first())
        mutableState.value = if (error != null) State(current.id, Phase.ERROR, error) else State()
    }
}
