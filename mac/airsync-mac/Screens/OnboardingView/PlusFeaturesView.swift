//
//  PlusFeaturesView.swift
//  AirSync
//
//  Created by AI Assistant on 2025-09-04.
//

import SwiftUI

struct PlusFeaturesView: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 15) {
            VStack(spacing: 4) {
                Text("Make your phone and Mac work together")
                    .font(.title)
                    .multilineTextAlignment(.center)
                
                Text("Included in this private androp build")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top)

            Text("Configure the features you want in Settings. Mirroring and call controls need Android debugging access; native widgets need matching App Group signing. The floating phone widget works while androp is running.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

                List{
                    featureRow(icon: "macbook.and.iphone", title: "Android Mirroring", description: "Mirror your Android screen and apps to your Mac with full control, wirelessly")
                    featureRow(icon: "music.note", title: "Media Controls", description: "Control music playback and volume directly from your Mac")
                    featureRow(icon: "desktopcomputer", title: "Wireless Desktop Mode", description: "Use the phone in a familiar way, with full desktop controls")
                    featureRow(icon: "phone", title: "Control calls", description: "Accept, decline, or end phone calls from your Mac (ADB)")
                    featureRow(icon: "folder", title: "File Browser & Mounting", description: "Browse, manage, and mount your Android storage directly as a local Finder drive")
                    featureRow(icon: "menubar.rectangle", title: "MenuBar Customizations", description: "Customize menu bar text style, font size, battery style, and album art layout")
                    featureRow(icon: "battery.25percent", title: "Low Battery Alerts", description: "Choose a threshold and receive one notification per low-battery cycle")
                    featureRow(icon: "widget.small.badge.plus", title: "Widgets", description: "Live floating phone status, plus native WidgetKit with App Group signing")
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 250)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(12)

            HStack(spacing: 16) {
                GlassButtonView(
                    label: "Let's begin syncing",
                    systemImage: "arrow.right.circle",
                    size: .large,
                    primary: true,
                    fixedIconSize: 16,
                    action: onNext
                )
                .transition(.identity)
            }
        }
    }

    @ViewBuilder
    func featureRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.primary)
                .frame(width: 24, height: 24)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(2)
    }
}
