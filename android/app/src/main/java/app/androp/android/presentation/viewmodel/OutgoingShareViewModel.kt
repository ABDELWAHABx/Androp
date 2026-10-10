package app.androp.android.presentation.viewmodel

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.androp.android.data.local.DataStoreManager
import app.androp.android.service.OutboundQuickShareService
import app.androp.android.utils.BackgroundWorkController
import app.androp.android.utils.OutgoingShareCache
import app.androp.android.utils.OutgoingShareGate
import app.androp.android.utils.TransferNetworkManager
import app.androp.android.utils.WebSocketUtil
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.io.File
import java.util.UUID

/** Keeps a staged share across rotation, permission prompts and recoverable network failures. */
internal class OutgoingShareViewModel(private val context: Context) : ViewModel() {
    sealed interface State {
        data class Progress(val message: String) : State
        data object Permission : State
        data object Started : State
        data class Error(val message: String) : State
    }
    private val mutableState = MutableStateFlow<State>(State.Progress("Preparing files…"))
    val state = mutableState.asStateFlow()
    private val dataStore = DataStoreManager.getInstance(context)
    private var initialized = false
    private var closed = false
    private var handedOff = false
    private var permissionInFlight = false
    private var selection: List<Uri> = emptyList()
    private var staged: List<File> = emptyList()
    private var pairedKey: String? = null
    private var gate: OutgoingShareGate? = null
    private var task: Job? = null
    private var lease: String? = null

    fun begin(uris: List<Uri>) {
        if (initialized) return
        initialized = true
        selection = uris
        retry()
    }

    fun beginPermissionRequest(): Boolean {
        if (permissionInFlight || closed || mutableState.value != State.Permission) return false
        permissionInFlight = true
        return true
    }

    fun permissionResult(granted: Boolean) {
        permissionInFlight = false
        if (closed || handedOff) return
        if (granted) retry()
        else {
            val permission = if (android.os.Build.VERSION.SDK_INT >= 33) "Nearby Wi-Fi" else "Precise Location"
            mutableState.value = State.Error("$permission permission is needed to create a transfer connection. Your files are still selected. Allow it and retry, or connect both devices to the same Wi-Fi.")
        }
    }

