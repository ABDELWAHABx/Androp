import Foundation
import CoreBluetooth
import Combine
import CryptoKit

class BLECentralManager: NSObject, ObservableObject {
    static let shared = BLECentralManager()
    
    private var centralManager: CBCentralManager!
    private var discoveredPeripheral: CBPeripheral?
    
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var chunkBuffers: [CBUUID: BLEChunkUtil.Reassembler] = [:]
    private struct PendingWrite {
        let uuid: CBUUID
        let data: Data
        let type: CBCharacteristicWriteType
    }
    private var pendingWrites: [PendingWrite] = []
    private var pendingWriteBytes = 0
    private var responseWriteInFlight = false
    private let maxPendingWriteBytes = 512 * 1024
    private let priorityCharacteristics: Set<CBUUID> = [BLEConstants.charMediaControl, BLEConstants.charNotificationAction, BLEConstants.charNotificationDismiss]
    private var discoveredServices: Set<CBUUID> = []
    private var requestedServices: Set<CBUUID> = []
    private var hasAttemptedAuth = false
    /// Reconnect handshake state: the Mac's nonce, and whether the phone proved itself.
    private var reconnectNonce: String?
    private var reconnectPhoneVerified = false
    private let expectedServiceCount = 4
    
    @Published var connectionStatus: BLEConnectionStatus = .disconnected
    @Published var connectedDeviceName: String? = nil
    @Published private(set) var bluetoothStatusMessage: String? = "Starting Bluetooth…"
    @Published private(set) var bluetoothPermissionDenied = false
    struct BLEDiscoveryRecord {
        let peripheral: CBPeripheral
        var lastSeen: Date
    }
    
    @Published var discoveredPeripherals: [String: BLEDiscoveryRecord] = [:]
    @Published var connectingDeviceUUID: String? = nil
    
    var isManuallyDisconnected = false
    
    var isConnected: Bool {
        connectionStatus != .disconnected && connectionStatus != .scanning
    }

    var isAuthenticated: Bool {
        connectionStatus == .authenticated
    }
    
    enum BLEConnectionStatus: Equatable {
        case disconnected
        case scanning
        case connected
        case authenticated
    }
    
    private var scanTimer: Timer?
    private var connectionTimer: Timer?
    private var discoveryBackoffStep = 0
    private var failureBackoffStep = 0
    private var rejectedPeers: [String: Date] = [:]
    private var authenticationTokenFingerprint: String?
    private struct QRPairingSession {
        let id: UUID
        let key: Data
        let deadline: Date
    }
    private var qrPairingSession: QRPairingSession?
    private var qrPairingTimer: Timer?
    private var qrPairingNonce: UUID?
    private var qrPairingResponse: BLEPairingProtocol.Payload?
    private let qrPairingChunks = BLEChunkUtil.Reassembler(maximumMessageBytes: BLEPairingProtocol.maximumEnvelopeBytes)
    private let scanWindow: TimeInterval = 10
    private var scanRestartWorkItem: DispatchWorkItem?
    private var scanRestartGeneration = 0
    private var isTearingDown = false
    private(set) var sessionGeneration = 0
    /// While set, discovery rests half a second instead of backing off (see BLELinkPolicy).
    private var reconnectBurstUntil: Date?
    // Heartbeat: an authenticated link that stops carrying anything is torn down and
    // reconnected instead of looking connected while dead.
    private var heartbeatTimer: Timer?
    private var heartbeatSequence = 0
    private var missedHeartbeats = 0
    private var heartbeatSupported = false
    private var notifyRetried: Set<CBUUID> = []
    // Instant reconnect (opt-in): once bonded, macOS can resolve the phone's rotating private
    // address, so a no-timeout pending connect reconnects the moment the phone is in range.
    @Published var instantReconnectEnabled = UserDefaults.standard.bool(forKey: "bleInstantReconnect") {
        didSet {
            UserDefaults.standard.set(instantReconnectEnabled, forKey: "bleInstantReconnect")
            if instantReconnectEnabled {
                bondIssue = nil
                if isAuthenticated, let peripheral = discoveredPeripheral { probeBondIfNeeded(peripheral) }
                else { armBondedReconnect() }
            } else { cancelBondedReconnect() }
        }
    }
    @Published private(set) var bondIssue: String?
    private var pendingBondedPeripheral: CBPeripheral?
    private var bondedReconnectRetry: DispatchWorkItem?
    // File lane: the phone's L2CAP channel for small files when there is no Wi-Fi.
    private(set) var fileLanePSM: CBL2CAPPSM?
    private var pendingLaneOpen: ((CBL2CAPChannel?) -> Void)?
    private var laneOpenTimeout: DispatchWorkItem?
    /// Held while authenticated so App Nap cannot stretch the heartbeat and reconnect timers.
    /// It allows idle system sleep; Pause on sleep tears the session down anyway.
    private var appNapActivity: NSObjectProtocol?
    
