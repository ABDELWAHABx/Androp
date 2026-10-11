//
//  RemotePermissionView.swift
//  airsync-mac
//
//  Created by AirSync on 2026-01-10.
//

import SwiftUI
import Combine

struct RemotePermissionView: View {
    @Environment(\.dismiss) var dismiss
    @State private var isTrusted: Bool = false
    @State private var timer: AnyCancellable?
    @State private var resetting = false
    @State private var resetNote: String?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "keyboard.badge.eye")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)
                .padding(.bottom, 10)
            
            Text("Remote control permission")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("To allow androp to simulate keystrokes (arrows, media keys) and control volume, you need to grant Accessibility permissions in System Settings.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal)

            GlassButtonView(
                label:  !isTrusted ? "Open System Settings" : "You're all set!",
                systemImage: "accessibility",
                primary: true,
            ){
                if isTrusted {
                    dismiss()
                } else {
                    MacRemoteManager.shared.requestAccessibilityPermission()
                    MacRemoteManager.shared.openAccessibilitySettings()
                }
            }

            if !isTrusted {
                // Each private build is ad-hoc signed, so macOS treats an update as a new app:
                // the old switch can stay on without applying to this version.
                VStack(spacing: 8) {
                    Text("Already switched on for androp? This version isn't recognised yet. Reset, then switch androp on again.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(resetting ? "Resetting…" : "Reset permission") {
                        resetting = true
                        MacRemoteManager.shared.resetAccessibilityPermission { reset in
                            resetting = false
                            resetNote = reset ? "Now switch androp on in Accessibility."
                                : "Remove androp from the Accessibility list with −, then add it again."
                            MacRemoteManager.shared.openAccessibilitySettings()
                        }
                    }
                    .disabled(resetting)
                    if let resetNote {
                        Text(resetNote).font(.caption).foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(30)
        .frame(width: 450)
        .onAppear {
            checkPermission()
            timer = Timer.publish(every: 2, on: .main, in: .default)
                .autoconnect()
                .sink { _ in checkPermission() }
        }
        .onDisappear {
            timer?.cancel()
            timer = nil
        }
    }
    
    private func checkPermission() {
        isTrusted = MacRemoteManager.shared.isAccessibilityTrusted()
        // Keep the phone's remote screen in step with what this window shows.
        MacRemoteManager.shared.publishTrust(force: false)
    }
}

#Preview {
    RemotePermissionView()
}
