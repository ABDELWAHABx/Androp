# Automatic Wi-Fi for file transfers

Preview 5 makes network preparation part of Send in both directions. Install both updated apps, pair them once, and enable Bluetooth sync on both. An authenticated Wi-Fi connection is reused when available. Otherwise, the paired BLE connection coordinates a temporary phone Wi-Fi network, the Mac joins it, and the files start after the paired network session has authenticated. You do not need to choose an SSID, enter a password, or press a separate hotspot Connect button for this transfer path.

## Sending files

- **Mac → Android:** choose or drop files, review the selection, and press **Send**. The sheet shows connection progress before file progress. Recoverable connection errors retain the selection for **Review and retry**; a partially completed batch continues with its remaining files.
- **Android → Mac:** share files to androp. The share flow prepares the files once, requests a fast connection when needed, and hands them to the sending service after the same paired Mac authenticates. Permission prompts and screen rotation preserve the pending selection. Retry keeps the staged files; cancellation removes the temporary copies. Existing receiving consent or PIN prompts still apply.
- File bytes use the network, not BLE. Device identity and the pairing key are checked before handing off a selection; a nearby device with a matching display name cannot inherit it.

The temporary connection uses Android's public **local-only hotspot** API. It does not enable cellular tethering, require a mobile data plan, or provide internet access to the Mac. Joining it can temporarily replace the Mac's current Wi-Fi connection. The separate **Phone hotspot → Connect** action remains available when you want the phone's existing internet hotspot instead.

## Permissions and platform limits

Android 13 and newer require **Nearby Wi-Fi devices** permission; older supported Android versions require Location permission and may require Location Services to be enabled. Android-originated sharing asks through the normal system permission dialog. For the first Mac-originated attempt, a background phone app cannot force that dialog onto the screen: the Mac explains that you must open androp on the phone. The resumed phone app requests the permission, then you can retry with the files still selected.

macOS asks for Location access when needed to discover the temporary Wi-Fi network. There is no need to grant root access, use ADB, enable wireless debugging, or install a helper. Denied permissions, unavailable Wi-Fi, and manufacturer restrictions produce an error with a shared-Wi-Fi alternative.

Samsung firmware, carrier policy, or an already-active hotspot can prevent Android from creating the temporary network. androp does not disable or reconfigure the user's existing internet hotspot to work around that failure. Ordinary Android applications also cannot disable global Data Saver. This implementation does not promise that every Samsung configuration supports local-only hotspot operation.

## Coordination, identity, and credentials

The peers exchange a versioned `transferNetwork` envelope with a UUID identifying one transfer-network lease. The inner payload, including generated SSID and password, is encrypted with AES-GCM using the pairing's existing network key. It travels over the authenticated BLE control characteristics. These credentials stay in memory: androp does not log them, persist them, pass them to a shell, or add them to its saved-hotspot preferences.

Initial network creation requires the paired BLE connection. After Wi-Fi authenticates for the same pairing, encrypted keep-alive, stop, and error messages can use that socket if BLE drops. An active file transfer therefore need not fail just because Bluetooth briefly disconnects. A newly authenticated BLE connection for the same pairing can resume carrying lease controls while the paired Wi-Fi session remains valid. Wi-Fi lease-control messages cannot initiate an unsolicited new hotspot or share.

The Mac joins only the supplied WPA2/WPA3 network and waits for a local IPv4 address on the selected Wi-Fi interface. It then proposes that private address and its server port over BLE. Android validates the bounded private-IPv4 endpoint and starts its normal authenticated socket connection. The Mac allows up to three endpoint announcements, 17 seconds apart, so the handoff does not depend solely on mDNS visibility on the phone hotspot.

This new envelope encryption applies to transfer-network coordination. It does not retrofit encryption onto every legacy BLE feature or replace the existing BLE pairing-token protocol with mutual cryptographic authentication.

## Lifetime, cancellation, and power

