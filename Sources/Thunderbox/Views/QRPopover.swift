import SwiftUI
import AppKit

/// QR code sized for a phone camera held up to the screen, with the URL and a
/// copy button underneath. Used for individual servers and the LAN dashboard.
struct QRPopover: View {
    let url: URL
    let name: String
    var footnote: String = "Point your phone's camera at the code."

    var body: some View {
        VStack(spacing: 10) {
            Text(name).font(.headline)
            if let qr = LANPresence.qrCode(for: url, sidePixels: 360) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 180, height: 180)
                    .padding(10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Text(url.absoluteString)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
        .padding(16)
    }
}
