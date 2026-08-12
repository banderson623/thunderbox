import SwiftUI
import AppKit

/// Custom About panel — the app icon over the tagline, themed to match the app.
struct AboutView: View {
    private var appIcon: NSImage? {
        NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName)
    }

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return b.isEmpty ? "Version \(v)" : "Version \(v) (\(b))"
    }

    var body: some View {
        ZStack {
            WoodsBackground()
            VStack(spacing: 16) {
                if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable().interpolation(.high)
                        .frame(width: 104, height: 104)
                        .clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 23, style: .continuous)
                            .stroke(Theme.surfaceStroke, lineWidth: 1))
                        .shadow(color: Theme.accent.opacity(0.25), radius: 14, y: 4)
                }

                VStack(spacing: 6) {
                    Text("Thunderbox")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Local development.\nOne convenient seat.")
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.textSecondary)
                }

                Text(version)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary.opacity(0.8))
                    .padding(.top, 2)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 34)
        }
        .frame(width: 340, height: 400)
    }
}
