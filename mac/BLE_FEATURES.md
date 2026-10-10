# Bluetooth feature coverage

Both peers must run the updated androp build. Pair over Wi-Fi once to establish the shared device identity, enable Bluetooth sync on both peers, and keep Bluetooth enabled. Once paired, these features work without a shared Wi-Fi network. When a network socket exists, androp uses it for higher throughput; otherwise small commands use authenticated BLE.

| Feature | BLE | Notes |
| --- | --- | --- |
| Clipboard text in both directions | Yes | Up to 64 KiB UTF-8; message IDs, acknowledgements, bounded retries, duplicate suppression. Android automatic reads require the app in the foreground; share sheet and clipboard tile remain explicit entry points. |
| YouTube link handoff | Yes | Uses the acknowledged text envelope. Android presents a continue-watching action because background activity launches are restricted. |
| Media play/pause, next/previous, seek | Yes | Full small JSON commands preserve seek positions. The destination player must support the requested action. |
| Phone media likes and volume | Yes | Uses the same handlers as Wi-Fi; unsupported like actions depend on the player. |
| Battery and charging state | Yes | Full state includes charging rather than only the old percentage byte. |
| Track metadata and progress | Yes | Duration and playback position included. Artwork omitted to keep control and clipboard traffic responsive. |
| Notifications, replies, dismissals | Yes | Bounded text and actions; reply text preserved. Rich images and large application-icon collections require network. |
| Keyboard text and keys | Yes | Bounded JSON preserves text and modifiers. macOS Accessibility permission remains required. |
| Lock, brightness, media/volume buttons | Yes | Small validated control actions. |
| Find Phone | Yes | Start/stop ring commands; phone sound/DND settings apply. |
| Call events and controls | Yes | Small events and action responses; Android phone/call permissions apply. Oversized caller-photo messages are rejected. |
| Mac keep-awake/sleep controls | Yes | Uses existing authenticated power command envelope; hardware/macOS restrictions remain. |
| Hotspot control/status | Transport ready | Uses phoneHotspotControl/phoneHotspotState; Android version, permissions, Data Saver, and Samsung policy still determine whether activation is allowed. |
| File transfer setup in both directions | BLE coordinates Wi-Fi | Send reuses paired Wi-Fi or negotiates an encrypted temporary local-only phone hotspot, then sends after network authentication. Normal Wi-Fi/Location permissions apply. |
| Files, file browser, WebDAV | Network | File bytes require a reachable IP connection. Send can establish a temporary transfer connection automatically; this does not imply that opening the file browser or WebDAV creates one. Plugging in USB alone does not connect these features. |
| Screen mirroring | Network or existing USB mirroring setup | Uses the separate mirroring transport; its USB support does not provide file sync or the app's remote trackpad connection. |
| Continuous mouse/trackpad streaming | Network | Excluded from BLE to avoid saturating its control queue. Requires the app's network connection, including when USB mirroring is already active. |

## Persistent Bluetooth beside Wi-Fi

Preview 4 keeps authenticated Bluetooth connected when Wi-Fi connects. Losing only the network path preserves the phone identity and Bluetooth controls. The dashboard reports both links. Each command still selects one transport; ordinary messages prefer an available network socket, while hotspot activation explicitly prefers the authenticated BLE peer. Files and continuous pointer input stay on the network.

Mac discovery uses 10-second windows followed by 5–60 seconds of rest; transient connection failures back off to 60 seconds. An established link has no discovery timer. Android uses low-power advertising and radio/settings/foreground lifecycle events rather than a reconnect polling loop. Pause, disabling Bluetooth sync and manual disconnect stop automatic connection work. Reconnection can take up to the current rest interval plus discovery/authentication time; Bluetooth availability does not guarantee an instant connection.

The Mac remembers the authenticated peripheral against the pairing-token fingerprint. If the phone's Bluetooth identity changes after a reset, select it explicitly in the device list or pair again. This reduces automatic token disclosure to unrelated advertisers after first contact; the existing initial token exchange is not mutual cryptographic authentication and the general BLE transport remains unchanged. Preview 5 separately encrypts transfer-network coordination envelopes as described below.


## Fixed in this pass

