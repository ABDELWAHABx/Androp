import SwiftUI

/// The Mac-side permission page: one button turns on everything on the phone, using
/// wireless debugging once instead of a dozen Android settings screens.
struct PhonePermissionsSettingsView: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var granter = PhonePermissionGranter.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsHeaderView(title: "Phone permissions", icon: "lock.shield")
                VStack(alignment: .leading, spacing: 14) {
                    Text("Turn on everything androp can do on your phone: notifications, clipboard from any app, calls, hotspot and staying connected in the background.")
                        .fixedSize(horizontal: false, vertical: true)

                    if !granter.adbInstalled {
                        step(1, "Install Android platform tools on this Mac:")
                        HStack {
                            Text("brew install android-platform-tools").font(.system(.body, design: .monospaced))
                            Spacer()
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("brew install android-platform-tools", forType: .string)
                            }
                        }
                        .padding(8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    } else if !appState.adbConnected {
                        step(1, "On your phone, turn on Developer options → Wireless debugging.")
                        step(2, "Pair once, then connect.")
                        HStack {
                            Button("Pair with code…") { appState.showADBPairingSheet = true }
                            Button(appState.adbConnecting ? "Connecting…" : "Connect") { connect() }
                                .disabled(appState.device == nil || appState.adbConnecting)
                            Spacer()
                            // A phone plugged in over USB works without wireless pairing.
                            Button("Allow everything over USB") { granter.grantAll() }
                                .disabled(granter.state == .working)
                        }
                    }

                    if granter.adbInstalled && appState.adbConnected {
                        HStack {
                            Button {
                                granter.grantAll()
                            } label: {
                                Label("Allow everything", systemImage: "checkmark.shield")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(granter.state == .working)
                            if granter.state == .working { ProgressView().controlSize(.small) }
                        }
                    }

                    switch granter.state {
                    case .done:
                        Label("Done. Everything is on — you can turn Wireless debugging off.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .noADB:
                        Label("Phone not reachable. Connect wireless debugging or plug in USB.", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    case .failed:
                        Label("Some settings didn't apply. Try again.", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    case .idle, .working:
                        EmptyView()
                    }
                }
                .padding()
                .glassBoxIfAvailable(radius: 18)
            }
            .padding()
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)").font(.caption.weight(.bold))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            Text(text)
        }
    }

    /// Same flow as Connect ADB elsewhere: ask the phone for its current debugging ports.
    private func connect() {
        appState.adbConnectionResult = ""
        appState.manualAdbConnectionPending = true
        appState.userInitiatedAdbConnect = true
        WebSocketServer.shared.sendRefreshAdbPortsRequest()
    }
}
