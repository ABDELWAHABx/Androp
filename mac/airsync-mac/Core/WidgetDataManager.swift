import Combine
import Foundation
import WidgetKit

final class WidgetDataManager: ObservableObject {
    static let shared = WidgetDataManager()
    @Published private(set) var nativeSharingAvailable = false
    private let appGroupIdentifier = "group.app.androp.mac.widget"
    private let snapshotFile = "phone-widget-snapshot.json"
    private let writer = DispatchQueue(label: "app.androp.widget.snapshot", qos: .utility)
    private var observers = Set<AnyCancellable>()
    private var started = false
    private var lastSnapshot: Snapshot?
    private var pendingWrite: (Data, URL)?
    private var writing = false
    private var reloadWork: DispatchWorkItem?
    private var lastReload = Date.distantPast

    private struct Snapshot: Codable, Equatable {
        let deviceName: String
        let batteryLevel: Int
        let batteryKnown: Bool
        let isCharging: Bool
        let isPaired: Bool
        let isPaused: Bool
        let wallpaperBase64: String?
        let isLocalNetwork: Bool
        let isBLEConnected: Bool
        let isADBConnected: Bool
        let adbMode: String
        let isMusicPlaying: Bool
        let musicTitle: String
        let musicArtist: String
        let musicAlbumArt: String
    }

    func refreshAvailability() {
        // A nonnil UserDefaults(suiteName:) does not prove that the App Group exists.
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            nativeSharingAvailable = false
            return
        }
        nativeSharingAvailable = FileManager.default.isWritableFile(atPath: group.path)
    }

    func start(appState: AppState) {
        guard !started else { return }
        started = true
        let publish = { [weak self, weak appState] in
            guard let self, let state = appState else { return }
            self.updateWidgetData(deviceStatus: state.status, deviceName: state.device?.name ?? "Your phone",
                                  wallpaperBase64: state.currentDeviceWallpaperBase64,
                                  isLocalNetwork: state.isConnectedOverLocalNetwork,
                                  isBLEConnected: BLECentralManager.shared.isAuthenticated,
                                  isADBConnected: state.adbConnected,
                                  adbMode: state.adbConnectionMode?.rawValue ?? "wireless",
                                  isPaused: state.isSyncPaused, isConnected: state.device != nil)
        }
        Publishers.CombineLatest3(appState.$status, appState.$device, appState.$isSyncPaused)
            .receive(on: DispatchQueue.main).sink { _, _, _ in publish() }.store(in: &observers)
        appState.$currentDeviceWallpaperBase64.receive(on: DispatchQueue.main)
            .sink { _ in publish() }.store(in: &observers)
        appState.$adbConnected.receive(on: DispatchQueue.main)
            .sink { _ in publish() }.store(in: &observers)
        appState.$adbConnectionMode.receive(on: DispatchQueue.main)
            .sink { _ in publish() }.store(in: &observers)
        refreshAvailability()
    }

    func updateWidgetData(deviceStatus: DeviceStatus?, deviceName: String, wallpaperBase64: String? = nil,
                          isLocalNetwork: Bool = false, isBLEConnected: Bool = false,
                          isADBConnected: Bool = false, adbMode: String = "wireless",
                          isPaused: Bool = false, isConnected: Bool? = nil) {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            nativeSharingAvailable = false
            lastSnapshot = nil
            return
        }
        let connected = !isPaused && (isConnected ?? (deviceStatus?.isPaired == true))
        let music = connected ? deviceStatus?.music : nil
        let snapshot = Snapshot(
            deviceName: String(deviceName.prefix(200)),
            batteryLevel: min(100, max(0, deviceStatus?.battery.level ?? 0)),
            batteryKnown: deviceStatus != nil && deviceStatus?.battery.isReported != false && (0...100).contains(deviceStatus?.battery.level ?? -1),
            isCharging: connected && deviceStatus?.battery.isCharging == true,
            isPaired: connected, isPaused: isPaused,
            wallpaperBase64: boundedImage(wallpaperBase64, maxBytes: 3_000_000),
            isLocalNetwork: connected && isLocalNetwork, isBLEConnected: connected && isBLEConnected,
            isADBConnected: connected && isADBConnected, adbMode: adbMode,
            isMusicPlaying: music?.isPlaying == true,
            musicTitle: String((music?.title ?? "").prefix(500)),
            musicArtist: String((music?.artist ?? "").prefix(500)),
            musicAlbumArt: boundedImage(music?.albumArt, maxBytes: 1_000_000) ?? "")
        guard snapshot != lastSnapshot else { return }
        guard let encoded = try? JSONEncoder().encode(snapshot),
              var payload = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] else { return }
        payload["updatedAt"] = Date().timeIntervalSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        lastSnapshot = snapshot
        let destination = group.appendingPathComponent(snapshotFile)
        // Publish one atomic, bounded snapshot; the extension never sees partial fields.
        pendingWrite = (data, destination)
        drainNextWrite()
    }

    private func drainNextWrite() {
        guard !writing, let (data, destination) = pendingWrite else { return }
        pendingWrite = nil
        writing = true
        writer.async { [weak self] in
            do {
                try data.write(to: destination, options: .atomic)
                DispatchQueue.main.async {
                    self?.nativeSharingAvailable = true
                    self?.scheduleReload()
                    self?.writing = false
                    self?.drainNextWrite()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.nativeSharingAvailable = false
                    self?.lastSnapshot = nil
                    self?.writing = false
                    self?.drainNextWrite()
                }
            }
        }
    }

    private func boundedImage(_ value: String?, maxBytes: Int) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= maxBytes else { return nil }
        return value
    }

    private func scheduleReload() {
        guard reloadWork == nil else { return }
        let delay = max(0, 15 - Date().timeIntervalSince(lastReload))
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reloadWork = nil
            self.lastReload = Date()
            WidgetCenter.shared.reloadTimelines(ofKind: "PhoneInfoWidget")
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
