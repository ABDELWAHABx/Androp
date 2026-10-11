package app.androp.android.data.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.os.PowerManager
import android.provider.MediaStore
import android.util.Log
import app.androp.android.utils.BulkTransferProtocol
import app.androp.android.utils.NotificationUtil
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Small files to and from the Mac over Bluetooth, on an L2CAP channel beside the GATT link,
 * so a photo or PDF doesn't need the temporary Wi-Fi network (which takes the Mac off its own
 * Wi-Fi). Protocol in [BleFileLaneProtocol]. Listens only while the GATT server runs.
 */
@SuppressLint("MissingPermission")
object BleFileLane {
    private const val TAG = "BleFileLane"
    /** A silent channel is closed after this long; Bluetooth moves at least a record per second. */
    private const val STALL_MS = 30_000L

    @Volatile var psm: Int = 0
        private set
    @Volatile private var server: BluetoothServerSocket? = null
    @Volatile private var gatt: BleGattServer? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val outgoing = ConcurrentHashMap<String, Outgoing>()
    private val recentIds = object : LinkedHashMap<String, Boolean>() {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Boolean>?) = size > 64
    }

    private class Outgoing(val context: Context, val uri: Uri, val size: Long, val onProgress: (Long) -> Unit) {
        val result = CompletableDeferred<Pair<Boolean, String?>>()
        @Volatile var socket: BluetoothSocket? = null
    }

    fun start(context: Context, owner: BleGattServer) {
        gatt = owner
        if (server != null) return
        val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter ?: return
        val listener = try { adapter.listenUsingInsecureL2capChannel() } catch (failure: Exception) {
            Log.w(TAG, "Bluetooth file lane unavailable", failure)
            return
        }
        server = listener
        psm = listener.psm
        Thread({ acceptLoop(context.applicationContext, listener) }, "androp-file-lane").apply { isDaemon = true }.start()
        Log.d(TAG, "Bluetooth file lane listening on PSM $psm")
    }

    fun stop(owner: BleGattServer) {
        if (gatt !== owner && gatt != null) return
        val listener = server
        server = null
        psm = 0
        gatt = null
        runCatching { listener?.close() }
        outgoing.values.forEach {
            it.result.complete(false to "Bluetooth disconnected.")
            runCatching { it.socket?.close() }
        }
        outgoing.clear()
    }

    /** True when the connected Mac has read the lane's channel, i.e. it runs a version with the lane. */
    fun canSendToMac(totalBytes: Long): Boolean =
        server != null && gatt?.let { it.isAuthenticated && it.peerUsesFileLane } == true && BleFileLaneProtocol.fits(totalBytes)

    /**
     * Phone → Mac. Asks the Mac over BLE to open a channel for this file, then streams it.
     * Returns null when the lane isn't usable at all, so the caller can use another route.
     */
    suspend fun sendToMac(context: Context, uri: Uri, name: String, size: Long, mime: String,
                          onProgress: (Long) -> Unit): Pair<Boolean, String?>? {
        if (!canSendToMac(size)) return null
        val id = UUID.randomUUID().toString()
        val transfer = Outgoing(context.applicationContext, uri, size, onProgress)
        outgoing[id] = transfer
        try {
            val offer = JSONObject().put("id", id).put("name", name).put("size", size).put("mime", mime)
            if (!BleTransportBridge.sendControl("bleFileOffer", offer)) return null
            // At ~20 KB/s worst case, plus time for the Mac to open the channel.
            val budget = 30_000L + size / 20
            return withTimeoutOrNull(budget) { transfer.result.await() } ?: (false to "Your Mac didn't receive the file over Bluetooth.")
        } finally {
            outgoing.remove(id)
            runCatching { transfer.socket?.close() }
        }
    }

    /** The Mac refused an offer before opening a channel (receiving off, no space, bad name). */
    fun handleReject(data: JSONObject) {
        val id = data.optString("id")
        outgoing[id]?.result?.complete(false to data.optString("error").ifBlank { "Your Mac declined the file." })
    }

    private fun acceptLoop(context: Context, listener: BluetoothServerSocket) {
        while (server === listener) {
            val socket = try { listener.accept() } catch (_: Exception) { break }
            scope.launch { handle(context, socket) }
        }
    }

    private fun handle(context: Context, socket: BluetoothSocket) {
        val watchdog = Watchdog(socket)
        try {
            val owner = gatt
            val pairingKey = owner?.captureAuthenticatedPeer()?.pairingKey
            // Only the authenticated Mac may use the lane; anyone else is dropped before reading.
            if (owner == null || pairingKey == null || !owner.isAuthenticatedAddress(socket.remoteDevice?.address)) return
            val input = DataInputStream(BufferedInputStream(socket.inputStream, 64 * 1024))
            val output = DataOutputStream(BufferedOutputStream(socket.outputStream, 64 * 1024))
            val id = BleFileLaneProtocol.readPreamble(input) ?: return
            synchronized(recentIds) { if (recentIds.put(id, true) != null) return }
            val key = BleFileLaneProtocol.deriveKey(pairingKey, id) ?: return
            watchdog.touch()
            val transfer = outgoing[id]
            if (transfer != null) {
                transfer.socket = socket
                val outcome = runCatching { send(transfer, key, input, output, watchdog) }
                    .getOrElse { Log.w(TAG, "Bluetooth send failed", it); false to "The Bluetooth connection dropped. Try again." }
                transfer.result.complete(outcome)
            } else {
                receive(context, id, key, input, output, watchdog)
            }
        } catch (failure: Exception) {
            Log.w(TAG, "Bluetooth file lane channel failed", failure)
        } finally {
            watchdog.cancel()
            runCatching { socket.close() }
        }
    }

    private fun send(transfer: Outgoing, key: ByteArray, input: DataInputStream, output: DataOutputStream,
                     watchdog: Watchdog): Pair<Boolean, String?> = keepAwake(transfer.context) {
        val sealer = BulkTransferProtocol.Sealer(key, BulkTransferProtocol.PHONE_TO_MAC)
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(BleFileLaneProtocol.RECORD_BYTES)
        var sent = 0L
        requireNotNull(transfer.context.contentResolver.openInputStream(transfer.uri)) { "Couldn't read the file" }.use { file ->
            while (true) {
                val count = file.read(buffer)
                if (count < 0) break
                if (count == 0) continue
                digest.update(buffer, 0, count)
                sealer.write(output, BulkTransferProtocol.TYPE_DATA, buffer, 0, count)
                sent += count
                watchdog.touch()
                transfer.onProgress(sent)
            }
        }
        require(transfer.size < 0 || sent == transfer.size) { "The file changed while sending" }
        sealer.write(output, BulkTransferProtocol.TYPE_END,
            JSONObject().put("sha256", hex(digest.digest())).put("size", sent).toString().toByteArray())
        output.flush()
        // The Mac answers once the file is verified and saved.
        val reply = BulkTransferProtocol.Sealer(key, BulkTransferProtocol.MAC_TO_PHONE).read(input)
            ?: return@keepAwake false to "Your Mac closed the connection."
        val result = JSONObject(String(reply.payload))
        result.optBoolean("ok") to result.optString("error").takeIf { it.isNotBlank() && it != "null" }
    }

    private fun receive(context: Context, id: String, key: ByteArray, input: DataInputStream,
                        output: DataOutputStream, watchdog: Watchdog) = keepAwake(context) {
        val opener = BulkTransferProtocol.Sealer(key, BulkTransferProtocol.MAC_TO_PHONE)
        val reply = BulkTransferProtocol.Sealer(key, BulkTransferProtocol.PHONE_TO_MAC)
        val hello = opener.read(input) ?: return@keepAwake
        require(hello.type == BulkTransferProtocol.TYPE_HELLO) { "Expected file details" }
        val meta = JSONObject(String(hello.payload))
        val name = meta.optString("name")
        val size = meta.optLong("size", -1)
        val mime = meta.optString("mime").ifBlank { "application/octet-stream" }
        val notifId = id.hashCode()
        var uri: Uri? = null
        var success = false
        var failure = "The transfer was interrupted. Try sending again."
        try {
            require(BleFileLaneProtocol.validName(name) && size in 0..BleFileLaneProtocol.MAX_LANE_BYTES) { "Invalid file details" }
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, mime)
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            uri = requireNotNull(context.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)) {
                "Couldn't create a file in Downloads"
            }
            val digest = MessageDigest.getInstance("SHA-256")
            var received = 0L
            var lastProgress = 0L
            requireNotNull(context.contentResolver.openOutputStream(uri)) { "Couldn't write to Downloads" }.buffered(64 * 1024).use { file ->
                while (true) {
                    val record = requireNotNull(opener.read(input)) { "The Mac closed the connection" }
                    watchdog.touch()
                    when (record.type) {
                        BulkTransferProtocol.TYPE_DATA -> {
                            received += record.payload.size
                            require(received <= size) { "Received more data than expected" }
                            digest.update(record.payload)
                            file.write(record.payload)
                            val now = android.os.SystemClock.elapsedRealtime()
                            if (now - lastProgress >= 500) {
                                lastProgress = now
                                val percent = if (size > 0) (received * 100 / size).toInt() else 0
                                NotificationUtil.showFileProgress(context, notifId, name, percent, id, transferKind = "ws")
                            }
                        }
                        BulkTransferProtocol.TYPE_END -> {
                            val expected = JSONObject(String(record.payload)).getString("sha256")
                            require(received == size) { "The file is incomplete" }
                            require(hex(digest.digest()).equals(expected, ignoreCase = true)) { "File verification failed" }
                            break
                        }
                        else -> error("Unexpected record")
                    }
                }
            }
            require(context.contentResolver.update(uri, ContentValues().apply {
                put(MediaStore.Downloads.IS_PENDING, 0) }, null, null) > 0) { "Couldn't publish the file in Downloads" }
            success = true
        } catch (e: Exception) {
            Log.w(TAG, "Bluetooth receive failed", e)
            failure = e.message?.takeIf { it.length < 160 } ?: failure
        } finally {
            if (!success) uri?.let { runCatching { context.contentResolver.delete(it, null, null) } }
            runCatching {
                reply.write(output, BulkTransferProtocol.TYPE_END, JSONObject().put("ok", success)
                    .put("error", if (success) JSONObject.NULL else failure).toString().toByteArray())
                output.flush()
            }
            NotificationUtil.showFileComplete(context, notifId, name.ifBlank { "File" }, success, contentUri = uri.takeIf { success })
        }
    }

    /** Closes a channel that stops moving, which unblocks a read waiting on it. */
    private class Watchdog(private val socket: BluetoothSocket) {
        @Volatile private var last = android.os.SystemClock.elapsedRealtime()
        private val job = CoroutineScope(Dispatchers.IO).launch {
            while (true) {
                kotlinx.coroutines.delay(5_000)
                if (android.os.SystemClock.elapsedRealtime() - last > STALL_MS) {
                    Log.w(TAG, "Bluetooth file lane stalled; closing it")
                    runCatching { socket.close() }
                    return@launch
                }
            }
        }
        fun touch() { last = android.os.SystemClock.elapsedRealtime() }
        fun cancel() = job.cancel()
    }

    @SuppressLint("WakelockTimeout")
    private inline fun <T> keepAwake(context: Context, block: () -> T): T {
        val wake = runCatching {
            context.getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "androp:lane")
        }.getOrNull()
        runCatching { wake?.acquire(30 * 60 * 1000L) }
        try { return block() } finally { runCatching { if (wake?.isHeld == true) wake.release() } }
    }

    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it.toInt() and 255) }
}
