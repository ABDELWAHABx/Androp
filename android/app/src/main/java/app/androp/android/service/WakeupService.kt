package app.androp.android.service

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.util.Log
import app.androp.android.data.local.DataStoreManager
import app.androp.android.utils.BackgroundWorkController
import app.androp.android.utils.WakeupHttpHeaders
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import app.androp.android.utils.WakeupHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.IOException
import java.io.OutputStreamWriter
import java.io.PrintWriter
import java.net.ServerSocket
import java.net.Socket

/**
 * Service that runs a lightweight HTTP server
 * to receive wake-up requests from Mac clients for initiating reconnection.
 * UDP wake-up requests are now handled by UDPDiscoveryManager to avoid port conflicts.
 */
class WakeupService : Service() {
    companion object {
        private const val TAG = "WakeupService"
        private const val HTTP_PORT = 8891 // HTTP server port
        private const val WAKEUP_ENDPOINT = "/wakeup"

        fun startService(context: Context) {
            if (BackgroundWorkController.isPaused) return
            val intent = Intent(context, WakeupService::class.java)
            try { context.startService(intent) }
            catch (error: RuntimeException) { Log.w(TAG, "Wake-up service start rejected", error) }
        }

        fun stopService(context: Context) {
            val intent = Intent(context, WakeupService::class.java)
            context.stopService(intent)
        }
    }

