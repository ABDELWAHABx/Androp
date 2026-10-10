import SwiftUI
import AppKit
import Combine

/// Shares one bounded Find Phone request across the menu and main window.
/// This records a request, not a delivery acknowledgement from the phone.
final class FindPhoneRequestState: ObservableObject {
    static let shared = FindPhoneRequestState()
    @Published private(set) var hasPendingRequest = false
    @Published private(set) var message: String?
    private var expiry: DispatchWorkItem?
    private var connectionObserver: AnyCancellable?
    private var targetID: String?

    private init() {
        connectionObserver = Publishers.CombineLatest(AppState.shared.$device, AppState.shared.$isSyncPaused)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] device, paused in
                guard let self = self else { return }
                if paused || device == nil || device?.deviceId != self.targetID {
                    self.reset()
                }
                self.targetID = device?.deviceId
            }
    }

    func toggleRequest() {
        guard !AppState.shared.isSyncPaused, AppState.shared.device != nil else { return }
        if hasPendingRequest {
            guard WebSocketServer.shared.sendFindPhone(stop: true) else {
                message = "Couldn't send stop. The alert ends automatically."
                return
            }
            reset()
            return
        }
        guard WebSocketServer.shared.sendFindPhone() else {
            message = "Couldn't send. Reconnect your phone."
            return
        }
        hasPendingRequest = true
        message = "Ring requested · up to 30 seconds"
        expiry?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reset() }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private func reset() {
        expiry?.cancel()
        expiry = nil
        hasPendingRequest = false
        message = nil
    }
}

struct FindPhoneButton: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var request = FindPhoneRequestState.shared
    var compact = false

    private var available: Bool { appState.device != nil && !appState.isSyncPaused }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: request.toggleRequest) {
                Label(request.hasPendingRequest ? "Stop ringing" : "Find phone",
                      systemImage: request.hasPendingRequest ? "speaker.slash.fill" : "iphone.radiowaves.left.and.right")
                    .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: compact ? 24 : 28)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(compact ? .regular : .large)
            .disabled(!available)
            .accessibilityHint("Requests a ring for up to thirty seconds. Your phone's sound settings apply.")
            .help(appState.isSyncPaused ? "Resume syncing to find your phone" :
                    (available ? "Ring your connected phone for up to 30 seconds; phone sound settings apply" : "Connect your phone first"))
            if let message = request.message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(message)
            }
        }
    }
}

struct PhoneConnectionSummary: View {
    @ObservedObject private var appState = AppState.shared
    var compact = false

