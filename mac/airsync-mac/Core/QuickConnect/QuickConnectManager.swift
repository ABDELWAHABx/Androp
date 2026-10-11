//
//  QuickConnectManager.swift
//  airsync-mac
//
//  Created by Sameera Sandakelum on 2025-09-30.
//

import Foundation
import Combine

/// Manages quick reconnection functionality for previously connected devices
class QuickConnectManager: ObservableObject {
    static let shared = QuickConnectManager()
    
    // Android wake-up ports
    private static let ANDROID_HTTP_WAKEUP_PORT = 8891
    private static let ANDROID_UDP_WAKEUP_PORT = 8890
    
    // Storage key for device history
    private static let DEVICE_HISTORY_KEY = "deviceHistory"
    
    // Store last connected devices per network (key: Mac IP, value: Device)
    @Published var lastConnectedDevices: [String: Device] = [:]
    
    // Track which device is currently being connected to 
    private var connectionTask: Task<Void, Never>?
    private var connectionAttempt = UUID()

    @Published var connectingDeviceID: String? = nil
    
    private init() {
        loadDeviceHistoryFromDisk()
    }
    
    // MARK: - Public Interface
    
    /// Gets the last connected device for the current network
    func getLastConnectedDevice() -> Device? {
        guard let currentIP = getCurrentMacIP() else { return nil }
        return lastConnectedDevices[currentIP]
    }
    
    /// Saves a device as the last connected for the current network
    func saveLastConnectedDevice(_ device: Device) {
        guard let currentMacIP = getCurrentMacIP() else {
            print("[quick-connect] Cannot save device - no current Mac IP available")
            return
        }
        
        let isBLE = device.ipAddress == "Bluetooth LE" || device.ipAddress == "BLE"
        
        DispatchQueue.main.async {
            if isBLE {
                if let existing = self.lastConnectedDevices[currentMacIP] {
                    let existingIsBLE = existing.ipAddress == "Bluetooth LE" || existing.ipAddress == "BLE"
                    if !existingIsBLE {
                        print("[quick-connect] Not overwriting existing Wi-Fi device (\(existing.name): \(existing.ipAddress)) with BLE device")
                        return
                    }
                }
            }
            
            self.lastConnectedDevices[currentMacIP] = device
            self.saveDeviceHistoryToDisk()
            print("[quick-connect] Saved last connected device for network \(currentMacIP): \(device.name) (\(device.ipAddress))")
        }
    }
    
    /// Clears the last connected device for the current network
    func clearLastConnectedDevice() {
        guard let currentMacIP = getCurrentMacIP() else { return }
        
        DispatchQueue.main.async {
            self.lastConnectedDevices.removeValue(forKey: currentMacIP)
            self.saveDeviceHistoryToDisk()
        }
        print("[quick-connect] Cleared last connected device for network \(currentMacIP)")
    }
    
