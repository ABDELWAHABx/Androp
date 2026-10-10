package app.androp.android.presentation.ui.components.cards

import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.platform.LocalContext
import app.androp.android.R
import app.androp.android.data.ble.BleGattServer
import app.androp.android.data.local.DataStoreManager
import kotlinx.coroutines.launch

@Composable
fun BleSyncCard(viewModel: app.androp.android.presentation.viewmodel.AirSyncViewModel) {
    val context = LocalContext.current
    val dataStoreManager = remember { DataStoreManager.getInstance(context) }
    val scope = rememberCoroutineScope()

    val bleEnabled by dataStoreManager.getBleSyncEnabled().collectAsState(initial = false)

    val uiState by viewModel.uiState.collectAsState()
    val bleState = uiState.bleConnectionState

    val statusText = when (bleState) {
        BleGattServer.BleConnectionState.DISCONNECTED -> "Keep available nearby, including while Wi-Fi is connected"
        BleGattServer.BleConnectionState.ADVERTISING -> "Available for your paired Mac nearby"
        BleGattServer.BleConnectionState.CONNECTED -> "Authenticating"
        BleGattServer.BleConnectionState.AUTHENTICATED -> "Connected"
    }

    IconToggleItem(
        iconRes = R.drawable.rounded_bluetooth_24,
        title = "Bluetooth LE Sync",
        description = statusText,
        isChecked = bleEnabled,
        onCheckedChange = {
            scope.launch { dataStoreManager.setBleSyncEnabled(it) }
        }
    )

    // Advertising availability is governed by the main Bluetooth switch.
    // The previous auto-connect preference was never read by the peripheral.
}
