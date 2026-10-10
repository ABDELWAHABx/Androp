# Instant hotspot and the macOS Wi-Fi menu

Research requested for a Samsung S21 FE / One UI 8 and MacBook Air M1 / macOS 15. Primary sources were checked on 10 October 2026. This describes feasibility; it does not claim automatic Wi-Fi joining is implemented in Preview 3.

## Native Wi-Fi menu

Apple's documented [Instant Hotspot](https://support.apple.com/en-gb/109321) uses a nearby iPhone or iPad, Bluetooth/Wi-Fi, and the same Apple Account or configured Family Sharing. The Mac can select that Apple device in its native Wi-Fi menu while its hotspot is inactive. Samsung/Android is outside that documented provider flow.

The public [CoreWLAN framework](https://developer.apple.com/documentation/CoreWLAN) exposes scanning, network information and association. No documented public integration was found for inserting a synthetic dormant-phone item in the system Wi-Fi menu or intercepting that menu's selection. Private menu hooks or attempts to impersonate Apple's Continuity protocol would not be a dependable supported feature.

Once the phone actually broadcasts its hotspot, it can appear as an ordinary network in the Mac Wi-Fi menu. Preview 3 can request activation from androp, subject to Android's restrictions; the user can then select the real network normally.

## Supported alternative

A future **Connect to phone hotspot** action in androp's own menu bar could:

1. Send the existing authenticated BLE activation request.
2. Wait for the phone's confirmed tethered-interface state, with cancellation and a finite timeout.
3. Scan for the configured SSID and use public CoreWLAN association to join it.
4. Report the association result separately from internet availability.

[CWInterface association](https://developer.apple.com/documentation/corewlan/cwinterface/associate%28to%3Apassword%3A%29) uses the network's credentials and can be subject to system authorization. [Apple DTS guidance](https://developer.apple.com/forums/thread/748161) explains that modern macOS Wi-Fi scans need Location Services authorization for useful network information. The app should request that normal permission and store an explicitly supplied hotspot password in Keychain, never logs or plain preferences. Association changes the active Mac network, so it should follow an explicit Connect action. Keep BLE available while the IP connection changes.

Android ordinarily cannot reveal the user's existing hotspot password to androp. [TetheringInterface.getSoftApConfiguration](https://developer.android.com/reference/android/net/TetheringInterface#getSoftApConfiguration()) limits configuration visibility to the UID that specified it or an app with privileged NETWORK_SETTINGS permission. Android 16's [WifiServiceImpl.getSoftApConfiguration](https://android.googlesource.com/platform/packages/modules/Wifi/+/refs/heads/android16-release/service/java/com/android/server/wifi/WifiServiceImpl.java) similarly guards persistent configuration. Public getters on SoftApConfiguration do not grant permission to obtain that configuration. Plan for one-time user entry/confirmation of the SSID and password.

Samsung/carrier denial of native hotspot control and the lack of an ordinary permission to disable global Data Saver remain unchanged. See [RELIABILITY_REVIEW.md](RELIABILITY_REVIEW.md). No ADB, wireless-debugging or root setup is proposed for this flow.

## Current implementation boundary

Preview 3 provides Enable, Disable, Refresh and Setup on phone in androp's Mac UI, with corresponding Android permission/settings actions. It does not insert native Wi-Fi menu items, retrieve the Samsung hotspot password, or automatically associate the Mac with the hotspot.
