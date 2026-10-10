//
//  PhoneInfoWidget.swift
//  AirSyncWidget
//
//  Created by Sameera Sandakelum on 2026-09-15.
//

import WidgetKit
import SwiftUI
import AppKit
import ImageIO

struct PhoneInfoEntry: TimelineEntry {
    let date: Date
    let deviceName: String
    let batteryLevel: Int
    let isCharging: Bool
    let isPaired: Bool
    let wallpaperImageData: Data?
    let isLocalNetwork: Bool
    let isBLEConnected: Bool
    let isADBConnected: Bool
    let adbMode: String
    let isMusicPlaying: Bool
    let musicTitle: String
    let musicArtist: String
    let musicAlbumArtData: Data?
    var batteryKnown: Bool = true
    var statusMessage: String = ""
    var lastUpdated: Date? = nil
}

struct PhoneInfoWidgetEntryView: View {
    var entry: PhoneInfoEntry
    @Environment(\.widgetFamily) var widgetFamily
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.widgetContentMargins) private var contentMargins

    var body: some View {
        if entry.isPaired {
            switch widgetFamily {
            case .systemLarge:
                largeLayout
            case .systemMedium:
                mediumLayout
            default:
                smallLayout
            }
        } else {
            disconnectedLayout
        }
    }

    @ViewBuilder
    private var glassBackground: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(in: .rect(cornerRadius: 0))
        } else {
            Color.clear.background(.ultraThinMaterial)
        }
    }

    private var smallLayout: some View {
        VStack(spacing: 8) {
            PhoneDeviceView(wallpaperImageData: entry.wallpaperImageData)
                .frame(maxHeight: 100)

            VStack(spacing: 2) {
                Text(entry.deviceName)
                    .font(.system(.caption, design: .rounded))
                    .lineLimit(1)
                    .foregroundColor(.primary)

                if entry.batteryKnown {
                    BatteryIconView(level: entry.batteryLevel, isCharging: entry.isCharging)
                }
            }
            .widgetAccentable()
        }
        .padding(12)
        .padding(contentMargins)
        .containerBackground(for: .widget) { glassBackground }
    }

    private var mediumLayout: some View {
        HStack(spacing: 0) {
            PhoneDeviceView(wallpaperImageData: entry.wallpaperImageData)
                .frame(maxHeight: 110)
                .padding(.trailing, 20)

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                Text(entry.deviceName)
                    .font(.system(.headline, design: .rounded))
                    .lineLimit(2)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.trailing)
                    .widgetAccentable()

                if entry.isMusicPlaying {
                    statusIconsRow
                    Spacer()
                    mediaPlayerRow
                } else {
                    Spacer()
                    statusIconsRow
                }
            }
        }
        .padding(16)
        .padding(contentMargins)
        .containerBackground(for: .widget) { glassBackground }
    }

    private var largeLayout: some View {
        ZStack {
            if let nsImage = largeBackgroundNSImage {
                GeometryReader { geo in
                    ZStack {
                        largeBackgroundImage(nsImage)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()

                        blurredBackgroundLayer(nsImage, size: geo.size, radius: 6, fadeStart: 0.35)
                        blurredBackgroundLayer(nsImage, size: geo.size, radius: 16, fadeStart: 0.55)
                        blurredBackgroundLayer(nsImage, size: geo.size, radius: 32, fadeStart: 0.75)
                    }
                }

                 LinearGradient(
                     colors: [.clear, .black.opacity(0.55)],
                     startPoint: .center,
                     endPoint: .bottom
                 )
                 .ignoresSafeArea()
            } else {
                LinearGradient(colors: [.indigo, .blue.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }

            VStack(spacing: 0) {
                largeStatusIconsRow

                Spacer()

                if entry.isMusicPlaying {
                    VStack(spacing: 4) {
                        Text(entry.musicTitle)
                            .font(.title3)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .foregroundColor(.white)
                        Text(entry.musicArtist)
                            .font(.subheadline)
                            .lineLimit(1)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .multilineTextAlignment(.center)

                    Spacer()
                }

                Text(entry.deviceName)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(contentMargins)
        }
        .containerBackground(for: .widget) { glassBackground }
    }

    private var largeStatusIconsRow: some View {
        HStack(spacing: 6) {
            if entry.isLocalNetwork {
                Image(systemName: "wifi")
                    .font(.system(size: 10))
            }
            if entry.isADBConnected {
                Image(systemName: entry.adbMode == "wired" ? "cable.connector" : "iphone.gen3.crop.circle")
                    .font(.system(size: 10))
            }
            if entry.isBLEConnected {
                Image(systemName: "bluetooth")
                    .font(.system(size: 10))
            }
            if entry.batteryKnown {
                BatteryIconView(level: entry.batteryLevel, isCharging: entry.isCharging)
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            .black.opacity(0.3)
//            .ultraThinMaterial
            , in: Capsule())
//        .widgetAccentable()
    }

    private var largeBackgroundNSImage: NSImage? {
        if entry.isMusicPlaying, let artData = entry.musicAlbumArtData, let nsImage = NSImage(data: artData) {
            return nsImage
        }
        if let wallpaperData = entry.wallpaperImageData, let nsImage = NSImage(data: wallpaperData) {
            return nsImage
        }
        return nil
    }

    private func blurredBackgroundLayer(
        _ nsImage: NSImage,
        size: CGSize,
        radius: CGFloat,
        fadeStart: CGFloat
    ) -> some View {
        largeBackgroundImage(nsImage)
            .frame(width: size.width, height: size.height)
            .blur(radius: radius)
            .scaleEffect(1.1)
            .clipped()
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: fadeStart),
                        .init(color: .white, location: min(fadeStart + 0.25, 1.0))
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }

    @ViewBuilder
    private func largeBackgroundImage(_ nsImage: NSImage) -> some View {
        if #available(macOS 15.0, *), renderingMode == .accented {
            Image(nsImage: nsImage)
                .resizable()
                .widgetAccentedRenderingMode(.accentedDesaturated)
                .scaledToFill()
        } else {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
        }
    }

    private var statusIconsRow: some View {
        HStack(spacing: 6) {
            if entry.isLocalNetwork {
                Image(systemName: "wifi")
                    .font(.system(size: 10))
            }
            if entry.isADBConnected {
                Image(systemName: entry.adbMode == "wired" ? "cable.connector" : "iphone.gen3.crop.circle")
                    .font(.system(size: 10))
            }
            if entry.isBLEConnected {
                Image(systemName: "bluetooth")
                    .font(.system(size: 10))
            }
            if entry.batteryKnown {
                BatteryIconView(level: entry.batteryLevel, isCharging: entry.isCharging)
            }
        }
        .foregroundColor(.secondary)
        .widgetAccentable()
    }

    private var mediaPlayerRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.musicTitle)
                    .font(.system(.caption, design: .rounded))
                    .lineLimit(1)
                    .foregroundColor(.primary)
                Text(entry.musicArtist)
                    .font(.system(.caption2, design: .rounded))
                    .lineLimit(1)
                    .foregroundColor(.secondary)
            }
            .widgetAccentable()

            if let artData = entry.musicAlbumArtData, let nsImage = NSImage(data: artData) {
                renderedAlbumArt(nsImage)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 48, height: 48)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                    )
                    .widgetAccentable()
            }
        }
    }

    @ViewBuilder
    private func renderedAlbumArt(_ nsImage: NSImage) -> some View {
        if #available(macOS 15.0, *), renderingMode == .accented {
            Image(nsImage: nsImage)
                .resizable()
                .widgetAccentedRenderingMode(.accentedDesaturated)
                .scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var disconnectedLayout: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                PhoneDeviceView(wallpaperImageData: entry.wallpaperImageData)
                    .frame(maxHeight: 100)
                    .grayscale(1)
                    .opacity(0.6)

                Image(systemName: "iphone.slash")
                    .font(.system(size: 20))
                    .foregroundColor(.gray)
                    .padding(4)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                    .offset(x: 8, y: 8)
                    .widgetAccentable()
            }

            Text(entry.deviceName)
                .font(.system(.caption, design: .rounded))
                .lineLimit(1)
                .foregroundColor(.primary)
                .widgetAccentable()
            Text(entry.statusMessage.isEmpty ? "Phone offline" : entry.statusMessage)
                .font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineLimit(3)
        }
        .padding(12)
        .padding(contentMargins)
        .containerBackground(for: .widget) { glassBackground }
    }
}

