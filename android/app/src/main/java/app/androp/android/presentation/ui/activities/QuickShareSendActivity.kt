package app.androp.android.presentation.ui.activities

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Parcelable
import android.provider.OpenableColumns
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.ExperimentalAnimationApi
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Error
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.TextButton
import androidx.compose.material3.Icon
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import app.androp.android.R
import app.androp.android.presentation.viewmodel.AirSyncViewModel
import app.androp.android.service.OutboundQuickShareService
import app.androp.android.ui.theme.AirSyncTheme
import app.androp.android.utils.YouTubeHandoff
import app.androp.android.utils.ClipboardSyncManager
import app.androp.android.utils.ShortcutUtil
import app.androp.android.utils.StoragePathResolver
import app.androp.android.utils.OutgoingShareCache
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

class QuickShareSendActivity : ComponentActivity() {

    private val _windowFocus = mutableStateOf(false)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.auto(Color.TRANSPARENT, Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.auto(Color.TRANSPARENT, Color.TRANSPARENT)
        )
        window.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))

        val uris = extractUris(intent)
        val sharedText = if (uris.isEmpty()) intent?.getStringExtra(Intent.EXTRA_TEXT) else null

        setContent {
            val viewModel: AirSyncViewModel = viewModel { AirSyncViewModel.create(this@QuickShareSendActivity) }
            val uiState by viewModel.uiState.collectAsState()

            AirSyncTheme(pitchBlackTheme = uiState.isPitchBlackThemeEnabled) {
                QuickShareSendScreen(
                    hasWindowFocus = _windowFocus.value,
                    uris = uris,
                    sharedText = sharedText,
                    pairedDeviceName = uiState.lastConnectedDevice?.name,
                    onFinished = { finish() }
                )
            }
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        _windowFocus.value = hasFocus
    }

    private fun extractUris(intent: Intent?): List<Uri> {
        if (intent == null) return emptyList()
        if (intent.action != Intent.ACTION_SEND && intent.action != Intent.ACTION_SEND_MULTIPLE) return emptyList()
        val streams = runCatching {
            if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
                val list: ArrayList<out Parcelable>? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
                }
                list?.filterIsInstance<Uri>().orEmpty()
            } else {
                val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                }
                listOfNotNull(uri)
            }
        }.getOrDefault(emptyList())
        // Samsung Gallery and other providers may carry the selection only in ClipData.
        val clipUris = intent.clipData?.let { clip ->
            (0 until clip.itemCount).mapNotNull { clip.getItemAt(it).uri }
        }.orEmpty()
        return (streams + clipUris).distinct().filter { it.scheme == "content" }

    }
}

