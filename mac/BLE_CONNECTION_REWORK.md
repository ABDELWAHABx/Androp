# Bluetooth connection rework: a persistent link and one-tap hotspot

This pass reviews the whole Bluetooth (BLE) connection system on both apps and makes it reconnect by itself, notice a dead link and recover, and turn on the phone's hotspot in one tap. The work is in tiers, ordered by how easy each item is to build. All three tiers are implemented.

## How the connection works

| Stage | Phone (Android, GATT server) | Mac (CoreBluetooth central) |
| --- | --- | --- |
| 1. Advertise / discover | `BleGattServer` adds 4 services, then advertises the system service UUID plus a rotating 5-byte proof of the pairing token | `BLECentralManager` scans for that UUID in 10-second windows. It connects to an advertiser whose proof matches, or to the remembered peer |
| 2. Connect | Accepts the link. A central that uses androp's service becomes an auth candidate with a 30-second deadline | 10-second connect timeout, then service and characteristic discovery and 9 notification subscriptions, under a 15-second timer |
| 3. Authenticate | Answers the Mac's nonce with a proof and checks the Mac's proof. The token is never sent | Sends a hello nonce, checks the phone's proof, then sends its own |
| 4. Session | One outstanding notification at a time. Priority traffic jumps the queue. State messages replace older queued copies | Write-without-response queue with flow control. Priority characteristics jump the queue |
| 5. Routing | `WebSocketUtil.sendMessage`: Wi-Fi socket first, BLE second | `WebSocketServer.sendOverBLE` for control types. Hotspot control always prefers BLE |
| 6. Loss / recovery | On disconnect: restart advertising | On disconnect: tear down, wait 3 s, then scan windows with 5 → 30 s rests |

Wi-Fi and BLE run side by side. BLE carries control messages: clipboard, media, notifications, keyboard, hotspot and transfer setup. Files and the trackpad stay on Wi-Fi. A file sent while only BLE is up first sets up a temporary Wi-Fi link.

## What made it unstable

| # | Problem | Effect | Fixed in |
| --- | --- | --- | --- |
| 1 | The phone sent hotspot answers over Wi-Fi first. Turning Hotspot on drops the phone's own Wi-Fi on most phones, and the socket goes with it | Connect on the Mac waited 25 s for nothing, then asked you to turn Hotspot on when it was already on | Tier 1 |
| 2 | An advertising failure (another app using every advertiser slot, an internal stack error) was never retried | The phone stayed invisible to the Mac until Bluetooth was toggled or the app reopened | Tier 1 |
| 3 | GATT service setup gave up after 5 quick retries | Same: invisible until the next radio event | Tier 1 |
| 4 | After a drop, the Mac waited 3 s, then scanned 10 s and rested 5 → 30 s. The phone advertised only once a second (low power) | Reconnecting often took 15–45 s, even with the phone next to the Mac | Tier 1 |
| 5 | One failed notification subscription stalled authentication | Authentication sat until the 15-second timer tore the link down and started over | Tier 1 |
| 6 | Connect sent `status`, then `enable`: two BLE round trips | Slower Connect, with one more step that could fail | Tier 1 |
| 7 | No liveness check. A half-dead link (phone app restarted, stack glitch) still looked connected | The phone stopped advertising because it thought it had a Mac, so the Mac could never find it again | Tier 2 |
| 8 | Hotspot could only be started from the Mac | You needed the Mac's window to get it online through the phone | Tier 2 |

## Tier 1: small changes, high impact (implemented)

