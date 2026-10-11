# androp

**Your Android phone and Mac, working together.**

androp is a personal continuation of [AirSync macOS](https://github.com/sameerasw/airsync-mac) and [AirSync Android](https://github.com/sameerasw/airsync-android), focused on dependable handoff, quieter background work, and controls that fit the way you use your devices. It has its own app identity and pairing namespace, so it can be installed alongside AirSync.

Control your Mac from your phone, send files into Android Downloads, share a video at its timestamp, and reach everyday actions from one notification dashboard. Pause stops the underlying work. An empty media session no longer takes over the screen.

[Public source](https://github.com/ABDELWAHABx/Androp) · [Private preview downloads](https://github.com/ABDELWAHABx/airsync-selfbuild/releases/tag/androp-v0.1.0-preview.6) · [Reliability review](mac/RELIABILITY_REVIEW.md) · [BLE coverage](mac/BLE_FEATURES.md) · [Crash review](mac/CRASH_REVIEW.md) · [Experience review](mac/EXPERIENCE_REVIEW.md) · [Power and performance review](mac/PERFORMANCE_REVIEW.md) · [Closed-lid experiment](mac/CLOSED_LID_REVIEW.md)

## What changed

Preview 6 adds Bluetooth-only first pairing and fixes QR, listener and reconnect failures. [Pairing and connection review](mac/CONNECTION_REVIEW.md). Install both updated apps.

| Area | androp behavior |
| --- | --- |
| Pause and power | Cancels sync, discovery, transfers, media and mirroring work. Resume remains available. Event-driven input, bounded queues and active-only monitoring replace unnecessary background work. |
| Phone battery alerts | Configurable low-battery threshold and optional sound, one alert per battery cycle. Paused, disconnected and unknown battery states do not trigger alerts. |
| Phone widget | Floating live connection, battery and media panel with Pause/Resume; native WidgetKit snapshots are bounded and refreshed on status changes. |
| Android dashboard | One quiet notification combines connection state, transfers, consent, clipboard links and Find Phone. Contextual actions open the right screen. Native media keeps its own player. |
| Samsung / Android 16 | Requests supported Live Updates for active work, with a normal notification fallback. Now Bar placement and visibility remain controlled by Android and Samsung settings. |
| Remote controls | Trackpad below the buttons in portrait, to their right in wide layouts. Empty media hides; paused media stays compact. Text keyboard and small controls also work over authenticated BLE. Continuous pointer input uses the paired network connection. |
| File transfers | Send uses authenticated Wi-Fi when available. From BLE, it prepares temporary Wi-Fi, connects the same paired devices, then starts sending. Progress, cancellation and setup retry retain your selection. Mac-to-phone sends verify SHA-256 and the final Android save. |
| Clipboard | Message acknowledgements, finite retries and duplicate handling distinguish waiting from delivered. Android clipboard reading follows foreground restrictions; explicit Share to androp remains available. |
| Media | Native Android MediaSession metadata, playback controls and remote volume control your Mac. Audio continues playing on the Mac; this does not stream its audio to the phone. |
| Bluetooth connection | Stays connected beside Wi-Fi. Radio/lifecycle recovery, low-power Android advertising and bounded Mac discovery backoff; Pause/manual disconnect stop reconnect work. |
| Phone hotspot | Connect enables the hotspot and joins its Wi-Fi using the password saved on your Mac. Select its saved network name once. Normal Android, Location and Keychain permissions apply; Samsung/carrier restrictions can block activation. Data Saver has a direct settings action. |
| Find Phone | A bounded alert can be started and stopped from Mac. It respects silent mode and Do Not Disturb; a visible alert remains available when sound is suppressed. |
| YouTube handoff | Share a supported YouTube URL to androp and choose **Open video on Mac**. Timestamp parameters survive the handoff; ordinary clipboard sync does not automatically open a browser. |
| Keep Mac awake | Opt-in prevention of idle sleep during transfers, recent remote input or playback. Phone controls show reported Mac state; **Sleep Mac** appears when the Mac reports a closed lid. |

These are implemented changes, not measured battery or throughput claims. Physical-device testing is still needed, especially on the reported Samsung S21 FE / One UI 8 and MacBook Air M1 / macOS 15 configuration.

## Download and install

The **private** [airsync-selfbuild preview release](https://github.com/ABDELWAHABx/airsync-selfbuild/releases/tag/androp-v0.1.0-preview.6) links to the verified installers on a dedicated private download branch. Sign in with an account that has access; public source access does not grant access to those downloads.

### Android

1. Download [androp-android.apk](https://github.com/ABDELWAHABx/airsync-selfbuild/raw/116f81bcbec4f09cee44f12b8ba4593abefd7695/preview6/androp-android.apk), the optimized, locally signed private preview.
2. On Android 11 or newer, open the APK and allow installation from that source if Android asks.
3. Open androp, then pair with the matching Mac app. Allow notifications if you want the dashboard in the notification shade.

Use the signed release APK for installation and updates. CI debug builds use a temporary signing identity and are used only for verification; the public workflow uploads reports, not APKs. This is a development preview, not a Play Store release.

### macOS

Download the Apple Silicon **[DMG](https://github.com/ABDELWAHABx/airsync-selfbuild/raw/116f81bcbec4f09cee44f12b8ba4593abefd7695/preview6/androp-v0.1.0-preview.6-arm64.dmg)** or **[ZIP](https://github.com/ABDELWAHABx/airsync-selfbuild/raw/116f81bcbec4f09cee44f12b8ba4593abefd7695/preview6/androp-v0.1.0-preview.6-arm64.zip)** for M1 and newer Macs. The [native build passed](https://github.com/ABDELWAHABx/Androp/actions/runs/38099927653); installation notes, build metadata and SHA-256 checksums accompany the downloads. Intel Macs require a separate universal build.

Extract the ZIP or mount the DMG, move `androp.app` to Applications, and open it. The private build is ad-hoc signed, without Apple Developer ID signing or notarization. If macOS blocks launch, use the explicit **Open Anyway** option in **System Settings → Privacy & Security** after trying to open it.

The main app targets macOS **14.5+**; the bundled widget requires **macOS 15+**. The floating phone widget works while androp is running. Native WidgetKit app-group access with an ad-hoc signature may require a locally developer-signed build. Newer visual and AI features retain their own OS requirements.

### Hotspot without debugging setup

On Android, open **Settings → Connection → Hotspot** and allow **Modify system settings**. On Mac, expand **Phone hotspot**, select its Wi-Fi name from **Saved networks**, and click **Connect**. androp requests activation, waits for confirmation, then joins using the existing Mac Keychain password. Allow Location and Keychain access if macOS asks. Enable and Disable remain available for hotspot-only control. **Setup on phone** places a settings action in the existing dashboard notification. No ADB or wireless debugging is required for this feature.

Android 16 exposes the API, but some Samsung firmware and carriers block ordinary apps even with that permission. androp reports this instead of claiming success. Android provides no normal app permission to turn global Data Saver off; use the direct settings action when it blocks activation. Hotspot uses your mobile data plan.

### Automatic Wi-Fi for files

Preview 5 makes **Send** handle connection setup in both directions. With an authenticated Wi-Fi connection, files start over it. With BLE only, the phone creates a temporary local Wi-Fi network, exchanges its credentials in an encrypted message with the paired Mac, and the Mac joins automatically. Sending starts after the matching authenticated connection is ready. The phone closes the temporary network afterward; the Mac attempts to return to its previous saved network without replacing another network you chose.

First use may ask for **Nearby Wi-Fi devices** on Android and **Location** on Mac. An Android permission request received in the background asks you to open androp, allow it and retry. Setup failures keep selected files available for retry; Android failures after actual sending starts may require sharing again. Cancel and Pause release the transfer network and cancel further setup work. A Wi-Fi association already submitted to macOS may finish before cleanup runs.

Temporary transfer Wi-Fi is **local-only, without internet**, and may interrupt the Mac’s internet connection while in use. It does not need ADB, change Data Saver, or use cellular tethering. Existing hotspot activity, phone policy or firmware can prevent creation; connect both devices to a shared Wi-Fi network in that case. Bluetooth remains available alongside Wi-Fi; an established authenticated Wi-Fi connection can maintain transfer coordination if BLE drops.

Install both updated apps. A dormant Android phone cannot be inserted through a documented public API into the native macOS Wi-Fi menu. [Connection behavior, permissions and cancellation](mac/HOTSPOT_CONNECTION_REVIEW.md).

### Battery alerts and phone widget

Open **Settings → My Mac → Phone battery alerts & widgets** to enable low-battery alerts or the floating phone widget. Choose an alert threshold and optional sound, then use the test-notification button to check macOS permissions. Closing the floating widget disables it; you can enable it again in settings.

### Pair and choose permissions

Open both updated apps. On Mac, choose **Bluetooth**, reveal the QR code and scan it inside androp on Android. Allow **Nearby devices** and turn on Bluetooth when prompted; keep the code open until connected. The code expires after two minutes. **No Wi-Fi is needed for first pairing.** You can instead select **Wi-Fi** on Mac when both devices are on a reachable shared network. The Wi-Fi code appears only when the listener is ready. Existing AirSync pairings are separate; pair again in androp. Leave Bluetooth sync enabled: it stays connected alongside Wi-Fi, with spaced reconnect attempts when the phone is unavailable. Pause stops both transports. Use Wi-Fi or a reachable hotspot connection for bulk files and continuous pointer input. You can select/drop files over BLE and press Send; androp prepares Wi-Fi automatically before sending the file bytes. Text keyboard, clipboard, media controls and other bounded messages also work over BLE. USB mirroring is a separate adb/scrcpy feature; plugging in a cable alone does not establish sync. The [BLE feature matrix](mac/BLE_FEATURES.md) lists supported commands and payload limits.

Permissions are feature-specific:

- **Notifications** enable the dashboard. Pending Nearby transfers can also be accepted or rejected in the app.
- **Notification access** enables phone notification/media sync; it does not block basic pairing, remote controls or file delivery. On a sideloaded Samsung installation, Android may require **Settings → Apps → androp → ⋮ → Allow restricted settings** before notification access can be enabled.
- **Nearby devices**, camera and Mac Accessibility permissions are requested for the features that need them. Grant Local Network access if the OS requires it for pairing.
- **All files access** is optional for phone file browsing. Selected-file sending and receiving into Downloads do not need it. Android still restricts `Android/data` and `Android/obb`.

Finder browsing is read-only and uses a revocable session token. Its HTTP traffic is unencrypted; use it only on a trusted local network. Use androp’s Send Files action to upload. Both peers must be updated for the new access protocol.

For Android-to-Mac Quick Share, enable Quick Share in androp on the Mac. Send can prepare the temporary Wi-Fi connection automatically; receiver consent remains in place. Paired Mac-to-Android drops use the connected transfer path. Find received files in Downloads.

## Keep awake and closed-lid testing

Ordinary **Keep Mac awake** prevents idle sleep during actual activity. Closing the lid still follows normal macOS sleep rules.

A separate **experimental closed-lid** option is off by default and must first be enabled locally in Mac settings. It uses a bundled nonprivileged watchdog and an undocumented macOS 15 interface, with short leases, battery/thermal checks and cleanup when activity ends. It does not install a privileged daemon or change `pmset`.

Request acceptance is not proof that an M1 Mac stays awake with the lid closed. This behavior has **not been physically verified**. Follow the desk checks in [CLOSED_LID_REVIEW.md](mac/CLOSED_LID_REVIEW.md), including normal sleep after Pause, disconnect and quit, before relying on it. Do not treat it as verified enclosed/bag operation.

## Build from source

The combined repository contains `android/` and `mac/`. Each keeps its original license and upstream documentation.

### Android

Use **Java 21**, Android SDK platform **37.0**, and Build Tools **36.0.0**. The repository includes the Gradle wrapper.

```sh
cd android
export ANDROID_HOME=/path/to/android-sdk
./gradlew :app:assembleDebug :app:testDebugUnitTest :app:lintDebug
```

The debug APK is `app/build/outputs/apk/debug/app-debug.apk`. Android application ID and namespace: `app.androp.android`. Android Studio can open the `android/` directory directly. A release build needs your own signing configuration; no signing key is included in this source repository.

### macOS

Use **Xcode 26+**, the macOS 26 SDK, and **Swift 6.2+**. On Sequoia, use a compatible Xcode release; [Apple's Xcode requirements](https://developer.apple.com/support/xcode/) list the host OS requirements. The build SDK does not change the app's runtime deployment target.

Open `mac/AirSync.xcodeproj` and select the **androp** scheme. Configure your own signing team and matching app group for normal app/widget development. For an unsigned compilation check:

```sh
cd mac
xcodebuild -project AirSync.xcodeproj -scheme androp \
  -configuration 'Self Compiled' -destination 'platform=macOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

Optional integrations use `scrcpy`/`adb` for mirroring and `media-control` for media support. Their availability, Android consent and macOS permissions determine which actions can run.

### Free public builds

Standard public GitHub runners compile and test both apps. Private build workflows are disabled. Mac artifacts are encrypted before public upload; installable downloads remain private. [Workflow and privacy details](BUILDING.md).

## Verification status

As of **11 October 2026**:

- The supplied idle Pause crash was traced to recursive Bluetooth scan/disconnect teardown and fixed. [CRASH_REVIEW.md](mac/CRASH_REVIEW.md) records the section audits and regressions.
- Android debug and optimized release APKs assembled; **213 JVM tests passed** with no failures, errors or skips. The optimized update retains the preview 1 signing certificate. [Android CI passed](https://github.com/ABDELWAHABx/Androp/actions/runs/38099496525/job/114352290938).
- Android lint finished with **0 errors, 255 warnings and 10 hints**. Remaining warnings are not presented as a clean lint result.
- Mac regressions passed on macOS 15 and 26: 21 production Bluetooth-manager cases (including the reported Pause state and 1,000 repeated teardowns), 27 encrypted Bluetooth QR pairing checks, six keep-awake tests, 23 packet checks, 16 remote-input checks, 10 battery-policy checks, 26 hotspot-manager checks, 32 hotspot Wi-Fi policy checks, 22 file-route checks, 17 temporary-network ownership checks, 84 encrypted transfer-protocol checks, 4 preference-persistence checks, 12 BLE-control checks, 11 network-recovery checks, 7 widget-placement checks, 12 notification-policy checks, plus clipboard, media and discovery checks, including 13 additional DNS-SD name-bound checks.
- The [native Mac build passed](https://github.com/ABDELWAHABx/Androp/actions/runs/38099927653) on Xcode 26.6. The actual compiled app passed a network-loss/Bluetooth-handoff check, three idle Pause cycles, two real Resume cycles, live receiving-toggle/listener checks, and two actual IPv4 WebSocket pairing exchanges that reject a wrong key and receive encrypted MacInfo with the correct key. The final ZIP package passed the same checks on **macOS 26**. The preceding Preview 6 package, before the DNS-SD name bounds, passed the encrypted handshake and lifecycle checks on **macOS 15.7.9** ([runtime verification](https://github.com/ABDELWAHABx/airsync-selfbuild/actions/runs/38098171307)). The current final package has not been independently run on macOS 15; current policy tests passed there. CI kept Bluetooth radio and the experimental helper inactive; physical pairing remains unverified.
- Battery savings, BLE responsiveness, transfer throughput, Samsung Now Bar presentation and closed-lid behavior require measurements or device checks.

[EXPERIENCE_REVIEW.md](mac/EXPERIENCE_REVIEW.md) records protocol behavior and remaining device checks. [PERFORMANCE_REVIEW.md](mac/PERFORMANCE_REVIEW.md) covers implementation findings; [CLOSED_LID_REVIEW.md](mac/CLOSED_LID_REVIEW.md) records the experimental power mechanism and its limits.

## Credits and licenses

androp builds on AirSync by **Sameera Wijerathna** and its contributors. Original notices and documentation are retained in [mac/README.upstream.md](mac/README.upstream.md) and [android/README.upstream.md](android/README.upstream.md). Some upstream artwork and support links remain; those links are not an androp download or support service.

Publicly visible source is **not a blanket grant of unrestricted redistribution**. Read [mac/LICENSE](mac/LICENSE) and [android/LICENSE](android/LICENSE): both retain their upstream MPL 2.0 notices and additional terms. The Mac license restricts modified binaries to private/internal use and prohibits redistribution of modified builds. Android's additional terms require publisher responsibility and retention of the license. No upstream trademark rights are granted.

The preview downloads therefore remain private. This project does not replace or relax either component's license.
