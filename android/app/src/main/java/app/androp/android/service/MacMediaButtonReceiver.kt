package app.androp.android.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Delivers native/headset media keys only to an existing remote session; never wakes idle media. */
class MacMediaButtonReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_MEDIA_BUTTON) MacMediaPlayerService.dispatchMediaButton(intent)
    }
}
