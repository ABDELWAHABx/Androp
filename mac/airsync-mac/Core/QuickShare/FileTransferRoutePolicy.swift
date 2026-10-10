import Foundation

/// Retaining a selection across a network change must not retarget its files.
/// A display name or a nearby device with the same SSID is never sufficient.
nonisolated enum FileTransferRoutePolicy {
    static func maySend(preparedDeviceID: String?, currentDeviceID: String?,
                        preparedPairingToken: String?, currentPairingToken: String?,
                        networkConnected: Bool, paused: Bool) -> Bool {
        guard !paused, networkConnected,
              let preparedDeviceID, !preparedDeviceID.isEmpty,
              preparedDeviceID == currentDeviceID else { return false }
        return preparedPairingToken == currentPairingToken
    }
}