struct PhoneInfoWidget: Widget {
    let kind: String = "PhoneInfoWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PhoneInfoProvider()) { entry in
            PhoneInfoWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Phone Info")
        .description("Display your connected phone's battery and status")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct PhoneInfoProvider: TimelineProvider {
    private func getSharedData() -> PhoneInfoEntry {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: APP_GROUP_IDENTIFIER) else {
            var empty = placeholderEntry()
            empty.statusMessage = "Use the floating widget in androp settings, or configure App Group signing."
            return empty
        }
        let file = group.appendingPathComponent("phone-widget-snapshot.json")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 5_000_000,
              let data = try? Data(contentsOf: file),
              let shared = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            var empty = placeholderEntry()
            empty.statusMessage = "Open androp to publish phone status."
            return empty
        }
        func image(_ key: String, limit: Int) -> Data? {
            guard let value = shared[key] as? String, !value.isEmpty, value.utf8.count <= limit else { return nil }
            guard let data = Data(base64Encoded: value),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 4096, height <= 4096,
                  width * height <= 8_000_000 else { return nil }
            return data
        }
        let updated = (shared["updatedAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let paused = shared["isPaused"] as? Bool ?? false
        let connected = !paused && (shared["isPaired"] as? Bool ?? false)
        var entry = PhoneInfoEntry(
            date: Date(),
            deviceName: String((shared["deviceName"] as? String ?? "Your phone").prefix(200)),
            batteryLevel: min(100, max(0, shared["batteryLevel"] as? Int ?? 0)),
            isCharging: shared["isCharging"] as? Bool ?? false,
            isPaired: connected,
            wallpaperImageData: image("wallpaperBase64", limit: 3_000_000),
            isLocalNetwork: connected && (shared["isLocalNetwork"] as? Bool ?? false),
            isBLEConnected: connected && (shared["isBLEConnected"] as? Bool ?? false),
            isADBConnected: connected && (shared["isADBConnected"] as? Bool ?? false),
            adbMode: shared["adbMode"] as? String ?? "wireless",
            isMusicPlaying: connected && (shared["isMusicPlaying"] as? Bool ?? false),
            musicTitle: String((shared["musicTitle"] as? String ?? "").prefix(500)),
            musicArtist: String((shared["musicArtist"] as? String ?? "").prefix(500)),
            musicAlbumArtData: image("musicAlbumArt", limit: 1_000_000))
        entry.batteryKnown = shared["batteryKnown"] as? Bool ?? false
        entry.lastUpdated = updated
        entry.statusMessage = paused ? "Paused" : "Phone offline"
        // A cached snapshot is not evidence of a live connection after the app stops.
        if connected, let updated, Date().timeIntervalSince(updated) > 15 * 60 {
            entry.isPaired = false
            entry.statusMessage = "Last known status · open androp to refresh"
        }
        return entry
    }

    private func placeholderEntry() -> PhoneInfoEntry {
        PhoneInfoEntry(date: Date(), deviceName: "androp", batteryLevel: 0,
                       isCharging: false, isPaired: false, wallpaperImageData: nil,
                       isLocalNetwork: false, isBLEConnected: false, isADBConnected: false,
                       adbMode: "wireless", isMusicPlaying: false, musicTitle: "",
                       musicArtist: "", musicAlbumArtData: nil, batteryKnown: false)
    }

    func placeholder(in context: Context) -> PhoneInfoEntry {
        PhoneInfoEntry(
            date: Date(),
            deviceName: "Loading...",
            batteryLevel: 0,
            isCharging: false,
            isPaired: false,
            wallpaperImageData: nil,
            isLocalNetwork: false,
            isBLEConnected: false,
            isADBConnected: false,
            adbMode: "wireless",
            isMusicPlaying: false,
            musicTitle: "",
            musicArtist: "",
            musicAlbumArtData: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (PhoneInfoEntry) -> ()) {
        completion(getSharedData())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PhoneInfoEntry>) -> ()) {
        let currentDate = Date()
        let refreshDate = currentDate.addingTimeInterval(15 * 60)

        let entry = getSharedData()
        let timeline = Timeline(entries: [entry], policy: .after(refreshDate))
        completion(timeline)
    }
}

#Preview("Small - Connected", as: .systemSmall) {
    PhoneInfoWidget()
} timeline: {
    PhoneInfoEntry(
        date: .now,
        deviceName: "Pixel 8",
        batteryLevel: 75,
        isCharging: false,
        isPaired: true,
        wallpaperImageData: nil,
        isLocalNetwork: false,
        isBLEConnected: false,
        isADBConnected: false,
        adbMode: "wireless",
        isMusicPlaying: false,
        musicTitle: "",
        musicArtist: "",
        musicAlbumArtData: nil
    )
}

