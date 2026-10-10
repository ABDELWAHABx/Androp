import Foundation
import Combine

/// One user-initiated request at a time. Phone observations, never a successful
/// send or submitted Android request, determine the displayed hotspot state.
final class PhoneHotspotManager: ObservableObject {
    enum Action: String { case status, enable, disable, setup }

    struct State {
        let status: String
        let apiSupported: Bool?
        let writeSettingsGranted: Bool?
        let dataSaverEnabled: Bool?
        let hotspotEnabled: Bool?
        let canAttemptControl: Bool
        let errorCode: Int?
    }

    static let shared = PhoneHotspotManager()
    @Published private(set) var state: State?
    @Published private(set) var pendingAction: Action?
    @Published private(set) var message: String?

    private struct Request {
        let id: String
        let deviceID: String
        let action: Action
    }
    private var request: Request?
    private var targetID: String?
    private var timeout: DispatchWorkItem?
    private var connectionObserver: AnyCancellable?
    private var requestCompletion: ((Bool?) -> Void)?

    private init() {
        targetID = AppState.shared.device?.deviceId
        connectionObserver = Publishers.CombineLatest(AppState.shared.$device, AppState.shared.$isSyncPaused)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.connectionDidChange() }
    }

    func refreshIfNeeded() {
        if state == nil && pendingAction == nil { send(.status) }
    }

    func send(_ action: Action, completion: ((Bool?) -> Void)? = nil) {
        let appState = AppState.shared
        guard !appState.isSyncPaused, let device = appState.device, !device.deviceId.isEmpty,
              request == nil else { completion?(nil); return }
        if targetID != device.deviceId { reset() }
        targetID = device.deviceId
        let request = Request(id: UUID().uuidString, deviceID: device.deviceId, action: action)
        self.request = request
        requestCompletion = completion
        pendingAction = action
        message = action == .setup ? "Requesting setup on your phone…" : "Waiting for your phone…"
        guard WebSocketServer.shared.sendPowerProtocol(type: "phoneHotspotControl", data: [
            "id": request.id, "action": action.rawValue
        ]) else {
            finishRequest()
            message = "Couldn't send the request. Reconnect your phone and try again."
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.request?.id == request.id else { return }
            self.finishRequest()
            self.message = "Your phone did not confirm the hotspot state. Refresh or check Hotspot settings on your phone."
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    /// Called only after the existing transport authenticates the phone.
    func handleState(_ data: [String: Any]) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.handleState(data) }
            return
        }
        guard !AppState.shared.isSyncPaused, let request,
              AppState.shared.device?.deviceId == request.deviceID,
              data["id"] as? String == request.id,
              data["action"] as? String == request.action.rawValue,
              let status = data["status"] as? String,
              Self.validStatuses.contains(status) else { return }
        state = State(
            status: status,
            apiSupported: data["apiSupported"] as? Bool,
            writeSettingsGranted: data["writeSettingsGranted"] as? Bool,
            dataSaverEnabled: data["dataSaverEnabled"] as? Bool,
            hotspotEnabled: data["hotspotEnabled"] as? Bool,
            canAttemptControl: data["canAttemptControl"] as? Bool == true,
            errorCode: data["errorCode"] as? Int
        )
        let detail = (data["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        message = detail.flatMap { $0.isEmpty ? nil : String($0.prefix(1_024)) }
        if status != "requesting" {
            finishRequest(succeeded: ["enabled", "disabled", "ready"].contains(status) ? state?.hotspotEnabled : nil)
        }
    }

    private static let validStatuses: Set<String> = [
        "ready", "enabled", "disabled", "requesting", "permissionRequired",
        "dataSaverEnabled", "unsupported", "failed", "unknown", "busy"
    ]

    private func connectionDidChange() {
        let appState = AppState.shared
        let currentID = appState.device?.deviceId
        if appState.isSyncPaused || currentID == nil || currentID != targetID { reset() }
        targetID = currentID
    }

    private func finishRequest(succeeded: Bool? = nil) {
        timeout?.cancel()
        timeout = nil
        request = nil
        pendingAction = nil
        let completion = requestCompletion
        requestCompletion = nil
        completion?(succeeded)
    }

    private func reset() {
        finishRequest()
        state = nil
        message = nil
    }
}
