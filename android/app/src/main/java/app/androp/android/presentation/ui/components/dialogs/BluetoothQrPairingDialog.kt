package app.androp.android.presentation.ui.components.dialogs

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Intent
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import app.androp.android.AirSyncApp
import app.androp.android.data.local.DataStoreManager
import app.androp.android.utils.PairingLink
import app.androp.android.utils.PermissionUtil
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull

/** The scanned key remains in composition memory until the authenticated manager commits it. */
@SuppressLint("MissingPermission") // Adapter access follows the normal runtime permission check below.
@Composable
fun BluetoothQrPairingDialog(
    pairing: PairingLink,
    paused: Boolean,
    onConnectingChanged: (Boolean) -> Unit,
    onConnected: () -> Unit,
    onDismiss: () -> Unit,
    onScanAgain: () -> Unit
) {
    val context = LocalContext.current
    val dataStore = remember(context) { DataStoreManager.getInstance(context.applicationContext) }
    var attempt by remember(pairing) { mutableIntStateOf(0) }
    var error by remember(pairing) { mutableStateOf<String?>(null) }
    var waiting by remember(pairing) { mutableStateOf(true) }
    val currentOnConnecting by rememberUpdatedState(onConnectingChanged)
    val currentOnConnected by rememberUpdatedState(onConnected)
    val permissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        if (PermissionUtil.isBluetoothPermissionsGranted(context)) {
            attempt++
        } else {
            waiting = false
            error = "Allow Nearby devices for androp to pair over Bluetooth. If Android no longer asks, enable it in Settings → Apps → androp → Permissions."
        }
    }
    val enableBluetooth = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        val enabled = try {
            context.getSystemService(BluetoothManager::class.java)?.adapter?.isEnabled == true
        } catch (_: SecurityException) { false }
        if (enabled) {
            attempt++
        } else {
            waiting = false
            error = "Turn on Bluetooth on your phone and Mac, then retry."
        }
    }

    DisposableEffect(pairing) {
        onDispose { currentOnConnecting(false) }
    }
    LaunchedEffect(pairing, attempt, paused) {
        waiting = true
        error = null
        if (paused || dataStore.isAppPaused().first()) {
            waiting = false
            currentOnConnecting(false)
            error = "Resume androp before pairing."
            return@LaunchedEffect
        }
        if (!PermissionUtil.isBluetoothPermissionsGranted(context)) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                permissions.launch(arrayOf(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_ADVERTISE))
            } else {
                waiting = false
                error = "Bluetooth permission is unavailable on this phone."
            }
            return@LaunchedEffect
        }
        val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter
        if (adapter == null) {
            waiting = false
            error = "This phone does not have a usable Bluetooth adapter."
            return@LaunchedEffect
        }
        val radioEnabled = try { adapter.isEnabled } catch (_: SecurityException) { false }
        if (!radioEnabled) {
            try {
                enableBluetooth.launch(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE))
            } catch (_: RuntimeException) {
                waiting = false
                error = "Turn on Bluetooth in your phone's settings, then retry."
            }
            return@LaunchedEffect
        }
        val manager = AirSyncApp.getBleConnectionManager()
        val key = pairing.key
        val session = pairing.pairingSessionId
        if (manager == null || key == null || session == null) {
            waiting = false
            error = "Pairing could not start. Open a new QR code on your Mac and scan it again."
            return@LaunchedEffect
        }
        currentOnConnecting(true)
        try {
            dataStore.setUserManuallyDisconnected(false)
            val connected = withTimeoutOrNull(125_000) {
                manager.pairFromQr(key, session, pairing.name ?: "My Mac")
            } == true
            waiting = false
            if (connected) {
                currentOnConnected()
            } else {
                error = "Your Mac did not complete Bluetooth pairing. Keep androp's QR code open, turn on Bluetooth on both devices, and stay nearby. If the code expired, scan a new one."
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            waiting = false
            error = "Bluetooth pairing could not finish. Check Bluetooth permissions on both devices and scan a new QR code."
        } finally {
            currentOnConnecting(false)
        }
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (waiting) "Pairing over Bluetooth" else "Bluetooth pairing") },
        text = {
            Column {
                Text(error ?: "Keep androp's QR code open on ${pairing.name ?: "your Mac"} and keep both devices nearby. Wi-Fi is not needed.")
                if (waiting) {
                    Spacer(Modifier.height(16.dp))
                    CircularProgressIndicator()
                }
            }
        },
        confirmButton = {
            if (!waiting && !paused) {
                TextButton(onClick = { attempt++ }) { Text("Retry") }
            }
        },
        dismissButton = {
            if (!waiting) {
                TextButton(onClick = onScanAgain) { Text("Scan again") }
            }
            TextButton(onClick = onDismiss) { Text(if (waiting) "Cancel" else "Close") }
        }
    )
}
