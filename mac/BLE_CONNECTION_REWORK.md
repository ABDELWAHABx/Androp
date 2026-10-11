# Bluetooth connection rework: a persistent link and one-tap hotspot

This pass reviews the whole Bluetooth (BLE) connection system on both apps and makes it reconnect by itself, notice a dead link and recover, and turn on the phone's hotspot in one tap. The work is in tiers, ordered by how easy each item is to build. Tiers 1 and 2 are implemented. Tier 3 lists larger work for later.

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
  - **Phone:** a phone that has seen pings drops a Mac it hasn't heard from in 4 minutes, then advertises again. The limit is generous because App Nap can stretch Mac timers.
  - **Older builds:** each side enforces the heartbeat only after the other side has shown it supports it. A new phone paired with an old Mac (or the reverse) behaves exactly as before.
- **One-tap hotspot from the phone.** A **Hotspot · Connect Mac** card appears on the Android home screen while the Mac is connected, and the same button is in **Settings → Hotspot**. It sends `phoneHotspotOffer`, which runs the Mac's normal Connect: turn Hotspot on, then join it with the password saved on the Mac.
  - On Android 16 with Modify system settings allowed, nothing else is needed.
  - Otherwise the button opens the phone's Hotspot page, and the Mac keeps looking for about a minute and joins as soon as Hotspot comes on.
  - On first use, the Mac guesses the hotspot from its saved networks, as its own Hotspot row does.

## Tier 3: larger work (not implemented)

Ordered by ease. Each needs physical-device testing or a product decision before it is built.

1. **Keep the Mac out of App Nap while BLE is authenticated** (`ProcessInfo.beginActivity`). This keeps heartbeat timing exact, so the phone's 4-minute limit could shrink. Measure the power cost first.
2. **Auto-join the phone's hotspot when the Mac loses internet** (opt-in, like Instant Hotspot). The pieces exist: BLE stays up, and Connect works from either side. It needs a Mac reachability trigger and a user setting.
3. **LE bonding (Secure Connections).** macOS could then resolve the phone's rotating private address. That gives the Mac a stable peer identity, lets it reconnect with a no-timeout pending `connect()` at zero scanning cost, and adds link-layer encryption. It adds a system pairing prompt and bond-loss handling on both platforms.
4. **L2CAP connection-oriented channel** (Android 10+ `listenUsingInsecureL2capChannel`, macOS `CBL2CAPChannel`). Roughly 5–10× GATT throughput, so small files and screenshots could go without setting up Wi-Fi.
5. **Hotspot on Android 15 and older.** There is no public API. The only routes are a Shizuku/ADB-granted permission or an accessibility service. Both conflict with the project's no-ADB, no-root rule, so the phone-side button opens Hotspot settings instead.

## Using the hotspot now

1. **Android 16, once:** open androp → **Settings → Hotspot → Allow** (Modify system settings).
2. **Mac, once:** join the phone's hotspot from the Wi-Fi menu, so macOS saves its password.
3. **Then, from either device:**
   - **Mac:** press **Connect** in the Hotspot row.
   - **Phone:** tap **Connect Mac** on the home screen.

   Bluetooth carries the request and the answer, so this works with no shared Wi-Fi network.

## Compatibility

- **Wire protocol:** only new message types are added (`blePing`, `blePong`, `phoneHotspotOffer`). An older peer ignores them, and every existing message is unchanged.
- **Old phone, new Mac:** the phone ignores pings, so the Mac never enforces the heartbeat.
- **New phone, old Mac:** the Mac never pings, so the phone never enforces its watchdog.
- **Hotspot answers on Bluetooth:** an older Mac already routes `phoneHotspotState` from BLE to the same handler.

## Verification

- **Android:** new radio-free tests in `BleLinkPolicyTest` pin the advertising speeds, the retry backoff, setup retries that never stop, and the heartbeat-only silence rule.
- **Mac:** three new BLE lifecycle regressions cover the reconnect burst, its end on manual disconnect and pause, and the heartbeat rules, including that the Mac gives up well before the phone's limit.
- **Not yet tested on hardware:** radio behavior, reconnect time and battery impact. In particular, the Samsung S21 FE / One UI 8 and M1 Mac pair named in the README.
