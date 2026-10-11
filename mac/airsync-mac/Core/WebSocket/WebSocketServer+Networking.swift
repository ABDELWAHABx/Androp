//
//  WebSocketServer+Networking.swift
//  airsync-mac
//

import Foundation
import UniformTypeIdentifiers
import Network
#if canImport(MobileCoreServices)
import MobileCoreServices
#endif

extension WebSocketServer {
    
    // MARK: - Local IP handling

    /// Retrieves the local IP address based on configuration.
    /// Supports binding to a specific adapter or auto-discovery of all available non-loopback interfaces.
    func getLocalIPAddress(adapterName: String?) -> String? {
        let adapters = getAvailableNetworkAdapters()

        if let adapterName = adapterName {
            if let exact = adapters.first(where: { $0.name == adapterName }) {
                self.lock.lock()
                let lastLogged = lastLoggedSelectedAdapter
                self.lock.unlock()
                
                if lastLogged?.name != exact.name || lastLogged?.address != exact.address {
                    print("[websocket] Selected adapter match: \(exact.name) -> \(exact.address)")
                    self.lock.lock()
                    lastLoggedSelectedAdapter = (exact.name, exact.address)
                    self.lock.unlock()
                }
                return exact.address
            }
        }

        // Auto mode
        if adapterName == nil {
            let allAddresses = adapters.map { $0.address }
            if !allAddresses.isEmpty {
                let joined = allAddresses.joined(separator: ",")
                
                self.lock.lock()
                let lastLogged = lastLoggedSelectedAdapter
                self.lock.unlock()
                
                if lastLogged?.address != joined {
                    print("[websocket] Auto-mode addresses: \(joined)")
                    self.lock.lock()
                    lastLoggedSelectedAdapter = ("auto", joined)
                    self.lock.unlock()
                }
                return joined
            }
        }

        return nil
    }

    func getAvailableNetworkAdapters() -> [(name: String, address: String)] {
        var adapters: [(name: String, address: String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil

        if getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr {
            for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
                let interface = ptr.pointee
                guard let interfaceAddress = interface.ifa_addr else { continue }
                guard (interface.ifa_flags & UInt32(IFF_UP)) != 0,
                      (interface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
                let addrFamily = interfaceAddress.pointee.sa_family

                if addrFamily == UInt8(AF_INET),
                   let name = String(validatingUTF8: interface.ifa_name) {
                    var addr = interface.ifa_addr.pointee
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let result = getnameinfo(&addr,
                                             socklen_t(interface.ifa_addr.pointee.sa_len),
                                             &hostname,
                                             socklen_t(hostname.count),
                                             nil,
                                             socklen_t(0),
                                             NI_NUMERICHOST)
                    if result == 0 {
                        let address = String(cString: hostname)
                        if address != "127.0.0.1" {
                            adapters.append((name, address))
                        }
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        return adapters.sorted { lhs, rhs in
            if lhs.name == rhs.name { return lhs.address < rhs.address }
            return lhs.name < rhs.name
        }
    }

    func ipIsPrivatePreferred(_ ip: String) -> Bool {
        if ip.hasPrefix("192.168.") { return true }
        if ip.hasPrefix("10.") { return true }
        if ip.hasPrefix("172.") {
            let parts = ip.split(separator: ".")
            if parts.count > 1, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        // Carrier-grade NAT / Tailscale (100.64.0.0/10). Android already accepts 100.x as local.
        if ip.hasPrefix("100.") {
            let parts = ip.split(separator: ".")
            if parts.count > 1, let second = Int(parts[1]), (64...127).contains(second) {
                return true
            }
        }
        return false
    }

    // MARK: - Network Monitoring

    func startNetworkMonitoring() {
        guard !AppState.shared.isSyncPaused else { return }
        networkPathMonitor?.cancel()
        lock.lock()
        let generation = lifecycleGeneration
        networkRecovery = NetworkRecoveryPolicy()
        lock.unlock()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            let available = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self = self, let monitor = monitor,
                      self.networkPathMonitor === monitor,
                      self.isCurrentLifecycle(generation) else { return }
                self.checkNetworkChange(pathAvailable: available)
            }
        }
        networkPathMonitor = monitor
        monitor.start(queue: networkMonitorQueue)
    }

    func stopNetworkMonitoring() {
        networkPathMonitor?.cancel()
        networkPathMonitor = nil
        lock.lock()
        networkMonitorTimer?.invalidate()
        networkMonitorTimer = nil
        lastKnownAdapters = []
        networkRecovery = NetworkRecoveryPolicy()
        lock.unlock()
    }

    /// Observe loss as well as recovery: Wi-Fi often returns with the SAME address.
    /// Ignoring the loss leaves stale sessions and prevents the listener recovering.
    func checkNetworkChange(pathAvailable: Bool? = nil) {
        guard !AppState.shared.isSyncPaused else { return }
        AppState.shared.revalidateNetworkAdapter()
        let adapters = getAvailableNetworkAdapters()
        let chosenIP = getLocalIPAddress(adapterName: AppState.shared.selectedNetworkAdapterName)
        lock.lock()
        guard shouldRun else { lock.unlock(); return }
        let action = networkRecovery.update(
            available: pathAvailable ?? !adapters.isEmpty,
            endpoint: chosenIP,
            previousEndpoint: lastKnownIP
        )
        lastKnownAdapters = adapters
        lastKnownIP = chosenIP
        let port = localPort ?? requestedPort
        lock.unlock()

        localIPAddress = chosenIP
        AppState.shared.shouldRefreshQR = true
        if case .started = AppState.shared.webSocketStatus {
            AppState.shared.webSocketStatus = .started(port: port, ip: chosenIP)
        }
        if action == .lost {
            // Keep the listener/monitor alive to hear the recovery event. Do not
            // persist a manual disconnect or disturb a BLE-only connection.
            if AppState.shared.device?.isRegularConnection == true {
                AppState.shared.disconnectDevice(manual: false)
            }
        } else if action == .restart {
            print("[websocket] Network recovered or endpoint changed; refreshing listener")
            restartServer()
        }
    }

    // MARK: - Utils

    func mimeType(for url: URL) -> String? {
        let ext = url.pathExtension
        if ext.isEmpty { return nil }

        if #available(macOS 11.0, *) {
            if let ut = UTType(filenameExtension: ext) {
                return ut.preferredMIMEType
            }
        } else {
#if canImport(MobileCoreServices)
            if let uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, ext as CFString, nil)?.takeRetainedValue() {
                if let mime = UTTypeCopyPreferredTagWithClass(uti, kUTTagClassMIMEType)?.takeRetainedValue() as String? {
                    return mime
                }
            }
#endif
        }
        return nil
    }
}
