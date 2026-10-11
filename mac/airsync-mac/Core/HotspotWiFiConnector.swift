import Foundation
import Combine
import CoreWLAN
import CoreLocation
import Security
import Darwin

/// Uses only the user-selected SSID's existing Keychain credential. No password
/// is persisted by androp, logged, passed to a subprocess, or sent to the phone.
nonisolated enum HotspotWiFiWorker {
    static let queue = DispatchQueue(label: "app.androp.hotspot-wifi", qos: .userInitiated)
    // All reads/writes are asserted onto this serial worker queue.
    nonisolated(unsafe) private static var temporaryOwnership = TemporaryWiFiOwnership()

    static func savedNetworks() -> [String] {
        let profiles = CWWiFiClient.shared().interface()?.configuration()?.networkProfiles.array ?? []
        return Array(Set(profiles.compactMap { ($0 as? CWNetworkProfile)?.ssid }
            .filter { HotspotWiFiPolicy.validSSID($0) })).sorted()
    }

    /// Read only the interface associated with the selected hotspot. Wait
    /// briefly for DHCP; never send an unrelated VPN/Ethernet address to Android.
    static func joinedIPv4(ssid: String, attempt: HotspotWiFiAttempt) -> String? {
        // Association can return before the DHCP lease is ready.
        attempt.waitForRetry()
        for index in 0..<6 {
            guard !attempt.isCancelled, let wifi = CWWiFiClient.shared().interface(),
                  wifi.ssid() == ssid, let interfaceName = wifi.interfaceName else { return nil }
            if let address = localIPv4(interface: interfaceName) { return address }
            if index < 5 { attempt.waitForRetry() }
        }
        return nil
    }

    private static func localIPv4(interface: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr,
                  Int32(address.pointee.sa_family) == AF_INET,
                  String(cString: entry.pointee.ifa_name) == interface else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let value = String(cString: host)
            if HotspotWiFiPolicy.validLocalIPv4(value) { return value }
        }
        return nil
    }

    static func currentSSID() -> String? { CWWiFiClient.shared().interface()?.ssid() }

    static func joinTemporary(ssid: String, password: String, attempt: HotspotWiFiAttempt, owner: UUID) -> (String?, String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !attempt.isCancelled, HotspotWiFiPolicy.validSSID(ssid), (8...63).contains(password.utf8.count),
              let wifi = CWWiFiClient.shared().interface(), wifi.powerOn() else {
            return (nil, "Turn on Mac Wi-Fi and try Send again.")
        }
        // Capture restoration state before submitting any asynchronous-to-us
        // CoreWLAN work. Cancel does not depend on a later main-queue callback.
        temporaryOwnership.begin(owner: owner, ssid: ssid, currentSSID: wifi.ssid())
        for index in 0..<6 {
            guard !attempt.isCancelled else { return (nil, "Connection cancelled.") }
            if wifi.ssid() == ssid { break }
            if let networks = try? wifi.scanForNetworks(withName: ssid),
               let network = networks.filter({ $0.ssid == ssid &&
                   ($0.supportsSecurity(.wpa2Personal) || $0.supportsSecurity(.wpa3Personal) || $0.supportsSecurity(.wpa3Transition)) })
                .max(by: { $0.rssiValue < $1.rssiValue }) {
                guard !attempt.isCancelled, temporaryOwnership.willAssociate(owner: owner) else {
                    return (nil, "Connection cancelled.")
                }
                // CoreWLAN may finish a submitted association after cancellation;
                // the single owner-bound release will clean up that result.
                do { try wifi.associate(to: network, password: password) }
                catch { return (nil, "Mac couldn't join the temporary Wi-Fi network. Check Location access and retry Send.") }
                break
            }
            if index < 5 { attempt.waitForRetry() }
        }
        guard !attempt.isCancelled, wifi.ssid() == ssid else { return (nil, "Temporary Wi-Fi wasn't found. Keep the phone nearby and retry Send.") }
        guard let address = joinedIPv4(ssid: ssid, attempt: attempt) else { return (nil, "Wi-Fi connected but no local address was assigned. Retry Send.") }
        return (address, "Connecting to the paired phone…")
    }

    /// Called once by the coordinator, never from a stale join completion.
    /// A cancelled cleanup can disconnect its own temporary network, but starts
    /// no restoration scans, Keychain lookups, or associations.
    static func releaseTemporary(owner: UUID, attempt: HotspotWiFiAttempt) {
        dispatchPrecondition(condition: .onQueue(queue))
        let wifi = CWWiFiClient.shared().interface()
        guard let release = temporaryOwnership.release(owner: owner, currentSSID: wifi?.ssid(),
                                                       cancelled: attempt.isCancelled) else { return }
        if release.disconnect { wifi?.disassociate() }
        guard !attempt.isCancelled, let previousSSID = release.restoreSSID,
              HotspotWiFiPolicy.validSSID(previousSSID) else { return }
        // Reuse the coordinator's token: Pause or a pairing change cancels
        // restoration work already queued behind a synchronous CoreWLAN call.
        // A new transfer does not cancel it, so the user's Wi-Fi is still restored.
        _ = join(ssid: previousSSID, attempt: attempt, onlyWhileUnassociated: true)
    }

    static func join(ssid: String, attempt: HotspotWiFiAttempt, onlyWhileUnassociated: Bool = false) -> String {
        guard HotspotWiFiPolicy.validSSID(ssid), !attempt.isCancelled else { return "Connection cancelled." }
        guard let wifi = CWWiFiClient.shared().interface(), wifi.powerOn() else {
            return "Turn on Wi-Fi on your Mac, then try Connect again."
        }
        if wifi.ssid() == ssid { return "Already connected to your phone's Wi-Fi. Internet access depends on the phone and carrier." }
        func mayContinue() -> Bool {
            !attempt.isCancelled && (!onlyWhileUnassociated || wifi.ssid() == nil || wifi.ssid() == ssid)
        }
        guard mayContinue() else { return "Wi-Fi changed. Keeping the current network." }
        let started = ProcessInfo.processInfo.systemUptime
        var network: CWNetwork?
        for index in 0..<6 {
            guard mayContinue() else { return "Connection cancelled or Wi-Fi changed." }
            guard HotspotWiFiPolicy.mayRetry(attempt: index, elapsed: ProcessInfo.processInfo.systemUptime - started,
                                            cancelled: attempt.isCancelled) else { break }
            do {
                let matches = try wifi.scanForNetworks(withName: ssid)
                // Never downgrade to an open lookalike with the same name.
                network = matches.filter {
                    $0.ssid == ssid && ($0.supportsSecurity(.wpa2Personal) ||
                        $0.supportsSecurity(.wpa3Personal) || $0.supportsSecurity(.wpa3Transition))
                }.max { $0.rssiValue < $1.rssiValue }
            } catch {
                if index == 5 { return "macOS could not scan for the hotspot. Check Wi-Fi and androp's Location access, then retry." }
            }
            if network != nil { break }
            if index < 5 { attempt.waitForRetry() }
        }
        guard mayContinue() else { return "Connection cancelled or Wi-Fi changed." }
        guard let network else {
            return "The selected WPA2/WPA3 hotspot wasn't found. Check its Wi-Fi name, phone hotspot settings and Mac Location access."
        }
        guard let ssidData = network.ssidData else { return "macOS did not provide the hotspot identity. Check Location access." }
        var password: NSString?
        defer { password = nil }
        // Only try the other domain when the item does not exist. A denial or
        // cancelled Keychain prompt must not trigger another authorization prompt.
        var status = CWKeychainFindWiFiPassword(.user, ssidData, &password)
        if status == errSecItemNotFound && mayContinue() {
            status = CWKeychainFindWiFiPassword(.system, ssidData, &password)
        }
        guard mayContinue() else { return "Connection cancelled or Wi-Fi changed." }
        guard status == errSecSuccess, let savedPassword = password as String?, !savedPassword.isEmpty else {
            return status == errSecItemNotFound
                ? "No saved password was found for this hotspot. Join it once in the Mac Wi-Fi menu and save its password, then retry."
                : "macOS did not allow access to the saved Wi-Fi password. Allow androp's Keychain request, or join using the Mac Wi-Fi menu."
        }
        do {
            guard mayContinue() else { return "Connection cancelled or Wi-Fi changed." }
            try wifi.associate(to: network, password: savedPassword)
            if attempt.isCancelled { return "Cancelled. macOS may have completed the Wi-Fi connection already." }
            return wifi.ssid() == ssid
                ? "Connected to your phone's Wi-Fi. Internet access depends on the phone and carrier."
                : "macOS accepted the connection but hasn't confirmed the selected network. Check the Wi-Fi menu."
        } catch {
            return "macOS couldn't join the hotspot with its saved password. Check the password in the Mac Wi-Fi menu and retry."
        }
    }
}

