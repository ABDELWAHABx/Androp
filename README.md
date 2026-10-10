# androp

**Your Android phone and Mac, working together.**

androp is a personal continuation of [AirSync macOS](https://github.com/sameerasw/airsync-mac) and [AirSync Android](https://github.com/sameerasw/airsync-android), focused on dependable handoff, quieter background work, and controls that fit the way you use your devices. It has its own app identity and pairing namespace, so it can be installed alongside AirSync.

Control your Mac from your phone, send files into Android Downloads, share a video at its timestamp, and reach everyday actions from one notification dashboard. Pause stops the underlying work. An empty media session no longer takes over the screen.

[Private preview downloads](https://github.com/ABDELWAHABx/airsync-selfbuild/releases/tag/androp-v0.1.0-preview.1) · [Experience review](mac/EXPERIENCE_REVIEW.md) · [Power and performance review](mac/PERFORMANCE_REVIEW.md) · [Closed-lid experiment](mac/CLOSED_LID_REVIEW.md)

## What changed

| Area | androp behavior |
| --- | --- |
| Pause and power | Cancels sync, discovery, transfers, media and mirroring work. Resume remains available. Event-driven input, bounded queues and active-only monitoring replace unnecessary background work. |
| Android dashboard | One quiet notification combines connection state, transfers, consent, clipboard links and Find Phone. Contextual actions open the right screen. Native media keeps its own player. |
| Samsung / Android 16 | Requests supported Live Updates for active work, with a normal notification fallback. Now Bar placement and visibility remain controlled by Android and Samsung settings. |
| Remote controls | Trackpad below the buttons in portrait, to their right in wide layouts. Empty media hides; paused media stays compact. Pointer and text keyboard input use Wi-Fi/USB; supported small controls also work over authenticated BLE. |
| File transfers | Review dropped files on Mac, send with progress and cancellation, and confirm the final Android save. Bounded writes, SHA-256 verification and interrupted-transfer cleanup protect the paired transfer path. |
| Clipboard | Message acknowledgements, finite retries and duplicate handling distinguish waiting from delivered. Android clipboard reading follows foreground restrictions; explicit Share to androp remains available. |
| Media | Native Android MediaSession metadata, playback controls and remote volume control your Mac. Audio continues playing on the Mac; this does not stream its audio to the phone. |
| Find Phone | A bounded alert can be started and stopped from Mac. It respects silent mode and Do Not Disturb; a visible alert remains available when sound is suppressed. |
| YouTube handoff | Share a supported YouTube URL to androp and choose **Open video on Mac**. Timestamp parameters survive the handoff; ordinary clipboard sync does not automatically open a browser. |
| Keep Mac awake | Opt-in prevention of idle sleep during transfers, recent remote input or playback. Phone controls show reported Mac state; **Sleep Mac** appears when the Mac reports a closed lid. |

These are implemented changes, not measured battery or throughput claims. Physical-device testing is still needed, especially on the reported Samsung S21 FE / One UI 8 and MacBook Air M1 / macOS 15 configuration.

## Download and install

Build downloads live in the **private** [airsync-selfbuild preview release](https://github.com/ABDELWAHABx/airsync-selfbuild/releases/tag/androp-v0.1.0-preview.1). Sign in with an account that has access; public source access does not grant access to those downloads.

### Android

1. Download [androp-android.apk](https://github.com/ABDELWAHABx/airsync-selfbuild/releases/download/androp-v0.1.0-preview.1/androp-android.apk), the optimized, locally signed private preview.
2. On Android 11 or newer, open the APK and allow installation from that source if Android asks.
3. Open androp, then pair with the matching Mac app. Allow notifications if you want the dashboard in the notification shade.

Use the signed release APK for installation and updates. CI debug artifacts use a temporary signing identity and cannot replace an installed private release. This is a development preview, not a Play Store release.

### macOS

**Native Mac CI is running; a successful build and Mac download are not yet confirmed.** Check the private release page for the ZIP or DMG and its installation notes when packaging finishes.

Once available, extract the ZIP or mount the DMG, move `androp.app` to Applications, and open it. The private build is ad-hoc signed, without Apple Developer ID signing or notarization. If macOS blocks launch, use the explicit **Open Anyway** option in **System Settings → Privacy & Security** after trying to open it.

The main app targets macOS **14.5+**; the bundled widget requires **macOS 15+**. Widget app-group access with an ad-hoc signature may require a locally developer-signed build. Newer visual and AI features retain their own OS requirements.

### Pair and choose permissions

Open both updated apps on the same Wi-Fi network and scan the Mac's pairing QR code from Android. Existing AirSync pairings are separate; pair again in androp. Wi-Fi or USB is required for bulk files and pointer/text input. Authenticated BLE supports selected small commands; it is not a bulk-transfer replacement.

Permissions are feature-specific:

- **Notifications** enable the dashboard. Pending Nearby transfers can also be accepted or rejected in the app.
- **Notification access** enables phone notification/media sync; it does not block basic pairing, remote controls or file delivery. On a sideloaded Samsung installation, Android may require **Settings → Apps → androp → ⋮ → Allow restricted settings** before notification access can be enabled.
- **Nearby devices**, camera and Mac Accessibility permissions are requested for the features that need them. Grant Local Network access if the OS requires it for pairing.
- **All files access** is optional for phone file browsing. Selected-file sending and receiving into Downloads do not need it. Android still restricts `Android/data` and `Android/obb`.

For Android-to-Mac Quick Share, enable Quick Share in androp on the Mac and keep both devices on reachable Wi-Fi. Paired Mac-to-Android drops use the connected transfer path. Find received files in Downloads.

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

## Verification status

As of **10 October 2026**:

- Android debug and optimized release APKs assembled; application identity and APK signatures were verified.
- **56 Android JVM tests passed** with no failures or errors.
- Android lint finished with **0 errors, 250 warnings and 10 hints**. Remaining warnings are not presented as a clean lint result.
- Native Mac CI is running. A passing native build, bundled-helper execution and hardware pairing are not yet confirmed.
- Battery savings, BLE responsiveness, transfer throughput, Samsung Now Bar presentation and closed-lid behavior require measurements or device checks.

[EXPERIENCE_REVIEW.md](mac/EXPERIENCE_REVIEW.md) records protocol behavior and remaining device checks. [PERFORMANCE_REVIEW.md](mac/PERFORMANCE_REVIEW.md) covers implementation findings; [CLOSED_LID_REVIEW.md](mac/CLOSED_LID_REVIEW.md) records the experimental power mechanism and its limits.

## Credits and licenses

androp builds on AirSync by **Sameera Wijerathna** and its contributors. Original notices and documentation are retained in [mac/README.upstream.md](mac/README.upstream.md) and [android/README.upstream.md](android/README.upstream.md). Some upstream artwork and support links remain; those links are not an androp download or support service.

Publicly visible source is **not a blanket grant of unrestricted redistribution**. Read [mac/LICENSE](mac/LICENSE) and [android/LICENSE](android/LICENSE): both retain their upstream MPL 2.0 notices and additional terms. The Mac license restricts modified binaries to private/internal use and prohibits redistribution of modified builds. Android's additional terms require publisher responsibility and retention of the license. No upstream trademark rights are granted.

The preview downloads therefore remain private. This project does not replace or relax either component's license.