    /// Attempts to wake up and reconnect to a specific discovered device
    func connect(to discoveredDevice: DiscoveredDevice) {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.connect(to: discoveredDevice) }; return }
        guard !AppState.shared.isSyncPaused else { return }
        if connectingDeviceID == discoveredDevice.id { return }
        cancelPendingConnection()
        UserDefaults.standard.isManuallyDisconnected = false
        let attempt = connectionAttempt
        let hasWifiIPs = discoveredDevice.ips.contains { $0 != "Bluetooth LE" && $0 != "Nearby" && !$0.isEmpty }
        if (discoveredDevice.type == "ble" || discoveredDevice.ips.contains("Bluetooth LE")) && !hasWifiIPs {
            print("[quick-connect] Discovered device is Bluetooth LE, connecting directly via BLE...")
            // Show progress in UI
            connectingDeviceID = discoveredDevice.id
            
            // Save as last connected device (so we can auto-reconnect later)
            let device = Device(
                name: discoveredDevice.name,
                ipAddress: "Bluetooth LE",
                port: discoveredDevice.port,
                version: "Unknown",
                adbPorts: [],
                deviceId: discoveredDevice.deviceId
            )
            saveLastConnectedDevice(device)
            
            BLECentralManager.shared.connectManually(toUuid: discoveredDevice.deviceId)
            
            // Clear progress after short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard self.connectionAttempt == attempt else { return }
                self.connectingDeviceID = nil
            }
            return
        }
        
        // Pick best IP: prefer local (non-100.x) over VPN
        let bestIP = discoveredDevice.ips.first(where: { !$0.hasPrefix("100.") && $0 != "Bluetooth LE" && $0 != "Nearby" && !$0.isEmpty }) ?? discoveredDevice.ips.first(where: { $0 != "Bluetooth LE" && $0 != "Nearby" && !$0.isEmpty }) ?? ""
        
        guard !bestIP.isEmpty, (1...65535).contains(discoveredDevice.port) else { return }
        // Convert DiscoveredDevice to Device model
        let device = Device(
            name: discoveredDevice.name,
            ipAddress: bestIP,
            port: discoveredDevice.port,
            version: "Unknown",
            adbPorts: [],
            deviceId: discoveredDevice.deviceId
        )
        
        saveLastConnectedDevice(device)
        
        print("[quick-connect] Initiating connection to discovered device: \(device.name) at \(device.ipAddress)")
        
        // Show progress in UI
        connectingDeviceID = discoveredDevice.id
        
        connectionTask = Task {
            await sendWakeUpRequest(to: device, attempt: attempt)
        }
    }

    /// Attempts to wake up and reconnect to the last connected device
    func wakeUpLastConnectedDevice() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.wakeUpLastConnectedDevice() }; return }
        guard !AppState.shared.isSyncPaused, connectionTask == nil else { return }
        UserDefaults.standard.isManuallyDisconnected = false
        let attempt = connectionAttempt
        guard let lastDevice = getLastConnectedDevice() else {
            print("[quick-connect] No last connected device to wake up")
            return
        }
        
        if lastDevice.ipAddress == "Bluetooth LE" {
            print("[quick-connect] Last connected device is BLE. Initiating BLE reconnection...")
            BLECentralManager.shared.connectManually(toUuid: lastDevice.deviceId)
            return
        }
        
        print("[quick-connect] Attempting to wake up device: \(lastDevice.name) at \(lastDevice.ipAddress)")
        print("[quick-connect] Will try HTTP port \(Self.ANDROID_HTTP_WAKEUP_PORT), then UDP port \(Self.ANDROID_UDP_WAKEUP_PORT) if needed")
        
        connectingDeviceID = lastDevice.deviceId
        connectionTask = Task {
            await sendWakeUpRequest(to: lastDevice, attempt: attempt)
        }
    }
    
    func cancelPendingConnection() {
        connectionTask?.cancel()
        connectionTask = nil
        connectionAttempt = UUID()
        connectingDeviceID = nil
    }

    /// Refreshes device info for current network (triggers UI updates)
    func refreshDeviceForCurrentNetwork() {
        objectWillChange.send()
        print("[quick-connect] Refreshed device info for current network")
    }
    
    // MARK: - Private Implementation
    
    private func getCurrentMacIP() -> String? {
        return WebSocketServer.shared.getLocalIPAddress(
            adapterName: AppState.shared.selectedNetworkAdapterName
        )
    }
    
    private func getCurrentMacPort() -> UInt16? {
        return WebSocketServer.shared.getListeningNetworkEndpoint()?.port
    }
    
    private func saveDeviceHistoryToDisk() {
        if let encoded = try? JSONEncoder().encode(lastConnectedDevices) {
            UserDefaults.standard.set(encoded, forKey: Self.DEVICE_HISTORY_KEY)
        }
    }
    
    private func loadDeviceHistoryFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: Self.DEVICE_HISTORY_KEY),
              let history = try? JSONDecoder().decode([String: Device].self, from: data) else {
            return
        }
        
        self.lastConnectedDevices = history
        print("[quick-connect] Loaded device history for \(history.count) networks")
    }
    
    // MARK: - Wake-up Implementation
    
    private func sendWakeUpRequest(to device: Device, attempt: UUID) async {
        guard !Task.isCancelled, !AppState.shared.isSyncPaused else { return }
        // Get current connection info to send in wake-up request
        var currentIP = getBestLocalIP(for: device.ipAddress)
        var currentPort = getCurrentMacPort()
        
        if currentIP == nil || currentPort == nil {
            print("[quick-connect] Network info not ready, waiting for WebSocket server...")
            for i in 1...10 {
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                guard !Task.isCancelled, !AppState.shared.isSyncPaused else { return }
                currentIP = getBestLocalIP(for: device.ipAddress)
                currentPort = getCurrentMacPort()
                
                if currentIP != nil && currentPort != nil {
                    print("[quick-connect] Network info obtained after \(i * 200)ms")
                    break
                }
            }
        }
        
        guard let finalIP = currentIP, let finalPort = currentPort else {
            print("[quick-connect] Cannot wake up device - no current connection info available after waiting")
            DispatchQueue.main.async {
                guard self.connectionAttempt == attempt else { return }
                self.connectionTask = nil
                self.connectingDeviceID = nil
            }
            return
        }
        
        let macName = AppState.shared.myDevice?.name ?? "My Mac"
        
        // Create wake-up message with current connection details (no auth key needed)
        guard let messageData = try? JSONSerialization.data(withJSONObject: [
            "type": "wakeUpRequest", "data": [
                "macIP": finalIP, "macPort": Int(finalPort), "macName": macName,
                "isPlus": AppState.shared.isPlus
            ]
        ]), let wakeUpMessage = String(data: messageData, encoding: .utf8),
              !Task.isCancelled, !AppState.shared.isSyncPaused else { return }

        // Try to send HTTP POST request to the Android device
        await sendHTTPWakeUpRequest(to: device, message: wakeUpMessage)
        
        guard !Task.isCancelled, !AppState.shared.isSyncPaused else { return }
        // Clear progress after short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            guard self.connectionAttempt == attempt else { return }
            self.connectionTask = nil
            self.connectingDeviceID = nil
        }
    }
    
    /// Selects the best local IP to present to the target device
    /// Prioritizes IPs that match the target's subnet/prefix (e.g. Tailscale 100.x)
    private func getBestLocalIP(for targetIP: String) -> String? {
        guard let endpoint = WebSocketServer.shared.getListeningNetworkEndpoint() else { return nil }
        let adapters = endpoint.adapters
        let allIPs = adapters.map { $0.address }
        
        // 1. If user manually selected an adapter, MUST use that
        if let selected = AppState.shared.selectedNetworkAdapterName {
            // A changed preference may still be waiting for its listener to bind.
            return adapters.first(where: { $0.name == selected })?.address
        }
        
        // 2. If valid target IP, try to match prefix
        if !targetIP.isEmpty {
            // Check for Tailscale (100.x)
            if targetIP.hasPrefix("100.") {
                if let tailscaleIP = allIPs.first(where: { $0.hasPrefix("100.") }) {
                    return tailscaleIP
                }
            }
            
            // Check for other common prefixes (subnet match)
            let parts = targetIP.split(separator: ".")
            if let firstOctet = parts.first {
                let prefix = "\(firstOctet)."
                if let match = allIPs.first(where: { $0.hasPrefix(prefix) }) {
                    return match
                }
            }
        }
        
        // 3. Fallback: Use the first available IP 
        return allIPs.first
    }
    
    private func sendHTTPWakeUpRequest(to device: Device, message: String) async {
        print("[quick-connect] Trying HTTP wake-up to \(device.ipAddress):\(Self.ANDROID_HTTP_WAKEUP_PORT)")
        
        // Construct URL for Android device's HTTP endpoint
        guard let url = URL(string: "http://\(device.ipAddress):\(Self.ANDROID_HTTP_WAKEUP_PORT)/wakeup") else {
            print("[quick-connect] Invalid wake-up URL for device")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = message.data(using: .utf8)
        request.timeoutInterval = 5.0
        
        var success = false
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    print("[quick-connect] Wake-up request successful - device should reconnect soon")
                    success = true
                } else if httpResponse.statusCode == 502 {
                    print("[quick-connect] Wake-up request failed with 502 (Bad Gateway). Retrying once...")
                    
                    // Small delay before retry
                    do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                    guard !Task.isCancelled, !AppState.shared.isSyncPaused else { return }
                    
                    if let (_, secondResponse) = try? await URLSession.shared.data(for: request),
                       let secondHttpResponse = secondResponse as? HTTPURLResponse,
                       secondHttpResponse.statusCode == 200 {
                        print("[quick-connect] Wake-up retry successful")
                        success = true
                    } else {
                        print("[quick-connect] Wake-up retry failed")
                    }
                } else {
                    print("[quick-connect] Wake-up request failed with status: \(httpResponse.statusCode)")
                }
            }
        } catch {
            print("[quick-connect] Failed to send wake-up request: \(error)")
        }
        
        guard !Task.isCancelled, !AppState.shared.isSyncPaused else { return }
        if !success {
            // Fallback: Try UDP broadcast
            await sendUDPWakeUpRequest(to: device, message: message)
        }
    }
    
    private func sendUDPWakeUpRequest(to device: Device, message: String) async {
        print("[quick-connect] Trying UDP wake-up to \(device.ipAddress):\(Self.ANDROID_UDP_WAKEUP_PORT) as fallback")
        
        // Fire-and-forget fallback. Android's UDP listener parses raw JSON "wakeUpRequest" packets,
        // so a text prefix here made every fallback packet unparseable.
        let udpMessage = message
        
        guard !Task.isCancelled, !AppState.shared.isSyncPaused else { return }
        DispatchQueue.global(qos: .background).async {
            guard !AppState.shared.isSyncPaused else { return }
            // Create UDP socket and send wake-up message
            let socket = socket(AF_INET, SOCK_DGRAM, 0)
            defer { close(socket) }
            
            guard socket >= 0 else {
                print("[quick-connect] Failed to create UDP socket")
                return
            }
            
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(Self.ANDROID_UDP_WAKEUP_PORT).bigEndian)
            guard inet_aton(device.ipAddress, &addr.sin_addr) != 0 else { return }
            
            let messageData = udpMessage.data(using: .utf8) ?? Data()
            _ = messageData.withUnsafeBytes { bytes in
                withUnsafePointer(to: addr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        return sendto(socket, bytes.bindMemory(to: Int8.self).baseAddress, messageData.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }
}
