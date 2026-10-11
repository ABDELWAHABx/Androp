//
//  QRConnectionManager.swift
//  airsync-mac
//
//  Created by Sameera Sandakelum on 2026-05-19.
//

import SwiftUI
import Combine
import QRCode
import LocalAuthentication

class QRConnectionManager: ObservableObject {
    enum PairingTransport: String, CaseIterable { case bluetooth = "Bluetooth", wifi = "Wi-Fi" }
    static let shared = QRConnectionManager()
    
    @Published var qrImage: CGImage?
    @Published var isUnlocked = false
    @Published var transport: PairingTransport = .bluetooth {
        didSet {
            guard transport != oldValue else { return }
            BLECentralManager.shared.endQRPairing()
            generateQRAsync()
        }
    }
    @Published var pairingMessage: String?
    @Published var copyStatus: String?
    @Published var showConfirmReset = false
    
    private var unlockTimer: Timer?
    private var generation = UUID()
    private var authenticationRequest: UUID?
    private var pairingKey: Data?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        AppState.shared.$isSyncPaused.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] paused in
            if paused { self?.cleanUpTimer() }
        }.store(in: &cancellables)
        AppState.shared.$isBLEEnabled.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] enabled in
            guard let self = self, self.transport == .bluetooth else { return }
            if !enabled { self.cleanUpTimer() }
            else if self.isUnlocked { self.generateQRAsync() }
        }.store(in: &cancellables)
        AppState.shared.$webSocketStatus.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self = self, self.transport == .wifi, self.isUnlocked else { return }
            self.generateQRAsync()
        }.store(in: &cancellables)
        WebSocketServer.shared.$symmetricKey.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self = self, self.isUnlocked else { return }
            let currentKey = WebSocketServer.shared.getSymmetricKeyBase64().flatMap { Data(base64Encoded: $0) }
            if self.pairingKey != currentKey { self.generateQRAsync() }
        }.store(in: &cancellables)
    }
    
    func generateQRAsync() {
        guard isUnlocked else { return }
        generation = UUID()
        let revision = generation
        qrImage = nil
        pairingMessage = nil
        guard !AppState.shared.isSyncPaused,
              let encodedKey = WebSocketServer.shared.getSymmetricKeyBase64(), let key = Data(base64Encoded: encodedKey) else {
            pairingMessage = "Resume androp to pair your phone."
            return
        }
        let text: String
        if transport == .bluetooth {
            guard AppState.shared.isBLEEnabled else {
                pairingMessage = "Enable Bluetooth in androp to pair your phone."
                return
            }
            // beginQRPairing refuses to replace a live phone; say so instead of blaming the Bluetooth toggle.
            guard !BLECentralManager.shared.isAuthenticated else {
                pairingMessage = "A Bluetooth phone is already connected. Disconnect it to pair another phone over Bluetooth."
                return
            }
            guard let qr = BLEPairingProtocol.qrText(pairing: revision, key: key, name: AppState.shared.myDevice?.name ?? "My Mac"),
                  BLECentralManager.shared.beginQRPairing(id: revision, key: key) else {
                pairingMessage = "Bluetooth is not ready. Check Bluetooth in System Settings and try again."
                return
            }
            text = qr
        } else {
            BLECentralManager.shared.endQRPairing()
            guard case .started = AppState.shared.webSocketStatus,
                  let endpoint = WebSocketServer.shared.getListeningNetworkEndpoint(),
                  let qr = generateQRText(ip: endpoint.adapters.map(\.address).prefix(16).joined(separator: ","),
                      port: endpoint.port, name: AppState.shared.myDevice?.name, key: encodedKey) else {
                pairingMessage = "Wi-Fi is not ready. Connect your Mac to a network and wait for androp to start."
                return
            }
            text = qr
        }
        pairingKey = key
        unlockTimer?.invalidate()
        unlockTimer = Timer.scheduledTimer(withTimeInterval: BLEPairingProtocol.windowDuration, repeats: false) { [weak self] _ in
            self?.cleanUpTimer()
        }
        Task {
            if let cgImage = await QRCodeGenerator.generateQRCode(for: text) {
                DispatchQueue.main.async {
                    guard self.generation == revision, self.isUnlocked, !AppState.shared.isSyncPaused else { return }
                    self.qrImage = cgImage
                }
            }
        }
    }
    
    func authenticateUser() {
        let request = UUID()
        authenticationRequest = request
        let context = LAContext()
        var error: NSError?
        
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            let reason = "Authenticate to reveal connection credentials"
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, authenticationError in
                DispatchQueue.main.async {
                    guard self.authenticationRequest == request else { return }
                    if success {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            self.isUnlocked = true
                        }
                        
                        self.generateQRAsync()
                    }
                }
            }
        } else {
            // Fallback if no auth policy is available
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                self.isUnlocked = true
            }
            self.generateQRAsync()
        }
    }
    
    func cleanUpTimer() {
        authenticationRequest = nil
        generation = UUID()
        unlockTimer?.invalidate()
        unlockTimer = nil
        isUnlocked = false
        qrImage = nil
        pairingKey = nil
        pairingMessage = nil
        BLECentralManager.shared.endQRPairing()
    }
    
    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        withAnimation {
            copyStatus = "Copied! Keep it safe"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation {
                self.copyStatus = nil
            }
        }
    }
}
