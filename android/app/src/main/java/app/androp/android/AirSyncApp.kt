package app.androp.android

import android.app.Activity
import android.app.Application
import android.os.Bundle
import app.androp.android.utils.BackgroundWorkController
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import app.androp.android.data.local.DataStoreManager
import app.androp.android.crash.CrashNotificationHelper

class AirSyncApp : Application() {
    private val applicationScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var activityCount = 0
    private lateinit var bleConnectionManager: app.androp.android.data.ble.BleConnectionManager

    companion object {
        private var instance: AirSyncApp? = null
        fun getContext(): Application? = instance
        fun isAppForeground(): Boolean = instance?.isForeground() ?: false
        fun getBleConnectionManager(): app.androp.android.data.ble.BleConnectionManager? =
            instance?.bleConnectionManager
    }

    override fun onCreate() {
        super.onCreate()
        instance = this

        CrashNotificationHelper.createChannel(this)

        bleConnectionManager = app.androp.android.data.ble.BleConnectionManager(this)
        bleConnectionManager.start()
        app.androp.android.utils.SyncDashboardController.initialize(this)
        applicationScope.launch {
            DataStoreManager.getInstance(this@AirSyncApp).isAppPaused().collect { paused ->
                if (paused) BackgroundWorkController.pause(this@AirSyncApp)
                else BackgroundWorkController.resume()
            }
        }
        registerActivityLifecycleCallbacks(object : ActivityLifecycleCallbacks {
            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
            override fun onActivityStarted(activity: Activity) {
                activityCount++
                if (activityCount == 1 && !BackgroundWorkController.isPaused) {
                    app.androp.android.utils.MacDeviceStatusManager.refreshNativePlayer(this@AirSyncApp)
                }
            }

            override fun onActivityResumed(activity: Activity) {}
            override fun onActivityPaused(activity: Activity) {}
            override fun onActivityStopped(activity: Activity) {
                activityCount--
            }

            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
            override fun onActivityDestroyed(activity: Activity) {}
        })
    }

    private fun isForeground(): Boolean = activityCount > 0
}
