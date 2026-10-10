package app.androp.android.utils

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Base64
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.UUID

/** Receives files over the authenticated, paired WebSocket without broad storage permission. */
object WebSocketFileTransfer {
    private const val TAG = "WebSocketFileTransfer"
    private const val MAX_CHUNK_SIZE = 1024 * 1024
    private data class Command(val context: Context, val type: String, val data: JSONObject)
    private data class Incoming(
        val id: String, val name: String, val size: Long, val mime: String, val chunkSize: Int,
        val checksum: String?, val temporary: File, val handle: RandomAccessFile, val isClipboard: Boolean = false,
        val chunks: java.util.BitSet = java.util.BitSet(), var bytes: Long = 0, var lastProgress: Long = 0,
        var lastActivity: Long = android.os.SystemClock.elapsedRealtime(),
        var pendingUri: Uri? = null
    )
    private class Receiver(val context: Context) {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val queue = Channel<Command>(16)
        val files = java.util.concurrent.ConcurrentHashMap<String, Incoming>()
        val cancelledIDs = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
        fun markCancelled(id: String): Boolean = synchronized(cancelledIDs) {
            if (id.isBlank() || id.length > 128) return@synchronized false
            if (cancelledIDs.size >= 256 && id !in cancelledIDs) return@synchronized false
            cancelledIDs.add(id)
            true
        }
        init {
            scope.launch {
                try {
                    while (true) {
                        val received = if (files.isEmpty()) queue.receiveCatching() else
                            withTimeoutOrNull(60_000) { queue.receiveCatching() }
                        if (received == null) {
                            val now = android.os.SystemClock.elapsedRealtime()
                            files.values.filter { now - it.lastActivity >= 60_000 }.forEach {
                                discard(context, it.id)
                                verified(it.id, false, "Transfer timed out. Try sending again.")
                            }
                            continue
                        }
                        val command = received.getOrNull() ?: break
                        ensureActive()
                        if (BackgroundWorkController.isPaused || !WebSocketUtil.isConnected()) continue
                        val id = command.data.optString("id")
                        try {
                            when (command.type) {
                                "fileTransferInit" -> prepare(command.context, command.data)
                                "fileChunk" -> writeChunk(command.context, command.data)
                                "fileTransferComplete" -> finish(command.context, command.data)
                                "fileTransferCancel" -> discard(command.context, id)
                            }
                        } catch (e: Exception) {
                            if (e is kotlinx.coroutines.CancellationException) throw e
                            Log.w(TAG, "File transfer failed", e)
                            discard(command.context, id)
                            verified(id, false, e.message ?: "Couldn't save the file")
                        }
                    }
                } finally {
                    queue.close()
                    files.values.toList().forEach { cleanup(it, context) }
                    files.clear()
                }
            }
        }

        private fun prepare(context: Context, data: JSONObject) {
            val id = data.getString("id")
            require(id.isNotBlank() && id.length <= 128) { "Invalid transfer ID" }
            require(!cancelledIDs.contains(id)) { "Transfer cancelled" }
            if (files.containsKey(id)) return
            require(files.size < 4) { "Too many active transfers" }
            val rawName = data.getString("name")
            val name = StoragePathResolver.safeFileName(rawName, "shared_file")
            require(name == rawName && name.length <= 255) { "Invalid filename" }
            val size = data.getLong("size")
            val chunkSize = data.getInt("chunkSize")
            require(size >= 0 && chunkSize in FileTransferValidation.MIN_CHUNK_SIZE..MAX_CHUNK_SIZE) { "Invalid transfer size" }
            val temporary = File(context.cacheDir, "incoming_${UUID.randomUUID()}")
            require(size <= context.cacheDir.usableSpace / 2) { "Not enough space on your phone" }
            val file = Incoming(id, name, size, data.optString("mime", "application/octet-stream"),
                chunkSize, data.optString("checksum").takeIf { it.isNotBlank() }, temporary,
                RandomAccessFile(temporary, "rw"), isClipboard = data.optBoolean("isClipboard", false))
            files[id] = file
            progress(context, file, force = true)
        }

        private fun writeChunk(context: Context, data: JSONObject) {
            val id = data.getString("id")
            val file = requireNotNull(files[id]) { "Transfer is no longer active" }
            val index = data.getLong("index")
            checkActive(file)
            val expectedLength = requireNotNull(FileTransferValidation.expectedChunkLength(file.size, file.chunkSize, index)) { "Invalid chunk index" }
            val encoded = data.getString("chunk")
            require(encoded.length <= ((MAX_CHUNK_SIZE + 2) / 3) * 4 + 4) { "Chunk too large" }
            val bytes = Base64.decode(encoded, Base64.NO_WRAP)
            val offset = index * file.chunkSize
            require(bytes.size == expectedLength) { "Invalid chunk size" }
            if (!file.chunks.get(index.toInt())) {
                file.handle.seek(offset)
                file.handle.write(bytes)
                file.chunks.set(index.toInt())
                file.bytes += bytes.size
                progress(context, file)
            }
            checkActive(file)
            file.lastActivity = android.os.SystemClock.elapsedRealtime()
            WebSocketUtil.sendMessage(JSONObject().put("type", "fileChunkAck")
                .put("data", JSONObject().put("id", id).put("index", index)).toString())
        }