    override init() {
        super.init()
        // The isolated production-app lifecycle check must not request radio
        // permissions or create a Bluetooth connection on the CI runner.
        guard !LifecycleSelfTest.isRequested else { return }
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    #if BLE_LIFECYCLE_TESTS
    // The regression harness exercises this exact manager without creating a
    // Bluetooth radio or initializing the rest of the application.
    init(testingWithoutRadio: Bool) {
        super.init()
        precondition(testingWithoutRadio)
    }

    private(set) var scheduledScanDelayForTesting: TimeInterval?
    var hasPendingScanRestartForTesting: Bool { scanRestartWorkItem != nil }
    var automaticConnectionAllowedForTesting: Bool { automaticConnectionAllowed }
    var hasQRPairingWindowForTesting: Bool { activeQRPairingSession != nil }
    func finishDiscoveryWindowForTesting() { finishDiscoveryWindow() }
    func retryTransportFailureForTesting() { retryAfterTransportFailure() }
    func rememberPeerForTesting(_ uuid: String) { rememberAuthenticatedPeer(uuid) }
    func mayAutomaticallyConnectForTesting(to uuid: String, now: Date = Date()) -> Bool {
        mayAutomaticallyConnect(to: uuid, now: now)
    }
    func rejectAuthenticationForTesting(peerUUID: String) { rejectAuthentication(peerUUID: peerUUID) }
    func scheduleScanRestartForTesting(after delay: TimeInterval) {
        scheduleAutomaticScanRestart(after: delay)
    }
    var reconnectBurstActiveForTesting: Bool { BLELinkPolicy.inReconnectBurst(until: reconnectBurstUntil) }
    func endReconnectBurstForTesting() { reconnectBurstUntil = nil }
    #endif

    /// Scan almost continuously for a minute: after a lost link, a wake from sleep, or the radio
    /// coming back, the phone is most likely nearby and advertising fast for the same minute.
    func beginReconnectBurst() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.beginReconnectBurst() }
            return
        }
        reconnectBurstUntil = Date().addingTimeInterval(BLELinkPolicy.reconnectBurst)
        discoveryBackoffStep = 0
        failureBackoffStep = 0
        // Replace a long rest that is already queued.
        if scanRestartWorkItem != nil { scheduleAutomaticScanRestart(after: BLELinkPolicy.burstRescanDelay) }
    }

    // Wi-Fi is an independent transport, not a reason to tear down BLE.
    // AppState can request discovery on meaningful lifecycle events without
    // shortening a pending cooldown or creating a second reconnect timer.
    func ensureAutomaticConnection() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.ensureAutomaticConnection() }
            return
        }
        armBondedReconnect()
        guard automaticConnectionAllowed, scanRestartWorkItem == nil,
              connectionStatus == .disconnected, discoveredPeripheral == nil else { return }
        startScanning()
    }

    private var automaticConnectionAllowed: Bool {
        AppState.shared.isBLEEnabled &&
        !AppState.shared.isSyncPaused && !isManuallyDisconnected && !isTearingDown &&
        !UserDefaults.standard.bool(forKey: "isManuallyDisconnected") &&
        (activeQRPairingSession != nil || (AppState.shared.isBLEAutoConnectEnabled &&
        !(UserDefaults.standard.string(forKey: "bleAuthToken") ?? "").isEmpty))
    }

    private var activeQRPairingSession: QRPairingSession? {
        guard let session = qrPairingSession, Date() < session.deadline,
              let encoded = UserDefaults.standard.string(forKey: "encryptionKey"),
              Data(base64Encoded: encoded) == session.key else { return nil }
        return session
    }

    /// Only revealing the authenticated QR enables first contact with unknown advertisers.
    @discardableResult
    func beginQRPairing(id: UUID, key: Data) -> Bool {
        guard Thread.isMainThread, !AppState.shared.isSyncPaused, AppState.shared.isBLEEnabled,
              !isAuthenticated, key.count == 32 else { return false }
        endQRPairing()
        if discoveredPeripheral != nil { tearDownConnection(cancelPeripheral: true) }
        qrPairingSession = QRPairingSession(id: id, key: key,
            deadline: Date().addingTimeInterval(BLEPairingProtocol.windowDuration))
        qrPairingTimer = Timer.scheduledTimer(withTimeInterval: BLEPairingProtocol.windowDuration, repeats: false) { [weak self] _ in
            self?.endQRPairing()
        }
        isManuallyDisconnected = false
        UserDefaults.standard.set(false, forKey: "isManuallyDisconnected")
        discoveryBackoffStep = 0
        failureBackoffStep = 0
        rejectedPeers.removeAll()
        cancelPendingScanRestart()
        startScanning()
        return true
    }

    func endQRPairing() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.endQRPairing() }
            return
        }
        let wasPairing = qrPairingSession != nil
        qrPairingSession = nil
        qrPairingTimer?.invalidate()
        qrPairingTimer = nil
        qrPairingNonce = nil
        qrPairingResponse = nil
        qrPairingChunks.clear()
        if wasPairing && !isAuthenticated { tearDownConnection(cancelPeripheral: true) }
    }

    private func tokenFingerprint() -> String? {
        guard let token = UserDefaults.standard.string(forKey: "bleAuthToken"), !token.isEmpty else { return nil }
        return SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func rememberAuthenticatedPeer(_ uuid: String) {
        guard let fingerprint = tokenFingerprint() else { return }
        UserDefaults.standard.set(uuid, forKey: "bleAuthenticatedPeerUUID")
        UserDefaults.standard.set(fingerprint, forKey: "bleAuthenticatedTokenFingerprint")
    }

    private func mayAutomaticallyConnect(to uuid: String, manufacturerData: Data? = nil, now: Date = Date()) -> Bool {
        if let deadline = rejectedPeers[uuid], deadline > now { return false }
        if activeQRPairingSession != nil { return true }
        guard let fingerprint = tokenFingerprint() else { return false }
        // The paired phone proves it holds the token in its advertisement, so a new
        // private Bluetooth address (Android rotates it) no longer blocks reconnects.
        if let token = UserDefaults.standard.string(forKey: "bleAuthToken"),
           BLEAdvertisementProof.verifies(manufacturerData: manufacturerData, token: token, now: now) {
            return true
        }
        // A newly paired phone has a different token, so its first BLE contact
        // can establish a new pin. Never send the existing token to other
        // advertisers after its authenticated peripheral has been learned.
        if UserDefaults.standard.string(forKey: "bleAuthenticatedTokenFingerprint") == fingerprint,
           let pinned = UserDefaults.standard.string(forKey: "bleAuthenticatedPeerUUID") {
            return pinned == uuid
        }
        return true
    }

    private func finishDiscoveryWindow() {
        guard connectionStatus == .scanning, discoveredPeripheral == nil else { return }
        stopScanning()
        let now = Date()
        discoveredPeripherals = discoveredPeripherals.filter { now.timeIntervalSince($0.value.lastSeen) <= 120 }
        rejectedPeers = rejectedPeers.filter { $0.value > now }
        // A visible pairing code is waiting for a phone that may start advertising
        // at any moment, and the code expires in two minutes. Rest briefly instead
        // of backing off for up to a minute.
        if activeQRPairingSession != nil {
            scheduleAutomaticScanRestart(after: 1)
            return
        }
        if BLELinkPolicy.inReconnectBurst(until: reconnectBurstUntil) {
            scheduleAutomaticScanRestart(after: BLELinkPolicy.burstRescanDelay)
            return
        }
        // Established BLE connections have no scan timer.
        // Ten seconds of discovery, then 5, 10, 20 and at most 30 seconds of rest,
        // so a phone coming back into range reconnects within about half a minute.
        let delay = min(30, 5 * pow(2, Double(discoveryBackoffStep)))
        discoveryBackoffStep = min(discoveryBackoffStep + 1, 3)
        scheduleAutomaticScanRestart(after: delay)
    }

    private func retryAfterTransportFailure() {
        if activeQRPairingSession != nil, let peer = discoveredPeripheral {
            // The phone may not have scanned yet; revisit it after a short rest,
            // while giving other nearby candidates an opportunity to prove the QR key.
            rejectedPeers[peer.identifier.uuidString] = Date().addingTimeInterval(10)
        }
        tearDownConnection(cancelPeripheral: true)
        // During a visible pairing window, a phone that is still starting its GATT
        // server must be revisited within seconds, not after a multi-minute backoff.
        if activeQRPairingSession != nil {
            scheduleAutomaticScanRestart(after: 1)
            return
        }
        if BLELinkPolicy.inReconnectBurst(until: reconnectBurstUntil) {
            scheduleAutomaticScanRestart(after: BLELinkPolicy.burstRescanDelay)
            return
        }
        let delay = min(30, 3 * pow(2, Double(failureBackoffStep)))
        failureBackoffStep = min(failureBackoffStep + 1, 4)
        scheduleAutomaticScanRestart(after: delay)
    }

    private func rejectAuthentication(peerUUID: String) {
        // Bad credentials are different from a transient timeout. A rejected
        // advertiser gets a five-minute cooldown, without stopping discovery
        // of a different newly paired phone or changing explicit user intent.
        if rejectedPeers.count >= 64 { rejectedPeers = rejectedPeers.filter { $0.value > Date() } }
        if rejectedPeers.count >= 64, let oldest = rejectedPeers.min(by: { $0.value < $1.value })?.key {
            rejectedPeers.removeValue(forKey: oldest)
        }
        rejectedPeers[peerUUID] = Date().addingTimeInterval(activeQRPairingSession == nil ? 60 : 10)
        retryAfterTransportFailure()
    }

    func startScanning() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.startScanning() }
            return
        }
        guard !isTearingDown, centralManager?.state == .poweredOn, AppState.shared.isBLEEnabled, !AppState.shared.isSyncPaused,
              !isManuallyDisconnected, !UserDefaults.standard.bool(forKey: "isManuallyDisconnected"),
              discoveredPeripheral == nil, connectingDeviceUUID == nil else { return }
        
        guard connectionStatus != .scanning else { return }

        cancelPendingScanRestart()
        print("[BLE] Starting scan...")
        connectionStatus = .scanning
        
        centralManager.stopScan()
        scanTimer?.invalidate()
        scanTimer = nil
        
        centralManager.scanForPeripherals(withServices: [BLEConstants.serviceSystem], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        
        scanTimer = Timer.scheduledTimer(withTimeInterval: scanWindow, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishDiscoveryWindow() }
        }
    }
    
    func stopScanning() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.stopScanning() }
            return
        }
        cancelPendingScanRestart()
        scanTimer?.invalidate()
        scanTimer = nil
        centralManager?.stopScan()
        // Stopping discovery must never call disconnect: disconnect itself
        // stops discovery. That cycle exhausted the stack when paused while
        // scanning, even with no paired or connected phone.
        if connectionStatus == .scanning { connectionStatus = .disconnected }
    }

    func disconnect(restartScanning: Bool = false) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.disconnect(restartScanning: restartScanning) }
            return
        }
        guard !isTearingDown else { return }
        if !restartScanning { endQRPairing(); reconnectBurstUntil = nil }
        isManuallyDisconnected = !restartScanning
        tearDownConnection(cancelPeripheral: true)
        if restartScanning {
            discoveryBackoffStep = 0
            failureBackoffStep = 0
            rejectedPeers.removeAll()
            ensureAutomaticConnection()
        }
    }

    private func tearDownConnection(cancelPeripheral: Bool) {
        guard !isTearingDown else { return }
        isTearingDown = true
        sessionGeneration &+= 1
        defer { isTearingDown = false }
        stopScanning()
        connectionTimer?.invalidate()
        connectionTimer = nil
        let previousPeripheral = discoveredPeripheral
        // Forget the old session before cancellation or published changes can
        // invoke callbacks. Late callbacks must not resurrect or clear a new one.
        discoveredPeripheral = nil
        connectingDeviceUUID = nil
        clearTransportState()
        connectionStatus = .disconnected
        connectedDeviceName = nil
        discoveredPeripherals.removeAll()
        previousPeripheral?.delegate = nil
        if cancelPeripheral, let peripheral = previousPeripheral,
           centralManager?.state == .poweredOn {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        if AppState.shared.device?.isBLE == true { AppState.shared.device = nil }
        // Manual disconnect and Pause make automatic connection disallowed, so this only
        // re-arms the bonded phone after an ordinary drop or failure. Deferred: teardown
        // itself counts as disallowed until it returns.
        cancelBondedReconnect()
        DispatchQueue.main.async { [weak self] in self?.armBondedReconnect() }
    }

    private func cancelPendingScanRestart() {
        scanRestartGeneration &+= 1
        scanRestartWorkItem?.cancel()
        scanRestartWorkItem = nil
        #if BLE_LIFECYCLE_TESTS
        scheduledScanDelayForTesting = nil
        #endif
    }

    private func scheduleAutomaticScanRestart(after delay: TimeInterval) {
        cancelPendingScanRestart()
        guard automaticConnectionAllowed, discoveredPeripheral == nil, !isConnected else { return }
        #if BLE_LIFECYCLE_TESTS
        scheduledScanDelayForTesting = delay
        #endif
        let generation = scanRestartGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.scanRestartGeneration == generation else { return }
            self.scanRestartWorkItem = nil
            guard self.automaticConnectionAllowed else { return }
            self.startScanning()
        }
        scanRestartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func clearTransportState() {
        characteristics.removeAll()
        chunkBuffers.removeAll()
        discoveredServices.removeAll()
        requestedServices.removeAll()
        pendingWrites.removeAll()
        pendingWriteBytes = 0
        responseWriteInFlight = false
        hasAttemptedAuth = false
        reconnectNonce = nil
        reconnectPhoneVerified = false
        authenticationTokenFingerprint = nil
        qrPairingNonce = nil
        qrPairingResponse = nil
        qrPairingChunks.clear()
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        missedHeartbeats = 0
        heartbeatSupported = false
        notifyRetried.removeAll()
        if let activity = appNapActivity {
            ProcessInfo.processInfo.endActivity(activity)
            appNapActivity = nil
        }
        fileLanePSM = nil
        finishLaneOpen(nil)
    }

    // MARK: Instant reconnect (bonding)

    private var bondedPeerUUID: UUID? {
        UserDefaults.standard.string(forKey: "bleBondedPeerUUID").flatMap(UUID.init(uuidString:))
    }

    private func probeBondIfNeeded(_ peripheral: CBPeripheral) {
        let peer = peripheral.identifier.uuidString
        let defaults = UserDefaults.standard
        guard isAuthenticated, let probe = characteristics[BLEConstants.charBondProbe],
              BLELinkPolicy.mayProbeBond(enabled: instantReconnectEnabled,
                                        bondedPeer: defaults.string(forKey: "bleBondedPeerUUID"), peer: peer,
                                        lastAttemptPeer: defaults.string(forKey: "bleBondAttemptPeer"),
                                        lastAttempt: defaults.object(forKey: "bleBondAttemptAt") as? Date) else { return }
        defaults.set(peer, forKey: "bleBondAttemptPeer")
        defaults.set(Date(), forKey: "bleBondAttemptAt")
        print("[BLE] Pairing with the phone for instant reconnect")
        peripheral.readValue(for: probe)
    }

    private func handleBondProbe(_ peripheral: CBPeripheral, error: Error?) {
        guard peripheral === discoveredPeripheral else { return }
        if let error {
            // Declined or failed prompt: mayProbeBond waits a day before asking again.
            print("[BLE] Phone pairing for instant reconnect failed: \(error.localizedDescription)")
            return
        }
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "bleBondedPeerUUID")
        bondIssue = nil
        print("[BLE] Bonded with the phone; reconnects no longer need a scan")
    }

    /// A pending connect has no timeout: macOS completes it whenever the bonded phone advertises.
    private func armBondedReconnect() {
        guard Thread.isMainThread, instantReconnectEnabled, pendingBondedPeripheral == nil,
              discoveredPeripheral == nil, activeQRPairingSession == nil, automaticConnectionAllowed,
              centralManager?.state == .poweredOn, let id = bondedPeerUUID,
              let peripheral = centralManager.retrievePeripherals(withIdentifiers: [id]).first else { return }
        bondedReconnectRetry?.cancel()
        bondedReconnectRetry = nil
        pendingBondedPeripheral = peripheral
        centralManager.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    }

    private func cancelBondedReconnect() {
        bondedReconnectRetry?.cancel()
        bondedReconnectRetry = nil
        guard let peripheral = pendingBondedPeripheral else { return }
        pendingBondedPeripheral = nil
        // Never cancel the session we are adopting or already running.
        if peripheral !== discoveredPeripheral, centralManager?.state == .poweredOn {
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    private func retryBondedReconnectLater() {
        bondedReconnectRetry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.bondedReconnectRetry = nil
            self?.armBondedReconnect()
        }
        bondedReconnectRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + BLELinkPolicy.bondedReconnectRetry, execute: work)
    }

    /// The phone dropped its half of the pairing (unpaired in Settings, reset). macOS keeps its
    /// half and the app cannot remove it, so tell the user, and stop relying on the bond.
    private func handleBondLossIfNeeded(_ error: Error?) {
        guard let error = error as? CBError, error.code == .peerRemovedPairingInformation else { return }
        UserDefaults.standard.removeObject(forKey: "bleBondedPeerUUID")
        cancelBondedReconnect()
        bondIssue = "Your phone forgot this Mac's Bluetooth pairing. Remove the phone in System Settings → Bluetooth, then reconnect."
    }

    // MARK: File lane (L2CAP)

    var fileLaneAvailable: Bool { isAuthenticated && fileLanePSM != nil }

    /// Opens a fresh L2CAP channel to the phone's file lane. One open at a time; nil on failure.
    func openFileLane(completion: @escaping (CBL2CAPChannel?) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { completion(nil); return }
                self.openFileLane(completion: completion)
            }
            return
        }
        guard isAuthenticated, !AppState.shared.isSyncPaused, pendingLaneOpen == nil,
              let peripheral = discoveredPeripheral, let psm = fileLanePSM else { completion(nil); return }
        pendingLaneOpen = completion
        let timeout = DispatchWorkItem { [weak self] in self?.finishLaneOpen(nil) }
        laneOpenTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
        peripheral.openL2CAPChannel(psm)
    }

    private func finishLaneOpen(_ channel: CBL2CAPChannel?) {
        laneOpenTimeout?.cancel()
        laneOpenTimeout = nil
        let completion = pendingLaneOpen
        pendingLaneOpen = nil
        completion?(channel)
    }

    private func startHeartbeat() {
        if appNapActivity == nil {
            appNapActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Keeping the phone's Bluetooth link responsive")
        }
        heartbeatTimer?.invalidate()
        missedHeartbeats = 0
        heartbeatSupported = false
        let generation = sessionGeneration
        let timer = Timer(timeInterval: BLELinkPolicy.heartbeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.heartbeatTick(generation: generation) }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    private func heartbeatTick(generation: Int) {
        guard sessionGeneration == generation, isAuthenticated, !AppState.shared.isSyncPaused else {
            heartbeatTimer?.invalidate()
            heartbeatTimer = nil
            return
        }
        if BLELinkPolicy.linkIsDead(heartbeatSupported: heartbeatSupported, missedHeartbeats: missedHeartbeats) {
            print("[BLE] Phone stopped answering; reconnecting")
            beginReconnectBurst()
            retryAfterTransportFailure()
            return
        }
        heartbeatSequence &+= 1
        // Also keeps the phone's own watchdog satisfied when only it has been sending.
        if let ping = BLELinkPolicy.pingPayload(id: heartbeatSequence),
           writeChunked(characteristicUUID: BLEConstants.charMediaControl, payload: ping) {
            missedHeartbeats += 1
        }
    }

    func write(characteristicUUID: CBUUID, data: Data) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.write(characteristicUUID: characteristicUUID, data: data) }
            return
        }
        guard !AppState.shared.isSyncPaused, let peripheral = discoveredPeripheral,
              peripheral.state == .connected, let char = characteristics[characteristicUUID],
              char.properties.contains(.write) || char.properties.contains(.writeWithoutResponse),
              characteristicUUID == BLEConstants.charAuthToken || isAuthenticated else { return }
        let type: CBCharacteristicWriteType = characteristicUUID != BLEConstants.charAuthToken && char.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        guard data.count <= peripheral.maximumWriteValueLength(for: type),
              pendingWriteBytes + data.count <= maxPendingWriteBytes, pendingWrites.count < 32768 else { return }
        pendingWrites.append(PendingWrite(uuid: characteristicUUID, data: data, type: type))
        pendingWriteBytes += data.count
        drainWrites()
    }

    @discardableResult
    func writeChunked(characteristicUUID: CBUUID, payload: String) -> Bool {
        // CoreBluetooth and this queue are main-thread confined. Synchronous
        // callers need an actual acceptance result: never schedule a future send
        // and report success before authentication/capacity checks can run.
        // In particular, do not main.sync here: callers can hold transport locks.
        guard Thread.isMainThread else { return false }
        guard isAuthenticated, !AppState.shared.isSyncPaused, let peripheral = discoveredPeripheral,
              let char = characteristics[characteristicUUID],
              char.properties.contains(.write) || char.properties.contains(.writeWithoutResponse) else { return false }
        let type: CBCharacteristicWriteType = char.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let chunks = BLEChunkUtil.splitIntoChunks(payload: payload, mtu: peripheral.maximumWriteValueLength(for: type))
        guard !chunks.isEmpty else { return false }
        let byteCount = chunks.reduce(0) { $0 + $1.count }
        // Enqueue whole messages atomically so queue pressure cannot truncate one.
        guard pendingWriteBytes + byteCount <= maxPendingWriteBytes, pendingWrites.count + chunks.count < 32768 else { return false }
        let message = chunks.map { PendingWrite(uuid: characteristicUUID, data: $0, type: type) }
        if priorityCharacteristics.contains(characteristicUUID) {
            // Preserve control ordering while bypassing pending clipboard/media packets.
            let index = pendingWrites.firstIndex { !priorityCharacteristics.contains($0.uuid) } ?? pendingWrites.endIndex
            pendingWrites.insert(contentsOf: message, at: index)
        } else {
            pendingWrites.append(contentsOf: message)
        }
        pendingWriteBytes += byteCount
        drainWrites()
        return true
    }

    private func drainWrites() {
        guard !responseWriteInFlight, let peripheral = discoveredPeripheral, peripheral.state == .connected else { return }
        while let next = pendingWrites.first {
            guard next.type != .withoutResponse || peripheral.canSendWriteWithoutResponse else { return }
            pendingWrites.removeFirst()
            pendingWriteBytes -= next.data.count
            guard let characteristic = characteristics[next.uuid] else { continue }
            responseWriteInFlight = next.type == .withResponse
            peripheral.writeValue(next.data, for: characteristic, type: next.type)
            if responseWriteInFlight { return }
        }
    }

    var discoveredBLEDevices: [DiscoveredDevice] {
        let token = UserDefaults.standard.string(forKey: "bleAuthToken") ?? ""
        if token.isEmpty {
            return []
        }
        
        let preferredName = AppState.getPreferredDeviceName(fallback: nil)
        return discoveredPeripherals.values.map { record in
            DiscoveredDevice(
                deviceId: record.peripheral.identifier.uuidString,
                name: preferredName.isEmpty ? (record.peripheral.name ?? "Android Device") : preferredName,
                ips: ["Bluetooth LE"],
                port: 0,
                type: "ble",
                lastSeen: record.lastSeen
            )
        }
    }
    
    func connectManually(toUuid uuidStr: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.connectManually(toUuid: uuidStr) }
            return
        }
        guard !isTearingDown, centralManager?.state == .poweredOn,
              AppState.shared.isBLEEnabled, !AppState.shared.isSyncPaused,
              discoveredPeripheral == nil, connectingDeviceUUID == nil else { return }
        let token = UserDefaults.standard.string(forKey: "bleAuthToken") ?? ""
        if token.isEmpty {
            print("[BLE] Cannot connect manually: Devices have never been paired via QR/Wi-Fi before.")
            return
        }
        
        guard connectionStatus == .disconnected || connectionStatus == .scanning else {
            print("[BLE] Already connecting or connected (status: \(connectionStatus))")
            return
        }
        
        guard let record = discoveredPeripherals[uuidStr] else { return }
        let peripheral = record.peripheral
        print("[BLE] Manual connection requested for \(peripheral.name ?? "Unknown")")
        
        isManuallyDisconnected = false
        UserDefaults.standard.set(false, forKey: "isManuallyDisconnected")
        rejectedPeers.removeValue(forKey: uuidStr)
        stopScanning()
        if pendingBondedPeripheral === peripheral { pendingBondedPeripheral = nil } else { cancelBondedReconnect() }
        discoveredPeripheral = peripheral
        connectingDeviceUUID = uuidStr
        centralManager.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])
        
        connectionTimer?.invalidate()
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self, weak peripheral] _ in
            guard let self = self, let peripheral = peripheral,
                  self.discoveredPeripheral === peripheral else { return }
            print("[BLE] Manual connection timed out, cancelling...")
            self.retryAfterTransportFailure()
        }
    }
    

}