#Preview("Small - Low Battery", as: .systemSmall) {
    PhoneInfoWidget()
} timeline: {
    PhoneInfoEntry(
        date: .now,
        deviceName: "Galaxy S24",
        batteryLevel: 15,
        isCharging: false,
        isPaired: true,
        wallpaperImageData: nil,
        isLocalNetwork: false,
        isBLEConnected: false,
        isADBConnected: false,
        adbMode: "wireless",
        isMusicPlaying: false,
        musicTitle: "",
        musicArtist: "",
        musicAlbumArtData: nil
    )
}

#Preview("Small - Charging", as: .systemSmall) {
    PhoneInfoWidget()
} timeline: {
    PhoneInfoEntry(
        date: .now,
        deviceName: "iPhone 15",
        batteryLevel: 45,
        isCharging: true,
        isPaired: true,
        wallpaperImageData: nil,
        isLocalNetwork: false,
        isBLEConnected: false,
        isADBConnected: false,
        adbMode: "wireless",
        isMusicPlaying: false,
        musicTitle: "",
        musicArtist: "",
        musicAlbumArtData: nil
    )
}

#Preview("Medium - Connected", as: .systemMedium) {
    PhoneInfoWidget()
} timeline: {
    PhoneInfoEntry(
        date: .now,
        deviceName: "Pixel 8 Pro",
        batteryLevel: 82,
        isCharging: true,
        isPaired: true,
        wallpaperImageData: nil,
        isLocalNetwork: true,
        isBLEConnected: false,
        isADBConnected: false,
        adbMode: "wireless",
        isMusicPlaying: false,
        musicTitle: "",
        musicArtist: "",
        musicAlbumArtData: nil
    )
}

