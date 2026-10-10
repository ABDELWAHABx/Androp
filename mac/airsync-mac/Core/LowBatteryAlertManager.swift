import AppKit
import Combine
import UserNotifications

final class LowBatteryAlertManager: ObservableObject {
    static let shared = LowBatteryAlertManager()
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "phoneLowBatteryAlertsEnabled")
    @Published private(set) var threshold: Int = {
        let saved = UserDefaults.standard.integer(forKey: "phoneLowBatteryAlertThreshold")
        return (5...50).contains(saved) ? saved : 20
    }()
    @Published private(set) var soundEnabled = UserDefaults.standard.bool(forKey: "phoneLowBatteryAlertSound")
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var error: String?
    private var observers = Set<AnyCancellable>()
    private weak var appState: AppState?
    private var pendingGeneration: UUID?
    private var permissionGeneration = UUID()
    private var retryAfter = Date.distantPast
    private let notificationID = "androp.phone.low-battery"
    private var alertedDevices = UserDefaults.standard.stringArray(forKey: "phoneLowBatteryAlertedDevices") ?? []

    func start(appState: AppState) {
        guard self.appState == nil else { return }
        self.appState = appState
        Publishers.CombineLatest3(appState.$status, appState.$device, appState.$isSyncPaused)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in self?.evaluate() }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshAuthorization() }
            .store(in: &observers)
        refreshAuthorization()
    }

    var permissionGranted: Bool { authorization == .authorized || authorization == .provisional }

    func setEnabled(_ value: Bool) {
        let generation = UUID()
        permissionGeneration = generation
        retryAfter = .distantPast
        enabled = value
        UserDefaults.standard.set(value, forKey: "phoneLowBatteryAlertsEnabled")
        if !value { clearPending(); return }
        // This method is called only by the user's settings toggle.
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self, self.enabled, self.permissionGeneration == generation else { return }
                if settings.authorizationStatus == .notDetermined {
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, requestError in
                        DispatchQueue.main.async {
                            guard let self, self.enabled, self.permissionGeneration == generation else { return }
                            self.error = requestError?.localizedDescription
                            self.refreshAuthorization()
                        }
                    }
                } else {
                    self.refreshAuthorization()
                }
            }
        }
    }

    func setThreshold(_ value: Int) {
        threshold = min(50, max(5, value))
        UserDefaults.standard.set(threshold, forKey: "phoneLowBatteryAlertThreshold")
        clearPending()
        evaluate()
    }

    func setSoundEnabled(_ value: Bool) {
        soundEnabled = value
        UserDefaults.standard.set(value, forKey: "phoneLowBatteryAlertSound")
    }

    func refreshAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authorization = settings.authorizationStatus
                self.evaluate()
            }
        }
    }

    func sendTest() {
        guard permissionGranted else { return }
        let content = UNMutableNotificationContent()
        content.title = "androp battery alerts"
        content.body = "Phone battery alerts are ready. Your threshold is \(threshold)%."
        if soundEnabled { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notificationID + ".test", content: content, trigger: nil)) { [weak self] failure in
            DispatchQueue.main.async { self?.error = failure?.localizedDescription }
        }
    }

    private func clearPending() {
        guard let generation = pendingGeneration else { return }
        pendingGeneration = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [requestID(generation)])
    }

    private func requestID(_ generation: UUID) -> String { notificationID + "." + generation.uuidString }

    private func evaluate() {
        guard let state = appState, enabled, !state.isSyncPaused,
              let device = state.device, !device.deviceId.isEmpty,
              let status = state.status, status.isPaired else { clearPending(); return }
        let battery = status.battery
        guard battery.isReported != false else { clearPending(); return }
        let wasAlerted = alertedDevices.contains(device.deviceId)
        guard let latch = PhoneBatteryAlertPolicy.nextLatch(level: battery.level, charging: battery.isCharging,
                                                          threshold: threshold, alerted: wasAlerted) else { clearPending(); return }
        if !latch && wasAlerted {
            alertedDevices.removeAll { $0 == device.deviceId }
            persistLatch()
        }
        guard permissionGranted,
              PhoneBatteryAlertPolicy.shouldAlert(level: battery.level, charging: battery.isCharging,
                                                  threshold: threshold, alerted: latch) else { clearPending(); return }
        guard pendingGeneration == nil, Date() >= retryAfter else { return }
        let generation = UUID()
        pendingGeneration = generation
        let content = UNMutableNotificationContent()
        content.title = "\(device.name) needs charging"
        content.body = "Phone battery is at \(battery.level)%. Connect it to a charger."
        if soundEnabled { content.sound = .default }
        let identifier = requestID(generation)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { [weak self] failure in
            DispatchQueue.main.async {
                guard let self, self.pendingGeneration == generation else {
                    // Cancellation may race the notification daemon accepting add().
                    // A unique ID prevents this cleanup from removing a newer alert.
                    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
                    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
                    return
                }
                self.pendingGeneration = nil
                self.error = failure?.localizedDescription
                self.retryAfter = failure == nil ? .distantPast : Date().addingTimeInterval(60)
                if failure == nil {
                    self.alertedDevices.removeAll { $0 == device.deviceId }
                    self.alertedDevices.append(device.deviceId)
                    self.alertedDevices = Array(self.alertedDevices.suffix(32))
                    self.persistLatch()
                }
            }
        }
    }

    private func persistLatch() { UserDefaults.standard.set(alertedDevices, forKey: "phoneLowBatteryAlertedDevices") }
}