        private suspend fun finish(context: Context, data: JSONObject) {
            val id = data.getString("id")
            val file = requireNotNull(files[id]) { "Transfer is no longer active" }
            checkActive(file)
            require(file.bytes == file.size && file.handle.length() == file.size) { "The file is incomplete" }
            file.handle.close()
            val checksum = requireNotNull(data.optString("checksum").takeIf { it.isNotBlank() } ?: file.checksum) { "Missing file verification checksum" }
            require(checksum.matches(Regex("[0-9a-fA-F]{64}"))) { "Invalid file verification checksum" }
            val digest = MessageDigest.getInstance("SHA-256")
            file.temporary.inputStream().buffered(64 * 1024).use { input ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    scope.coroutineContext.ensureActive()
                    checkActive(file)
                    val count = input.read(buffer)
                    if (count < 0) break
                    digest.update(buffer, 0, count)
                }
            }
            val calculated = digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
            require(calculated.equals(checksum, ignoreCase = true)) { "File verification failed" }
            scope.coroutineContext.ensureActive()
            checkActive(file)
            require(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) { "Receiving requires Android 10 or newer" }
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, file.name)
                put(MediaStore.Downloads.MIME_TYPE, file.mime)
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = requireNotNull(context.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)) {
                "Couldn't create a file in Downloads"
            }
            file.pendingUri = uri
            requireNotNull(context.contentResolver.openOutputStream(uri)).buffered(64 * 1024).use { output ->
                file.temporary.inputStream().buffered(64 * 1024).use { input ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        scope.coroutineContext.ensureActive()
                        checkActive(file)
                        val count = input.read(buffer)
                        if (count < 0) break
                        output.write(buffer, 0, count)
                    }
                }
            }
            scope.coroutineContext.ensureActive()
            checkActive(file)
            require(context.contentResolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null) > 0) { "Couldn't publish the file in Downloads" }
            file.pendingUri = null
            files.remove(id)
            file.temporary.delete()
            val detail = if (file.isClipboard && file.mime.startsWith("image/")) {
                if (ClipboardUtil.copyUriToClipboard(context, uri)) "Saved image and copied to clipboard"
                else "Saved image; clipboard copy failed"
            } else null
            NotificationUtil.showFileComplete(context, id.hashCode(), file.name, true, contentUri = uri, detail = detail)
            verified(id, true)
        }

        private fun checkActive(file: Incoming) {
            scope.coroutineContext.ensureActive()
            check(!cancelledIDs.contains(file.id)) { "Transfer cancelled" }
        }

        private fun progress(context: Context, file: Incoming, force: Boolean = false) {
            checkActive(file)
            val now = android.os.SystemClock.elapsedRealtime()
            if (!force && now - file.lastProgress < 800) return
            file.lastProgress = now
            val percent = if (file.size > 0) (file.bytes.toDouble() * 100 / file.size).toInt() else 0
            NotificationUtil.showFileProgress(context, file.id.hashCode(), file.name, percent, file.id, transferKind = "ws")
        }

        fun discard(context: Context, id: String) {
            files.remove(id)?.let { file ->
                cleanup(file, context)
                NotificationUtil.showFileComplete(context, id.hashCode(), file.name, false)
            }
        }

        private fun cleanup(file: Incoming, context: Context?) {
            runCatching { file.handle.close() }
            runCatching { file.temporary.delete() }
            if (context != null) runCatching { file.pendingUri?.let { context.contentResolver.delete(it, null, null) } }
        }
    }

    @Volatile private var receiver: Receiver? = null

    @Synchronized
    fun handle(context: Context, type: String, data: JSONObject) {
        if (BackgroundWorkController.isPaused || !WebSocketUtil.isConnected()) return
        if (type == "fileChunk" && data.optString("chunk").length > ((MAX_CHUNK_SIZE + 2) / 3) * 4 + 4) {
            cancelAll()
            verified(data.optString("id"), false, "Chunk too large")
            return
        }
        val worker = receiver ?: Receiver(context.applicationContext).also { receiver = it }
        if (type == "fileTransferCancel" && !worker.markCancelled(data.optString("id"))) {
            // Keep late-frame tombstones bounded for an otherwise idle connection.
            cancelAll()
            return
        }
        if (!worker.queue.trySend(Command(context.applicationContext, type, data)).isSuccess) {
            // A bounded queue prevents slow storage from retaining unlimited Base64 frames.
            cancelAll()
            verified(data.optString("id"), false, "Phone storage is busy. Try sending again.")
        }
    }

    @Synchronized
    fun cancelAll() {
        val worker = receiver ?: return
        receiver = null
        worker.queue.close()
        worker.scope.cancel()
        NotificationUtil.clearTransferKind("ws")
        app.androp.android.utils.SyncDashboardController.clearTransfers(kind = "ws")
    }

    fun cancelTransfer(id: String) {
        val worker = receiver ?: return
        if (!worker.markCancelled(id)) { cancelAll(); return }
        val data = JSONObject().put("id", id)
        // Cancellation is queued with file writes, so a closed handle cannot be reused.
        val appContext = worker.context
        if (!worker.queue.trySend(Command(appContext, "fileTransferCancel", data)).isSuccess) cancelAll()
        WebSocketUtil.sendMessage(JSONObject().put("type", "fileTransferCancel").put("data", data).toString())
    }

    private fun verified(id: String, success: Boolean, error: String? = null) {
        WebSocketUtil.sendMessage(JSONObject().put("type", "transferVerified")
            .put("data", JSONObject().put("id", id).put("verified", success).put("error", error)).toString())
    }
}
