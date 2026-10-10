//
//  WebSocketServer.swift
//  airsync-mac
//
//  Created by Sameera Sandakelum on 2025-07-28.
//

import Foundation
import Swifter
import CryptoKit
import UserNotifications
import Combine
import Network

class WebSocketServer: ObservableObject {
    static let shared = WebSocketServer()
    
    internal var server = HttpServer()
    internal var activeSessions: [WebSocketSession] = []
    internal var authenticatedPrimarySessionID: ObjectIdentifier?
    var authenticatedSessionIdentity: ObjectIdentifier? {
        lock.lock(); defer { lock.unlock() }
        guard let identity = authenticatedPrimarySessionID, primarySessionID == identity,
              activeSessions.contains(where: { ObjectIdentifier($0) == identity }) else { return nil }
        return identity
    }
    internal var primarySessionID: ObjectIdentifier?
    internal var pingTimer: Timer?
    internal let pingInterval: TimeInterval = 4.5
    internal var lastActivity: [ObjectIdentifier: Date] = [:]
    internal let activityTimeout: TimeInterval = 20.0
    
    @Published var symmetricKey: SymmetricKey?
    @Published var localPort: UInt16?
    @Published var localIPAddress: String?
    @Published var connectedDevice: Device?
    @Published var notifications: [Notification] = []
    @Published var deviceStatus: DeviceStatus?

    internal var lastKnownIP: String?
    internal var isRestarting: Bool = false
    internal var restartWorkItem: DispatchWorkItem?
    internal var shouldRun = false
    internal var lifecycleGeneration: UInt64 = 0
    internal let lifecycleQueue = DispatchQueue(label: "app.androp.server.lifecycle", qos: .utility)
    internal var networkMonitorTimer: Timer?
    internal var networkPathMonitor: NWPathMonitor?
    internal var networkRecovery = NetworkRecoveryPolicy()
    internal let networkMonitorQueue = DispatchQueue(label: "com.airsync.networkmonitor", qos: .utility)
    internal let networkCheckInterval: TimeInterval = 10.0
    internal let lock = NSRecursiveLock()
    internal let writeQueue = DispatchQueue(label: "app.androp.socket.write", qos: .utility)
    internal var pendingWrites = 0
    internal let fileQueue = DispatchQueue(label: "com.airsync.fileio")
    
    internal var servers: [String: HttpServer] = [:]
    internal var isListeningOnAll = false

    internal var incomingFiles: [String: IncomingFileIO] = [:]
    internal var incomingFilesChecksum: [String: String] = [:]
    internal let transferWakeup = NSCondition()
    internal var outgoingAcks: [String: Set<Int>] = [:]
    internal var outgoingVerification: [String: (verified: Bool, error: String?)] = [:]

    internal let maxChunkRetries = 3
    internal let ackWaitMs: UInt16 = 2000

    internal var lastKnownAdapters: [(name: String, address: String)] = []
    internal var lastLoggedSelectedAdapter: (name: String, address: String)? = nil

