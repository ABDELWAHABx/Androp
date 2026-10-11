//
//  MacAppLaunchManager.swift
//  airsync-mac
//

import AppKit
import Foundation

/// Responsible for launching the user-configured Mac app or web URL
/// when a mirrored Android notification is clicked.
struct MacAppLaunchManager {

    /// Open what a click on a mirrored notification should show: the exact content when
    /// the phone sent a link for it, otherwise the configured target for the package.
    /// - Returns: `true` if something was opened or requested from the phone.
    @discardableResult
    static func open(package: String, nid: String? = nil, link: String? = nil, canOpenOnPhone: Bool = false) -> Bool {
        let target = configuredTarget(for: package)
        let policyTarget: NotificationOpenPolicy.Target
        switch target {
        case nil: policyTarget = .none
        case .disabled: policyTarget = .disabled
        case .macApp: policyTarget = .macApp
        case .webURL(let urlString): policyTarget = .web(urlString)
        }
        let destination = NotificationOpenPolicy.clickDestination(
            link: link,
            canOpenOnPhone: canOpenOnPhone && nid != nil,
            target: policyTarget,
            openOnPhoneWithoutLink: AppState.shared.openNotificationOnPhoneWithoutLink
        )
        switch destination {
        case .link(let url):
            NSWorkspace.shared.open(url)
            return true
        case .phone:
            guard let nid else { return false }
            openOnPhone(nid: nid)
            return true
        case .launchTarget:
            guard let target else { return false }
            return launch(target: target, package: package)
        case .nothing:
            return false
        }
    }

    /// Ask the phone to fire the notification's own tap intent, opening the exact content there.
    static func openOnPhone(nid: String) {
        WebSocketServer.shared.sendNotificationAction(id: nid, name: NotificationOpenPolicy.openOnPhoneAction)
    }

    /// User-saved preference first (it overrides defaults), then the pre-configured default.
    private static func configuredTarget(for package: String) -> MacAppLaunchPreference.LaunchTarget? {
        if let pref = AppState.shared.notificationLaunchPreferences[package] {
            return pref.target
        }
        if let entry = NotificationLaunchDefaults.findDefault(for: package) {
            return NotificationLaunchDefaults.resolveTarget(for: entry)
        }
        return nil
    }

    private static func launch(target: MacAppLaunchPreference.LaunchTarget, package: String) -> Bool {
        switch target {
        case .macApp(let bundleID, _):
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                print("[MacAppLaunchManager] App '\(bundleID)' not found — may have been uninstalled.")
                return false
            }
            NSWorkspace.shared.openApplication(at: appURL, configuration: .init()) { _, error in
                if let error = error {
                    print("[MacAppLaunchManager] Failed to open '\(bundleID)': \(error)")
                }
            }
            return true

        case .webURL(var urlString):
            // Auto-prepend https:// if no scheme present
            if !urlString.lowercased().hasPrefix("http://") && !urlString.lowercased().hasPrefix("https://") {
                urlString = "https://\(urlString)"
            }
            guard let url = URL(string: urlString),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                print("[MacAppLaunchManager] Invalid URL '\(urlString)' for package '\(package)'.")
                return false
            }
            NSWorkspace.shared.open(url)
            return true

        case .disabled:
            return false
        }
    }
}