extension BLECentralManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothPermissionDenied = central.state == .unauthorized
        switch central.state {
        case .poweredOn: bluetoothStatusMessage = nil
        case .poweredOff: bluetoothStatusMessage = "Turn on Bluetooth on your Mac."
        case .unauthorized: bluetoothStatusMessage = "Allow androp in System Settings → Privacy & Security → Bluetooth."
        case .unsupported: bluetoothStatusMessage = "Bluetooth is unavailable. Pair over Wi-Fi instead."
        case .resetting, .unknown: bluetoothStatusMessage = "Starting Bluetooth…"
        @unknown default: bluetoothStatusMessage = "Bluetooth is unavailable. Pair over Wi-Fi instead."
        }
        if central.state == .poweredOn {
            if AppState.shared.isBLEEnabled {
                print("[BLE] Bluetooth powered on, starting scan")
                beginReconnectBurst()
                ensureAutomaticConnection()
            }
        } else {
            print("[BLE] Bluetooth state changed: \(central.state.rawValue)")
            // Radio-off previously only changed the label: stale peripherals,
            // pending writes and timers survived and prevented reconnection.
            tearDownConnection(cancelPeripheral: false)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        guard AppState.shared.isBLEEnabled, !AppState.shared.isSyncPaused, connectionStatus == .scanning else { return }
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Unknown"
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let uuidStr = peripheral.identifier.uuidString
        let isNewDevice = discoveredPeripherals[uuidStr] == nil
        if isNewDevice {
            print("[BLE] Discovered \(name) with RSSI: \(RSSI), Services: \(serviceUUIDs.map { $0.uuidString }.joined(separator: ", "))")
        }
        
        discoveredPeripherals[uuidStr] = BLEDiscoveryRecord(peripheral: peripheral, lastSeen: Date())
        
        // Auto connect if enabled and not manually disconnected
        if automaticConnectionAllowed {
            guard connectionStatus == .disconnected || connectionStatus == .scanning else { return }
            guard discoveredPeripheral == nil else { return }

            guard mayAutomaticallyConnect(to: uuidStr,
                manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data) else { return }

            stopScanning()
            if pendingBondedPeripheral === peripheral { pendingBondedPeripheral = nil } else { cancelBondedReconnect() }
            discoveredPeripheral = peripheral
            connectingDeviceUUID = uuidStr
            
            print("[BLE] Attempting auto-connect to \(name)...")
            centralManager.connect(peripheral, options: [
                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
            ])
            
            // CoreBluetooth connect() has no timeout — it can hang forever with stale pairing data.
            connectionTimer?.invalidate()
            connectionTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self, weak peripheral] _ in
                guard let self = self, let peripheral = peripheral,
                      self.discoveredPeripheral === peripheral else { return }
                print("[BLE] Connection timed out, cancelling and retrying...")
                self.retryAfterTransportFailure()
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if peripheral === pendingBondedPeripheral {
            pendingBondedPeripheral = nil
            if discoveredPeripheral == nil, automaticConnectionAllowed {
                // The bonded phone came into range: adopt it like a scanned, connected peer.
                print("[BLE] Bonded phone reconnected without a scan")
                stopScanning()
                cancelPendingScanRestart()
                discoveredPeripheral = peripheral
            }
        }
        guard peripheral === discoveredPeripheral, !AppState.shared.isSyncPaused,
              AppState.shared.isBLEEnabled else {
            if peripheral === discoveredPeripheral { tearDownConnection(cancelPeripheral: true) }
            else { central.cancelPeripheralConnection(peripheral) }
            return
        }
        connectionTimer?.invalidate()
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self, weak peripheral] _ in
            guard let self = self, let peripheral = peripheral,
                  self.discoveredPeripheral === peripheral else { return }
            self.retryAfterTransportFailure()
        }
        connectingDeviceUUID = peripheral.identifier.uuidString
        clearTransportState()
        sessionGeneration &+= 1
        let name = peripheral.name ?? "Unknown Device"
        let maxWrite = peripheral.maximumWriteValueLength(for: .withoutResponse)
        print("[BLE] Connected to \(name), Max Write Length: \(maxWrite)")
        connectionStatus = .connected
        peripheral.delegate = self
        peripheral.discoverServices([BLEConstants.serviceSystem, BLEConstants.serviceNotifications, BLEConstants.serviceMedia, BLEConstants.serviceClipboard])
        
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        handleBondLossIfNeeded(error)
        if peripheral === pendingBondedPeripheral {
            pendingBondedPeripheral = nil
            retryBondedReconnectLater()
            return
        }
        guard peripheral === discoveredPeripheral else { return }
        print("[BLE] Failed to connect: \(error?.localizedDescription ?? "Unknown error")")
        retryAfterTransportFailure()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        handleBondLossIfNeeded(error)
        if peripheral === pendingBondedPeripheral, peripheral !== discoveredPeripheral {
            pendingBondedPeripheral = nil
            retryBondedReconnectLater()
            return
        }
        guard peripheral === discoveredPeripheral else { return }
        print("[BLE] Disconnected: \(error?.localizedDescription ?? "clean")")
        // A working link that dropped usually means a brief range or radio blip: look again at once.
        if isAuthenticated { beginReconnectBurst() }
        retryAfterTransportFailure()
    }
}

