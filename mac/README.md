# androp for macOS

Private development version of [AirSync macOS](https://github.com/sameerasw/airsync-mac), based on upstream commit `bdaaecbebbc8308faeebe164334e6c409b34aaa6`.

The original application documentation is preserved in [README.upstream.md](README.upstream.md). The original [LICENSE](LICENSE) and author attribution remain intact.

## Local development

This repository is on the `own-version` branch. The `upstream` Git remote points to Sameera Wijerathna's repository. There is no publishing remote configured.

Open `AirSync.xcodeproj` in Xcode and select the **androp** scheme. Original target and source names remain to simplify comparisons with upstream. Build products are named `androp.app` and `andropWidget.appex`.

The main app bundle ID is `app.androp.mac`, the widget ID is `app.androp.mac.widget`, and shared widget storage uses `group.app.androp.mac.widget`. Keychain storage is also separate from AirSync.

Tracked configuration files in `airsync-mac/BuildConfig` enable the upstream `SELF_COMPILED` mode. The original author's signing team has been removed. Set your own signing team for the app and widget, and configure the matching app group when building with signing.

```sh
xcodebuild -project AirSync.xcodeproj -scheme androp \
  -configuration 'Self Compiled' -destination 'platform=macOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

This command is a build check; configure signing in Xcode for normal installation and widget use. The main app targets macOS 14.5; the widget and project default target macOS 15.0, so the app and widget can run together on Sequoia. Liquid Glass uses a material fallback below macOS 26; AI notification summaries require macOS 26.

Building still requires Xcode 26 or newer with the macOS 26 SDK and Swift 6.2, because the source references newer SDK symbols inside runtime availability guards. For building on Sequoia, use Xcode 26 through 26.3 on macOS 15.6 or later; newer Xcode releases may require Tahoe. See Apple's [Xcode requirements](https://developer.apple.com/support/xcode/). The build SDK version does not raise the app's runtime deployment target. Mac compilation and device pairing cannot be verified on this Linux workspace.

## Private GitHub downloads

The manual `Private androp macOS build` workflow requires a private repository and a release tag. Its default `arm64` build targets M1 and other Apple Silicon Macs; `universal` also includes Intel. It runs on a macOS runner with Xcode 26+, runs the power-policy tests, builds the `androp` scheme in `Self Compiled`, verifies ad-hoc signatures, and produces ZIP/DMG downloads with licenses, build metadata and SHA256 checksums. `publish_release` uploads them to a private prerelease; disabling it retains Actions artifacts only. The repository privacy is checked again before release publication.

To build the same downloads locally, run `bash Tools/Release/build-mac.sh androp-private-1 arm64`. The source icon metadata is compatible with Xcode 26. No developer certificate secret is needed for this private build. Ad-hoc downloads are not Apple notarized and may need an explicit Open Anyway in macOS Privacy & Security; widget app-group access may require a developer-signed build. CI does not activate the experimental closed-lid mode or change system power settings. The inherited Telegram notification and obsolete upstream-scheme workflows have been removed.

Optional mirroring integrations use `scrcpy` and `adb`; optional media integrations use `media-control`.

## Pairing

Install the private androp Android APK and open both apps on the same network. QR pairing uses `androp://`, Bonjour uses `_androp._tcp`, the default WebSocket port is 6997, UDP discovery is 8890, and Android HTTP reconnection is 8891. Both apps share a new Bluetooth UUID namespace. Existing AirSync pairings are not imported.

The upstream Sparkle updater is disabled and its update feed removed. Onboarding no longer points to the AirSync Play Store listing. Quick Share retains its standard Nearby interoperability protocol.

## Branding and distribution

The name and installed identity are separate from AirSync. Existing icon artwork and some upstream feature, help, and support content are still present; upstream links are not an androp download or support service.

The original license permits private modification and explicitly prohibits distributing modified Mac builds. Keep the complete license and additional terms. This workspace is prepared for private development.

## Verification

Property lists, widget entitlements, Xcode schemes, localization JSON, and matching Android/Mac discovery constants were checked. The original licenses are unchanged. Xcode compilation and physical device pairing have not been tested in this Linux workspace.

## Performance and bug fixes

Pause/Resume is available in the menu bar. Pause cancels connections, discovery, transfers, polling, media and mirroring, including standalone scrcpy. Sleep/wake preserves an intentional pause. Monitoring runs while connected; socket writes and transfer disk IO avoid blocking the main thread.

[PERFORMANCE_REVIEW.md](PERFORMANCE_REVIEW.md) records the findings, repairs, regression coverage and remaining device checks. A Foundation-only media regression harness can run on a Swift-enabled machine:

```sh
swiftc airsync-mac/Model/NowPlayingInfo.swift Tests/NowPlayingInfoRegression.swift -o /tmp/androp-media-tests
/tmp/androp-media-tests
```

## Notification and handoff improvements

Android now has a consolidated action dashboard, native Mac media controls, conditional Android Live Updates / Samsung Now Bar support, feature-specific Samsung permission guidance and in-app Nearby transfer consent. Mac provides Find Phone and reviewed drag/drop into Android Downloads. Clipboard sends use receiver acknowledgements and finite retries; YouTube sharing offers an explicit Open video on Mac action and preserves timestamps.

[EXPERIENCE_REVIEW.md](EXPERIENCE_REVIEW.md) records the behavior, platform limits and remaining device checks. Both updated clients are required for confirmed clipboard and paired file transfers.

## Keep awake and closed-lid experiment

Mac settings provide an opt-in Keep Awake mode tied to actual file transfers, recent remote input and playback. Idle pairing alone does not hold a sleep assertion. Pause, disconnect and quit release activity; the phone offers Sleep Mac when the Mac reports a closed lid.

On macOS 15, a separate default-off experimental option uses a bundled nonprivileged watchdog to request lid-specific sleep prevention. It requires battery above 20% and a thermal state below serious, with short renewable leases and cleanup on stop or loss of the parent. This uses a private OS interface; successful request acceptance does not prove closed-lid operation. Read [CLOSED_LID_REVIEW.md](CLOSED_LID_REVIEW.md) and perform its desk checks before relying on it on an M1 Air.

Six pure keep-awake policy tests can run on a Swift-enabled host with `bash Tests/run-mac-power-policy-tests.sh`. They could not run in this Linux workspace because no Swift compiler is installed.
