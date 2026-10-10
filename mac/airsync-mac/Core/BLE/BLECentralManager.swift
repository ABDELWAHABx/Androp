import Foundation
import CoreBluetooth
import Combine

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
    private let expectedServiceCount = 4
    
    @Published var connectionStatus: BLEConnectionStatus = .disconnected
    @Published var connectedDeviceName: String? = nil
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
    
    private var cancellables = Set<AnyCancellable>()
    private var scanTimer: Timer?
    private var connectionTimer: Timer?
    private var wifiStabilityTimer: Timer?
    private var scanRestartWorkItem: DispatchWorkItem?
    private var scanRestartGeneration = 0
    private var isTearingDown = false
    private(set) var sessionGeneration = 0
    
    override init() {
        super.init()
        // The isolated production-app lifecycle check must not request radio
        // permissions or create a Bluetooth connection on the CI runner.
        guard !LifecycleSelfTest.isRequested else { return }
        centralManager = CBCentralManager(delegate: self, queue: nil)
        DispatchQueue.main.async { [weak self] in
            self?.setupWifiStabilityObserver()
        }
    }
    
    #if BLE_LIFECYCLE_TESTS
    // The regression harness exercises this exact manager without creating a
    // Bluetooth radio or initializing the rest of the application.
    init(testingWithoutRadio: Bool) {
        super.init()
        precondition(testingWithoutRadio)
    }

    var hasPendingScanRestartForTesting: Bool { scanRestartWorkItem != nil }
    func scheduleScanRestartForTesting(after delay: TimeInterval) {
        scheduleAutomaticScanRestart(after: delay)
    }
    #endif

    private func setupWifiStabilityObserver() {
        AppState.shared.$device
            .receive(on: DispatchQueue.main)
            .sink { [weak self] device in
                guard let self = self else { return }
                let isWifiConnected = device != nil && device?.ipAddress != "BLE" && device?.ipAddress != "Bluetooth LE"
                
                if isWifiConnected {
                    if self.isConnected && self.wifiStabilityTimer == nil {
                        print("[BLE] Wi-Fi device connected (\(device?.name ?? "")). Starting 5s stability timer before disconnecting BLE...")
                        self.wifiStabilityTimer?.invalidate()
                        self.wifiStabilityTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
                            guard let self = self else { return }
                            self.wifiStabilityTimer = nil
                            let currentDevice = AppState.shared.device
                            let isStillWifiConnected = currentDevice != nil && currentDevice?.ipAddress != "BLE" && currentDevice?.ipAddress != "Bluetooth LE"
                            if isStillWifiConnected && self.isConnected {
                                print("[BLE] Wi-Fi connection is stable after 5s. Disconnecting redundant BLE connection.")
                                self.disconnect()
                            } else {
                                print("[BLE] Wi-Fi connection was lost before 5s stability check. Keeping BLE active.")
                            }
                        }
                    }
                } else {
                    if self.wifiStabilityTimer != nil {
                        print("[BLE] Wi-Fi disconnected during stability timer. Cancelling BLE disconnect.")
                        self.wifiStabilityTimer?.invalidate()
                        self.wifiStabilityTimer = nil
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    func startScanning() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.startScanning() }
            return
        }
        guard !isTearingDown, centralManager?.state == .poweredOn, AppState.shared.isBLEEnabled, !AppState.shared.isSyncPaused,
              discoveredPeripheral == nil, connectingDeviceUUID == nil else { return }
        
        let isRegularConnection = AppState.shared.device?.ipAddress != nil && AppState.shared.device?.ipAddress != "BLE" && AppState.shared.device?.ipAddress != "Bluetooth LE"
        guard !isRegularConnection else {
            print("[BLE] Skip scan: Regular connection is active.")
            return
        }
        
        cancelPendingScanRestart()
        print("[BLE] Starting scan...")
        connectionStatus = .scanning
        
        centralManager.stopScan()
        scanTimer?.invalidate()
        scanTimer = nil
        
        centralManager.scanForPeripherals(withServices: [BLEConstants.serviceSystem], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        
        // Restart scan periodically to avoid stale states
        scanTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                // Skip restart cycle when already connected — nothing to rediscover
                guard self.connectionStatus == .scanning, self.discoveredPeripheral == nil,
                      self.centralManager?.state == .poweredOn, AppState.shared.isBLEEnabled,
                      !AppState.shared.isSyncPaused, !self.isTearingDown else {
                    self.stopScanning()
                    return
                }

                // Prune stale devices older than 25 seconds
                let now = Date()
                let staleUUIDs = self.discoveredPeripherals.filter { now.timeIntervalSince($1.lastSeen) > 60.0 }.map { $0.key }
                for uuid in staleUUIDs {
                    self.discoveredPeripherals.removeValue(forKey: uuid)
                }

                self.centralManager.stopScan()
                self.centralManager.scanForPeripherals(withServices: [BLEConstants.serviceSystem], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            }
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
        isManuallyDisconnected = !restartScanning
        tearDownConnection(cancelPeripheral: true)
        if restartScanning { startScanning() }
    }

    private func tearDownConnection(cancelPeripheral: Bool) {
        guard !isTearingDown else { return }
        isTearingDown = true
        sessionGeneration &+= 1
        defer { isTearingDown = false }
        stopScanning()
        connectionTimer?.invalidate()
        connectionTimer = nil
        wifiStabilityTimer?.invalidate()
        wifiStabilityTimer = nil
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
    }

    private func cancelPendingScanRestart() {
        scanRestartGeneration &+= 1
        scanRestartWorkItem?.cancel()
        scanRestartWorkItem = nil
    }

    private func scheduleAutomaticScanRestart(after delay: TimeInterval) {
        cancelPendingScanRestart()
        guard AppState.shared.isBLEEnabled, AppState.shared.isBLEAutoConnectEnabled,
              !AppState.shared.isSyncPaused, !isManuallyDisconnected, !isTearingDown else { return }
        let generation = scanRestartGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.scanRestartGeneration == generation else { return }
            self.scanRestartWorkItem = nil
            guard AppState.shared.isBLEEnabled, AppState.shared.isBLEAutoConnectEnabled,
                  !AppState.shared.isSyncPaused, !self.isManuallyDisconnected else { return }
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
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in _ = self?.writeChunked(characteristicUUID: characteristicUUID, payload: payload) }
            return true
        }
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
        stopScanning()
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
            self.tearDownConnection(cancelPeripheral: true)
        }
    }
    

}