#Preview("Medium - Playing Music", as: .systemMedium) {
    PhoneInfoWidget()
} timeline: {
    PhoneInfoEntry(
        date: .now,
        deviceName: "Pixel 8 Pro",
        batteryLevel: 82,
        isCharging: false,
        isPaired: true,
        wallpaperImageData: nil,
        isLocalNetwork: true,
        isBLEConnected: false,
        isADBConnected: true,
        adbMode: "wireless",
        isMusicPlaying: true,
        musicTitle: "Blinding Lights",
        musicArtist: "The Weeknd",
        musicAlbumArtData: nil
    )
}

#Preview("Large - Connected", as: .systemLarge) {
    PhoneInfoWidget()
} timeline: {
    PhoneInfoEntry(
        date: .now,
        deviceName: "Pixel 8 Pro",
        batteryLevel: 82,
        isCharging: true,
        isPaired: true,
        wallpaperImageData: nil,
        isLocalNetwork: true,
        isBLEConnected: false,
        isADBConnected: false,
        adbMode: "wireless",
        isMusicPlaying: false,
        musicTitle: "",
        musicArtist: "",
        musicAlbumArtData: nil
    )
}

#Preview("Large - Playing Music", as: .systemLarge) {
    PhoneInfoWidget()
} timeline: {
    PhoneInfoEntry(
        date: .now,
        deviceName: "Pixel 8 Pro",
        batteryLevel: 82,
        isCharging: false,
        isPaired: true,
        wallpaperImageData: nil,
        isLocalNetwork: true,
        isBLEConnected: false,
        isADBConnected: true,
        adbMode: "wireless",
        isMusicPlaying: true,
        musicTitle: "Blinding Lights",
        musicArtist: "The Weeknd",
        musicAlbumArtData: nil
    )
}

#Preview("Disconnected", as: .systemSmall) {
    PhoneInfoWidget()
} timeline: {
    PhoneInfoEntry(
        date: .now,
        deviceName: "Unknown",
        batteryLevel: 0,
        isCharging: false,
        isPaired: false,
        wallpaperImageData: nil,
        isLocalNetwork: false,
        isBLEConnected: false,
        isADBConnected: false,
        adbMode: "wireless",
        isMusicPlaying: false,
        musicTitle: "",
        musicArtist: "",
        musicAlbumArtData: nil
    )
}
