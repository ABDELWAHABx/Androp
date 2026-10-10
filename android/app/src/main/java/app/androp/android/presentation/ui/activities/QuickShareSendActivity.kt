package app.androp.android.presentation.ui.activities

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Parcelable
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import app.androp.android.presentation.viewmodel.OutgoingShareViewModel
import app.androp.android.utils.TransferNetworkManager
import app.androp.android.presentation.viewmodel.AirSyncViewModel
import app.androp.android.ui.theme.AirSyncTheme
import app.androp.android.utils.YouTubeHandoff
import app.androp.android.utils.ClipboardSyncManager
import app.androp.android.utils.ShortcutUtil
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

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
    val outgoing: OutgoingShareViewModel = viewModel { OutgoingShareViewModel(context.applicationContext) }
    val outgoingState by outgoing.state.collectAsState()
    val nearbyPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        // Approximate Location alone cannot start a local-only hotspot on API 30–32.
        outgoing.permissionResult(result[TransferNetworkManager.requiredPermission()] == true)
    }
    val closeShare = { outgoing.cancel(); onFinished() }
    LaunchedEffect(outgoingState) {
        if (uris.isNotEmpty()) when (val state = outgoingState) {
            is OutgoingShareViewModel.State.Progress -> uiState = SendUiState.Progress(state.message)
            is OutgoingShareViewModel.State.Permission -> {
                uiState = SendUiState.Progress(if (android.os.Build.VERSION.SDK_INT >= 33)
                    "Allow Nearby Wi-Fi to connect your Mac…" else "Allow Precise Location to prepare transfer Wi-Fi…")
                if (outgoing.beginPermissionRequest()) nearbyPermission.launch(TransferNetworkManager.requiredPermissions())
            }
            is OutgoingShareViewModel.State.Error -> uiState = SendUiState.Error(state.message)
            is OutgoingShareViewModel.State.Started -> {
                reportSummonShortcutUsed(context)
                uiState = SendUiState.Success
                delay(1200)
                onFinished()
            }
        }
    }
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
                outgoing.begin(uris)
            }
        }
    }

    if (uiState is SendUiState.Error && uris.isNotEmpty()) {
        AlertDialog(
            onDismissRequest = closeShare,
            title = { Text("Files not sent") },
            text = { Text((uiState as SendUiState.Error).message) },
            confirmButton = { TextButton(onClick = { outgoing.retry() }) { Text("Retry") } },
            dismissButton = { TextButton(onClick = closeShare) { Text("Cancel") } }
        )
    } else if (showVideoChoice) {
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
            .clickable(onClick = closeShare),
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
                    is SendUiState.Progress -> (uiState as SendUiState.Progress).message
                    is SendUiState.Loading -> "Sending to ${pairedDeviceName ?: stringResource(R.string.your_mac)}..."
                    is SendUiState.Success -> if (uris.isEmpty()) "Delivered to ${pairedDeviceName ?: stringResource(R.string.your_mac)}" else "File transfer started"
                    is SendUiState.Error -> if (uris.isNotEmpty()) "File transfer needs attention" else (uiState as SendUiState.Error).message
                }
                Text(
                    text = label,
                    modifier = Modifier.weight(1f, fill = false),
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurface
                )

                if (uris.isNotEmpty() && uiState !is SendUiState.Success) {
                    TextButton(onClick = closeShare) { Text("Cancel") }
                }

                AnimatedContent(
                    targetState = uiState,
                    transitionSpec = { fadeIn().togetherWith(fadeOut()) },
                    label = "StatusAnimation"
                ) { state ->
                    Box(modifier = Modifier.size(28.dp), contentAlignment = Alignment.Center) {
                        when (state) {
                            is SendUiState.Loading, is SendUiState.Progress -> LoadingIndicator(
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
    data class Progress(val message: String) : SendUiState()
    data object Success : SendUiState()
    data class Error(val message: String) : SendUiState()
}

private fun reportSummonShortcutUsed(context: Context) {
    try {
        ShortcutUtil.reportShareMacShortcutUsed(context)
    } catch (_: Exception) {

    }
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
