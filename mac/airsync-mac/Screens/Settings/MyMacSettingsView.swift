import SwiftUI

struct MyMacSettingsView: View {
    @ObservedObject var appState = AppState.shared
    @ObservedObject private var power = MacPowerManager.shared
    @ObservedObject private var ble = BLECentralManager.shared

    @State private var deviceName: String = ""
    @State private var port: String = "6997"
    @State private var availableAdapters: [(name: String, address: String)] = []
    @State private var currentIPAddress: String = "N/A"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 1. Device Info
                SettingsHeaderView(title: "Device Name", icon: "iphone")
                VStack {
                    DeviceNameView(deviceName: $deviceName)
                }
                .padding()
                .glassBoxIfAvailable(radius: 18)

                PhoneExtrasSettingsView()

                SettingsHeaderView(title: "Power", icon: "moon.zzz")
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Keep Mac awake during active sync", isOn: $appState.keepAwakeEnabled)
                        .toggleStyle(.switch)
                        .accessibilityHint("Prevents idle sleep only during transfers, recent remote control or media playback.")
                    Label(power.keepAwakeActive ? "Preventing idle sleep · \(power.keepAwakeReason)" : "Normal idle sleep allowed",
                          systemImage: power.keepAwakeActive ? "sun.max" : "moon")
                        .font(.caption)
                    if let closed = power.lidClosed {
                        Text(closed ? "Laptop lid closed" : "Laptop lid open")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Prevents idle sleep during active work; the display can turn off. This ordinary idle-sleep setting does not override lid closure.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15 {
                        Divider()
                        Toggle("Experimental closed-lid mode", isOn: $appState.experimentalClosedLidEnabled)
                            .toggleStyle(.switch)
                            .disabled(!MacClamshellController.isAvailable)
                            .accessibilityHint("Local opt-in for an unverified private macOS 15 driver request. Only active sync renews the thirty-second watchdog.")
                        Text("macOS 15 test mode. Attempts to keep closed-lid work running only during active sync. Hardware behavior is unverified; test with the lid open and your Mac in reach before relying on it. The driver setting is shared with macOS and other apps. Avoid heat buildup in a bag.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !MacClamshellController.isAvailable {
                            Text("The experimental helper is unavailable in this build.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if power.closedLidOverrideActive {
                            Label("Experimental request accepted · watchdog active", systemImage: "laptopcomputer")
                                .font(.caption)
                        }
                    }
                    if let error = power.powerError {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding()
                .glassBoxIfAvailable(radius: 18)

                // 2. Connection Mode
                SettingsHeaderView(title: L("settings.connectionMode"), icon: "antenna.radiowaves.left.and.right")
                VStack(alignment: .leading, spacing: 12) {
                    HStack{
                        Picker("", selection: $appState.connectionMode) {
                            ForEach(AppState.AppConnectionMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                    .pickerStyle(.segmented)
                    .controlSize(.large)

                    Spacer()
                    }

                    Text(connectionModeDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .glassBoxIfAvailable(radius: 18)

                // 3. Server settings
                SettingsHeaderView(title: "Server Configuration", icon: "server.rack")
                VStack(spacing: 12) {
                    HStack {
                        Label("Network adapter", systemImage: "rectangle.connected.to.line.below")
                        Spacer()

                        Picker("", selection: Binding(
                            get: { appState.selectedNetworkAdapterName },
                            set: { appState.selectedNetworkAdapterName = $0 }
                        )) {
                            Text("Auto").tag(nil as String?)
                            ForEach(availableAdapters, id: \.name) { adapter in
                                Text("\(adapter.name) (\(adapter.address))").tag(Optional(adapter.name))
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                    }
                    .onAppear {
                        availableAdapters = WebSocketServer.shared.getAvailableNetworkAdapters()
                        currentIPAddress = WebSocketServer.shared.getLocalIPAddress(adapterName: appState.selectedNetworkAdapterName) ?? "N/A"
                    }
                    .onChange(of: appState.selectedNetworkAdapterName) { _, _ in
                        currentIPAddress = WebSocketServer.shared.getLocalIPAddress(adapterName: appState.selectedNetworkAdapterName) ?? "N/A"
                        WebSocketServer.shared.stop()
                        if let port = UInt16(port) {
                            WebSocketServer.shared.start(port: port)
                        } else {
                            WebSocketServer.shared.start()
                        }
                        appState.shouldRefreshQR = true
                    }

                    ConnectionInfoText(
                        label: "IP address",
                        icon: "wifi",
                        text: currentIPAddress,
                        activeIp: appState.activeMacIp
                    )

                    HStack {
                        Label("Server port", systemImage: "rectangle.connected.to.line.below")
                            .padding(.trailing, 20)
                        Spacer()
                        TextField("Server Port", text: $port)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: port) { oldValue, newValue in
                                port = newValue.filter { "0123456789".contains($0) }
                            }
                            .frame(maxWidth: 100)
                    }
                }
                .padding()
                .glassBoxIfAvailable(radius: 18)


                HStack {
                    Spacer()
                    SaveAndRestartButton(
                        title: "Save and Restart the Server",
                        systemImage: "square.and.arrow.down.badge.checkmark",
                        deviceName: deviceName,
                        port: port,
                        version: appState.device?.version ?? "",
                        onSave: nil,
                        onRestart: nil
                    )
                }

                // 4. Connection settings
                SettingsHeaderView(title: "Nearby", icon: "dot.radiowaves.left.and.right")
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.title3)
                            .foregroundColor(.accentColor)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-connect Bluetooth")
                                .font(.body)
                            Text("Automatically connect to known nearby devices over Bluetooth")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $appState.isBLEAutoConnectEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(!appState.isBLEEnabled)
                    }

                    HStack(spacing: 12) {
                        Image(systemName: "arrow.triangle.swap")
                            .font(.title3)
                            .foregroundColor(.accentColor)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto switch with nearby")
                                .font(.body)
                            Text("Automatically switch between Wi-Fi and Bluetooth LE when detected and stable")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $appState.isAutoSwitchWithBLEEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(!appState.isBLEEnabled)
                    }

                    HStack(spacing: 12) {
                        Image(systemName: "bolt.horizontal")
                            .font(.title3)
                            .foregroundColor(.accentColor)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Instant reconnect")
                                .font(.body)
                            Text(ble.bondIssue ?? "Pair the phone with this Mac over Bluetooth once, so it reconnects the moment it's in range. Both devices ask to confirm.")
                                .font(.caption)
                                .foregroundColor(ble.bondIssue == nil ? Color.secondary : Color.orange)
                        }
                        Spacer()
                        Toggle("", isOn: $ble.instantReconnectEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(!appState.isBLEEnabled)
                    }
                }
                .padding()
                .glassBoxIfAvailable(radius: 18)

            }
            .padding()
        }
        .onAppear {
            if let device = appState.myDevice {
                deviceName = device.name
                port = String(device.port)
            } else {
                deviceName = UserDefaults.standard.string(forKey: "deviceName")
                ?? (Host.current().localizedName ?? "My Mac")
                port = UserDefaults.standard.string(forKey: "devicePort")
                ?? String(Defaults.serverPort)
            }
        }
    }

    private var connectionModeDescription: String {
        switch appState.connectionMode {
        case .network:
            return L("settings.connectionMode.network.info")
        case .dynamic:
            return L("settings.connectionMode.dynamic.info")
        case .nearby:
            return L("settings.connectionMode.nearby.info")
        }
    }
}
