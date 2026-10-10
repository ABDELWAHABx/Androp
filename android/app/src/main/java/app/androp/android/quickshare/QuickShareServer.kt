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
                        // stop() must finish registering this accepted socket before it
                        // snapshots the service's connections for cancellation.
                        synchronized(this@QuickShareServer) {
                            if (!isRunning || serverSocket !== listener) {
                                socket.close()
                            } else {
                                var connection: InboundQuickShareConnection? = null
                                try {
                                    socket.tcpNoDelay = true
                                    socket.soTimeout = 60_000
                                    val accepted = InboundQuickShareConnection(context, socket)
                                    connection = accepted
                                    onNewConnection(accepted)
                                    accepted.start()
                                } catch (e: Exception) {
                                    if (connection != null) connection.closeConnection()
                                    else runCatching { socket.close() }
                                    throw e
                                }
                            }
                        }
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
            stop()
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
