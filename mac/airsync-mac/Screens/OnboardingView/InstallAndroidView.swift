import SwiftUI

struct InstallAndroidView: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "smartphone")
                .font(.system(size: 64))

            Text("Install androp on your Android device")
                .font(.title)
                .multilineTextAlignment(.center)

            Text("Use your private androp Android installer, then open the app on your phone. Keep both devices on the same network to pair them.")
                .multilineTextAlignment(.center)

            GlassButtonView(
                label: "I'm ready",
                systemImage: "apps.iphone.badge.checkmark",
                size: .extraLarge,
                primary: true,
                action: onNext
            )
        }
        .padding()
    }
}

#Preview {
    InstallAndroidView(onNext: {})
}