- **Hotspot answers go over Bluetooth.** `HotspotControlManager.deliver` sends every `phoneHotspotState` over BLE when it is up, and over Wi-Fi too while that socket is open. The Mac matches answers by request ID, so it ignores the second copy.
- **Connect is one round trip.** The Mac sends `enable` directly. The phone answers `enabled` at once when Hotspot is already on, and puts its one-tap prompt in the dashboard notification when it can't switch Hotspot itself. Phones running the older app answer `enable` the same way.
- **Advertising retries itself.** Temporary failures retry after 2 s, 5 s, 15 s, 30 s, then once a minute. `FEATURE_UNSUPPORTED` does not retry. Pause, stop and an authenticated Mac cancel the retry.
- **Service setup never gives up.** It retries quickly 5 times, then once a minute, until it works or Bluetooth sync stops.
- **Fast reconnect window, on both sides.** For 60 s after the server starts or loses its Mac, the phone advertises in BALANCED mode (about 4× a second) instead of LOW_POWER. For 60 s after a working link drops, the Mac wakes, Resume runs, or the Mac's Bluetooth comes back, the Mac rescans after 0.5 s instead of backing off. Outside that minute, the existing battery-saving backoff applies unchanged. During a visible QR code, the phone uses LOW_LATENCY.
- **Subscription retry.** Each notification subscription that fails is retried once, so authentication isn't left waiting on it.

## Tier 2: moderate changes (implemented)

- **Heartbeat.** While authenticated, the Mac writes a tiny `blePing` every 20 s, and the phone answers `blePong`.
  - **Mac:** after 3 pings with nothing at all received, the Mac drops the link and reconnects, about 80 s after the last data.
  - **Phone:** a phone that has seen pings drops a Mac it hasn't heard from in 160 s, then advertises again. Tier 3 keeps the Mac out of App Nap, so its pings arrive on time.
  - **Older builds:** each side enforces the heartbeat only after the other side has shown it supports it. A new phone paired with an old Mac (or the reverse) behaves exactly as before.
- **One-tap hotspot from the phone.** A **Hotspot · Connect Mac** card appears on the Android home screen while the Mac is connected, and the same button is in **Settings → Hotspot**. It sends `phoneHotspotOffer`, which runs the Mac's normal Connect: turn Hotspot on, then join it with the password saved on the Mac.
  - On Android 16 with Modify system settings allowed, nothing else is needed.
  - Otherwise the button opens the phone's Hotspot page, and the Mac keeps looking for about a minute and joins as soon as Hotspot comes on.
  - On first use, the Mac guesses the hotspot from its saved networks, as its own Hotspot row does.

## Tier 3: larger work (implemented)

Hotspot control for Android 15 and older is out of scope. The target phone runs One UI 8 (Android 16), which has the public API.

- **App Nap exemption.** While a phone is authenticated over BLE, the Mac holds a `userInitiatedAllowingIdleSystemSleep` activity, so App Nap can't stretch the heartbeat and reconnect timers. It doesn't block system sleep. Because the Mac now keeps time, the phone's silence limit drops from 4 minutes to 160 s.
- **Auto-join the hotspot when the Mac is offline** (opt-in: Hotspot row menu → *Join automatically when the Mac is offline*). `PhoneHotspotAutoJoin` watches `NWPathMonitor`. After 10 s with no network, it runs the normal Connect, at most once every 5 minutes.
  - **It doesn't run** while paused or manually disconnected, while Connect is already running, during the local-only transfer network, or when Mac Wi-Fi is switched off.
  - **Limit:** it reacts to having no network at all. A router that is up but has lost its internet connection still looks connected.
- **Instant reconnect through LE bonding** (opt-in: Settings → Nearby → *Instant reconnect*).
  - **Bonding:** after authenticating, the Mac reads an encrypted characteristic (`a1520109`). Android answers that read with "insufficient encryption", so macOS pairs and both devices ask you to confirm once. macOS can then resolve the phone's rotating private address, so the phone keeps one identity.
  - **Reconnecting:** after a drop, the Mac leaves a no-timeout pending `connect()` on the bonded phone, alongside normal scanning. macOS reconnects as soon as the phone is in range, at no scanning cost.
  - **Bond loss:** if the phone forgets the pairing, macOS reports `peerRemovedPairingInformation`. The app then stops relying on the bond and asks you to remove the phone in System Settings → Bluetooth, which the app can't do itself.
  - **Prompts:** a declined prompt isn't repeated for 24 hours.
