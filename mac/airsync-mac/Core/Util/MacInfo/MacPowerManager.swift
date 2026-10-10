import Foundation
import Combine
import IOKit
import IOKit.pwr_mgt

@MainActor
final class MacPowerManager: ObservableObject {
    static let shared = MacPowerManager()
    @Published private(set) var lidClosed: Bool?
    @Published private(set) var keepAwakeActive = false
    @Published private(set) var keepAwakeReason = "Idle"
    @Published private(set) var closedLidOverrideActive = false
    @Published private(set) var lastError: String?

    private var assertion: IOPMAssertionID?
    private var expiry: DispatchWorkItem?
    private var transfers: [String: TimeInterval] = [:]
    private var remoteUntil: TimeInterval = 0
    private var mediaUntil: TimeInterval = 0
    private var lastRemoteNote: TimeInterval = -10
    private var lastMediaNote: TimeInterval = -10
    private var observers = Set<AnyCancellable>()
    private var started = false
    private var wasEligible = false
    private let clamshell = MacClamshellController()
    private var clamshellRenewal: DispatchWorkItem?
    private var experimentalError: String?
    var powerError: String? { experimentalError ?? lastError }
    private var notificationPort: IONotificationPortRef?
    private var rootDomain: io_service_t = 0
    private var notification: io_object_t = 0
    private var lidNotificationGeneration: UInt64 = 0
    private let ioQueue = DispatchQueue(label: "app.androp.power", qos: .utility)

    var statusFields: [String: Any] {
        var fields: [String: Any] = [
            "keepAwakeEnabled": AppState.shared.keepAwakeEnabled,
            "keepAwakeActive": keepAwakeActive,
            "keepAwakeReason": keepAwakeReason,
            "closedLidOverrideSupported": MacClamshellController.isAvailable,
            "closedLidOverrideEnabled": AppState.shared.experimentalClosedLidEnabled,
            "closedLidOverrideActive": closedLidOverrideActive
        ]
        if let lidClosed { fields["lidClosed"] = lidClosed }
        fields["powerError"] = powerError ?? ""
        return fields
    }

