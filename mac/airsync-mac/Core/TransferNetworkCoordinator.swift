import Foundation
import Combine
import CoreLocation

/// One explicit transfer owns the temporary network. Radio discovery is never
/// started by this coordinator while idle; credentials live only in memory.
@MainActor
final class TransferNetworkCoordinator: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = TransferNetworkCoordinator()
    @Published private(set) var statusMessage: String?
    @Published private(set) var isBusy = false

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private final class Session {
        let id: UUID
        let deviceID: String
        let pairingToken: String?
        let key: Data
        let bluetoothPeer: String?
        let remote: Bool
        let attempt = HotspotWiFiAttempt()
        var completion: ((Result<Void, Error>) -> Void)?
        var requested = false
        var joining = false
        var connected = false
        var temporarySSID: String?
        var address: String?
        var originalSocket: ObjectIdentifier?
        var endpointAttempts = 0
        init(id: UUID, deviceID: String, pairingToken: String?, key: Data,
             bluetoothPeer: String?, remote: Bool, completion: ((Result<Void, Error>) -> Void)?) {
            self.id = id; self.deviceID = deviceID; self.pairingToken = pairingToken
            self.key = key; self.bluetoothPeer = bluetoothPeer; self.remote = remote; self.completion = completion
        }
    }
    private var session: Session?
    private var deadline: DispatchWorkItem?
    private var heartbeat: Timer?
    private var endpointRetry: DispatchWorkItem?
    private let location = CLLocationManager()
    private var awaitingPermission = false
    private var cleanupAttempt: HotspotWiFiAttempt?
    private var cleanupKey: Data?
    private var cleanupPairingToken: String?
    private var observers = Set<AnyCancellable>()
    private var recentRequests: [UUID: Date] = [:]

    private override init() {
        super.init()
        location.delegate = self
        Publishers.CombineLatest3(AppState.shared.$device, AppState.shared.$isSyncPaused,
                                  BLECentralManager.shared.$connectionStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in self?.connectionChanged() }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.connectionChanged() }
            .store(in: &observers)
    }

    @discardableResult
    func ensureNetwork(deviceID: String, pairingToken: String?, completion: @escaping (Result<Void, Error>) -> Void) -> UUID? {
        begin(id: UUID(), deviceID: deviceID, pairingToken: pairingToken, remote: false, completion: completion)
    }

    @discardableResult
    private func begin(id: UUID, deviceID: String, pairingToken: String?, remote: Bool,
                       completion: ((Result<Void, Error>) -> Void)?) -> UUID? {
        guard session == nil else { completion?(.failure(Failure(message: "Another transfer is connecting. Finish or cancel it first."))); return nil }
        let state = AppState.shared
        guard !state.isSyncPaused, !UserDefaults.standard.isManuallyDisconnected,
              state.device?.deviceId == deviceID, !deviceID.isEmpty,
              pairingToken == UserDefaults.standard.string(forKey: "bleAuthToken"),
              let encoded = UserDefaults.standard.string(forKey: "encryptionKey"),
              let key = Data(base64Encoded: encoded), [16, 24, 32].contains(key.count) else {
            completion?(.failure(Failure(message: "Reconnect the same paired phone and retry Send."))); return nil
        }
        let value = Session(id: id, deviceID: deviceID, pairingToken: pairingToken, key: key,
                            bluetoothPeer: PhoneHotspotTransport.bluetoothPeer, remote: remote, completion: completion)
        // A previous transfer's queued cleanup still restores the user's Wi-Fi.
        // Only Pause, manual disconnect, or a pairing change may cancel it.
        value.originalSocket = WebSocketServer.shared.authenticatedSessionIdentity
        session = value
        isBusy = true
        if state.device?.isRegularConnection == true && WebSocketServer.shared.authenticatedSessionIdentity != nil && !remote {
            markConnected(value)
            return id
        }
        guard value.bluetoothPeer != nil else {
            fail(value, "Enable Bluetooth sync on both devices, or connect them to the same Wi-Fi, then retry Send.")
            return id
        }
        guard !HotspotWiFiConnector.shared.isBusy else {
            fail(value, "A hotspot connection is already in progress. Wait for it to finish, then retry Send.")
            return id
        }
        armDeadline(value, seconds: 120, message: "The transfer network didn't connect in time. Keep both apps open and retry Send.")
        switch location.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: requestNetwork(value)
        case .notDetermined:
            awaitingPermission = true
            statusMessage = "Allow Mac Location access to connect the transfer Wi-Fi."
            location.requestWhenInUseAuthorization()
        default:
            fail(value, "Allow androp in Mac Privacy & Security → Location Services, then retry Send. You can also connect both devices to the same Wi-Fi.")
        }
        return id
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self, self.awaitingPermission, let value = self.session else { return }
            switch self.location.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                self.awaitingPermission = false
                self.requestNetwork(value)
            case .denied, .restricted:
                self.fail(value, "Mac Location permission is needed to find the transfer network. Allow it, then retry Send.")
            default: break
            }
        }
    }

    private func requestNetwork(_ value: Session) {
        guard session === value, valid(value), !value.requested else { return }
        value.requested = true
        statusMessage = "Creating a temporary Wi-Fi connection…"
        guard send("start", value: value) else { fail(value, "Couldn't reach your phone over Bluetooth. Retry Send."); return }
        startHeartbeat(value)
    }

    /// Called only from the authenticated BLE bridge; AES-GCM additionally binds
    /// the protocol to the paired network key rather than an advertised name.
    func handleEnvelope(_ envelope: String, fromNetwork: Bool = false) {
        guard !AppState.shared.isSyncPaused,
              (fromNetwork ? WebSocketServer.shared.authenticatedSessionIdentity != nil : BLECentralManager.shared.isAuthenticated),
              let encoded = UserDefaults.standard.string(forKey: "encryptionKey"), let key = Data(base64Encoded: encoded),
              let payload = TransferNetworkProtocol.decode(envelope, key: key),
              let textID = payload["id"] as? String, let id = UUID(uuidString: textID),
              let action = payload["action"] as? String else { return }
        if fromNetwork {
            guard action != "request", let existing = session, existing.connected,
                  existing.key == key, AppState.shared.device?.deviceId == existing.deviceID else { return }
        }
        if action == "request" {
            if let existing = session, existing.id == id { return }
            recentRequests = recentRequests.filter { $0.value > Date() }
            guard recentRequests[id] == nil else { return }
            guard session == nil else {
                sendRejection(id: id, key: key, message: "Another transfer is using the connection. Finish it and retry.")
                return
            }
            guard let deviceID = AppState.shared.device?.deviceId else { return }
            if begin(id: id, deviceID: deviceID, pairingToken: UserDefaults.standard.string(forKey: "bleAuthToken"), remote: true, completion: nil) == nil {
                sendRejection(id: id, key: key, message: "Mac cannot start the connection. Resume androp and reconnect the paired phone.")
            }
            return
        }
        guard let value = session, value.id == id, valid(value), value.key == key else { return }
        switch action {
        case "ready":
            guard value.requested, !value.joining, !value.connected,
                  let ssid = payload["ssid"] as? String, let password = payload["password"] as? String else { return }
            value.joining = true
            value.temporarySSID = ssid
            statusMessage = "Connecting Wi-Fi for your files…"
            let attempt = value.attempt
            let owner = value.id
            HotspotWiFiWorker.queue.async {
                let result = HotspotWiFiWorker.joinTemporary(ssid: ssid, password: password, attempt: attempt, owner: owner)
                DispatchQueue.main.async { [weak self] in
                    // end() owns queued cleanup, including a synchronous
                    // association completing after cancellation. Never enqueue
                    // a second SSID-only cleanup from a stale completion.
                    guard let self, self.session === value else { return }
                    guard self.valid(value), let address = result.0 else { self.fail(value, result.1); return }
                    value.address = address
                    self.statusMessage = "Wi-Fi ready · reconnecting to your paired phone…"
                    self.sendEndpoint(value)
                    self.connectionChanged()
                }
            }
        case "error": fail(value, String((payload["message"] as? String ?? "The phone couldn't create a transfer network. Retry Send.").prefix(512)))
        case "stop": end(value, failure: !value.remote || !value.connected ? "Transfer connection cancelled on your phone." : nil, notify: false)
        case "keepAlive":
            if value.remote && value.connected {
                armDeadline(value, seconds: 90, message: "The phone stopped the transfer. Connection closed.")
                _ = send("connected", value: value)
            }
        default: break
        }
    }

    private func sendRejection(id: UUID, key: Data, message: String) {
        guard let envelope = TransferNetworkProtocol.encode(["v": 1, "id": id.uuidString, "action": "error", "message": message], key: key) else { return }
        _ = BLECentralManager.shared.writeChunked(characteristicUUID: BLEConstants.charMediaControl, payload: envelope)
    }

    private func valid(_ value: Session) -> Bool {
        guard !AppState.shared.isSyncPaused, !UserDefaults.standard.isManuallyDisconnected,
              UserDefaults.standard.string(forKey: "bleAuthToken") == value.pairingToken,
              UserDefaults.standard.string(forKey: "encryptionKey").flatMap({ Data(base64Encoded: $0) }) == value.key else { return false }
        if let peer = value.bluetoothPeer, PhoneHotspotTransport.bluetoothPeer != peer {
            guard (value.connected || hasFreshNetwork(value)), AppState.shared.device?.isRegularConnection == true,
                  AppState.shared.device?.deviceId == value.deviceID,
                  WebSocketServer.shared.authenticatedSessionIdentity != nil else { return false }
        }
        if let device = AppState.shared.device { return device.deviceId == value.deviceID }
        return value.bluetoothPeer != nil
    }

    private func hasFreshNetwork(_ value: Session) -> Bool {
        value.requested && value.address != nil &&
        AppState.shared.device?.deviceId == value.deviceID &&
        AppState.shared.device?.isRegularConnection == true &&
        WebSocketServer.shared.authenticatedSessionIdentity.map { $0 != value.originalSocket } == true
    }

    private func connectionChanged() {
        if AppState.shared.isSyncPaused || UserDefaults.standard.isManuallyDisconnected ||
            (cleanupKey != nil && (UserDefaults.standard.string(forKey: "encryptionKey").flatMap({ Data(base64Encoded: $0) }) != cleanupKey ||
             UserDefaults.standard.string(forKey: "bleAuthToken") != cleanupPairingToken)) {
            cleanupAttempt?.cancel()
        }
        guard let value = session else { return }
        guard valid(value) else { end(value, failure: "Transfer stopped: paused, disconnected, or the paired device changed.", notify: true); return }
        if AppState.shared.device?.deviceId == value.deviceID,
           AppState.shared.device?.isRegularConnection == true, !value.connected {
            // Temporary network requests must finish joining before declaring
            // success; an old socket can still exist during the Wi-Fi transition.
            guard value.requested, value.address != nil,
                  let fresh = WebSocketServer.shared.authenticatedSessionIdentity,
                  fresh != value.originalSocket else { return }
            markConnected(value)
        }
    }

    private func markConnected(_ value: Session) {
        guard session === value, valid(value), !value.connected else { return }
        value.connected = true
        endpointRetry?.cancel(); endpointRetry = nil
        deadline?.cancel(); deadline = nil
        statusMessage = "Wi-Fi connected · sending files"
        if value.remote {
            armDeadline(value, seconds: 90, message: "The phone stopped the transfer. Connection closed.")
            _ = send("connected", value: value)
        }
        let completion = value.completion; value.completion = nil
        completion?(.success(Void()))
    }

    private func sendEndpoint(_ value: Session) {
        guard session === value, valid(value), !value.connected, let address = value.address,
              value.endpointAttempts < 3 else { return }
        // Joining a hotspot can trigger a listener rebind. Never send the configured
        // port before it actually listens, or consume a retry while it is starting.
        var retryDelay: TimeInterval = 2
        if let endpoint = WebSocketServer.shared.getListeningNetworkEndpoint(),
           endpoint.adapters.contains(where: { $0.address == address }),
           let data = try? JSONSerialization.data(withJSONObject: ["type": "connectNetwork", "data": ["ip": address, "port": Int(endpoint.port)]]),
           let text = String(data: data, encoding: .utf8),
           BLECentralManager.shared.writeChunked(characteristicUUID: BLEConstants.charMediaControl, payload: text) {
            value.endpointAttempts += 1
            retryDelay = 17
        }
        // The original 120-second setup deadline still bounds these readiness checks.
        endpointRetry?.cancel()
        let retry = DispatchWorkItem { [weak self] in self?.sendEndpoint(value) }
        endpointRetry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: retry)
    }

    @discardableResult
    private func send(_ action: String, value: Session, message: String? = nil) -> Bool {
        var payload: [String: Any] = ["v": 1, "id": value.id.uuidString, "action": action]
        if let message { payload["message"] = message }
        guard let envelope = TransferNetworkProtocol.encode(payload, key: value.key) else { return false }
        if PhoneHotspotTransport.bluetoothPeer == value.bluetoothPeer, value.bluetoothPeer != nil,
           BLECentralManager.shared.writeChunked(characteristicUUID: BLEConstants.charMediaControl, payload: envelope) { return true }
        guard value.connected, AppState.shared.device?.deviceId == value.deviceID,
              UserDefaults.standard.string(forKey: "encryptionKey").flatMap({ Data(base64Encoded: $0) }) == value.key,
              WebSocketServer.shared.authenticatedSessionIdentity != nil else { return false }
        return WebSocketServer.shared.sendDataToFirstAvailable(Data(envelope.utf8))
    }

    private func startHeartbeat(_ value: Session) {
        heartbeat?.invalidate()
        // For phone-originated sends, the phone's foreground transfer owns the
        // heartbeat. Neither peer may keep an abandoned remote request alive.
        guard !value.remote else { return }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.session === value else { return }
                guard self.valid(value) else { self.fail(value, "The paired connection changed. Retry Send."); return }
                _ = self.send("keepAlive", value: value)
            }
        }
        heartbeat?.tolerance = 3
    }

    private func armDeadline(_ value: Session, seconds: TimeInterval, message: String) {
        deadline?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.session === value else { return }
            self.fail(value, message)
        }
        deadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func isActiveLease(id: UUID) -> Bool {
        guard let value = session, value.id == id else { return false }
        return value.connected && valid(value)
    }

    func cancel(id: UUID) { if let value = session, value.id == id { end(value, failure: "Transfer cancelled.", notify: true) } }
    func finish(id: UUID) { if let value = session, value.id == id { end(value, failure: nil, notify: true) } }
    private func fail(_ value: Session, _ message: String) { end(value, failure: message, notify: true) }

    private func end(_ value: Session, failure: String?, notify: Bool) {
        guard session === value else { return }
        value.attempt.cancel()
        deadline?.cancel(); deadline = nil
        endpointRetry?.cancel(); endpointRetry = nil
        heartbeat?.invalidate(); heartbeat = nil
        awaitingPermission = false
        if notify, value.requested || value.remote {
            if let failure { _ = send("error", value: value, message: failure) }
            _ = send("stop", value: value)
        }
        recentRequests[value.id] = Date().addingTimeInterval(300)
        if recentRequests.count > 64, let oldest = recentRequests.min(by: { $0.value < $1.value })?.key { recentRequests.removeValue(forKey: oldest) }
        session = nil
        isBusy = false
        statusMessage = failure
        if value.temporarySSID != nil {
            // Queued restorations share a live token, so Pause or a pairing change
            // cancels every release still waiting behind a CoreWLAN call.
            let cleanup: HotspotWiFiAttempt
            if let previous = cleanupAttempt, !previous.isCancelled { cleanup = previous } else { cleanup = HotspotWiFiAttempt() }
            if AppState.shared.isSyncPaused || UserDefaults.standard.isManuallyDisconnected ||
                UserDefaults.standard.string(forKey: "bleAuthToken") != value.pairingToken ||
                UserDefaults.standard.string(forKey: "encryptionKey").flatMap({ Data(base64Encoded: $0) }) != value.key {
                cleanup.cancel()
            }
            cleanupAttempt = cleanup
            cleanupKey = value.key
            cleanupPairingToken = value.pairingToken
            let owner = value.id
            HotspotWiFiWorker.queue.async { HotspotWiFiWorker.releaseTemporary(owner: owner, attempt: cleanup) }
        }
        if value.connected && !value.remote, let failure {
            QuickShareManager.shared.transferNetworkInvalidated(id: value.id, message: failure)
        }
        let completion = value.completion; value.completion = nil
        if let failure { completion?(.failure(Failure(message: failure))) }
    }
}
