import Foundation
import Network
import Combine

class BonjourServiceAdvertiser: NSObject, NetServiceDelegate {
    private var netService: NetService?
    private var pathMonitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "com.airsync.bonjour.advertiser")
    private var isAdvertising = false
    private var cancellables = Set<AnyCancellable>()
    private var publishedEndpoint: String?
    
    func start() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.start() }; return }
        guard !isAdvertising, !AppState.shared.isSyncPaused else { return }
        isAdvertising = true
        
        setupPathMonitor()
        Publishers.CombineLatest3(AppState.shared.$webSocketStatus, AppState.shared.$myDevice,
                                  AppState.shared.$isSyncPaused)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in self?.publishService() }
            .store(in: &cancellables)
        publishService()
    }
    
    func stop() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.stop() }; return }
        guard isAdvertising else { return }
        isAdvertising = false
        
        pathMonitor?.cancel()
        pathMonitor = nil
        cancellables.removeAll()
        unpublishService()
    }

    private func unpublishService() {
        netService?.stop()
        netService = nil
        publishedEndpoint = nil
    }
    
    private func setupPathMonitor() {
        pathMonitor?.cancel()
        
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self = self, self.isAdvertising else { return }
                if path.status == .satisfied { self.publishService() }
                else { self.unpublishService() }
            }
        }
        self.pathMonitor = monitor
        monitor.start(queue: queue)
    }
    
    private func publishService() {
        guard isAdvertising, !AppState.shared.isSyncPaused,
              case .started = AppState.shared.webSocketStatus,
              let endpoint = WebSocketServer.shared.getListeningNetworkEndpoint() else {
            unpublishService()
            return
        }
        let info = AppState.shared.myDevice
        let port = Int32(endpoint.port)
        let name = info?.name ?? Host.current().localizedName ?? "Mac"
        let uuid = getStableUUID()
        
        let serviceName = "androp-\(name)"
        // One DNS-SD TXT entry (including "ips=") must stay below 256 bytes.
        let ips = endpoint.adapters.map(\.address).sorted().prefix(15).joined(separator: ",")
        let signature = "\(serviceName)|\(port)|\(ips)"
        guard publishedEndpoint != signature || netService == nil else { return }
        unpublishService()

        let service = NetService(domain: "", type: "_androp._tcp", name: serviceName, port: port)
        service.delegate = self
        
        let txtDict = [
            "id": uuid,
            "name": name,
            "port": String(port),
            "ips": ips,
            "ver": "1",
            "type": "mac"
        ]
        
        let txtRecordData = NetService.data(fromTXTRecord: txtDict.mapValues { $0.data(using: .utf8)! })
        service.setTXTRecord(txtRecordData)
        
        self.netService = service
        publishedEndpoint = signature
        service.publish()
        print("[Bonjour] Publishing service: \(serviceName) on port \(port)")
    }
    
    // MARK: - NetServiceDelegate
    
    func netServiceDidPublish(_ sender: NetService) {
        print("[Bonjour] Successfully published service: sender name = \(sender.name)")
    }
    
    func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        if sender === netService { unpublishService() }
        print("[Bonjour] Failed to publish service: \(errorDict)")
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