    private var deviceName: String {
        appState.device?.name ?? UserDefaults.standard.string(forKey: "lastRegularDeviceName") ?? "Your phone"
    }
    private var isAvailable: Bool { appState.device != nil && !appState.isSyncPaused }
    private var connectionLabel: String {
        if appState.isSyncPaused { return "Sync paused" }
        guard let device = appState.device else { return "Phone offline" }
        if device.isBLE { return "Bluetooth LE connected" }
        return device.ipAddress.hasPrefix("100.") ? "Network connected" : "Wi-Fi connected"
    }
    private var connectionIcon: String {
        if appState.isSyncPaused { return "pause.circle.fill" }
        guard let device = appState.device else { return "iphone.slash" }
        return device.isBLE ? "antenna.radiowaves.left.and.right" : "wifi"
    }
    private var isSamsung: Bool {
        let name = deviceName.lowercased()
        return name.contains("samsung") || name.contains("galaxy") || name.contains("s21 fe") || name.contains("sm-g990")
    }
    private var capabilityText: String {
        if appState.isSyncPaused { return "Connections and background work stopped." }
        if appState.device == nil { return "Open androp on your phone to reconnect." }
        if appState.device?.isBLE == true { return "Messages and controls · Wi-Fi needed for files" }
        if appState.adbConnected {
            return appState.adbConnectionMode == .wired ? "USB mirroring ready · Wi-Fi sync" : "Wireless mirroring ready"
        }
        return "Files, clipboard and notifications"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 7) {
            Text(deviceName)
                .font(compact ? .headline : .title3.weight(.semibold))
                .lineLimit(2)
            Label(connectionLabel, systemImage: connectionIcon)
                .font(.caption.weight(.medium))
                .foregroundStyle(isAvailable ? Color.green : Color.secondary)
            Text(capabilityText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if isSamsung && isAvailable && !compact {
                Text("One UI: allow Nearby devices and notification access on your phone.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if appState.device?.isBLE == true && appState.adbConnected {
                Label(appState.adbConnectionMode == .wired ? "USB mirroring ready" : "Wireless mirroring ready",
                      systemImage: appState.adbConnectionMode == .wired ? "cable.connector" : "airplay.video")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct PhoneActionTile: View {
    let title: String
    let symbol: String
    var enabled = true
    var help = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                Text(title).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!enabled)
        .help(help.isEmpty ? title : help)
        .accessibilityLabel(title)
    }
}

struct PhonePrimaryActions: View {
    @ObservedObject private var appState = AppState.shared
    @State private var showingPlusPopover = false
    var compact = false
    private var available: Bool { appState.device != nil && !appState.isSyncPaused }
    private var filesAvailable: Bool { available && appState.device?.isRegularConnection == true }

    var body: some View {
        VStack(spacing: 8) {
            FindPhoneButton(compact: compact)
            HStack(spacing: 6) {
                PhoneActionTile(title: "Send files", symbol: "square.and.arrow.up", enabled: filesAvailable,
                                help: filesAvailable ? "Choose files and review before sending" : "Files need a connected Wi-Fi session") {
                    QuickShareManager.shared.chooseFilesForConnectedDevice()
                }
                .keyboardShortcut("f", modifiers: .command)
                PhoneActionTile(title: "Open files", symbol: "folder", enabled: filesAvailable && appState.isFileAccessEnabled,
                                help: filesAvailable ? "Browse your phone's files" : "File browsing needs Wi-Fi") {
                    guard appState.isPlus || !appState.licenseCheck else {
                        showingPlusPopover = true
                        return
                    }
                    if WebDAVManager.shared.isMounted {
                        WebDAVManager.shared.openInFinder()
                    } else {
                        appState.openFileBrowser()
                    }
                }
                .keyboardShortcut("b", modifiers: .command)
                .popover(isPresented: $showingPlusPopover) {
                    PlusFeaturePopover(message: "Browse files with androp+")
                }
            }
        }
    }
}

/// Both surfaces use the same clipboard action and file-review flow.
enum PhoneClipboardAction {
    static func send() {
        let appState = AppState.shared
        guard let target = appState.device, !appState.isSyncPaused else { return }
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            guard appState.device?.isRegularConnection == true else { return }
            QuickShareManager.shared.prepareFilesForConnectedDevice(urls)
        } else if let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation {
            guard appState.device?.isRegularConnection == true else { return }
            DispatchQueue.global(qos: .utility).async {
                guard let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else { return }
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("androp-clipboard-\(UUID().uuidString).png")
                do { try png.write(to: file) } catch { return }
                DispatchQueue.main.async {
                    guard !appState.isSyncPaused, appState.device?.isRegularConnection == true,
                          appState.device?.deviceId == target.deviceId else {
                        try? FileManager.default.removeItem(at: file)
                        return
                    }
                    QuickShareManager.shared.prepareFilesForConnectedDevice([file])
                }
            }
        } else if let text = pasteboard.string(forType: .string) {
            appState.sendClipboardToAndroid(text: text, force: true)
        }
    }
}

extension DeviceStatus.Music {
    var hasDisplayableSession: Bool {
        let emptyValues: Set<String> = ["", "unknown", "unknown title", "unknown artist", "none", "null"]
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return isPlaying || !emptyValues.contains(cleanTitle) || !emptyValues.contains(cleanArtist)
    }
}

/// Decode artwork only when its payload changes, rather than on every status or
/// playback-position update observed by the surrounding dashboard.
struct PhoneMediaArtworkBackground: View {
    let artwork: String
    var visible: Bool
    @State private var image: NSImage?

    var body: some View {
        Group {
            if visible, !artwork.isEmpty, let image = image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .accessibilityHidden(true)
        .onAppear { updateImage() }
        .onChange(of: artwork) { _, _ in updateImage() }
        .onChange(of: visible) { _, _ in updateImage() }
    }

    private func updateImage() {
        guard visible, let data = Data(base64Encoded: artwork.stripBase64Prefix()), !data.isEmpty else {
            image = nil
            return
        }
        image = NSImage(data: data)
    }
}