- A single explicit transfer owns the temporary network. There are no idle hotspot scans, network creation loops, or keep-alives when there is no active lease.
- Android limits local-hotspot startup to 30 seconds. The Mac's complete connection attempt has a 120-second deadline; the Android outgoing-share screen waits up to 90 seconds. These application deadlines stop subsequent work, but cannot forcibly abort a synchronous platform Wi-Fi call already in progress.
- An unused lease expires after 90 seconds. The owning Mac transfer sends a keep-alive approximately every 30 seconds; an Android outgoing share or sending service sends one approximately every 25 seconds. A keep-alive cannot extend Android's initial hotspot-startup deadline. The receiving peer does not keep an abandoned sender's lease alive indefinitely.
- Completion, cancellation, pause, explicit disconnect, a changed pairing, and loss of both usable transports release the owned temporary network. Unexpected BLE loss alone can retain it while the same-key Wi-Fi connection is authenticated. Stop and stale callbacks cannot release another transfer's lease.
- Android closes only its own local-only hotspot reservation. The public API cannot cancel a pending startup request before a reservation is returned; a late reservation belonging to a cancelled attempt is immediately closed.
- On the Mac, background serial Wi-Fi work keeps synchronous CoreWLAN and Keychain calls off the UI thread. Cleanup is tied to the transfer owner and the actual current network. Normal completion can leave the owned temporary network and attempt to restore the previous saved network; it does not override a network the user has already selected. Pause/manual disconnect suppress new restoration scans, Keychain lookups, and association attempts. A previously submitted OS association can still finish before queued cleanup runs.

Cancellation is explicit; a cancelled or failed transfer does not silently start sending later when an unrelated connection appears.

## Existing internet-hotspot joining

For cellular internet, expand **Phone hotspot**, select the phone's exact SSID from **Saved networks** or enter it once, then click **Connect**. androp requests fresh phone hotspot status and, if needed, asks Android to activate the existing hotspot. It waits for actual status confirmation. If Android acknowledges activation before dropping its old Wi-Fi link, the Mac may instead confirm the selected secure hotspot by association.

The Mac obtains the selected SSID's existing password through Apple's Keychain API. The system may ask to authorize Keychain access. Only an item-not-found result triggers a second lookup in the system domain; denial does not cause another authorization prompt. The password is used in memory, and is not logged, saved by androp, or sent to the phone. Missing credentials must first be saved through the normal macOS Wi-Fi interface. androp remembers only the selected SSID for that paired identity.

This saved-network path uses bounded scans and interruptible retries, and distinguishes Wi-Fi association from actual internet availability. Android's ordinary Modify System Settings permission and supported tethering implementation are still required for internet-hotspot activation. Samsung/carrier restrictions and global Data Saver remain outside androp's control.

## Native macOS Wi-Fi menu

Apple's documented [Instant Hotspot](https://support.apple.com/en-gb/109321) uses a nearby iPhone/iPad and an Apple Account or Family Sharing relationship. No documented public API was found for adding a dormant Android device to the native macOS Wi-Fi menu or intercepting its selection. androp supplies its own automatic transfer flow and internet-hotspot Connect action. An actual broadcasting phone network can appear in the native menu normally.

## Public APIs and verification

- [Android local-only hotspot](https://developer.android.com/develop/connectivity/wifi/localonlyhotspot) creates a temporary local network without cellular tethering.
- [CWInterface association](https://developer.apple.com/documentation/corewlan/cwinterface/associate%28to%3Apassword%3A%29) joins a supplied secure network.
- [CWConfiguration.networkProfiles](https://developer.apple.com/documentation/corewlan/cwconfiguration/networkprofiles) lists remembered networks for the separate saved-hotspot flow.
- [CWKeychainFindWiFiPassword](https://developer.apple.com/documentation/corewlan/cwkeychainfindwifipassword%28_%3A_%3A_%3A%29) retrieves a selected saved network's credential for joining or restoration.
- [Apple DTS guidance](https://developer.apple.com/forums/thread/748161) explains Location Services authorization for modern macOS scanning.

Regression coverage includes bounded envelopes and UUIDs, authenticated credential encryption and tamper rejection, Wi-Fi control restrictions, paired-device transfer gating, cancellation, retry selection handling, and temporary-network ownership. Build and packaged-app results are recorded separately in the repository verification files. Local-only hotspot creation, Samsung coexistence restrictions, physical BLE/Wi-Fi handoff, system permission prompts, actual network restoration, and battery impact still require testing on the user's Mac and phone. Simulator or radio-free CI results are not evidence that those hardware paths work.
