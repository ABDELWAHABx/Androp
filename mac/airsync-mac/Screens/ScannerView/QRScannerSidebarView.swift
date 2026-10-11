//
//  QRScannerSidebarView.swift
//  airsync-mac
//
//  Created by Sameera Sandakelum on 2026-05-19.
//

import SwiftUI
import QRCode
import LocalAuthentication

struct QRScannerSidebarView: View {
    @ObservedObject var appState = AppState.shared
    @ObservedObject var qrManager = QRConnectionManager.shared
    @ObservedObject var bluetooth = BLECentralManager.shared
    
    private func statusInfo(for status: WebSocketStatus) -> (text: String, icon: String, color: Color) {
        switch status {
        case .stopped:
            return ("Stopped", "xmark.circle", .gray)
        case .starting:
            return ("Starting...", "clock", .orange)
        case .started(_, let ip):
            return ip?.isEmpty == false ? ("Ready", "checkmark.circle", .green) : ("Waiting for network", "wifi.slash", .orange)
        case .failed(let error):
            return ("Failed: \(error)", "exclamationmark.triangle", .red)
        }
    }
    
    @State private var showingSettingsPopover = false
    
    var body: some View {
        let info: (text: String, icon: String, color: Color) = {
            if appState.isSyncPaused { return ("Paused", "pause.circle", .gray) }
            if qrManager.transport == .wifi { return statusInfo(for: appState.webSocketStatus) }
            switch bluetooth.connectionStatus {
            case .disconnected: return ("Bluetooth pairing", "qrcode", .secondary)
            case .scanning: return ("Looking for phone", "antenna.radiowaves.left.and.right", .orange)
            case .connected: return ("Connecting…", "clock", .orange)
            case .authenticated: return ("Connected", "checkmark.circle", .green)
            }
        }()
        
        VStack(spacing: 16) {

                Text("Scan to connect")
                    .font(.title3)
                    .fontWeight(.bold)
                    .whatsNewPopover(item: .scanQR, arrowEdge: .trailing)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            Picker("Pair using", selection: $qrManager.transport) {
                ForEach(QRConnectionManager.PairingTransport.allCases, id: \.self) { transport in
                    Text(transport.rawValue).tag(transport)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 8)

            Spacer()

            
            if appState.isSyncPaused || qrManager.pairingMessage != nil ||
                (qrManager.transport == .bluetooth && (!appState.isBLEEnabled || bluetooth.bluetoothStatusMessage != nil)) {
                VStack {
                    Image(systemName: appState.isSyncPaused ? "pause.circle" : "antenna.radiowaves.left.and.right")
                        .font(.system(size: 30))
                        .foregroundColor(.gray)
                        .padding()
                    
                    Text(appState.isSyncPaused ? "Resume androp to pair your phone." :
                        (!appState.isBLEEnabled && qrManager.transport == .bluetooth ? "Enable Bluetooth in androp to pair your phone." :
                        (qrManager.pairingMessage ?? bluetooth.bluetoothStatusMessage ?? "")))
                        .font(.title3)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    if appState.isSyncPaused {
                        Button("Resume") { appState.setSyncPaused(false) }
                    } else if qrManager.transport == .bluetooth && !appState.isBLEEnabled {
                        Button("Enable Bluetooth") {
                            appState.connectionMode = .dynamic
                            qrManager.cleanUpTimer()
                        }
                    } else if qrManager.transport == .bluetooth && bluetooth.bluetoothStatusMessage != nil {
                        Button("Bluetooth Settings") {
                            let destination = bluetooth.bluetoothPermissionDenied ? "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth" : "x-apple.systempreferences:com.apple.BluetoothSettings"
                            if let url = URL(string: destination) { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                .padding()
                .glassBoxIfAvailable(radius: 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if !qrManager.isUnlocked {
                    // Locked UI: 1:1 card with glass background
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 36))
                            .foregroundColor(.accentColor)
                        Text("Click to Reveal")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text(qrManager.transport == .bluetooth ? "Pair over Bluetooth" : "Pair on the same Wi-Fi")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(width: 240, height: 240)
                    .glassBoxIfAvailable(radius: 24)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        qrManager.authenticateUser()
                    }
                } else {
                    // Unlocked
                    if let qrImage = qrManager.qrImage {
                        VStack(spacing: 12) {
                            Image(decorative: qrImage, scale: 1.0)
                                .resizable()
                                .interpolation(.none)
                                .frame(width: 180, height: 180)
                                .accessibilityLabel("QR Code")
                                .shadow(radius: 20)
                                .padding()
                                .background(Color.black, in: .rect(cornerRadius: 30))
                            Text(qrManager.transport == .bluetooth ? "Keep Bluetooth on in both devices.\nNo Wi-Fi required. Code expires in 2 minutes." : "Connect both devices to the same Wi-Fi.\nKeep androp running on your Mac.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            
                            if let key = WebSocketServer.shared.getSymmetricKeyBase64(), !key.isEmpty {
                                VStack(spacing: 8) {
                                    HStack {
                                        GlassButtonView(
                                            label: "Copy Key",
                                            systemImage: "key",
                                            action: {
                                                qrManager.copyToClipboard(key)
                                            }
                                        )
                                        
                                        GlassButtonView(
                                            label: "Re-generate key",
                                            systemImage: "repeat.badge.xmark",
                                            iconOnly: true,
                                            action: {
                                                qrManager.showConfirmReset = true
                                            }
                                        )
                                    }
                                    .confirmationDialog(
                                        "Are you sure you want to reset the key? You will have to re-auth all the devices.",
                                        isPresented: $qrManager.showConfirmReset
                                    ) {
                                        Button("Reset key", role: .destructive) {
                                            WebSocketServer.shared.resetSymmetricKey()
                                            qrManager.generateQRAsync()
                                        }
                                        Button("Cancel", role: .cancel) { }
                                    }
                                    
                                    if let status = qrManager.copyStatus {
                                        Text(status)
                                            .font(.caption)
                                            .foregroundColor(.green)
                                            .transition(.opacity)
                                    }
                                }
                            }
                        }
                        .frame(width: 240)
                    } else {
                        ProgressView("Generating QR…")
                            .frame(width: 240, height: 240)
                    }
                }
            }

            Spacer()

            HStack {
                GlassButtonView(
                    label: info.text,
                    systemImage: info.icon,
                    action: {}
                )
                .foregroundStyle(info.color)
                .focusable(false)


                GlassButtonView(
                    label: "",
                    systemImage: "gearshape",
                    iconOnly: true,
                    action: {showingSettingsPopover.toggle()}
                )
                .popover(isPresented: $showingSettingsPopover, arrowEdge: .top) {
                    ConnectionPillPopover()
                }
                .focusable(false)
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 8)
        .onAppear {
            qrManager.generateQRAsync()
            WhatsNewTourManager.shared.evaluateActiveItem()
        }
        .onDisappear {
            qrManager.cleanUpTimer()
        }
    }
}
