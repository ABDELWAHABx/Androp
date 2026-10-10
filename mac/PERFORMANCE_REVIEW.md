# androp bug and performance review

Private development changes to the Mac and Android clients, reviewed on 2026-10-10 with six parallel agents. This records the problems found and the implemented repairs; it does not certify that every possible bug is gone.

## Background work and pause

| Problem found | Change |
| --- | --- |
| Paused clients could restart discovery, advertising, or connections from delayed callbacks and service entry points. | Centralized Android shutdown and persisted pause guards; Mac Pause/Resume control cancels pending connections, discovery, transfers, sockets, media, mirroring, and monitoring. |
| Android sync child jobs and pending clipboard/call tasks survived shutdown. | Cancel the complete work hierarchy and reject stale work after synchronous queries. Stop loading haptics on pause or when hidden. |
| Android had permanent high-performance Wi-Fi locking, frequent pings and battery polling. | Removed the permanent Wi-Fi lock; pings and battery checks use 30-second intervals. Backoff reaches 120 seconds, and active discovery uses finite bursts. |
| Parallel WebSocket attempts and stale callbacks could replace a newer connection or reconnect after pause. | Connection epochs, synchronized registration, cancelled deadlines, and pause checks protect connection ownership. |
| Android service startup could skip initial synchronization. | Corrected initialization and scanning/connected service transitions. Active foreground sync remains restartable; a persisted pause stops a restarted service. |
| Mac timers ran without a connected phone; discovery pruning timers could duplicate. | Gate clipboard and notification monitoring on an active connection, stop them on pause/disconnect, and make discovery timers idempotent. |
| Mac sleep/wake callbacks could undo a deliberate pause. | Temporary sleep pause preserves the user's prior choice. Fixed the termination delegate signature so cleanup executes. |
| Congested Mac socket writes held the shared state lock and could stall UI/pause. | Bounded serial write queue; close actual sockets outside the state lock. |

## Transfers and BLE

| Problem found | Change |
| --- | --- |
| Receiver acknowledged a transfer before opening destination files. | Acknowledge only after destinations are ready; preserve receive backpressure through disk writes. |
| Small framing writes, synchronous disk operations, and frequent progress updates caused stalls. | Buffer and serialize frames, move Mac chunk disk IO off the main thread, and throttle progress UI updates. |
| Missing deadlines, polling retries, and cancellation leaks left transfers running. | Finite socket/process deadlines, condition-driven bounded retries, complete socket/job/executor cleanup, and partial-file cleanup. |
| Malformed offsets, oversized frames, bad checksums or unsafe storage paths could corrupt output or crash. | Bounds and size validation, streaming checksum verification, safe path resolution, and throwing crypto failures. |
| QuickShare pause stopped a flag but left listeners/discovery alive. | Suspend the TCP listener, discovery and active transfers; recreate them on resume while retaining the preference. |
| WebDAV operations raced and could remove directories unsafely. | Serialized cancellable mount operations, finite process deadlines and safer cleanup. |
| Android GATT callbacks released multiple competing senders, interleaving or dropping fragments. | One bounded serialized notification queue, peer-specific authentication/reassembly, and control-message prioritization. |
| Mac wrote BLE chunks without respecting CoreBluetooth backpressure. | Resume queued writes when CoreBluetooth reports capacity. |
| Android BLE packets exceeded ATT payload capacity by three bytes. | Correct MTU accounting; validate fragments, bound reassembly, and expire incomplete messages. |
| Disconnect restarted BLE advertising even during pause. | Pause closes GATT work; restart paths honor pause state on both clients. |
| Compact battery formats differed between clients. | Accept the matching battery format so immediate BLE battery updates are visible. |
| BLE notifications discarded original IDs and actions, so updates duplicated entries and dismissals could not match the phone. | Preserve bounded ID/action/priority metadata, update the same Mac notification, and route phone dismissals through BLE. |

## Media, notifications and controls

