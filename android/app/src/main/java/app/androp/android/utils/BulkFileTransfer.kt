package app.androp.android.utils

import android.annotation.SuppressLint
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Environment
import android.os.PowerManager
import android.provider.MediaStore
import android.util.Base64
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap

/**
 * Fast file transfers over a direct encrypted TCP stream (see [BulkTransferProtocol]).
 * Received bytes go straight into Downloads while they are hashed, so a 3 GB file is
 * written once and never re-read or copied.
 */
object BulkFileTransfer {
    private const val TAG = "BulkFileTransfer"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val active = ConcurrentHashMap<String, Pair<Job, Socket>>()

    /** Closes the stream; the coroutine notices and cleans up. */
    fun cancel(id: String) {
        active.remove(id)?.let { (job, socket) -> runCatching { socket.close() }; job.cancel() }
    }

    fun isActive(id: String) = active.containsKey(id)

    /** Keeps Wi-Fi at full speed and the CPU awake for the duration of a transfer. */
    @SuppressLint("WakelockTimeout")
    private inline fun <T> keepAwake(context: Context, block: () -> T): T {
        val wifi = context.applicationContext.getSystemService(WifiManager::class.java)
        @Suppress("DEPRECATION")
        val wifiLock = runCatching { wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "androp:transfer") }.getOrNull()
        val wake = runCatching {
            context.getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "androp:transfer")
        }.getOrNull()
        runCatching { wifiLock?.acquire() }
        runCatching { wake?.acquire(60 * 60 * 1000L) }
        try { return block() } finally {
            runCatching { if (wifiLock?.isHeld == true) wifiLock.release() }
            runCatching { if (wake?.isHeld == true) wake.release() }
        }
    }

    private fun connect(host: String, port: Int): Socket = Socket().apply {
        receiveBufferSize = 4 * 1024 * 1024
        sendBufferSize = 4 * 1024 * 1024
        tcpNoDelay = true
        soTimeout = 30_000
        connect(InetSocketAddress(host, port), 5_000)
    }

    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it.toInt() and 255) }

    /**
     * Mac → phone. Returns false when the Mac did not offer a fast stream, so the caller
     * keeps the classic chunked path for older Mac versions.
     */
    fun receiveIfOffered(context: Context, data: JSONObject, name: String, size: Long, mime: String,
                         isClipboard: Boolean, onUnreachable: () -> Unit, onFinished: (Boolean, String?) -> Unit): Boolean {
        val id = data.optString("id")
        val port = data.optInt("bulkPort", 0)
        val key = data.optString("bulkKey").takeIf { it.isNotBlank() }
            ?.let { runCatching { Base64.decode(it, Base64.NO_WRAP) }.getOrNull() }
        val host = WebSocketUtil.currentIpAddress
        if (port !in 1..65535 || key?.size != 32 || host.isNullOrBlank() || active.containsKey(id)) return false
        val job = scope.launch(start = kotlinx.coroutines.CoroutineStart.LAZY) {
            var uri: Uri? = null
            var success = false
            var connected = false
            var failure: String? = "The transfer was interrupted. Try sending again."
            try {
                keepAwake(context) {
                    val socket = connect(host, port)
                    connected = true
                    // Cancel closes this socket, which unblocks a pending read at once.
                    active[id]?.let { active[id] = it.first to socket } ?: run { socket.close(); return@keepAwake }
                    socket.use {
                        val output = DataOutputStream(BufferedOutputStream(socket.getOutputStream()))
                        BulkTransferProtocol.Sealer(key, BulkTransferProtocol.PHONE_TO_MAC)
                            .write(output, BulkTransferProtocol.TYPE_HELLO, id.toByteArray())
                        output.flush()
                        val input = DataInputStream(BufferedInputStream(socket.getInputStream(), 1024 * 1024))
                        val opener = BulkTransferProtocol.Sealer(key, BulkTransferProtocol.MAC_TO_PHONE)
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
                        requireNotNull(context.contentResolver.openOutputStream(uri!!)).buffered(1024 * 1024).use { file ->
                            while (true) {
                                ensureActive()
                                val record = requireNotNull(opener.read(input)) { "The Mac closed the connection" }
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
                                            NotificationUtil.showFileProgress(context, id.hashCode(), name, percent, id, transferKind = "ws")
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
                        require(context.contentResolver.update(uri!!, ContentValues().apply {
                            put(MediaStore.Downloads.IS_PENDING, 0) }, null, null) > 0) { "Couldn't publish the file in Downloads" }
                        success = true
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "Fast receive failed", e)
                failure = e.message?.takeIf { it.length < 160 } ?: failure
            } finally {
                active.remove(id)
                if (!connected && !success) {
                    // Firewall or route problem: let the classic chunked path take over.
                    onUnreachable()
                    return@launch
                }
                if (!success) uri?.let { runCatching { context.contentResolver.delete(it, null, null) } }
                val detail = if (success && isClipboard && mime.startsWith("image/") && uri != null) {
                    if (ClipboardUtil.copyUriToClipboard(context, uri!!)) "Saved image and copied to clipboard" else null
                } else null
                NotificationUtil.showFileComplete(context, id.hashCode(), name, success, contentUri = uri.takeIf { success }, detail = detail)
                onFinished(success, if (success) null else failure)
            }
        }
        active[id] = job to Socket()
        job.start()
        return true
    }

    /**
     * Phone → Mac: streams [uri] to a port the Mac opened for this transfer. Throws on failure;
     * the Mac verifies the digest and reports through transferVerified.
     */
    fun send(context: Context, id: String, uri: Uri, size: Long, host: String, port: Int, key: ByteArray,
             onProgress: (Long) -> Unit) {
        keepAwake(context) {
            connect(host, port).use { socket ->
                active[id] = Job() to socket
                try {
                    val out = DataOutputStream(BufferedOutputStream(socket.getOutputStream(), 1024 * 1024 + 64))
                    val sealer = BulkTransferProtocol.Sealer(key, BulkTransferProtocol.PHONE_TO_MAC)
                    sealer.write(out, BulkTransferProtocol.TYPE_HELLO, id.toByteArray())
                    val digest = MessageDigest.getInstance("SHA-256")
                    val buffer = ByteArray(BulkTransferProtocol.MAX_PAYLOAD)
                    var sent = 0L
                    requireNotNull(context.contentResolver.openInputStream(uri)) { "Couldn't read the file" }.use { input ->
                        while (true) {
                            var filled = 0
                            while (filled < buffer.size) {
                                val count = input.read(buffer, filled, buffer.size - filled)
                                if (count < 0) break
                                filled += count
                            }
                            if (filled == 0) break
                            digest.update(buffer, 0, filled)
                            sealer.write(out, BulkTransferProtocol.TYPE_DATA, buffer, 0, filled)
                            sent += filled
                            onProgress(sent)
                            if (filled < buffer.size) break
                        }
                    }
                    require(size < 0 || sent == size) { "The file changed while sending" }
                    sealer.write(out, BulkTransferProtocol.TYPE_END,
                        JSONObject().put("sha256", hex(digest.digest())).put("size", sent).toString().toByteArray())
                    out.flush()
                    socket.shutdownOutput()
                    // Wait for the Mac to close after it has stored the file.
                    runCatching { socket.getInputStream().read() }
                } finally {
                    active.remove(id)
                }
            }
        }
    }
}
