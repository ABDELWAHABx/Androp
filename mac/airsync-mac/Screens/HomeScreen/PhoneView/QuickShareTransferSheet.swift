import SwiftUI
import AppKit
import Foundation

@MainActor
struct QuickShareTransferSheet: View {
    @ObservedObject var manager = QuickShareManager.shared
    @ObservedObject var appState = AppState.shared
    
    var body: some View {
        ZStack {
            VisualEffectBlur(material: NSVisualEffectView.Material.hudWindow, blendingMode: NSVisualEffectView.BlendingMode.behindWindow)
                .edgesIgnoringSafeArea(Edge.Set.all)
            
            VStack(spacing: 20) {

                if case .reviewing(let target) = manager.transferState {
                    reviewView(target: target)
                } else if case .preparing(let target) = manager.transferState {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Preparing files for \(target)").font(.headline)
                        Button("Cancel") { manager.cancelActiveTransfer() }
                            .keyboardShortcut(.cancelAction)
                    }
                } else if manager.transferState == .discovering {
                    VStack(alignment: .leading, spacing: 10) {
                        if let targetName = manager.autoTargetDeviceName {
                            // Special Auto-Targeting UI for Menubar/Drop
                            VStack(spacing: 20) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(String(format: Localizer.shared.text("quickshare.waiting_for"), targetName))
                                            .font(.subheadline).bold()
                                        Text(Localizer.shared.text("quickshare.searching"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                
                                HStack(spacing: 12) {
                                    GlassButtonView(label: Localizer.shared.text("quickshare.more_devices"), size: .regular) {
                                        manager.autoTargetDeviceName = nil
                                    }
                                    
                                    GlassButtonView(label: Localizer.shared.text("quickshare.cancel"), size: .regular) {
                                        manager.stopDiscovery()
                                        appState.showingQuickShareTransfer = false
                                    }
                                }
                            }
                            // .frame(minHeight: 150)
                        } else {
                            // Default Device Selection UI
                            HStack {
                                Text(Localizer.shared.text("quickshare.select_device"))
                                    .font(.subheadline)
                                Spacer()
                                ProgressView()
                                    .controlSize(.small)
                            }
                            
                            RadarView(devices: manager.discoveredDevices) { device in
                                manager.sendFiles(urls: manager.transferURLs, to: device)
                            }
                            .frame(height: 250)
                            
                            GlassButtonView(label: Localizer.shared.text("quickshare.cancel"), size: .large) {
                                manager.stopDiscovery()
                                appState.showingQuickShareTransfer = false
                            }
                        }
                    }
                } else {
                    transferStatusView
                }
            }
            .padding(20)
        }

        .frame(minWidth: 380, idealWidth: 400)
        .animation(.default, value: manager.transferState)
    }

    private func reviewView(target: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "iphone.and.arrow.forward").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Send to \(target)").font(.headline)
                    Text("\(manager.transferURLs.count) \(manager.transferURLs.count == 1 ? "file" : "files") · \(ByteCountFormatter.string(fromByteCount: manager.selectedFileSize, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(manager.transferURLs, id: \.self) { url in
                        HStack(spacing: 10) {
                            Image(systemName: "doc.fill").foregroundStyle(.secondary)
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 8)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .frame(maxHeight: 168)
            Text("Files will be saved in Downloads on your phone.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Choose files…") { manager.chooseFilesForConnectedDevice() }
                Spacer()
                Button("Cancel") { manager.cancelActiveTransfer() }.keyboardShortcut(.cancelAction)
                Button("Send") { manager.sendPreparedFiles() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Send selected files to \(target)")
            }
        }
    }

    private var transferStatusView: some View {
        VStack(spacing: 15) {
            
            if case .awaitingPin(let pin, _) = manager.transferState {
                VStack(spacing: 5) {
                    Text(Localizer.shared.text("quickshare.confirm_pin"))
                        .font(.subheadline)
                    Text(pin)
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .padding()
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(10)
                }
            } else if case .receiving = manager.transferState {
                VStack(spacing: 8) {
                    Text(Localizer.shared.text("quickshare.receiving"))
                        .font(.headline)
                    ProgressView(value: manager.transferProgress)
                    Text("\(Int(min(1, max(0, manager.transferProgress)) * 100))%")
                        .font(.caption)
                }
            } else if case .incomingAwaitingConsent(let metadata, let device) = manager.transferState {
                VStack(spacing: 15) {
                    VStack(spacing: 5) {
                        Image(systemName: iconForDeviceType(device.type))
                            .font(.system(size: 40))
                            .padding(.bottom, 5)
                        Text(device.name)
                            .font(.subheadline).bold()
                        
                        let fileStr: String = {
                            if let textTitle = metadata.textDescription {
                                return textTitle
                            } else if metadata.files.count == 1 {
                                return metadata.files[0].name
                            } else {
                                return String(format: Localizer.shared.text("n_files"), metadata.files.count)
                            }
                        }()
                        
                        Text(fileStr)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    
                    if let pin = metadata.pinCode {
                        Text(pin)
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 15)
                            .padding(.vertical, 8)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(8)
                    }
                    
                    HStack(spacing: 15) {
                        GlassButtonView(label: Localizer.shared.text("quickshare.decline"), size: .large) {
                            manager.handleUserConsent(transferID: metadata.id, accepted: false)
                        }
                        .foregroundStyle(.red)
                        
                        GlassButtonView(label: Localizer.shared.text("quickshare.accept"), size: .large, primary: true) {
                            manager.handleUserConsent(transferID: metadata.id, accepted: true)
                        }
                        .foregroundStyle(.green)
                    }
                }
            } else if case .sending = manager.transferState {
                VStack(spacing: 8) {
                    Text(manager.sendingDeviceName.map { "Sending to \($0)" } ?? Localizer.shared.text("quickshare.sending"))
                        .font(.headline)
                    if let fileName = manager.sendingFileName {
                        Text(fileName).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    ProgressView(value: manager.transferProgress)
                    Text("\(Int(min(1, max(0, manager.transferProgress)) * 100))%")
                        .font(.caption)
                }
            } else if case .connecting = manager.transferState {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(Localizer.shared.text("quickshare.connecting"))
                        .font(.caption)
                }
            } else if manager.transferState == .finished {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text(Localizer.shared.text("quickshare.finished"))
                        .font(.headline)
                    if !manager.transferURLs.isEmpty {
                        Text("Saved in Downloads on your phone.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if case .failed(let error) = manager.transferState {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.red)
                    Text(Localizer.shared.text("quickshare.failed"))
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            
            if manager.transferState == .finished {
                GlassButtonView(label: Localizer.shared.text("quickshare.done"), size: .large, primary: true) {
                    manager.stopDiscovery()
                    appState.showingQuickShareTransfer = false
                }
            } else if manager.transferState != .idle && manager.transferState != .finished {
                Button(isFailure ? "Close" : Localizer.shared.text("quickshare.cancel")) {
                    manager.stopDiscovery()
                    manager.cancelActiveTransfer()
                    appState.showingQuickShareTransfer = false
                }
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var isFailure: Bool {
        if case .failed = manager.transferState { return true }
        return false
    }

    private func iconForDeviceType(_ type: RemoteDeviceInfo.DeviceType) -> String {
        switch type {
        case .phone: return "iphone"
        case .tablet: return "ipad"
        case .computer: return "macbook"
        default: return "questionmark.circle"
        }
    }
}
