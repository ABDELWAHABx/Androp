# Pause crash and lifecycle review

The supplied macOS 15.8.1 report shows a main-thread stack overflow while
pausing an idle app. `BLECentralManager.stopScanning()` called `disconnect()`,
which called `stopScanning()` again before the scanning state changed. No
connected phone or active media was needed. The previous compilation checks
did not catch this runtime call cycle.

## Repairs

| Section | Concrete repair |
| --- | --- |
| Bluetooth | Discovery stopping is nonrecursive; disconnect is ordered and idempotent. Queued callbacks and retries belong to their original session and cannot restart after Pause. |
| App lifecycle | Late authentication cannot reconnect a paused app; power-observer startup is generation-checked; changing phones clears old status. |
| Mirroring and media | Wire headers avoid unaligned reads and bound packet sizes; asynchronous video decoding owns its sample memory; cancelled sessions reject stale reconnects; idle cleanup does not launch a missing ADB process. |
| Remote input | Invalid numeric scroll and keycode values are rejected before conversions that could trap. |
| Transfers | Malformed discovery and handshake state fail cleanly; transfer callbacks cannot affect a replacement session; throwing file I/O makes cleanup errors recoverable; invalid popup limits are clamped. |
| Release UI | The intentional crash menu and shortcut are restricted to Debug builds. Bundle version lookup handles missing metadata. |
| Android | Foreground startup rejection, teardown ordering, malformed pairing input and wake-up socket/parser bounds are covered in [the Android review](../android/CRASH_REVIEW.md). |

## Implemented features previously marked Soon

**Low Battery Alerts:** Settings → My Mac → Phone battery alerts & widgets.
Choose a threshold, optional sound, and send a test notification. Alerts are
event-driven and suppressed while paused, disconnected, or battery status is
unknown. Charging or recovery five points above the threshold rearms the alert.
macOS notification and Focus settings still apply.

**Widgets:** The floating phone widget displays connection, battery and media
status with Pause/Resume controls. It works while the main app is running and
does not require a signed App Group. Native WidgetKit snapshots are atomic,
bounded and coalesced, with explicit freshness and unknown-battery handling.
Native desktop/Notification Center widgets require usable app-and-extension
App Group signing; the settings panel reports that capability.

## Regression evidence

The macOS 15 CI job passed the production Bluetooth-manager regression
(including the exact scanning/no-phone Pause case and 1,000 repeated teardowns),
10 BLE cases, six keep-awake policy tests, 23 packet checks, 16 numeric input
checks, 10 battery-policy checks, Nearby discovery metadata and media checks.

The native package job also runs those checks and then executes three Pause
cycles and two real Resume cycles in a disposable copy of the compiled app.
That test has isolated preferences, does not open a Bluetooth radio, and cannot
enable the experimental power helper. The [native build](https://github.com/ABDELWAHABx/airsync-selfbuild/actions/runs/38085118534) passed these checks and the real-app lifecycle test on macOS 26. The exact packaged ARM64 app then passed the same three Pause/two Resume cycles on [macOS 15.7.9](https://github.com/ABDELWAHABx/airsync-selfbuild/actions/runs/38085737665), with strict signatures, SHA-256 and source-commit comparison verified. The supplied report is from 15.8.1; CI covers its OS generation, not that exact point release or physical Mac.

Real phone pairing, mirroring, cancellation during a large transfer, Samsung
notification surfaces, battery measurements and closed-lid behavior still need
device checks. These repairs and regressions do not establish that every runtime
crash has been eliminated.
