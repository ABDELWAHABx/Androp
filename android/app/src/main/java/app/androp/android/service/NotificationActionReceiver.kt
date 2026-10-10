package app.androp.android.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import app.androp.android.data.local.DataStoreManager
import app.androp.android.quickshare.QuickShareService
import app.androp.android.utils.BackgroundWorkController
import app.androp.android.utils.FindPhoneManager
import app.androp.android.utils.ShortcutUtil
import app.androp.android.utils.SyncDashboardController
import app.androp.android.utils.WebSocketFileTransfer
import app.androp.android.utils.WebSocketUtil
import app.androp.android.utils.discovery.DiscoveryOrchestrator
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/** Explicit, immutable dashboard actions; network work remains stopped while paused. */
class NotificationActionReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_CONTINUE_BROWSING_DISMISS = "app.androp.android.CONTINUE_BROWSING_DISMISS"
        const val ACTION_CANCEL_TRANSFER = "app.androp.android.CANCEL_TRANSFER"
        const val ACTION_PAUSE = "app.androp.android.DASHBOARD_PAUSE"
        const val ACTION_RESUME = "app.androp.android.DASHBOARD_RESUME"
        const val ACTION_STOP_PHONE_ALERT = "app.androp.android.DASHBOARD_STOP_PHONE_ALERT"
        const val ACTION_ACCEPT_SHARE = "app.androp.android.DASHBOARD_ACCEPT_SHARE"
        const val ACTION_REJECT_SHARE = "app.androp.android.DASHBOARD_REJECT_SHARE"
        const val ACTION_CLEAR_ACTIVITY = "app.androp.android.DASHBOARD_CLEAR_ACTIVITY"
        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    }

    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        val application = context.applicationContext
        scope.launch {
            try {
                val dataStore = DataStoreManager.getInstance(application)
                when (intent.action) {
                    ACTION_PAUSE -> {
                        BackgroundWorkController.pause(application)
                        dataStore.setAppPaused(true)
                        ShortcutUtil.refreshShortcuts(application, false)
                    }
                    ACTION_RESUME -> {
                        dataStore.setAppPaused(false)
                        dataStore.setUserManuallyDisconnected(false)
                        BackgroundWorkController.resume()
                        DiscoveryOrchestrator.start(application, dataStore.getDeviceDiscoveryEnabled().first())
                        AirSyncService.startScanning(application)
                        WebSocketUtil.requestAutoReconnect(application)
                        ShortcutUtil.refreshShortcuts(application, false)
                    }
                    ACTION_STOP_PHONE_ALERT -> FindPhoneManager.stop()
                    ACTION_ACCEPT_SHARE, ACTION_REJECT_SHARE -> {
                        if (!BackgroundWorkController.isPaused) intent.getStringExtra("connection_id")?.let {
                            QuickShareService.respondToShare(it, intent.action == ACTION_ACCEPT_SHARE)
                        }
                    }
                    ACTION_CONTINUE_BROWSING_DISMISS -> SyncDashboardController.clearLink()
                    ACTION_CLEAR_ACTIVITY -> SyncDashboardController.clearActivity()
                    AirSyncService.ACTION_DISCONNECT -> WebSocketUtil.disconnect(application, manual = true)
                    ACTION_CANCEL_TRANSFER -> intent.getStringExtra("transfer_id")?.takeIf { it.isNotBlank() }?.let { id ->
                        val sending = intent.getBooleanExtra("is_sending", false)
                        if (intent.getStringExtra("transfer_kind") == "ws") {
                            WebSocketFileTransfer.cancelTransfer(id)
                        } else if (sending) {
                            application.stopService(Intent(application, OutboundQuickShareService::class.java))
                        } else {
                            QuickShareService.cancelTransfer(id)
                        }
                        SyncDashboardController.cancelTransfer(id, sending)
                    }
                }
            } catch (e: Exception) {
                android.util.Log.w("DashboardActions", "Could not complete dashboard action", e)
            } finally { pending.finish() }
        }
    }
}
