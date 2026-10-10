# androp for Android

**Your phone's companion to androp on Mac.**

Control your Mac, receive files in Downloads, share clipboard text and timestamped YouTube links, and reach everyday actions from a quiet notification dashboard. androp is a personal continuation of [AirSync Android](https://github.com/sameerasw/airsync-android), with its own Android identity: `app.androp.android`. It can be installed alongside AirSync; pair it with the matching androp Mac app.

[Private preview release](https://github.com/ABDELWAHABx/airsync-selfbuild/releases/tag/androp-v0.1.0-preview.1) · [Signed Android APK](https://github.com/ABDELWAHABx/airsync-selfbuild/releases/download/androp-v0.1.0-preview.1/androp-android.apk) · [Upstream documentation](README.upstream.md)

## Everyday improvements

- **Pause stops the work:** sync, discovery, transfers and media work are cancelled, with a lightweight Resume action available. Input and notification updates follow activity instead of constant idle polling.
- **A useful dashboard:** connection, transfers, Nearby consent, clipboard links and Find Phone share one notification. Actions open the relevant screen. Pending Nearby transfers can also be accepted in the app when notifications are disabled.
- **Native media controls:** Mac playback uses Android MediaSession and native player controls. Empty sessions hide; paused sessions stay compact. Audio stays on the Mac; this does not stream it to Android.
- **A better remote layout:** controls sit above the trackpad in portrait and to its left in wide layouts. Wi-Fi/USB is required for pointer and text input; selected small controls work over authenticated BLE.
- **Confirmed handoff:** clipboard acknowledgements distinguish waiting from delivered, with bounded retries. Explicit YouTube sharing preserves timestamps and offers **Open video on Mac**.
- **Reliable Downloads delivery:** paired Mac file transfers use bounded writes, SHA-256 verification, final-save acknowledgement and cancellation cleanup. The Mac gets success after the phone saves the file.
- **Mac power controls:** opt-in activity-based keep-awake shows actual Mac state. Sleep Mac is offered only when a closed lid is reported; acknowledgement means the sleep request was queued.

On Android 16+, the dashboard can request supported Live Updates. Samsung decides Now Bar placement and visibility; the normal notification remains the fallback. Find Phone respects silent mode/Do Not Disturb and does not force system volume.

## Install and pair

1. Download the signed `androp-android.apk` from the private preview release. GitHub access to that repository is required.
2. Install on **Android 11 / API 30 or newer**. Allow installation from your chosen source if Android asks.
3. Install the matching androp Mac app, open both on reachable Wi-Fi, and scan the Mac QR code. Existing AirSync pairings are separate.

Use the signed preview APK for updates. CI debug artifacts use a temporary signing identity and cannot replace an installed private release. No signing key is included in the public source.

For Android-to-Mac Quick Share, enable Quick Share in androp on the Mac and keep both devices on Wi-Fi. Mac-to-Android paired file drops save to Downloads. BLE does not carry bulk file transfers.

## Permissions on Android and Samsung

Enable permissions when you choose the feature that needs them; optional permissions do not block basic pairing.

| Permission | Needed for |
| --- | --- |
| Notifications | Dashboard, transfer actions and visible alerts in the notification shade. In-app Nearby consent remains available without it. |
| Notification access | Phone notification/media sync. On a sideloaded Samsung app, first allow **Settings → Apps → androp → ⋮ → Allow restricted settings** if Android blocks access. |
| Nearby devices | Bluetooth discovery/connection features. |
| Camera | QR scanning. |
| Local Network, where required | Discovery and pairing on newer Android versions. |
| All files access | Optional phone file browsing. It is not required for selected-file sends or Downloads receives; Android still restricts `Android/data` and `Android/obb`. |

Use **Live updates / Now bar** in androp settings to open the relevant OS settings on supported versions. If background sync stops on Samsung, check Sleeping/Deep Sleeping Apps settings for androp; battery-policy changes are optional and do not bypass Pause.

Android limits background clipboard reading. androp monitors it while the app is visible and detaches when hidden. Use Android's share sheet or explicit Send clipboard for deliberate handoff; automatic background browser launches are not forced.

## Build and verify

Use **Java 21**, Android SDK platform **37.0**, and Build Tools **36.0.0**. The Gradle wrapper is included.

```sh
export ANDROID_HOME=/path/to/android-sdk
./gradlew :app:assembleDebug :app:testDebugUnitTest :app:lintDebug
```

Open this directory in Android Studio, or install `app/build/outputs/apk/debug/app-debug.apk` from a local debug build. Release builds need your own signing configuration. Kotlin sources are in `app/src/main/java/app/androp/android`; application ID and namespace are both `app.androp.android`.

As of **10 October 2026**, debug and optimized release APKs assembled and identity/signature inspection passed. **56 JVM tests passed** with no failures/errors. Lint completed with **0 errors, 250 warnings and 10 hints**; see `app/build/reports/lint-results-debug.html` after a local run.

Native Mac CI is running; no passing Mac build or device pairing is claimed yet. Battery savings, BLE latency, large-file throughput and Samsung S21 FE / One UI 8 presentation require physical-device checks. In the combined source repository, `mac/EXPERIENCE_REVIEW.md` and `mac/PERFORMANCE_REVIEW.md` document behavior and remaining checks.

## Keep-awake limits

Ordinary Mac Keep Awake prevents idle sleep during actual transfer, remote input or playback; lid closure still follows macOS sleep rules. The separate experimental closed-lid option is **off by default**, enabled locally on Mac, and scoped to macOS 15. It uses an undocumented interface and a bounded nonprivileged watchdog. Phone state reflects request acceptance, not proof of physical closed-lid operation on M1 hardware. Read `mac/CLOSED_LID_REVIEW.md` in the combined repository before testing it on a desk or relying on it.

## Attribution and distribution

Based on upstream commit `2559ec38d8ef49d7efbe5af3e21fe632feb7b716` of AirSync Android by **Sameera Wijerathna** and contributors. The original [LICENSE](LICENSE), additional terms and [upstream README](README.upstream.md) are retained. Some original artwork and support links remain; they are not androp download or support services.

Source visibility does not grant unrestricted redistribution. Android retains its MPL 2.0 notice and additional publisher-responsibility/license-retention terms. The companion Mac license prohibits redistribution of modified binaries and limits them to private/internal use; build downloads remain private. No upstream trademark rights or replacement license are asserted.
