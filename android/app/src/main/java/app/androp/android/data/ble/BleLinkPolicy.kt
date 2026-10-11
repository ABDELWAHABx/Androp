package app.androp.android.data.ble

import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseSettings

/**
 * Timing for keeping the Mac link up. Pure functions so the radio-free tests can pin them.
 * Must stay in step with BLELinkPolicy.swift.
 */
object BleLinkPolicy {
    /** Advertise faster right after start or a lost link, so the Mac finds the phone in seconds. */
    const val FAST_ADVERTISE_MS = 60_000L

    /**
     * The Mac pings every 20 s and itself reconnects after about 80 s of silence. App Nap can
     * stretch its timers, so the phone waits much longer before deciding the Mac is gone; this
     * only has to catch a link that died without either side being told.
     */
    const val PEER_SILENCE_LIMIT_MS = 240_000L
    const val PEER_WATCHDOG_INTERVAL_MS = 20_000L

    enum class AdvertiseSpeed { PAIRING, FAST, LOW_POWER }

    fun advertiseSpeed(nowMs: Long, fastUntilMs: Long, pairing: Boolean): AdvertiseSpeed = when {
        pairing -> AdvertiseSpeed.PAIRING
        nowMs < fastUntilMs -> AdvertiseSpeed.FAST
        else -> AdvertiseSpeed.LOW_POWER
    }

    fun advertiseMode(speed: AdvertiseSpeed): Int = when (speed) {
        AdvertiseSpeed.PAIRING -> AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY
        AdvertiseSpeed.FAST -> AdvertiseSettings.ADVERTISE_MODE_BALANCED
        AdvertiseSpeed.LOW_POWER -> AdvertiseSettings.ADVERTISE_MODE_LOW_POWER
    }

    /** Another app holding every advertiser slot, or a stack hiccup, is temporary. Unsupported hardware is not. */
    fun shouldRetryAdvertising(errorCode: Int): Boolean =
        errorCode != AdvertiseCallback.ADVERTISE_FAILED_FEATURE_UNSUPPORTED

    /** 2 s, 5 s, 15 s, 30 s, then once a minute for as long as the link should exist. */
    fun advertiseRetryDelayMs(failures: Int): Long = when {
        failures <= 1 -> 2_000L
        failures == 2 -> 5_000L
        failures == 3 -> 15_000L
        failures == 4 -> 30_000L
        else -> 60_000L
    }

    /** A few quick service-setup retries, then a slow one rather than giving up until the next radio event. */
    fun serviceSetupRetryDelayMs(retries: Int): Long = if (retries < 5) 2_000L else 60_000L

    /**
     * Only a Mac that has shown it sends heartbeats can be judged silent; an older Mac build
     * that never pings must not be disconnected every two minutes.
     */
    fun peerIsSilent(heartbeatSeen: Boolean, lastActivityMs: Long, nowMs: Long): Boolean =
        heartbeatSeen && nowMs - lastActivityMs > PEER_SILENCE_LIMIT_MS
}
