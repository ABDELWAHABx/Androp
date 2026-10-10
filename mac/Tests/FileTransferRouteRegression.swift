import Foundation

@main
struct FileTransferRouteRegression {
    static func main() {
        func maySend(id: String? = "paired-phone", token: String? = "original-pairing",
                     wifi: Bool = true, paused: Bool = false) -> Bool {
            FileTransferRoutePolicy.maySend(preparedDeviceID: "paired-phone", currentDeviceID: id,
                preparedPairingToken: "original-pairing", currentPairingToken: token,
                networkConnected: wifi, paused: paused)
        }
        precondition(maySend()) // Same authenticated identity after BLE → Wi-Fi handoff.
        precondition(!maySend(wifi: false)) // Never stream a file over BLE.
        precondition(!maySend(id: nil)) // Temporary handoff disconnect retains selection, not permission to send.
        precondition(!maySend(id: "different-phone"))
        precondition(!maySend(token: "new-pairing")) // Same device ID cannot reuse an old send approval after re-pairing.
        precondition(!maySend(token: nil))
        precondition(!maySend(paused: true))
        precondition(FileTransferRoutePolicy.maySend(preparedDeviceID: "network-only", currentDeviceID: "network-only",
            preparedPairingToken: nil, currentPairingToken: nil, networkConnected: true, paused: false))
        precondition(!FileTransferRoutePolicy.maySend(preparedDeviceID: nil, currentDeviceID: nil,
            preparedPairingToken: nil, currentPairingToken: nil, networkConnected: true, paused: false))
        precondition(!FileTransferRoutePolicy.maySend(preparedDeviceID: "", currentDeviceID: "",
            preparedPairingToken: nil, currentPairingToken: nil, networkConnected: true, paused: false))
        print("File transfer route policy: 10 checks passed")
    }
}
