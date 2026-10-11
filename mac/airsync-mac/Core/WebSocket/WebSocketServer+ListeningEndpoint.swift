import Foundation

extension WebSocketServer {
    /// Advertise only sockets that finished binding, and only addresses that socket accepts.
    /// `localIPAddress` is a UI/network preference and may change before a rebind completes.
    func getListeningNetworkEndpoint() -> (port: UInt16, adapters: [(name: String, address: String)])? {
        lock.lock()
        guard shouldRun, let port = listeningPort, port > 0, !servers.isEmpty else {
            lock.unlock()
            return nil
        }
        let generation = lifecycleGeneration
        let boundAddresses = listeningAddresses
        lock.unlock()

        let adapters = getAvailableNetworkAdapters().filter { adapter in
            boundAddresses?.contains(adapter.address) ?? true
        }
        guard !adapters.isEmpty else { return nil }

        lock.lock()
        defer { lock.unlock() }
        guard shouldRun, lifecycleGeneration == generation, listeningPort == port,
              listeningAddresses == boundAddresses, !servers.isEmpty else { return nil }
        return (port, adapters)
    }
}
