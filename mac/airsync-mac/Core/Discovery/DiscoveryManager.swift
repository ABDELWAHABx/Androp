import Foundation
import Combine
import Network

class DiscoveryManager: ObservableObject {
    static let shared = DiscoveryManager()
    
    @Published var discoveredDevices: [DiscoveredDevice] = []
    
    private let bonjourAdvertiser = BonjourServiceAdvertiser()
    private let bonjourBrowser = BonjourServiceBrowser()
    private let udpDiscovery = UdpBroadcastDiscovery()
    
    private var mdnsDevices: [String: DiscoveredDevice] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var isRunning = false
    private var lifecycleGeneration: UInt64 = 0
    private var reachabilityGeneration: UInt64 = 0
    var isServiceRunning: Bool { isRunning }
    private var networkMonitor: NWPathMonitor?
    private var reachabilityTimer: Timer?
    private var reachabilityConnections: [String: NWConnection] = [:]
    private var reachabilityCallbacks: [String: [(Bool) -> Void]] = [:]
    private var reachabilityCache: [String: (checkedAt: Date, reachable: Bool)] = [:]
    
    private init() {
        setupBonjourBrowser()
        setupUdpDiscoveryObserver()
        DispatchQueue.main.async { [weak self] in
            self?.setupDeviceConnectionObserver()
        }
    }
    
    @Published var availableWifiDeviceForCurrentBLE: DiscoveredDevice? = nil
    private var wifiAutoSwitchTimer: Timer?
    private var wifiStabilityDisconnectBleTimer: Timer?
    private var lastDeviceReconnectAttemptAt: Date?
    private static let lastDeviceReconnectCooldown: TimeInterval = 15.0