    private var httpServerSocket: ServerSocket? = null
    private var serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    @Volatile private var isRunning = false
    private val clients = java.util.concurrent.CopyOnWriteArraySet<Socket>()
    private var startJob: kotlinx.coroutines.Job? = null
    private val lifecycleLock = Any()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "WakeupService created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!isRunning && startJob?.isActive != true) startWakeupListeners()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        stopWakeupListeners()
        serviceScope.cancel()
        Log.d(TAG, "WakeupService destroyed")
    }

    private fun startWakeupListeners() {
        startJob = serviceScope.launch {
            try {
                if (BackgroundWorkController.isPaused || DataStoreManager.getInstance(this@WakeupService).isAppPaused().first()) {
                    stopSelf()
                    return@launch
                }
                synchronized(lifecycleLock) {
                    if (!isActive || BackgroundWorkController.isPaused) return@launch
                    isRunning = true
                }

                // Start HTTP server
                startHttpServer()

                Log.i(TAG, "Wake-up HTTP listener started on port $HTTP_PORT")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start wake-up listeners", e)
            }
        }
    }

    private fun stopWakeupListeners() {
        synchronized(lifecycleLock) {
            isRunning = false
            startJob?.cancel()
            clients.forEach { runCatching { it.close() } }
            clients.clear()

            // Stop HTTP server
            try {
                httpServerSocket?.close()
            } catch (e: Exception) {
                Log.w(TAG, "Error closing HTTP server socket", e)
            }
            httpServerSocket = null
        }

        Log.i(TAG, "Wake-up HTTP server stopped")
    }

    private suspend fun startHttpServer() {
        withContext(Dispatchers.IO) {
            try {
                val server = synchronized(lifecycleLock) {
                    if (!isActive || !isRunning || BackgroundWorkController.isPaused) return@withContext
                    ServerSocket(HTTP_PORT).also { httpServerSocket = it }
                }

                serviceScope.launch {
                    while (isActive && isRunning && !server.isClosed) {
                        try {
                            val clientSocket = server.accept()
                            clientSocket.soTimeout = 5000
                            val accepted = synchronized(lifecycleLock) {
                                if (!isRunning || BackgroundWorkController.isPaused || clients.size >= 16) false
                                else { clients.add(clientSocket); true }
                            }
                            if (!accepted) {
                                clientSocket.close()
                            } else {
                                // Handle client connection in a separate coroutine
                                launch {
                                    try { handleHttpRequest(clientSocket) }
                                    finally { clients.remove(clientSocket); runCatching { clientSocket.close() } }
                                }
                            }
                        } catch (e: Exception) {
                            if (isRunning) {
                                Log.e(TAG, "Error accepting HTTP connection", e)
                            }
                        }
                    }
                }

                Log.d(TAG, "HTTP server started on port $HTTP_PORT")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start HTTP server", e)
                stopWakeupListeners()
                stopSelf()
            }
        }
    }

    private suspend fun handleHttpRequest(clientSocket: Socket) {
        withContext(Dispatchers.IO) {
            try {
                clientSocket.use { socket ->
                    val input = BufferedInputStream(socket.getInputStream())
                    val output = PrintWriter(OutputStreamWriter(socket.getOutputStream(), Charsets.UTF_8), true)
                    val deadline = System.nanoTime() + 5_000_000_000L
                    val checkDeadline = {
                        if (System.nanoTime() >= deadline) throw java.net.SocketTimeoutException("Wake-up request deadline exceeded")
                    }

                    // Read HTTP request line
                    val requestLine = readHttpLine(input, checkDeadline)
                    if (requestLine == null) return@withContext

                    val parts = requestLine.split(" ")
                    if (parts.size < 3) return@withContext

                    val method = parts[0]
                    val path = parts[1]

                    // Read headers to find Content-Length
                    val contentLength = WakeupHttpHeaders.readContentLength(input, checkDeadline)
                    if (!isRunning || BackgroundWorkController.isPaused) return@withContext
                    // Handle wake-up request
                    if (method == "POST" && path == WAKEUP_ENDPOINT) {
                        // Read request body
                        val body = if (contentLength > 0) {
                            val bodyBytes = ByteArray(contentLength)
                            var readCount = 0
                            while (readCount < contentLength) {
                                checkDeadline()
                                val count = input.read(bodyBytes, readCount, contentLength - readCount)
                                if (count < 0) throw IOException("Incomplete wake-up request")
                                readCount += count
                            }
                            String(bodyBytes, Charsets.UTF_8)
                        } else {
                            ""
                        }

                        Log.d(TAG, "Received HTTP wake-up request (${body.length} characters)")

                        // Parse the wake-up request
                        try {
                            val jsonRequest = JSONObject(body)

                            // Handle nested JSON structure from Mac
                            val macIp: String
                            val macPort: Int
                            val macName: String

                            if (jsonRequest.has("data")) {
                                // Mac sends nested format: {"type": "wakeUpRequest", "data": {...}}
                                val data = jsonRequest.getJSONObject("data")
                                macIp = data.optString(
                                    "macIP",
                                    ""
                                ) // Note: Mac uses "macIP" not "macIp"
                                macPort = data.optInt("macPort", 6997)
                                macName = data.optString("macName", "Mac")
                            } else {
                                // Fallback to flat structure
                                macIp = jsonRequest.optString("macIp", "")
                                macPort = jsonRequest.optInt("macPort", 6997)
                                macName = jsonRequest.optString("macName", "Mac")
                            }

                            // Send success response
                            val response =
                                """{"status": "success", "message": "Wake-up request received"}"""
                            sendHttpResponse(output, 200, "OK", response)

                            // Process the wake-up request using centralized handler
                            WakeupHandler.processWakeupRequest(
                                this@WakeupService,
                                macIp,
                                macPort,
                                macName
                            )
                        } catch (e: Exception) {
                            Log.e(TAG, "Error parsing wake-up request", e)
                            val response = """{"status": "error", "message": "Invalid JSON"}"""
                            sendHttpResponse(output, 400, "Bad Request", response)
                        }
                    } else if (method == "OPTIONS") {
                        // Handle CORS preflight
                        sendCorsResponse(output)
                    } else {
                        // Method not allowed or path not found
                        val response =
                            """{"status": "error", "message": "Method not allowed or path not found"}"""
                        sendHttpResponse(output, 405, "Method Not Allowed", response)
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error handling HTTP request", e)
            }
        }
    }

    private fun readHttpLine(input: BufferedInputStream, checkDeadline: () -> Unit): String? {
        val line = StringBuilder()
        while (line.length < 8192) {
            checkDeadline()
            val next = input.read()
            if (next < 0) return if (line.isEmpty()) null else line.toString()
            if (next == 10) return line.toString()
            if (next != 13) line.append(next.toChar())
        }
        throw IOException("HTTP line too long")
    }

    private fun sendHttpResponse(
        output: PrintWriter,
        statusCode: Int,
        statusText: String,
        body: String
    ) {
        output.print("HTTP/1.1 $statusCode $statusText\r\n")
        output.print("Content-Type: application/json\r\n")
        output.print("Access-Control-Allow-Origin: *\r\n")
        output.print("Access-Control-Allow-Methods: POST, OPTIONS\r\n")
        output.print("Access-Control-Allow-Headers: Content-Type\r\n")
        output.print("Content-Length: ${body.toByteArray(Charsets.UTF_8).size}\r\n")
        output.print("\r\n") // Empty line to end headers
        output.print(body)
        output.flush()
    }

    private fun sendCorsResponse(output: PrintWriter) {
        output.print("HTTP/1.1 200 OK\r\n")
        output.print("Access-Control-Allow-Origin: *\r\n")
        output.print("Access-Control-Allow-Methods: POST, OPTIONS\r\n")
        output.print("Access-Control-Allow-Headers: Content-Type\r\n")
        output.println("Content-Length: 0")
        output.print("\r\n") // Empty line to end headers
        output.flush()
    }
}