    init() {
        loadOrGenerateSymmetricKey()
        setupWebSocket(for: server)
        guard !LifecycleSelfTest.isRequested else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let err = error {
                print("[websocket] Notification auth error: \(err)")
            } else {
                print("[websocket] Notification permission granted: \(granted)")
            }
        }
    }

    /// Starts the WebSocket server on the specified port.
    /// Handles binding to a specific network adapter or all available interfaces if "auto" is selected.
    func start(port: UInt16 = Defaults.serverPort) {
        guard !AppState.shared.isSyncPaused else { return }
        let adapterName = AppState.shared.selectedNetworkAdapterName
        lock.lock()
        shouldRun = true
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        lock.unlock()
        DispatchQueue.main.async {
            guard self.isCurrentLifecycle(generation) else { return }
            AppState.shared.webSocketStatus = .starting
            self.startNetworkMonitoring()
        }
        lifecycleQueue.async { [weak self] in
            guard let self = self, self.isCurrentLifecycle(generation) else { return }
            self.lock.lock()
            self.primarySessionID = nil; self.authenticatedPrimarySessionID = nil
            self.activeSessions.removeAll()
            self.lastActivity.removeAll()
            self.lock.unlock()
            self.stopAllServers()
            do {
                guard port > 0 else { throw NSError(domain: "androp", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid server port"]) }
                // Swifter binds all interfaces. One listener is sufficient even when
                // the Mac has no address yet; NWPathMonitor handles subsequent changes.
                let server = HttpServer()
                self.setupWebSocket(for: server, generation: generation)
                if let adapterName = adapterName {
                    server.listenAddressIPv4 = self.getLocalIPAddress(adapterName: adapterName)
                }
                try server.start(in_port_t(port), forceIPv4: adapterName != nil)
                guard self.isCurrentLifecycle(generation) else { server.stop(); return }
                self.lock.lock()
                self.servers[adapterName ?? "any"] = server
                self.isListeningOnAll = adapterName == nil
                self.lock.unlock()
                DispatchQueue.main.async {
                    guard self.isCurrentLifecycle(generation), !AppState.shared.isSyncPaused else { return }
                    let ip = self.getLocalIPAddress(adapterName: adapterName)
                    self.localPort = port
                    self.localIPAddress = ip
                    self.lastKnownIP = ip
                    AppState.shared.webSocketStatus = .started(port: port, ip: ip)
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.isCurrentLifecycle(generation) else { return }
                    AppState.shared.webSocketStatus = .failed(error: "\(error)")
                }
            }
        }
    }

    internal func isCurrentLifecycle(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return shouldRun && lifecycleGeneration == generation
    }

    internal func stopAllServers() {
        lock.lock()
        let oldServers = Array(servers.values)
        servers.removeAll()
        lock.unlock()
        // HttpServer.stop waits for handlers; holding their state lock here deadlocks.
        for server in oldServers { server.stop() }
    }

    func stop() {
        lock.lock()
        shouldRun = false
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        restartWorkItem?.cancel()
        restartWorkItem = nil
        isRestarting = false
        primarySessionID = nil
        authenticatedPrimarySessionID = nil
        activeSessions.removeAll()
        lastActivity.removeAll()
        lock.unlock()
        cancelAllFileTransfers()
        stopPing()
        stopNetworkMonitoring()
        DispatchQueue.main.async {
            self.lock.lock()
            let isStopped = !self.shouldRun && self.lifecycleGeneration == generation
            self.lock.unlock()
            guard isStopped else { return }
            MacRemoteManager.shared.stopVolumeMonitoring()
            AppState.shared.webSocketStatus = .stopped
        }
        lifecycleQueue.async { [weak self] in self?.stopAllServers() }
    }

    /// Configures WebSocket routes and event callbacks.
    /// Handles message decryption before passing payload to the message router.
    private func setupWebSocket(for server: HttpServer, generation: UInt64 = 0) {
        server["/socket"] = websocket(
            text: { [weak self] session, text in
                guard let self = self, !AppState.shared.isSyncPaused else { return }
                let decryptedData: Data?
                if let key = self.symmetricKey {
                    decryptedData = decryptMessageToData(text, using: key)
                } else {
                    decryptedData = text.data(using: .utf8)
                }

                guard let data = decryptedData, !data.isEmpty else { return }

                self.lock.lock()
                guard self.shouldRun, self.activeSessions.contains(where: { $0 === session }) else { self.lock.unlock(); return }
                self.lastActivity[ObjectIdentifier(session)] = Date()
                self.lock.unlock()
                DispatchQueue.main.async {
                    if AppState.shared.isConnectionWeak {
                        AppState.shared.isConnectionWeak = false
                    }
                }

                do {
                    let message = try JSONDecoder().decode(Message.self, from: data)
                    if message.type == .status {
                        // Pong / keepalive check
                        if let dict = message.data.value as? [String: Any],
                           (dict["type"] as? String) == "pong" {
                            return
                        }
                    }

                    if message.type == .fileChunk || message.type == .fileChunkAck || message.type == .fileTransferComplete || message.type == .fileTransferInit {
                         self.handleMessage(message, session: session)
                    } else {
                        DispatchQueue.main.async {
                            guard !AppState.shared.isSyncPaused else { return }
                            self.lock.lock()
                            let isActive = self.activeSessions.contains { $0 === session }
                            self.lock.unlock()
                            if isActive { self.handleMessage(message, session: session) }
                        }
                    }
                } catch {
                    print("[websocket] JSON decode failed: \(error)")
                }
            },
            binary: { [weak self] session, _ in
                guard let self = self else { return }
                self.lock.lock()
                guard self.shouldRun, self.activeSessions.contains(where: { $0 === session }) else { self.lock.unlock(); return }
                self.lastActivity[ObjectIdentifier(session)] = Date()
                self.lock.unlock()
            },
            connected: { [weak self] session in
                guard let self = self else { return }
                self.lock.lock()
                guard self.shouldRun, self.lifecycleGeneration == generation else { self.lock.unlock(); return }
                let sessionId = ObjectIdentifier(session)
                self.lastActivity[sessionId] = Date()
                self.activeSessions.append(session)
                let sessionCount = self.activeSessions.count
                if self.primarySessionID == nil { self.primarySessionID = sessionId }
                self.lock.unlock()
                print("[websocket] Session \(sessionId) connected.")
                
                if sessionCount == 1 {
                    DispatchQueue.main.async {
                        guard !AppState.shared.isSyncPaused else { return }
                        MacRemoteManager.shared.startVolumeMonitoring()
                    }
                    self.startPing()
                }
            },
            disconnected: { [weak self] session in
                guard let self = self else { return }
                self.lock.lock()
                guard self.activeSessions.contains(where: { $0 === session }) else { self.lock.unlock(); return }
                self.lastActivity.removeValue(forKey: ObjectIdentifier(session))
                self.activeSessions.removeAll(where: { $0 === session })
                let sessionCount = self.activeSessions.count
                let wasPrimary = (ObjectIdentifier(session) == self.primarySessionID)
                if wasPrimary { self.primarySessionID = nil; self.authenticatedPrimarySessionID = nil }
                self.lock.unlock()
                
                if sessionCount == 0 {
                    self.cancelAllFileTransfers()
                    DispatchQueue.main.async { MacRemoteManager.shared.stopVolumeMonitoring() }
                    self.stopPing()
                }
                
                if wasPrimary {
                    DispatchQueue.main.async {
                        self.lock.lock()
                        let shouldDisconnect = self.shouldRun && self.lifecycleGeneration == generation && self.primarySessionID == nil
                        self.lock.unlock()
                        guard shouldDisconnect, !AppState.shared.isSyncPaused else { return }
                        AppState.shared.disconnectDevice(manual: false)
                        ADBConnector.disconnectADB()
                        AppState.shared.adbConnected = false
                        // Guard against cascading restarts from multiple disconnected callbacks
                        self.restartServer()
                    }
                }
            }
        )
    }

    // MARK: - Crypto Helpers
    
    func loadOrGenerateSymmetricKey() {
        let defaults = UserDefaults.standard
        if let savedKey = defaults.string(forKey: "encryptionKey"),
           let keyData = Data(base64Encoded: savedKey) {
            symmetricKey = SymmetricKey(data: keyData)
        } else {
            let base64Key = generateSymmetricKey()
            defaults.set(base64Key, forKey: "encryptionKey")
            if let keyData = Data(base64Encoded: base64Key) {
                symmetricKey = SymmetricKey(data: keyData)
            }
        }
    }

    func resetSymmetricKey() {
        UserDefaults.standard.removeObject(forKey: "encryptionKey")
        loadOrGenerateSymmetricKey()
    }

    func getSymmetricKeyBase64() -> String? {
        guard let key = symmetricKey else { return nil }
        return key.withUnsafeBytes { Data($0).base64EncodedString() }
    }

    func setEncryptionKey(base64Key: String) {
        if let data = Data(base64Encoded: base64Key) {
            symmetricKey = SymmetricKey(data: data)
        }
    }
    
    func wakeUpLastConnectedDevice() {
        QuickConnectManager.shared.wakeUpLastConnectedDevice()
    }

    // MARK: - Restart Helper

    /// Single entry-point for all server restart logic.
    /// Guarded by `isRestarting` to prevent cascading calls from multiple
    /// simultaneous `disconnected` callbacks or stale-ping handlers.
    /// Waits 1.5 s before restarting so any remaining callbacks finish first,
    /// then re-broadcasts presence so Android can rediscover the Mac.
    func restartServer() {
        lock.lock()
        guard shouldRun, !isRestarting else { lock.unlock(); return }
        isRestarting = true
        let generation = lifecycleGeneration
        let port = localPort ?? Defaults.serverPort
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.isCurrentLifecycle(generation), !AppState.shared.isSyncPaused else { return }
            if AppState.shared.device?.isRegularConnection == true {
                AppState.shared.disconnectDevice(manual: false)
            }
            self.stop()
            self.start(port: port)
            DiscoveryManager.shared.broadcastBurst()
        }
        restartWorkItem?.cancel()
        restartWorkItem = work
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}
