# Android lifecycle and input review

This section covers Android service startup/pause, the notification dashboard,
Find Phone, and pairing/navigation. It does not diagnose the supplied macOS
crash report; that report requires the macOS stack and native build validation.

## Repairs

- Foreground dashboard acquisition now returns success. A framework rejection
  during `onCreate` or `onStartCommand` rolls back only that service's owner,
  logs the actual failure and stops the service instead of crashing the process
  or leaving a phantom running dashboard. Callers must check that result before
  installing listeners, opening servers or accepting transfer work.
- Sync-service shutdown is dispatched to Main to serialize it with startup jobs.
  Stopping cancels startup as well as discovery/WebDAV jobs, and stale WebDAV
  emissions cannot open a server while pausing. Network-thread flags are volatile.
- Pause attempts every independent cleanup even if an Android API throws. A
  failed observer removal no longer prevents later socket, timer, discovery or
  service shutdown. Pause state is set before teardown, so entry points stop
  accepting new background work immediately.
- Android/Samsung Live Update construction now falls back to the regular
  dashboard if the OEM implementation rejects promotion. Notification posting
  failures are logged without killing the state collector.
- Pairing links are bounded and validated before connection setup. Invalid ports,
  missing endpoints, malformed escapes, user-info and oversized payloads produce
  an invalid-link message instead of crashing `MainActivity` while reading an
  externally supplied URI. Invalid scans leave the dashboard usable. Both the
  upstream repeated `?` query separator and standard `&` are supported.
- Wake-up service binding/client registration and shutdown share a lifecycle
  lock, preventing a delayed startup from leaving an open listener or accepted
  client after pause. A bind failure stops the service. Framework-denied starts
  are logged without crashing their caller.
- Wake-up requests have a total read deadline, bounded header count/aggregate
  bytes, and a bounded body. Duplicate/negative/oversized content lengths and
  unsupported chunked encoding are rejected. A client cannot keep one of the
  bounded worker slots busy indefinitely by trickling headers.

## Regression checks

All 72 JVM tests passed in the integrated build, including thirteen added cases for shutdown continuation, pairing input and bounded wake-up headers, and three added transfer shutdown cases. Debug and optimized release APKs assembled; lint completed with zero errors, 250 warnings and 10 hints.

Physical permission revocation, rapid pause/resume, Samsung Live Update behavior,
Find Phone sound/vibration policies, background process eviction and battery
measurements still require device testing. JVM tests do not simulate those APIs.

## Feature inventory

No user-facing "Soon" or "Coming soon" feature labels exist in the Android
Kotlin/XML sources reviewed. Two TODO comments concern captured-image notes
integration and call retry implementation; they are not visible coming-soon
controls. The separate macOS settings inventory should drive implementation of
the placeholders reported by the user.
