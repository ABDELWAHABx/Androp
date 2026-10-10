import AppKit
import Combine
import SwiftUI

/// In-app alternative to WidgetKit for builds without a usable App Group.
final class FloatingPhoneWidgetManager: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = FloatingPhoneWidgetManager()
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "floatingPhoneWidgetEnabled")
    private var panel: NSPanel?
    private var screenObserver: AnyCancellable?

    private override init() {
        super.init()
        screenObserver = NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.enabled else { return }
                self.keepWidgetOnScreen()
            }
    }

    func restoreIfEnabled() { if enabled { show() } }

    func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: "floatingPhoneWidgetEnabled")
        if value { show() } else { panel?.orderOut(nil) }
    }

    func show() {
        if panel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 172),
                                 styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            window.title = "androp phone widget"
            window.isReleasedWhenClosed = false
            window.isFloatingPanel = true
            window.level = .floating
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = NSHostingView(rootView: FloatingPhoneWidgetView())
            window.delegate = self
            window.setFrameAutosaveName("androp.phone.widget")
            if !window.setFrameUsingName("androp.phone.widget") { window.center() }
            panel = window
        }
        keepWidgetOnScreen()
        panel?.orderFrontRegardless()
    }

    private func keepWidgetOnScreen() {
        guard let panel else { return }
        let screens = NSScreen.screens
        let preferred = NSScreen.main ?? screens.first
        let orderedScreens = [preferred].compactMap { $0 } + screens.filter { $0 !== preferred }
        let frame = FloatingWidgetPlacement.frame(panel.frame, visibleScreens: orderedScreens.map(\.visibleFrame))
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    func windowWillClose(_ notification: Foundation.Notification) { setEnabled(false) }
}

private struct FloatingPhoneWidgetView: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "iphone")
                Text(state.device?.name ?? "Your phone").font(.headline).lineLimit(1)
                Spacer()
            }
            if state.isSyncPaused {
                Label("Paused · background work stopped", systemImage: "pause.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let device = state.device {
                Label(device.isBLE ? "Bluetooth connected" : "Network connected",
                      systemImage: device.isBLE ? "antenna.radiowaves.left.and.right" : "wifi")
                    .font(.caption).foregroundStyle(.secondary)
                if let status = state.status, status.battery.isReported != false, (0...100).contains(status.battery.level) {
                    HStack {
                        Image(systemName: status.battery.isCharging ? "battery.100percent.bolt" : "battery.50percent")
                        Text("\(status.battery.level)%\(status.battery.isCharging ? " · Charging" : "")")
                            .font(.title3.monospacedDigit())
                    }
                    if let music = status.music, music.isPlaying, !music.title.isEmpty {
                        Text(music.title).font(.caption).lineLimit(1)
                    }
                } else {
                    Text("Waiting for phone status").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Phone offline · open androp on your phone to reconnect")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(state.isSyncPaused ? "Resume sync" : "Pause sync") { state.setSyncPaused(!state.isSyncPaused) }
                .controlSize(.small)
        }
        .padding(16)
        .frame(width: 300, height: 172, alignment: .topLeading)
        .background(.regularMaterial)
    }
}
