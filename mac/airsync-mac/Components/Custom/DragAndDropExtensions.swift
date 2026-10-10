//
//  DragAndDropExtensions.swift
//  airsync-mac
//
//  Created by Sameera Sandakelum on 2025-10-22.
//

import SwiftUI
import UniformTypeIdentifiers

// Custom UTType for AndroidApp
extension UTType {
    static let androidApp = UTType(exportedAs: "app.androp.mac.android-app")
}

// Extension to make AndroidApp draggable
extension View {
    func draggableApp(_ app: AndroidApp, preview: @escaping () -> some View) -> some View {
        self.onDrag {
            let provider = NSItemProvider()
            
            // Encode the app to JSON
            if let jsonData = try? JSONEncoder().encode(app) {
                provider.registerDataRepresentation(
                    forTypeIdentifier: UTType.androidApp.identifier,
                    visibility: .all
                ) { completion in
                    completion(jsonData, nil)
                    return nil
                }
            }
            
            return provider
        }
    }
}

/// A small, native Finder drop target shared by the phone panel and menu bar.
@MainActor
struct ConnectedFileDropZone: View {
    var compact: Bool = true
    @ObservedObject private var manager = QuickShareManager.shared
    @ObservedObject private var appState = AppState.shared
    @State private var targeted = false

    var body: some View {
        Button { manager.chooseFilesForConnectedDevice() } label: {
            HStack(spacing: 8) {
                Image(systemName: targeted ? "tray.and.arrow.down.fill" : "doc.badge.arrow.up")
                    .font(.system(size: compact ? 17 : 24, weight: .medium))
                VStack(alignment: .leading, spacing: 2) {
                    Text(targeted ? "Drop to send" : "Drop files here")
                        .font(compact ? .caption : .headline)
                        .fontWeight(.medium)
                    if !compact {
                        Text(appState.device.map { "Send to \($0.name)" } ?? "Connect your Android phone first")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(compact ? 10 : 16)
            .frame(maxWidth: .infinity, minHeight: compact ? 42 : 74)
            .background(targeted ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                targeted ? Color.accentColor : Color.secondary.opacity(0.35),
                style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: [4, 3])))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("Drop one or more Finder files, or click to choose files. Transfers use your connected phone over Wi-Fi.")
        .accessibilityLabel("Send files to your Android phone")
        .accessibilityHint("Choose files or drop files from Finder, then review and send.")
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            guard !providers.isEmpty else { return false }
            let group = DispatchGroup()
            let lock = NSLock()
            var urls: [URL] = []
            var failed = false
            for provider in providers {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    let url: URL?
                    if let value = item as? URL { url = value }
                    else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else if let string = item as? String { url = URL(string: string) }
                    else { url = nil }
                    lock.lock()
                    if let url, error == nil { urls.append(url) } else { failed = true }
                    lock.unlock()
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                if failed { manager.presentFileError("Couldn't read one of the dropped items. Choose the files again in Finder.") }
                else { manager.prepareFilesForConnectedDevice(urls) }
            }
            return true
        }
        if let message = manager.dropFeedback {
            Text(message).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