@OptIn(ExperimentalAnimationApi::class, ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun QuickShareSendScreen(
    hasWindowFocus: Boolean,
    uris: List<Uri>,
    sharedText: String?,
    pairedDeviceName: String?,
    onFinished: () -> Unit
) {
    val context = LocalContext.current
    var uiState by remember { mutableStateOf<SendUiState>(SendUiState.Loading) }
    val currentWindowFocus by rememberUpdatedState(hasWindowFocus)
    var showVideoChoice by remember { mutableStateOf(false) }
    val textScope = rememberCoroutineScope()
    val videoURL = remember(sharedText) { sharedText?.let(YouTubeHandoff::extract) }
    suspend fun sendText(handoff: Boolean) {
        uiState = SendUiState.Loading
        val delivered = ClipboardSyncManager.sendAndAwait(sharedText.orEmpty(), videoHandoff = handoff)
        if (delivered) {
            reportSummonShortcutUsed(context)
            uiState = SendUiState.Success
            delay(1200)
            onFinished()
        } else uiState = SendUiState.Error("Delivery not confirmed. Check the connection and retry.")
    }

    LaunchedEffect(Unit) {
        snapshotFlow { currentWindowFocus }.first { it }
        run {
            delay(100)
            val knownPairedName = withContext(Dispatchers.IO) {
                app.androp.android.data.local.DataStoreManager.getInstance(context).getLastConnectedDevice().first()?.name
            }

            if (uris.isEmpty() && sharedText.isNullOrBlank()) {
                uiState = SendUiState.Error("Nothing to send")
                delay(1500)
                onFinished()
            } else if (knownPairedName.isNullOrBlank()) {
                uiState = SendUiState.Error("No Mac paired")
                delay(1500)
                onFinished()
            } else if (uris.isEmpty()) {
                if (videoURL != null) showVideoChoice = true else sendText(false)
            } else {
                var staged: List<File> = emptyList()
                var handedToService = false
                try {
                    check(!OutboundQuickShareService.isSending) { "A file transfer is already running. Try again when it finishes." }
                    withContext(Dispatchers.IO) { staged = copyUrisToCache(context, uris) }
                    handedToService = OutboundQuickShareService.start(context, staged.map(Uri::fromFile))
                    check(handedToService) { "Couldn't start sending. Wait for the current transfer, then try again." }
                    reportSummonShortcutUsed(context)
                    uiState = SendUiState.Success
                    delay(1200)
                    onFinished()
                } catch (e: Exception) {
                    if (e is kotlinx.coroutines.CancellationException) throw e
                    Log.w("QuickShareSendActivity", "Couldn't prepare shared files", e)
                    uiState = SendUiState.Error(e.message ?: "Couldn't read the selected files")
                } finally {
                    if (!handedToService) withContext(kotlinx.coroutines.NonCancellable + Dispatchers.IO) {
                        staged.forEach { runCatching { it.delete() } }
                    }
                }
            }
        }
    }

    if (showVideoChoice) {
        AlertDialog(
            onDismissRequest = onFinished,
            title = { Text("Continue watching on Mac") },
            text = { Text("Open this YouTube video on your Mac, or copy the shared text.") },
            confirmButton = { TextButton(onClick = {
                showVideoChoice = false
                textScope.launch { sendText(true) }
            }) { Text("Open video on Mac") } },
            dismissButton = { TextButton(onClick = {
                showVideoChoice = false
                textScope.launch { sendText(false) }
            }) { Text("Copy text to Mac") } }
        )
    } else if (uiState is SendUiState.Error && uris.isEmpty() && !sharedText.isNullOrBlank()) {
        AlertDialog(
            onDismissRequest = onFinished,
            title = { Text("Clipboard not delivered") },
            text = { Text((uiState as SendUiState.Error).message) },
            confirmButton = { TextButton(onClick = {
                if (videoURL != null) showVideoChoice = true else textScope.launch { sendText(false) }
            }) { Text("Retry") } },
            dismissButton = { TextButton(onClick = onFinished) { Text("Close") } }
        )
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .clickable(onClick = onFinished),
        contentAlignment = Alignment.BottomCenter
    ) {
        Surface(
            modifier = Modifier
                .navigationBarsPadding()
                .padding(bottom = 64.dp)
                .padding(horizontal = 24.dp),
            shape = RoundedCornerShape(percent = 50),
            color = MaterialTheme.colorScheme.surfaceContainerHigh,
            tonalElevation = 8.dp,
            shadowElevation = 12.dp
        ) {
            Row(
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(12.dp)
            ) {
                Icon(
                    painter = painterResource(id = R.drawable.ic_laptop_24),
                    contentDescription = null,
                    modifier = Modifier.size(24.dp),
                    tint = MaterialTheme.colorScheme.primary
                )

                val label = when (uiState) {
                    is SendUiState.Loading -> "Sending to ${pairedDeviceName ?: stringResource(R.string.your_mac)}..."
                    is SendUiState.Success -> if (uris.isEmpty()) "Delivered to ${pairedDeviceName ?: stringResource(R.string.your_mac)}" else "File transfer started"
                    is SendUiState.Error -> (uiState as SendUiState.Error).message
                }
                Text(
                    text = label,
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurface
                )

                AnimatedContent(
                    targetState = uiState,
                    transitionSpec = { fadeIn().togetherWith(fadeOut()) },
                    label = "StatusAnimation"
                ) { state ->
                    Box(modifier = Modifier.size(28.dp), contentAlignment = Alignment.Center) {
                        when (state) {
                            is SendUiState.Loading -> LoadingIndicator(
                                modifier = Modifier.size(24.dp),
                                color = MaterialTheme.colorScheme.primary
                            )

                            is SendUiState.Success -> Icon(
                                imageVector = Icons.Rounded.CheckCircle,
                                contentDescription = "Success",
                                modifier = Modifier.size(28.dp),
                                tint = MaterialTheme.colorScheme.primary
                            )

                            is SendUiState.Error -> Icon(
                                imageVector = Icons.Rounded.Error,
                                contentDescription = "Error",
                                tint = MaterialTheme.colorScheme.error,
                                modifier = Modifier.size(28.dp)
                            )
                        }
                    }
                }
            }
        }
    }
}

sealed class SendUiState {
    data object Loading : SendUiState()
    data object Success : SendUiState()
    data class Error(val message: String) : SendUiState()
}

private fun reportSummonShortcutUsed(context: Context) {
    try {
        ShortcutUtil.reportShareMacShortcutUsed(context)
    } catch (_: Exception) {

    }
}

private suspend fun copyUrisToCache(context: Context, uris: List<Uri>): List<File> {
    val coroutine = currentCoroutineContext()
    val sources = uris.map { uri ->
        coroutine.ensureActive()
        val fallback = "file_${java.util.UUID.randomUUID()}"
        var name = if (uri.scheme == "file") uri.lastPathSegment ?: fallback else fallback
        if (uri.scheme == "content") {
            context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (cursor.moveToFirst() && index >= 0) name = cursor.getString(index) ?: fallback
            }
        }
        OutgoingShareCache.Source(name) {
            requireNotNull(context.contentResolver.openInputStream(uri)) { "Couldn't read $name" }
        }
    }
    return OutgoingShareCache.stage(File(context.cacheDir, "quickshare_outgoing"), sources,
        checkActive = { coroutine.ensureActive() })
}

@Preview(name = "Loading", showBackground = true)
@Composable
private fun QuickShareSendScreenPreviewLoading() {
    AirSyncTheme {
        QuickShareSendScreen(
            hasWindowFocus = true,
            uris = emptyList(),
            sharedText = null,
            pairedDeviceName = "Sameera's Mac",
            onFinished = {}
        )
    }
}
