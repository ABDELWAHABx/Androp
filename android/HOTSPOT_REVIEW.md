# Phone hotspot control

The paired Mac can request real internet tethering over either encrypted Wi-Fi or authenticated BLE. Android 16 exposes the public `TetheringManager` API. androp checks Modify system settings access before attempting it, and reports the operating system's outcome. This permission does **not** guarantee support: current AOSP blocks ordinary apps when its newer tethering configuration flag is enabled, and carrier provisioning can also reject requests. Samsung One UI 8 behavior still requires testing on the user's phone.

## Permission-only setup

On Android, Settings → Connection → Hotspot contains the system's Modify system settings permission page and direct Hotspot/Data Saver settings buttons. The Mac's Set up on phone action places a user-tapped settings action inside androp's existing quiet dashboard notification. Remote requests never launch background activities.

Android provides no ordinary permission for an app to toggle global Data Saver. When enabled (including when androp itself is exempt), a start request is blocked with a Data Saver action in the existing dashboard. The user must switch it off there and retry. androp does not silently change or restore Data Saver. No ADB, wireless debugging, root, system daemon, hidden-API policy changes, or local-only Wi-Fi hotspot is used.

## Protocol and lifecycle

- Incoming `phoneHotspotControl`: `data.id` (nonempty, at most 128 characters), `data.action`: `status`, `enable`, `disable`, or `setup`.
- Outgoing `phoneHotspotState`: same ID/action, `status`, `message`, `apiSupported`, `writeSettingsGranted`, `dataSaverEnabled` (nullable), `hotspotEnabled` (nullable), `canAttemptControl`, optional numeric `errorCode`.
- Status values: `ready`, `requesting`, `enabled`, `disabled`, `permissionRequired`, `dataSaverEnabled`, `unsupported`, `failed`, `unknown`, `busy`.
- `canAttemptControl` means API version and special access prerequisites are met; firmware may still refuse the attempt.
- Real Wi-Fi tethered-interface callbacks confirm state. A successful submission alone never becomes an enabled/disabled response. Internet availability still depends on upstream cellular service and the carrier.
- Observation is on demand, expires after 20 seconds, and unregisters on completion or Pause. No ongoing polling or wake lock. Pause does not turn off a hotspot the user explicitly enabled.
- Duplicate in-flight requests do not start another operation; the last 16 completed responses are replayed for up to 60 seconds.
- Android may only stop a hotspot created by the requesting UID. Unknown-request failures clearly direct the user to phone Hotspot settings.
- Three dashboard regressions verify one-notification setup, incoming-file priority, immediate action publication without repeated idle updates, and prompt removal on Pause.

## Sources reviewed

- Public API: https://developer.android.com/reference/android/net/TetheringManager
- Android 16 service permission checks (`checkTetherChangePermission`, newer-feature restriction): https://android.googlesource.com/platform/packages/modules/Connectivity/+/refs/tags/android-16.0.0_r1/Tethering/src/com/android/networkstack/tethering/TetheringService.java
- Tethering API and callbacks: https://android.googlesource.com/platform/packages/modules/Connectivity/+/refs/tags/android-16.0.0_r1/Tethering/common/TetheringLib/src/android/net/TetheringManager.java
- Global Data Saver app-visible status: https://developer.android.com/reference/android/net/ConnectivityManager#getRestrictBackgroundStatus()

Local API signatures were checked against the installed Android SDK. Physical Samsung hotspot permission acceptance, cellular routing, and BLE-only operation are not yet verified.
