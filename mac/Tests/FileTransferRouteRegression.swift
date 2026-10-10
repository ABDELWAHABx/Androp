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
        func mayBegin(id: String? = "paired-phone", token: String? = "original-pairing",
                      wifi: Bool = false, ble: Bool = true, paused: Bool = false) -> Bool {
            FileTransferRoutePolicy.mayBegin(preparedDeviceID: "paired-phone", currentDeviceID: id,
                preparedPairingToken: "original-pairing", currentPairingToken: token,
                networkConnected: wifi, bluetoothAuthenticated: ble, paused: paused)
        }
        precondition(mayBegin()) // BLE can establish a network, never stream bytes itself.
        precondition(!maySend(wifi: false))
        precondition(!mayBegin(ble: false)) // An advertisement is insufficient.
        precondition(mayBegin(wifi: true, ble: false)) // Wi-Fi-only pairing remains usable.
        precondition(!mayBegin(id: "different-phone"))
        precondition(!mayBegin(id: nil))
        precondition(!mayBegin(token: "new-pairing"))
        precondition(!mayBegin(token: nil))
        precondition(!mayBegin(paused: true))
        precondition(!FileTransferRoutePolicy.mayBegin(preparedDeviceID: "phone", currentDeviceID: "phone",
            preparedPairingToken: nil, currentPairingToken: nil, networkConnected: false,
            bluetoothAuthenticated: true, paused: false))
        precondition(!FileTransferRoutePolicy.mayBegin(preparedDeviceID: "phone", currentDeviceID: "phone",
            preparedPairingToken: "", currentPairingToken: "", networkConnected: false,
            bluetoothAuthenticated: true, paused: false))
        precondition(FileTransferRoutePolicy.mayBegin(preparedDeviceID: "phone", currentDeviceID: "phone",
            preparedPairingToken: nil, currentPairingToken: nil, networkConnected: true,
            bluetoothAuthenticated: false, paused: false))
        print("File transfer route policy: 22 checks passed")
    }
}