| Problem found | Change |
| --- | --- |
| Empty/placeholder sessions displayed a player; stale tracks could return on battery updates. | Normalize absent media, clear cached snapshots, hide absent players without reserving layout space, and collapse genuine paused tracks. |
| Repeated artwork encoding/decoding, blurred artwork and animated progress consumed work while idle. | Bounded artwork caches, transmit unchanged artwork less often, remove continuous animation, and tick only an expanded foreground player. |
| Media helper streams could repeatedly restart or deliver stale updates. | Serialized start/stop, cancellation generations, bounded output, restart backoff, and immediate metadata/state updates with coalesced timeline updates. |
| Silent Mac audio and Android media services could remain active without playback. | Stop silent audio on pause/clear; stop idle Android media directly without starting an empty foreground service. |
| Playback timestamps drifted and seek events could be missed. | Project from the source playback timestamp, detect seek discontinuities, freeze paused progress, and bound timestamp compensation. |
| Notification listener reconnect cancelled its permanent scope and could kill independent sync. | Separate listener and work lifetimes; reconnect restores work without tearing down unrelated transports. |
| Notifications with identical bodies were dropped even with different IDs; updates were lost. | Bounded successful-send fingerprints keyed by notification identity, including titles, actions and progress. |
| Quotes, tabs and backslashes broke JSON or clipboard text; whitespace normalization altered notification text. | Escape every string and control character; remove JSON formatting only outside strings. |
| Remote control used a perpetual 100 Hz loop and unbounded movement queues. | Event-driven, frame-paced delta batching with no idle polling; stop input when hidden or backgrounded. |
| Mouse release could be cancelled; keyboard modifiers, repeats, and symbol keys were wrong. | Queue click edges together, cancel repeats, clear modifiers, and send Shift for shifted symbols. |
| Trackpad/control layout and player sizing wasted space. | Trackpad below controls in portrait, to their right in wide layouts; smaller player padding, adequate touch targets and scrollable controls. |
| Volume dragging sent every intermediate value. | Preview locally and send the final value on release. |
| Android static checks found tile launch crashes on API 34+, missing vibration permission and unsafe notification permission assumptions. | Use version-gated PendingIntent tile launches, declare vibration permission and check notification permission centrally with revocation handling. |
| Android resource/manifest checks found API 31 splash attributes in API 30 resources, ungrantable permissions and missing optional camera declaration. | Add API-specific splash resources, remove ungrantable requested permissions, retain the service binding requirement and declare camera hardware optional. |
| Outbound temporary copies trusted ContentProvider filenames. | Sanitize to a safe basename and enforce canonical cache-directory containment. |

## Validation and practical limits

Android compilation and targeted JVM regression tests are run before packaging. Tests cover BLE fragmentation, socket framing, storage paths, connection ownership, media visibility, keyboard symbols, notification deduplication and JSON round trips. APK identity and debug signature are checked. Swift parser checks compare changed files against upstream; this is not Swift type checking or a native Mac build. A Foundation-only media regression harness is included in `Tests/NowPlayingInfoRegression.swift` for a Swift-enabled machine.

Verified in this workspace: Android debug and optimized release APKs assembled; 56 unit tests passed with no failures/errors; Android lint passed with zero errors, 250 warnings and 10 hints. Debug and locally signed optimized APK identity and signatures verified. All 82 changed Swift files parsed without new errors (four unchanged upstream parser limitations). Six Mac keep-awake policy tests were added but could not run without a Swift compiler. Structured resource/configuration files parsed, both licenses remain unchanged. Native Mac compilation, device behavior and power consumption remain unverified.

This Linux workspace cannot verify native Mac compilation, real GATT throughput, device rendering, pairing or battery consumption. Use both updated clients for device testing. BLE remains a limited-bandwidth fallback; it is not the file-transfer or pointer-control transport.

Android lint warnings are retained for review rather than hidden by a baseline. They include unused resources, dependency update suggestions, vector/icon cleanup, API compatibility simplifications and application-context singleton warnings. Local WebSocket networking intentionally permits cleartext transport with application-layer payload encryption; replacing it with TLS and changing pairing is a separate protocol change. The battery-optimization exemption remains an explicit user choice for continuous background sync.

## Device checks still needed

1. Pair both androp clients, then pause from each supported entry point. Confirm sockets, discovery, transfers and media stop; lock the phone and sleep/wake the Mac; confirm a deliberate pause stays paused.
2. Resume and reconnect over Wi-Fi and BLE. Exercise BLE-only notification updates, dismissals, media controls, long clipboard text and Bluetooth interruptions.
3. Send large and multiple files in both directions; cancel midway, interrupt Wi-Fi, retry, and compare checksums. Check that failed files are cleaned up and the UI stays responsive.
4. Stop all Mac playback, reopen Android, and confirm no player or blank space. Pause a real track, seek, change artwork, then resume and check position/controls.
5. Check portrait, landscape and small-window trackpad/keyboard operation, including rapid clicks and navigation during input.
6. Compare Energy Log/Instruments on Mac and Android Battery Historian/Profiler over equal active, idle and paused periods. No measured power-saving percentage is claimed yet.
