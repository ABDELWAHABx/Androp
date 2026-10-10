import SwiftUI
import UserNotifications

struct PhoneExtrasSettingsView: View {
    @ObservedObject private var battery = LowBatteryAlertManager.shared
    @ObservedObject private var floating = FloatingPhoneWidgetManager.shared
    @ObservedObject private var widget = WidgetDataManager.shared

    var body: some View {
        SettingsHeaderView(title: "Phone battery alerts & widgets", icon: "battery.25percent")
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Alert when phone battery is low", isOn: Binding(get: { battery.enabled }, set: battery.setEnabled))
                .toggleStyle(.switch)
            HStack {
                Text("Alert at")
                Picker("Battery threshold", selection: Binding(get: { battery.threshold }, set: battery.setThreshold)) {
                    ForEach([5, 10, 15, 20, 25, 30, 40, 50], id: \.self) { value in Text("\(value)%").tag(value) }
                }
                .labelsHidden().frame(width: 85)
                Spacer()
                Toggle("Sound", isOn: Binding(get: { battery.soundEnabled }, set: battery.setSoundEnabled))
                    .toggleStyle(.switch)
            }
            .disabled(!battery.enabled)
            Text("One alert per low-battery cycle while connected. Charging or recovery five points above the threshold resets it. Pause stops monitoring. macOS notification and Focus settings apply.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if battery.enabled && !battery.permissionGranted {
                HStack {
                    Text("Allow androp notifications to receive battery alerts.").font(.caption)
                    Spacer()
                    Button("Notification settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") { NSWorkspace.shared.open(url) }
                    }
                }
            }
            HStack {
                Button("Send test alert", action: battery.sendTest).disabled(!battery.enabled || !battery.permissionGranted)
                if let error = battery.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
            }
            Divider()
            Toggle("Floating phone widget", isOn: Binding(get: { floating.enabled }, set: floating.setEnabled))
                .toggleStyle(.switch)
            Text("A small live phone-status window that works while androp is running, including private ad-hoc builds. Drag its title bar to position it; closing it turns it off.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label(widget.nativeSharingAvailable ? "Native widget data sharing is available" : "Native widget sharing unavailable in this build",
                  systemImage: widget.nativeSharingAvailable ? "checkmark.circle" : "info.circle")
                .font(.caption)
            Text(widget.nativeSharingAvailable
                 ? "To add the native widget, right-click your desktop, choose Edit Widgets, and search for androp. WidgetKit controls refresh timing."
                 : "Native desktop/Notification Center widgets need a working signed App Group. Use the floating widget here, or configure app and widget signing with a matching App Group in Xcode.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .glassBoxIfAvailable(radius: 18)
        .onAppear { battery.refreshAuthorization(); widget.refreshAvailability() }
    }
}