@MainActor
final class HotspotWiFiConnector: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = HotspotWiFiConnector()
    @Published var ssid = ""
    @Published private(set) var savedNetworks: [String] = []
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    private let location = CLLocationManager()
    private var attempt: HotspotWiFiAttempt?
    private var awaitingPermission = false
    private var joining = false
    private var permissionTimeout: DispatchWorkItem?
    private var pauseObserver: AnyCancellable?
    private var phoneID: String?
    private var bluetoothPeer: String?
    private var requestedSSID = ""
    private var loadingNetworks = false

    private override init() {
        super.init()
        location.delegate = self
        pauseObserver = AppState.shared.$isSyncPaused.receive(on: DispatchQueue.main).sink { [weak self] paused in
            if paused { self?.cancel() }
        }
    }

    func selectPhone() {
        guard !isBusy else { return }
        let id = AppState.shared.device?.deviceId
        if id != phoneID {
            phoneID = id
            let names = UserDefaults.standard.dictionary(forKey: "hotspotWiFiNames") as? [String: String] ?? [:]
            ssid = id.flatMap { names[$0] } ?? ""
            message = nil
        }
    }

    func loadSavedNetworks() {
        selectPhone()
        guard !loadingNetworks, !isBusy else { return }
        loadingNetworks = true
        HotspotWiFiWorker.queue.async {
            let names = HotspotWiFiWorker.savedNetworks()
            DispatchQueue.main.async { [weak self] in
                self?.savedNetworks = names
                self?.loadingNetworks = false
            }
        }
    }

    func connect() {
        guard !isBusy, !AppState.shared.isSyncPaused, let id = AppState.shared.device?.deviceId,
              PhoneHotspotManager.shared.pendingAction == nil, HotspotWiFiPolicy.validSSID(ssid) else { return }
        phoneID = id
        bluetoothPeer = PhoneHotspotTransport.bluetoothPeer
        requestedSSID = ssid
        var names = UserDefaults.standard.dictionary(forKey: "hotspotWiFiNames") as? [String: String] ?? [:]
        names[id] = ssid
        UserDefaults.standard.set(names, forKey: "hotspotWiFiNames")
        let token = HotspotWiFiAttempt()
        attempt = token
        isBusy = true
        switch location.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: activatePhone(token)
        case .notDetermined:
            awaitingPermission = true
            message = "Allow Location access so macOS can find your hotspot."
            location.requestWhenInUseAuthorization()
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.attempt === token, self.awaitingPermission else { return }
                self.finish(token, "Location permission is still needed. Allow androp in Privacy & Security → Location Services, then retry.")
            }
            permissionTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
        default:
            finish(token, "Allow androp in System Settings → Privacy & Security → Location Services, then retry Connect.")
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self, self.awaitingPermission, let token = self.attempt else { return }
            switch self.location.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                self.awaitingPermission = false
                self.permissionTimeout?.cancel()
                self.activatePhone(token)
            case .denied, .restricted:
                self.finish(token, "Location access is required to find and join the hotspot. You can still join it using the Mac Wi-Fi menu.")
            default: break
            }
        }
    }

    private func activatePhone(_ token: HotspotWiFiAttempt) {
        guard attempt === token, !token.isCancelled, !AppState.shared.isSyncPaused,
              PhoneHotspotTransport.matches(deviceID: phoneID ?? "", bluetoothPeer: bluetoothPeer) else { finish(token, "Connection cancelled. Reconnect your phone and retry."); return }
        message = "Requesting your phone's hotspot…"
        // Ask for a fresh observation even if an older status said it was on.
        PhoneHotspotManager.shared.send(.status) { [weak self] enabled in
            guard let self, self.attempt === token, !token.isCancelled else { return }
            guard PhoneHotspotTransport.matches(deviceID: self.phoneID ?? "", bluetoothPeer: self.bluetoothPeer) else { self.finish(token, "Connection cancelled. The phone changed or sync paused."); return }
            if enabled == true { self.join(token); return }
            guard enabled != nil else { self.finish(token, "Your phone did not confirm hotspot status. Refresh and retry."); return }
            guard PhoneHotspotManager.shared.state?.canAttemptControl == true else {
                self.finish(token, "Your phone couldn't confirm hotspot control. Use Setup on phone and check its reported status.")
                return
            }
            PhoneHotspotManager.shared.send(.enable) { [weak self] enabled in
                guard let self, self.attempt === token, !token.isCancelled else { return }
                // Some phones drop their old Wi-Fi before they can send the
                // final state. After an acknowledged activation request only,
                // look for the selected secure hotspot; finding/associating with
                // that real network supplies the Mac-side confirmation instead.
                if enabled == nil && HotspotWiFiPolicy.mayRecoverHandoff(
                    status: PhoneHotspotManager.shared.state?.status,
                    hasPhone: AppState.shared.device != nil,
                    paused: AppState.shared.isSyncPaused,
                    manuallyDisconnected: UserDefaults.standard.isManuallyDisconnected) {
                    self.join(token)
                    return
                }
                guard PhoneHotspotTransport.matches(deviceID: self.phoneID ?? "", bluetoothPeer: self.bluetoothPeer) else { self.finish(token, "Connection cancelled. The phone changed or sync paused."); return }
                if enabled == true { self.join(token) }
                else { self.finish(token, "Hotspot activation wasn't confirmed. Check the phone's hotspot status or use Setup on phone.") }
            }
        }
    }

    private func join(_ token: HotspotWiFiAttempt) {
        guard attempt === token, !token.isCancelled, !AppState.shared.isSyncPaused else { return }
        joining = true
        message = "Finding your hotspot and joining with its saved Mac password…"
        let name = requestedSSID
        HotspotWiFiWorker.queue.async {
            let result = HotspotWiFiWorker.join(ssid: name, attempt: token)
            let address = HotspotWiFiWorker.joinedIPv4(ssid: name, attempt: token)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.attempt === token else { return }
                if let address, !token.isCancelled, !AppState.shared.isSyncPaused,
                   !UserDefaults.standard.isManuallyDisconnected,
                   let peer = self.bluetoothPeer,
                   PhoneHotspotTransport.matches(deviceID: self.phoneID ?? "", bluetoothPeer: peer) {
                    let port = AppState.shared.myDevice?.port ?? Int(Defaults.serverPort)
                    if (1...65535).contains(port),
                       let data = try? JSONSerialization.data(withJSONObject: [
                        "type": "connectNetwork", "data": ["ip": address, "port": port]]),
                       let payload = String(data: data, encoding: .utf8) {
                        _ = BLECentralManager.shared.writeChunked(
                            characteristicUUID: BLEConstants.charMediaControl, payload: payload)
                    }
                }
                self.finish(token, result)
            }
        }
    }

    func cancel() {
        guard let token = attempt else { return }
        token.cancel()
        if joining {
            message = "Cancelling… a Wi-Fi request already submitted to macOS may finish."
        } else { finish(token, "Connection cancelled. A hotspot request already sent to the phone may still complete.") }
    }

    private func finish(_ token: HotspotWiFiAttempt, _ result: String) {
        guard attempt === token else { return }
        permissionTimeout?.cancel()
        permissionTimeout = nil
        awaitingPermission = false
        joining = false
        attempt = nil
        isBusy = false
        if AppState.shared.device != nil { selectPhone() }
        message = result
    }
}
