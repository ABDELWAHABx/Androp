package app.androp.android.utils

import android.content.Context
import android.content.Intent
import android.util.Log
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
        // Repeated persisted-state emissions may retry failed platform cleanup safely.
        if (!isPaused) runCatching { WebSocketUtil.sendMessage("{\"type\":\"userDisconnected\",\"data\":{}}") }
        isPaused = true
        val application = context.applicationContext
        runShutdownSteps(listOf(
            "temporary transfer Wi-Fi" to { TransferNetworkManager.cancelAll() },
            "Bluetooth" to { app.androp.android.AirSyncApp.getBleConnectionManager()?.refreshAvailability(); Unit },
            "phone alert" to { FindPhoneManager.stop() },
            "hotspot status" to { HotspotControlManager.stopObserving() },
            "dashboard" to { SyncDashboardController.setPaused(true) },
            "file transfers" to { WebSocketFileTransfer.cancelAll() },
            "connection" to { WebSocketUtil.disconnect(application, manual = true) },
            "periodic sync" to { SyncManager.stopPeriodicSync() },
            "clipboard" to { ClipboardSyncManager.stopSync(application) },
            "call observer" to { app.androp.android.service.CallStateListener.stopSync() },
            "haptics" to { HapticUtil.stopLoadingHaptics() },
            "Mac status" to { MacDeviceStatusManager.cleanup(application) },
            "discovery" to { app.androp.android.utils.discovery.DiscoveryOrchestrator.stop(application) },
            "ADB discovery" to { AdbDiscoveryHolder.stop() },
            "wake-up service" to { WakeupService.stopService(application) },
            "sync service" to { AirSyncService.stop(application) },
            "Nearby receive" to { application.stopService(Intent(application, QuickShareService::class.java)); Unit },
            "Nearby send" to { application.stopService(Intent(application, OutboundQuickShareService::class.java)); Unit }
        )) { name, error -> Log.w("BackgroundWork", "Pause cleanup failed for $name", error) }
    }

    fun resume() {
        isPaused = false
        // Preference collectors can observe Resume before this runtime flag. An
        // event-driven recheck closes that ordering gap without polling.
        app.androp.android.AirSyncApp.getBleConnectionManager()?.refreshAvailability()
        SyncDashboardController.setPaused(false)
        app.androp.android.service.MediaNotificationListener.refreshMonitoring()
    }
}