    private func setupDeviceConnectionObserver() {
        AppState.shared.$device
            .receive(on: DispatchQueue.main)
            .sink { [weak self] device in
                guard let self = self else { return }
                guard !AppState.shared.isSyncPaused else { self.stop(); return }
                if let device = device {
                    let isBLE = device.isBLE
                    if !isBLE {
                        if self.isRunning {
                            print("[DiscoveryManager] Wi-Fi device connected. Stopping discovery and advertising.")
                            self.stop()
                        }
                        // If auto-switch is enabled and BLE is active, wait 5s to ensure Wi-Fi is stable before disconnecting BLE
                        if AppState.shared.isAutoSwitchWithBLEEnabled && BLECentralManager.shared.isAuthenticated {
                            print("[DiscoveryManager] Connected to Wi-Fi while BLE is active. Starting 5s stability timer before disconnecting BLE...")
                            self.wifiStabilityDisconnectBleTimer?.invalidate()
                            self.wifiStabilityDisconnectBleTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
                                if AppState.shared.device?.isRegularConnection == true && BLECentralManager.shared.isAuthenticated {
                                    print("[DiscoveryManager] Wi-Fi connection stayed stable for 5s! Disconnecting BLE connection...")
                                    BLECentralManager.shared.disconnect()
                                }
                            }
                        }
                    } else {
                        self.wifiStabilityDisconnectBleTimer?.invalidate()
                        self.wifiStabilityDisconnectBleTimer = nil
                        if !self.isRunning {
                            print("[DiscoveryManager] BLE device connected. Keeping discovery active for Wi-Fi switch.")
                            self.start()
                        }
                    }
                } else {
                    self.wifiStabilityDisconnectBleTimer?.invalidate()
                    self.wifiStabilityDisconnectBleTimer = nil
                    if !self.isRunning {
                        print("[DiscoveryManager] No device connected. Resuming discovery and advertising.")
                        self.start()
                    }
                }
                self.updateAvailableWifiDevice()
            }
            .store(in: &cancellables)
    }
    
    func updateAvailableWifiDevice() {
        guard isRunning, !AppState.shared.isSyncPaused else { return }
        guard let detected = evaluateAvailableWifiDeviceForCurrentBLE(),
              let bestIP = detected.ips.first(where: { $0 != "Bluetooth LE" && $0 != "Nearby" && !$0.isEmpty }) else {
            self.availableWifiDeviceForCurrentBLE = nil
            if wifiAutoSwitchTimer != nil {
                wifiAutoSwitchTimer?.invalidate()
                wifiAutoSwitchTimer = nil
            }
            return
        }

        // Verify TCP reachability over Wi-Fi socket before exposing to UI or auto-switching
        let revision = reachabilityGeneration
        verifyIPReachability(ip: bestIP, port: detected.port) { [weak self] isReachable in
            guard let self = self else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.isRunning, self.reachabilityGeneration == revision, !AppState.shared.isSyncPaused,
                      self.evaluateAvailableWifiDeviceForCurrentBLE()?.id == detected.id else { return }
                guard isReachable else {
                    print("[DiscoveryManager] Discovered Wi-Fi device (\(detected.name)) is NOT reachable over TCP at \(bestIP):\(detected.port). Ignoring stale mDNS record.")
                    self.availableWifiDeviceForCurrentBLE = nil
                    if self.wifiAutoSwitchTimer != nil {
                        self.wifiAutoSwitchTimer?.invalidate()
                        self.wifiAutoSwitchTimer = nil
                    }
                    return
                }

                self.availableWifiDeviceForCurrentBLE = detected

                if AppState.shared.isAutoSwitchWithBLEEnabled {
                    if self.wifiAutoSwitchTimer == nil {
                        print("[DiscoveryManager] Auto-switch enabled: Verified Wi-Fi endpoint (\(detected.name) at \(bestIP)). Starting 5s stability timer...")
                        self.wifiAutoSwitchTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
                            guard let self = self else { return }
                            self.wifiAutoSwitchTimer = nil
                            
                            guard let targetDevice = self.evaluateAvailableWifiDeviceForCurrentBLE(),
                                  let targetIP = targetDevice.ips.first(where: { $0 != "Bluetooth LE" && $0 != "Nearby" && !$0.isEmpty }) else {
                                print("[DiscoveryManager] Wi-Fi device lost before 5s auto-switch. Cancelling switch.")
                                return
                            }

                            self.verifyIPReachability(ip: targetIP, port: targetDevice.port, forceRefresh: true) { isStillReachable in
                                guard self.isRunning, !AppState.shared.isSyncPaused, isStillReachable else {
                                    print("[DiscoveryManager] Wi-Fi device socket closed before auto-switch. Cancelling switch.")
                                    return
                                }
                                print("[DiscoveryManager] Wi-Fi device verified reachable for 5s! Triggering auto-switch to Wi-Fi...")
                                QuickConnectManager.shared.connect(to: targetDevice)
                            }
                        }
                    }
                } else {
                    if self.wifiAutoSwitchTimer != nil {
                        self.wifiAutoSwitchTimer?.invalidate()
                        self.wifiAutoSwitchTimer = nil
                    }
                }
            }
        }
    }
    
    private func evaluateAvailableWifiDeviceForCurrentBLE() -> DiscoveredDevice? {
        let isBLEConnected = BLECentralManager.shared.isAuthenticated ||
            (AppState.shared.device?.isBLE == true)
            
        guard isBLEConnected else { return nil }
        
        let currentName = AppState.shared.device?.name ?? BLECentralManager.shared.connectedDeviceName ?? ""
        let currentId = AppState.shared.device?.deviceId ?? ""
        
        return discoveredDevices.first { discovered in
            let wifiIps = discovered.ips.filter { $0 != "Bluetooth LE" && $0 != "Nearby" && !$0.isEmpty }
            guard !wifiIps.isEmpty else { return false }
            
            if !currentId.isEmpty && !discovered.deviceId.isEmpty && currentId == discovered.deviceId {
                return true
            }
            
            if !currentName.isEmpty {
                let clean1 = cleanName(currentName)
                let clean2 = cleanName(discovered.name)
                if !clean1.isEmpty && !clean2.isEmpty && (clean1 == clean2 || clean1.contains(clean2) || clean2.contains(clean1)) {
                    return true
                }
            }
            
            return false
        }
    }
    
    private func cleanName(_ name: String) -> String {
        return name
            .replacingOccurrences(of: "androp-", with: "")
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
    
    func start() {
        guard !isRunning, !AppState.shared.isSyncPaused else { return }
        if AppState.shared.connectionMode == .nearby {
            print("[Discovery] Connection mode is Nearby only. Skipping DiscoveryManager start.")
            return
        }
        lifecycleGeneration &+= 1
        isRunning = true
        
        setupNetworkMonitor()
        print("[Discovery] Starting DiscoveryManager")
        bonjourAdvertiser.start()
        bonjourBrowser.start()
        udpDiscovery.start()
        startReachabilityTimer()
    }
    
    func stop() {
        lifecycleGeneration &+= 1
        reachabilityGeneration &+= 1
        isRunning = false
        networkMonitor?.cancel()
        networkMonitor = nil
        wifiAutoSwitchTimer?.invalidate()
        wifiAutoSwitchTimer = nil
        wifiStabilityDisconnectBleTimer?.invalidate()
        wifiStabilityDisconnectBleTimer = nil
        availableWifiDeviceForCurrentBLE = nil
        let connections = Array(reachabilityConnections.values)
        reachabilityConnections.removeAll()
        reachabilityCallbacks.removeAll()
        reachabilityCache.removeAll()
        for connection in connections { connection.stateUpdateHandler = nil; connection.cancel() }
        
        print("[Discovery] Stopping DiscoveryManager")
        bonjourAdvertiser.stop()
        bonjourBrowser.stop()
        udpDiscovery.stop()
        stopReachabilityTimer()
        
        mdnsDevices.removeAll()
        discoveredDevices.removeAll()
    }
    
    func broadcastBurst() {
        guard isRunning, !AppState.shared.isSyncPaused else { return }
        udpDiscovery.broadcastBurst()
    }
    
    private func setupBonjourBrowser() {
        bonjourBrowser.onDeviceDiscovered = { [weak self] device in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard self.isRunning, !AppState.shared.isSyncPaused else { return }
                guard self.mdnsDevices[device.deviceId] != nil || self.mdnsDevices.count < 256 else { return }
                self.mdnsDevices[device.deviceId] = device
                self.mergeAndPublish()
            }
        }
        
        bonjourBrowser.onDeviceLost = { [weak self] deviceId in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.mdnsDevices.removeValue(forKey: deviceId)
                self.mergeAndPublish()
            }
        }
    }
    
    private func setupUdpDiscoveryObserver() {
        udpDiscovery.$discoveredDevices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.mergeAndPublish()
            }
            .store(in: &cancellables)
    }
    
    private func mergeAndPublish() {
        guard isRunning, !AppState.shared.isSyncPaused else { return }
        var merged: [String: DiscoveredDevice] = [:]
        
        for device in udpDiscovery.discoveredDevices {
            let filteredIps = device.ips.filter { isIPOnLocalNetwork($0) }
            if !filteredIps.isEmpty {
                var d = device
                d.ips = filteredIps
                merged[device.deviceId] = d
            }
        }
        
        for (_, device) in mdnsDevices {
            let filteredIps = device.ips.filter { isIPOnLocalNetwork($0) }
            guard !filteredIps.isEmpty else { continue }
            
            var d = device
            d.ips = filteredIps
            
            if let existing = merged[device.deviceId] {
                let mergedIps = existing.ips.union(d.ips)
                let mergedDevice = DiscoveredDevice(
                    deviceId: device.deviceId,
                    name: device.name,
                    ips: mergedIps,
                    port: device.port,
                    type: device.type,
                    lastSeen: max(existing.lastSeen, device.lastSeen),
                    discoverySource: .mdns
                )
                merged[device.deviceId] = mergedDevice
            } else {
                merged[device.deviceId] = d
            }
        }
        
        let next = merged.values.sorted { $0.id < $1.id }
        // Presence refreshes need not redraw every device card when its identity,
        // endpoint and metadata are unchanged. Keep lastSeen inside the sources.
        if next.count != discoveredDevices.count || zip(next, discoveredDevices).contains(where: {
            $0.id != $1.id || $0.name != $1.name || $0.ips != $1.ips || $0.port != $1.port || $0.discoverySource != $1.discoverySource || ($0.discoverySource == .udp && $0.lastSeen != $1.lastSeen)
        }) { discoveredDevices = next }
        self.updateAvailableWifiDevice()
        self.attemptAutoReconnectToLastDevice()
    }

    private func attemptAutoReconnectToLastDevice() {
        guard isRunning, !AppState.shared.isSyncPaused, AppState.shared.device == nil else { return }
        guard !UserDefaults.standard.isManuallyDisconnected else { return }

        guard let lastDevice = QuickConnectManager.shared.getLastConnectedDevice(), !lastDevice.isBLE else { return }

        guard let candidate = discoveredDevices.first(where: { discovered in
            let wifiIps = discovered.ips.filter { $0 != "Bluetooth LE" && $0 != "Nearby" && !$0.isEmpty }
            guard !wifiIps.isEmpty else { return false }

            if !lastDevice.deviceId.isEmpty && !discovered.deviceId.isEmpty {
                return lastDevice.deviceId == discovered.deviceId
            }

            let clean1 = cleanName(lastDevice.name)
            let clean2 = cleanName(discovered.name)
            return !clean1.isEmpty && !clean2.isEmpty && clean1 == clean2
        }), let bestIP = candidate.ips.first(where: { $0 != "Bluetooth LE" && $0 != "Nearby" && !$0.isEmpty }) else { return }

        if let lastAttempt = lastDeviceReconnectAttemptAt,
           Date().timeIntervalSince(lastAttempt) < Self.lastDeviceReconnectCooldown {
            return
        }

        lastDeviceReconnectAttemptAt = Date()
        let revision = reachabilityGeneration
        verifyIPReachability(ip: bestIP, port: candidate.port) { [weak self] isReachable in
            guard let self = self, isReachable else { return }
            DispatchQueue.main.async {
                guard self.isRunning, self.reachabilityGeneration == revision, !AppState.shared.isSyncPaused, AppState.shared.device == nil, !UserDefaults.standard.isManuallyDisconnected else { return }
                print("[DiscoveryManager] Last connected device '\(candidate.name)' reappeared on the network. Auto-reconnecting...")
                self.lastDeviceReconnectAttemptAt = Date()
                QuickConnectManager.shared.connect(to: candidate)
            }
        }
    }
    
    func isIPOnLocalNetwork(_ targetIP: String) -> Bool {
        if targetIP == "Bluetooth LE" || targetIP == "Nearby" {
            return true
        }
        
        let adapters = WebSocketServer.shared.getAvailableNetworkAdapters()
        guard !adapters.isEmpty else { return false }
        
        for adapter in adapters {
            if areOnSameSubnet(targetIP, adapter.address) {
                return true
            }
        }
        return false
    }
    
    private func areOnSameSubnet(_ ip1: String, _ ip2: String) -> Bool {
        let p1 = ip1.split(separator: ".")
        let p2 = ip2.split(separator: ".")
        guard p1.count == 4 && p2.count == 4 else { return false }
        
        if ip1.hasPrefix("100.") && ip2.hasPrefix("100.") {
            return true
        }
        if ip1.hasPrefix("192.168.") && ip2.hasPrefix("192.168.") {
            return p1[0] == p2[0] && p1[1] == p2[1] && p1[2] == p2[2]
        }
        return p1[0] == p2[0] && p1[1] == p2[1]
    }
    
    private func setupNetworkMonitor() {
        let generation = lifecycleGeneration
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            guard let self = self else { return }
            print("[DiscoveryManager] Network path update: \(path.status)")
            
            DispatchQueue.main.async {
                guard self.isRunning, self.lifecycleGeneration == generation,
                      self.networkMonitor === monitor, !AppState.shared.isSyncPaused else { return }
                // Probes from the old interface must not prune or auto-connect devices
                // discovered on the replacement network.
                self.reachabilityGeneration &+= 1
                let probes = Array(self.reachabilityConnections.values)
                self.reachabilityConnections.removeAll()
                self.reachabilityCallbacks.removeAll()
                for probe in probes { probe.stateUpdateHandler = nil; probe.cancel() }
                self.wifiAutoSwitchTimer?.invalidate()
                self.wifiAutoSwitchTimer = nil
                self.lastDeviceReconnectAttemptAt = nil
                self.reachabilityCache.removeAll()
                // Clear out stale network devices on network change/disconnect
                self.mdnsDevices.removeAll()
                self.udpDiscovery.discoveredDevices.removeAll()
                self.mergeAndPublish()
                
                // Restart Bonjour browser to trigger fresh searches on the new interface
                self.bonjourBrowser.stop()
                if path.status == .satisfied {
                    self.bonjourBrowser.start()
                    self.udpDiscovery.broadcastBurst()
                }
            }
        }
        self.networkMonitor = monitor
        monitor.start(queue: DispatchQueue(label: "com.airsync.discoveryManager.network"))
    }
    
    private func startReachabilityTimer() {
        let generation = lifecycleGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.lifecycleGeneration == generation, self.isRunning, !AppState.shared.isSyncPaused else { return }
            self.reachabilityTimer?.invalidate()
            self.reachabilityTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
                self?.checkMdnsDevicesReachability()
                self?.attemptAutoReconnectToLastDevice()
            }
            self.reachabilityTimer?.tolerance = 5
        }
    }
    
    private func stopReachabilityTimer() {
        reachabilityTimer?.invalidate()
        reachabilityTimer = nil
    }
    
    private func checkMdnsDevicesReachability() {
        let revision = reachabilityGeneration
        let devices = mdnsDevices.values
        if devices.isEmpty { return }
        
        for device in devices {
            let ips = device.ips
            let port = device.port
            let deviceId = device.deviceId
            let name = device.name
            
            var checkedCount = 0
            var reachable = false
            let total = ips.count
            
            if total == 0 {
                DispatchQueue.main.async {
                    guard self.isRunning, self.reachabilityGeneration == revision else { return }
                    self.mdnsDevices.removeValue(forKey: deviceId)
                    self.mergeAndPublish()
                }
                continue
            }
            
            for ip in ips {
                verifyIPReachability(ip: ip, port: port) { [weak self] isReachable in
                    guard let self = self else { return }
                    checkedCount += 1
                    if isReachable {
                        reachable = true
                    }
                    
                    if checkedCount == total {
                        if !reachable {
                            print("[Discovery] Device \(name) (\(deviceId)) is not reachable on any IP. Removing device.")
                            DispatchQueue.main.async {
                                guard self.isRunning, self.reachabilityGeneration == revision else { return }
                                self.mdnsDevices.removeValue(forKey: deviceId)
                                self.mergeAndPublish()
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func verifyIPReachability(ip: String, port: Int, forceRefresh: Bool = false, completion: @escaping (Bool) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.verifyIPReachability(ip: ip, port: port, forceRefresh: forceRefresh, completion: completion) }
            return
        }
        guard isRunning, !AppState.shared.isSyncPaused, (1...65535).contains(port) else { completion(false); return }
        let endpoint = "\(ip):\(port)"
        if !forceRefresh, let cached = reachabilityCache[endpoint], Date().timeIntervalSince(cached.checkedAt) < 10 {
            completion(cached.reachable)
            return
        }
        if reachabilityCallbacks[endpoint] != nil {
            reachabilityCallbacks[endpoint]?.append(completion)
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(integerLiteral: UInt16(port)), using: .tcp)
        reachabilityConnections[endpoint] = connection
        reachabilityCallbacks[endpoint] = [completion]
        // All state, the timeout, and completion handlers share the main queue.
        // This prevents duplicate callbacks/data races on the old completed flag.
        let finish: (Bool) -> Void = { [weak self, weak connection] reachable in
            guard let self = self, let connection = connection,
                  self.reachabilityConnections[endpoint] === connection else { return }
            self.reachabilityConnections.removeValue(forKey: endpoint)
            let callbacks = self.reachabilityCallbacks.removeValue(forKey: endpoint) ?? []
            connection.stateUpdateHandler = nil
            connection.cancel()
            guard self.isRunning, !AppState.shared.isSyncPaused else { return }
            self.reachabilityCache[endpoint] = (Date(), reachable)
            callbacks.forEach { $0(reachable) }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(true)
            case .failed, .cancelled: finish(false)
            default: break
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { finish(false) }
        connection.start(queue: .main)
    }
}
