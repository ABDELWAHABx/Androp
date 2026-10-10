//
//  MenubarSegments.swift
//  AirSync
//
//  Created by Sameera Sandakelum on 2026-05-07.
//

import SwiftUI

struct TopSegmentView: View {
    @ObservedObject var appState = AppState.shared
    @State private var showingConnectionDetails = false
    let toolButtonSize: CGFloat
    let openAndFocusMainWindow: () -> Void
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: toolButtonSize, height: toolButtonSize)

                Menu {
                    Button(appState.isSyncPaused ? "Resume syncing" : "Pause syncing",
                           systemImage: appState.isSyncPaused ? "play.fill" : "pause.fill") {
                        appState.setSyncPaused(!appState.isSyncPaused)
                    }
                    Divider()
                    Button("Quit", systemImage: "power") {
                        NSApplication.shared.terminate(nil)
                    }
                } label: {
                    Text("androp")
                        .font(.title2)
                }
                .menuStyle(.borderlessButton)

                Spacer()

                Button {
                    showingConnectionDetails.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .disabled(appState.isSyncPaused)
                .help("Connection details")
                .accessibilityLabel("Connection details")
                .popover(isPresented: $showingConnectionDetails, arrowEdge: .bottom) {
                    ConnectionPillPopover()
                }

                GlassButtonView(
                    label: appState.isSyncPaused ? "Resume syncing" : "Pause syncing",
                    systemImage: appState.isSyncPaused ? "play.fill" : "pause.fill",
                    iconOnly: true,
                    circleSize: toolButtonSize
                ) {
                    appState.setSyncPaused(!appState.isSyncPaused)
                }
                .help(appState.isSyncPaused ? "Resume syncing" : "Pause syncing")
                .accessibilityLabel(appState.isSyncPaused ? "Resume syncing" : "Pause syncing")
                
                GlassButtonView(
                    label: "Open App",
                    systemImage: "arrow.up.forward.app",
                    iconOnly: true,
                    circleSize: toolButtonSize
                ) {
                    openAndFocusMainWindow()
                }
                .help("Open androp")
                .accessibilityLabel("Open androp")
            }

            PhoneConnectionSummary()
            PhonePrimaryActions()
            if appState.device != nil && !appState.isSyncPaused {
                HStack(spacing: 6) {
                    GlassButtonView(
                        label: "Send Clipboard",
                        systemImage: "clipboard",
                        iconOnly: true,
                        circleSize: toolButtonSize,
                        action: {
                            sendClipboard()
                        }
                    )
                    .help(appState.device?.isBLE == true ? "Send copied text; images and files need Wi-Fi" : "Send Clipboard")
                    .accessibilityLabel("Send Clipboard")
                    
                    if appState.adbConnected && (appState.isPlus || !appState.licenseCheck) {
                        GlassButtonView(
                            label: "Mirror",
                            systemImage: "apps.iphone",
                            iconOnly: true,
                            circleSize: toolButtonSize,
                            action: {
                                if appState.useNativeMirroringByDefault {
                                    appState.isNativeMirroring = true
                                } else {
                                    ADBConnector.startScrcpy(
                                        ip: appState.device?.ipAddress ?? "",
                                        port: appState.adbPort,
                                        deviceName: appState.device?.name ?? "My Phone"
                                    )
                                }
                            }
                        )
                        .contextMenu {
                            if appState.useNativeMirroringByDefault {
                                Button("scrcpy Mirror") {
                                    ADBConnector.startScrcpy(
                                        ip: appState.device?.ipAddress ?? "",
                                        port: appState.adbPort,
                                        deviceName: appState.device?.name ?? "My Phone"
                                    )
                                }
                            } else {
                                Button("Android Mirror") {
                                    appState.isNativeMirroring = true
                                }
                            }

                            Divider()

                            if appState.useNativeDesktopMirroringByDefault {
                                Button("Native Desktop") {
                                    appState.isNativeDesktopMirroring = true
                                }
                                Button("scrcpy Desktop") {
                                    ADBConnector.startScrcpy(
                                        ip: appState.device?.ipAddress ?? "",
                                        port: appState.adbPort,
                                        deviceName: appState.device?.name ?? "My Phone",
                                        desktop: true
                                    )
                                }
                            } else {
                                Button("Desktop Mode") {
                                    ADBConnector.startScrcpy(
                                        ip: appState.device?.ipAddress ?? "",
                                        port: appState.adbPort,
                                        deviceName: appState.device?.name ?? "My Phone",
                                        desktop: true
                                    )
                                }
                                Button("Native Desktop") {
                                    appState.isNativeDesktopMirroring = true
                                }
                            }
                        }

                    }
                    
                    
                    GlassButtonView(
                        label: "DND",
                        systemImage: appState.silenceAllNotifications ? "bell.slash.fill" : "bell.badge",
                        iconOnly: true,
                        circleSize: toolButtonSize
                    ) {
                        appState.silenceAllNotifications.toggle()
                    }
                    .help(appState.silenceAllNotifications ? "Unmute notifications" : "Mute notifications")
                    .accessibilityLabel(appState.silenceAllNotifications ? "Unmute notifications" : "Mute notifications")

                    if appState.adbConnected {
                        GlassButtonView(
                            label: "Summon Screenshot",
                            systemImage: "iphone.pattern.diagonalline.on.rectangle.portrait.dashed",
                            iconOnly: true,
                            circleSize: toolButtonSize
                        ) {
                            SummonManager.shared.summonScreenshot()
                        }
                    }
                }
                
                ConnectedFileDropZone(compact: true)
                    .disabled(appState.device?.isRegularConnection != true)

                if appState.adbConnected && !appState.recentApps.isEmpty {
                    RecentAppsGridView()
                }
            }
        }
        .padding(12)
        .segmentStyle()
    }
    
    private func sendClipboard() {
        PhoneClipboardAction.send()
    }

}

