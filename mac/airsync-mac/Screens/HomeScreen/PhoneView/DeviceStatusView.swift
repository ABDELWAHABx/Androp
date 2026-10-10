import SwiftUI
import AppKit

struct DeviceStatusView: View {
    @ObservedObject var appState = AppState.shared
    @State private var showingVolumePopover = false
    @State private var showingPlusPopover = false
    @State private var tempVolume: Double = 100
    var showMediaToggle: Bool = true
    var useGlass: Bool = true

    private var validMusic: DeviceStatus.Music? {
        guard !appState.isSyncPaused, let music = appState.status?.music else { return nil }
        return music.hasDisplayableSession ? music : nil
    }

    @ViewBuilder
    var body: some View {
        if useGlass { content.applyGlassViewIfAvailable() }
        else { content }
    }

    private var content: some View {
        VStack(spacing: 6) {
            if let music = validMusic, showMediaToggle && !appState.isMusicCardHidden {
                MediaPlayerView(music: music)
            }
            HStack(spacing: 10) {
                let battery = appState.status?.battery
                let level = battery?.level ?? -1
                let charging = battery?.isCharging ?? false
                let validLevel = (0...100).contains(level)
                Label(validLevel ? "\(level)%" : "Battery —",
                      systemImage: batteryIcon(for: level, isCharging: charging))
                    .font(.caption)
                    .monospacedDigit()
                    .help(validLevel ? (charging ? "Phone charging · \(level)%" : "Phone battery · \(level)%") : "Phone battery not available")
                    .accessibilityLabel("Phone battery")
                    .accessibilityValue(validLevel ? "\(level) percent\(charging ? ", charging" : "")" : "Not available")
                Spacer(minLength: 0)
                if let music = validMusic, showMediaToggle {
                    Button {
                        if appState.isPlus || !appState.licenseCheck {
                            tempVolume = Double(min(100, max(0, music.volume)))
                            showingVolumePopover.toggle()
                        } else {
                            showingPlusPopover = true
                        }
                    } label: {
                        Image(systemName: volumeIcon(for: music.volume, isMuted: music.isMuted))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Phone volume")
                    .help(music.isMuted ? "Phone muted" : "Phone volume · \(music.volume)%")
                    .popover(isPresented: $showingVolumePopover, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Phone volume").font(.caption.weight(.semibold))
                            Slider(value: $tempVolume, in: 0...100, onEditingChanged: { editing in
                                if !editing && !appState.isSyncPaused {
                                    WebSocketServer.shared.setVolume(Int(tempVolume))
                                }
                            })
                            .accessibilityLabel("Phone volume")
                            .accessibilityValue("\(Int(tempVolume)) percent")
                        }
                        .padding()
                        .frame(width: 200)
                    }
                    .popover(isPresented: $showingPlusPopover, arrowEdge: .bottom) {
                        PlusFeaturePopover(message: "Control volume with androp+")
                    }
                    Button {
                        appState.isMusicCardHidden.toggle()
                    } label: {
                        Image(systemName: appState.isMusicCardHidden ? "music.note" : "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .help(appState.isMusicCardHidden ? "Show player" : "Hide player")
                    .accessibilityLabel(appState.isMusicCardHidden ? "Show player" : "Hide player")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .padding(4)
        .onChange(of: appState.isSyncPaused) { _, paused in
            if paused { showingVolumePopover = false; showingPlusPopover = false }
        }
    }

    private func batteryIcon(for level: Int, isCharging: Bool) -> String {
        if isCharging { return "battery.100.bolt" }
        switch level {
        case 0...10: return "battery.0"
        case 11...25: return "battery.25"
        case 26...50: return "battery.50"
        case 51...75: return "battery.75"
        case 76...100: return "battery.100"
        default: return "battery.0"
        }
    }

    private func volumeIcon(for volume: Int, isMuted: Bool) -> String {
        if isMuted || volume == 0 { return "speaker.slash" }
        if volume <= 25 { return "speaker.wave.1" }
        if volume <= 50 { return "speaker.wave.2" }
        return "speaker.wave.3"
    }
}

#Preview { DeviceStatusView() }