    fun retry() {
        if (closed || handedOff || task?.isCompleted == false) return
        task = viewModelScope.launch {
            var intentObserver: Job? = null
            try {
                check(!OutboundQuickShareService.isSending) { "A file transfer is already running. Retry when it finishes." }
                val saved = dataStore.getLastConnectedDevice().first()
                if (pairedKey == null) pairedKey = saved?.symmetricKey
                val expected = requireNotNull(pairedKey?.takeIf { it.isNotBlank() }) { "Pair your Mac before sending files." }
                val attempt = OutgoingShareGate(expected)
                gate = attempt
                checkAllowed(attempt, expected)
                val owner = currentCoroutineContext()[Job]!!
                intentObserver = launch {
                    combine(dataStore.getLastConnectedDevice(), dataStore.isAppPaused(),
                        dataStore.getUserManuallyDisconnected()) { device, paused, disconnected ->
                        device?.symmetricKey != expected || paused || disconnected
                    }.first { it }
                    attempt.cancel()
                    mutableState.value = State.Error("Connection cancelled or paired Mac changed. Your files won't send until you retry.")
                    owner.cancel()
                }
                if (staged.isEmpty()) {
                    mutableState.value = State.Progress("Preparing files…")
                    withContext(Dispatchers.IO) { staged = stageFiles(selection) }
                }
                ensureActive()
                checkAllowed(attempt, expected)
                if (WebSocketUtil.authenticatedPeerAddress(expected) == null) {
                    if (!TransferNetworkManager.hasPermission(context)) {
                        mutableState.value = State.Permission
                        return@launch
                    }
                    mutableState.value = State.Progress("Connecting to your Mac over Wi-Fi…")
                    val id = UUID.randomUUID().toString()
                    lease = id
                    check(TransferNetworkManager.requestMacNetwork(context, id, expected)) {
                        "Couldn't ask your Mac to connect. Keep Bluetooth on and retry, or connect both devices to the same Wi-Fi."
                    }
                    coroutineScope {
                        val heartbeat = launch {
                            while (isActive) { delay(25_000); TransferNetworkManager.keepAlive(id) }
                        }
                        try {
                            withTimeout(90_000) {
                                combine(dataStore.getLastConnectedDevice(), dataStore.isAppPaused(),
                                    dataStore.getUserManuallyDisconnected(), WebSocketUtil.connectionState,
                                    TransferNetworkManager.state) { device, paused, disconnected, _, network ->
                                    val decision = attempt.evaluate(device?.symmetricKey,
                                        paused || BackgroundWorkController.isPaused, disconnected,
                                        WebSocketUtil.authenticatedPeerAddress(expected),
                                        setupConfirmed = network.phase == TransferNetworkManager.Phase.CONNECTED)
                                    check(decision != OutgoingShareGate.Decision.STOP) {
                                        "Connection cancelled or paired Mac changed. Resume and retry when ready."
                                    }
                                    check(network.id == id) { "Connection preparation stopped. Your files are still selected; retry when ready." }
                                    check(network.phase != TransferNetworkManager.Phase.ERROR) {
                                        network.message ?: "Couldn't create the Wi-Fi connection. Your files are still selected."
                                    }
                                    decision == OutgoingShareGate.Decision.READY
                                }.first { it }
                            }
                        } finally { heartbeat.cancel() }
                    }
                }
                ensureActive()
                val current = dataStore.getLastConnectedDevice().first()
                val paused = dataStore.isAppPaused().first() || BackgroundWorkController.isPaused
                val disconnected = dataStore.getUserManuallyDisconnected().first()
                check(attempt.claim(current?.symmetricKey, paused, disconnected,
                    WebSocketUtil.authenticatedPeerAddress(expected), setupConfirmed = lease?.let { id ->
                        TransferNetworkManager.state.value.let { it.id == id && it.phase == TransferNetworkManager.Phase.CONNECTED }
                    } ?: true)) { "Connection changed before sending. Retry when ready." }
                mutableState.value = State.Progress("Sending files to your Mac…")
                handedOff = OutboundQuickShareService.start(context, staged.map(Uri::fromFile), expected, lease)
                check(handedOff) { "Couldn't start the transfer. Your files are still selected; retry when ready." }
                lease = null // Service now owns the temporary network and staged files.
                staged = emptyList()
                mutableState.value = State.Started
            } catch (_: TimeoutCancellationException) {
                mutableState.value = State.Error("Your Mac didn't finish connecting. Your files are still selected. Keep both devices nearby and retry, or join the same Wi-Fi.")
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                mutableState.value = State.Error(error.message ?: "Couldn't send these files. Your selection is kept for retry.")
            } finally {
                intentObserver?.cancel()
                lease?.let(TransferNetworkManager::stop)
                lease = null
                if (closed && !handedOff) deleteStaged()
            }
        }
    }

    private suspend fun checkAllowed(attempt: OutgoingShareGate, expected: String) {
        check(attempt.evaluate(dataStore.getLastConnectedDevice().first()?.symmetricKey,
            BackgroundWorkController.isPaused || dataStore.isAppPaused().first(),
            dataStore.getUserManuallyDisconnected().first(), WebSocketUtil.authenticatedPeerAddress(expected)) != OutgoingShareGate.Decision.STOP) {
            "Sync is paused, disconnected, or the paired Mac changed. Resume and retry when ready."
        }
    }

    private suspend fun stageFiles(uris: List<Uri>): List<File> {
        val coroutine = currentCoroutineContext()
        val sources = uris.map { uri ->
            coroutine.ensureActive()
            var name = "file_${UUID.randomUUID()}"
            context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (cursor.moveToFirst() && index >= 0) name = cursor.getString(index) ?: name
            }
            OutgoingShareCache.Source(name) {
                requireNotNull(context.contentResolver.openInputStream(uri)) { "Couldn't read a selected file." }
            }
        }
        return OutgoingShareCache.stage(File(context.cacheDir, "quickshare_outgoing"), sources,
            checkActive = { coroutine.ensureActive() })
    }

    fun cancel() {
        closed = true
        gate?.cancel()
        task?.cancel()
        lease?.let(TransferNetworkManager::stop)
        lease = null
        if (task?.isActive != true && !handedOff) deleteStaged()
    }
    private fun deleteStaged() { staged.forEach { runCatching { it.delete() } }; staged = emptyList() }
    override fun onCleared() { cancel(); super.onCleared() }
}