    func start() {
        guard !started else { return }
        started = true
        clamshell.onStateChange = { [weak self] active, error in
            guard let self else { return }
            self.closedLidOverrideActive = active
            if let error {
                self.experimentalError = error
                self.lastError = error
                AppState.shared.experimentalClosedLidEnabled = false
                self.clamshellRenewal?.cancel()
                self.clamshellRenewal = nil
            }
            self.publishStatus()
        }
        AppState.shared.$experimentalClosedLidEnabled.receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                if enabled { self?.experimentalError = nil }
                self?.reconcile()
            }.store(in: &observers)
        Publishers.CombineLatest3(AppState.shared.$device, AppState.shared.$isSyncPaused,
                                  AppState.shared.$keepAwakeEnabled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in
                guard let self else { return }
                self.refreshEligibility()
            }.store(in: &observers)
        MacInfoSyncManager.shared.$isPlaying.receive(on: DispatchQueue.main)
            .sink { [weak self] playing in self?.noteMediaActivity(playing: playing) }
            .store(in: &observers)
        AppState.shared.$status.receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.noteMediaActivity(playing: status?.music?.isPlaying == true) }
            .store(in: &observers)
        QuickShareManager.shared.$transferProgress.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                switch QuickShareManager.shared.transferState {
                case .connectingNetwork, .sending, .receiving: self?.setTransferActive(id: "quickshare", active: true)
                default: self?.setTransferActive(id: "quickshare", active: false)
                }
            }.store(in: &observers)
        QuickShareManager.shared.$transferState.receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                switch state {
                case .connectingNetwork, .sending, .receiving: self?.setTransferActive(id: "quickshare", active: true)
                default: self?.setTransferActive(id: "quickshare", active: false)
                }
            }.store(in: &observers)
        startLidNotifications()
        reconcile()
    }

    func setKeepAwake(enabled: Bool) {
        AppState.shared.keepAwakeEnabled = enabled
        if !enabled { clearActivity() }
        refreshEligibility()
    }

    private func refreshEligibility() {
        let eligible = canAssert
        if !eligible { clearActivity() }
        if eligible && !wasEligible { refreshMediaActivity() }
        wasEligible = eligible
        reconcile()
    }

    /// Also called by the existing battery/media status timer, since the external
    /// media stream is event-driven and does not promise periodic position events.
    func refreshMediaActivity() {
        noteMediaActivity(playing: MacInfoSyncManager.shared.isPlaying || AppState.shared.status?.music?.isPlaying == true)
    }

    /// Call on start/progress and once with false on every completion/cancellation.
    nonisolated func setTransferActive(id: String, active: Bool, timeout: TimeInterval = 120) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !id.isEmpty else { return }
            if active {
                guard self.canAssert, self.transfers.count < 64 || self.transfers[id] != nil else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let duration = timeout.isFinite ? min(900, max(1, timeout)) : 120
                // Progress may arrive for every chunk. Renew at most every ten seconds.
                if let until = self.transfers[id], until - now > duration - 10 { return }
                self.transfers[id] = now + duration
            } else { self.transfers.removeValue(forKey: id) }
            self.reconcile()
        }
    }

    nonisolated func noteRemoteActivity() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.canAssert else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastRemoteNote >= 10 else { return }
            self.lastRemoteNote = now
            self.remoteUntil = now + 60
            self.reconcile()
        }
    }

    private func noteMediaActivity(playing: Bool) {
        guard playing else {
            if !MacInfoSyncManager.shared.isPlaying && AppState.shared.status?.music?.isPlaying != true {
                mediaUntil = 0
                reconcile()
            }
            return
        }
        guard canAssert else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMediaNote >= 10 else { return }
        lastMediaNote = now
        mediaUntil = now + 120
        reconcile()
    }

    private var canAssert: Bool {
        started && AppState.shared.keepAwakeEnabled && !AppState.shared.isSyncPaused && AppState.shared.device != nil
    }

    /// Acceptance means the public sleep request was queued, not that the OS slept.
    @discardableResult func requestSleep() -> Bool {
        guard started, lidClosed == true, !AppState.shared.isSyncPaused,
              AppState.shared.device != nil else { return false }
        setKeepAwake(enabled: false)
        suspend()
        lastError = nil
        publishStatus()
        // Give the authenticated response/status frames time to enter the socket.
        clamshell.stop {
        self.ioQueue.asyncAfter(deadline: .now() + .milliseconds(300)) {
            let connection = IOPMFindPowerManagement(kIOMainPortDefault)
            guard connection != 0 else {
                DispatchQueue.main.async {
                    self.lastError = "macOS couldn't open its sleep service."
                    self.publishStatus()
                }
                return
            }
            let result = IOPMSleepSystem(connection)
            IOServiceClose(connection)
            if result != kIOReturnSuccess {
                DispatchQueue.main.async {
                    self.lastError = "macOS declined the sleep request (\(result))."
                    self.publishStatus()
                }
            }
        }
        }
        return true
    }

    func suspend() {
        wasEligible = false
        stopClamshell()
        clearActivity()
        releaseAssertion()
        publishStatus()
    }

    func stop() {
        started = false
        lidNotificationGeneration &+= 1
        observers.removeAll()
        suspend()
        let port = notificationPort
        let service = rootDomain
        let object = notification
        notificationPort = nil
        rootDomain = 0
        notification = 0
        ioQueue.async {
            if object != 0 { IOObjectRelease(object) }
            if let port { IONotificationPortDestroy(port) }
            if service != 0 { IOObjectRelease(service) }
        }
    }

    private func clearActivity() {
        transfers.removeAll()
        remoteUntil = 0
        mediaUntil = 0
        lastRemoteNote = -10
        lastMediaNote = -10
    }

    private func reconcile() {
        let now = ProcessInfo.processInfo.systemUptime
        transfers = transfers.filter { $0.value > now }
        let transferUntil = transfers.values.max() ?? 0
        let reason = MacKeepAwakePolicy.reason(enabled: canAssert, connected: AppState.shared.device != nil,
            paused: AppState.shared.isSyncPaused, now: now, transferUntil: transferUntil,
            remoteUntil: remoteUntil, mediaUntil: mediaUntil)
        expiry?.cancel()
        expiry = nil
        guard let reason else { stopClamshell(); releaseAssertion(); publishStatus(); return }
        updateClamshell(reason: reason)
        let deadline = max(transferUntil, remoteUntil, mediaUntil)
        let timeout = min(120, max(1, deadline - now))
        if let assertion {
            let result = IOPMAssertionSetProperty(assertion, kIOPMAssertionTimeoutKey as CFString, NSNumber(value: timeout))
            guard result == kIOReturnSuccess else {
                releaseAssertion()
                lastError = "macOS couldn't renew idle-sleep prevention (\(result))."
                publishStatus()
                return
            }
            let levelResult = IOPMAssertionSetProperty(assertion, kIOPMAssertionLevelKey as CFString, NSNumber(value: kIOPMAssertionLevelOn))
            guard levelResult == kIOReturnSuccess else {
                releaseAssertion()
                lastError = "macOS couldn't activate idle-sleep prevention (\(levelResult))."
                publishStatus()
                return
            }
        } else {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithDescription(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                "androp active sync" as CFString, reason as CFString, nil, nil, timeout,
                kIOPMAssertionTimeoutActionTurnOff as CFString, &id)
            guard result == kIOReturnSuccess else {
                lastError = "macOS couldn't prevent idle sleep (\(result))."
                releaseAssertion()
                publishStatus()
                return
            }
            assertion = id
        }
        keepAwakeActive = true
        keepAwakeReason = reason
        lastError = experimentalError
        let work = DispatchWorkItem { [weak self] in self?.reconcile() }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        publishStatus()
    }

    private func updateClamshell(reason: String) {
        guard MacKeepAwakePolicy.shouldUseExperimental(majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            enabled: AppState.shared.experimentalClosedLidEnabled, connected: AppState.shared.device != nil,
            paused: AppState.shared.isSyncPaused, activityReason: reason) else {
            stopClamshell()
            return
        }
        clamshell.renew()
        if clamshellRenewal == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.clamshellRenewal = nil
                self.reconcile()
            }
            clamshellRenewal = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
        }
    }

    private func stopClamshell() {
        clamshellRenewal?.cancel()
        clamshellRenewal = nil
        clamshell.stop()
    }

    private func releaseAssertion() {
        expiry?.cancel()
        expiry = nil
        if let assertion { IOPMAssertionRelease(assertion) }
        assertion = nil
        keepAwakeActive = false
        keepAwakeReason = "Idle"
    }

    private var lastPublishedStatus: NSDictionary?
    private func publishStatus() {
        let snapshot = statusFields as NSDictionary
        guard snapshot != lastPublishedStatus else { return }
        lastPublishedStatus = snapshot
        if AppState.shared.device != nil, !AppState.shared.isSyncPaused {
            WebSocketServer.shared.sendMacInfoResponse()
        }
    }

    nonisolated private static func readLid(_ service: io_service_t) -> Bool? {
        IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }

    private func startLidNotifications() {
        lidNotificationGeneration &+= 1
        let generation = lidNotificationGeneration
        ioQueue.async {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
            guard service != 0 else { return }
            let closed = Self.readLid(service)
            guard let port = IONotificationPortCreate(kIOMainPortDefault) else { IOObjectRelease(service); return }
            IONotificationPortSetDispatchQueue(port, self.ioQueue)
            var object: io_object_t = 0
            let result = IOServiceAddInterestNotification(port, service, kIOGeneralInterest, { _, service, _, _ in
                // Re-read on root-domain events rather than depending on the
                // clamshell-message C macro, which Swift cannot import in Xcode 26.
                // publishStatus suppresses unchanged snapshots; no polling is needed.
                let value = MacPowerManager.readLid(service)
                DispatchQueue.main.async {
                    guard MacPowerManager.shared.started, MacPowerManager.shared.rootDomain == service else { return }
                    MacPowerManager.shared.lidClosed = value
                    MacPowerManager.shared.publishStatus()
                }
            }, nil, &object)
            DispatchQueue.main.async {
                guard self.started, self.lidNotificationGeneration == generation else {
                    self.ioQueue.async {
                        if object != 0 { IOObjectRelease(object) }
                        IONotificationPortDestroy(port)
                        IOObjectRelease(service)
                    }
                    return
                }
                self.rootDomain = service
                self.notificationPort = port
                self.notification = result == kIOReturnSuccess ? object : 0
                self.lidClosed = result == kIOReturnSuccess ? closed : nil
                if result != kIOReturnSuccess {
                    if object != 0 { IOObjectRelease(object) }
                    self.lastError = "macOS couldn't observe laptop lid changes (\(result))."
                }
                self.publishStatus()
            }
        }
    }
}