extension BLECentralManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === discoveredPeripheral, !AppState.shared.isSyncPaused,
              AppState.shared.isBLEEnabled else { return }
        if let error = error {
            print("[BLE] Error discovering services: \(error.localizedDescription)")
            return
        }
        guard let rawServices = peripheral.services as NSArray? else { return }
        let validServices = rawServices.compactMap { $0 as? CBService }
        for service in validServices {
            if !requestedServices.contains(service.uuid) {
                requestedServices.insert(service.uuid)
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === discoveredPeripheral, !AppState.shared.isSyncPaused,
              AppState.shared.isBLEEnabled else { return }
        if let error = error {
            print("[BLE] Error discovering characteristics for \(service.uuid): \(error.localizedDescription)")
            return
        }
        guard let rawChars = service.characteristics as NSArray? else { return }
        let validChars = rawChars.compactMap { $0 as? CBCharacteristic }
        print("[BLE] Discovered \(validChars.count) characteristics for service \(service.uuid)")
        for char in validChars {
            characteristics[char.uuid] = char
            
            if char.properties.contains(.notify) && !char.isNotifying {
                print("[BLE] Subscribing to \(char.uuid)")
                peripheral.setNotifyValue(true, for: char)
            }
        }
        
        discoveredServices.insert(service.uuid)
        print("[BLE] Services discovered: \(discoveredServices.count)/\(expectedServiceCount)")
        
        authenticateWhenReady(peripheral)
    }

    private func authenticateWhenReady(_ peripheral: CBPeripheral) {
        guard discoveredServices.count >= expectedServiceCount, !hasAttemptedAuth,
              characteristics[BLEConstants.charAuthToken] != nil,
              characteristics[BLEConstants.charAuthResult]?.isNotifying == true,
              characteristics.values.filter({ $0.properties.contains(.notify) }).allSatisfy({ $0.isNotifying }) else { return }
        hasAttemptedAuth = true
        attemptAuthentication()
    }

    private func attemptAuthentication() {
        guard connectionStatus == .connected, !AppState.shared.isSyncPaused else { return }
        if let session = activeQRPairingSession {
            let nonce = UUID()
            let request = BLEPairingProtocol.Payload(v: 1, action: "request", pairing: session.id.uuidString.lowercased(), nonce: nonce.uuidString.lowercased())
            qrPairingNonce = nonce
            qrPairingResponse = nil
            qrPairingChunks.clear()
            // Authentication writes permit chunked proofs, but never a bearer token to an unknown peer.
            if !sendQRPairingProof(request, key: session.key) { retryAfterTransportFailure() }
            return
        }
        let token = UserDefaults.standard.string(forKey: "bleAuthToken") ?? ""
        if !token.isEmpty {
            // Ask the phone to prove it holds the pairing token first; the token
            // itself is never written to the peripheral.
            print("[BLE] Attempting authentication...")
            authenticationTokenFingerprint = tokenFingerprint()
            let nonce = BLEPairingProtocol.newReconnectNonce()
            reconnectNonce = nonce
            reconnectPhoneVerified = false
            qrPairingChunks.clear()
            guard let hello = BLEPairingProtocol.reconnectHello(nonce: nonce),
                  sendFramedAuthentication(hello) else { retryAfterTransportFailure(); return }
        } else {
            print("[BLE] Auth token is empty, skipping auth and disconnecting because they have never paired")
            tearDownConnection(cancelPeripheral: true)
        }
    }

    private func sendQRPairingProof(_ payload: BLEPairingProtocol.Payload, key: Data) -> Bool {
        guard let envelope = BLEPairingProtocol.encode(payload, key: key),
              activeQRPairingSession != nil else { return false }
        return sendFramedAuthentication(envelope)
    }

    private func sendFramedAuthentication(_ payload: String) -> Bool {
        guard payload.utf8.count <= BLEPairingProtocol.maximumEnvelopeBytes, let peripheral = discoveredPeripheral else { return false }
        // withResponse may advertise 512-byte long writes even at ATT MTU 23.
        // Android deliberately rejects prepared writes, so fit each packet to the immediate ATT payload.
        let capacity = min(peripheral.maximumWriteValueLength(for: .withResponse),
                           peripheral.maximumWriteValueLength(for: .withoutResponse))
        let chunks = BLEChunkUtil.splitIntoChunks(payload: payload, mtu: capacity)
        guard !chunks.isEmpty, pendingWriteBytes + chunks.reduce(0, { $0 + $1.count }) <= maxPendingWriteBytes,
              pendingWrites.count + chunks.count < 32768 else { return false }
        for chunk in chunks { write(characteristicUUID: BLEConstants.charAuthToken, data: chunk) }
        return true
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === discoveredPeripheral, !AppState.shared.isSyncPaused else { return }
        if characteristic.uuid == BLEConstants.charBondProbe {
            handleBondProbe(peripheral, error: error)
            return
        }
        if characteristic.uuid == BLEConstants.charFileLanePSM {
            if error == nil, isAuthenticated, let value = characteristic.value, value.count == 2 {
                let psm = CBL2CAPPSM(value[value.startIndex]) << 8 | CBL2CAPPSM(value[value.startIndex + 1])
                fileLanePSM = psm == 0 ? nil : psm
            }
            return
        }
        if let error = error {
            print("[BLE] Error updating value for characteristic \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value, characteristic.uuid == BLEConstants.charAuthResult || isAuthenticated else { return }
        // Anything arriving proves the link works.
        missedHeartbeats = 0
        
        switch characteristic.uuid {
        case BLEConstants.charAuthResult:
            if let session = activeQRPairingSession, let nonce = qrPairingNonce, qrPairingResponse == nil {
                guard connectionStatus == .connected, hasAttemptedAuth else { return }
                if data.count == 1 { rejectAuthentication(peerUUID: peripheral.identifier.uuidString); return }
                guard let text = qrPairingChunks.add(data) else { return }
                guard let response = BLEPairingProtocol.response(text, key: session.key, pairing: session.id, nonce: nonce),
                      let token = response.token else {
                    rejectAuthentication(peerUUID: peripheral.identifier.uuidString)
                    return
                }
                qrPairingResponse = response
                authenticationTokenFingerprint = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
                let confirmation = BLEPairingProtocol.Payload(v: 1, action: "confirm", pairing: session.id.uuidString.lowercased(),
                    nonce: nonce.uuidString.lowercased(), token: token)
                if !sendQRPairingProof(confirmation, key: session.key) { retryAfterTransportFailure() }
                return
            }
            if activeQRPairingSession == nil, qrPairingResponse == nil, let macNonce = reconnectNonce, data.count != 1 {
                guard connectionStatus == .connected, hasAttemptedAuth else { return }
                guard let text = qrPairingChunks.add(data) else { return }
                let token = UserDefaults.standard.string(forKey: "bleAuthToken") ?? ""
                guard let phoneNonce = BLEPairingProtocol.verifiedPhoneNonce(challenge: text, token: token, macNonce: macNonce),
                      let auth = BLEPairingProtocol.reconnectAuth(token: token, macNonce: macNonce, phoneNonce: phoneNonce) else {
                    // Not our phone (or a replayed advertisement): nothing secret was sent.
                    rejectAuthentication(peerUUID: peripheral.identifier.uuidString)
                    return
                }
                reconnectNonce = nil
                reconnectPhoneVerified = true
                if !sendFramedAuthentication(auth) { retryAfterTransportFailure() }
                return
            }
            if let response = qrPairingResponse {
                guard activeQRPairingSession != nil, connectionStatus == .connected, hasAttemptedAuth,
                      data.count == 1, data.first == BLEConstants.authSuccess,
                      let token = response.token, let deviceID = response.deviceID else {
                    rejectAuthentication(peerUUID: peripheral.identifier.uuidString)
                    return
                }
                // Commit credentials and identity only after both peers complete this live handshake.
                UserDefaults.standard.set(token, forKey: "bleAuthToken")
                UserDefaults.standard.set(deviceID, forKey: "lastBLEPairedDeviceID")
                UserDefaults.standard.set(true, forKey: "hasPairedDeviceOnce")
            }
            guard connectionStatus == .connected, hasAttemptedAuth,
                  let authenticatedToken = authenticationTokenFingerprint,
                  authenticatedToken == tokenFingerprint() else { return }
            // Success counts only after the phone proved itself (reconnect) or the
            // encrypted QR exchange completed (first pairing).
            if data.count == 1 && data.first == BLEConstants.authSuccess &&
                (reconnectPhoneVerified || qrPairingResponse != nil) {
                print("[BLE] Auth Success!")
                connectionTimer?.invalidate()
                connectionTimer = nil
                rememberAuthenticatedPeer(peripheral.identifier.uuidString)
                discoveryBackoffStep = 0
                failureBackoffStep = 0
                rejectedPeers.removeValue(forKey: peripheral.identifier.uuidString)
                reconnectBurstUntil = nil
                connectionStatus = .authenticated
                startHeartbeat()
                let devName = qrPairingResponse?.name ?? AppState.getPreferredDeviceName(fallback: discoveredPeripheral?.name)
                connectedDeviceName = devName
                endQRPairing()
                
                let bleDeviceId = UserDefaults.standard.string(forKey: "lastBLEPairedDeviceID")
                    ?? discoveredPeripheral?.identifier.uuidString ?? ""
                let generation = sessionGeneration
                DispatchQueue.main.async { [weak self, weak peripheral] in
                    guard let self = self, let peripheral = peripheral,
                          self.discoveredPeripheral === peripheral, self.sessionGeneration == generation,
                          self.isAuthenticated, !AppState.shared.isSyncPaused else { return }
                    if AppState.shared.device == nil || AppState.shared.device?.isBLE == true {
                        AppState.shared.device = Device(
                            name: devName,
                            ipAddress: "BLE",
                            port: 0,
                            version: "1.0",
                            adbPorts: [],
                            deviceId: bleDeviceId
                        )
                    }
                }
                
                // Initial discovery can read the standard battery before auth.
                // Request it again now so the authenticated session receives an
                // actual percentage instead of waiting for the next battery change.
                if let battery = characteristics[BLEConstants.charBatteryLevel], battery.properties.contains(.read) {
                    peripheral.readValue(for: battery)
                }
                // Phones with the file lane publish its L2CAP channel; older phones lack the characteristic.
                if let lane = characteristics[BLEConstants.charFileLanePSM] { peripheral.readValue(for: lane) }
                probeBondIfNeeded(peripheral)

                // Immediately notify Android of Mac status
                WebSocketServer.shared.sendMacStatusOverBLE()
                
                // Also trigger a status update (which includes current media info)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak peripheral] in
                    guard let self = self, let peripheral = peripheral,
                          self.discoveredPeripheral === peripheral, self.sessionGeneration == generation, self.isAuthenticated,
                          !AppState.shared.isSyncPaused, AppState.shared.isBLEEnabled else { return }
                    MacInfoSyncManager.shared.forceRefresh()
                }
            } else {
                print("[BLE] Auth Failed!")
                rejectAuthentication(peerUUID: peripheral.identifier.uuidString)
            }
        case BLEConstants.charBatteryLevel:
            guard let level = BLEConstants.batteryLevel(from: data) else {
                print("[BLE] Ignoring malformed Android battery packet")
                return
            }
            print("[BLE] Received Android Battery: \(level)%")
            let generation = sessionGeneration
            DispatchQueue.main.async { [weak self, weak peripheral] in
                guard let self = self, let peripheral = peripheral,
                      self.discoveredPeripheral === peripheral, self.sessionGeneration == generation, self.isAuthenticated,
                      !AppState.shared.isSyncPaused else { return }
                if AppState.shared.status == nil {
                    AppState.shared.status = DeviceStatus(battery: DeviceStatus.Battery(level: level, isCharging: false), isPaired: true, music: nil)
                } else {
                    AppState.shared.status?.battery.level = level
                    AppState.shared.status?.battery.isReported = true
                }
            }
        case BLEConstants.charNotificationData, BLEConstants.charMediaState, BLEConstants.charClipboardDataNotify, BLEConstants.charDeviceName, BLEConstants.charNotificationDismissNotify, BLEConstants.charMacControl:
            handleChunkedUpdate(uuid: characteristic.uuid, data: data)
        default:
            break
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === discoveredPeripheral else { return }
        responseWriteInFlight = false
        if let error = error {
            print("[BLE] Error writing value to characteristic \(characteristic.uuid): \(error.localizedDescription)")
            retryAfterTransportFailure()
            return
        }
        drainWrites()
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === discoveredPeripheral, !AppState.shared.isSyncPaused,
              AppState.shared.isBLEEnabled else { return }
        if let error = error {
            print("[BLE] Error updating notification state for characteristic \(characteristic.uuid): \(error.localizedDescription)")
            // Authentication waits for every subscription; one transient failure used to
            // stall it until the connection timer gave up. Try each one once more.
            if !notifyRetried.contains(characteristic.uuid) {
                notifyRetried.insert(characteristic.uuid)
                peripheral.setNotifyValue(true, for: characteristic)
            }
        } else {
            print("[BLE] Notification state updated for \(characteristic.uuid): \(characteristic.isNotifying)")
            authenticateWhenReady(peripheral)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("[BLE] Error discovering descriptors for \(characteristic.uuid): \(error.localizedDescription)")
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        if let error = error {
            print("[BLE] Error updating value for descriptor \(descriptor.uuid): \(error.localizedDescription)")
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: Error?) {
        if let error = error {
            print("[BLE] Error writing value for descriptor \(descriptor.uuid): \(error.localizedDescription)")
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard peripheral === discoveredPeripheral else { return }
        if let error { print("[BLE] File lane channel failed: \(error.localizedDescription)") }
        finishLaneOpen(error == nil ? channel : nil)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral === discoveredPeripheral else { return }
        drainWrites()
    }
    
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard peripheral === discoveredPeripheral else { return }
        print("[BLE] Services invalidated: \(invalidatedServices.map { $0.uuid.uuidString })")
        retryAfterTransportFailure()
    }
    
    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if let error = error {
            print("[BLE] Error reading RSSI: \(error.localizedDescription)")
        }
    }
    
    private func handleChunkedUpdate(uuid: CBUUID, data: Data) {
        let assembler = chunkBuffers[uuid] ?? BLEChunkUtil.Reassembler()
        chunkBuffers[uuid] = assembler
        if let completePayload = assembler.add(data) {
            if uuid == BLEConstants.charMacControl, BLELinkPolicy.isPong(completePayload) {
                heartbeatSupported = true
                return
            }
            BLETransportBridge.shared.handleIncoming(uuid: uuid, payload: completePayload)
        }
    }
}
