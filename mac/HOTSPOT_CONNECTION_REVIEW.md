# Automatic Mac hotspot joining

Preview 4 adds **Connect** to the Phone hotspot controls in both the main window and androp menu bar. The saved-password joining action also understands Preview 3 Android, but install both Preview 4 apps for persistent BLE alongside Wi-Fi and the latest connection recovery.

## Setup and behavior

1. Expand **Phone hotspot** and choose the phone's Wi-Fi name from **Saved networks**, or enter its exact name. androp remembers that selection for the connected device identity.
2. Click **Connect**. If necessary, macOS asks for Location access so CoreWLAN can find the Wi-Fi network.
3. androp requests fresh hotspot status over the existing authenticated connection. If the hotspot is off, it requests activation and waits for the phone's actual tethered-interface confirmation. If the phone acknowledges the activation request and then drops its old Wi-Fi connection, androp instead searches for the selected secure hotspot and confirms the Mac's actual association; merely sending a command never means connected.
4. The Mac scans for the selected WPA2/WPA3 network, obtains its existing password through Apple's Keychain API, and associates with it. macOS may ask to authorize Keychain access or the Wi-Fi change.

The SSID is stored in androp preferences; the password stays in the existing Mac Keychain. Only that selected network's password is requested. It is used in process memory for association, never logged, persisted by androp, passed to a shell/subprocess, or sent to Android. If the saved credential is missing or access is denied, the app explains how to join using the native Wi-Fi menu and save the password there. No extra password-entry form, ADB or wireless debugging is required.

Joining changes the active Mac Wi-Fi network. Bluetooth keeps the control path usable while the network changes. Association success is reported separately from cellular/internet availability.

## Bounds and cancellation

- One connection attempt at a time; no background auto-join polling or automatic network switching merely because the phone connects.
- Fresh phone status and an activation acknowledgement are required. An unacknowledged queued request, permission failure, cancelled request or mismatched response cannot initiate association. A link loss after a requesting acknowledgement can start the bounded hotspot scan, unless the user paused or explicitly disconnected.
- At most six Wi-Fi scans with short interruptible retry waits and a 30-second retry deadline; no new retries after cancellation. Location authorization waiting expires after 30 seconds. Phone requests retain their existing 30-second Mac / 20-second Android observation limits.
- CoreWLAN/Keychain operations are synchronous system APIs and run on a serial background queue, outside the main thread. A call already submitted to macOS cannot be safely retracted; cancelling or pausing prevents subsequent work and reports that an in-flight association may complete. androp does not disconnect a network the OS has already joined.
- Phone identity is checked before activation. Requests prefer an already-authenticated BLE peer and retain that binding across Wi-Fi loss; a different peer cannot complete them. Once association starts, ordinary control-session disconnection does not cancel it, because changing Wi-Fi can itself interrupt that session.
- SSIDs are validated by UTF-8 byte length, not character count. Open lookalikes with the same SSID are never used as a fallback. Keychain denial does not trigger another domain's authorization prompt.

Samsung/carrier restrictions on hotspot activation still apply. Android offers no ordinary app permission to disable global Data Saver; use the phone settings action when needed. These Mac changes cannot grant additional Android privileges.

## Native Wi-Fi menu boundary

Apple's documented [Instant Hotspot](https://support.apple.com/en-gb/109321) uses a nearby iPhone/iPad and an Apple Account or Family Sharing relationship. No documented public API was found for adding a dormant Android device to the native macOS Wi-Fi menu or intercepting its selection. androp therefore provides its own Connect action. The real phone network naturally appears in the native menu once it is broadcasting.

## Public APIs and verification

- [CWConfiguration.networkProfiles](https://developer.apple.com/documentation/corewlan/cwconfiguration/networkprofiles) lists remembered networks.
- [CWKeychainFindWiFiPassword](https://developer.apple.com/documentation/corewlan/cwkeychainfindwifipassword%28_%3A_%3A_%3A%29) reads the selected SSID's credential from the user domain, then the system domain only if the item was not found.
- [CWInterface association](https://developer.apple.com/documentation/corewlan/cwinterface/associate%28to%3Apassword%3A%29) joins the selected network.
- [Apple DTS guidance](https://developer.apple.com/forums/thread/748161) explains the Location Services authorization requirement for modern macOS scans.

Production-manager regressions cover confirmed on/off versus failed observations, queued-request rejection, duplicate confirmations, pause cancellation and reentrant activation. Policy regressions cover SSID byte limits, invalid clock/retry limits and cancellation waking a retry wait. Native builds and packaged-app lifecycle checks are recorded in the repository verification files. Actual Keychain authorization, Samsung activation, Wi-Fi association, and cellular routing still need testing on the user's Mac and phone.

## File-transfer handoff

Selecting or dropping files while on BLE now retains them in a review sheet with hotspot controls. After the same authenticated phone reconnects over Wi-Fi, Send becomes available. Device identity and pairing-token continuity are checked before sending and before every file in a batch. Files are never sent over BLE, and a nearby phone with a matching display name cannot inherit the selection.

This flow uses the existing phone hotspot or a shared Wi-Fi network. It does not automatically create a temporary transfer network. Android's public [local-only hotspot API](https://developer.android.com/develop/connectivity/wifi/localonlyhotspot) could support a future router-free, non-cellular transfer path using normal Nearby Wi-Fi permission. That requires authenticated temporary credential exchange, IP discovery and cleanup on both peers; the current Nearby protocol implementation does not negotiate that upgrade.
