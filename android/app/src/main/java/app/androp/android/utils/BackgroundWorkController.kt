package app.androp.android.utils

import android.content.Context
import android.content.Intent
import app.androp.android.AdbDiscoveryHolder
import app.androp.android.quickshare.QuickShareService
import app.androp.android.service.AirSyncService
import app.androp.android.service.OutboundQuickShareService
import app.androp.android.service.WakeupService

/** The application observes persisted pause state so every entry point shares one shutdown path. */
object BackgroundWorkController {
    @Volatile
    var isPaused: Boolean = false
        private set

    fun pause(context: Context) {
        if (!isPaused) WebSocketUtil.sendMessage("{\"type\":\"userDisconnected\",\"data\":{}}")
        isPaused = true
        FindPhoneManager.stop()
        SyncDashboardController.setPaused(true)
        WebSocketFileTransfer.cancelAll()
        WebSocketUtil.disconnect(context, manual = true)
        SyncManager.stopPeriodicSync()
        ClipboardSyncManager.stopSync(context)
        app.androp.android.service.CallStateListener.stopSync()
        HapticUtil.stopLoadingHaptics()
        MacDeviceStatusManager.cleanup(context)
        app.androp.android.utils.discovery.DiscoveryOrchestrator.stop(context)
        AdbDiscoveryHolder.stop()
        WakeupService.stopService(context)
        AirSyncService.stop(context)
        context.stopService(Intent(context, QuickShareService::class.java))
        context.stopService(Intent(context, OutboundQuickShareService::class.java))
    }

    fun resume() {
        isPaused = false
        SyncDashboardController.setPaused(false)
        app.androp.android.service.MediaNotificationListener.refreshMonitoring()
    }
}
