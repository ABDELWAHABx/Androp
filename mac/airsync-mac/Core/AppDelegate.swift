//
//  AppDelegate.swift
//  AirSync
//
//  Created by Sameera Sandakelum on 2025-08-07.
//
import SwiftUI
import Cocoa
import Foundation


final class AppDelegate: NSObject, NSApplicationDelegate {
    var mainWindow: NSWindow?

    // Access the single shared AppDelegate instance
    static var shared: AppDelegate? { NSApp.delegate as? AppDelegate }

    private var menuBarManager: MenuBarManager?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var resumeAfterSleep = false

    func applicationWillTerminate(_ notification: Foundation.Notification) {
        if LifecycleSelfTest.isRequested {
            LifecycleSelfTest.cleanUp()
            return
        }
        MacPowerManager.shared.stop()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        let wasPaused = AppState.shared.isSyncPaused && !resumeAfterSleep
        AppState.shared.setSyncPaused(true)
        // Termination is not an explicit user pause. Preserve the launch preference.
        UserDefaults.standard.set(wasPaused, forKey: "isSyncPaused")
        WebSocketServer.shared.stop()
    }

    func applicationDidFinishLaunching(_ notification: Foundation.Notification) {
        if LifecycleSelfTest.isRequested {
            LifecycleSelfTest.run()
            return
        }
        CrashManager.shared.install()
        CrashManager.shared.checkAndNotify(mode: AppState.shared.crashReportingMode)

        // Dock icon visibility is now controlled by AppState.hideDockIcon
        AppState.shared.updateDockIconVisibility()
        
        // Initialize Menu Bar Manager
        menuBarManager = MenuBarManager.shared

        // Initialize Quick Share; a persisted pause must never start advertising.
        _ = QuickShareManager.shared
        if AppState.shared.isSyncPaused { QuickShareManager.shared.suspendService() }
        MacPowerManager.shared.start()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.resumeAfterSleep = !AppState.shared.isSyncPaused
            AppState.shared.setSyncPaused(true)
            // Automatic sleep suspension is temporary, including if the app quits asleep.
            if self.resumeAfterSleep { UserDefaults.standard.set(false, forKey: "isSyncPaused") }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.resumeAfterSleep else { return }
            self.resumeAfterSleep = false
            AppState.shared.setSyncPaused(false)
        })

        // Register all app shortcuts' global (KeyboardShortcuts/Carbon) handlers, enabled per
        // the user's chosen scope. Carbon hotkey registration — unlike an NSEvent global
        // monitor — doesn't require Accessibility permission.
        ShortcutManager.registerIfNeeded()

        // Require holding Cmd+Q instead of a single press to quit
        QuitHoldManager.registerIfNeeded()

        // Register Services Provider
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if !urls.isEmpty, !AppState.shared.isSyncPaused {
            QuickShareManager.shared.transferURLs = urls
            QuickShareManager.shared.startDiscovery(autoTargetName: nil)
            AppState.shared.showingQuickShareTransfer = true
        }
    }

    @objc func handleServices(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard !AppState.shared.isSyncPaused else { return }
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            QuickShareManager.shared.transferURLs = urls
            QuickShareManager.shared.startDiscovery(autoTargetName: nil)
            AppState.shared.showingQuickShareTransfer = true
        }
    }

    // Configure and retain main window when captured
    func configureMainWindowIfNeeded(_ window: NSWindow) {
        if mainWindow == nil || mainWindow !== window {
            mainWindow = window
            window.delegate = self
        }
        window.isReleasedWhenClosed = false
        window.isReleasedWhenClosed = false
    }




    // Public helper to bring the main window to the current Space and focus it
    func showAndActivateMainWindow() {
        guard let window = mainWindow else { return }

        if !AppState.shared.hideDockIcon {
            NSApp.setActivationPolicy(.regular)
        }

        window.collectionBehavior.insert(.moveToActiveSpace)
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak window] in
            guard let w = window else { return }
            w.collectionBehavior.insert(.moveToActiveSpace)
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Foundation.Notification) {
        if let window = (notification as NSNotification).object as? NSWindow,
           window === mainWindow {
            DispatchQueue.main.async {
                if AppState.shared.hideDockIcon {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    func windowDidBecomeMain(_ notification: Foundation.Notification) {
        if let window = (notification as NSNotification).object as? NSWindow,
           window === mainWindow {
            if !AppState.shared.hideDockIcon {
                NSApp.setActivationPolicy(.regular)
            }
        }
    }
}


