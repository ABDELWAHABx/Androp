# androp notification and handoff improvements

Implemented for the Mac companion and Android client, with Samsung S21 FE / One UI 8 and MacBook Air M1 (2020) / macOS 15 Sequoia as the reported devices. Hardware behavior still needs verification on that phone and a Mac.

## Android dashboard

Connection, Mac battery, transfers, transfer consent, clipboard links and Find Phone share one quiet notification. Its expanded native layout provides context and up to three actions, including Pause/Resume, Remote, Accept/Reject, Cancel, Open link/file and Stop alert. Media retains its independent native player.

Nearby file consent is also available in the app when notification permission is denied.

The sync, sending and receiving services each enter foreground promptly but share a stable notification ID. Owner tracking and foreground detachment prevent one stopped service from erasing another service's card. Pause keeps an ordinary lightweight Resume card while cancelling actual background sync work. Lock-screen public content is generic; private clipboard/link details are not displayed there.

Updates follow state changes. Transfer progress uses ten-percent steps, and media position/ETA changes do not rebuild the dashboard. Quick Settings no longer polls every 600 ms. Foreground-service notifications are still required by Android; permission and dismissal behavior are controlled by the OS.

## Samsung Now Bar and native media

On Android 16+, where the platform supports promoted ongoing notifications, the dashboard uses supported native BigText/Progress notification styles and requests promoted ongoing presentation when an active connection, transfer or phone alert is present. Paused and idle discovery states do not request promotion. The app checks platform promotion capabilities and retains the regular notification fallback. The promotion request uses the same backward-compatible notification extra as AndroidX NotificationCompat, avoiding the framework setter that requires API 36.1. This follows [Android Live Updates](https://developer.android.com/develop/ui/views/notifications/live-update); it does not use a floating overlay or a simulated island.

The Android settings UI includes a **Live updates / Now bar** action. Allow live notifications/promoted notifications for androp and enable the desired Samsung Now Bar surfaces in phone settings. Samsung decides which eligible notifications appear and where; the S21 FE's exact presentation has not been tested here.

Mac playback publishes an active Android remote MediaSession, MediaStyle notification, metadata, artwork, playback state, native transport controls and remote volume provider. Seeking is offered only over Wi-Fi with a known duration. A session can run under the existing sync foreground service, avoiding a second background foreground-service launch. Reopening the app retries a cached native session if Android previously blocked startup. Mirrored sessions are excluded from phone media selection to prevent control loops.

This is native remote media control. It does not route Mac audio through Bluetooth or impersonate an A2DP device. Audio remains on the Mac. Phone media syncing back to Mac needs notification access, and individual players decide whether seek and transport commands are supported.

## Mac actions and file sending

The phone panel and menu bar provide Find Phone, Stop alert, Send files, Open files, clipboard and mirroring actions with actual connection/capability status. Find Phone requests a bounded thirty-second alert over Wi-Fi or authenticated BLE; it does not change system volume or override silent mode/Do Not Disturb. The visible alert still appears when sound is suppressed, and pause/stop cancels its resources.

The connected-phone drop zone opens a file review sheet with filenames, sizes, send, progress and cancel. Transfers pin the paired WebSocket session and phone identity. The previously missing Android WebSocket receiver now writes bounded chunks, acknowledges successful disk writes, verifies SHA-256 and publishes to Downloads through MediaStore. Normal receiving does not require All Files access. A successful Mac result follows the phone's final save confirmation, not merely the last transmitted chunk. Interrupted transfers clean up temporary and pending files. BLE-only connections explain that files require Wi-Fi.

File browsing is separate from sending/receiving and still requires the phone's broad storage permission. Samsung notification access and sideload restricted-settings guidance are optional feature-specific steps; they no longer block pairing or unrelated remote/file actions. Nearby QuickShare retains explicit consent when peer identity is not authenticated.

## Reliable clipboard and YouTube

Clipboard delivery uses message IDs, receiver acknowledgements, bounded pending queues, finite retries and duplicate-receipt handling across Wi-Fi and BLE. An enqueued message is reported as waiting, not delivered. Changing the paired device cancels pending delivery and resets deduplication for the new peer. Failed encryption/decryption does not fall back to plaintext or dispatch unauthenticated pre-handshake payloads. Pause cancels pending work. Android clipboard monitoring is attached while the app is visible and detached when hidden; Android prevents general background clipboard reading. Explicit Share to androp and Send clipboard remain available.

Sharing a YouTube link to androp offers **Open video on Mac** and **Copy text**. The handoff extracts a supported YouTube video URL from shared text, preserves timestamp parameters, and requests browser opening only for the explicit video action. Normal clipboard sync does not gain automatic browser opening. On Android, incoming links remain available through the consolidated dashboard's Open action; background activity launches are not forced. Video availability, browser sign-in and autoplay remain controlled by YouTube/browser behavior.

Both clients need the updated clipboard protocol for confirmed delivery. The parser accepts public YouTube watch, short-link, Shorts and live URLs; it does not fetch private WhatsApp conversations or download videos.

## Activity-based keep-awake and experimental closed-lid testing

The Mac includes opt-in idle-sleep prevention while actual transfers, recent remote input or playback are active. Enabling the preference alone creates no assertion. Monotonic activity leases, OS assertion timeouts and pause/disconnect/termination cleanup release it when activity ends. Android shows confirmed Mac state and a Sleep Mac action only when the Mac reports a closed lid. Sleep acceptance means queued; subsequent OS errors are reported separately.

For the user's M1 Air on battery without an external display, normal macOS idle assertions do not override lid-close sleep. Research of Amphetamine and Sequoia source identified a private lid-specific IOKit operation distinct from the global `pmset disablesleep` workaround. An opt-in experimental backend uses a bundled nonprivileged watchdog, short active leases, battery/thermal guards and restoration on EOF, stop or expiry. It is enabled locally in Mac settings, not remotely installed or silently enabled. It does not install Amphetamine, change sudoers or use global SleepDisabled.

This uses an undocumented OS interface and has not been run on the user's Mac. Accepted IOKit operations are not proof of uninterrupted closed-lid behavior. [CLOSED_LID_REVIEW.md](CLOSED_LID_REVIEW.md) records the source evidence, integration limits and device checks. Test on a desk before enclosed use; verify normal lid sleep after ending a session or quitting the app.

## Validation

Android debug and optimized release APKs assembled; 56 unit tests passed with no failures/errors; Android lint passed with zero errors, 250 warnings and 10 hints. Debug and locally signed optimized APK identity and signatures verified. All 82 changed Swift files parsed without new errors (four unchanged upstream parser limitations). All six Mac keep-awake policy tests passed in native CI on Xcode 26.6 / Swift 6.3.3. Structured resource/configuration files parsed, both licenses remain unchanged. The native Mac app, widget and helper compiled, and strict signature, bundle identity, deployment target and arm64 package checks passed in [CI](https://github.com/ABDELWAHABx/airsync-selfbuild/actions/runs/38081058944). Physical device behavior and power consumption remain unverified. Tests cover dashboard ownership and pause, progress/promotion rules, native media timeline bounds, notification navigation, file chunk bounds, clipboard acknowledgement/retry behavior and YouTube parsing, alongside the earlier regression suite. Swift syntax checks compare changed files with upstream; they do not replace Xcode compilation.

Device checks remain necessary: Now Bar eligibility/presentation, Samsung native media/headset controls, Find Phone under locked/silent conditions, large-file drop/cancel/disconnect, clipboard while visible/hidden, explicit YouTube handoff and actual power consumption. Native compilation was verified on the GitHub macOS runner; rendering and device behavior remain unverified.