- **Bluetooth file lane (L2CAP).** The phone listens on an insecure L2CAP channel and publishes its PSM in a readable characteristic (`a152010a`).
  - **When it's used:** if there is no Wi-Fi session, a selection of up to 16 MB goes over this channel instead of starting the temporary hotspot, so the Mac stays on its own Wi-Fi. Bigger selections, and phones or Macs without the lane, keep the existing route.
  - **Who opens the channel:** the Mac always does, since Apple allows only the central to. For phone → Mac, the phone first sends `bleFileOffer` over BLE. The Mac checks it (receiving on, free space, safe name), opens the channel, or answers `bleFileReject`.
  - **Encryption:** the Mac sends the plaintext preamble `[u16 len]["androp-lane:1:" + id]`. Both sides derive that transfer's key as `HMAC-SHA256(pairing key, "androp-file-lane:v1:" + id)` and exchange the same AES-GCM records as the Wi-Fi fast path. The receiver verifies SHA-256, saves to Downloads and answers with a final record.
  - **Who may connect:** the phone accepts the channel only from the authenticated Mac's address and ignores a repeated transfer ID.
  - **Stalls and fallback:** a channel silent for 30 s is closed. If the Mac can't open the channel at all, it falls back to the temporary Wi-Fi route without losing the selection.

## Remote control permission

**Symptom:** after allowing androp in Accessibility, the phone kept showing "On your Mac, allow androp in Accessibility". There were two causes:

1. **The phone wasn't told about the change.** The Mac checked trust only when remote input arrived, and never told the phone when it changed. It now watches the `com.apple.accessibility.api` distributed notification, polls every 2 s while untrusted, and resends the status whenever a phone connects. The phone's screen updates as soon as you switch androp on.
2. **macOS ignored the old switch after an update.** Private builds are ad-hoc signed (`codesign --sign -`), so each update has a new code signature. macOS can show androp switched on while not trusting the new build, and switching it on again doesn't help. The permission sheet now offers **Reset permission**, which runs `tccutil reset Accessibility app.androp.mac`, asks again and opens the Accessibility pane. If the reset is refused, it explains how to remove androp with − and add it again.

The permanent fix for cause 2 is to sign releases with one stable certificate, even a self-signed one. The grant then survives updates.

## Using the hotspot now

1. **Android 16, once:** open androp → **Settings → Hotspot → Allow** (Modify system settings).
2. **Mac, once:** join the phone's hotspot from the Wi-Fi menu, so macOS saves its password.
3. **Then, from either device:**
   - **Mac:** press **Connect** in the Hotspot row.
   - **Phone:** tap **Connect Mac** on the home screen.

   Bluetooth carries the request and the answer, so this works with no shared Wi-Fi network.

## Compatibility

- **Wire protocol:** only new message types (`blePing`, `blePong`, `phoneHotspotOffer`, `bleFileOffer`, `bleFileReject`) and two new read characteristics are added. An older peer ignores them, and every existing message is unchanged.
- **File lane:** used only when the Mac reads a non-zero PSM. With an older peer on either side, Send keeps the temporary Wi-Fi route.
- **Old phone, new Mac:** the phone ignores pings, so the Mac never enforces the heartbeat.
- **New phone, old Mac:** the Mac never pings, so the phone never enforces its watchdog.
- **Hotspot answers on Bluetooth:** an older Mac already routes `phoneHotspotState` from BLE to the same handler.

## Verification

- **Android:** new radio-free tests in `BleLinkPolicyTest` pin the advertising speeds, the retry backoff, setup retries that never stop, and the heartbeat-only silence rule.
- **Android, Tier 3:** `BleFileLaneProtocolTest` pins the key derivation to a shared vector, the preamble format, the size limit and safe file names.
- **Mac:** BLE lifecycle regressions cover the reconnect burst, its end on manual disconnect and pause, the heartbeat rules (including that the Mac gives up well before the phone's 160 s limit), the bond-prompt policy, and that bonding never replaces discovery.
- **Mac, Tier 3:** `run-ble-file-lane-tests.sh` checks the same key vector as Android. `HotspotWiFiPolicyRegression` covers every auto-join condition.
- **Not yet tested on hardware:** radio behavior, reconnect time, battery impact, the macOS and Samsung pairing prompts, and L2CAP throughput. In particular, the Samsung S21 FE / One UI 8 and M1 Mac pair named in the README.