extension BLECentralManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            if AppState.shared.isBLEEnabled {
                print("[BLE] Bluetooth powered on, starting scan")
                startScanning()
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
        if AppState.shared.isBLEAutoConnectEnabled && !isManuallyDisconnected {
            guard connectionStatus == .disconnected || connectionStatus == .scanning else { return }
            guard discoveredPeripheral == nil else { return }

            let isWifiConnected = AppState.shared.device != nil && AppState.shared.device?.ipAddress != "BLE" && AppState.shared.device?.ipAddress != "Bluetooth LE"
            if isWifiConnected {
                print("[BLE] Regular Wi-Fi connection is active — skipping auto-connect to BLE")
                return
            }
            
            let token = UserDefaults.standard.string(forKey: "bleAuthToken") ?? ""
            if token.isEmpty {
                return
            }
            
            stopScanning()
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
                self.tearDownConnection(cancelPeripheral: true)
                self.scheduleAutomaticScanRestart(after: 2.0)
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let isWiFiConnected = AppState.shared.device != nil && AppState.shared.device?.isBLE == false
        guard peripheral === discoveredPeripheral, !AppState.shared.isSyncPaused,
              AppState.shared.isBLEEnabled, !isWiFiConnected else {
            if peripheral === discoveredPeripheral { tearDownConnection(cancelPeripheral: true) }
            else { central.cancelPeripheralConnection(peripheral) }
            return
        }
        connectionTimer?.invalidate()
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self, weak peripheral] _ in
            guard let self = self, let peripheral = peripheral,
                  self.discoveredPeripheral === peripheral else { return }
            self.disconnect()
        }
        connectingDeviceUUID = nil
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
        guard peripheral === discoveredPeripheral else { return }
        print("[BLE] Failed to connect: \(error?.localizedDescription ?? "Unknown error")")
        tearDownConnection(cancelPeripheral: false)
        scheduleAutomaticScanRestart(after: 3.0)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === discoveredPeripheral else { return }
        print("[BLE] Disconnected: \(error?.localizedDescription ?? "clean")")
        tearDownConnection(cancelPeripheral: false)
        scheduleAutomaticScanRestart(after: 3.0)
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
        let token = UserDefaults.standard.string(forKey: "bleAuthToken") ?? ""
        if !token.isEmpty, let data = token.data(using: .utf8) {
            print("[BLE] Attempting authentication...")
            write(characteristicUUID: BLEConstants.charAuthToken, data: data)
        } else {
            print("[BLE] Auth token is empty, skipping auth and disconnecting because they have never paired")
            disconnect()
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === discoveredPeripheral, !AppState.shared.isSyncPaused else { return }
        if let error = error {
            print("[BLE] Error updating value for characteristic \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value, characteristic.uuid == BLEConstants.charAuthResult || isAuthenticated else { return }
        
        switch characteristic.uuid {
        case BLEConstants.charAuthResult:
            if data.first == BLEConstants.authSuccess {
                print("[BLE] Auth Success!")
                connectionTimer?.invalidate()
                connectionTimer = nil
                connectionStatus = .authenticated
                let rawName = discoveredPeripheral?.name
                let devName = AppState.getPreferredDeviceName(fallback: rawName)
                connectedDeviceName = devName
                
                let bleDeviceId = discoveredPeripheral?.identifier.uuidString ?? ""
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
                disconnect()
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
            disconnect()
            return
        }
        drainWrites()
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === discoveredPeripheral, !AppState.shared.isSyncPaused,
              AppState.shared.isBLEEnabled else { return }
        if let error = error {
            print("[BLE] Error updating notification state for characteristic \(characteristic.uuid): \(error.localizedDescription)")
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
    
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral === discoveredPeripheral else { return }
        drainWrites()
    }
    
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard peripheral === discoveredPeripheral else { return }
        print("[BLE] Services invalidated: \(invalidatedServices.map { $0.uuid.uuidString })")
        disconnect()
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
            BLETransportBridge.shared.handleIncoming(uuid: uuid, payload: completePayload)
        }
    }
}
