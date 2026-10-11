import Foundation
import Network
import Combine
import SwiftUI

enum DiscoverySource: String, Codable, CaseIterable {
    case mdns
    case udp
}

struct DiscoveredDevice: Identifiable, Equatable, Hashable {
    let deviceId: String
    let name: String
    var ips: Set<String>
    let port: Int
    let type: String
    var lastSeen: Date
    var discoverySource: DiscoverySource = .udp
    
    var id: String {
        return deviceId
    }
    
    var isActive: Bool {
        if discoverySource == .mdns {
            return true
        }
        return Date().timeIntervalSince(lastSeen) < 20
    }
    
    static func == (lhs: DiscoveredDevice, rhs: DiscoveredDevice) -> Bool {
        return lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

class UdpBroadcastDiscovery: ObservableObject {
    @Published var discoveredDevices: [DiscoveredDevice] = []
    
    private var listener: NWListener?
    private var connection: NWConnection?
    private let queue = DispatchQueue.main
    private let broadcastPort: NWEndpoint.Port = 8890
    private var cancellables = Set<AnyCancellable>()
    private var isListening = false
    private var lastBroadcastTime: Date = .distantPast
    private var networkChangePendingWork: DispatchWorkItem?
    
    init() {
        // Init logic only
    }
    
    private var networkMonitor: NWPathMonitor?
    
    // MARK: - Lifecycle
    
    func start() {
        if !isListening {
            guard !AppState.shared.isSyncPaused else { return }
            isListening = true
            startListening()
            startMonitoring()
            
            // Immediate broadcast on start
            broadcastBurst()
        }
    }
    
    func stop() {
        isListening = false
        networkChangePendingWork?.cancel()
        networkChangePendingWork = nil
        stopListening()
        stopMonitoring()
        discoveredDevices.removeAll()
        isListening = false
    }
    
    // MARK: - Smart Triggers
    
    private func startMonitoring() {
        setupNetworkPathMonitor()
        AppState.shared.$webSocketStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard case .started = status else { return }
                self?.broadcastBurst()
            }
            .store(in: &cancellables)
    }
    
    private func setupNetworkPathMonitor() {
        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            guard let self = self, self.isListening, !AppState.shared.isSyncPaused else { return }
            guard path.status == .satisfied else { return }

            self.networkChangePendingWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.isListening, !AppState.shared.isSyncPaused else { return }
                guard Date().timeIntervalSince(self.lastBroadcastTime) >= 2.0 else { return }
                print("[Discovery] Network change detected – broadcasting presence")
                self.broadcastBurst()
            }
            self.networkChangePendingWork = work
            queue.asyncAfter(deadline: .now() + 2.0, execute: work)
        }
        networkMonitor?.start(queue: queue)
    }
    
    private func stopMonitoring() {
        cancellables.removeAll()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        networkMonitor?.cancel()
        networkMonitor = nil
    }
    
    // MARK: - Broadcasting
    
    func broadcastBurst() {
        guard isListening, !AppState.shared.isSyncPaused,
              WebSocketServer.shared.getListeningNetworkEndpoint() != nil else { return }
        print("[Discovery] Triggering broadcast burst")
        lastBroadcastTime = Date()
        
        for i in 0..<3 {
            queue.asyncAfter(deadline: .now() + (Double(i) * 0.1)) { [weak self] in
                self?.broadcastPresence()
            }
        }
    }
    
    func broadcastPresence() {
        guard isListening, !AppState.shared.isSyncPaused else { return }
        guard let endpoint = WebSocketServer.shared.getListeningNetworkEndpoint() else { return }
        let adapters = endpoint.adapters
        
        let knownPeerIPs = Set(QuickConnectManager.shared.lastConnectedDevices.values.map { $0.ipAddress })
        let allIPs = adapters.map { $0.address }
        
        let info = AppState.shared.myDevice
        let port = Int(endpoint.port)
        let name = info?.name ?? Host.current().localizedName ?? "Mac"
        let uuid = getStableUUID()
        
        let payload: [String: Any] = [
            "type": "presence",
            "deviceType": "mac",
            "id": uuid,
            "name": name,
            "ips": allIPs,
            "port": port
        ]
        
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let jsonString = String(data: data, encoding: .utf8) {
            for adapter in adapters {
                sendBroadcast(message: jsonString, sourceIP: adapter.address, endpointPort: endpoint.port, advertisedIPs: allIPs)
            }
        }
        
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let jsonString = String(data: data, encoding: .utf8) {
            for peerIP in knownPeerIPs {
                if allIPs.contains(peerIP) { continue }
                guard DiscoveryManager.shared.isIPOnLocalNetwork(peerIP) else { continue }
                sendUnicast(message: jsonString, targetIP: peerIP, endpointPort: endpoint.port, advertisedIPs: allIPs)
            }
        }
    }
    
    private func sendBroadcast(message: String, sourceIP: String, endpointPort: UInt16, advertisedIPs: [String]) {
        let host = NWEndpoint.Host("255.255.255.255")
        let port = broadcastPort
        
        let parameters = NWParameters.udp
        if let localIP = IPv4Address(sourceIP) {
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(localIP.debugDescription), port: 0)
        }
        
        let connection = NWConnection(host: host, port: port, using: parameters)
        
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection = connection else { return }
            switch state {
            case .ready:
                guard let self, self.isListening, !AppState.shared.isSyncPaused,
                      let current = WebSocketServer.shared.getListeningNetworkEndpoint(),
                      current.port == endpointPort,
                      Set(advertisedIPs).isSubset(of: Set(current.adapters.map(\.address))) else {
                    connection.cancel()
                    return
                }
                connection.send(content: message.data(using: .utf8), completion: .contentProcessed({ _ in
                    connection.cancel()
                }))
            case .failed(_):
                connection.cancel()
            case .cancelled:
                break
            default:
                break
            }
        }
        
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 2) { [weak connection] in connection?.cancel() }
    }
    
    private func sendUnicast(message: String, targetIP: String, endpointPort: UInt16, advertisedIPs: [String]) {
        let host = NWEndpoint.Host(targetIP)
        let port = broadcastPort
        let parameters = NWParameters.udp
        let connection = NWConnection(host: host, port: port, using: parameters)
        
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection = connection else { return }
            switch state {
            case .ready:
                guard let self, self.isListening, !AppState.shared.isSyncPaused,
                      let current = WebSocketServer.shared.getListeningNetworkEndpoint(),
                      current.port == endpointPort,
                      Set(advertisedIPs).isSubset(of: Set(current.adapters.map(\.address))) else {
                    connection.cancel()
                    return
                }
                connection.send(content: message.data(using: .utf8), completion: .contentProcessed({ _ in
                    connection.cancel()
                }))
            case .failed(_):
                connection.cancel()
            case .cancelled:
                break
            default:
                break
            }
        }
        
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 2) { [weak connection] in connection?.cancel() }
    }
    
    // MARK: - Listening
    
    private func startListening() {
        do {
            let parameters = NWParameters.udp
            parameters.allowLocalEndpointReuse = true
            
            listener = try NWListener(using: parameters, on: broadcastPort)
            
            listener?.newConnectionHandler = { [weak self] newConnection in
                newConnection.receiveMessage { (data, context, isComplete, error) in
                    if let data = data, !data.isEmpty, let message = String(data: data, encoding: .utf8) {
                        self?.handleMessage(message)
                    }
                    newConnection.cancel()
                }
                newConnection.start(queue: self?.queue ?? .global())
            }
            
            listener?.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    print("[UDP] Listener ready on port \(self.broadcastPort.rawValue)")
                case .failed(let error):
                    print("[UDP] Listener failed: \(error)")
                default:
                    break
                }
            }
            
            listener?.start(queue: queue)
            
            Timer.publish(every: 10, tolerance: 2, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    guard let self = self, self.isListening, !AppState.shared.isSyncPaused else { return }
                    self.pruneStaleDevices()
                    let isWifiConnected = AppState.shared.device != nil &&
                                         AppState.shared.device?.ipAddress != "BLE" &&
                                         AppState.shared.device?.ipAddress != "Bluetooth LE"
                    guard !isWifiConnected else { return }
                    self.broadcastPresence()
                }
                .store(in: &cancellables)
            
        } catch {
            print("[UDP] Failed to create listener: \(error)")
        }
    }
    
    private func stopListening() {
        listener?.cancel()
        listener = nil
        cancellables.removeAll()
    }
    
    private func handleMessage(_ message: String) {
        guard isListening, !AppState.shared.isSyncPaused, message.utf8.count <= 16_384 else { return }
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              let deviceType = json["deviceType"] as? String,
              deviceType == "android"
        else { return }
        
        guard let id = json["id"] as? String, !id.isEmpty, id.count <= 256 else { return }
        
        if type == "bye" {
            DispatchQueue.main.async {
                self.discoveredDevices.removeAll { $0.deviceId == id }
            }
            return
        }
        
        guard type == "presence" else { return }
        
        let name = json["name"] as? String ?? "Unknown Android"
        let port = json["port"] as? Int ?? 0
        guard (1...65535).contains(port) else { return }
        
        var incomingIps: Set<String> = []
        if let ipsArray = json["ips"] as? [String] {
            incomingIps = Set(ipsArray)
        } else if let singleIp = json["ip"] as? String {
            incomingIps = [singleIp]
        }
        
        let validIps = incomingIps.filter { isValidCandidateIP($0) }
        guard !validIps.isEmpty else { return }
        
        DispatchQueue.main.async {
            guard self.isListening, !AppState.shared.isSyncPaused else { return }
            let device = DiscoveredDevice(deviceId: id, name: name, ips: validIps,
                                          port: port, type: deviceType, lastSeen: Date(), discoverySource: .udp)
            if let index = self.discoveredDevices.firstIndex(where: { $0.deviceId == id }) {
                // Replace stale endpoints rather than unioning removed addresses forever.
                self.discoveredDevices[index] = device
            } else if self.discoveredDevices.count < 256 {
                self.discoveredDevices.append(device)
            }
        }
    }

    private func isValidCandidateIP(_ ip: String) -> Bool {
        if ip.hasPrefix("100.") { return true }
        if ip.hasPrefix("192.168.") { return true }
        if ip.hasPrefix("172.") {
             let parts = ip.split(separator: ".")
             if parts.count > 1, let octet = Int(parts[1]), octet >= 16 && octet <= 31 {
                 return true
             }
        }
        
        if ip.hasPrefix("10.") {
            let adapters = WebSocketServer.shared.getAvailableNetworkAdapters()
            let hasTenNet = adapters.contains { $0.address.hasPrefix("10.") }
            return hasTenNet
        }
        
        return false
    }
    
    private func pruneStaleDevices() {
        let now = Date()
        if discoveredDevices.contains(where: { now.timeIntervalSince($0.lastSeen) > 35 }) {
            discoveredDevices.removeAll { now.timeIntervalSince($0.lastSeen) > 35 }
        }
    }

    private func getStableUUID() -> String {
        let defaults = UserDefaults.standard
        if let uuid = defaults.string(forKey: "device_stable_uuid") {
            return uuid
        }
        let uuid = UUID().uuidString
        defaults.set(uuid, forKey: "device_stable_uuid")
        return uuid
    }
}