struct MediaSegmentView: View {
    @ObservedObject var appState = AppState.shared
    
    var body: some View {
        if let status = appState.status {
            DeviceStatusView(showMediaToggle: true)
                .background {
                    PhoneMediaArtworkBackground(
                        artwork: status.music?.albumArt ?? "",
                        visible: !appState.isMusicCardHidden && status.music?.hasDisplayableSession == true
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 20))

        }
    }
}



struct DiscoverySegmentView: View {
    @ObservedObject var appState = AppState.shared
    @ObservedObject private var udpDiscovery = DiscoveryManager.shared
    @ObservedObject private var bleManager = BLECentralManager.shared

    var body: some View {
        let hasUdp = !udpDiscovery.discoveredDevices.isEmpty
        let hasBle = appState.isBLEEnabled && !bleManager.discoveredBLEDevices.isEmpty
        
        if !appState.isSyncPaused && appState.device == nil && (hasUdp || hasBle) {
            MenubarDeviceDiscoveryView()
                .padding(10)
                .segmentStyle()
        }
    }
}

struct NotificationsSegmentView: View {
    @ObservedObject var appState = AppState.shared
    @ObservedObject var summaryViewModel = NotificationSummaryViewModel.shared
    
    var body: some View {
        let nonSilentNotifications = appState.notifications.filter { $0.priority != "silent" }
        let filtered = appState.includeSilentInAIOption ? appState.notifications : nonSilentNotifications
        
        if appState.device != nil && !nonSilentNotifications.isEmpty {
            VStack(spacing: 6) {
                HStack {
                    Text("Notifications")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)

                if !appState.disableAllAIFeatures && appState.enableMenubarAISummary && filtered.count >= 3 {
                    if summaryViewModel.showMenubarSummary {
                        MenubarSummaryCardView(viewModel: summaryViewModel)
                            .padding(6)
                            .segmentStyle()
                            .modifier(AIGlowModifier(isGenerating: summaryViewModel.isGeneratingSummary, cornerRadius: 20))
                    }
                }

                MenuBarNotificationsListView()
            }
            .onAppear {
                if appState.autoMenubarSummary {
                    summaryViewModel.showMenubarSummary = true
                }
                if summaryViewModel.showMenubarSummary {
                    summaryViewModel.generateSummary(notifications: appState.notifications, androidApps: appState.androidApps)
                }
            }
            .onChange(of: appState.notifications) { _, newNotifications in
                if summaryViewModel.showMenubarSummary {
                    summaryViewModel.generateSummary(notifications: newNotifications, androidApps: appState.androidApps)
                }
            }
        }
    }
}



