# Pairing and connection reliability — Preview 6

The reported Bluetooth-only QR timeout was a real first-pairing gap: the old QR path always opened a Wi-Fi socket, and Bluetooth previously needed credentials exchanged during a Wi-Fi handshake. The Wi-Fi refusal has several possible device/network causes; the code review also found stale QR/form values, configured rather than ready listener endpoints, and reliance on an IPv6 wildcard listener accepting advertised IPv4 addresses. These software defects are corrected; the user's exact radio/firewall conditions have not been reproduced.

## Pairing

Install both Preview 6 apps. On Mac, select **Bluetooth** on the pairing screen and reveal the code. Scan it inside androp on Android, allow Nearby devices and turn on Bluetooth if prompted. Keep the code open and both devices nearby. The two-minute pairing window needs no Wi-Fi, ADB, root or wireless debugging. Cancel, Pause, closing the QR screen and expiry stop pending pairing work.

**Wi-Fi** remains an explicit alternative. Both devices must be able to reach each other on the network. A code is generated only for a running listener; it uses that listener's actual port and bound IPv4 addresses. Changes invalidate old asynchronous QR results. Local Network permission and any firewall rule still apply; the app does not bypass them. The Mac screen shows listener failure and Bluetooth permission/radio guidance instead of only an Android toast.

## Fixes

- Android scanner and deep links share one validated parser. The connection receives the scanned endpoint, name and key directly, rather than waiting and reading an old Compose state snapshot. Legacy QR separators, multiple adapter addresses and escaped Base64 remain supported. QR keys are no longer logged.
- Bluetooth first pairing uses AES-GCM request, response and confirmation messages bound to the QR session and a fresh per-contact nonce. Credentials are not sent in plaintext to unknown advertisers. Small pre-authentication buffers, an expiring window, current-connection checks and a bounded replay ledger reject unrelated, stale and oversized exchanges. Saving the phone's new Mac pairing checks authorization inside the serialized settings transaction.
- Both the new proof and reconnect authentication support the minimum 20-byte ATT payload. Packet framing avoids Android-rejected prepared writes.
- The Mac explicitly binds IPv4, matching the addresses it publishes. Restart/Refresh retain the configured port. Stopped/starting/failed listeners have no advertised endpoint. Bonjour and UDP use actual ready bound addresses; Android replaces stale mDNS addresses and ports instead of accumulating them.
- Bonjour/NSD names now obey UTF-8 byte limits, including service prefixes and TXT keys. Long or Unicode device names are shortened safely, with a stable suffix when needed, instead of silently failing discovery registration.
- Initial Wi-Fi sync uses the current QR key and exact socket generation. Timeout, close and terminal failure invalidate callbacks; a late handshake cannot revive a timed-out socket. Failure does not silently persist a manual disconnect.
- A socket can use an attached Wi-Fi/Ethernet subnet when Android chooses mobile data for internet. An active VPN retains routing control. No process-wide network binding is used.
- Transfer setup waits for the correct listener before offering its endpoint over BLE. It retains the existing setup deadline and cleanup behavior.

## Verification and limits

Automated coverage includes shared cross-platform AES-GCM fixtures, wrong keys, tampering, session/nonce mismatch, replay, minimum-MTU chunking, QR formats, route selection, mDNS bounds, BLE lifecycle and listener cleanup. The packaged Mac lifecycle test opens a real IPv4 WebSocket on the configured port, rejects a wrong-key handshake and receives encrypted MacInfo with the correct key, on each Resume cycle. Exact results and artifact hashes are recorded in `../verification/android-and-source-checks.json` after the builds finish.

Physical Samsung S21 FE / One UI 8 and M1 Mac radio pairing, system permission prompts, access-point isolation, firewall behavior, hotspot handoff and battery impact remain device checks. CI's loopback handshake proves the app protocol and listener, not reachability across a particular Wi-Fi network.
