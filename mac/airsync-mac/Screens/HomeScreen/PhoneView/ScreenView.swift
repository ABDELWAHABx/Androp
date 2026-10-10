import SwiftUI
import AppKit

/// A compact dashboard inside the phone card. Long content scrolls instead of
/// clipping the actions or reserving space for an empty player.
struct ScreenView: View {
    @ObservedObject var appState = AppState.shared

    private var available: Bool { appState.device != nil && !appState.isSyncPaused }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                PhoneConnectionSummary(compact: true)
                if appState.isSyncPaused {
                    Button("Resume syncing", systemImage: "play.fill") {
                        appState.setSyncPaused(false)
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                }
                PhonePrimaryActions(compact: true)
                HStack(spacing: 6) {
                    PhoneActionTile(title: "Clipboard", symbol: "clipboard", enabled: available,
                                    help: appState.device?.isBLE == true ? "Send copied text; images and files need Wi-Fi" : "Send copied text, images or files") {
                        PhoneClipboardAction.send()
                    }
                    PhoneActionTile(title: "Mirror", symbol: "rectangle.on.rectangle", enabled: available && appState.adbConnected && (appState.isPlus || !appState.licenseCheck),
                                    help: appState.adbConnected ? "Open phone mirroring" : "Connect USB or wireless debugging to mirror") {
                        if appState.useNativeMirroringByDefault {
                            appState.isNativeMirroring = true
                        } else if let device = appState.device {
                            ADBConnector.startScrcpy(ip: device.ipAddress, port: appState.adbPort, deviceName: device.name)
                        }
                    }
                }
                ConnectedFileDropZone(compact: true)
                    .disabled(!available || appState.device?.isRegularConnection != true)
                if available, appState.status != nil {
                    DeviceStatusView()
                        .frame(maxWidth: .infinity)
                }
                if available && appState.adbConnected && !appState.recentApps.isEmpty {
                    Divider()
                    Text("Recent apps")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    RecentAppsGridView()
                }
                if available {
                    Button(appState.silenceAllNotifications ? "Unmute notifications" : "Mute notifications",
                           systemImage: appState.silenceAllNotifications ? "bell.slash.fill" : "bell") {
                        appState.silenceAllNotifications.toggle()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .scrollIndicators(.hidden)
        .padding(6)
        .onAppear { WhatsNewTourManager.shared.evaluateActiveItem() }
        .onChange(of: appState.device) { _, _ in WhatsNewTourManager.shared.evaluateActiveItem() }
        .onChange(of: appState.selectedTab) { _, _ in WhatsNewTourManager.shared.evaluateActiveItem() }
    }
}

#Preview { ScreenView() }
