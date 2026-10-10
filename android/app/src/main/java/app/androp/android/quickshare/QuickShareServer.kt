package app.androp.android.quickshare

import android.content.Context
import android.util.Log
import java.net.ServerSocket
import java.util.concurrent.Executors

/**
 * A TCP server that listens for incoming Quick Share connections.
 */
class QuickShareServer(
    private val context: Context,
    private val onNewConnection: (InboundQuickShareConnection) -> Unit
) {
    companion object {
        private const val TAG = "QuickShareServer"
    }

    private var serverSocket: ServerSocket? = null
    private var executor = Executors.newSingleThreadExecutor()
    @Volatile
    private var isRunning = false

    val port: Int
        get() = serverSocket?.localPort ?: -1

    @Synchronized
    fun start() {
        if (isRunning) return
        isRunning = true
        if (executor.isShutdown) executor = Executors.newSingleThreadExecutor()

        try {
            val listener = ServerSocket(0) // Bind to any available port synchronously
            serverSocket = listener
            val currentPort = port
            Log.d(TAG, "Server bound to port $currentPort")

            executor.execute {
                try {
                    while (isRunning) {
                        val socket = listener.accept()
                        if (!isRunning || serverSocket !== listener) { socket.close(); break }
                        Log.d(TAG, "New connection from ${socket.remoteSocketAddress}")

                        socket.tcpNoDelay = true
                        socket.soTimeout = 60_000
                        val connection = InboundQuickShareConnection(
                            context = context,
                            socket = socket
                        )
                        onNewConnection(connection)
                        connection.start()
                    }
                } catch (e: Exception) {
                    if (isRunning) {
                        Log.e(TAG, "Server accept error", e)
                    }
                } finally {
                    synchronized(this@QuickShareServer) {
                        if (serverSocket === listener) stop()
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start server", e)
            isRunning = false
        }
    }

    @Synchronized
    fun stop() {
        isRunning = false
        try {
            serverSocket?.close()
        } catch (e: Exception) {
            // Ignore
        }
        serverSocket = null
        executor.shutdownNow()
    }
}
