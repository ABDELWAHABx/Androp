import Foundation
import Combine

/// Grants, over wireless debugging (or USB), everything Android only lets the user flip
/// one screen at a time: runtime permissions, notification access, the clipboard helper,
/// background running, hotspot control and Samsung's "restricted settings" block.
/// One shell session; nothing is installed on the phone.
@MainActor
final class PhonePermissionGranter: ObservableObject {
    static let shared = PhonePermissionGranter()

    enum State: Equatable { case idle, working, done, noADB, failed }
    @Published private(set) var state: State = .idle

    var adbInstalled: Bool { ADBConnector.isExecutableAvailable("adb") }

    func grantAll() {
        guard state != .working else { return }
        state = .working
        ADBConnector.shell(Self.script) { [weak self] output in
            guard let self else { return }
            if output == nil { self.state = .noADB; return }
            self.state = output?.contains(Self.doneMarker) == true ? .done : .failed
        }
    }

    private static let doneMarker = "androp-permissions-done"

    /// Each step tolerates permissions the phone's Android version does not have.
    static let script = """
    P=app.androp.android
    for p in POST_NOTIFICATIONS BLUETOOTH_CONNECT BLUETOOTH_ADVERTISE BLUETOOTH_SCAN NEARBY_WIFI_DEVICES \
    READ_PHONE_STATE READ_CALL_LOG READ_CONTACTS ANSWER_PHONE_CALLS ACCESS_LOCAL_NETWORK; do
      pm grant $P android.permission.$p >/dev/null 2>&1
    done
    for o in ACCESS_RESTRICTED_SETTINGS WRITE_SETTINGS SYSTEM_ALERT_WINDOW RUN_ANY_IN_BACKGROUND \
    RUN_IN_BACKGROUND MANAGE_EXTERNAL_STORAGE; do
      appops set $P $o allow >/dev/null 2>&1
    done
    dumpsys deviceidle whitelist +$P >/dev/null 2>&1
    cmd notification allow_listener $P/$P.service.MediaNotificationListener >/dev/null 2>&1
    A=$P/$P.service.ClipboardAccessibilityService
    C=$(settings get secure enabled_accessibility_services)
    case "$C" in
      *ClipboardAccessibilityService*) ;;
      ""|null) settings put secure enabled_accessibility_services $A ;;
      *) settings put secure enabled_accessibility_services "$C:$A" ;;
    esac
    settings put secure accessibility_enabled 1
    echo \(doneMarker)
    """
}