- Removed duplicate Mac media/volume sends: toggles previously executed twice on BLE and could immediately undo themselves.
- Corrected Mac volume action names to match Android's common handler.
- BLE now carries media seek/like parameters, keyboard text/modifiers, charging state and playback position through bounded control envelopes.
- BLE-only authentication starts battery/media status synchronization; disconnect stops it only when Wi-Fi is also absent. Battery synchronization no longer depends on enabling mirrored notifications.
- BLE send results now reflect actual queue acceptance for notification/control traffic.
- Clipboard retry delay scales from 8 to 60 seconds by payload size; Wi-Fi keeps its 4-second retry. Explicit Android sends wait long enough for all three BLE attempts instead of expiring at the first retry deadline.
- Eliminated resizing/encoding album artwork that BLE should not transmit.

## Verification and limits

Added five Android policy tests and twelve Swift regression assertions covering command boundaries, cursor/bulk rejection, clipboard retry budgets, UTF-8 limits, media parameters, compact status and charging. The integrated Android build and 141-test suite passed; the Mac policy suite and native app build passed on CI. Physical Samsung/Mac BLE latency and reliability still require device testing.

BLE authentication remains the existing paired-device token protocol. Legacy BLE feature payloads are not all application-encrypted; Preview 5 adds AES-GCM protection specifically to the transfer-network envelope.

Preview 4 verification: 19 production BLE-manager regression cases, 10 file-route checks and the expanded hotspot suite passed on macOS 15 and 26. Android passed 149 JVM tests, debug/release assembly and lint without errors. The actual Mac app passed radio-free network-loss/Bluetooth handoff and Pause/Resume checks; physical radio behavior remains unverified.


## Preview 5: Send prepares Wi-Fi automatically

Mac Send and Android sharing now treat the fast connection as part of the transfer. If the paired authenticated network socket already exists, it is reused. Otherwise, the existing paired BLE link requests an Android local-only hotspot, exchanges its generated credentials in an AES-GCM `transferNetwork` envelope, and helps the Mac establish a new authenticated network session. File bytes never pass through the BLE control queue. Users do not need to select the temporary SSID, enter its password, or press a separate hotspot Connect button.

The transfer-network messages use the pairing's existing network encryption key, a bounded versioned payload, and a UUID for a single active lease. Credentials stay in memory and are neither logged nor persisted by androp. Initial creation is BLE-only. Once the same pairing has authenticated over Wi-Fi, keep-alive/stop/error controls can use Wi-Fi during a BLE dropout, so an otherwise healthy file transfer can continue. BLE may resume control after authentication for the same pairing; an unrelated device or stale lease cannot take over a pending selection.

Network setup is bounded, and keep-alives exist only while a transfer owns the lease. Android hotspot startup expires after 30 seconds, the Mac setup attempt after 120 seconds, and Android outgoing setup waiting after 90 seconds. An idle lease expires after 90 seconds. Pause, explicit disconnect, cancellation, completion, pairing changes, or losing both transports clean up the owned temporary network. Cleanup respects a network the user manually selected and does not disable the user's existing internet hotspot.

Android asks for Nearby Wi-Fi devices on Android 13+ or Location permission on older supported versions. macOS asks for Location access when required for scanning. A first Mac-originated attempt may require opening the phone app to accept its normal permission prompt and retrying. No ADB, wireless debugging, root helper, or password entry is needed for the temporary transfer path. Existing receiving confirmation/PIN prompts remain applicable.

The local-only connection has no internet access; it can temporarily replace the Mac's current Wi-Fi network. Samsung firmware or an already-active hotspot can refuse local-only startup. The error flow retains selected files and offers retry or shared Wi-Fi. It cannot disable global Data Saver, and it does not add an Android row to Apple's native Instant Hotspot menu. See [Automatic Wi-Fi for file transfers](HOTSPOT_CONNECTION_REVIEW.md) for lifecycle details and the separate saved-password internet-hotspot action.

Preview 5 adds protocol/cryptographic and transfer-lifecycle regression coverage. Consult the release verification files for completed build and test results; physical Samsung/Mac local-hotspot behavior, radio reliability, and battery usage are not yet hardware-validated.
